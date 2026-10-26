'use strict';
// The math fixtures: each check is a Treadle expression and its C reference (double precision).
const { X, lit, f, d, i, v2, v3, v4, q, CTYPE } = require('./dsl');

// a call: Core.<name>; recv may be null (static); args {param: X}; c the C reference text
function call(name, ret, recv, args, c) {
  return new X(ret, g => {
    const ins = {};
    if (recv) ins.receiver = recv.pin(g);
    for (const k of Object.keys(args || {})) ins[k] = args[k].pin(g);
    return g.call('Core.' + name, ins);
  }, c);
}
// the out pin `pin` of a call
function outOf(name, ret, recv, args, pin, c) {
  return new X(ret, g => {
    const ins = {};
    if (recv) ins.receiver = recv.pin(g);
    for (const k of Object.keys(args || {})) ins[k] = args[k].pin(g);
    return g.call('Core.' + name, ins).out(pin);
  }, c);
}
const get = (name, type, c) => new X(type, g => g.get('Core.' + name), c);
const op = (sym, type, a, b, c) => new X(type, g => g.op(sym, a.pin(g), b ? b.pin(g) : undefined), c);
const raw = (type, c) => new X(type, null, c); // C only

// componentwise C over arrays: body uses A[i], B[i], C[i]
function ew(type, n, ins, body) {
  const ct = CTYPE[type];
  const names = ['A', 'B', 'C'];
  let decl = '';
  ins.forEach((x, k) => { decl += `${x.type in CTYPE && !['float', 'double'].includes(x.type) ? CTYPE[x.type] : 'double'} ${names[k]}_ = ${x.c}; `; });
  const b = body.replace(/\b([ABC])\[i\]/g, (m, a) => `VA(${a}_)[i_]`).replace(/\b([ABC])s\b/g, (m, a) => `${a}_`);
  return `({ ${decl}${ct} r_; for (int i_ = 0; i_ < ${n}; i_++) VA(r_)[i_] = ${b}; r_; })`;
}
function red(n, ins, body) {
  const names = ['A', 'B'];
  let decl = '';
  ins.forEach((x, k) => { decl += `${CTYPE[x.type]} ${names[k]}_ = ${x.c}; `; });
  const b = body.replace(/\b([AB])\[i\]/g, (m, a) => `VA(${a}_)[i_]`);
  return `({ ${decl}double s_ = 0; for (int i_ = 0; i_ < ${n}; i_++) s_ += ${b}; s_; })`;
}

const F = {}; // fixture name -> [{label, x, eps}]
function fx(name) { F[name] = F[name] || []; return (label, x, eps) => F[name].push({ label, x, eps }); }

// ---------------- vectors
function vectorChecks(N, fixture) {
  const dbl = N.endsWith('d');
  const n = Number(N[3]);
  const S = dbl ? 'double' : 'float';
  const s = dbl ? d : f;
  const C = ['X', 'Y', 'Z', 'W'].slice(0, n);
  const V = (...xs) => lit(N, ...xs.slice(0, n));
  const chk = fx(fixture);
  const L = N.toLowerCase() + '.';
  const a = V(1.5, -2, 3, 0.5), b = V(4, 0.25, -6, 2), z = V(0, 0, 0, 0);
  const vn = V(0, 1, 0, 0); // a unit normal
  const ct = CTYPE[N];
  const cl = (...xs) => `((${ct}){${xs.slice(0, n).join(', ')}})`;
  chk(L + 'Zero', get(N + '.Zero', N, cl(0, 0, 0, 0)));
  chk(L + 'One', get(N + '.One', N, cl(1, 1, 1, 1)));
  for (const u of C) chk(L + 'Unit' + u, get(N + '.Unit' + u, N, cl(...C.map(c => (c === u ? 1 : 0)))));
  chk(L + 'add', op('+', N, a, b, ew(N, n, [a, b], 'A[i] + B[i]')));
  chk(L + 'sub', op('-', N, a, b, ew(N, n, [a, b], 'A[i] - B[i]')));
  chk(L + 'mul', op('*', N, a, b, ew(N, n, [a, b], 'A[i] * B[i]')));
  chk(L + 'div', op('/', N, a, b, ew(N, n, [a, b], 'A[i] / B[i]')));
  chk(L + 'neg', op('neg', N, a, null, ew(N, n, [a], '-A[i]')));
  chk(L + 'eq', op('==', 'bool', a, V(1.5, -2, 3, 0.5), '1'));
  chk(L + 'eq.false', op('==', 'bool', a, b, '0'));
  chk(L + 'ne', op('!=', 'bool', a, b, '1'));
  chk(L + 'ne.false', op('!=', 'bool', a, a, '0'));
  chk(L + 'Scaled', call(N + '.Scaled', N, a, { k: s(2.5) }, ew(N, n, [a], 'A[i] * 2.5')));
  chk(L + 'mul.scalar', op('*', N, a, s(2.5), ew(N, n, [a], 'A[i] * 2.5')));
  chk(L + 'mul.scalar.left', op('*', N, s(-3), a, ew(N, n, [a], '-3 * A[i]')));
  chk(L + 'div.scalar', op('/', N, a, s(4), ew(N, n, [a], 'A[i] / 4')));
  chk(L + 'mul.scalar.wired', new X(N, g => g.op('*', g.call(`Core.${N}.Length`, { receiver: b.pin(g) }), a.pin(g)), ew(N, n, [a, b], `A[i] * sqrt(${red(n, [b], 'A[i] * A[i]')})`)));
  chk(L + 'math', new X(N, g => g.math(`v * ${dbl ? '2.0' : '2.0f'} - w / 4 + v * w`, { v: a.pin(g), w: b.pin(g) }), ew(N, n, [a, b], 'A[i] * 2 - B[i] / 4 + A[i] * B[i]')));
  chk(L + 'Dot', call(N + '.Dot', S, a, { b }, red(n, [a, b], 'A[i] * B[i]')));
  chk(L + 'LengthSquared', call(N + '.LengthSquared', S, a, {}, red(n, [a], 'A[i] * A[i]')));
  chk(L + 'Length', call(N + '.Length', S, a, {}, `sqrt(${red(n, [a], 'A[i] * A[i]')})`));
  chk(L + 'DistanceSquared', call(N + '.DistanceSquared', S, a, { b }, red(n, [a, b], '(A[i] - B[i]) * (A[i] - B[i])')));
  chk(L + 'Distance', call(N + '.Distance', S, a, { b }, `sqrt(${red(n, [a, b], '(A[i] - B[i]) * (A[i] - B[i])')})`));
  chk(L + 'Normalized', call(N + '.Normalized', N, b, {}, ew(N, n, [b], `B[i] / sqrt(${red(n, [b], 'A[i] * A[i]')})`.replace(/B\[i\]/, 'A[i]'))));
  chk(L + 'Normalized.zero', call(N + '.Normalized', N, z, {}, cl(0, 0, 0, 0)));
  chk(L + 'Lerp', call(N + '.Lerp', N, a, { to: b, t: s(0.25) }, ew(N, n, [a, b], 'A[i] + (B[i] - A[i]) * 0.25')));
  chk(L + 'Min', call(N + '.Min', N, a, { b }, ew(N, n, [a, b], 'fmin(A[i], B[i])')));
  chk(L + 'Max', call(N + '.Max', N, a, { b }, ew(N, n, [a, b], 'fmax(A[i], B[i])')));
  const lo = V(-1, -1, -1, -1), hi = V(1, 1, 1, 1);
  chk(L + 'Clamp', call(N + '.Clamp', N, a, { lo, hi }, ew(N, n, [a], 'clampd(A[i], -1, 1)')));
  const r = V(2.5, -2.5, 0.4, -1.6);
  chk(L + 'Abs', call(N + '.Abs', N, r, {}, ew(N, n, [r], 'fabs(A[i])')));
  chk(L + 'Floor', call(N + '.Floor', N, r, {}, ew(N, n, [r], 'floor(A[i])')));
  chk(L + 'Ceil', call(N + '.Ceil', N, r, {}, ew(N, n, [r], 'ceil(A[i])')));
  chk(L + 'Round', call(N + '.Round', N, r, {}, ew(N, n, [r], 'round(A[i])')));
  chk(L + 'Reflect', call(N + '.Reflect', N, a, { normal: vn }, ew(N, n, [a, vn], `A[i] - 2 * ${red(n, [a, vn], 'A[i] * B[i]')} * B[i]`)));
  chk(L + 'ProjectOnto', call(N + '.ProjectOnto', N, a, { b }, ew(N, n, [a, b], `B[i] * (${red(n, [a, b], 'A[i] * B[i]')} / ${red(n, [b], 'A[i] * A[i]')})`)));
  chk(L + 'ProjectOnto.zero', call(N + '.ProjectOnto', N, a, { b: z }, cl(0, 0, 0, 0)));
  chk(L + 'AngleTo', call(N + '.AngleTo', S, a, { b }, `acos(${red(n, [a, b], 'A[i] * B[i]')} / sqrt(${red(n, [a], 'A[i] * A[i]')} * ${red(n, [b], 'A[i] * A[i]')}))`));
  chk(L + 'AngleTo.zero', call(N + '.AngleTo', S, a, { b: z }, '0'));
  chk(L + 'IsFinite', call(N + '.IsFinite', 'bool', a, {}, '1'));
  chk(L + 'IsFinite.inf', new X('bool', g => g.call(`Core.${N}.IsFinite`, { receiver: g.op('/', a.pin(g), z.pin(g)) }), '0'));
  chk(L + 'ApproxEquals', call(N + '.ApproxEquals', 'bool', a, { other: V(1.500001, -2.000001, 3.000001, 0.500001) }, '1'));
  chk(L + 'ApproxEquals.false', call(N + '.ApproxEquals', 'bool', a, { other: V(1.5001, -2, 3, 0.5) }, '0'));
  chk(L + 'ApproxEquals.eps', call(N + '.ApproxEquals', 'bool', a, { other: V(1.5001, -2, 3, 0.5), epsilon: s(0.001) }, '1'));
  chk(L + 'ToVector.round', new X('bool', g => g.op('==', g.call(`Core.${N}.FromVector`, { value: g.call(`Core.${N}.ToVector`, { receiver: a.pin(g) }) }), a.pin(g)), '1'));
  chk(L + 'ToVector.lanes', new X(S, g => g.math(C.map((c, k) => `p.${'xyzw'[k]} * ${k + 1}.0${dbl ? '' : 'f'}`).join(' + '), { p: g.call(`Core.${N}.ToVector`, { receiver: a.pin(g) }) }), [1.5, -2, 3, 0.5].slice(0, n).map((x, k) => `${x} * ${k + 1}`).join(' + ')));
  if (n === 2) {
    chk(L + 'Perpendicular', call(N + '.Perpendicular', N, a, {}, cl(2, 1.5)));
    chk(L + 'Cross', call(N + '.Cross', S, a, { b }, '(1.5 * 0.25 - (-2) * 4)'));
    chk(L + 'Angle', call(N + '.Angle', S, a, {}, 'atan2(-2, 1.5)'));
    chk(L + 'FromAngle', call(N + '.FromAngle', N, null, { angle: s(2.0) }, cl('cos(2.0)', 'sin(2.0)')));
  }
  if (n === 3) {
    chk(L + 'Cross', call(N + '.Cross', N, a, { b }, `cross3(${a.c}, ${b.c})`));
    chk(L + 'XY', call(N + '.XY', dbl ? 'Vec2d' : 'Vec2', a, {}, '((v2){1.5, -2})'));
  }
  if (n === 4) {
    chk(L + 'XYZ', call(N + '.XYZ', dbl ? 'Vec3d' : 'Vec3', a, {}, '((v3){1.5, -2, 3})'));
    chk(L + 'FromVec3', call(N + '.FromVec3', N, null, { v: lit(dbl ? 'Vec3d' : 'Vec3', 7, 8, 9), w: s(-1) }, cl(7, 8, 9, -1)));
  }
}
vectorChecks('Vec2', 'math-vec2');
vectorChecks('Vec3', 'math-vec3');
vectorChecks('Vec4', 'math-vec4');
for (const N of ['Vec2d', 'Vec3d', 'Vec4d']) vectorChecks(N, 'math-vecd');
// the splat constructor (a Local of the struct)
fx('math-vec3')('vec3.this(all)', new X('Vec3', g => g.flow('Local', 'Core.Vec3', { all: '2.5f' }, ['set ctor (float)']) + '.object', '((v3){2.5, 2.5, 2.5})'));

