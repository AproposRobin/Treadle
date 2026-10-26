/*
 * treadle_gpu_math.c - the transcendental Math functions of [Kernel] code on the GPU
 * (docs/GPU-Compute.md, "Math on the GPU").
 *
 * NVPTX has no instructions for sin, cos, exp, log and the rest, and LLVM lowers their intrinsics
 * to calls of CUDA's libdevice, which is part of the CUDA toolkit (not shipped, not installed). This
 * file is Treadle's own: plain C with no headers, compiled by the vendored clang for
 * nvptx64-nvidia-cuda to bitcode at Build and linked into the kernels' module
 * (-mlink-builtin-bitcode: only what a kernel calls is kept). The kernel module calls
 * treadle_gpu_<name>f (float) and treadle_gpu_<name> (double) where the CPU code calls
 * llvm.<name>.f32 / .f64 (EmitKernel.bf rewrites the calls).
 *
 * Method: range reduction with FMA (Cody-Waite, the reduction constants split in two or three
 * parts) and polynomials on the reduced range (minimax for the float sin and cos, Taylor series of
 * enough terms for the rest), the float functions in float where the result allows it (the float
 * sin and cos coefficients are the widely published Cephes minimax values). Accuracy
 * against the C library of the CPU (measured by the gpu-math fixture): see GPU-Compute.md. Known
 * limits: the trigonometric reduction loses accuracy for |x| above about 1e9 (no Payne-Hanek), and
 * double pow is exp(y * log(x)), whose relative error grows with |y * log(x)| (about 1e-13 for
 * results near 1e300).
 */

typedef unsigned int u32;
typedef unsigned long long u64;

#define FN __attribute__((always_inline)) static inline

FN float f_bits(u32 b) { return __builtin_bit_cast(float, b); }
FN u32 f_word(float x) { return __builtin_bit_cast(u32, x); }
FN double d_bits(u64 b) { return __builtin_bit_cast(double, b); }
FN u64 d_word(double x) { return __builtin_bit_cast(u64, x); }

FN int f_isnan(float x) { return x != x; }
FN int d_isnan(double x) { return x != x; }

#define F_INF __builtin_inff()
#define D_INF __builtin_inf()
#define F_NAN __builtin_nanf("")
#define D_NAN __builtin_nan("")

static const double PIO2_HI = 1.5707963267948966192e+00;    /* 0x3FF921FB54442D18 */
static const double PIO2_LO = 6.1232339957367660e-17;       /* 0x3C91A62633145C07 */
static const double PIO2_LO2 = -1.4973849048591698e-33;     /* 0xB91F1976B7ED8FBC */
static const double PI = 3.14159265358979311600e+00;
static const double PI_LO = 1.2246467991473532e-16;
static const double LN2_HI = 6.93147180559945286227e-01;    /* 0x3FE62E42FEFA39EF */
static const double LN2_LO = 2.31904681384629955842e-17;
static const double LOG2E = 1.44269504088896338700e+00;

/* ---- double ---------------------------------------------------------------------------------- */

/* x - k * pi/2 for k = round(x * 2/pi), and k's low bits (the quadrant). */
FN double d_reduce(double x, int* quadrant)
{
    double k = __builtin_rint(x * 6.36619772367581382433e-01);
    double r = __builtin_fma(-k, PIO2_HI, x);
    r = __builtin_fma(-k, PIO2_LO, r);
    r = __builtin_fma(-k, PIO2_LO2, r);
    *quadrant = (int)(long long)k & 3;
    return r;
}

/* sin and cos on [-pi/4, pi/4]: Taylor series through x^21 / x^18 (the next terms are below
   1e-20 there). */
FN double d_sin_kernel(double x)
{
    double z = x * x;
    double p = 1.0 / 51090942171709440000.0;                 /* 1/21! */
    p = __builtin_fma(p, z, -1.0 / 121645100408832000.0);    /* -1/19! */
    p = __builtin_fma(p, z, 1.0 / 355687428096000.0);        /* 1/17! */
    p = __builtin_fma(p, z, -1.0 / 1307674368000.0);
    p = __builtin_fma(p, z, 1.0 / 6227020800.0);
    p = __builtin_fma(p, z, -1.0 / 39916800.0);
    p = __builtin_fma(p, z, 1.0 / 362880.0);
    p = __builtin_fma(p, z, -1.0 / 5040.0);
    p = __builtin_fma(p, z, 1.0 / 120.0);
    p = __builtin_fma(p, z, -1.0 / 6.0);
    return __builtin_fma(x * z, p, x);
}

