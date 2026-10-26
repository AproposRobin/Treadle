'use strict';
const { TypeFile } = require('./lib');
const { opts } = require('./common');

const R = ['X', 'Y', 'Z', 'W'];
const E = (m, c, r) => `${m}.C${c}.${R[r]}`; // element at row r, column c

// Make a matrix of n columns from cell(c, r) -> a pin or a literal.
function mk(g, n, cell) {
  const M = n === 3 ? 'Mat3' : 'Mat4', V = n === 3 ? 'Vec3' : 'Vec4';
  const cols = {};
  for (let c = 0; c < n; c++) {
    const f = {};
    for (let r = 0; r < n; r++) f[R[r]] = cell(c, r);
    cols['C' + c] = g.make(V, f);
  }
  return g.make(M, cols);
}
const lit = x => { let s = String(x); if (!/[.eE]/.test(s)) s += '.0'; return s + 'f'; };

// determinant expression of the k x k matrix given by cell(i, j) strings (Laplace on the first index)
function detExpr(cells, k) {
  if (k === 1) return cells[0][0];
  if (k === 2) return `${cells[0][0]} * ${cells[1][1]} - ${cells[1][0]} * ${cells[0][1]}`;
  const terms = [];
  for (let j = 0; j < k; j++) {
    const sub = [];
    for (let i = 1; i < k; i++) sub.push(cells[i].filter((_, jj) => jj !== j));
    terms.push(`${j % 2 ? '-' : '+'} ${cells[0][j]} * (${detExpr(sub, k - 1)})`);
  }
  return terms.join(' ').replace(/^\+ /, '');
}

// 4x4 inverse through shared 2x2 sub-determinants; a[i][j] = column i, component j.
function inverse4(g, m, singularZero) {
  const a = (i, j) => E('m', i, j);
  const S = {
    s0: `${a(0, 0)} * ${a(1, 1)} - ${a(1, 0)} * ${a(0, 1)}`,
    s1: `${a(0, 0)} * ${a(1, 2)} - ${a(1, 0)} * ${a(0, 2)}`,
    s2: `${a(0, 0)} * ${a(1, 3)} - ${a(1, 0)} * ${a(0, 3)}`,
    s3: `${a(0, 1)} * ${a(1, 2)} - ${a(1, 1)} * ${a(0, 2)}`,
    s4: `${a(0, 1)} * ${a(1, 3)} - ${a(1, 1)} * ${a(0, 3)}`,
    s5: `${a(0, 2)} * ${a(1, 3)} - ${a(1, 2)} * ${a(0, 3)}`,
    c5: `${a(2, 2)} * ${a(3, 3)} - ${a(3, 2)} * ${a(2, 3)}`,
    c4: `${a(2, 1)} * ${a(3, 3)} - ${a(3, 1)} * ${a(2, 3)}`,
    c3: `${a(2, 1)} * ${a(3, 2)} - ${a(3, 1)} * ${a(2, 2)}`,
    c2: `${a(2, 0)} * ${a(3, 3)} - ${a(3, 0)} * ${a(2, 3)}`,
    c1: `${a(2, 0)} * ${a(3, 2)} - ${a(3, 0)} * ${a(2, 2)}`,
    c0: `${a(2, 0)} * ${a(3, 1)} - ${a(3, 0)} * ${a(2, 1)}`,
  };
  const P = {};
  for (const k of Object.keys(S)) P[k] = g.math(S[k], { m });
  const det = g.math('s0 * c5 - s1 * c4 + s2 * c3 + s3 * c2 - s4 * c1 + s5 * c0', P);
  const inv = g.math(singularZero ? 'd != 0.0f ? 1.0f / d : 0.0f' : '1.0f / d', { d: det });
  const B = {
    '00': `${a(1, 1)} * c5 - ${a(1, 2)} * c4 + ${a(1, 3)} * c3`,
    '01': `-${a(0, 1)} * c5 + ${a(0, 2)} * c4 - ${a(0, 3)} * c3`,
    '02': `${a(3, 1)} * s5 - ${a(3, 2)} * s4 + ${a(3, 3)} * s3`,
    '03': `-${a(2, 1)} * s5 + ${a(2, 2)} * s4 - ${a(2, 3)} * s3`,
    '10': `-${a(1, 0)} * c5 + ${a(1, 2)} * c2 - ${a(1, 3)} * c1`,
    '11': `${a(0, 0)} * c5 - ${a(0, 2)} * c2 + ${a(0, 3)} * c1`,
    '12': `-${a(3, 0)} * s5 + ${a(3, 2)} * s2 - ${a(3, 3)} * s1`,
    '13': `${a(2, 0)} * s5 - ${a(2, 2)} * s2 + ${a(2, 3)} * s1`,
    '20': `${a(1, 0)} * c4 - ${a(1, 1)} * c2 + ${a(1, 3)} * c0`,
    '21': `-${a(0, 0)} * c4 + ${a(0, 1)} * c2 - ${a(0, 3)} * c0`,
    '22': `${a(3, 0)} * s4 - ${a(3, 1)} * s2 + ${a(3, 3)} * s0`,
    '23': `-${a(2, 0)} * s4 + ${a(2, 1)} * s2 - ${a(2, 3)} * s0`,
    '30': `-${a(1, 0)} * c3 + ${a(1, 1)} * c1 - ${a(1, 2)} * c0`,
    '31': `${a(0, 0)} * c3 - ${a(0, 1)} * c1 + ${a(0, 2)} * c0`,
    '32': `-${a(3, 0)} * s3 + ${a(3, 1)} * s1 - ${a(3, 2)} * s0`,
    '33': `${a(2, 0)} * s3 - ${a(2, 1)} * s1 + ${a(2, 2)} * s0`,
  };
  const res = mk(g, 4, (c, r) => {
    const ex = B['' + c + r];
    const ins = { m, k: inv };
    for (const k of Object.keys(P)) if (new RegExp('\\b' + k + '\\b').test(ex)) ins[k] = P[k];
    return g.math(`(${ex}) * k`, ins);
  });
  return { res, det };
}