// ---------------- scalar Math additions
{
  const chk = fx('math-scalar');
  for (const [S, s] of [['float', f], ['double', d]]) {
    const L = 'math.' + S + '.';
    const M = (name, args, c) => call('Math.' + name, S, null, args, c);
    chk(L + 'Tan', M('Tan', { x: s(0.7) }, 'tan(0.7)'));
    chk(L + 'Asin', M('Asin', { x: s(0.4) }, 'asin(0.4)'));
    chk(L + 'Acos', M('Acos', { x: s(-0.3) }, 'acos(-0.3)'));
    chk(L + 'Atan', M('Atan', { x: s(2.5) }, 'atan(2.5)'));
    chk(L + 'Atan2', M('Atan2', { y: s(-1), x: s(-2) }, 'atan2(-1, -2)'));
    chk(L + 'Fma', M('Fma', { a: s(1.5), b: s(2), c: s(-0.25) }, '(1.5 * 2 - 0.25)'));
    chk(L + 'CopySign', M('CopySign', { x: s(3), sign: s(-0.5) }, '-3'));
    chk(L + 'Radians', M('Radians', { degrees: s(90) }, 'PI / 2'));
    chk(L + 'Degrees', M('Degrees', { radians: s(1) }, '180 / PI'));
    chk(L + 'SmoothStep', M('SmoothStep', { e0: s(1), e1: s(3), x: s(1.5) }, '(0.25 * 0.25 * (3 - 2 * 0.25))'));
    chk(L + 'SmoothStep.below', M('SmoothStep', { e0: s(1), e1: s(3), x: s(0) }, '0'));
    chk(L + 'SmoothStep.above', M('SmoothStep', { e0: s(1), e1: s(3), x: s(9) }, '1'));
  }
  chk('math.Tau', get('Math.Tau', 'double', '2 * PI'));
}