FN double d_cos_kernel(double x)
{
    double z = x * x;
    double p = -1.0 / 6402373705728000.0;                     /* -1/18! */
    p = __builtin_fma(p, z, 1.0 / 20922789888000.0);          /* 1/16! */
    p = __builtin_fma(p, z, -1.0 / 87178291200.0);            /* -1/14! */
    p = __builtin_fma(p, z, 1.0 / 479001600.0);
    p = __builtin_fma(p, z, -1.0 / 3628800.0);
    p = __builtin_fma(p, z, 1.0 / 40320.0);
    p = __builtin_fma(p, z, -1.0 / 720.0);
    p = __builtin_fma(p, z, 1.0 / 24.0);
    /* 1 - z/2 + z^2 p, with 1 - z/2 summed so that its rounding error is kept */
    double hz = 0.5 * z;
    double w = 1.0 - hz;
    return w + (((1.0 - w) - hz) + z * z * p);
}

double treadle_gpu_sin(double x)
{
    if (__builtin_fabs(x) == D_INF || d_isnan(x))
        return D_NAN;
    int q;
    double r = d_reduce(x, &q);
    switch (q)
    {
    case 0: return d_sin_kernel(r);
    case 1: return d_cos_kernel(r);
    case 2: return -d_sin_kernel(r);
    default: return -d_cos_kernel(r);
    }
}

double treadle_gpu_cos(double x)
{
    if (__builtin_fabs(x) == D_INF || d_isnan(x))
        return D_NAN;
    int q;
    double r = d_reduce(x, &q);
    switch (q)
    {
    case 0: return d_cos_kernel(r);
    case 1: return -d_sin_kernel(r);
    case 2: return -d_cos_kernel(r);
    default: return d_sin_kernel(r);
    }
}

double treadle_gpu_tan(double x)
{
    if (__builtin_fabs(x) == D_INF || d_isnan(x))
        return D_NAN;
    int q;
    double r = d_reduce(x, &q);
    double s = d_sin_kernel(r), c = d_cos_kernel(r);
    return (q & 1) ? -c / s : s / c;
}

/* 2^k for any int k (subnormal and overflowing results included) times x. */
FN double d_scale(double x, int k)
{
    if (k > 1023)
    {
        x *= d_bits(0x7FE0000000000000ull); /* 2^1023 */
        k -= 1023;
        if (k > 1023)
            k = 1023;
    }
    else if (k < -1022)
    {
        x *= d_bits(0x0010000000000000ull) * d_bits(0x4340000000000000ull); /* 2^-1022 * 2^53 */
        k += 1022 - 53;
        if (k < -1022)
            k = -1022;
    }
    return x * d_bits((u64)(k + 1023) << 52);
}

double treadle_gpu_exp(double x)
{
    if (d_isnan(x))
        return x;
    if (x > 709.782712893384)
        return D_INF;
    if (x < -745.1332191019412)
        return 0.0;
    double k = __builtin_rint(x * LOG2E);
    double r = __builtin_fma(-k, LN2_HI, x);
    r = __builtin_fma(-k, LN2_LO, r);
    /* e^r for |r| <= ln2/2: Taylor through r^13 */
    double p = 1.0 / 6227020800.0;
    p = __builtin_fma(p, r, 1.0 / 479001600.0);
    p = __builtin_fma(p, r, 1.0 / 39916800.0);
    p = __builtin_fma(p, r, 1.0 / 3628800.0);
    p = __builtin_fma(p, r, 1.0 / 362880.0);
    p = __builtin_fma(p, r, 1.0 / 40320.0);
    p = __builtin_fma(p, r, 1.0 / 5040.0);
    p = __builtin_fma(p, r, 1.0 / 720.0);
    p = __builtin_fma(p, r, 1.0 / 120.0);
    p = __builtin_fma(p, r, 1.0 / 24.0);
    p = __builtin_fma(p, r, 1.0 / 6.0);
    p = __builtin_fma(p, r, 0.5);
    double e = __builtin_fma(p * r, r, r) + 1.0; /* 1 + r + r^2 p */
    return d_scale(e, (int)k);
}

