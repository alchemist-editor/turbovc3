#include <math.h>
#include <stddef.h>
#include <stdint.h>

static const double DNX_IDCT_BASIS[8][8] = {
  { 0.70710678118654757, 0.98078528040323043, 0.92387953251128674, 0.83146961230254524, 0.70710678118654757, 0.55557023301960229, 0.38268343236508984, 0.19509032201612833 },
  { 0.70710678118654757, 0.83146961230254524, 0.38268343236508984, -0.19509032201612819, -0.70710678118654746, -0.98078528040323043, -0.92387953251128685, -0.55557023301960218 },
  { 0.70710678118654757, 0.55557023301960229, -0.38268343236508973, -0.98078528040323043, -0.70710678118654768, 0.19509032201612830, 0.92387953251128652, 0.83146961230254557 },
  { 0.70710678118654757, 0.19509032201612833, -0.92387953251128674, -0.55557023301960218, 0.70710678118654735, 0.83146961230254557, -0.38268343236508989, -0.98078528040323065 },
  { 0.70710678118654757, -0.19509032201612819, -0.92387953251128685, 0.55557023301960184, 0.70710678118654768, -0.83146961230254512, -0.38268343236509056, 0.98078528040323043 },
  { 0.70710678118654757, -0.55557023301960196, -0.38268343236509034, 0.98078528040323043, -0.70710678118654668, -0.19509032201612803, 0.92387953251128674, -0.83146961230254501 },
  { 0.70710678118654757, -0.83146961230254535, 0.38268343236509000, 0.19509032201612878, -0.70710678118654713, 0.98078528040323065, -0.92387953251128641, 0.55557023301960151 },
  { 0.70710678118654757, -0.98078528040323043, 0.92387953251128652, -0.83146961230254512, 0.70710678118654657, -0.55557023301960151, 0.38268343236508956, -0.19509032201612858 }
};

static int32_t dnx_clip_sample(int32_t value, uint32_t bit_depth) {
  const int32_t max = (1 << bit_depth) - 1;
  if (value < 0) return 0;
  if (value > max) return max;
  return value;
}

void dnx_idct_i32_blocks(const int32_t* coeffs, uint16_t* samples, uint32_t block_count, uint32_t bit_depth) {
  double scratch[64];

  if (coeffs == 0 || samples == 0 || (bit_depth != 8 && bit_depth != 10 && bit_depth != 12)) return;

  for (uint32_t block = 0; block < block_count; block += 1) {
    const int32_t* block_coeffs = coeffs + block * 64;
    uint16_t* block_samples = samples + block * 64;

    for (uint32_t v = 0; v < 8; v += 1) {
      const uint32_t row_offset = v * 8;
      for (uint32_t x = 0; x < 8; x += 1) {
        double sum = 0.0;
        for (uint32_t u = 0; u < 8; u += 1) {
          sum += (double)block_coeffs[row_offset + u] * DNX_IDCT_BASIS[x][u];
        }
        scratch[row_offset + x] = sum;
      }
    }

    for (uint32_t y = 0; y < 8; y += 1) {
      for (uint32_t x = 0; x < 8; x += 1) {
        double sum = 0.0;
        for (uint32_t v = 0; v < 8; v += 1) {
          sum += scratch[v * 8 + x] * DNX_IDCT_BASIS[y][v];
        }
        block_samples[y * 8 + x] = (uint16_t)dnx_clip_sample((int32_t)floor(sum / 4.0 + 0.5), bit_depth);
      }
    }
  }
}

uint32_t dnx_idct_kernel_version(void) {
  return 1;
}

/* AVX2 versions of the native frame decoder's two hottest loops, chosen at run
 * time so a baseline x86-64 build still benefits. They perform the operations
 * of dnx_fast_idct.zig and the frame decoder's RGB conversion in the same
 * order, without fused multiply-add, so their output is bit-identical. */
#if defined(__x86_64__) && (defined(__clang__) || defined(__GNUC__))
#include <cpuid.h>
#include <immintrin.h>

#define DNX_AVX2 __attribute__((target("avx2")))