// ---------------- matrices
const rows4 = [[2, 0, 1, 3], [1, 3, 2, 1], [0, 1, 4, 2], [3, 1, 0, 5]];
const rowsB = [[1, 2, 0, -1], [0, 1, 3, 2], [4, 0, 1, 1], [-2, 1, 0, 2]];
const colMajor = rows => rows[0].map((_, c) => rows.map(r => r[c])).flat();
const m4 = rows => lit('Mat4', ...colMajor(rows));
const m3 = rows => lit('Mat3', ...colMajor(rows));
const M4R = rows => `M4R(${rows.flat().join(', ')})`;
const M3R = rows => `M3R(${rows.flat().join(', ')})`;
{
  const chk = fx('math-mat4');
  const A = m4(rows4), B = m4(rowsB);
  const Ac = M4R(rows4), Bc = M4R(rowsB);
  chk('mat4.Identity', get('Mat4.Identity', 'Mat4', 'm4id()'));
  chk('mat4.Zero', get('Mat4.Zero', 'Mat4', '((m4){0})'));
  chk('mat4.Get', call('Mat4.Get', 'float', A, { row: i(1), col: i(2) }, '2'));
  chk('mat4.Get.corner', call('Mat4.Get', 'float', A, { row: i(3), col: i(0) }, '3'));
  chk('mat4.Column', call('Mat4.Column', 'Vec4', A, { index: i(3) }, '((v4){3, 1, 2, 5})'));
  chk('mat4.Row', call('Mat4.Row', 'Vec4', A, { index: i(1) }, '((v4){1, 3, 2, 1})'));
  chk('mat4.mul', op('*', 'Mat4', A, B, `m4mul(${Ac}, ${Bc})`));
  chk('mat4.Multiply', call('Mat4.Multiply', 'Mat4', A, { b: B }, `m4mul(${Ac}, ${Bc})`));
  chk('mat4.add', op('+', 'Mat4', A, B, `({ m4 a_ = ${Ac}, b_ = ${Bc}; for (int k = 0; k < 16; k++) (&a_.m[0][0])[k] += (&b_.m[0][0])[k]; a_; })`));
  chk('mat4.sub', op('-', 'Mat4', A, B, `({ m4 a_ = ${Ac}, b_ = ${Bc}; for (int k = 0; k < 16; k++) (&a_.m[0][0])[k] -= (&b_.m[0][0])[k]; a_; })`));
  chk('mat4.eq', op('==', 'bool', A, m4(rows4), '1'));
  chk('mat4.eq.false', op('==', 'bool', A, B, '0'));
  chk('mat4.mul.vec4', op('*', 'Vec4', A, v4(1, -2, 0.5, 3), `m4v(${Ac}, V4(1, -2, 0.5, 3))`));
  chk('mat4.mul.scalar', op('*', 'Mat4', A, f(-0.5), `({ m4 a_ = ${Ac}; for (int k = 0; k < 16; k++) (&a_.m[0][0])[k] *= -0.5; a_; })`));
  chk('mat4.Transform', call('Mat4.Transform', 'Vec4', A, { v: v4(1, -2, 0.5, 3) }, `m4v(${Ac}, V4(1, -2, 0.5, 3))`));
  chk('mat4.Scaled', call('Mat4.Scaled', 'Mat4', A, { k: f(-0.5) }, `({ m4 a_ = ${Ac}; for (int k = 0; k < 16; k++) (&a_.m[0][0])[k] *= -0.5; a_; })`));
  chk('mat4.Transposed', call('Mat4.Transposed', 'Mat4', A, {}, `m4T(${Ac})`));
  chk('mat4.Determinant', call('Mat4.Determinant', 'float', A, {}, `m4det(${Ac})`));
  chk('mat4.Inverted', call('Mat4.Inverted', 'Mat4', A, {}, `m4inv(${Ac})`));
  chk('mat4.Inverted.times', new X('Mat4', g => g.op('*', g.call('Core.Mat4.Inverted', { receiver: A.pin(g) }), A.pin(g)), 'm4id()'));
  const sing = m4([[1, 2, 3, 4], [2, 4, 6, 8], [0, 1, 0, 1], [1, 0, 1, 0]]);
  chk('mat4.Inverted.singular', call('Mat4.Inverted', 'Mat4', sing, {}, '((m4){0})'));
  chk('mat4.Determinant.singular', call('Mat4.Determinant', 'float', sing, {}, '0'));
  chk('mat4.TryInvert', call('Mat4.TryInvert', 'bool', B, {}, '1'));
  chk('mat4.TryInvert.inverse', outOf('Mat4.TryInvert', 'Mat4', B, {}, 'inverse', `m4inv(${Bc})`));
  chk('mat4.TryInvert.singular', call('Mat4.TryInvert', 'bool', sing, {}, '0'));
  const trsC = 'trs(V3(1, -2, 3), qaxis(V3(1, 2, 2), 0.8), V3(2, 2, 2))';
  const trsT = call('Mat4.FromTRS', 'Mat4', null, { translation: v3(1, -2, 3), rotation: call('Quat.FromAxisAngle', 'Quat', null, { axis: v3(1 / 3, 2 / 3, 2 / 3), angle: f(0.8) }, ''), scale: v3(2, 2, 2) }, trsC);
  chk('mat4.FromTRS', trsT);
  chk('mat4.InvertedAffine', call('Mat4.InvertedAffine', 'Mat4', trsT, {}, `m4inv(${trsC})`));
  chk('mat4.ApproxEquals', call('Mat4.ApproxEquals', 'bool', A, { other: m4(rows4.map(r => r.map(x => x + 0.000001))) }, '1'));
  chk('mat4.ApproxEquals.false', call('Mat4.ApproxEquals', 'bool', A, { other: B }, '0'));
  chk('mat4.Translation', call('Mat4.Translation', 'Mat4', null, { offset: v3(1, 2, 3) }, 'translation(V3(1, 2, 3))'));
  chk('mat4.Scale', call('Mat4.Scale', 'Mat4', null, { scale: v3(2, 3, 4) }, 'scale4(V3(2, 3, 4))'));
  chk('mat4.RotationX', call('Mat4.RotationX', 'Mat4', null, { angle: f(0.6) }, 'rotx(0.6)'));
  chk('mat4.RotationY', call('Mat4.RotationY', 'Mat4', null, { angle: f(0.6) }, 'roty(0.6)'));
  chk('mat4.RotationZ', call('Mat4.RotationZ', 'Mat4', null, { angle: f(0.6) }, 'rotz(0.6)'));
  chk('mat4.RotationY.axis', call('Mat4.RotationY', 'Mat4', null, { angle: f(0.6) }, 'm3to4(rotaxis3(V3(0, 1, 0), 0.6))'));
  chk('mat4.Rotation', call('Mat4.Rotation', 'Mat4', null, { rotation: call('Quat.FromAxisAngle', 'Quat', null, { axis: v3(0, 0.6, 0.8), angle: f(1.1) }, '') }, 'm3to4(rotaxis3(V3(0, 0.6, 0.8), 1.1))'));
  chk('mat4.LookAt', call('Mat4.LookAt', 'Mat4', null, { eye: v3(3, 4, 5), target: v3(0, 1, 0), up: v3(0, 1, 0) }, 'lookat(V3(3, 4, 5), V3(0, 1, 0), V3(0, 1, 0))'));
  chk('mat4.LookAt.eye', new X('Vec3', g => g.call('Core.Mat4.TransformPoint', { receiver: g.call('Core.Mat4.LookAt', { eye: v3(3, 4, 5).pin(g), target: v3(0, 1, 0).pin(g), up: v3(0, 1, 0).pin(g) }), point: v3(3, 4, 5).pin(g) }), 'V3(0, 0, 0)'));
  chk('mat4.LookAt.target', new X('Vec3', g => g.call('Core.Mat4.TransformPoint', { receiver: g.call('Core.Mat4.LookAt', { eye: v3(3, 4, 5).pin(g), target: v3(0, 1, 0).pin(g), up: v3(0, 1, 0).pin(g) }), point: v3(0, 1, 0).pin(g) }), 'V3(0, 0, -sqrt(9 + 9 + 25))'));
  chk('mat4.Perspective', call('Mat4.Perspective', 'Mat4', null, { fovY: f(1.0), aspect: f(1.5), near: f(0.1), far: f(100) }, 'persp(1.0, 1.5, 0.1, 100, 0)'), 1e-4);
  chk('mat4.PerspectiveGL', call('Mat4.PerspectiveGL', 'Mat4', null, { fovY: f(1.0), aspect: f(1.5), near: f(0.1), far: f(100) }, 'persp(1.0, 1.5, 0.1, 100, 1)'), 1e-4);
  chk('mat4.Perspective.near', new X('Vec3', g => g.call('Core.Mat4.TransformPerspective', { receiver: g.call('Core.Mat4.Perspective', { fovY: '1.0f', aspect: '1.5f', near: '0.1f', far: '100.0f' }), point: v3(0, 0, -0.1).pin(g) }), 'V3(0, 0, 0)'), 1e-4);
  chk('mat4.Perspective.far', new X('Vec3', g => g.call('Core.Mat4.TransformPerspective', { receiver: g.call('Core.Mat4.Perspective', { fovY: '1.0f', aspect: '1.5f', near: '0.1f', far: '100.0f' }), point: v3(0, 0, -100).pin(g) }), 'V3(0, 0, 1)'), 1e-4);
  chk('mat4.PerspectiveGL.near', new X('Vec3', g => g.call('Core.Mat4.TransformPerspective', { receiver: g.call('Core.Mat4.PerspectiveGL', { fovY: '1.0f', aspect: '1.5f', near: '0.1f', far: '100.0f' }), point: v3(0, 0, -0.1).pin(g) }), 'V3(0, 0, -1)'), 1e-4);
  chk('mat4.Orthographic', call('Mat4.Orthographic', 'Mat4', null, { left: f(-2), right: f(6), bottom: f(-1), top: f(3), near: f(0.5), far: f(10) }, 'ortho(-2, 6, -1, 3, 0.5, 10, 0)'));
  chk('mat4.OrthographicGL', call('Mat4.OrthographicGL', 'Mat4', null, { left: f(-2), right: f(6), bottom: f(-1), top: f(3), near: f(0.5), far: f(10) }, 'ortho(-2, 6, -1, 3, 0.5, 10, 1)'));
  chk('mat4.TransformPoint', call('Mat4.TransformPoint', 'Vec3', A, { point: v3(1, 2, -1) }, `m4point(${Ac}, V3(1, 2, -1))`));
  chk('mat4.TransformVector', call('Mat4.TransformVector', 'Vec3', A, { vector: v3(1, 2, -1) }, `m4dir(${Ac}, V3(1, 2, -1))`));
  chk('mat4.TransformPerspective', call('Mat4.TransformPerspective', 'Vec3', A, { point: v3(1, 2, -1) }, `m4persp(${Ac}, V3(1, 2, -1))`));
  chk('mat4.Upper3x3', call('Mat4.Upper3x3', 'Mat3', A, {}, `m4to3(${Ac})`));
  // ToStd430 into a float[16]: the sum of i * element i
  chk('mat4.ToStd430', new X('float', g => {
    const arr = g.flow('Local', 'float', { count: '16' }, ['set count']);
    g.flow('Call', 'Core.Mat4.ToStd430', { receiver: A.pin(g), into: arr + '.object' });
    let acc = null;
    for (let k = 0; k < 16; k++) {
      const ix = g.node('Index'); g.feed(ix, 'collection', arr + '.object'); g.feed(ix, 'index', String(k));
      acc = acc ? g.math(`s + e * ${k}.0f`, { s: acc, e: ix + '.value' }) : g.math('e * 0.0f', { e: ix + '.value' });
    }
    return acc;
  }, `({ m4 a_ = ${Ac}; double s = 0; for (int k = 0; k < 16; k++) s += (&a_.m[0][0])[k] * k; s; })`));
}
{
  const chk = fx('math-mat3');
  const r3 = [[2, -1, 0.5], [1, 3, 2], [0, 1, 4]], s3 = [[1, 0, 2], [-1, 2, 1], [3, 1, 0]];
  const A = m3(r3), B = m3(s3), Ac = M3R(r3), Bc = M3R(s3);
  chk('mat3.Identity', get('Mat3.Identity', 'Mat3', 'm3id()'));
  chk('mat3.Zero', get('Mat3.Zero', 'Mat3', '((m3){0})'));
  chk('mat3.Get', call('Mat3.Get', 'float', A, { row: i(0), col: i(1) }, '-1'));
  chk('mat3.Column', call('Mat3.Column', 'Vec3', A, { index: i(2) }, '((v3){0.5, 2, 4})'));
  chk('mat3.Row', call('Mat3.Row', 'Vec3', A, { index: i(2) }, '((v3){0, 1, 4})'));
  chk('mat3.mul', op('*', 'Mat3', A, B, `m3mul(${Ac}, ${Bc})`));
  chk('mat3.add', op('+', 'Mat3', A, B, `({ m3 a_ = ${Ac}, b_ = ${Bc}; for (int k = 0; k < 9; k++) (&a_.m[0][0])[k] += (&b_.m[0][0])[k]; a_; })`));
  chk('mat3.sub', op('-', 'Mat3', A, B, `({ m3 a_ = ${Ac}, b_ = ${Bc}; for (int k = 0; k < 9; k++) (&a_.m[0][0])[k] -= (&b_.m[0][0])[k]; a_; })`));
  chk('mat3.eq', op('==', 'bool', A, m3(r3), '1'));
  chk('mat3.mul.vec3', op('*', 'Vec3', A, v3(1, -2, 0.5), `m3v(${Ac}, V3(1, -2, 0.5))`));
  chk('mat3.mul.scalar', op('*', 'Mat3', A, f(3), `({ m3 a_ = ${Ac}; for (int k = 0; k < 9; k++) (&a_.m[0][0])[k] *= 3; a_; })`));
  chk('mat3.Transform', call('Mat3.Transform', 'Vec3', A, { v: v3(1, -2, 0.5) }, `m3v(${Ac}, V3(1, -2, 0.5))`));
  chk('mat3.Scaled', call('Mat3.Scaled', 'Mat3', A, { k: f(3) }, `({ m3 a_ = ${Ac}; for (int k = 0; k < 9; k++) (&a_.m[0][0])[k] *= 3; a_; })`));
  chk('mat3.Transposed', call('Mat3.Transposed', 'Mat3', A, {}, `m3T(${Ac})`));
  chk('mat3.Determinant', call('Mat3.Determinant', 'float', A, {}, `m3det(${Ac})`));
  chk('mat3.Inverted', call('Mat3.Inverted', 'Mat3', A, {}, `m3inv(${Ac})`));
  const sing = m3([[1, 2, 3], [2, 4, 6], [0, 1, 1]]);
  chk('mat3.Inverted.singular', call('Mat3.Inverted', 'Mat3', sing, {}, '((m3){0})'));
  chk('mat3.TryInvert', call('Mat3.TryInvert', 'bool', B, {}, '1'));
  chk('mat3.TryInvert.inverse', outOf('Mat3.TryInvert', 'Mat3', B, {}, 'inverse', `m3inv(${Bc})`));
  chk('mat3.TryInvert.singular', call('Mat3.TryInvert', 'bool', sing, {}, '0'));
  chk('mat3.ApproxEquals', call('Mat3.ApproxEquals', 'bool', A, { other: m3(r3.map(r => r.map(x => x - 0.000001))) }, '1'));
  chk('mat3.FromQuat', call('Mat3.FromQuat', 'Mat3', null, { rotation: call('Quat.FromAxisAngle', 'Quat', null, { axis: v3(0.6, 0, 0.8), angle: f(-0.7) }, '') }, 'rotaxis3(V3(0.6, 0, 0.8), -0.7)'));
  chk('mat3.Scale', call('Mat3.Scale', 'Mat3', null, { scale: v3(2, -1, 0.5) }, 'M3R(2, 0, 0, 0, -1, 0, 0, 0, 0.5)'));
  chk('mat3.RotationZ', call('Mat3.RotationZ', 'Mat3', null, { angle: f(0.9) }, 'rotaxis3(V3(0, 0, 1), 0.9)'));
  chk('mat3.ToStd430', new X('float', g => {
    const arr = g.flow('Local', 'float', { count: '12' }, ['set count']);
    g.flow('Call', 'Core.Mat3.ToStd430', { receiver: A.pin(g), into: arr + '.object' });
    let acc = null;
    for (let k = 0; k < 12; k++) {
      const ix = g.node('Index'); g.feed(ix, 'collection', arr + '.object'); g.feed(ix, 'index', String(k));
      acc = acc ? g.math(`s + e * ${k + 1}.0f`, { s: acc, e: ix + '.value' }) : g.math('e', { e: ix + '.value' });
    }
    return acc;
  }, `({ m3 a_ = ${Ac}; double s = 0; for (int c = 0; c < 3; c++) for (int r = 0; r < 3; r++) s += a_.m[c][r] * (c * 4 + r + 1); s; })`));
}

