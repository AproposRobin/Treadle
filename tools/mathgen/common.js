'use strict';
// Shared helpers for the math library generator.
const VECS = {
  Vec2: { S: 'float', C: ['X', 'Y'] },
  Vec3: { S: 'float', C: ['X', 'Y', 'Z'] },
  Vec4: { S: 'float', C: ['X', 'Y', 'Z', 'W'] },
  Vec2d: { S: 'double', C: ['X', 'Y'] },
  Vec3d: { S: 'double', C: ['X', 'Y', 'Z'] },
  Vec4d: { S: 'double', C: ['X', 'Y', 'Z', 'W'] },
};
// A literal of the element type: 1 -> "1.0f" (float) or "1.0" (double).
function lit(S, x) {
  let s = String(x);
  if (!/[.eE]/.test(s)) s += '.0';
  return S === 'float' ? s + 'f' : s;
}
// Options set by the driver: whether the compiler picks operators by both sides' types.
const opts = { overloads: false, vectors: false };
module.exports = { VECS, lit, opts };