int dnx_x86_has_avx2(void) {
  unsigned eax, ebx, ecx, edx;
  const unsigned osxsave_and_avx = (1u << 27) | (1u << 28);
  if (!__get_cpuid(1, &eax, &ebx, &ecx, &edx)) return 0;
  if ((ecx & osxsave_and_avx) != osxsave_and_avx) return 0;
  unsigned xcr0_low, xcr0_high;
  __asm__ volatile("xgetbv" : "=a"(xcr0_low), "=d"(xcr0_high) : "c"(0));
  (void)xcr0_high;
  if ((xcr0_low & 6) != 6) return 0;
  if (!__get_cpuid_count(7, 0, &eax, &ebx, &ecx, &edx)) return 0;
  return (ebx >> 5) & 1;
}

DNX_AVX2 static inline void dnx_transpose8(__m256 r[8]) {
  const __m256 t0 = _mm256_unpacklo_ps(r[0], r[1]);
  const __m256 t1 = _mm256_unpackhi_ps(r[0], r[1]);
  const __m256 t2 = _mm256_unpacklo_ps(r[2], r[3]);
  const __m256 t3 = _mm256_unpackhi_ps(r[2], r[3]);
  const __m256 t4 = _mm256_unpacklo_ps(r[4], r[5]);
  const __m256 t5 = _mm256_unpackhi_ps(r[4], r[5]);
  const __m256 t6 = _mm256_unpacklo_ps(r[6], r[7]);
  const __m256 t7 = _mm256_unpackhi_ps(r[6], r[7]);
  const __m256 s0 = _mm256_shuffle_ps(t0, t2, 0x44);
  const __m256 s1 = _mm256_shuffle_ps(t0, t2, 0xee);
  const __m256 s2 = _mm256_shuffle_ps(t1, t3, 0x44);
  const __m256 s3 = _mm256_shuffle_ps(t1, t3, 0xee);
  const __m256 s4 = _mm256_shuffle_ps(t4, t6, 0x44);
  const __m256 s5 = _mm256_shuffle_ps(t4, t6, 0xee);
  const __m256 s6 = _mm256_shuffle_ps(t5, t7, 0x44);
  const __m256 s7 = _mm256_shuffle_ps(t5, t7, 0xee);
  r[0] = _mm256_permute2f128_ps(s0, s4, 0x20);
  r[1] = _mm256_permute2f128_ps(s1, s5, 0x20);
  r[2] = _mm256_permute2f128_ps(s2, s6, 0x20);
  r[3] = _mm256_permute2f128_ps(s3, s7, 0x20);
  r[4] = _mm256_permute2f128_ps(s0, s4, 0x31);
  r[5] = _mm256_permute2f128_ps(s1, s5, 0x31);
  r[6] = _mm256_permute2f128_ps(s2, s6, 0x31);
  r[7] = _mm256_permute2f128_ps(s3, s7, 0x31);
}

/* idctColumns in dnx_fast_idct.zig, operation for operation. */
DNX_AVX2 static inline void dnx_idct_columns(__m256 r[8], const float* factors) {
  const __m256 k0 = _mm256_set1_ps(factors[0]);
  const __m256 k1 = _mm256_set1_ps(factors[1]);
  const __m256 k2 = _mm256_set1_ps(factors[2]);
  const __m256 k3 = _mm256_set1_ps(factors[3]);
  const __m256 k4 = _mm256_set1_ps(factors[4]);
  const __m256 v15 = r[0], v26 = r[1], v21 = r[2], v28 = r[3];
  const __m256 v16 = r[4], v25 = r[5], v22 = r[6], v27 = r[7];
  const __m256 v19 = _mm256_sub_ps(v25, v28);
  const __m256 v20 = _mm256_sub_ps(v26, v27);
  const __m256 v23 = _mm256_add_ps(v26, v27);
  const __m256 v24 = _mm256_add_ps(v25, v28);
  const __m256 v7 = _mm256_add_ps(v23, v24);
  const __m256 v11 = _mm256_add_ps(v21, v22);
  const __m256 v13 = _mm256_sub_ps(v23, v24);
  const __m256 v17 = _mm256_sub_ps(v21, v22);
  const __m256 v8 = _mm256_add_ps(v15, v16);
  const __m256 v9 = _mm256_sub_ps(v15, v16);
  const __m256 v18 = _mm256_mul_ps(_mm256_sub_ps(v19, v20), k0);
  const __m256 v12 = _mm256_sub_ps(_mm256_mul_ps(v19, k1), v18);
  const __m256 v14 = _mm256_sub_ps(v18, _mm256_mul_ps(v20, k2));
  const __m256 v6 = _mm256_sub_ps(v14, v7);
  const __m256 v5 = _mm256_sub_ps(_mm256_mul_ps(v13, k3), v6);
  const __m256 v4 = _mm256_add_ps(v5, v12);
  const __m256 v10 = _mm256_sub_ps(_mm256_mul_ps(v17, k4), v11);
  const __m256 v0 = _mm256_add_ps(v8, v11);
  const __m256 v1 = _mm256_add_ps(v9, v10);
  const __m256 v2 = _mm256_sub_ps(v9, v10);
  const __m256 v3 = _mm256_sub_ps(v8, v11);
  r[0] = _mm256_add_ps(v0, v7);
  r[1] = _mm256_add_ps(v1, v6);
  r[2] = _mm256_add_ps(v2, v5);
  r[3] = _mm256_sub_ps(v3, v4);
  r[4] = _mm256_add_ps(v3, v4);
  r[5] = _mm256_sub_ps(v2, v5);
  r[6] = _mm256_sub_ps(v1, v6);
  r[7] = _mm256_sub_ps(v0, v7);
}