// ---------------- quaternions
{
  const chk = fx('math-quat');
  const qa = call('Quat.FromAxisAngle', 'Quat', null, { axis: v3(1 / 3, 2 / 3, 2 / 3), angle: f(0.9) }, 'qaxis(V3(1, 2, 2), 0.9)');
  const qb = call('Quat.FromAxisAngle', 'Quat', null, { axis: v3(0, 0.6, -0.8), angle: f(-1.7) }, 'qaxis(V3(0, 0.6, -0.8), -1.7)');
  chk('quat.Identity', get('Quat.Identity', 'Quat', 'Q(0, 0, 0, 1)'));
  chk('quat.FromAxisAngle', qa);
  chk('quat.FromAxisAngle.matrix', new X('Mat3', g => g.call('Core.Quat.ToMat3', { receiver: qa.pin(g) }), 'rotaxis3(V3(1, 2, 2), 0.9)'));
  chk('quat.mul', op('*', 'Quat', qa, qb, `qmul(${qa.c}, ${qb.c})`));
  chk('quat.Multiply', call('Quat.Multiply', 'Quat', qa, { b: qb }, `qmul(${qa.c}, ${qb.c})`));
  chk('quat.mul.order', new X('Vec3', g => g.call('Core.Quat.Rotate', { receiver: g.op('*', qa.pin(g), qb.pin(g)), v: v3(1, 2, 3).pin(g) }), `qrot(${qa.c}, qrot(${qb.c}, V3(1, 2, 3)))`));
  chk('quat.eq', op('==', 'bool', q(0.5, 0.5, 0.5, 0.5), q(0.5, 0.5, 0.5, 0.5), '1'));
  chk('quat.eq.false', op('==', 'bool', q(0.5, 0.5, 0.5, 0.5), q(-0.5, -0.5, -0.5, -0.5), '0'));
  chk('quat.mul.vec3', op('*', 'Vec3', qa, v3(1, -2, 0.5), `qrot(${qa.c}, V3(1, -2, 0.5))`));
  chk('quat.Rotate', call('Quat.Rotate', 'Vec3', qa, { v: v3(1, -2, 0.5) }, `qrot(${qa.c}, V3(1, -2, 0.5))`));
  chk('quat.Conjugate', call('Quat.Conjugate', 'Quat', q(1, 2, 3, 4), {}, 'Q(-1, -2, -3, 4)'));
  chk('quat.Inverse', call('Quat.Inverse', 'Quat', q(1, 2, 3, 4), {}, 'qinv(Q(1, 2, 3, 4))'));
  chk('quat.Normalized', call('Quat.Normalized', 'Quat', q(1, 2, 3, 4), {}, 'qnorm(Q(1, 2, 3, 4))'));
  chk('quat.Normalized.zero', call('Quat.Normalized', 'Quat', q(0, 0, 0, 0), {}, 'Q(0, 0, 0, 1)'));
  chk('quat.Dot', call('Quat.Dot', 'float', q(1, 2, 3, 4), { b: q(-1, 0.5, 2, 1) }, '(-1 + 1 + 6 + 4)'));
  chk('quat.Length', call('Quat.Length', 'float', q(1, 2, 3, 4), {}, 'sqrt(30)'));
  chk('quat.Slerp', call('Quat.Slerp', 'Quat', qa, { to: qb, t: f(0.3) }, `qslerp(${qa.c}, ${qb.c}, 0.3)`));
  chk('quat.Slerp.0', call('Quat.Slerp', 'Quat', qa, { to: qb, t: f(0) }, qa.c));
  chk('quat.Slerp.1', call('Quat.Slerp', 'Quat', qa, { to: qb, t: f(1) }, qb.c));
  const qn = call('Quat.FromAxisAngle', 'Quat', null, { axis: v3(1 / 3, 2 / 3, 2 / 3), angle: f(0.91) }, 'qaxis(V3(1, 2, 2), 0.91)');
  chk('quat.Slerp.near', call('Quat.Slerp', 'Quat', qa, { to: qn, t: f(0.5) }, `qslerp(${qa.c}, ${qn.c}, 0.5)`));
  const qneg = new X('Quat', g => g.make('Core.Quat', { X: g.math('-q.X', { q: qb.pin(g) }), Y: g.math('-q.Y', { q: qb.pin(g) }), Z: g.math('-q.Z', { q: qb.pin(g) }), W: g.math('-q.W', { q: qb.pin(g) }) }), '');
  chk('quat.Slerp.shortest', call('Quat.Slerp', 'Quat', qa, { to: qneg, t: f(0.3) }, `qslerp(${qa.c}, ${qb.c}, 0.3)`));
  chk('quat.Slerp.half.angle', new X('float', g => g.call('Core.Quat.AngleTo', { receiver: qa.pin(g), b: g.call('Core.Quat.Slerp', { receiver: qa.pin(g), to: qb.pin(g), t: '0.5f' }) }), `qangle(${qa.c}, ${qb.c}) / 2`));
  chk('quat.Nlerp', call('Quat.Nlerp', 'Quat', qa, { to: qb, t: f(0.3) }, `qnlerp(${qa.c}, ${qb.c}, 0.3)`));
  chk('quat.AngleTo', call('Quat.AngleTo', 'float', qa, { b: qb }, `qangle(${qa.c}, ${qb.c})`));
  chk('quat.ToMat3', call('Quat.ToMat3', 'Mat3', qb, {}, `qtom3(${qb.c})`));
  chk('quat.ToMat4', call('Quat.ToMat4', 'Mat4', qb, {}, `m3to4(qtom3(${qb.c}))`));
  chk('quat.FromMat3', call('Quat.FromMat3', 'Quat', null, { m: m3([[0, -1, 0], [0, 0, -1], [1, 0, 0]]) }, 'm3toq(M3R(0, -1, 0, 0, 0, -1, 1, 0, 0))'));
  chk('quat.FromMat3.round', new X('Quat', g => g.call('Core.Quat.FromMat3', { m: g.call('Core.Quat.ToMat3', { receiver: qb.pin(g) }) }), qb.c));
  for (const [k, ang] of [['x', 3.0], ['y', 3.0], ['z', 3.0]]) {
    const ax = k === 'x' ? [1, 0, 0] : k === 'y' ? [0, 1, 0] : [0, 0, 1];
    const qq = call('Quat.FromAxisAngle', 'Quat', null, { axis: v3(...ax), angle: f(ang) }, `qaxis(V3(${ax}), ${ang})`);
    chk('quat.FromMat3.' + k, new X('Quat', g => g.call('Core.Quat.FromMat3', { m: g.call('Core.Quat.ToMat3', { receiver: qq.pin(g) }) }), qq.c));
  }
  chk('quat.FromEuler', call('Quat.FromEuler', 'Quat', null, { pitch: f(0.3), yaw: f(-1.2), roll: f(0.8) }, 'qeuler(0.3, -1.2, 0.8)'));
  chk('quat.ToEuler', call('Quat.ToEuler', 'Vec3', call('Quat.FromEuler', 'Quat', null, { pitch: f(0.3), yaw: f(-1.2), roll: f(0.8) }, ''), {}, 'V3(0.3, -1.2, 0.8)'), 2e-5);
  chk('quat.ToEuler.ref', call('Quat.ToEuler', 'Vec3', qa, {}, `qtoeuler(${qa.c})`), 2e-5);
  chk('quat.ToEuler.pole', call('Quat.ToEuler', 'Vec3', call('Quat.FromEuler', 'Quat', null, { pitch: f(PI2()), yaw: f(0.5), roll: f(0) }, ''), {}, 'V3(PI / 2, 0.5, 0)'), 2e-3);
  chk('quat.ToAxisAngle', call('Quat.ToAxisAngle', 'float', qa, {}, '0.9'));
  chk('quat.ToAxisAngle.axis', outOf('Quat.ToAxisAngle', 'Vec3', qa, {}, 'axis', 'V3(1.0 / 3, 2.0 / 3, 2.0 / 3)'));
  chk('quat.ToAxisAngle.none', outOf('Quat.ToAxisAngle', 'Vec3', q(0, 0, 0, 1), {}, 'axis', 'V3(1, 0, 0)'));
  chk('quat.LookRotation', call('Quat.LookRotation', 'Quat', null, { forward: v3(1, -1, -2), up: v3(0, 1, 0) }, 'qlook(V3(1, -1, -2), V3(0, 1, 0))'));
  chk('quat.LookRotation.forward', new X('Vec3', g => g.call('Core.Quat.Rotate', { receiver: g.call('Core.Quat.LookRotation', { forward: v3(1, -1, -2).pin(g), up: v3(0, 1, 0).pin(g) }), v: v3(0, 0, -1).pin(g) }), 'norm3(V3(1, -1, -2))'));
  chk('quat.FromTo', call('Quat.FromTo', 'Quat', null, { from: v3(1, 0, 0), to: v3(0, 3, 4) }, 'qfromto(V3(1, 0, 0), V3(0, 3, 4))'));
  chk('quat.FromTo.rotates', new X('Vec3', g => g.call('Core.Quat.Rotate', { receiver: g.call('Core.Quat.FromTo', { from: v3(2, 1, 0).pin(g), to: v3(0, 3, 4).pin(g) }), v: v3(2, 1, 0).pin(g) }), 'mul3(V3(0, 0.6, 0.8), sqrt(5))'));
  chk('quat.FromTo.same', call('Quat.FromTo', 'Quat', null, { from: v3(1, 2, 3), to: v3(2, 4, 6) }, 'Q(0, 0, 0, 1)'));
  chk('quat.FromTo.opposite', new X('Vec3', g => g.call('Core.Quat.Rotate', { receiver: g.call('Core.Quat.FromTo', { from: v3(1, 0, 0).pin(g), to: v3(-1, 0, 0).pin(g) }), v: v3(1, 0, 0).pin(g) }), 'V3(-1, 0, 0)'));
  chk('quat.ApproxEquals.negated', call('Quat.ApproxEquals', 'bool', q(0.5, -0.5, 0.5, 0.5), { other: q(-0.5, 0.5, -0.5, -0.5) }, '1'));
  chk('quat.ApproxEquals.false', call('Quat.ApproxEquals', 'bool', q(0.5, -0.5, 0.5, 0.5), { other: q(0.5, 0.5, 0.5, 0.5) }, '0'));
}
function PI2() { return Math.PI / 2; }