/* log(x) as e*ln2 + 2 atanh(s), s = (m - 1) / (m + 1), m in [sqrt(1/2), sqrt(2)). */
double treadle_gpu_log(double x)
{
    if (d_isnan(x) || x < 0.0)
        return D_NAN;
    if (x == 0.0)
        return -D_INF;
    if (x == D_INF)
        return x;
    int e = 0;
    if (x < d_bits(0x0010000000000000ull))
    {
        x *= d_bits(0x4350000000000000ull); /* 2^54 */
        e = -54;
    }
    u64 w = d_word(x);
    e += (int)((w >> 52) & 0x7FF) - 1023;
    double m = d_bits((w & 0x000FFFFFFFFFFFFFull) | 0x3FF0000000000000ull);
    if (m > 1.4142135623730951)
    {
        m *= 0.5;
        e++;
    }
    double f = m - 1.0;
    double s = f / (2.0 + f);
    double z = s * s;
    double p = 1.0 / 25.0;
    p = __builtin_fma(p, z, 1.0 / 23.0);
    p = __builtin_fma(p, z, 1.0 / 21.0);
    p = __builtin_fma(p, z, 1.0 / 19.0);
    p = __builtin_fma(p, z, 1.0 / 17.0);
    p = __builtin_fma(p, z, 1.0 / 15.0);
    p = __builtin_fma(p, z, 1.0 / 13.0);
    p = __builtin_fma(p, z, 1.0 / 11.0);
    p = __builtin_fma(p, z, 1.0 / 9.0);
    p = __builtin_fma(p, z, 1.0 / 7.0);
    p = __builtin_fma(p, z, 1.0 / 5.0);
    p = __builtin_fma(p, z, 1.0 / 3.0);
    /* log(m) = 2 atanh(s) = 2s (1 + z/3 + z^2/5 + ...) */
    double t = 2.0 * s;
    double lm = __builtin_fma(t * z, p, t);
    double de = (double)e;
    return __builtin_fma(de, LN2_HI, __builtin_fma(de, LN2_LO, lm));
}

FN int d_is_int(double y) { return __builtin_rint(y) == y; }
FN int d_is_odd_int(double y) { return d_is_int(y) && __builtin_fabs(y) < 9007199254740992.0 && __builtin_fmod(y, 2.0) != 0.0; }

double treadle_gpu_pow(double x, double y)
{
    if (y == 0.0 || x == 1.0)
        return 1.0;
    if (d_isnan(x) || d_isnan(y))
        return D_NAN;
    double ax = __builtin_fabs(x);
    if (__builtin_fabs(y) == D_INF)
    {
        if (ax == 1.0)
            return 1.0;
        return ((ax > 1.0) == (y > 0.0)) ? D_INF : 0.0;
    }
    int negate = 0;
    if (x < 0.0)
    {
        if (!d_is_int(y))
            return D_NAN;
        negate = d_is_odd_int(y);
    }
    if (ax == 0.0)
    {
        double r = (y > 0.0) ? 0.0 : D_INF;
        return negate ? -r : r;
    }
    if (ax == D_INF)
    {
        double r = (y > 0.0) ? D_INF : 0.0;
        return negate ? -r : r;
    }
    double r = treadle_gpu_exp(y * treadle_gpu_log(ax));
    return negate ? -r : r;
}

