'use strict';
const { TypeFile } = require('./lib');
const { VECS } = require('./common');

// String.Append overloads for the math types (SIMD-and-Vectors.md 2.2, "Formatting").
function mathFormat() {
  const t = new TypeFile('MathFormat', 'extension', ['namespace Core', 'extends Core.String',
    'doc "String.Append for the math types: vectors, quaternions and colours as (1, 2, 3), matrices as their rows [(..), (..)], each number as Append writes it. AppendF uses these for its arguments."']);
  // parts: strings (text) or [pinFn, type]
  const app = (name, type, doc, build) => t.fn('Append', { pure: false, params: [['value', type]], doc }, g => {
    const parts = build(g, g.arg('value'));
    for (const p of parts) {
      if (typeof p === 'string') g.flow('Call', 'this.Append(StringView)', { text: JSON.stringify(p) });
      else g.flow('Call', `this.Append(${p[1]})`, { value: p[0] });
    }
    g.ret();
  });
  const list = (items, open, close) => {
    const out = [open];
    items.forEach((it, i) => { if (i) out.push(', '); if (Array.isArray(it[0])) out.push(...it[0]); else out.push(it); });
    out.push(close);
    // merge adjacent texts
    const m = [];
    for (const p of out) { if (typeof p === 'string' && typeof m[m.length - 1] === 'string') m[m.length - 1] += p; else m.push(p); }
    return m;
  };
  for (const N of Object.keys(VECS)) {
    const { S, C } = VECS[N];
    app(N, N, `Appends the vector as (${C.join(', ')}).`, (g, v) => { const b = g.brk('Core.' + N, v); return list(C.map(c => [b(c), S]), '(', ')'); });
  }
  const R = ['X', 'Y', 'Z', 'W'];
  for (const n of [3, 4]) {
    const M = 'Mat' + n, V = 'Vec' + n;
    app(M, M, 'Appends the matrix row by row: [(row 0), (row 1), ...].', (g, v) => {
      const b = g.brk('Core.' + M, v);
      const cols = [...Array(n).keys()].map(c => g.brk('Core.' + V, b('C' + c)));
      return list([...Array(n).keys()].map(r => [list(cols.map(col => [col(R[r]), 'float']), '(', ')')]), '[', ']');
    });
  }
  app('Quat', 'Quat', 'Appends the quaternion as (X, Y, Z, W).', (g, v) => { const b = g.brk('Core.Quat', v); return list(R.map(c => [b(c), 'float']), '(', ')'); });
  app('Color', 'Color', 'Appends the colour as (R, G, B, A).', (g, v) => { const b = g.brk('Core.Color', v); return list(['R', 'G', 'B', 'A'].map(c => [b(c), 'float']), '(', ')'); });
  app('Color32', 'Color32', 'Appends the colour as (R, G, B, A), each 0 to 255.', (g, v) => { const b = g.brk('Core.Color32', v); return list(['R', 'G', 'B', 'A'].map(c => [g.cast('int', b(c)), 'int']), '(', ')'); });
  app('Rect', 'Rect', 'Appends the rectangle as (X, Y, Width, Height).', (g, v) => { const b = g.brk('Core.Rect', v); return list(['X', 'Y', 'Width', 'Height'].map(c => [b(c), 'float']), '(', ')'); });
  app('RectI', 'RectI', 'Appends the rectangle as (X, Y, Width, Height).', (g, v) => { const b = g.brk('Core.RectI', v); return list(['X', 'Y', 'Width', 'Height'].map(c => [g.cast('int', b(c)), 'int']), '(', ')'); });
  app('AABB', 'AABB', 'Appends the box as [(Min), (Max)].', (g, v) => { const b = g.brk('Core.AABB', v); return list([[b('Min'), 'Vec3'], [b('Max'), 'Vec3']], '[', ']'); });
  app('Plane', 'Plane', 'Appends the plane as (Normal.X, Normal.Y, Normal.Z, D).', (g, v) => {
    const b = g.brk('Core.Plane', v); const n = g.brk('Core.Vec3', b('Normal'));
    return list([[n('X'), 'float'], [n('Y'), 'float'], [n('Z'), 'float'], [b('D'), 'float']], '(', ')');
  });
  app('Ray', 'Ray', 'Appends the ray as [(Origin), (Direction)].', (g, v) => { const b = g.brk('Core.Ray', v); return list([[b('Origin'), 'Vec3'], [b('Direction'), 'Vec3']], '[', ']'); });
  app('Transform', 'Transform', 'Appends the transform as [(Translation), (Rotation), (Scale)].', (g, v) => {
    const b = g.brk('Core.Transform', v); return list([[b('Translation'), 'Vec3'], [b('Rotation'), 'Quat'], [b('Scale'), 'Vec3']], '[', ']');
  });
  return t;
}
module.exports = { mathFormat };
