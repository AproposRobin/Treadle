'use strict';
// A dual expression: builds the Treadle nodes (t(g) -> pin) and the C reference (c -> string), and knows its type.

// struct layouts (leaf order = C print order)
const STRUCT = {
  Vec2: [['X', 'float'], ['Y', 'float']],
  Vec3: [['X', 'float'], ['Y', 'float'], ['Z', 'float']],
  Vec4: [['X', 'float'], ['Y', 'float'], ['Z', 'float'], ['W', 'float']],
  Vec2d: [['X', 'double'], ['Y', 'double']],
  Vec3d: [['X', 'double'], ['Y', 'double'], ['Z', 'double']],
  Vec4d: [['X', 'double'], ['Y', 'double'], ['Z', 'double'], ['W', 'double']],
  Quat: [['X', 'float'], ['Y', 'float'], ['Z', 'float'], ['W', 'float']],
  Mat3: [['C0', 'Vec3'], ['C1', 'Vec3'], ['C2', 'Vec3']],
  Mat4: [['C0', 'Vec4'], ['C1', 'Vec4'], ['C2', 'Vec4'], ['C3', 'Vec4']],
  Color: [['R', 'float'], ['G', 'float'], ['B', 'float'], ['A', 'float']],
  Color32: [['R', 'uint8'], ['G', 'uint8'], ['B', 'uint8'], ['A', 'uint8']],
  Rect: [['X', 'float'], ['Y', 'float'], ['Width', 'float'], ['Height', 'float']],
  RectI: [['X', 'int32'], ['Y', 'int32'], ['Width', 'int32'], ['Height', 'int32']],
  AABB: [['Min', 'Vec3'], ['Max', 'Vec3']],
  Plane: [['Normal', 'Vec3'], ['D', 'float']],
  Ray: [['Origin', 'Vec3'], ['Direction', 'Vec3']],
  Transform: [['Translation', 'Vec3'], ['Rotation', 'Quat'], ['Scale', 'Vec3']],
};
const CTYPE = { Vec2: 'v2', Vec3: 'v3', Vec4: 'v4', Vec2d: 'v2', Vec3d: 'v3', Vec4d: 'v4', Quat: 'qt', Mat3: 'm3', Mat4: 'm4', Color: 'col', Color32: 'col32',
  Rect: 'rct', RectI: 'rcti', AABB: 'box', Plane: 'pln', Ray: 'ray', Transform: 'xf', float: 'double', double: 'double', bool: 'int', int: 'long long', int32: 'int', uint32: 'unsigned', uint8: 'int' };
const PRINT = { Vec2: 'Pv2', Vec3: 'Pv3', Vec4: 'Pv4', Vec2d: 'Pv2', Vec3d: 'Pv3', Vec4d: 'Pv4', Quat: 'Pq', Mat3: 'Pm3', Mat4: 'Pm4', Color: 'Pc', Color32: 'Pc32',
  Rect: 'Pr', RectI: 'Pri', AABB: 'Pbox', Plane: 'Ppl', Ray: 'Pray', Transform: 'Pxf', float: 'Pf', double: 'Pf', bool: 'Pb', int: 'Pi', int32: 'Pi', uint32: 'Pi', uint8: 'Pi' };
const SCALAR = new Set(['float', 'double', 'bool', 'int', 'int32', 'uint32', 'uint8']);

function leaves(type, prefix) {
  if (SCALAR.has(type)) return [[prefix, type]];
  const out = [];
  for (const [f, ft] of STRUCT[type]) out.push(...leaves(ft, prefix ? prefix + '.' + f : f));
  return out;
}

function numLit(type, x) {
  if (type === 'bool') return x ? 'true' : 'false';
  if (type === 'float' || type === 'double') {
    let s = Number.isInteger(x) && Math.abs(x) < 1e15 ? String(x) + '.0' : String(type === 'float' ? Math.fround(x) : x);
    if (s === '-0.0' || Object.is(x, -0)) s = '-0.0';
    if (!/[.eE]/.test(s)) s += '.0';
    if (/e/.test(s) && !/\./.test(s.split('e')[0])) s = s.replace('e', '.0e');
    return type === 'float' ? s + 'f' : s;
  }
  return String(Math.round(x));
}

// a Make tree of `type` from leaf values (in leaf order)
function makeLit(g, type, vals, pos) {
  pos = pos || { i: 0 };
  if (SCALAR.has(type)) return numLit(type, vals[pos.i++]);
  const fields = {};
  for (const [f, ft] of STRUCT[type]) fields[f] = makeLit(g, ft, vals, pos);
  return g.make('Core.' + type, fields);
}

class X {
  constructor(type, t, c) { this.type = type; this.t = t; this.c = c; this._pin = null; this._g = null; }
  pin(g) { if (this._g !== g) { this._g = g; this._pin = this.t(g); } return this._pin; }
}
// literal of a type from numbers
function lit(type, ...vals) {
  const cvals = vals.map(v => (typeof v === 'boolean' ? (v ? 1 : 0) : v));
  const c = SCALAR.has(type) ? `((${CTYPE[type]})(${cvals[0]}))` : `((${CTYPE[type]}){${cvals.map(v => `${v}`).join(', ')}})`;
  return new X(type, g => makeLit(g, type, vals), c);
}
const f = x => lit('float', x);
const d = x => lit('double', x);
const i = x => lit('int', x);
const v2 = (x, y) => lit('Vec2', x, y);
const v3 = (x, y, z) => lit('Vec3', x, y, z);
const v4 = (x, y, z, w) => lit('Vec4', x, y, z, w);
const q = (x, y, z, w) => lit('Quat', x, y, z, w);

module.exports = { STRUCT, CTYPE, PRINT, SCALAR, leaves, numLit, makeLit, X, lit, f, d, i, v2, v3, v4, q };