// ---------------- colours
{
  const chk = fx('math-color');
  const c = (...xs) => lit('Color', ...xs);
  for (const [n, v] of [['White', '1, 1, 1, 1'], ['Black', '0, 0, 0, 1'], ['Transparent', '0, 0, 0, 0'], ['Red', '1, 0, 0, 1'], ['Green', '0, 1, 0, 1'], ['Blue', '0, 0, 1, 1'], ['Yellow', '1, 1, 0, 1'], ['Cyan', '0, 1, 1, 1'], ['Magenta', '1, 0, 1, 1'], ['Gray', '0.5, 0.5, 0.5, 1']])
    chk('color.' + n, get('Color.' + n, 'Color', `((col){${v}})`));
  const u8 = x => lit('uint8', x), u32 = x => lit('uint32', x);
  chk('color.FromRGBA8', call('Color.FromRGBA8', 'Color', null, { r: u8(255), g: u8(128), b: u8(0), a: u8(51) }, '((col){1, 128 / 255.0, 0, 0.2})'));
  chk('color.FromRGBA8.alpha', call('Color.FromRGBA8', 'Color', null, { r: u8(10), g: u8(20), b: u8(30) }, '((col){10 / 255.0, 20 / 255.0, 30 / 255.0, 1})'));
  chk('color.FromHex', call('Color.FromHex', 'Color', null, { rrggbbaa: u32(0x3366CCFF) }, '((col){0.2, 0.4, 0.8, 1})'));
  const sc = c(0.5, 0.04, 0.9, 0.7);
  chk('color.FromSrgb', call('Color.FromSrgb', 'Color', null, { srgb: sc }, '((col){srgb_dec(0.5), srgb_dec(0.04), srgb_dec(0.9), 0.7})'));
  chk('color.ToSrgb', call('Color.ToSrgb', 'Color', sc, {}, '((col){srgb_enc(0.5), srgb_enc(0.04), srgb_enc(0.9), 0.7})'));
  chk('color.Srgb.round', new X('Color', g => g.call('Core.Color.ToSrgb', { receiver: g.call('Core.Color.FromSrgb', { srgb: sc.pin(g) }) }), sc.c));
  chk('color.ToColor32', call('Color.ToColor32', 'Color32', c(0.5, 0.002, 1.5, 0.25), {}, '((col32){(int)round(srgb_enc(0.5) * 255), (int)round(srgb_enc(0.002) * 255), 255, 64})'));
  chk('color.WithAlpha', call('Color.WithAlpha', 'Color', sc, { alpha: f(0.1) }, '((col){0.5, 0.04, 0.9, 0.1})'));
  chk('color.Premultiplied', call('Color.Premultiplied', 'Color', sc, {}, '((col){0.5 * 0.7, 0.04 * 0.7, 0.9 * 0.7, 0.7})'));
  chk('color.Lerp', call('Color.Lerp', 'Color', sc, { to: c(1, 0, 0, 1), t: f(0.25) }, '((col){0.5 + 0.5 * 0.25, 0.04 - 0.04 * 0.25, 0.9 - 0.9 * 0.25, 0.7 + 0.3 * 0.25})'));
  chk('color.Scaled', call('Color.Scaled', 'Color', sc, { k: f(2) }, '((col){1, 0.08, 1.8, 1.4})'));
  chk('color.add', op('+', 'Color', sc, c(0.25, 0.5, 0.1, 0.3), '((col){0.75, 0.54, 1.0, 1.0})'));
  chk('color.mul', op('*', 'Color', sc, c(0.5, 2, 0.5, 1), '((col){0.25, 0.08, 0.45, 0.7})'));
  chk('color.mul.scalar', op('*', 'Color', sc, f(2), '((col){1, 0.08, 1.8, 1.4})'));
  chk('color.eq', op('==', 'bool', sc, c(0.5, 0.04, 0.9, 0.7), '1'));
  chk('color.eq.false', op('==', 'bool', sc, c(0.5, 0.04, 0.9, 0.71), '0'));
  chk('color.ApproxEquals', call('Color.ApproxEquals', 'bool', sc, { other: c(0.500001, 0.04, 0.9, 0.7) }, '1'));
  chk('color32.FromHex', call('Color32.FromHex', 'Color32', null, { rrggbbaa: u32(0x12AB7F01) }, '((col32){0x12, 0xAB, 0x7F, 1})'));
  chk('color32.ToHex', call('Color32.ToHex', 'uint32', lit('Color32', 0x12, 0xAB, 0x7F, 1), {}, '0x12AB7F01'));
  chk('color32.ToColor', call('Color32.ToColor', 'Color', lit('Color32', 255, 128, 0, 51), {}, '((col){1, srgb_dec(128 / 255.0), 0, 0.2})'));
  chk('color32.round', new X('Color32', g => g.call('Core.Color.ToColor32', { receiver: g.call('Core.Color32.ToColor', { receiver: lit('Color32', 200, 17, 99, 250).pin(g) }) }), '((col32){200, 17, 99, 250})'));
  chk('color32.eq', op('==', 'bool', lit('Color32', 1, 2, 3, 4), lit('Color32', 1, 2, 3, 4), '1'));
  chk('color32.eq.false', op('==', 'bool', lit('Color32', 1, 2, 3, 4), lit('Color32', 1, 2, 3, 5), '0'));
}

