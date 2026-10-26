/* C vector types for the import's vector mapping (SIMD-and-Vectors.md 1.6): vectors.cdecl is what
   `Treadle.exe --import-c vectors.cimport` writes. */
#include <immintrin.h>

typedef float vf4 __attribute__((vector_size(16)));
typedef int vi4 __attribute__((vector_size(16)));
typedef unsigned char vb16 __attribute__((vector_size(16)));
typedef float vf3 __attribute__((ext_vector_type(3)));
typedef double vd2 __attribute__((vector_size(16)));
typedef short vs3 __attribute__((vector_size(6)));

__m128 vec_scale(__m128 v, float k);
__m128d vec_twice(__m128d v);
__m128i vec_bits(__m128i v);
__m256 vec_wide(__m256 v);
__m256i vec_wide_bits(__m256i v);
vf4 vec_add(vf4 a, vf4 b);
vi4 vec_addi(vi4 a, vi4 b);
vb16 vec_bytes(vb16 v);
vf3 vec_cross(vf3 a, vf3 b);
vd2 vec_d2(vd2 v);
vs3 vec_odd(vs3 v);
