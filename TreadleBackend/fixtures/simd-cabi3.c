/* The C side of the simd-cabi fixture: vector arguments and results across the C boundary both ways
   (SIMD-and-Vectors.md 1.6). Treadle calls the c_* functions; c_check calls Treadle's exported kx_*. */
#include <stdio.h>
#include <xmmintrin.h>

typedef float f2 __attribute__((vector_size(8)));
typedef float f8 __attribute__((vector_size(32)));
typedef int i4 __attribute__((vector_size(16)));
typedef float f3 __attribute__((ext_vector_type(3)));

__m128 kx_mad(__m128 a, __m128 b, __m128 c);
f2 kx_swap2(f2 v);
float kx_hsum8(f8 v);
f8 kx_twice8(f8 v);
f3 kx_lerp3(f3 a, f3 b, float t);
i4 kx_negi(i4 v);

__m128 c_scale(__m128 v, float k) { return _mm_mul_ps(v, _mm_set1_ps(k)); }
f2 c_swap2(f2 v) { f2 r = { v[1], v[0] }; return r; }
i4 c_addi(i4 a, i4 b) { return a + b; }
f3 c_cross(f3 a, f3 b) { return a.yzx * b.zxy - a.zxy * b.yzx; }
f8 c_twice8(f8 v) { return v + v; }
float c_sum8(f8 v) { float s = 0; for (int i = 0; i < 8; i++) s += v[i]; return s; }

/* every exported kx_* once; prints what came back */
long long c_check(void)
{
    __m128 m = kx_mad(_mm_set_ps(4, 3, 2, 1), _mm_set1_ps(2), _mm_set1_ps(0.5f));
    float mo[4];
    _mm_storeu_ps(mo, m);
    f2 s = kx_swap2((f2){ 1.5f, -2.5f });
    f8 e = { 1, 2, 3, 4, 5, 6, 7, 8 };
    float h = kx_hsum8(e);
    f8 t = kx_twice8(e);
    f3 l = kx_lerp3((f3){ 0, 10, 20 }, (f3){ 10, 20, 40 }, 0.5f);
    i4 n = kx_negi((i4){ 1, -2, 3, -4 });
    printf("C sees mad %g %g %g %g swap %g %g hsum %g twice %g %g lerp %g %g %g neg %d %d\n",
        mo[0], mo[1], mo[2], mo[3], s[0], s[1], h, t[0], t[7], l.x, l.y, l.z, n[0], n[3]);
    return (long long)(mo[3] + h + t[7] + l.z);
}