// 3x3 inverse by cofactors: inv[c][r] = cofactor(r, c) / det with a[i][j] = column i, component j.
function inverse3(g, m, singularZero) {
  const a = (i, j) => E('m', i, j);
  const cof = (i, j) => { // cofactor of a[i][j]
    const ii = [0, 1, 2].filter(x => x !== i), jj = [0, 1, 2].filter(x => x !== j);
    const ex = `${a(ii[0], jj[0])} * ${a(ii[1], jj[1])} - ${a(ii[1], jj[0])} * ${a(ii[0], jj[1])}`;
    return ((i + j) % 2) ? `-(${ex})` : `(${ex})`;
  };
  const det = g.math(`${a(0, 0)} * ${cof(0, 0)} + ${a(0, 1)} * ${cof(0, 1)} + ${a(0, 2)} * ${cof(0, 2)}`, { m });
  const inv = g.math(singularZero ? 'd != 0.0f ? 1.0f / d : 0.0f' : '1.0f / d', { d: det });
  // (A^-1)[i][j] = cof(j, i) / det
  const res = mk(g, 3, (c, r) => g.math(`${cof(r, c)} * k`, { m, k: inv }));
  return { res, det };
}

function matrix(n) {
  const M = n === 3 ? 'Mat3' : 'Mat4', V = n === 3 ? 'Vec3' : 'Vec4';
  const t = new TypeFile(M, 'struct', ['namespace Core', 'attr CRepr',
    `doc ${JSON.stringify(`A ${n}x${n} matrix of floats in columns C0..C${n - 1} (column-major, ${n * n * 4} bytes, as GLSL and Vulkan lay it out): M * v transforms a column vector. Every function is Pure.`)}`]);
  for (let c = 0; c < n; c++) t.field('C' + c, V, [`doc "Column ${c}."`]);
  const idx = [...Array(n).keys()];
  const me = g => ({ m: g.self() });

  t.prop('Identity', { type: M, static: true, doc: 'Ones on the diagonal, zeros elsewhere.' }, g => mk(g, n, (c, r) => lit(c === r ? 1 : 0)));
  t.prop('Zero', { type: M, static: true, doc: 'All zeros.' }, g => mk(g, n, () => lit(0)));

  const pick = (list, v) => list.reduceRight((acc, e, i) => (acc === null ? e : `${v} == ${i} ? ${e} : ${acc}`), null);
  t.fn('Get', { ret: 'float', params: [['row', 'int'], ['col', 'int']], doc: 'The element at `row`, `col` (0-based; an index out of range gives the last one).' },
    g => g.math(pick(idx.map(c => `(${pick(idx.map(r => E('m', c, r)), 'r')})`), 'c'), { m: g.self(), r: g.arg('row'), c: g.arg('col') }));
  t.fn('Column', { ret: V, params: [['index', 'int']], doc: 'Column `index` (0-based; out of range gives the last one).' },
    g => { const ins = { m: g.self(), i: g.arg('index') }; return g.make(V, Object.fromEntries(idx.map(r => [R[r], g.math(pick(idx.map(c => E('m', c, r)), 'i'), ins)]))); });
  t.fn('Row', { ret: V, params: [['index', 'int']], doc: 'Row `index` (0-based; out of range gives the last one).' },
    g => { const ins = { m: g.self(), i: g.arg('index') }; return g.make(V, Object.fromEntries(idx.map(c => [R[c], g.math(pick(idx.map(r => E('m', c, r)), 'i'), ins)]))); });

  const ab = [['a', M], ['b', M]];
  const mul = (g, a, b) => mk(g, n, (c, r) => g.math(idx.map(k => `${E('a', k, r)} * ${E('b', c, k)}`).join(' + '), { a, b }));
  t.op('*', { ret: M, params: ab, doc: 'The matrix product: (a * b) * v is a * (b * v), b applied first.' }, g => mul(g, g.arg('a'), g.arg('b')));
  t.op('+', { ret: M, params: ab, doc: 'Element by element: the sum.' }, g => mk(g, n, (c, r) => g.math(`${E('a', c, r)} + ${E('b', c, r)}`, { a: g.arg('a'), b: g.arg('b') })));
  t.op('-', { ret: M, params: ab, doc: 'Element by element: the difference.' }, g => mk(g, n, (c, r) => g.math(`${E('a', c, r)} - ${E('b', c, r)}`, { a: g.arg('a'), b: g.arg('b') })));
  t.op('==', { ret: 'bool', params: ab, doc: 'True when every element is equal (exact).' },
    g => g.math(idx.flatMap(c => idx.map(r => `${E('a', c, r)} == ${E('b', c, r)}`)).join(' && '), { a: g.arg('a'), b: g.arg('b') }));
  const xform = (g, m, v) => g.make(V, Object.fromEntries(idx.map(r => [R[r], g.math(idx.map(k => `${E('m', k, r)} * v.${R[k]}`).join(' + '), { m, v })])));
  if (opts.overloads) {
    t.op('*', { ret: V, params: [['m', M], ['v', V]], doc: 'The column vector `v` transformed: m * v.' }, g => xform(g, g.arg('m'), g.arg('v')));
    t.op('*', { ret: M, params: [['m', M], ['k', 'float']], doc: 'Every element times `k`.' }, g => mk(g, n, (c, r) => g.math(`${E('m', c, r)} * k`, { m: g.arg('m'), k: g.arg('k') })));
  }
  t.fn('Multiply', { ret: M, params: [['b', M]], doc: 'This matrix times `b` (the operator `*`): `b` is applied first.' }, g => mul(g, g.self(), g.arg('b')));
  t.fn('Transform', { ret: V, params: [['v', V]], doc: 'The column vector `v` transformed: M * v (the operator `*` with a vector).' }, g => xform(g, g.self(), g.arg('v')));
  t.fn('Scaled', { ret: M, params: [['k', 'float']], doc: 'Every element times `k`.' }, g => mk(g, n, (c, r) => g.math(`${E('m', c, r)} * k`, { m: g.self(), k: g.arg('k') })));
  t.fn('Transposed', { ret: M, doc: 'Rows and columns swapped.' }, g => mk(g, n, (c, r) => g.math(E('m', r, c), me(g))));
  if (n === 4) {
    t.fn('Determinant', { ret: 'float', doc: 'The determinant (0 for a matrix that has no inverse).' }, g => inverse4(g, g.self(), true).det);
    t.fn('Inverted', { ret: M, doc: 'The inverse (general, by cofactors); a singular matrix (determinant 0) gives all zeros.' }, g => inverse4(g, g.self(), true).res);
    t.fn('TryInvert', { ret: 'bool', outs: [['inverse', M]], doc: 'The inverse in `inverse` and true; false and all zeros when the determinant is 0.' }, g => {
      const { res, det } = inverse4(g, g.self(), true);
      g.ret(g.math('d != 0.0f', { d: det }), { inverse: res });
    });
    t.fn('InvertedAffine', { ret: M, doc: 'The inverse of an affine matrix (bottom row 0, 0, 0, 1: rotation, scale, translation), faster than Inverted: the 3x3 part inverted, the translation moved back. A singular 3x3 part gives zeros there.' }, g => {
      const m = g.self();
      const u = g.call('Core.Mat4.Upper3x3', { receiver: m });
      const ui = g.call('Core.Mat3.Inverted', { receiver: u });
      const t3 = g.math('-(i.C0.X * m.C3.X + i.C1.X * m.C3.Y + i.C2.X * m.C3.Z)', { i: ui, m });
      const t4 = g.math('-(i.C0.Y * m.C3.X + i.C1.Y * m.C3.Y + i.C2.Y * m.C3.Z)', { i: ui, m });
      const t5 = g.math('-(i.C0.Z * m.C3.X + i.C1.Z * m.C3.Y + i.C2.Z * m.C3.Z)', { i: ui, m });
      const tr = [t3, t4, t5];
      return mk(g, 4, (c, r) => (c === 3 ? (r === 3 ? lit(1) : tr[r]) : (r === 3 ? lit(0) : g.math(E('i', c, r), { i: ui }))));
    });
  } else {
    t.fn('Determinant', { ret: 'float', doc: 'The determinant (0 for a matrix that has no inverse).' }, g => inverse3(g, g.self(), true).det);
    t.fn('Inverted', { ret: M, doc: 'The inverse; a singular matrix (determinant 0) gives all zeros.' }, g => inverse3(g, g.self(), true).res);
    t.fn('TryInvert', { ret: 'bool', outs: [['inverse', M]], doc: 'The inverse in `inverse` and true; false and all zeros when the determinant is 0.' }, g => {
      const { res, det } = inverse3(g, g.self(), true);
      g.ret(g.math('d != 0.0f', { d: det }), { inverse: res });
    });
  }
  t.fn('ApproxEquals', { ret: 'bool', params: [['other', M], ['epsilon', 'float', '0.00001f']], doc: 'True when every element is within `epsilon` of the other\'s (absolute).' },
    g => g.math(idx.flatMap(c => idx.map(r => `Abs(${E('m', c, r)} - ${E('o', c, r)}) <= e`)).join(' && '), { m: g.self(), o: g.arg('other'), e: g.arg('epsilon') }));

  const S1 = (name, params, doc, cell, pre) => t.fn(name, { static: true, ret: M, params, doc }, g => {
    const extra = pre ? pre(g) : {};
    return mk(g, n, (c, r) => cell(g, c, r, extra));
  });
  const diag = (c, r) => lit(c === r ? 1 : 0);
  if (n === 4) {
    S1('Translation', [['offset', 'Vec3']], 'Moves points by `offset` (directions are unchanged).',
      (g, c, r) => (c === 3 && r < 3 ? g.math('v.' + R[r], { v: g.arg('offset') }) : diag(c, r)));
    S1('Scale', [['scale', 'Vec3']], 'Scales along X, Y and Z.',
      (g, c, r) => (c === r && r < 3 ? g.math('v.' + R[r], { v: g.arg('scale') }) : diag(c, r)));
    const rot = (name, axis, cells) => t.fn(name, { static: true, ret: M, params: [['angle', 'float']], doc: `A rotation of \`angle\` radians about ${axis} (counter-clockwise looking down the axis, right-handed).` }, g => {
      const cs = g.math('Cos(a)', { a: g.arg('angle') }), sn = g.math('Sin(a)', { a: g.arg('angle') }), ns = g.math('-Sin(a)', { a: g.arg('angle') });
      const P = { c: cs, s: sn, n: ns };
      return mk(g, 4, (c, r) => { const k = cells[c * 10 + r]; return k ? P[k] : diag(c, r); });
    });
    rot('RotationX', 'X', { 11: 'c', 12: 's', 21: 'n', 22: 'c' });
    rot('RotationY', 'Y', { 0: 'c', 2: 'n', 20: 's', 22: 'c' });
    rot('RotationZ', 'Z', { 0: 'c', 1: 's', 10: 'n', 11: 'c' });
    t.fn('Rotation', { static: true, ret: M, params: [['rotation', 'Quat']], doc: 'The rotation of a unit quaternion.' }, g => g.call('Core.Quat.ToMat4', { receiver: g.arg('rotation') }));
    t.fn('FromTRS', { static: true, ret: M, params: [['translation', 'Vec3'], ['rotation', 'Quat'], ['scale', 'Vec3']], doc: 'Scale, then rotate, then translate: Translation * Rotation * Scale.' }, g => {
      const r3 = g.call('Core.Quat.ToMat3', { receiver: g.arg('rotation') });
      const s = g.arg('scale'), tr = g.arg('translation');
      return mk(g, 4, (c, r) => (c === 3 ? (r === 3 ? lit(1) : g.math('t.' + R[r], { t: tr })) : (r === 3 ? lit(0) : g.math(`${E('q', c, r)} * s.${R[c]}`, { q: r3, s }))));
    });
    t.fn('LookAt', { static: true, ret: M, params: [['eye', 'Vec3'], ['target', 'Vec3'], ['up', 'Vec3']], doc: 'A view matrix: the camera at `eye` looking at `target` (right-handed, -Z forward, Y up).' }, g => {
      const e = g.arg('eye');
      const fw = g.call('Core.Vec3.Normalized', { receiver: g.op('-', g.arg('target'), e) });
      const sd = g.call('Core.Vec3.Normalized', { receiver: g.call('Core.Vec3.Cross', { receiver: fw, b: g.arg('up') }) });
      const u = g.call('Core.Vec3.Cross', { receiver: sd, b: fw });
      const rows = [sd, u, fw];
      return mk(g, 4, (c, r) => {
        if (r === 3) return lit(c === 3 ? 1 : 0);
        if (c === 3) {
          const dot = `v.X * e.X + v.Y * e.Y + v.Z * e.Z`;
          return g.math(r === 2 ? dot : `-(${dot})`, { v: rows[r], e });
        }
        return g.math((r === 2 ? '-' : '') + 'v.' + R[c], { v: rows[r] });
      });
    });
    const persp = (name, gl) => t.fn(name, { static: true, ret: M, params: [['fovY', 'float'], ['aspect', 'float'], ['near', 'float'], ['far', 'float']],
      doc: `A perspective projection (right-handed): vertical field of view \`fovY\` in radians, \`aspect\` width / height; depth ${gl ? '-1 to 1 (OpenGL)' : '0 to 1 (Vulkan, D3D)'}.` }, g => {
      const ins = { y: g.arg('fovY'), a: g.arg('aspect'), n: g.arg('near'), f: g.arg('far') };
      const th = g.math('Tan(y / 2.0f)', ins);
      return mk(g, 4, (c, r) => {
        if (c === 0 && r === 0) return g.math('1.0f / (a * h)', Object.assign({ h: th }, ins));
        if (c === 1 && r === 1) return g.math('1.0f / h', { h: th });
        if (c === 2 && r === 2) return g.math(gl ? '-(f + n) / (f - n)' : 'f / (n - f)', ins);
        if (c === 2 && r === 3) return lit(-1);
        if (c === 3 && r === 2) return g.math(gl ? '-(2.0f * f * n) / (f - n)' : '-(f * n) / (f - n)', ins);
        return lit(0);
      });
    });
    persp('Perspective', false); persp('PerspectiveGL', true);
    const ortho = (name, gl) => t.fn(name, { static: true, ret: M, params: [['left', 'float'], ['right', 'float'], ['bottom', 'float'], ['top', 'float'], ['near', 'float'], ['far', 'float']],
      doc: `An orthographic projection (right-handed); depth ${gl ? '-1 to 1 (OpenGL)' : '0 to 1 (Vulkan, D3D)'}.` }, g => {
      const ins = { l: g.arg('left'), r: g.arg('right'), b: g.arg('bottom'), t: g.arg('top'), n: g.arg('near'), f: g.arg('far') };
      const E2 = {
        '00': '2.0f / (r - l)', '11': '2.0f / (t - b)', '22': gl ? '-2.0f / (f - n)' : '-1.0f / (f - n)',
        '30': '-(r + l) / (r - l)', '31': '-(t + b) / (t - b)', '32': gl ? '-(f + n) / (f - n)' : '-n / (f - n)',
      };
      return mk(g, 4, (c, r) => { const ex = E2['' + c + r]; if (!ex) return diag(c, r); const used = {}; for (const k of Object.keys(ins)) if (new RegExp('\\b' + k + '\\b').test(ex)) used[k] = ins[k]; return g.math(ex, used); });
    });
    ortho('Orthographic', false); ortho('OrthographicGL', true);
    t.fn('TransformPoint', { ret: 'Vec3', params: [['point', 'Vec3']], doc: 'The point transformed (W = 1; no divide by W).' },
      g => g.make('Vec3', Object.fromEntries([0, 1, 2].map(r => [R[r], g.math(`${E('m', 0, r)} * p.X + ${E('m', 1, r)} * p.Y + ${E('m', 2, r)} * p.Z + ${E('m', 3, r)}`, { m: g.self(), p: g.arg('point') })]))));
    t.fn('TransformVector', { ret: 'Vec3', params: [['vector', 'Vec3']], doc: 'The direction transformed (W = 0: the translation does not apply).' },
      g => g.make('Vec3', Object.fromEntries([0, 1, 2].map(r => [R[r], g.math(`${E('m', 0, r)} * p.X + ${E('m', 1, r)} * p.Y + ${E('m', 2, r)} * p.Z`, { m: g.self(), p: g.arg('vector') })]))));
    t.fn('TransformPerspective', { ret: 'Vec3', params: [['point', 'Vec3']], doc: 'The point transformed with W = 1, then divided by the resulting W (a projection).' }, g => {
      const ins = { m: g.self(), p: g.arg('point') };
      const w = g.math(`${E('m', 0, 3)} * p.X + ${E('m', 1, 3)} * p.Y + ${E('m', 2, 3)} * p.Z + ${E('m', 3, 3)}`, ins);
      return g.make('Vec3', Object.fromEntries([0, 1, 2].map(r => [R[r], g.math(`(${E('m', 0, r)} * p.X + ${E('m', 1, r)} * p.Y + ${E('m', 2, r)} * p.Z + ${E('m', 3, r)}) / w`, Object.assign({ w }, ins))])));
    });
    t.fn('Upper3x3', { ret: 'Mat3', doc: 'The top-left 3x3 part (rotation and scale).' }, g => mk(g, 3, (c, r) => g.math(E('m', c, r), me(g))));
  } else {
    t.fn('FromQuat', { static: true, ret: M, params: [['rotation', 'Quat']], doc: 'The rotation of a unit quaternion.' }, g => g.call('Core.Quat.ToMat3', { receiver: g.arg('rotation') }));
    S1('Scale', [['scale', 'Vec3']], 'Scales along X, Y and Z.', (g, c, r) => (c === r ? g.math('v.' + R[r], { v: g.arg('scale') }) : diag(c, r)));
    t.fn('RotationZ', { static: true, ret: M, params: [['angle', 'float']], doc: 'A rotation of `angle` radians about Z: the 2D rotation of X and Y (counter-clockwise).' }, g => {
      const a = g.arg('angle');
      const P = { c: g.math('Cos(a)', { a }), s: g.math('Sin(a)', { a }), n: g.math('-Sin(a)', { a }) };
      const cells = { 0: 'c', 1: 's', 10: 'n', 11: 'c' };
      return mk(g, 3, (c, r) => { const k = cells[c * 10 + r]; return k ? P[k] : diag(c, r); });
    });
  }
  // ToStd430: the columns written as floats (Mat3: each column padded to 4).
  const pad = n === 3 ? 4 : 4;
  t.fn('ToStd430', { pure: false, params: [['into', 'Span<float>']], doc: `Writes the matrix as a GPU buffer lays it out (std140 / std430: ${n === 3 ? 'three columns of 4 floats, the 4th 0; 12' : '16'} floats from the start of \`into\`; a shorter span is a fatal error).` }, g => {
    const need = n * pad;
    const sp = g.brk('Span<float>', g.arg('into'));
    const br = g.flow('Branch', null, { condition: g.op('<', sp('Length'), String(need)) }, null, 'false');
    g.flow('Fatal', null, { message: JSON.stringify(`ToStd430: the span holds fewer than ${need} floats`) }, null, 'x');
    g.flowAt = br + '.false';
    // the Fatal hangs off `true`
    const fat = g.nodes.find(nd => nd.kind === 'Fatal').id;
    g.wires = g.wires.filter(w => w[1] !== fat + '.in');
    g.wire(br + '.true', fat + '.in');
    const sc = g.flow('Scope', null, {}, ['unsafe'], 'done');
    const after = g.flowAt;
    g.flowAt = sc + '.body';
    const m = g.self();
    for (let c = 0; c < n; c++)
      for (let r = 0; r < pad; r++) {
        const val = r < n ? g.math(E('m', c, r), { m }) : '0.0f';
        g.flow('Call', 'Pointer.Store', { ptr: g.call('Pointer.Add', { ptr: sp('Ptr'), count: String(c * pad + r) }), value: val });
      }
    g.flowAt = after;
    g.ret();
  });
  return t;
}
module.exports = { matrix, mk, E, R };
