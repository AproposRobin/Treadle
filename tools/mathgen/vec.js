'use strict';
const { TypeFile } = require('./lib');
const { VECS, lit, opts } = require('./common');

// Make N with one Math node per component: f(c) is the expression, inputs its pins.
function cw(g, N, C, f, inputs) {
  const fields = {};
  for (const c of C) fields[c] = g.math(f(c), inputs);
  return g.make(N, fields);
}
const sum = (C, f) => C.map(f).join(' + ');
const all = (C, f) => C.map(f).join(' && ');

function vector(N) {
  const { S, C } = VECS[N];
  const L = x => lit(S, x);
  const dim = C.length;
  const kind = S === 'float' ? 'float' : 'double';
  const t = new TypeFile(N, 'struct', ['namespace Core', 'attr CRepr',
    `doc ${JSON.stringify(`A ${dim}D vector of ${kind}s (${C.join(', ')}; ${dim * (S === 'float' ? 4 : 8)} bytes, laid out as in C): a position, a direction, a size. Every function is Pure.`)}`]);
  for (const c of C) t.field(c, S);

  const unit = (name, set, doc) => t.prop(name, { type: N, static: true, doc }, g => g.make(N, Object.fromEntries(C.map(c => [c, L(set(c))]))));
  unit('Zero', () => 0, 'All components 0.');
  unit('One', () => 1, 'All components 1.');
  for (const u of C) unit('Unit' + u, c => (c === u ? 1 : 0), `The unit vector along ${u}.`);

  t.ctor({ params: [['all', S]], doc: 'Every component set to `all`.' }, g => {
    for (const c of C) g.flow('Set', 'this.' + c, { value: g.arg('all') });
    g.ret();
  });

  // the vector primitive the Sheets compute on (SIMD-and-Vectors.md 2.1): Make it from the fields,
  // operate, Break it into the fields
  // Vec3 (12 bytes, packed) stays per component: a float3 around every operation repacks a loop-carried
  // Vec3 each pass (nbody-mathlib: 1.15x C as float3, 1.0x per component); Vec2 and Vec4 fill their vector
  const VEC = opts.vectors && dim !== 3;
  const P = kind + dim;
  const VX = x => `${P}(${C.map(c => `${x}.${c}`).join(', ')})`;
  const vmk = (g, expr, ins) => { const r = g.math(expr, ins); const br = g.brk(P, r); return g.make(N, Object.fromEntries(C.map((c, i) => [c, br('xyzw'[i])]))); };
  // component form f(c), or the vector expression vf
  const CW = (g, f, vf, ins) => (VEC && vf ? vmk(g, vf, ins) : cw(g, N, C, f, ins));
  const DOT = (x, y) => (VEC ? `Dot(${VX(x)}, ${VX(y)})` : sum(C, c => `${x}.${c} * ${y}.${c}`));

  // operators
  const ab = [['a', N], ['b', N]];
  const bin = (sym, word) => t.op(sym, { ret: N, params: ab, doc: `Component by component: ${word}.` },
    g => CW(g, c => `a.${c} ${sym} b.${c}`, `${VX('a')} ${sym} ${VX('b')}`, { a: g.arg('a'), b: g.arg('b') }));
  bin('+', 'the sum'); bin('-', 'the difference'); bin('*', 'the product'); bin('/', 'the quotient');
  t.op('neg', { ret: N, params: [['a', N]], doc: 'Every component negated.' }, g => CW(g, c => `-a.${c}`, `-${VX('a')}`, { a: g.arg('a') }));
  if (opts.overloads) {
    t.op('*', { ret: N, params: [['a', N], ['k', S]], doc: 'Every component times `k`.' }, g => CW(g, c => `a.${c} * k`, `${VX('a')} * k`, { a: g.arg('a'), k: g.arg('k') }));
    t.op('*', { ret: N, params: [['k', S], ['a', N]], doc: '`k` times every component.' }, g => CW(g, c => `k * a.${c}`, `k * ${VX('a')}`, { a: g.arg('a'), k: g.arg('k') }));
    t.op('/', { ret: N, params: [['a', N], ['k', S]], doc: 'Every component divided by `k`.' }, g => CW(g, c => `a.${c} / k`, `${VX('a')} / k`, { a: g.arg('a'), k: g.arg('k') }));
  }
  t.op('==', { ret: 'bool', params: ab, doc: 'True when every component is equal (exact).' },
    g => g.math(all(C, c => `a.${c} == b.${c}`), { a: g.arg('a'), b: g.arg('b') }));
  t.op('!=', { ret: 'bool', params: ab, doc: 'True when any component differs (exact).' },
    g => g.math(C.map(c => `a.${c} != b.${c}`).join(' || '), { a: g.arg('a'), b: g.arg('b') }));

  const me = g => ({ v: g.self() });
  t.fn('Scaled', { ret: N, params: [['k', S]], doc: 'Every component times `k` (the same as the operator `*` with a number).' },
    g => CW(g, c => `v.${c} * k`, `${VX('v')} * k`, { v: g.self(), k: g.arg('k') }));
  t.fn('Dot', { ret: S, params: [['b', N]], doc: 'The dot product.' }, g => g.math(DOT('v', 'b'), { v: g.self(), b: g.arg('b') }));
  t.fn('LengthSquared', { ret: S, doc: 'The squared length (no square root).' }, g => g.math(DOT('v', 'v'), me(g)));
  t.fn('Length', { ret: S, doc: 'The length.' }, g => g.math(`Sqrt(${DOT('v', 'v')})`, me(g)));
  const diff = c => `(v.${c} - b.${c}) * (v.${c} - b.${c})`;
  const dist2 = VEC ? `Dot(${VX('v')} - ${VX('b')}, ${VX('v')} - ${VX('b')})` : sum(C, diff);
  t.fn('DistanceSquared', { ret: S, params: [['b', N]], doc: 'The squared distance to `b`.' }, g => g.math(dist2, { v: g.self(), b: g.arg('b') }));
  t.fn('Distance', { ret: S, params: [['b', N]], doc: 'The distance to `b`.' }, g => g.math(`Sqrt(${dist2})`, { v: g.self(), b: g.arg('b') }));
  t.fn('Normalized', { ret: N, doc: 'The vector scaled to length 1; a zero vector gives zero.' }, g => {
    const v = g.self();
    const len = g.math(`Sqrt(${DOT('v', 'v')})`, { v });
    const inv = g.math(`l > ${L(0)} ? ${L(1)} / l : ${L(0)}`, { l: len });
    return CW(g, c => `v.${c} * k`, `${VX('v')} * k`, { v, k: inv });
  });
  t.fn('Lerp', { ret: N, params: [['to', N], ['t', S]], doc: 'The point `t` of the way to `to`: this at 0, `to` at 1 (t is not clamped).' },
    g => CW(g, c => `v.${c} + (b.${c} - v.${c}) * t`, `${VX('v')} + (${VX('b')} - ${VX('v')}) * t`, { v: g.self(), b: g.arg('to'), t: g.arg('t') }));
  t.fn('Min', { ret: N, params: [['b', N]], doc: 'The smaller of each pair of components.' }, g => cw(g, N, C, c => `Min(v.${c}, b.${c})`, { v: g.self(), b: g.arg('b') }));
  t.fn('Max', { ret: N, params: [['b', N]], doc: 'The larger of each pair of components.' }, g => cw(g, N, C, c => `Max(v.${c}, b.${c})`, { v: g.self(), b: g.arg('b') }));
  t.fn('Clamp', { ret: N, params: [['lo', N], ['hi', N]], doc: 'Each component limited to the range `lo` to `hi`.' },
    g => cw(g, N, C, c => `Clamp(v.${c}, lo.${c}, hi.${c})`, { v: g.self(), lo: g.arg('lo'), hi: g.arg('hi') }));
  for (const [f, d] of [['Abs', 'The absolute value'], ['Floor', 'The largest whole number not above'], ['Ceil', 'The smallest whole number not below'], ['Round', 'The nearest whole number (halves away from zero) to']])
    t.fn(f, { ret: N, doc: `${d} each component.` }, g => CW(g, c => `${f}(v.${c})`, `${f}(${VX('v')})`, me(g)));
  t.fn('Reflect', { ret: N, params: [['normal', N]], doc: 'The vector mirrored off a surface with this unit `normal`: v - 2 Dot(v, n) n.' }, g => {
    const v = g.self(), n = g.arg('normal');
    const k = g.math(`${L(2)} * (${DOT('v', 'n')})`, { v, n });
    return CW(g, c => `v.${c} - n.${c} * k`, `${VX('v')} - ${VX('n')} * k`, { v, n, k });
  });
  t.fn('ProjectOnto', { ret: N, params: [['b', N]], doc: 'The part of this vector along `b`; a zero `b` gives zero.' }, g => {
    const v = g.self(), b = g.arg('b');
    const bb = g.math(DOT('b', 'b'), { b });
    const k = g.math(`bb > ${L(0)} ? (${DOT('v', 'b')}) / bb : ${L(0)}`, { v, b, bb });
    return CW(g, c => `b.${c} * k`, `${VX('b')} * k`, { b, k });
  });
  t.fn('AngleTo', { ret: S, params: [['b', N]], doc: 'The angle to `b` in radians, 0 to PI; 0 when either is zero.' }, g => {
    const v = g.self(), b = g.arg('b');
    const den = g.math(`Sqrt((${DOT('v', 'v')}) * (${DOT('b', 'b')}))`, { v, b });
    return g.math(`d > ${L(0)} ? Acos(Clamp((${DOT('v', 'b')}) / d, ${L(-1)}, ${L(1)})) : ${L(0)}`, { v, b, d: den });
  });
  t.fn('IsFinite', { ret: 'bool', doc: 'True when no component is infinite or NaN.' }, g => g.math(all(C, c => `v.${c} - v.${c} == ${L(0)}`), me(g)));
  t.fn('ApproxEquals', { ret: 'bool', params: [['other', N], ['epsilon', S, S === 'float' ? '0.00001f' : '0.00001']], doc: 'True when every component is within `epsilon` of the other\'s (absolute).' },
    g => g.math(all(C, c => `Abs(v.${c} - o.${c}) <= e`), { v: g.self(), o: g.arg('other'), e: g.arg('epsilon') }));

  if (dim === 2) {
    t.fn('Perpendicular', { ret: N, doc: 'The vector turned a quarter left: (-Y, X).' }, g => g.make(N, { X: g.math('-v.Y', me(g)), Y: g.math('v.X', me(g)) }));
    t.fn('Cross', { ret: S, params: [['b', N]], doc: 'The 2D cross product X * b.Y - Y * b.X (the Z of the 3D one): positive when `b` is to the left.' },
      g => g.math('v.X * b.Y - v.Y * b.X', { v: g.self(), b: g.arg('b') }));
    t.fn('Angle', { ret: S, doc: 'The direction in radians, Atan2(Y, X): -PI to PI, 0 along +X.' }, g => g.math('Atan2(v.Y, v.X)', me(g)));
    t.fn('FromAngle', { ret: N, static: true, params: [['angle', S]], doc: 'The unit vector at `angle` radians from +X: (Cos, Sin).' },
      g => g.make(N, { X: g.math('Cos(a)', { a: g.arg('angle') }), Y: g.math('Sin(a)', { a: g.arg('angle') }) }));
  }
  if (dim === 3) {
    t.fn('Cross', { ret: N, params: [['b', N]], doc: 'The cross product (right-handed): perpendicular to both.' }, g => {
      const i = { v: g.self(), b: g.arg('b') };
      if (VEC)
        return vmk(g, `Cross(${VX('v')}, ${VX('b')})`, i);
      return g.make(N, { X: g.math('v.Y * b.Z - v.Z * b.Y', i), Y: g.math('v.Z * b.X - v.X * b.Z', i), Z: g.math('v.X * b.Y - v.Y * b.X', i) });
    });
    const two = N === 'Vec3' ? 'Vec2' : 'Vec2d';
    t.fn('XY', { ret: two, doc: 'X and Y as a 2D vector.' }, g => g.make(two, { X: g.math('v.X', me(g)), Y: g.math('v.Y', me(g)) }));
  }
  if (dim === 4) {
    const three = N === 'Vec4' ? 'Vec3' : 'Vec3d';
    t.fn('XYZ', { ret: three, doc: 'X, Y and Z as a 3D vector.' }, g => cw(g, three, ['X', 'Y', 'Z'], c => `v.${c}`, me(g)));
    t.fn('FromVec3', { ret: N, static: true, params: [['v', three], ['w', S]], doc: 'X, Y, Z from `v` and W from `w`.' },
      g => g.make(N, { X: g.math('v.X', { v: g.arg('v') }), Y: g.math('v.Y', { v: g.arg('v') }), Z: g.math('v.Z', { v: g.arg('v') }), W: g.arg('w') }));
  }
  if (opts.vectors) {
    t.fn('ToVector', { ret: P, doc: `The components as a ${P}${dim === 3 ? ' (the 4th lane 0)' : ''}: the vector primitive for SIMD work.` }, g => g.math(VX('v'), me(g)));
    t.fn('FromVector', { ret: N, static: true, params: [['value', P]], doc: `The lanes of a ${P} as a ${N}.` }, g => {
      const br = g.brk(P, g.arg('value'));
      return g.make(N, Object.fromEntries(C.map((c, i) => [c, br('xyzw'[i])])));
    });
  }
  return t;
}

module.exports = { vector, cw, sum, all };
