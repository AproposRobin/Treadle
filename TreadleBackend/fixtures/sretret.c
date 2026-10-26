/* The C side of the sretret fixture: a 24-byte struct returned to Treadle (through the hidden result
   pointer of the C ABI), and calls of Treadle's exported kx_big / kx_vscale, which return 24-byte
   structs to C. */
typedef struct { long long a, b, c; } Big3;
typedef struct { double x, y, z; } V3;

Big3 kx_big(long long n);
V3 kx_vscale(V3 v, double k);

Big3 c_make_big(long long n)
{
    Big3 r = { n, n * 2, n * 3 };
    return r;
}

/* kx_big(5) = 5, 10, 15 and kx_vscale((1, 1, 1), 4) = 4, 4, 4: 30 + 12 = 42 */
long long c_check(void)
{
    Big3 b = kx_big(5);
    V3 one = { 1.0, 1.0, 1.0 };
    V3 v = kx_vscale(one, 4.0);
    return b.a + b.b + b.c + (long long)(v.x + v.y + v.z);
}
