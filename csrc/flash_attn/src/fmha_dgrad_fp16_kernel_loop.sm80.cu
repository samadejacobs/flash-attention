/* Copyright (c) 2022, Tri Dao.
 */

#include "static_switch.h"
#include "fp16_switch.h"
#include "fmha.h"
#include "fmha_dgrad_kernel_1xN_loop.h"

// Find the number of splits that maximizes the occupancy. For example, if we have
// batch * n_heads = 48 and we have 108 SMs, having 2 splits (efficiency = 0.89) is
// better than having 3 splits (efficiency = 0.67). However, we also don't want too many
// splits as that would incur more HBM reads/writes.
// Moreover, more than 1 split incurs extra cost of zeroing out dk/dv and doing atomic add
// instead of just writing.
// So for num_splits > 1, we divide the efficiency by some factor (e.g. 1.25, depending on seqlen)
// to account for this. Moreover, more splits means atomic add will be slower.
int num_splits_heuristic_bwd(int batch_nheads, int num_SMs, int ctas_per_sm, int max_splits,
                             int seqlen, bool is_causal) {
    float max_efficiency = 0.f;
    int best_num_splits = 1;
    std::vector<float> efficiency;
    efficiency.reserve(max_splits);
    float discount_factor = 1.f + 512.0 / seqlen;  // 1.25 for seqlen 2k, 1.125 for 4k.
    discount_factor *= is_causal ? 1.1 : 1.f; // causal makes it even slower.
    for (int num_splits = 1; num_splits <= max_splits; num_splits++) {
        float n_waves = float(batch_nheads * num_splits) / (num_SMs * ctas_per_sm);
        float eff_raw = n_waves / ceil(n_waves);
        // Heuristic: each increase in num_splits results in 6% slowdown, up to maybe 8 splits.
        float eff = num_splits == 1 ? eff_raw : (eff_raw  - 0.07 * std::min(num_splits - 2, 6)) / discount_factor;
        // printf("num_splits = %d, eff_raw = %f, eff = %f\n", num_splits, eff_raw, eff);
        if (eff > max_efficiency) {
            max_efficiency = eff;
            best_num_splits = num_splits;
        }
        efficiency.push_back(eff);
    }
    // printf("num_splits chosen = %d\n", best_num_splits);
    return best_num_splits;
}

template<typename Kernel_traits, bool Is_dropout, bool Is_causal, int loop_steps=-1>
__global__ void fmha_dgrad_fp16_sm80_dq_dk_dv_loop_kernel(FMHA_dgrad_params params) {
    fmha::compute_dq_dk_dv_1xN<Kernel_traits, Is_dropout, Is_causal, loop_steps>(params);
}

template<typename Kernel_traits>
void run_fmha_dgrad_fp16_sm80_loop_(FMHA_dgrad_params &params, cudaStream_t stream, const bool configure) {
    constexpr int smem_size_softmax = Kernel_traits::Cta_tile_p::M * Kernel_traits::Cta_tile_p::WARPS_N * sizeof(float);
    constexpr int smem_size_q = Kernel_traits::Smem_tile_q::BYTES_PER_TILE;
    constexpr int smem_size_v = Kernel_traits::Smem_tile_v::BYTES_PER_TILE;
    constexpr int smem_size_dq = Kernel_traits::Smem_tile_o::BYTES_PER_TILE;

    using Smem_tile_s = fmha::Smem_tile_mma_transposed<typename Kernel_traits::Cta_tile_p>;
    constexpr int smem_size_s = Smem_tile_s::BYTES_PER_TILE;
    static_assert(smem_size_s == 16 * Kernel_traits::Cta_tile_p::N * 2);
    static_assert(smem_size_dq == 16 * Kernel_traits::Cta_tile_p::K * 4 * Kernel_traits::Cta_tile_p::WARPS_N);

    constexpr int smem_size_dq_dk_dv = smem_size_q * 2 + smem_size_v * (Kernel_traits::V_IN_REGS ? 1 : 2) + smem_size_dq + smem_size_s * 2;
    constexpr int blocksize_c = Kernel_traits::Cta_tile_p::N;
    // printf("blocksize_c = %d, WARPS_N = %d, Smem size = %d\n", blocksize_c, Kernel_traits::Cta_tile_p::WARPS_N, smem_size_dq_dk_dv);

    bool is_dropout = params.p_dropout < 1.f;  // params.p_dropout is the probability of "keeping"
    // Work-around for gcc 7. It doesn't like nested BOOL_SWITCH.
    BOOL_SWITCH(is_dropout, IsDropoutConst, [&] {
        auto kernel = params.is_causal
            ? &fmha_dgrad_fp16_sm80_dq_dk_dv_loop_kernel<Kernel_traits, IsDropoutConst, true>
            : &fmha_dgrad_fp16_sm80_dq_dk_dv_loop_kernel<Kernel_traits, IsDropoutConst, false>;
        if (params.seqlen_k == blocksize_c) {
            kernel = params.is_causal
                ? &fmha_dgrad_fp16_sm80_dq_dk_dv_loop_kernel<Kernel_traits, IsDropoutConst, true, /*loop_steps=*/1>
                : &fmha_dgrad_fp16_sm80_dq_dk_dv_loop_kernel<Kernel_traits, IsDropoutConst, false, /*loop_steps=*/1>;
        } else if (params.seqlen_k == blocksize_c * 2) {
            kernel = params.is_causal
                ? &fmha_dgrad_fp16_sm80_dq_dk_dv_loop_kernel<Kernel_traits, IsDropoutConst, true, /*loop_steps=*/2>
                : &fmha_dgrad_fp16_sm80_dq_dk_dv_loop_kernel<Kernel_traits, IsDropoutConst, false, /*loop_steps=*/2>;
        }
        if( smem_size_dq_dk_dv >= 48 * 1024 ) {
            FMHA_CHECK_CUDA(cudaFuncSetAttribute(
                kernel, cudaFuncAttributeMaxDynamicSharedMemorySize, smem_size_dq_dk_dv));
        }
        // Automatically set num_splits to maximize occupancy
        if (params.num_splits <= 0) {
            int ctas_per_sm;
            cudaError status_ = cudaOccupancyMaxActiveBlocksPerMultiprocessor(
                &ctas_per_sm, kernel, Kernel_traits::THREADS, smem_size_dq_dk_dv);
            auto dprops = at::cuda::getCurrentDeviceProperties();
            // printf("CTAS_PER_SM = %d, nSMs = %d\n", ctas_per_sm, dprops->multiProcessorCount);
            constexpr int M = Kernel_traits::Cta_tile_p::M;
            // We don't want more than 10 splits due to numerical error.
            // Numerical error on dk/dv scales as sqrt(num_splits).
            params.num_splits = num_splits_heuristic_bwd(
                params.b * params.h, dprops->multiProcessorCount,
                ctas_per_sm, /*max_splits=*/std::min(10, (params.seqlen_q + M - 1 / M)),
                params.seqlen_k, params.is_causal
            );
        }
        if (configure) return;
        dim3 grid(params.b, params.h, params.num_splits);
        kernel<<<grid, Kernel_traits::THREADS, smem_size_dq_dk_dv, stream>>>(params);
        FMHA_CHECK_CUDA(cudaPeekAtLastError());
    });
}

