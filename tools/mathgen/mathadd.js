'use strict';
// The scalar Math additions of SIMD-and-Vectors.md 2.2 (appended to Core.Math).
const fs = require('fs');
const path = require('path');
const { TypeFile } = require('./lib');

function mathAdditions() {
  const t = new TypeFile('Math', 'class', []);
  t.code = 'q';
  t.field('Tau', 'double', ['static', 'const', 'init 6.283185307179586', 'doc "A full turn in radians: 2 PI."']);
  for (const S of ['double', 'float']) {
    const f = S === 'float' ? 'f' : '';
    const one = [
      ['Tan', 'The tangent of an angle in radians.'],
      ['Asin', 'The arc sine in radians, -PI/2 to PI/2 (NaN outside -1 to 1).'],
      ['Acos', 'The arc cosine in radians, 0 to PI (NaN outside -1 to 1).'],
      ['Atan', 'The arc tangent in radians, -PI/2 to PI/2.'],
    ];
    for (const [n, d] of one)
      t.fn(n, { static: true, ret: S, attrs: ['Intrinsic Math.' + n], doc: d, params: [['x', S]] });
    t.fn('Atan2', { static: true, ret: S, attrs: ['Intrinsic Math.Atan2'], doc: 'The angle of the point (x, y) from +X in radians, -PI to PI.', params: [['y', S], ['x', S]] });
    t.fn('Fma', { static: true, ret: S, attrs: ['Intrinsic Math.Fma'], doc: 'a * b + c with one rounding (fused multiply-add).', params: [['a', S], ['b', S], ['c', S]] });
    t.fn('CopySign', { static: true, ret: S, attrs: ['Intrinsic Math.CopySign'], doc: 'The size of `x` with the sign of `sign`.', params: [['x', S], ['sign', S]] });
    t.fn('Radians', { static: true, ret: S, doc: 'Degrees converted to radians.', params: [['degrees', S]] },
      g => g.math(`d * ${S === 'float' ? '0.0174532925f' : '0.017453292519943295'}`, { d: g.arg('degrees') }));
    t.fn('Degrees', { static: true, ret: S, doc: 'Radians converted to degrees.', params: [['radians', S]] },
      g => g.math(`r * ${S === 'float' ? '57.2957795f' : '57.29577951308232'}`, { r: g.arg('radians') }));
    t.fn('SmoothStep', { static: true, ret: S, doc: 'A smooth step from 0 (x at or below e0) to 1 (x at or above e1): t * t * (3 - 2 t) with t clamped.', params: [['e0', S], ['e1', S], ['x', S]] }, g => {
      const tt = g.math(`Clamp((x - a) / (b - a), 0.0${f}, 1.0${f})`, { x: g.arg('x'), a: g.arg('e0'), b: g.arg('e1') });
      return g.math(`t * t * (3.0${f} - 2.0${f} * t)`, { t: tt });
    });
  }
  const base = fs.readFileSync(path.join(__dirname, 'Math.base.treadle'), 'utf8');
  const extra = t.text().split('\n').slice(2).join('\n');
  return base + extra;
}
module.exports = { mathAdditions };
