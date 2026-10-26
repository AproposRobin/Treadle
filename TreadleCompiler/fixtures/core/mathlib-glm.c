/* mathlib-glm: the C twin of the fixture (hand-written double-precision math with GLM's conventions: column-major,
   right-handed, depth 0 to 1). Each line is a check's name and its reference values; the fixture holds them as
   literals and compares within 1e-5 of the larger of 1 and the value. */
#include <math.h>
#include <stdio.h>

typedef struct { double x, y; } v2;
typedef struct { double x, y, z; } v3;
typedef struct { double x, y, z, w; } v4;
typedef struct { double m[3][3]; } m3; /* m[col][row] */
typedef struct { double m[4][4]; } m4; /* m[col][row] */
typedef struct { double x, y, z, w; } qt;
typedef struct { double r, g, b, a; } col;
typedef struct { int r, g, b, a; } col32;
typedef struct { double x, y, w, h; } rct;
typedef struct { int x, y, w, h; } rcti;
typedef struct { v3 min, max; } box;
typedef struct { v3 n; double d; } pln;
typedef struct { v3 o, d; } ray;
typedef struct { v3 t; qt r; v3 s; } xf;

static double PI = 3.14159265358979323846;
static v2 V2(double x, double y) { v2 r = { x, y }; return r; }
static v3 V3(double x, double y, double z) { v3 r = { x, y, z }; return r; }
static v4 V4(double x, double y, double z, double w) { v4 r = { x, y, z, w }; return r; }
static qt Q(double x, double y, double z, double w) { qt r = { x, y, z, w }; return r; }

/* vectors through arrays */
#define VA(v) ((double *)&(v))
static double vdot(const double *a, const double *b, int n) { double s = 0; for (int i = 0; i < n; i++) s += a[i] * b[i]; return s; }
static v3 add3(v3 a, v3 b) { return V3(a.x + b.x, a.y + b.y, a.z + b.z); }
static v3 sub3(v3 a, v3 b) { return V3(a.x - b.x, a.y - b.y, a.z - b.z); }
static v3 mul3(v3 a, double k) { return V3(a.x * k, a.y * k, a.z * k); }
static double dot3(v3 a, v3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
static double len3(v3 a) { return sqrt(dot3(a, a)); }
static v3 cross3(v3 a, v3 b) { return V3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x); }
static v3 norm3(v3 a) { double l = len3(a); return l > 0 ? mul3(a, 1 / l) : V3(0, 0, 0); }
static double clampd(double x, double lo, double hi) { return x < lo ? lo : (x > hi ? hi : x); }
static double roundd(double x) { return round(x); }