DNX_AVX2 void dnx_idct8_avx2(const int32_t* coefficients, uint16_t* output, const float* scale, const float* factors, uint32_t maximum) {
  __m256 r[8];
  for (int i = 0; i < 8; i += 1) {
    r[i] = _mm256_cvtepi32_ps(_mm256_loadu_si256((const __m256i*)(coefficients + i * 8)));
  }
  dnx_transpose8(r);
  for (int i = 0; i < 8; i += 1) r[i] = _mm256_mul_ps(r[i], _mm256_loadu_ps(scale + i * 8));
  dnx_idct_columns(r, factors);
  dnx_transpose8(r);
  dnx_idct_columns(r, factors);

  const __m256 half = _mm256_set1_ps(0.5f);
  const __m256 zero = _mm256_setzero_ps();
  const __m256 top = _mm256_set1_ps((float)maximum);
  __m256i rounded[8];
  for (int i = 0; i < 8; i += 1) {
    const __m256 offset = _mm256_add_ps(r[i], half);
    rounded[i] = _mm256_cvttps_epi32(_mm256_min_ps(_mm256_max_ps(offset, zero), top));
  }
  for (int i = 0; i < 8; i += 2) {
    const __m256i packed = _mm256_permute4x64_epi64(_mm256_packus_epi32(rounded[i], rounded[i + 1]), 0xd8);
    _mm256_storeu_si256((__m256i*)(output + i * 8), packed);
  }
}

/* Converts whole groups of 8 pixels and returns how many pixels it wrote; the
 * caller finishes the line. Writes exactly 3 bytes per pixel. */