/* atan on [0, inf) by reduction to |a| <= tan(pi/12), then the Taylor series. */
FN double d_atan_pos(double a)
{
    int invert = a > 1.0;
    if (invert)
        a = 1.0 / a;
    int shift = a > 0.2679491924311227; /* tan(pi/12) */
    if (shift)
        a = (a * 1.7320508075688772 - 1.0) / (a + 1.7320508075688772);
    double z = a * a;
    double p = -1.0 / 31.0;
    p = __builtin_fma(p, z, 1.0 / 29.0);
    p = __builtin_fma(p, z, -1.0 / 27.0);
    p = __builtin_fma(p, z, 1.0 / 25.0);
    p = __builtin_fma(p, z, -1.0 / 23.0);
    p = __builtin_fma(p, z, 1.0 / 21.0);
    p = __builtin_fma(p, z, -1.0 / 19.0);
    p = __builtin_fma(p, z, 1.0 / 17.0);
    p = __builtin_fma(p, z, -1.0 / 15.0);
    p = __builtin_fma(p, z, 1.0 / 13.0);
    p = __builtin_fma(p, z, -1.0 / 11.0);
    p = __builtin_fma(p, z, 1.0 / 9.0);
    p = __builtin_fma(p, z, -1.0 / 7.0);
    p = __builtin_fma(p, z, 1.0 / 5.0);
    p = __builtin_fma(p, z, -1.0 / 3.0);
    double r = __builtin_fma(a * z, p, a);
    if (shift)
        r += 5.2359877559829882e-01; /* pi/6 */
    if (invert)
        r = (PIO2_HI - r) + PIO2_LO;
    return r;
}

double treadle_gpu_atan(double x)
{
    if (d_isnan(x))
        return x;
    double r = d_atan_pos(__builtin_fabs(x));
    return __builtin_copysign(r, x);
}

double treadle_gpu_atan2(double y, double x)
{
    if (d_isnan(x) || d_isnan(y))
        return D_NAN;
    double ay = __builtin_fabs(y), ax = __builtin_fabs(x);
    int xneg = __builtin_signbit(x) != 0;
    double r;
    if (ay == 0.0)
        r = xneg ? PI : 0.0;
    else if (ax == 0.0)
        r = PIO2_HI;
    else if (ax == D_INF)
    {
        if (ay == D_INF)
            r = xneg ? 2.3561944901923448 : 7.8539816339744828e-01;
        else
            r = xneg ? PI : 0.0;
    }
    else if (ay == D_INF)
        r = PIO2_HI;
    else
    {
        r = d_atan_pos(ay / ax);
        if (xneg)
            r = (PI - r) + PI_LO;
    }
    return __builtin_copysign(r, y);
}

double treadle_gpu_asin(double x)
{
    if (d_isnan(x) || __builtin_fabs(x) > 1.0)
        return D_NAN;
    return treadle_gpu_atan2(x, __builtin_sqrt((1.0 - x) * (1.0 + x)));
}

double treadle_gpu_acos(double x)
{
    if (d_isnan(x) || __builtin_fabs(x) > 1.0)
        return D_NAN;
    return treadle_gpu_atan2(__builtin_sqrt((1.0 - x) * (1.0 + x)), x);
}

/* ---- float ----------------------------------------------------------------------------------- */

/* sin and cos on [-pi/4, pi/4] (minimax polynomials, about 1 ulp). */
FN float f_sin_kernel(float x)
{
    float z = x * x;
    float p = __builtin_fmaf(z, -1.9515295891e-4f, 8.3321608736e-3f);
    p = __builtin_fmaf(z, p, -1.6666654611e-1f);
    return __builtin_fmaf(x * z, p, x);
}

FN float f_cos_kernel(float x)
{
    float z = x * x;
    float p = __builtin_fmaf(z, 2.443315711809948e-5f, -1.388731625493765e-3f);
    p = __builtin_fmaf(z, p, 4.166664568298827e-2f);
    return __builtin_fmaf(z * z, p, __builtin_fmaf(z, -0.5f, 1.0f));
}

/* x - k * pi/2 in float (|x| below 105615: three parts with FMA), else through double. */
FN float f_reduce(float x, int* quadrant)
{
    if (__builtin_fabsf(x) < 105615.0f)
    {
        float k = __builtin_rintf(x * 0.636619772f);
        float r = __builtin_fmaf(-k, 1.57079637e+00f, x);
        r = __builtin_fmaf(-k, -4.37113883e-08f, r);
        r = __builtin_fmaf(-k, -1.71512451e-15f, r);
        *quadrant = (int)k & 3;
        return r;
    }
    int q;
    double r = d_reduce((double)x, &q);
    *quadrant = q;
    return (float)r;
}