/* N x N helpers on m[col][row] */
static void matmul(const double *a, const double *b, double *r, int n)
{
	for (int c = 0; c < n; c++)
		for (int rr = 0; rr < n; rr++)
		{
			double s = 0;
			for (int k = 0; k < n; k++) s += a[k * n + rr] * b[c * n + k];
			r[c * n + rr] = s;
		}
}
static void matvec(const double *a, const double *v, double *r, int n)
{
	for (int rr = 0; rr < n; rr++) { double s = 0; for (int k = 0; k < n; k++) s += a[k * n + rr] * v[k]; r[rr] = s; }
}
/* Gauss-Jordan with partial pivoting; returns the determinant (0: singular, r all zeros) */
static double matinv(const double *a, double *r, int n)
{
	double w[4][8];
	for (int i = 0; i < n; i++)
		for (int j = 0; j < 2 * n; j++)
			w[i][j] = j < n ? a[j * n + i] : (j - n == i ? 1 : 0); /* row i, col j */
	double det = 1;
	for (int c = 0; c < n; c++)
	{
		int p = c;
		for (int i = c + 1; i < n; i++) if (fabs(w[i][c]) > fabs(w[p][c])) p = i;
		if (w[p][c] == 0) { for (int i = 0; i < n * n; i++) r[i] = 0; return 0; }
		if (p != c) { for (int j = 0; j < 2 * n; j++) { double t = w[p][j]; w[p][j] = w[c][j]; w[c][j] = t; } det = -det; }
		double pv = w[c][c];
		det *= pv;
		for (int j = 0; j < 2 * n; j++) w[c][j] /= pv;
		for (int i = 0; i < n; i++)
			if (i != c) { double f = w[i][c]; for (int j = 0; j < 2 * n; j++) w[i][j] -= f * w[c][j]; }
	}
	for (int i = 0; i < n; i++) for (int j = 0; j < n; j++) r[j * n + i] = w[i][n + j];
	return det;
}
static m4 m4mul(m4 a, m4 b) { m4 r; matmul(&a.m[0][0], &b.m[0][0], &r.m[0][0], 4); return r; }
static m3 m3mul(m3 a, m3 b) { m3 r; matmul(&a.m[0][0], &b.m[0][0], &r.m[0][0], 3); return r; }
static m4 m4inv(m4 a) { m4 r; matinv(&a.m[0][0], &r.m[0][0], 4); return r; }
static m3 m3inv(m3 a) { m3 r; matinv(&a.m[0][0], &r.m[0][0], 3); return r; }
static double m4det(m4 a) { m4 r; return matinv(&a.m[0][0], &r.m[0][0], 4); }
static double m3det(m3 a) { m3 r; return matinv(&a.m[0][0], &r.m[0][0], 3); }
static m4 m4id(void) { m4 r = { 0 }; for (int i = 0; i < 4; i++) r.m[i][i] = 1; return r; }
static m3 m3id(void) { m3 r = { 0 }; for (int i = 0; i < 3; i++) r.m[i][i] = 1; return r; }
/* build from rows (as written on paper) */
static m4 M4R(double a00, double a01, double a02, double a03, double a10, double a11, double a12, double a13,
	double a20, double a21, double a22, double a23, double a30, double a31, double a32, double a33)
{
	double rows[4][4] = { { a00, a01, a02, a03 }, { a10, a11, a12, a13 }, { a20, a21, a22, a23 }, { a30, a31, a32, a33 } };
	m4 r; for (int c = 0; c < 4; c++) for (int rr = 0; rr < 4; rr++) r.m[c][rr] = rows[rr][c];
	return r;
}
static m3 M3R(double a00, double a01, double a02, double a10, double a11, double a12, double a20, double a21, double a22)
{
	double rows[3][3] = { { a00, a01, a02 }, { a10, a11, a12 }, { a20, a21, a22 } };
	m3 r; for (int c = 0; c < 3; c++) for (int rr = 0; rr < 3; rr++) r.m[c][rr] = rows[rr][c];
	return r;
}
static m4 m4T(m4 a) { m4 r; for (int c = 0; c < 4; c++) for (int rr = 0; rr < 4; rr++) r.m[c][rr] = a.m[rr][c]; return r; }
static m3 m3T(m3 a) { m3 r; for (int c = 0; c < 3; c++) for (int rr = 0; rr < 3; rr++) r.m[c][rr] = a.m[rr][c]; return r; }
static v4 m4v(m4 a, v4 v) { v4 r; matvec(&a.m[0][0], VA(v), VA(r), 4); return r; }
static v3 m3v(m3 a, v3 v) { v3 r; matvec(&a.m[0][0], VA(v), VA(r), 3); return r; }
static v3 m4point(m4 a, v3 p) { v4 r = m4v(a, V4(p.x, p.y, p.z, 1)); return V3(r.x, r.y, r.z); }
static v3 m4dir(m4 a, v3 p) { v4 r = m4v(a, V4(p.x, p.y, p.z, 0)); return V3(r.x, r.y, r.z); }
static v3 m4persp(m4 a, v3 p) { v4 r = m4v(a, V4(p.x, p.y, p.z, 1)); return V3(r.x / r.w, r.y / r.w, r.z / r.w); }