// ---------------- rectangles
{
  const chk = fx('math-rect');
  const R = (...xs) => lit('Rect', ...xs), RI = (...xs) => lit('RectI', ...xs), i32 = x => lit('int32', x);
  const a = R(1, 2, 4, 3), b = R(3, 4, 5, 5);
  chk('rect.FromMinMax', call('Rect.FromMinMax', 'Rect', null, { min: v2(1, 2), max: v2(5, 5) }, '((rct){1, 2, 4, 3})'));
  chk('rect.Min', call('Rect.Min', 'Vec2', a, {}, 'V2(1, 2)'));
  chk('rect.Max', call('Rect.Max', 'Vec2', a, {}, 'V2(5, 5)'));
  chk('rect.Center', call('Rect.Center', 'Vec2', a, {}, 'V2(3, 3.5)'));
  chk('rect.Size', call('Rect.Size', 'Vec2', a, {}, 'V2(4, 3)'));
  chk('rect.Contains', call('Rect.Contains', 'bool', a, { point: v2(1, 4.9) }, '1'));
  chk('rect.Contains.edge', call('Rect.Contains', 'bool', a, { point: v2(5, 3) }, '0'));
  chk('rect.Overlaps', call('Rect.Overlaps', 'bool', a, { other: b }, '1'));
  chk('rect.Overlaps.touch', call('Rect.Overlaps', 'bool', a, { other: R(5, 2, 1, 1) }, '0'));
  chk('rect.Intersection', call('Rect.Intersection', 'Rect', a, { other: b }, '((rct){3, 4, 2, 1})'));
  chk('rect.Intersection.none', call('Rect.Intersection', 'Rect', a, { other: R(10, 10, 1, 1) }, '((rct){10, 10, 0, 0})'));
  chk('rect.Union', call('Rect.Union', 'Rect', a, { other: b }, '((rct){1, 2, 7, 7})'));
  chk('rect.Expanded', call('Rect.Expanded', 'Rect', a, { amount: f(0.5) }, '((rct){0.5, 1.5, 5, 4})'));
  chk('rect.Translated', call('Rect.Translated', 'Rect', a, { offset: v2(-1, 10) }, '((rct){0, 12, 4, 3})'));
  chk('rect.IsEmpty', call('Rect.IsEmpty', 'bool', R(0, 0, 0, 3), {}, '1'));
  chk('rect.IsEmpty.false', call('Rect.IsEmpty', 'bool', a, {}, '0'));
  chk('rect.eq', op('==', 'bool', a, R(1, 2, 4, 3), '1'));
  const ai = RI(1, 2, 4, 3), bi = RI(3, 4, 5, 5);
  chk('recti.FromMinMax', call('RectI.FromMinMax', 'RectI', null, { minX: i32(1), minY: i32(2), maxX: i32(5), maxY: i32(5) }, '((rcti){1, 2, 4, 3})'));
  chk('recti.Contains', call('RectI.Contains', 'bool', ai, { x: i32(4), y: i32(2) }, '1'));
  chk('recti.Contains.edge', call('RectI.Contains', 'bool', ai, { x: i32(5), y: i32(2) }, '0'));
  chk('recti.ContainsPoint', call('RectI.ContainsPoint', 'bool', ai, { point: v2(4.5, 4.9) }, '1'));
  chk('recti.Expanded', call('RectI.Expanded', 'RectI', ai, { amount: i32(2) }, '((rcti){-1, 0, 8, 7})'));
  chk('recti.Translated', call('RectI.Translated', 'RectI', ai, { dx: i32(-3), dy: i32(4) }, '((rcti){-2, 6, 4, 3})'));
  chk('recti.Center', call('RectI.Center', 'Vec2', ai, {}, 'V2(3, 3.5)'));
  chk('recti.ToRect', call('RectI.ToRect', 'Rect', ai, {}, '((rct){1, 2, 4, 3})'));
  chk('recti.FromRect', call('RectI.FromRect', 'RectI', null, { rect: R(1.5, -2.25, 3, 1) }, '((rcti){1, -3, 4, 2})'));
  chk('recti.Overlaps', call('RectI.Overlaps', 'bool', ai, { other: bi }, '1'));
  chk('recti.Intersection', call('RectI.Intersection', 'RectI', ai, { other: bi }, '((rcti){3, 4, 2, 1})'));
  chk('recti.Intersection.none', call('RectI.Intersection', 'RectI', ai, { other: RI(9, 0, 2, 2) }, '((rcti){9, 2, 0, 0})'));
  chk('recti.Union', call('RectI.Union', 'RectI', ai, { other: bi }, '((rcti){1, 2, 7, 7})'));
  chk('recti.IsEmpty', call('RectI.IsEmpty', 'bool', RI(0, 0, 3, -1), {}, '1'));
  chk('recti.eq', op('==', 'bool', ai, RI(1, 2, 4, 3), '1'));
}