void run_fmha_dgrad_fp16_sm80(FMHA_dgrad_params &params, cudaStream_t stream, const bool configure) {
    // work around for MSVC issue
    FP16_SWITCH(params.is_bf16, [&] {
        auto dprops = at::cuda::getCurrentDeviceProperties();
        if (params.d <= 32) {
            if (params.seqlen_k == 128) {
                using Kernel_traits = FMHA_kernel_traits<128, 32, 16, 1, 8, 0x08u, elem_type>;
                run_fmha_dgrad_fp16_sm80_loop_<Kernel_traits>(params, stream, configure);
            } else if (params.seqlen_k >= 256) {
                using Kernel_traits = FMHA_kernel_traits<256, 32, 16, 1, 8, 0x08u, elem_type>;
                run_fmha_dgrad_fp16_sm80_loop_<Kernel_traits>(params, stream, configure);
            }
        } else if (params.d <= 64) {
            if (params.seqlen_k == 128) {
                using Kernel_traits = FMHA_kernel_traits<128, 64, 16, 1, 8, 0x08u, elem_type>;
                run_fmha_dgrad_fp16_sm80_loop_<Kernel_traits>(params, stream, configure);
            } else if (params.seqlen_k >= 256) {
                if (dprops->major == 8 && dprops->minor == 0) {
                    // Don't share smem for K & V, and don't keep V in registers
                    // This speeds things up by 2-3% by avoiding register spills, but it
                    // uses more shared memory, which is fine on A100 but not other GPUs.
                    // For other GPUs, we keep V in registers.
                    using Kernel_traits = FMHA_kernel_traits<256, 64, 16, 1, 8, 0x100u, elem_type>;
                    run_fmha_dgrad_fp16_sm80_loop_<Kernel_traits>(params, stream, configure);
                } else if (dprops->major == 8 && dprops->minor > 0) {
                    using Kernel_traits = FMHA_kernel_traits<256, 64, 16, 1, 8, 0x08u, elem_type>;
                    run_fmha_dgrad_fp16_sm80_loop_<Kernel_traits>(params, stream, configure);
                } else if (dprops->major == 7 && dprops->minor == 5) {
                    using Kernel_traits = FMHA_kernel_traits<128, 64, 16, 1, 8, 0x08u, elem_type>;
                    run_fmha_dgrad_fp16_sm80_loop_<Kernel_traits>(params, stream, configure);
                }
            }
        } else if (params.d <= 128) {
            using Kernel_traits = FMHA_kernel_traits<128, 128, 16, 1, 8, 0x100u, elem_type>;
            run_fmha_dgrad_fp16_sm80_loop_<Kernel_traits>(params, stream, configure);
        }
    });
}