static m4 translation(v3 t) { return M4R(1, 0, 0, t.x, 0, 1, 0, t.y, 0, 0, 1, t.z, 0, 0, 0, 1); }
static m4 scale4(v3 s) { return M4R(s.x, 0, 0, 0, 0, s.y, 0, 0, 0, 0, s.z, 0, 0, 0, 0, 1); }
static m4 rotx(double a) { double c = cos(a), s = sin(a); return M4R(1, 0, 0, 0, 0, c, -s, 0, 0, s, c, 0, 0, 0, 0, 1); }
static m4 roty(double a) { double c = cos(a), s = sin(a); return M4R(c, 0, s, 0, 0, 1, 0, 0, -s, 0, c, 0, 0, 0, 0, 1); }
static m4 rotz(double a) { double c = cos(a), s = sin(a); return M4R(c, -s, 0, 0, s, c, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1); }
/* axis-angle rotation matrix (Rodrigues) */
static m3 rotaxis3(v3 u, double a)
{
	u = norm3(u);
	double c = cos(a), s = sin(a), t = 1 - c;
	return M3R(t * u.x * u.x + c, t * u.x * u.y - s * u.z, t * u.x * u.z + s * u.y,
		t * u.x * u.y + s * u.z, t * u.y * u.y + c, t * u.y * u.z - s * u.x,
		t * u.x * u.z - s * u.y, t * u.y * u.z + s * u.x, t * u.z * u.z + c);
}
static m4 m3to4(m3 a) { m4 r = m4id(); for (int c = 0; c < 3; c++) for (int rr = 0; rr < 3; rr++) r.m[c][rr] = a.m[c][rr]; return r; }
static m3 m4to3(m4 a) { m3 r; for (int c = 0; c < 3; c++) for (int rr = 0; rr < 3; rr++) r.m[c][rr] = a.m[c][rr]; return r; }
/* GLM lookAtRH */
static m4 lookat(v3 eye, v3 target, v3 up)
{
	v3 f = norm3(sub3(target, eye)), s = norm3(cross3(f, up)), u = cross3(s, f);
	return M4R(s.x, s.y, s.z, -dot3(s, eye), u.x, u.y, u.z, -dot3(u, eye), -f.x, -f.y, -f.z, dot3(f, eye), 0, 0, 0, 1);
}
/* GLM perspectiveRH_ZO / _NO, orthoRH_ZO / _NO */
static m4 persp(double fovy, double aspect, double n, double f, int gl)
{
	double t = tan(fovy / 2);
	m4 r = { 0 };
	r.m[0][0] = 1 / (aspect * t); r.m[1][1] = 1 / t; r.m[2][3] = -1;
	r.m[2][2] = gl ? -(f + n) / (f - n) : f / (n - f);
	r.m[3][2] = gl ? -(2 * f * n) / (f - n) : -(f * n) / (f - n);
	return r;
}
static m4 ortho(double l, double rr, double b, double t, double n, double f, int gl)
{
	m4 r = m4id();
	r.m[0][0] = 2 / (rr - l); r.m[1][1] = 2 / (t - b); r.m[3][0] = -(rr + l) / (rr - l); r.m[3][1] = -(t + b) / (t - b);
	r.m[2][2] = gl ? -2 / (f - n) : -1 / (f - n);
	r.m[3][2] = gl ? -(f + n) / (f - n) : -n / (f - n);
	return r;
}