// ---------------- AABB, Plane, Ray
{
  const chk = fx('math-aabb');
  const B = (...xs) => lit('AABB', ...xs);
  const a = B(-1, 0, 2, 3, 4, 5), b = B(2, 3, 4, 6, 6, 6);
  chk('aabb.Empty', call('AABB.IsValid', 'bool', get('AABB.Empty', 'AABB', ''), {}, '0'));
  chk('aabb.Empty.Encapsulate', new X('AABB', g => g.call('Core.AABB.Encapsulate', { receiver: g.get('Core.AABB.Empty'), point: v3(1, 2, 3).pin(g) }), '((box){1, 2, 3, 1, 2, 3})'));
  chk('aabb.FromCenterExtents', call('AABB.FromCenterExtents', 'AABB', null, { center: v3(1, 2, 3), extents: v3(0.5, 1, 2) }, '((box){0.5, 1, 1, 1.5, 3, 5})'));
  chk('aabb.FromPoints', new X('AABB', g => {
    const arr = g.flow('Local', 'Core.Vec3', { count: '4' }, ['set count']);
    const pts = [[1, 2, 3], [-4, 5, 0.5], [2, -1, 7], [0, 0, 0]];
    pts.forEach((p, k) => g.flow('Call', 'Arrays.Set', { array: arr + '.object', index: String(k), value: v3(...p).pin(g) }));
    return g.call('Core.AABB.FromPoints', { points: arr + '.object' });
  }, '((box){-4, -1, 0, 2, 5, 7})'));
  chk('aabb.Center', call('AABB.Center', 'Vec3', a, {}, 'V3(1, 2, 3.5)'));
  chk('aabb.Extents', call('AABB.Extents', 'Vec3', a, {}, 'V3(2, 2, 1.5)'));
  chk('aabb.Size', call('AABB.Size', 'Vec3', a, {}, 'V3(4, 4, 3)'));
  chk('aabb.IsValid', call('AABB.IsValid', 'bool', a, {}, '1'));
  chk('aabb.Contains', call('AABB.Contains', 'bool', a, { point: v3(3, 0, 2) }, '1'));
  chk('aabb.Contains.out', call('AABB.Contains', 'bool', a, { point: v3(3, 0, 5.1) }, '0'));
  chk('aabb.Overlaps', call('AABB.Overlaps', 'bool', a, { other: b }, '1'));
  chk('aabb.Overlaps.touch', call('AABB.Overlaps', 'bool', a, { other: B(3, 4, 5, 9, 9, 9) }, '1'));
  chk('aabb.Overlaps.no', call('AABB.Overlaps', 'bool', a, { other: B(3.5, 0, 2, 9, 9, 9) }, '0'));
  chk('aabb.Union', call('AABB.Union', 'AABB', a, { other: b }, '((box){-1, 0, 2, 6, 6, 6})'));
  chk('aabb.Encapsulate', call('AABB.Encapsulate', 'AABB', a, { point: v3(-3, 10, 4) }, '((box){-3, 0, 2, 3, 10, 5})'));
  chk('aabb.ClosestPoint', call('AABB.ClosestPoint', 'Vec3', a, { point: v3(-5, 2, 9) }, 'V3(-1, 2, 5)'));
  const mT = call('Mat4.FromTRS', 'Mat4', null, { translation: v3(10, 0, -2), rotation: call('Quat.FromAxisAngle', 'Quat', null, { axis: v3(0, 1, 0), angle: f(Math.PI / 4) }, ''), scale: v3(1, 2, 1) }, '');
  const trC = `({ m4 m_ = trs(V3(10, 0, -2), qaxis(V3(0, 1, 0), PI / 4), V3(1, 2, 1)); box b_ = {{1e30, 1e30, 1e30}, {-1e30, -1e30, -1e30}}; for (int k = 0; k < 8; k++) { v3 c_ = m4point(m_, V3(k & 1 ? 3 : -1, k & 2 ? 4 : 0, k & 4 ? 5 : 2)); b_.min = V3(fmin(b_.min.x, c_.x), fmin(b_.min.y, c_.y), fmin(b_.min.z, c_.z)); b_.max = V3(fmax(b_.max.x, c_.x), fmax(b_.max.y, c_.y), fmax(b_.max.z, c_.z)); } b_; })`;
  chk('aabb.Transformed', call('AABB.Transformed', 'AABB', a, { m: mT }, trC));
  chk('aabb.Transformed.empty', new X('bool', g => g.call('Core.AABB.IsValid', { receiver: g.call('Core.AABB.Transformed', { receiver: g.get('Core.AABB.Empty'), m: g.get('Core.Mat4.Identity') }) }), '0'));
}
{
  const chk = fx('math-plane');
  const P = (...xs) => lit('Plane', ...xs);
  chk('plane.FromPointNormal', call('Plane.FromPointNormal', 'Plane', null, { point: v3(1, 2, 3), normal: v3(0, 0.6, 0.8) }, '((pln){0, 0.6, 0.8, -(1.2 + 2.4)})'));
  chk('plane.FromPoints', call('Plane.FromPoints', 'Plane', null, { a: v3(1, 0, 0), b: v3(0, 1, 0), c: v3(0, 0, 1) }, '((pln){1 / sqrt(3), 1 / sqrt(3), 1 / sqrt(3), -1 / sqrt(3)})'));
  const p = P(0, 0.6, 0.8, -2);
  chk('plane.DistanceTo', call('Plane.DistanceTo', 'float', p, { point: v3(5, 3, 4) }, '(1.8 + 3.2 - 2)'));
  chk('plane.DistanceTo.back', call('Plane.DistanceTo', 'float', p, { point: v3(0, 0, 0) }, '-2'));
  chk('plane.Side.front', call('Plane.Side', 'int', p, { point: v3(5, 3, 4) }, '1'));
  chk('plane.Side.back', call('Plane.Side', 'int', p, { point: v3(0, 0, 0) }, '-1'));
  chk('plane.Side.on', call('Plane.Side', 'int', P(0, 0, 1, -2), { point: v3(7, -3, 2) }, '0'));
  chk('plane.Normalized', call('Plane.Normalized', 'Plane', P(0, 3, 4, 10), {}, '((pln){0, 0.6, 0.8, 2})'));
  chk('plane.Project', call('Plane.Project', 'Vec3', P(0, 3, 4, 10), { point: v3(1, 1, 1) }, '({ v3 n_ = V3(0, 3, 4), p_ = V3(1, 1, 1); double k = (dot3(n_, p_) + 10) / 25; sub3(p_, mul3(n_, k)); })'));
}
{
  const chk = fx('math-ray');
  const RY = (...xs) => lit('Ray', ...xs);
  const r = RY(1, 2, 3, 0, 0, -2);
  chk('ray.At', call('Ray.At', 'Vec3', r, { t: f(1.5) }, 'V3(1, 2, 0)'));
  const box = lit('AABB', 0, 0, -5, 2, 4, -1);
  chk('ray.IntersectAABB', call('Ray.IntersectAABB', 'bool', r, { box }, '1'));
  chk('ray.IntersectAABB.t', outOf('Ray.IntersectAABB', 'float', r, { box }, 't', '2'));
  chk('ray.IntersectAABB.miss', call('Ray.IntersectAABB', 'bool', RY(5, 2, 3, 0, 0, -2), { box }, '0'));
  chk('ray.IntersectAABB.inside', outOf('Ray.IntersectAABB', 'float', RY(1, 2, -3, 0.3, 1, 0.1), { box }, 't', '0'));
  chk('ray.IntersectAABB.behind', call('Ray.IntersectAABB', 'bool', RY(1, 2, 3, 0, 0, 1), { box }, '0'));
  chk('ray.IntersectAABB.slant.t', outOf('Ray.IntersectAABB', 'float', RY(-2, 1, -3, 1, 0.5, 0), { box }, 't', '2'));
  const pl = lit('Plane', 0, 1, 0, -1);
  chk('ray.IntersectPlane', call('Ray.IntersectPlane', 'bool', RY(0, 5, 0, 1, -2, 0), { plane: pl }, '1'));
  chk('ray.IntersectPlane.t', outOf('Ray.IntersectPlane', 'float', RY(0, 5, 0, 1, -2, 0), { plane: pl }, 't', '2'));
  chk('ray.IntersectPlane.parallel', call('Ray.IntersectPlane', 'bool', RY(0, 5, 0, 1, 0, 0), { plane: pl }, '0'));
  chk('ray.IntersectPlane.behind', call('Ray.IntersectPlane', 'bool', RY(0, 5, 0, 0, 1, 0), { plane: pl }, '0'));
  chk('ray.IntersectSphere', call('Ray.IntersectSphere', 'bool', RY(0, 0, 10, 0, 0, -1), { center: v3(0, 0.6, 0), radius: f(1) }, '1'));
  chk('ray.IntersectSphere.t', outOf('Ray.IntersectSphere', 'float', RY(0, 0, 10, 0, 0, -1), { center: v3(0, 0.6, 0), radius: f(1) }, 't', '10 - 0.8'));
  chk('ray.IntersectSphere.scaled.t', outOf('Ray.IntersectSphere', 'float', RY(0, 0, 10, 0, 0, -2), { center: v3(0, 0.6, 0), radius: f(1) }, 't', '(10 - 0.8) / 2'));
  chk('ray.IntersectSphere.miss', call('Ray.IntersectSphere', 'bool', RY(0, 0, 10, 0, 0, -1), { center: v3(0, 1.5, 0), radius: f(1) }, '0'));
  chk('ray.IntersectSphere.inside', outOf('Ray.IntersectSphere', 'float', RY(0, 0, 0.2, 1, 0, 0), { center: v3(0, 0, 0), radius: f(1) }, 't', '0'));
  chk('ray.IntersectSphere.behind', call('Ray.IntersectSphere', 'bool', RY(0, 0, 5, 0, 0, 1), { center: v3(0, 0, 0), radius: f(1) }, '0'));
  const ta = v3(0, 0, 0), tb = v3(4, 0, 0), tc = v3(0, 4, 0);
  chk('ray.IntersectTriangle', call('Ray.IntersectTriangle', 'bool', RY(1, 1, 5, 0, 0, -1), { a: ta, b: tb, c: tc }, '1'));
  chk('ray.IntersectTriangle.t', outOf('Ray.IntersectTriangle', 'float', RY(1, 1, 5, 0, 0, -1), { a: ta, b: tb, c: tc }, 't', '5'));
  chk('ray.IntersectTriangle.back', outOf('Ray.IntersectTriangle', 'float', RY(1, 1, -2, 0, 0, 0.5), { a: ta, b: tb, c: tc }, 't', '4'));
  chk('ray.IntersectTriangle.miss', call('Ray.IntersectTriangle', 'bool', RY(3, 3, 5, 0, 0, -1), { a: ta, b: tb, c: tc }, '0'));
  chk('ray.IntersectTriangle.parallel', call('Ray.IntersectTriangle', 'bool', RY(1, 1, 0, 1, 0, 0), { a: ta, b: tb, c: tc }, '0'));
}
{
  const chk = fx('math-transform');
  const qr = call('Quat.FromAxisAngle', 'Quat', null, { axis: v3(0, 0.6, 0.8), angle: f(0.7) }, 'qaxis(V3(0, 0.6, 0.8), 0.7)');
  const T = new X('Transform', g => g.make('Core.Transform', { Translation: v3(1, 2, 3).pin(g), Rotation: qr.pin(g), Scale: v3(2, 2, 2).pin(g) }), `((xf){V3(1, 2, 3), ${qr.c}, V3(2, 2, 2)})`);
  const q2 = call('Quat.FromAxisAngle', 'Quat', null, { axis: v3(1, 0, 0), angle: f(-0.4) }, 'qaxis(V3(1, 0, 0), -0.4)');
  const T2 = new X('Transform', g => g.make('Core.Transform', { Translation: v3(-1, 0.5, 4).pin(g), Rotation: q2.pin(g), Scale: v3(0.5, 0.5, 0.5).pin(g) }), `((xf){V3(-1, 0.5, 4), ${q2.c}, V3(0.5, 0.5, 0.5)})`);
  const Tm = `trs(V3(1, 2, 3), ${qr.c}, V3(2, 2, 2))`, T2m = `trs(V3(-1, 0.5, 4), ${q2.c}, V3(0.5, 0.5, 0.5))`;
  chk('transform.Identity', get('Transform.Identity', 'Transform', '((xf){V3(0, 0, 0), Q(0, 0, 0, 1), V3(1, 1, 1)})'));
  chk('transform.ToMat4', call('Transform.ToMat4', 'Mat4', T, {}, Tm));
  chk('transform.TransformPoint', call('Transform.TransformPoint', 'Vec3', T, { point: v3(1, -1, 2) }, `m4point(${Tm}, V3(1, -1, 2))`));
  chk('transform.TransformVector', call('Transform.TransformVector', 'Vec3', T, { vector: v3(1, -1, 2) }, `m4dir(${Tm}, V3(1, -1, 2))`));
  chk('transform.Inverse.matrix', new X('Mat4', g => g.call('Core.Transform.ToMat4', { receiver: g.call('Core.Transform.Inverse', { receiver: T.pin(g) }) }), `m4inv(${Tm})`));
  chk('transform.Inverse.point', new X('Vec3', g => g.call('Core.Transform.TransformPoint', { receiver: g.call('Core.Transform.Inverse', { receiver: T.pin(g) }), point: g.call('Core.Transform.TransformPoint', { receiver: T.pin(g), point: v3(1, -1, 2).pin(g) }) }), 'V3(1, -1, 2)'));
  chk('transform.mul', new X('Mat4', g => g.call('Core.Transform.ToMat4', { receiver: g.op('*', T.pin(g), T2.pin(g)) }), `m4mul(${Tm}, ${T2m})`));
  chk('transform.Compose', new X('Mat4', g => g.call('Core.Transform.ToMat4', { receiver: g.call('Core.Transform.Compose', { receiver: T.pin(g), child: T2.pin(g) }) }), `m4mul(${Tm}, ${T2m})`));
  chk('transform.Lerp', call('Transform.Lerp', 'Transform', T, { to: T2, t: f(0.25) }, `((xf){V3(1 - 2 * 0.25, 2 - 1.5 * 0.25, 3 + 0.25), qslerp(${qr.c}, ${q2.c}, 0.25), V3(2 - 1.5 * 0.25, 2 - 1.5 * 0.25, 2 - 1.5 * 0.25)})`));
  chk('transform.ApproxEquals', call('Transform.ApproxEquals', 'bool', T, { other: T }, '1'));
  chk('transform.ApproxEquals.false', call('Transform.ApproxEquals', 'bool', T, { other: T2 }, '0'));
}