DNX_AVX2 size_t dnx_rgb8_line_avx2(const uint16_t* luma, const uint16_t* cb, const uint16_t* cr, uint8_t* out, size_t width, uint32_t shift, int is_444) {
  const __m128i count = _mm_cvtsi32_si128((int)shift);
  const __m256i double_up = _mm256_setr_epi32(0, 0, 1, 1, 2, 2, 3, 3);
  const __m256i y_offset = _mm256_set1_epi32(16);
  const __m256i chroma_offset = _mm256_set1_epi32(128);
  const __m256i y_factor = _mm256_set1_epi32(298);
  const __m256i red_v = _mm256_set1_epi32(459);
  const __m256i green_u = _mm256_set1_epi32(-55);
  const __m256i green_v = _mm256_set1_epi32(-136);
  const __m256i blue_u = _mm256_set1_epi32(541);
  const __m256i rounding = _mm256_set1_epi32(128);
  const __m256i zero = _mm256_setzero_si256();
  const __m256i top = _mm256_set1_epi32(255);
  const __m256i bytes = _mm256_setr_epi8(0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14, -1, -1, -1, -1, 0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14, -1, -1, -1, -1);
  const __m256i compact = _mm256_setr_epi32(0, 1, 2, 4, 5, 6, 3, 7);

  size_t x = 0;
  for (; x + 8 <= width; x += 8) {
    __m256i u, v;
    if (is_444) {
      u = _mm256_cvtepu16_epi32(_mm_loadu_si128((const __m128i*)(cb + x)));
      v = _mm256_cvtepu16_epi32(_mm_loadu_si128((const __m128i*)(cr + x)));
    } else {
      u = _mm256_permutevar8x32_epi32(_mm256_cvtepu16_epi32(_mm_loadl_epi64((const __m128i*)(cb + x / 2))), double_up);
      v = _mm256_permutevar8x32_epi32(_mm256_cvtepu16_epi32(_mm_loadl_epi64((const __m128i*)(cr + x / 2))), double_up);
    }
    u = _mm256_sub_epi32(_mm256_srl_epi32(u, count), chroma_offset);
    v = _mm256_sub_epi32(_mm256_srl_epi32(v, count), chroma_offset);
    __m256i y = _mm256_cvtepu16_epi32(_mm_loadu_si128((const __m128i*)(luma + x)));
    y = _mm256_mullo_epi32(_mm256_sub_epi32(_mm256_srl_epi32(y, count), y_offset), y_factor);
    y = _mm256_add_epi32(y, rounding);

    __m256i red = _mm256_add_epi32(y, _mm256_mullo_epi32(v, red_v));
    __m256i green = _mm256_add_epi32(y, _mm256_add_epi32(_mm256_mullo_epi32(u, green_u), _mm256_mullo_epi32(v, green_v)));
    __m256i blue = _mm256_add_epi32(y, _mm256_mullo_epi32(u, blue_u));
    red = _mm256_min_epi32(_mm256_max_epi32(_mm256_srai_epi32(red, 8), zero), top);
    green = _mm256_min_epi32(_mm256_max_epi32(_mm256_srai_epi32(green, 8), zero), top);
    blue = _mm256_min_epi32(_mm256_max_epi32(_mm256_srai_epi32(blue, 8), zero), top);

    const __m256i pixels = _mm256_or_si256(red, _mm256_or_si256(_mm256_slli_epi32(green, 8), _mm256_slli_epi32(blue, 16)));
    const __m256i packed = _mm256_permutevar8x32_epi32(_mm256_shuffle_epi8(pixels, bytes), compact);
    _mm_storeu_si128((__m128i*)(out + x * 3), _mm256_castsi256_si128(packed));
    _mm_storel_epi64((__m128i*)(out + x * 3 + 16), _mm256_extracti128_si256(packed, 1));
  }
  return x;
}

/* Copies whole groups of 16 samples to little-endian u16s moved up by `shift`;
 * returns how many it wrote. */
DNX_AVX2 size_t dnx_shift_line_avx2(const uint16_t* samples, uint8_t* out, size_t count, uint32_t shift) {
  const __m128i bits = _mm_cvtsi32_si128((int)shift);
  size_t x = 0;
  for (; x + 16 <= count; x += 16) {
    const __m256i moved = _mm256_sll_epi16(_mm256_loadu_si256((const __m256i*)(samples + x)), bits);
    _mm256_storeu_si256((__m256i*)(out + x * 2), moved);
  }
  return x;
}

/* Interleaves whole groups of 16 Cb,Cr pairs, each moved up by `shift`;
 * returns how many pairs it wrote. */
DNX_AVX2 size_t dnx_interleave_line_avx2(const uint16_t* cb, const uint16_t* cr, uint8_t* out, size_t pairs, uint32_t shift) {
  const __m128i bits = _mm_cvtsi32_si128((int)shift);
  size_t x = 0;
  for (; x + 16 <= pairs; x += 16) {
    const __m256i u = _mm256_sll_epi16(_mm256_loadu_si256((const __m256i*)(cb + x)), bits);
    const __m256i v = _mm256_sll_epi16(_mm256_loadu_si256((const __m256i*)(cr + x)), bits);
    const __m256i low = _mm256_unpacklo_epi16(u, v);
    const __m256i high = _mm256_unpackhi_epi16(u, v);
    _mm256_storeu_si256((__m256i*)(out + x * 4), _mm256_permute2x128_si256(low, high, 0x20));
    _mm256_storeu_si256((__m256i*)(out + x * 4 + 32), _mm256_permute2x128_si256(low, high, 0x31));
  }
  return x;
}
#endif