/* quaternions */
static qt qaxis(v3 u, double a) { u = norm3(u); double s = sin(a / 2); return Q(u.x * s, u.y * s, u.z * s, cos(a / 2)); }
static qt qmul(qt a, qt b)
{
	/* (a.w + a.v)(b.w + b.v) = a.w b.w - a.v.b.v + a.w b.v + b.w a.v + a.v x b.v */
	v3 av = V3(a.x, a.y, a.z), bv = V3(b.x, b.y, b.z);
	v3 v = add3(add3(mul3(bv, a.w), mul3(av, b.w)), cross3(av, bv));
	return Q(v.x, v.y, v.z, a.w * b.w - dot3(av, bv));
}
static double qdot(qt a, qt b) { return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w; }
static qt qnorm(qt a) { double l = sqrt(qdot(a, a)); return l > 0 ? Q(a.x / l, a.y / l, a.z / l, a.w / l) : Q(0, 0, 0, 1); }
static qt qconj(qt a) { return Q(-a.x, -a.y, -a.z, a.w); }
static qt qinv(qt a) { double d = qdot(a, a); return d > 0 ? Q(-a.x / d, -a.y / d, -a.z / d, a.w / d) : Q(0, 0, 0, 0); }
static m3 qtom3(qt q)
{
	q = qnorm(q);
	double x = q.x, y = q.y, z = q.z, w = q.w;
	return M3R(1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w),
		2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w),
		2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y));
}
static v3 qrot(qt q, v3 v) { return m3v(qtom3(q), v); }
/* Shepperd's method */
static qt m3toq(m3 a)
{
	double m00 = a.m[0][0], m11 = a.m[1][1], m22 = a.m[2][2];
	double r10 = a.m[0][1], r01 = a.m[1][0], r20 = a.m[0][2], r02 = a.m[2][0], r21 = a.m[1][2], r12 = a.m[2][1]; /* rRC: row R col C */
	double tr = m00 + m11 + m22;
	if (tr > 0) { double s = sqrt(tr + 1) * 2; return Q((r21 - r12) / s, (r02 - r20) / s, (r10 - r01) / s, s / 4); }
	if (m00 > m11 && m00 > m22) { double s = sqrt(1 + m00 - m11 - m22) * 2; return Q(s / 4, (r01 + r10) / s, (r02 + r20) / s, (r21 - r12) / s); }
	if (m11 > m22) { double s = sqrt(1 + m11 - m00 - m22) * 2; return Q((r01 + r10) / s, s / 4, (r12 + r21) / s, (r02 - r20) / s); }
	double s = sqrt(1 + m22 - m00 - m11) * 2; return Q((r02 + r20) / s, (r12 + r21) / s, s / 4, (r10 - r01) / s);
}
static qt qslerp(qt a, qt b, double t)
{
	double d = qdot(a, b);
	if (d < 0) { b = Q(-b.x, -b.y, -b.z, -b.w); d = -d; }
	if (d > 0.9999999) return qnorm(Q(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t, a.w + (b.w - a.w) * t));
	double th = acos(d), s = sin(th), k0 = sin((1 - t) * th) / s, k1 = sin(t * th) / s;
	return Q(a.x * k0 + b.x * k1, a.y * k0 + b.y * k1, a.z * k0 + b.z * k1, a.w * k0 + b.w * k1);
}
static qt qnlerp(qt a, qt b, double t)
{
	if (qdot(a, b) < 0) b = Q(-b.x, -b.y, -b.z, -b.w);
	return qnorm(Q(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t, a.w + (b.w - a.w) * t));
}
/* yaw (Y) * pitch (X) * roll (Z) as matrices, then to a quaternion */
static qt qeuler(double pitch, double yaw, double roll)
{
	m3 r = m3mul(m3mul(rotaxis3(V3(0, 1, 0), yaw), rotaxis3(V3(1, 0, 0), pitch)), rotaxis3(V3(0, 0, 1), roll));
	return m3toq(r);
}
static qt qfromto(v3 f, v3 t)
{
	f = norm3(f); t = norm3(t);
	double d = dot3(f, t);
	if (d > 0.999999) return Q(0, 0, 0, 1);
	if (d < -0.999999)
	{
		v3 ax = cross3(V3(1, 0, 0), f);
		if (dot3(ax, ax) <= 1e-6) ax = cross3(V3(0, 1, 0), f);
		return qaxis(ax, PI);
	}
	return qaxis(cross3(f, t), acos(d));
}
static qt qlook(v3 fwd, v3 up)
{
	v3 b = mul3(norm3(fwd), -1); /* the +Z axis of the frame points backwards */
	v3 r = norm3(cross3(up, b));
	v3 u = cross3(b, r);
	m3 m; /* columns r, u, b */
	m.m[0][0] = r.x; m.m[0][1] = r.y; m.m[0][2] = r.z;
	m.m[1][0] = u.x; m.m[1][1] = u.y; m.m[1][2] = u.z;
	m.m[2][0] = b.x; m.m[2][1] = b.y; m.m[2][2] = b.z;
	return m3toq(m);
}
static double qangle(qt a, qt b) { double d = fabs(qdot(qnorm(a), qnorm(b))); return 2 * acos(d > 1 ? 1 : d); }
/* (pitch, yaw, roll) of R = Ry Rx Rz */
static v3 qtoeuler(qt q)
{
	m3 m = qtom3(q); /* m.m[c][r] */
	double r12 = m.m[2][1];
	double pitch = asin(clampd(-r12, -1, 1));
	if (fabs(r12) > 0.99999) return V3(pitch, atan2(-m.m[0][2], m.m[0][0]), 0);
	return V3(pitch, atan2(m.m[2][0], m.m[2][2]), atan2(m.m[0][1], m.m[1][1]));
}
static double qtoaxis(qt q, v3 *axis)
{
	double w = clampd(q.w, -1, 1), s = sqrt(1 - w * w);
	*axis = s < 1e-6 ? V3(1, 0, 0) : V3(q.x / s, q.y / s, q.z / s);
	return 2 * acos(w);
}
static m4 trs(v3 t, qt r, v3 s) { return m4mul(m4mul(translation(t), m3to4(qtom3(r))), scale4(s)); }