// ---------------- a chain of transforms against GLM's conventions (mathlib-glm; the C twin is mathlib-glm.c)
{
  const chk = fx('mathlib-glm');
  const memo = new WeakMap();
  const P = g => memo.get(g) || (memo.set(g, P0(g)), memo.get(g));
  const P0 = g => {
    const q1 = g.call('Core.Quat.FromEuler', { pitch: '0.3f', yaw: '-0.7f', roll: '0.2f' });
    const model = g.call('Core.Mat4.FromTRS', { translation: v3(2, -1, 3).pin(g), rotation: q1, scale: v3(1.5, 1.5, 1.5).pin(g) });
    const view = g.call('Core.Mat4.LookAt', { eye: v3(4, 3, 6).pin(g), target: v3(0, 0.5, 0).pin(g), up: v3(0, 1, 0).pin(g) });
    const proj = g.call('Core.Mat4.Perspective', { fovY: g.call('Core.Math.Radians', { degrees: '60.0f' }), aspect: g.math('16.0f / 9.0f', {}), near: '0.1f', far: '50.0f' });
    const mvp = g.op('*', g.op('*', proj, view), model);
    return { q1, model, view, proj, mvp };
  };
  const cModel = 'trs(V3(2, -1, 3), qeuler(0.3, -0.7, 0.2), V3(1.5, 1.5, 1.5))';
  const cView = 'lookat(V3(4, 3, 6), V3(0, 0.5, 0), V3(0, 1, 0))';
  const cProj = 'persp(PI / 3, 16.0 / 9.0, 0.1, 50, 0)';
  const cMvp = `m4mul(m4mul(${cProj}, ${cView}), ${cModel})`;
  chk('glm.model', new X('Mat4', g => P(g).model, cModel));
  chk('glm.view', new X('Mat4', g => P(g).view, cView));
  chk('glm.proj', new X('Mat4', g => P(g).proj, cProj));
  chk('glm.mvp', new X('Mat4', g => P(g).mvp, cMvp), 2e-5);
  const pts = [[0, 0, 0], [1, 1, 1], [-1, 0.5, 2], [0.25, -2, -1]];
  pts.forEach((p, k) => {
    chk(`glm.clip.${k}`, new X('Vec4', g => g.op('*', P(g).mvp, v4(p[0], p[1], p[2], 1).pin(g)), `m4v(${cMvp}, V4(${p.join(', ')}, 1))`), 2e-5);
    chk(`glm.ndc.${k}`, new X('Vec3', g => g.call('Core.Mat4.TransformPerspective', { receiver: P(g).mvp, point: v3(...p).pin(g) }), `m4persp(${cMvp}, V3(${p.join(', ')}))`), 2e-5);
    chk(`glm.world.${k}`, new X('Vec3', g => g.call('Core.Mat4.TransformPoint', { receiver: P(g).model, point: v3(...p).pin(g) }), `m4point(${cModel}, V3(${p.join(', ')}))`));
  });
  chk('glm.mvp.inverse', new X('Mat4', g => g.op('*', g.call('Core.Mat4.Inverted', { receiver: P(g).mvp }), P(g).mvp), 'm4id()'), 1e-4);
  chk('glm.view.inverse.affine', new X('Mat4', g => g.call('Core.Mat4.InvertedAffine', { receiver: P(g).view }), `m4inv(${cView})`));
  chk('glm.normal.matrix', new X('Mat3', g => g.call('Core.Mat3.Transposed', { receiver: g.call('Core.Mat3.Inverted', { receiver: g.call('Core.Mat4.Upper3x3', { receiver: P(g).model }) }) }), `m3T(m3inv(m4to3(${cModel})))`));
  const T1 = g => g.make('Core.Transform', { Translation: v3(1, 2, 3).pin(g), Rotation: g.call('Core.Quat.FromAxisAngle', { axis: v3(0, 1, 0).pin(g), angle: '0.5f' }), Scale: v3(2, 2, 2).pin(g) });
  const T2 = g => g.make('Core.Transform', { Translation: v3(-0.5, 1, 0).pin(g), Rotation: g.call('Core.Quat.FromAxisAngle', { axis: v3(1, 0, 0).pin(g), angle: '-0.25f' }), Scale: v3(0.5, 0.5, 0.5).pin(g) });
  const cT1 = 'trs(V3(1, 2, 3), qaxis(V3(0, 1, 0), 0.5), V3(2, 2, 2))', cT2 = 'trs(V3(-0.5, 1, 0), qaxis(V3(1, 0, 0), -0.25), V3(0.5, 0.5, 0.5))';
  chk('glm.transform.chain', new X('Mat4', g => g.call('Core.Transform.ToMat4', { receiver: g.op('*', T1(g), T2(g)) }), `m4mul(${cT1}, ${cT2})`));
  chk('glm.transform.point', new X('Vec3', g => g.call('Core.Transform.TransformPoint', { receiver: g.op('*', T1(g), T2(g)), point: v3(1, -1, 0.5).pin(g) }), `m4point(m4mul(${cT1}, ${cT2}), V3(1, -1, 0.5))`));
  chk('glm.slerp.rotate', new X('Vec3', g => {
    const a = g.call('Core.Quat.FromEuler', { pitch: '0.3f', yaw: '-0.7f', roll: '0.2f' });
    const b = g.call('Core.Quat.FromEuler', { pitch: '-0.4f', yaw: '1.1f', roll: '0.0f' });
    return g.op('*', g.call('Core.Quat.Slerp', { receiver: a, to: b, t: '0.5f' }), v3(0, 0, -1).pin(g));
  }, 'qrot(qslerp(qeuler(0.3, -0.7, 0.2), qeuler(-0.4, 1.1, 0), 0.5), V3(0, 0, -1))'));
  chk('glm.ortho.gl', new X('Vec3', g => g.call('Core.Mat4.TransformPoint', { receiver: g.op('*', g.call('Core.Mat4.OrthographicGL', { left: '-4.0f', right: '4.0f', bottom: '-3.0f', top: '3.0f', near: '0.5f', far: '20.0f' }), P(g).view), point: v3(1, 1, 1).pin(g) }), `m4point(m4mul(ortho(-4, 4, -3, 3, 0.5, 20, 1), ${cView}), V3(1, 1, 1))`));
  chk('glm.aabb.view', new X('AABB', g => g.call('Core.AABB.Transformed', { receiver: lit('AABB', -1, -1, -1, 1, 1, 1).pin(g), m: P(g).view }),
    `({ m4 m_ = ${cView}; box b_ = {{1e30, 1e30, 1e30}, {-1e30, -1e30, -1e30}}; for (int k = 0; k < 8; k++) { v3 c_ = m4point(m_, V3(k & 1 ? 1 : -1, k & 2 ? 1 : -1, k & 4 ? 1 : -1)); b_.min = V3(fmin(b_.min.x, c_.x), fmin(b_.min.y, c_.y), fmin(b_.min.z, c_.z)); b_.max = V3(fmax(b_.max.x, c_.x), fmax(b_.max.y, c_.y), fmax(b_.max.z, c_.z)); } b_; })`));
}

module.exports = { F };