float treadle_gpu_sinf(float x)
{
    if (__builtin_fabsf(x) == F_INF || f_isnan(x))
        return F_NAN;
    int q;
    float r = f_reduce(x, &q);
    switch (q)
    {
    case 0: return f_sin_kernel(r);
    case 1: return f_cos_kernel(r);
    case 2: return -f_sin_kernel(r);
    default: return -f_cos_kernel(r);
    }
}

float treadle_gpu_cosf(float x)
{
    if (__builtin_fabsf(x) == F_INF || f_isnan(x))
        return F_NAN;
    int q;
    float r = f_reduce(x, &q);
    switch (q)
    {
    case 0: return f_cos_kernel(r);
    case 1: return -f_sin_kernel(r);
    case 2: return -f_cos_kernel(r);
    default: return f_sin_kernel(r);
    }
}

float treadle_gpu_tanf(float x)
{
    if (__builtin_fabsf(x) == F_INF || f_isnan(x))
        return F_NAN;
    /* in double: the quotient of two float kernels loses a few bits near the poles */
    return (float)treadle_gpu_tan((double)x);
}

float treadle_gpu_expf(float x)
{
    if (f_isnan(x))
        return x;
    if (x > 88.7228394f)
        return F_INF;
    if (x < -103.972084f)
        return 0.0f;
    float k = __builtin_rintf(x * 1.44269502f);
    float r = __builtin_fmaf(-k, 0.693145752f, x);
    r = __builtin_fmaf(-k, 1.42860677e-06f, r);
    /* e^r for |r| <= ln2/2: Taylor through r^7 */
    float p = 1.0f / 5040.0f;
    p = __builtin_fmaf(p, r, 1.0f / 720.0f);
    p = __builtin_fmaf(p, r, 1.0f / 120.0f);
    p = __builtin_fmaf(p, r, 1.0f / 24.0f);
    p = __builtin_fmaf(p, r, 1.0f / 6.0f);
    p = __builtin_fmaf(p, r, 0.5f);
    float e = __builtin_fmaf(p * r, r, r) + 1.0f;
    int ki = (int)k;
    /* 2^k in two steps, so that subnormal and the largest results come out right */
    int k1 = ki / 2, k2 = ki - k1;
    return e * f_bits((u32)(k1 + 127) << 23) * f_bits((u32)(k2 + 127) << 23);
}

float treadle_gpu_logf(float x)
{
    if (f_isnan(x) || x < 0.0f)
        return F_NAN;
    if (x == 0.0f)
        return -F_INF;
    if (x == F_INF)
        return x;
    int e = 0;
    if (x < f_bits(0x00800000u))
    {
        x *= 8388608.0f; /* 2^23 */
        e = -23;
    }
    u32 w = f_word(x);
    e += (int)((w >> 23) & 0xFF) - 127;
    float m = f_bits((w & 0x007FFFFFu) | 0x3F800000u);
    if (m > 1.41421354f)
    {
        m *= 0.5f;
        e++;
    }
    float f = m - 1.0f;
    float s = f / (2.0f + f);
    float z = s * s;
    float p = __builtin_fmaf(z, 1.0f / 11.0f, 1.0f / 9.0f);
    p = __builtin_fmaf(p, z, 1.0f / 7.0f);
    p = __builtin_fmaf(p, z, 1.0f / 5.0f);
    p = __builtin_fmaf(p, z, 1.0f / 3.0f);
    float t = 2.0f * s;
    float lm = __builtin_fmaf(t * z, p, t);
    float fe = (float)e;
    return __builtin_fmaf(fe, 0.693145752f, __builtin_fmaf(fe, 1.42860677e-06f, lm));
}

/* The rest of the float functions through double: their results are the double ones rounded. */
float treadle_gpu_powf(float x, float y) { return (float)treadle_gpu_pow((double)x, (double)y); }
float treadle_gpu_atanf(float x) { return (float)treadle_gpu_atan((double)x); }
float treadle_gpu_atan2f(float y, float x) { return (float)treadle_gpu_atan2((double)y, (double)x); }
float treadle_gpu_asinf(float x) { return (float)treadle_gpu_asin((double)x); }
float treadle_gpu_acosf(float x) { return (float)treadle_gpu_acos((double)x); }