/* colours */
static double srgb_dec(double x) { return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4); }
static double srgb_enc(double x) { return x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055; }

/* printing: every leaf with 17 significant digits */
static void P1(double x) { printf(" %.17g", x); }
static void Pf(double x) { P1(x); }
static void Pb(int x) { printf(" %d", x ? 1 : 0); }
static void Pi(long long x) { printf(" %lld", x); }
static void Pv2(v2 v) { P1(v.x); P1(v.y); }
static void Pv3(v3 v) { P1(v.x); P1(v.y); P1(v.z); }
static void Pv4(v4 v) { P1(v.x); P1(v.y); P1(v.z); P1(v.w); }
static void Pq(qt v) { P1(v.x); P1(v.y); P1(v.z); P1(v.w); }
static void Pm3(m3 a) { for (int c = 0; c < 3; c++) for (int r = 0; r < 3; r++) P1(a.m[c][r]); }
static void Pm4(m4 a) { for (int c = 0; c < 4; c++) for (int r = 0; r < 4; r++) P1(a.m[c][r]); }
static void Pc(col c) { P1(c.r); P1(c.g); P1(c.b); P1(c.a); }
static void Pc32(col32 c) { Pi(c.r); Pi(c.g); Pi(c.b); Pi(c.a); }
static void Pr(rct r) { P1(r.x); P1(r.y); P1(r.w); P1(r.h); }
static void Pri(rcti r) { Pi(r.x); Pi(r.y); Pi(r.w); Pi(r.h); }
static void Pbox(box b) { Pv3(b.min); Pv3(b.max); }
static void Ppl(pln p) { Pv3(p.n); P1(p.d); }
static void Pray(ray r) { Pv3(r.o); Pv3(r.d); }
static void Pxf(xf x) { Pv3(x.t); Pq(x.r); Pv3(x.s); }

