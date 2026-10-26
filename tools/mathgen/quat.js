'use strict';
const { TypeFile } = require('./lib');
const { opts } = require('./common');
const { mk, R } = require('./mat');

const Q4 = ['X', 'Y', 'Z', 'W'];
const qmake = (g, f) => g.make('Quat', { X: f('X'), Y: f('Y'), Z: f('Z'), W: f('W') });

function quat() {
  const t = new TypeFile('Quat', 'struct', ['namespace Core', 'attr CRepr',
    'doc "A rotation as a unit quaternion (X, Y, Z the vector part, W the real part; 16 bytes). a * b rotates by b first, then a. Every function is Pure."']);
  for (const c of Q4) t.field(c, 'float');
  const me = g => ({ q: g.self() });
  t.prop('Identity', { type: 'Quat', static: true, doc: 'No rotation: (0, 0, 0, 1).' }, g => g.make('Quat', { X: '0.0f', Y: '0.0f', Z: '0.0f', W: '1.0f' }));

  const mulEx = {
    X: 'a.W * b.X + a.X * b.W + a.Y * b.Z - a.Z * b.Y',
    Y: 'a.W * b.Y - a.X * b.Z + a.Y * b.W + a.Z * b.X',
    Z: 'a.W * b.Z + a.X * b.Y - a.Y * b.X + a.Z * b.W',
    W: 'a.W * b.W - a.X * b.X - a.Y * b.Y - a.Z * b.Z',
  };
  const mul = (g, a, b) => qmake(g, c => g.math(mulEx[c], { a, b }));
  const ab = [['a', 'Quat'], ['b', 'Quat']];
  t.op('*', { ret: 'Quat', params: ab, doc: 'The rotation b, then a (the Hamilton product).' }, g => mul(g, g.arg('a'), g.arg('b')));
  t.op('==', { ret: 'bool', params: ab, doc: 'True when every component is equal (exact; q and -q are the same rotation but not ==).' },
    g => g.math(Q4.map(c => `a.${c} == b.${c}`).join(' && '), { a: g.arg('a'), b: g.arg('b') }));
  const rotate = (g, q, v) => {
    // uv = cross(q.xyz, v); uuv = cross(q.xyz, uv); v + (uv * w + uuv) * 2
    const uv = { X: g.math('q.Y * v.Z - q.Z * v.Y', { q, v }), Y: g.math('q.Z * v.X - q.X * v.Z', { q, v }), Z: g.math('q.X * v.Y - q.Y * v.X', { q, v }) };
    const uvv = g.make('Vec3', uv);
    const uuv = { X: g.math('q.Y * u.Z - q.Z * u.Y', { q, u: uvv }), Y: g.math('q.Z * u.X - q.X * u.Z', { q, u: uvv }), Z: g.math('q.X * u.Y - q.Y * u.X', { q, u: uvv }) };
    return g.make('Vec3', Object.fromEntries(['X', 'Y', 'Z'].map(c => [c, g.math(`v.${c} + (u.${c} * q.W + w) * 2.0f`, { v, u: uvv, q, w: uuv[c] })])));
  };
  if (opts.overloads)
    t.op('*', { ret: 'Vec3', params: [['q', 'Quat'], ['v', 'Vec3']], doc: 'The vector `v` rotated by `q`.' }, g => rotate(g, g.arg('q'), g.arg('v')));
  t.fn('Multiply', { ret: 'Quat', params: [['b', 'Quat']], doc: 'This rotation after `b` (the operator `*`).' }, g => mul(g, g.self(), g.arg('b')));
  t.fn('Rotate', { ret: 'Vec3', params: [['v', 'Vec3']], doc: 'The vector `v` rotated by this quaternion.' }, g => rotate(g, g.self(), g.arg('v')));

  t.fn('FromAxisAngle', { static: true, ret: 'Quat', params: [['axis', 'Vec3'], ['angle', 'float']], doc: 'A rotation of `angle` radians about the unit vector `axis` (counter-clockwise looking down the axis).' }, g => {
    const a = g.arg('axis');
    const h = g.math('x * 0.5f', { x: g.arg('angle') });
    const s = g.math('Sin(h)', { h });
    return g.make('Quat', { X: g.math('a.X * s', { a, s }), Y: g.math('a.Y * s', { a, s }), Z: g.math('a.Z * s', { a, s }), W: g.math('Cos(h)', { h }) });
  });
  t.fn('FromEuler', { static: true, ret: 'Quat', params: [['pitch', 'float'], ['yaw', 'float'], ['roll', 'float']], doc: 'Angles in radians applied roll about Z, then pitch about X, then yaw about Y.' }, g => {
    const ax = (u, ang) => g.call('Core.Quat.FromAxisAngle', { axis: g.get('Core.Vec3.Unit' + u), angle: ang });
    const qy = ax('Y', g.arg('yaw')), qx = ax('X', g.arg('pitch')), qz = ax('Z', g.arg('roll'));
    return mul(g, mul(g, qy, qx), qz);
  });
  // FromMat3 (the largest of the four squares decides)
  const fromMat = (g, m) => {
    const fw = g.math('m.C0.X + m.C1.Y + m.C2.Z', { m });
    const fx = g.math('m.C0.X - m.C1.Y - m.C2.Z', { m });
    const fy = g.math('m.C1.Y - m.C0.X - m.C2.Z', { m });
    const fz = g.math('m.C2.Z - m.C0.X - m.C1.Y', { m });
    const P = { w: fw, x: fx, y: fy, z: fz };
    // index of the largest: w 0, x 1, y 2, z 3 (first wins)
    const i1 = g.math('x > w ? 1 : 0', P);
    const b1 = g.math('x > w ? x : w', P);
    const i2 = g.math('y > b ? 2 : i', { y: fy, b: b1, i: i1 });
    const b2 = g.math('y > b ? y : b', { y: fy, b: b1 });
    const idx = g.math('z > b ? 3 : i', { z: fz, b: b2, i: i2 });
    const big = g.math('z > b ? z : b', { z: fz, b: b2 });
    const bv = g.math('Sqrt(f + 1.0f) * 0.5f', { f: big });
    const mult = g.math('0.25f / v', { v: bv });
    const I = { m, k: mult, v: bv, i: idx };
    // (w, x, y, z) per case
    const W = ['v', '(m.C1.Z - m.C2.Y) * k', '(m.C2.X - m.C0.Z) * k', '(m.C0.Y - m.C1.X) * k'];
    const X = ['(m.C1.Z - m.C2.Y) * k', 'v', '(m.C0.Y + m.C1.X) * k', '(m.C2.X + m.C0.Z) * k'];
    const Y = ['(m.C2.X - m.C0.Z) * k', '(m.C0.Y + m.C1.X) * k', 'v', '(m.C1.Z + m.C2.Y) * k'];
    const Z = ['(m.C0.Y - m.C1.X) * k', '(m.C2.X + m.C0.Z) * k', '(m.C1.Z + m.C2.Y) * k', 'v'];
    const sel = L => g.math(`i == 0 ? ${L[0]} : i == 1 ? ${L[1]} : i == 2 ? ${L[2]} : ${L[3]}`, I);
    return g.make('Quat', { X: sel(X), Y: sel(Y), Z: sel(Z), W: sel(W) });
  };
  t.fn('FromMat3', { static: true, ret: 'Quat', params: [['m', 'Mat3']], doc: 'The rotation of a 3x3 rotation matrix (orthonormal, no scale).' }, g => fromMat(g, g.arg('m')));
  t.fn('LookRotation', { static: true, ret: 'Quat', params: [['forward', 'Vec3'], ['up', 'Vec3']], doc: 'The rotation that turns -Z to `forward` and keeps Y as close to `up` as it can.' }, g => {
    const c2 = g.call('Core.Vec3.Scaled', { receiver: g.call('Core.Vec3.Normalized', { receiver: g.arg('forward') }), k: '-1.0f' });
    const c0 = g.call('Core.Vec3.Normalized', { receiver: g.call('Core.Vec3.Cross', { receiver: g.arg('up'), b: c2 }) });
    const c1 = g.call('Core.Vec3.Cross', { receiver: c2, b: c0 });
    return fromMat(g, g.make('Mat3', { C0: c0, C1: c1, C2: c2 }));
  });
  t.fn('FromTo', { static: true, ret: 'Quat', params: [['from', 'Vec3'], ['to', 'Vec3']], doc: 'The shortest rotation that turns the direction `from` to `to` (any length but zero); opposite directions turn half a turn about an axis perpendicular to `from`.' }, g => {
    const f = g.call('Core.Vec3.Normalized', { receiver: g.arg('from') });
    const to = g.call('Core.Vec3.Normalized', { receiver: g.arg('to') });
    const d = g.call('Core.Vec3.Dot', { receiver: f, b: to });
    const c = g.call('Core.Vec3.Cross', { receiver: f, b: to });
    const s = g.math('Sqrt((1.0f + d) * 2.0f)', { d });
    const general = g.make('Quat', { X: g.math('c.X / s', { c, s }), Y: g.math('c.Y / s', { c, s }), Z: g.math('c.Z / s', { c, s }), W: g.math('s * 0.5f', { s }) });
    // opposite: an axis perpendicular to `from`
    const ax1 = g.call('Core.Vec3.Cross', { receiver: g.get('Core.Vec3.UnitX'), b: f });
    const ax2 = g.call('Core.Vec3.Cross', { receiver: g.get('Core.Vec3.UnitY'), b: f });
    const axis = g.select(g.math('a.X * a.X + a.Y * a.Y + a.Z * a.Z > 0.000001f', { a: ax1 }), ax1, ax2);
    const nax = g.call('Core.Vec3.Normalized', { receiver: axis });
    const half = g.make('Quat', { X: g.math('a.X', { a: nax }), Y: g.math('a.Y', { a: nax }), Z: g.math('a.Z', { a: nax }), W: '0.0f' });
    const notOpp = g.select(g.math('d < -0.999999f', { d }), half, general);
    return g.select(g.math('d > 0.999999f', { d }), g.get('Core.Quat.Identity'), notOpp);
  });

  t.fn('Conjugate', { ret: 'Quat', doc: 'The vector part negated: the inverse rotation of a unit quaternion.' },
    g => g.make('Quat', { X: g.math('-q.X', me(g)), Y: g.math('-q.Y', me(g)), Z: g.math('-q.Z', me(g)), W: g.math('q.W', me(g)) }));
  t.fn('Inverse', { ret: 'Quat', doc: 'The inverse: the conjugate divided by the squared length (zero stays zero).' }, g => {
    const q = g.self();
    const k = g.math('d > 0.0f ? 1.0f / d : 0.0f', { d: g.math('q.X * q.X + q.Y * q.Y + q.Z * q.Z + q.W * q.W', { q }) });
    return g.make('Quat', { X: g.math('-q.X * k', { q, k }), Y: g.math('-q.Y * k', { q, k }), Z: g.math('-q.Z * k', { q, k }), W: g.math('q.W * k', { q, k }) });
  });
  t.fn('Dot', { ret: 'float', params: [['b', 'Quat']], doc: 'The dot product of the four components.' }, g => g.math('q.X * b.X + q.Y * b.Y + q.Z * b.Z + q.W * b.W', { q: g.self(), b: g.arg('b') }));
  t.fn('Length', { ret: 'float', doc: 'The length (1 for a rotation).' }, g => g.math('Sqrt(q.X * q.X + q.Y * q.Y + q.Z * q.Z + q.W * q.W)', me(g)));
  const norm = (g, q) => {
    const l = g.math('Sqrt(q.X * q.X + q.Y * q.Y + q.Z * q.Z + q.W * q.W)', { q });
    const k = g.math('l > 0.0f ? 1.0f / l : 0.0f', { l });
    const r = g.make('Quat', { X: g.math('q.X * k', { q, k }), Y: g.math('q.Y * k', { q, k }), Z: g.math('q.Z * k', { q, k }), W: g.math('q.W * k', { q, k }) });
    return g.select(g.math('l > 0.0f', { l }), r, g.get('Core.Quat.Identity'));
  };
  t.fn('Normalized', { ret: 'Quat', doc: 'Scaled to length 1; a zero quaternion gives Identity.' }, g => norm(g, g.self()));
  // shortest arc: b negated when the dot is negative
  const near = (g, a, b) => {
    const d = g.math('a.X * b.X + a.Y * b.Y + a.Z * b.Z + a.W * b.W', { a, b });
    const s = g.math('d < 0.0f ? -1.0f : 1.0f', { d });
    return { d, s, bb: g.make('Quat', Object.fromEntries(Q4.map(c => [c, g.math(`b.${c} * s`, { b, s })]))) };
  };
  t.fn('Nlerp', { ret: 'Quat', params: [['to', 'Quat'], ['t', 'float']], doc: 'The straight blend `t` of the way to `to` (the shorter way), normalized: cheaper than Slerp, not at an even speed.' }, g => {
    const a = g.self(), { bb } = near(g, a, g.arg('to'));
    const l = g.make('Quat', Object.fromEntries(Q4.map(c => [c, g.math(`a.${c} + (b.${c} - a.${c}) * t`, { a, b: bb, t: g.arg('t') })])));
    return norm(g, l);
  });
  t.fn('Slerp', { ret: 'Quat', params: [['to', 'Quat'], ['t', 'float']], doc: 'The rotation `t` of the way to `to` along the shortest arc at an even speed (spherical interpolation; very close rotations blend straight).' }, g => {
    const a = g.self(), { d, s, bb } = near(g, a, g.arg('to'));
    const cs = g.math('d * s', { d, s });
    const ang = g.math('Acos(Min(c, 1.0f))', { c: cs });
    const sa = g.math('Sin(x)', { x: ang });
    const tt = g.arg('t');
    const k0 = g.math('c > 0.9995f ? 1.0f - t : Sin((1.0f - t) * x) / n', { c: cs, t: tt, x: ang, n: sa });
    const k1 = g.math('c > 0.9995f ? t : Sin(t * x) / n', { c: cs, t: tt, x: ang, n: sa });
    const r = g.make('Quat', Object.fromEntries(Q4.map(c => [c, g.math(`a.${c} * k + b.${c} * j`, { a, b: bb, k: k0, j: k1 })])));
    return g.select(g.math('c > 0.9995f', { c: cs }), norm(g, r), r);
  });
  t.fn('AngleTo', { ret: 'float', params: [['b', 'Quat']], doc: 'The angle in radians of the rotation from this one to `b` (unit quaternions), 0 to PI.' },
    g => g.math('2.0f * Acos(Min(Abs(q.X * b.X + q.Y * b.Y + q.Z * b.Z + q.W * b.W), 1.0f))', { q: g.self(), b: g.arg('b') }));
  const toMat = (g, q, four) => {
    const P = {};
    const sq = { xx: 'q.X * q.X', yy: 'q.Y * q.Y', zz: 'q.Z * q.Z', xz: 'q.X * q.Z', xy: 'q.X * q.Y', yz: 'q.Y * q.Z', wx: 'q.W * q.X', wy: 'q.W * q.Y', wz: 'q.W * q.Z' };
    for (const k of Object.keys(sq)) P[k] = g.math(sq[k], { q });
    const cell = {
      '00': '1.0f - 2.0f * (yy + zz)', '01': '2.0f * (xy + wz)', '02': '2.0f * (xz - wy)',
      '10': '2.0f * (xy - wz)', '11': '1.0f - 2.0f * (xx + zz)', '12': '2.0f * (yz + wx)',
      '20': '2.0f * (xz + wy)', '21': '2.0f * (yz - wx)', '22': '1.0f - 2.0f * (xx + yy)',
    };
    return mk(g, four ? 4 : 3, (c, r) => {
      if (c === 3 || r === 3) return (c === r) ? '1.0f' : '0.0f';
      const ex = cell['' + c + r]; const ins = {};
      for (const k of Object.keys(P)) if (new RegExp('\\b' + k + '\\b').test(ex)) ins[k] = P[k];
      return g.math(ex, ins);
    });
  };
  t.fn('ToMat3', { ret: 'Mat3', doc: 'The rotation as a 3x3 matrix (this must be a unit quaternion).' }, g => toMat(g, g.self(), false));
  t.fn('ToMat4', { ret: 'Mat4', doc: 'The rotation as a 4x4 matrix (this must be a unit quaternion).' }, g => toMat(g, g.self(), true));
  t.fn('ToAxisAngle', { ret: 'float', outs: [['axis', 'Vec3']], doc: 'The angle in radians (0 to 2 PI) and the unit `axis` of the rotation; no rotation gives the X axis.' }, g => {
    const q = g.self();
    const w = g.math('Clamp(q.W, -1.0f, 1.0f)', { q });
    const s = g.math('Sqrt(1.0f - w * w)', { w });
    const k = g.math('s < 0.000001f', { s });
    const axis = g.make('Vec3', { X: g.math('k ? 1.0f : q.X / s', { k, q, s }), Y: g.math('k ? 0.0f : q.Y / s', { k, q, s }), Z: g.math('k ? 0.0f : q.Z / s', { k, q, s }) });
    g.ret(g.math('2.0f * Acos(w)', { w }), { axis });
  });
  t.fn('ToEuler', { ret: 'Vec3', doc: 'The angles FromEuler takes, as (pitch, yaw, roll) in radians; pitch is -PI/2 to PI/2 (at the poles roll is 0).' }, g => {
    const q = g.self();
    const m12 = g.math('2.0f * (q.Y * q.Z - q.W * q.X)', { q });
    const pole = g.math('Abs(s) > 0.99999f', { s: m12 });
    const pitch = g.math('Asin(Clamp(-s, -1.0f, 1.0f))', { s: m12 });
    const yaw = g.math('p ? Atan2(-2.0f * (q.X * q.Z - q.W * q.Y), 1.0f - 2.0f * (q.Y * q.Y + q.Z * q.Z)) : Atan2(2.0f * (q.X * q.Z + q.W * q.Y), 1.0f - 2.0f * (q.X * q.X + q.Y * q.Y))', { p: pole, q });
    const roll = g.math('p ? 0.0f : Atan2(2.0f * (q.X * q.Y + q.W * q.Z), 1.0f - 2.0f * (q.X * q.X + q.Z * q.Z))', { p: pole, q });
    return g.make('Vec3', { X: pitch, Y: yaw, Z: roll });
  });
  t.fn('ApproxEquals', { ret: 'bool', params: [['other', 'Quat'], ['epsilon', 'float', '0.00001f']], doc: 'True when the components are within `epsilon` (absolute) of the other\'s or of their negation (q and -q are the same rotation).' },
    g => g.math(`(${Q4.map(c => `Abs(q.${c} - o.${c}) <= e`).join(' && ')}) || (${Q4.map(c => `Abs(q.${c} + o.${c}) <= e`).join(' && ')})`, { q: g.self(), o: g.arg('other'), e: g.arg('epsilon') }));
  return t;
}
module.exports = { quat };