int main(void)
{
	printf("%s", "glm.model"); Pm4(trs(V3(2, -1, 3), qeuler(0.3, -0.7, 0.2), V3(1.5, 1.5, 1.5))); printf("\n");
	printf("%s", "glm.view"); Pm4(lookat(V3(4, 3, 6), V3(0, 0.5, 0), V3(0, 1, 0))); printf("\n");
	printf("%s", "glm.proj"); Pm4(persp(PI / 3, 16.0 / 9.0, 0.1, 50, 0)); printf("\n");
	printf("%s", "glm.mvp"); Pm4(m4mul(m4mul(persp(PI / 3, 16.0 / 9.0, 0.1, 50, 0), lookat(V3(4, 3, 6), V3(0, 0.5, 0), V3(0, 1, 0))), trs(V3(2, -1, 3), qeuler(0.3, -0.7, 0.2), V3(1.5, 1.5, 1.5)))); printf("\n");
	printf("%s", "glm.clip.0"); Pv4(m4v(m4mul(m4mul(persp(PI / 3, 16.0 / 9.0, 0.1, 50, 0), lookat(V3(4, 3, 6), V3(0, 0.5, 0), V3(0, 1, 0))), trs(V3(2, -1, 3), qeuler(0.3, -0.7, 0.2), V3(1.5, 1.5, 1.5))), V4(0, 0, 0, 1))); printf("\n");
	printf("%s", "glm.ndc.0"); Pv3(m4persp(m4mul(m4mul(persp(PI / 3, 16.0 / 9.0, 0.1, 50, 0), lookat(V3(4, 3, 6), V3(0, 0.5, 0), V3(0, 1, 0))), trs(V3(2, -1, 3), qeuler(0.3, -0.7, 0.2), V3(1.5, 1.5, 1.5))), V3(0, 0, 0))); printf("\n");
	printf("%s", "glm.world.0"); Pv3(m4point(trs(V3(2, -1, 3), qeuler(0.3, -0.7, 0.2), V3(1.5, 1.5, 1.5)), V3(0, 0, 0))); printf("\n");
	printf("%s", "glm.clip.1"); Pv4(m4v(m4mul(m4mul(persp(PI / 3, 16.0 / 9.0, 0.1, 50, 0), lookat(V3(4, 3, 6), V3(0, 0.5, 0), V3(0, 1, 0))), trs(V3(2, -1, 3), qeuler(0.3, -0.7, 0.2), V3(1.5, 1.5, 1.5))), V4(1, 1, 1, 1))); printf("\n");
	printf("%s", "glm.ndc.1"); Pv3(m4persp(m4mul(m4mul(persp(PI / 3, 16.0 / 9.0, 0.1, 50, 0), lookat(V3(4, 3, 6), V3(0, 0.5, 0), V3(0, 1, 0))), trs(V3(2, -1, 3), qeuler(0.3, -0.7, 0.2), V3(1.5, 1.5, 1.5))), V3(1, 1, 1))); printf("\n");
	printf("%s", "glm.world.1"); Pv3(m4point(trs(V3(2, -1, 3), qeuler(0.3, -0.7, 0.2), V3(1.5, 1.5, 1.5)), V3(1, 1, 1))); printf("\n");
	printf("%s", "glm.clip.2"); Pv4(m4v(m4mul(m4mul(persp(PI / 3, 16.0 / 9.0, 0.1, 50, 0), lookat(V3(4, 3, 6), V3(0, 0.5, 0), V3(0, 1, 0))), trs(V3(2, -1, 3), qeuler(0.3, -0.7, 0.2), V3(1.5, 1.5, 1.5))), V4(-1, 0.5, 2, 1))); printf("\n");
	printf("%s", "glm.ndc.2"); Pv3(m4persp(m4mul(m4mul(persp(PI / 3, 16.0 / 9.0, 0.1, 50, 0), lookat(V3(4, 3, 6), V3(0, 0.5, 0), V3(0, 1, 0))), trs(V3(2, -1, 3), qeuler(0.3, -0.7, 0.2), V3(1.5, 1.5, 1.5))), V3(-1, 0.5, 2))); printf("\n");
	printf("%s", "glm.world.2"); Pv3(m4point(trs(V3(2, -1, 3), qeuler(0.3, -0.7, 0.2), V3(1.5, 1.5, 1.5)), V3(-1, 0.5, 2))); printf("\n");
	printf("%s", "glm.clip.3"); Pv4(m4v(m4mul(m4mul(persp(PI / 3, 16.0 / 9.0, 0.1, 50, 0), lookat(V3(4, 3, 6), V3(0, 0.5, 0), V3(0, 1, 0))), trs(V3(2, -1, 3), qeuler(0.3, -0.7, 0.2), V3(1.5, 1.5, 1.5))), V4(0.25, -2, -1, 1))); printf("\n");
	printf("%s", "glm.ndc.3"); Pv3(m4persp(m4mul(m4mul(persp(PI / 3, 16.0 / 9.0, 0.1, 50, 0), lookat(V3(4, 3, 6), V3(0, 0.5, 0), V3(0, 1, 0))), trs(V3(2, -1, 3), qeuler(0.3, -0.7, 0.2), V3(1.5, 1.5, 1.5))), V3(0.25, -2, -1))); printf("\n");
	printf("%s", "glm.world.3"); Pv3(m4point(trs(V3(2, -1, 3), qeuler(0.3, -0.7, 0.2), V3(1.5, 1.5, 1.5)), V3(0.25, -2, -1))); printf("\n");
	printf("%s", "glm.mvp.inverse"); Pm4(m4id()); printf("\n");
	printf("%s", "glm.view.inverse.affine"); Pm4(m4inv(lookat(V3(4, 3, 6), V3(0, 0.5, 0), V3(0, 1, 0)))); printf("\n");
	printf("%s", "glm.normal.matrix"); Pm3(m3T(m3inv(m4to3(trs(V3(2, -1, 3), qeuler(0.3, -0.7, 0.2), V3(1.5, 1.5, 1.5)))))); printf("\n");
	printf("%s", "glm.transform.chain"); Pm4(m4mul(trs(V3(1, 2, 3), qaxis(V3(0, 1, 0), 0.5), V3(2, 2, 2)), trs(V3(-0.5, 1, 0), qaxis(V3(1, 0, 0), -0.25), V3(0.5, 0.5, 0.5)))); printf("\n");
	printf("%s", "glm.transform.point"); Pv3(m4point(m4mul(trs(V3(1, 2, 3), qaxis(V3(0, 1, 0), 0.5), V3(2, 2, 2)), trs(V3(-0.5, 1, 0), qaxis(V3(1, 0, 0), -0.25), V3(0.5, 0.5, 0.5))), V3(1, -1, 0.5))); printf("\n");
	printf("%s", "glm.slerp.rotate"); Pv3(qrot(qslerp(qeuler(0.3, -0.7, 0.2), qeuler(-0.4, 1.1, 0), 0.5), V3(0, 0, -1))); printf("\n");
	printf("%s", "glm.ortho.gl"); Pv3(m4point(m4mul(ortho(-4, 4, -3, 3, 0.5, 20, 1), lookat(V3(4, 3, 6), V3(0, 0.5, 0), V3(0, 1, 0))), V3(1, 1, 1))); printf("\n");
	printf("%s", "glm.aabb.view"); Pbox(({ m4 m_ = lookat(V3(4, 3, 6), V3(0, 0.5, 0), V3(0, 1, 0)); box b_ = {{1e30, 1e30, 1e30}, {-1e30, -1e30, -1e30}}; for (int k = 0; k < 8; k++) { v3 c_ = m4point(m_, V3(k & 1 ? 1 : -1, k & 2 ? 1 : -1, k & 4 ? 1 : -1)); b_.min = V3(fmin(b_.min.x, c_.x), fmin(b_.min.y, c_.y), fmin(b_.min.z, c_.z)); b_.max = V3(fmax(b_.max.x, c_.x), fmax(b_.max.y, c_.y), fmax(b_.max.z, c_.z)); } b_; })); printf("\n");
	return 0;
}
