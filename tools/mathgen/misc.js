'use strict';
const { TypeFile } = require('./lib');
const { opts } = require('./common');

const RGBA = ['R', 'G', 'B', 'A'];
const RGB = ['R', 'G', 'B'];
const V3 = ['X', 'Y', 'Z'];
const make3 = (g, f, ins) => g.make('Vec3', Object.fromEntries(V3.map(c => [c, g.math(f(c), ins)])));

function color() {
  const t = new TypeFile('Color', 'struct', ['namespace Core', 'attr CRepr',
    'doc "A colour of four floats R, G, B, A (linear light; 0 to 1 is the usual range, more is allowed for bright lights; 16 bytes). Color32 holds it as four bytes in sRGB. Every function is Pure."']);
  for (const c of RGBA) t.field(c, 'float');
  const named = [['White', 1, 1, 1, 1], ['Black', 0, 0, 0, 1], ['Transparent', 0, 0, 0, 0], ['Red', 1, 0, 0, 1], ['Green', 0, 1, 0, 1], ['Blue', 0, 0, 1, 1],
    ['Yellow', 1, 1, 0, 1], ['Cyan', 0, 1, 1, 1], ['Magenta', 1, 0, 1, 1], ['Gray', 0.5, 0.5, 0.5, 1]];
  for (const [n, r, gg, b, a] of named)
    t.prop(n, { type: 'Color', static: true, doc: `${n} (${r}, ${gg}, ${b}, ${a}).` }, g => g.make('Color', { R: r + (Number.isInteger(r) ? '.0f' : 'f'), G: gg + (Number.isInteger(gg) ? '.0f' : 'f'), B: b + (Number.isInteger(b) ? '.0f' : 'f'), A: a + '.0f' }));
  const cmake = (g, f, ins) => g.make('Color', Object.fromEntries(RGBA.map(c => [c, g.math(f(c), ins)])));
  t.fn('FromRGBA8', { static: true, ret: 'Color', params: [['r', 'uint8'], ['g', 'uint8'], ['b', 'uint8'], ['a', 'uint8', '255']], doc: 'Bytes 0 to 255 as 0 to 1, as they are (no sRGB decoding: FromSrgb does that).' },
    g => g.make('Color', Object.fromEntries(RGBA.map(c => [c, g.math('x / 255.0f', { x: g.cast('float', g.arg(c.toLowerCase())) })]))));
  t.fn('FromHex', { static: true, ret: 'Color', params: [['rrggbbaa', 'uint32']], doc: 'A colour written 0xRRGGBBAA, each byte 0 to 255 as 0 to 1 (no sRGB decoding).' },
    g => g.make('Color', Object.fromEntries(RGBA.map((c, i) => [c, g.math('x / 255.0f', { x: g.cast('float', g.math(`(h >> ${24 - 8 * i}) & 255`, { h: g.arg('rrggbbaa') })) })]))));
  const dec = 'x <= 0.04045f ? x / 12.92f : Pow((x + 0.055f) / 1.055f, 2.4f)';
  const enc = 'x <= 0.0031308f ? x * 12.92f : 1.055f * Pow(x, 1.0f / 2.4f) - 0.055f';
  const conv = (g, src, ex) => g.make('Color', Object.fromEntries(RGBA.map(c => [c, c === 'A' ? g.math('s.A', { s: src }) : g.math(ex, { x: g.math('s.' + c, { s: src }) })])));
  t.fn('FromSrgb', { static: true, ret: 'Color', params: [['srgb', 'Color']], doc: 'A colour given in sRGB (as images and colour pickers store it) decoded to linear light; alpha is unchanged.' }, g => conv(g, g.arg('srgb'), dec));
  t.fn('ToSrgb', { ret: 'Color', doc: 'The colour encoded to sRGB; alpha is unchanged.' }, g => conv(g, g.self(), enc));
  t.fn('ToColor32', { ret: 'Color32', doc: 'Encoded to sRGB, clamped to 0 to 1 and rounded to bytes.' }, g => {
    const s = g.call('Core.Color.ToSrgb', { receiver: g.self() });
    return g.make('Color32', Object.fromEntries(RGBA.map(c => [c, g.cast('uint8', g.math(`Round(Clamp(s.${c}, 0.0f, 1.0f) * 255.0f)`, { s }))])));
  });
  t.fn('WithAlpha', { ret: 'Color', params: [['alpha', 'float']], doc: 'The same colour with alpha `alpha`.' },
    g => g.make('Color', { R: g.math('c.R', { c: g.self() }), G: g.math('c.G', { c: g.self() }), B: g.math('c.B', { c: g.self() }), A: g.arg('alpha') }));
  t.fn('Premultiplied', { ret: 'Color', doc: 'R, G and B multiplied by alpha (for premultiplied blending).' },
    g => cmake(g, c => (c === 'A' ? 'v.A' : `v.${c} * v.A`), { v: g.self() }));
  t.fn('Lerp', { ret: 'Color', params: [['to', 'Color'], ['t', 'float']], doc: 'The colour `t` of the way to `to`, each component (t is not clamped).' },
    g => cmake(g, c => `v.${c} + (b.${c} - v.${c}) * t`, { v: g.self(), b: g.arg('to'), t: g.arg('t') }));
  t.fn('Scaled', { ret: 'Color', params: [['k', 'float']], doc: 'Every component (alpha too) times `k`.' }, g => cmake(g, c => `v.${c} * k`, { v: g.self(), k: g.arg('k') }));
  const ab = [['a', 'Color'], ['b', 'Color']];
  t.op('+', { ret: 'Color', params: ab, doc: 'Component by component: the sum.' }, g => cmake(g, c => `a.${c} + b.${c}`, { a: g.arg('a'), b: g.arg('b') }));
  t.op('*', { ret: 'Color', params: ab, doc: 'Component by component: the product (a tint).' }, g => cmake(g, c => `a.${c} * b.${c}`, { a: g.arg('a'), b: g.arg('b') }));
  if (opts.overloads)
    t.op('*', { ret: 'Color', params: [['a', 'Color'], ['k', 'float']], doc: 'Every component times `k`.' }, g => cmake(g, c => `a.${c} * k`, { a: g.arg('a'), k: g.arg('k') }));
  t.op('==', { ret: 'bool', params: ab, doc: 'True when every component is equal (exact).' }, g => g.math(RGBA.map(c => `a.${c} == b.${c}`).join(' && '), { a: g.arg('a'), b: g.arg('b') }));
  t.fn('ApproxEquals', { ret: 'bool', params: [['other', 'Color'], ['epsilon', 'float', '0.00001f']], doc: 'True when every component is within `epsilon` of the other\'s (absolute).' },
    g => g.math(RGBA.map(c => `Abs(v.${c} - o.${c}) <= e`).join(' && '), { v: g.self(), o: g.arg('other'), e: g.arg('epsilon') }));
  return t;
}

function color32() {
  const t = new TypeFile('Color32', 'struct', ['namespace Core', 'attr CRepr',
    'doc "A colour of four bytes R, G, B, A (sRGB as stored in images and textures; 4 bytes). Color is the linear float form. Every function is Pure."']);
  for (const c of RGBA) t.field(c, 'uint8');
  t.fn('FromHex', { static: true, ret: 'Color32', params: [['rrggbbaa', 'uint32']], doc: 'A colour written 0xRRGGBBAA.' },
    g => g.make('Color32', Object.fromEntries(RGBA.map((c, i) => [c, g.cast('uint8', g.math(`(h >> ${24 - 8 * i}) & 255`, { h: g.arg('rrggbbaa') }))]))));
  t.fn('ToHex', { ret: 'uint32', doc: 'The colour as 0xRRGGBBAA.' }, g => {
    const v = g.self();
    const ins = {};
    for (const c of RGBA) ins[c.toLowerCase()] = g.cast('uint32', g.math('v.' + c, { v }));
    return g.math('(r << 24) | (g << 16) | (b << 8) | a', ins);
  });
  t.fn('ToColor', { ret: 'Color', doc: 'Decoded from sRGB to a linear Color (alpha 0 to 255 as 0 to 1).' }, g => {
    const v = g.self();
    const raw = g.make('Color', Object.fromEntries(RGBA.map(c => [c, g.math('x / 255.0f', { x: g.cast('float', g.math('v.' + c, { v })) })])));
    return g.call('Core.Color.FromSrgb', { srgb: raw });
  });
  t.op('==', { ret: 'bool', params: [['a', 'Color32'], ['b', 'Color32']], doc: 'True when every byte is equal.' }, g => g.math(RGBA.map(c => `a.${c} == b.${c}`).join(' && '), { a: g.arg('a'), b: g.arg('b') }));
  return t;
}

function rect(I) {
  const N = I ? 'RectI' : 'Rect', S = I ? 'int32' : 'float';
  const z = I ? '0' : '0.0f', two = I ? '2' : '2.0f';
  const t = new TypeFile(N, 'struct', ['namespace Core', 'attr CRepr',
    I ? 'doc "A rectangle of whole numbers X, Y, Width, Height (int32; 16 bytes, the layout of an SDL_Rect): pixels on a screen. It holds the points from X up to but not including X + Width (the same for Y). Every function is Pure."'
      : 'doc "A rectangle X, Y, Width, Height of floats (16 bytes): it holds the points from X up to but not including X + Width, the same for Y (Y down on a screen, up in a world: either works). Every function is Pure."']);
  for (const c of ['X', 'Y', 'Width', 'Height']) t.field(c, S);
  const rmake = (g, x, y, w, h) => g.make(N, { X: x, Y: y, Width: w, Height: h });
  const me = g => ({ r: g.self() });
  if (I) {
    t.fn('FromMinMax', { static: true, ret: N, params: [['minX', S], ['minY', S], ['maxX', S], ['maxY', S]], doc: 'The rectangle from (minX, minY) up to (maxX, maxY) (not included).' }, g => {
      const ins = { a: g.arg('minX'), b: g.arg('minY'), c: g.arg('maxX'), d: g.arg('maxY') };
      return rmake(g, g.arg('minX'), g.arg('minY'), g.math('c - a', ins), g.math('d - b', ins));
    });
    t.fn('Contains', { ret: 'bool', params: [['x', S], ['y', S]], doc: 'True when the pixel (x, y) is inside.' },
      g => g.math('x >= r.X && x < r.X + r.Width && y >= r.Y && y < r.Y + r.Height', { r: g.self(), x: g.arg('x'), y: g.arg('y') }));
    t.fn('ContainsPoint', { ret: 'bool', params: [['point', 'Vec2']], doc: 'True when the point is inside.' },
      g => g.math('p.X >= r.X && p.X < r.X + r.Width && p.Y >= r.Y && p.Y < r.Y + r.Height', { r: g.self(), p: g.arg('point') }));
    t.fn('Expanded', { ret: N, params: [['amount', S]], doc: 'Grown by `amount` on every side (a negative amount shrinks it).' }, g => {
      const ins = { r: g.self(), d: g.arg('amount') };
      return rmake(g, g.math('r.X - d', ins), g.math('r.Y - d', ins), g.math('r.Width + d * 2', ins), g.math('r.Height + d * 2', ins));
    });
    t.fn('Translated', { ret: N, params: [['dx', S], ['dy', S]], doc: 'Moved by (dx, dy).' }, g => {
      const ins = { r: g.self(), x: g.arg('dx'), y: g.arg('dy') };
      return rmake(g, g.math('r.X + x', ins), g.math('r.Y + y', ins), g.math('r.Width', ins), g.math('r.Height', ins));
    });
    t.fn('Center', { ret: 'Vec2', doc: 'The middle point (it may fall between pixels).' }, g =>
      g.make('Vec2', { X: g.math('x + w / 2.0f', { x: g.cast('float', g.math('r.X', me(g))), w: g.cast('float', g.math('r.Width', me(g))) }), Y: g.math('y + h / 2.0f', { y: g.cast('float', g.math('r.Y', me(g))), h: g.cast('float', g.math('r.Height', me(g))) }) }));
    t.fn('ToRect', { ret: 'Rect', doc: 'The same rectangle in floats.' }, g => g.make('Rect', Object.fromEntries(['X', 'Y', 'Width', 'Height'].map(c => [c, g.cast('float', g.math('r.' + c, me(g)))]))));
    t.fn('FromRect', { static: true, ret: N, params: [['rect', 'Rect']], doc: 'The smallest whole-number rectangle that covers `rect` (its edges rounded outwards).' }, g => {
      const r = g.arg('rect');
      const x0 = g.cast('int32', g.math('Floor(r.X)', { r })), y0 = g.cast('int32', g.math('Floor(r.Y)', { r }));
      const x1 = g.cast('int32', g.math('Ceil(r.X + r.Width)', { r })), y1 = g.cast('int32', g.math('Ceil(r.Y + r.Height)', { r }));
      return rmake(g, x0, y0, g.math('b - a', { a: x0, b: x1 }), g.math('b - a', { a: y0, b: y1 }));
    });
  } else {
    t.fn('FromMinMax', { static: true, ret: N, params: [['min', 'Vec2'], ['max', 'Vec2']], doc: 'The rectangle from `min` to `max`.' }, g => {
      const ins = { a: g.arg('min'), b: g.arg('max') };
      return rmake(g, g.math('a.X', ins), g.math('a.Y', ins), g.math('b.X - a.X', ins), g.math('b.Y - a.Y', ins));
    });
    t.fn('Min', { ret: 'Vec2', doc: 'The corner (X, Y).' }, g => g.make('Vec2', { X: g.math('r.X', me(g)), Y: g.math('r.Y', me(g)) }));
    t.fn('Max', { ret: 'Vec2', doc: 'The corner (X + Width, Y + Height).' }, g => g.make('Vec2', { X: g.math('r.X + r.Width', me(g)), Y: g.math('r.Y + r.Height', me(g)) }));
    t.fn('Center', { ret: 'Vec2', doc: 'The middle point.' }, g => g.make('Vec2', { X: g.math('r.X + r.Width * 0.5f', me(g)), Y: g.math('r.Y + r.Height * 0.5f', me(g)) }));
    t.fn('Size', { ret: 'Vec2', doc: '(Width, Height).' }, g => g.make('Vec2', { X: g.math('r.Width', me(g)), Y: g.math('r.Height', me(g)) }));
    t.fn('Contains', { ret: 'bool', params: [['point', 'Vec2']], doc: 'True when the point is inside (the far edges are outside).' },
      g => g.math('p.X >= r.X && p.X < r.X + r.Width && p.Y >= r.Y && p.Y < r.Y + r.Height', { r: g.self(), p: g.arg('point') }));
    t.fn('Expanded', { ret: N, params: [['amount', S]], doc: 'Grown by `amount` on every side (a negative amount shrinks it).' }, g => {
      const ins = { r: g.self(), d: g.arg('amount') };
      return rmake(g, g.math('r.X - d', ins), g.math('r.Y - d', ins), g.math('r.Width + d * 2.0f', ins), g.math('r.Height + d * 2.0f', ins));
    });
    t.fn('Translated', { ret: N, params: [['offset', 'Vec2']], doc: 'Moved by `offset`.' }, g => {
      const ins = { r: g.self(), o: g.arg('offset') };
      return rmake(g, g.math('r.X + o.X', ins), g.math('r.Y + o.Y', ins), g.math('r.Width', ins), g.math('r.Height', ins));
    });
  }
  t.fn('Overlaps', { ret: 'bool', params: [['other', N]], doc: 'True when the two share some area (touching edges do not count).' },
    g => g.math('a.X < b.X + b.Width && b.X < a.X + a.Width && a.Y < b.Y + b.Height && b.Y < a.Y + a.Height', { a: g.self(), b: g.arg('other') }));
  t.fn('Intersection', { ret: N, params: [['other', N]], doc: 'The area both cover; when they do not overlap, a rectangle of zero size.' }, g => {
    const ins = { a: g.self(), b: g.arg('other') };
    const x0 = g.math('Max(a.X, b.X)', ins), y0 = g.math('Max(a.Y, b.Y)', ins);
    const x1 = g.math('Min(a.X + a.Width, b.X + b.Width)', ins), y1 = g.math('Min(a.Y + a.Height, b.Y + b.Height)', ins);
    const P = { x0, y0, x1, y1 };
    const e = g.math('x1 <= x0 || y1 <= y0', P);
    return rmake(g, x0, y0, g.math(`e ? ${z} : x1 - x0`, { e, x0, x1 }), g.math(`e ? ${z} : y1 - y0`, { e, y0, y1 }));
  });
  t.fn('Union', { ret: N, params: [['other', N]], doc: 'The smallest rectangle that covers both.' }, g => {
    const ins = { a: g.self(), b: g.arg('other') };
    const x0 = g.math('Min(a.X, b.X)', ins), y0 = g.math('Min(a.Y, b.Y)', ins);
    const x1 = g.math('Max(a.X + a.Width, b.X + b.Width)', ins), y1 = g.math('Max(a.Y + a.Height, b.Y + b.Height)', ins);
    return rmake(g, x0, y0, g.math('x1 - x0', { x0, x1 }), g.math('y1 - y0', { y0, y1 }));
  });
  t.fn('IsEmpty', { ret: 'bool', doc: 'True when the width or the height is zero or less.' }, g => g.math(`r.Width <= ${z} || r.Height <= ${z}`, me(g)));
  t.op('==', { ret: 'bool', params: [['a', N], ['b', N]], doc: 'True when position and size are equal.' },
    g => g.math('a.X == b.X && a.Y == b.Y && a.Width == b.Width && a.Height == b.Height', { a: g.arg('a'), b: g.arg('b') }));
  void two;
  return t;
}

function aabb() {
  const t = new TypeFile('AABB', 'struct', ['namespace Core', 'attr CRepr',
    'doc "An axis-aligned box from corner Min to corner Max (24 bytes): bounds of a mesh, a broad-phase collision test. Empty (Min above Max) holds nothing and grows with Encapsulate. Every function is Pure."']);
  t.field('Min', 'Vec3'); t.field('Max', 'Vec3');
  const me = g => ({ b: g.self() });
  t.prop('Empty', { type: 'AABB', static: true, doc: 'The box that holds nothing: Min at +infinity, Max at -infinity; Encapsulate and Union start from it.' }, g => {
    const inf = g.math('1.0f / z', { z: '0.0f' });
    const ninf = g.math('-1.0f / z', { z: '0.0f' });
    return g.make('AABB', { Min: g.make('Vec3', { X: inf, Y: inf, Z: inf }), Max: g.make('Vec3', { X: ninf, Y: ninf, Z: ninf }) });
  });
  t.fn('FromCenterExtents', { static: true, ret: 'AABB', params: [['center', 'Vec3'], ['extents', 'Vec3']], doc: 'The box around `center` reaching `extents` (half the size) each way.' },
    g => g.make('AABB', { Min: g.op('-', g.arg('center'), g.arg('extents')), Max: g.op('+', g.arg('center'), g.arg('extents')) }));
  t.fn('FromPoints', { static: true, ret: 'AABB', params: [['points', 'Span<Vec3>']], locals: [['box', 'AABB']], doc: 'The smallest box holding every point (Empty when there are none).' }, g => {
    g.flow('Set', 'local:box', { value: g.get('Core.AABB.Empty') });
    const fe = g.flow('ForEach', null, { collection: g.arg('points') }, null, 'done');
    const save = g.flowAt;
    g.flowAt = fe + '.body';
    g.flow('Set', 'local:box', { value: g.call('Core.AABB.Encapsulate', { receiver: g.get('local:box'), point: fe + '.element' }) });
    g.flowAt = save;
    return g.get('local:box');
  });
  t.fn('Center', { ret: 'Vec3', doc: 'The middle point.' }, g => make3(g, c => `(b.Min.${c} + b.Max.${c}) * 0.5f`, me(g)));
  t.fn('Extents', { ret: 'Vec3', doc: 'Half the size along each axis.' }, g => make3(g, c => `(b.Max.${c} - b.Min.${c}) * 0.5f`, me(g)));
  t.fn('Size', { ret: 'Vec3', doc: 'The size along each axis.' }, g => make3(g, c => `b.Max.${c} - b.Min.${c}`, me(g)));
  t.fn('IsValid', { ret: 'bool', doc: 'True when Min is nowhere above Max (false for Empty).' }, g => g.math(V3.map(c => `b.Min.${c} <= b.Max.${c}`).join(' && '), me(g)));
  t.fn('Contains', { ret: 'bool', params: [['point', 'Vec3']], doc: 'True when the point is inside or on the surface.' },
    g => g.math(V3.map(c => `p.${c} >= b.Min.${c} && p.${c} <= b.Max.${c}`).join(' && '), { b: g.self(), p: g.arg('point') }));
  t.fn('Overlaps', { ret: 'bool', params: [['other', 'AABB']], doc: 'True when the boxes share a point (touching counts).' },
    g => g.math(V3.map(c => `a.Min.${c} <= b.Max.${c} && b.Min.${c} <= a.Max.${c}`).join(' && '), { a: g.self(), b: g.arg('other') }));
  t.fn('Union', { ret: 'AABB', params: [['other', 'AABB']], doc: 'The smallest box holding both.' }, g => {
    const ins = { a: g.self(), b: g.arg('other') };
    return g.make('AABB', { Min: make3(g, c => `Min(a.Min.${c}, b.Min.${c})`, ins), Max: make3(g, c => `Max(a.Max.${c}, b.Max.${c})`, ins) });
  });
  t.fn('Encapsulate', { ret: 'AABB', params: [['point', 'Vec3']], doc: 'The box grown to hold the point.' }, g => {
    const ins = { a: g.self(), p: g.arg('point') };
    return g.make('AABB', { Min: make3(g, c => `Min(a.Min.${c}, p.${c})`, ins), Max: make3(g, c => `Max(a.Max.${c}, p.${c})`, ins) });
  });
  t.fn('Transformed', { ret: 'AABB', params: [['m', 'Mat4']], doc: 'The box around this box moved by the affine matrix `m` (it can only grow on a rotation: Arvo\'s method). Empty stays Empty.' }, g => {
    const b = g.self(), m = g.arg('m');
    const c = g.call('Core.AABB.Center', { receiver: b }), e = g.call('Core.AABB.Extents', { receiver: b });
    const nc = g.call('Core.Mat4.TransformPoint', { receiver: m, point: c });
    const ne = make3(g, r => `Abs(m.C0.${r}) * e.X + Abs(m.C1.${r}) * e.Y + Abs(m.C2.${r}) * e.Z`, { m, e });
    const box = g.call('Core.AABB.FromCenterExtents', { center: nc, extents: ne });
    return g.select(g.call('Core.AABB.IsValid', { receiver: b }), box, b);
  });
  t.fn('ClosestPoint', { ret: 'Vec3', params: [['point', 'Vec3']], doc: 'The point of the box nearest to `point` (the point itself when inside).' },
    g => make3(g, c => `Clamp(p.${c}, b.Min.${c}, b.Max.${c})`, { b: g.self(), p: g.arg('point') }));
  return t;
}

function plane() {
  const t = new TypeFile('Plane', 'struct', ['namespace Core', 'attr CRepr',
    'doc "A plane: the points p with Dot(Normal, p) + D = 0 (16 bytes). The side Normal points to is the front. Every function is Pure."']);
  t.field('Normal', 'Vec3'); t.field('D', 'float');
  t.fn('FromPointNormal', { static: true, ret: 'Plane', params: [['point', 'Vec3'], ['normal', 'Vec3']], doc: 'The plane through `point` facing `normal` (kept as given: pass a unit normal for true distances).' }, g => {
    const p = g.arg('point'), n = g.arg('normal');
    return g.make('Plane', { Normal: n, D: g.math('-(n.X * p.X + n.Y * p.Y + n.Z * p.Z)', { n, p }) });
  });
  t.fn('FromPoints', { static: true, ret: 'Plane', params: [['a', 'Vec3'], ['b', 'Vec3'], ['c', 'Vec3']], doc: 'The plane through three points; its front is where they run counter-clockwise (unit normal).' }, g => {
    const a = g.arg('a');
    const n = g.call('Core.Vec3.Normalized', { receiver: g.call('Core.Vec3.Cross', { receiver: g.op('-', g.arg('b'), a), b: g.op('-', g.arg('c'), a) }) });
    return g.make('Plane', { Normal: n, D: g.math('-(n.X * p.X + n.Y * p.Y + n.Z * p.Z)', { n, p: a }) });
  });
  t.fn('DistanceTo', { ret: 'float', params: [['point', 'Vec3']], doc: 'The signed distance: positive in front, negative behind (true distance for a unit normal).' },
    g => g.math('l.Normal.X * p.X + l.Normal.Y * p.Y + l.Normal.Z * p.Z + l.D', { l: g.self(), p: g.arg('point') }));
  t.fn('Side', { ret: 'int', params: [['point', 'Vec3']], doc: '1 in front, -1 behind, 0 on the plane.' }, g => {
    const d = g.math('l.Normal.X * p.X + l.Normal.Y * p.Y + l.Normal.Z * p.Z + l.D', { l: g.self(), p: g.arg('point') });
    return g.math('d > 0.0f ? 1 : d < 0.0f ? -1 : 0', { d });
  });
  t.fn('Normalized', { ret: 'Plane', doc: 'The same plane with a unit normal (D scaled to match); a zero normal gives zeros.' }, g => {
    const l = g.self();
    const k = g.math('s > 0.0f ? 1.0f / s : 0.0f', { s: g.math('Sqrt(l.Normal.X * l.Normal.X + l.Normal.Y * l.Normal.Y + l.Normal.Z * l.Normal.Z)', { l }) });
    return g.make('Plane', { Normal: make3(g, c => `l.Normal.${c} * k`, { l, k }), D: g.math('l.D * k', { l, k }) });
  });
  t.fn('Project', { ret: 'Vec3', params: [['point', 'Vec3']], doc: 'The point of the plane nearest to `point`.' }, g => {
    const l = g.self(), p = g.arg('point');
    const nn = g.math('l.Normal.X * l.Normal.X + l.Normal.Y * l.Normal.Y + l.Normal.Z * l.Normal.Z', { l });
    const k = g.math('nn > 0.0f ? (l.Normal.X * p.X + l.Normal.Y * p.Y + l.Normal.Z * p.Z + l.D) / nn : 0.0f', { l, p, nn });
    return make3(g, c => `p.${c} - l.Normal.${c} * k`, { l, p, k });
  });
  return t;
}

function ray() {
  const t = new TypeFile('Ray', 'struct', ['namespace Core', 'attr CRepr',
    'doc "A half-line from Origin along Direction (24 bytes): picking, line of sight, bullets. The Intersect functions give the distance `t` along it in units of Direction\'s length (the hit point is At(t)). Every function is Pure."']);
  t.field('Origin', 'Vec3'); t.field('Direction', 'Vec3');
  t.fn('At', { ret: 'Vec3', params: [['t', 'float']], doc: 'The point Origin + Direction * t.' }, g => make3(g, c => `r.Origin.${c} + r.Direction.${c} * t`, { r: g.self(), t: g.arg('t') }));
  t.fn('IntersectAABB', { ret: 'bool', params: [['box', 'AABB']], outs: [['t', 'float']], doc: 'True when the ray meets the box; `t` is where it enters (0 when the origin is inside).' }, g => {
    const r = g.self(), b = g.arg('box');
    const I = {};
    for (const c of V3) {
      const inv = g.math(`1.0f / r.Direction.${c}`, { r });
      const t1 = g.math(`(b.Min.${c} - r.Origin.${c}) * i`, { b, r, i: inv });
      const t2 = g.math(`(b.Max.${c} - r.Origin.${c}) * i`, { b, r, i: inv });
      I['lo' + c] = g.math('Min(p, q)', { p: t1, q: t2 });
      I['hi' + c] = g.math('Max(p, q)', { p: t1, q: t2 });
    }
    const tmin = g.math('Max(Max(loX, loY), loZ)', { loX: I.loX, loY: I.loY, loZ: I.loZ });
    const tmax = g.math('Min(Min(hiX, hiY), hiZ)', { hiX: I.hiX, hiY: I.hiY, hiZ: I.hiZ });
    const hit = g.math('b >= Max(a, 0.0f)', { a: tmin, b: tmax });
    g.ret(hit, { t: g.math('h ? Max(a, 0.0f) : 0.0f', { h: hit, a: tmin }) });
  });
  t.fn('IntersectPlane', { ret: 'bool', params: [['plane', 'Plane']], outs: [['t', 'float']], doc: 'True when the ray meets the plane ahead of its origin (a ray along the plane never does).' }, g => {
    const r = g.self(), p = g.arg('plane');
    const den = g.math('p.Normal.X * r.Direction.X + p.Normal.Y * r.Direction.Y + p.Normal.Z * r.Direction.Z', { p, r });
    const tt = g.math('-(p.Normal.X * r.Origin.X + p.Normal.Y * r.Origin.Y + p.Normal.Z * r.Origin.Z + p.D) / d', { p, r, d: den });
    const hit = g.math('Abs(d) > 0.00000001f && t >= 0.0f', { d: den, t: tt });
    g.ret(hit, { t: g.math('h ? t : 0.0f', { h: hit, t: tt }) });
  });
  t.fn('IntersectSphere', { ret: 'bool', params: [['center', 'Vec3'], ['radius', 'float']], outs: [['t', 'float']], doc: 'True when the ray meets the sphere; `t` is where it enters (0 when the origin is inside).' }, g => {
    const r = g.self(), c = g.arg('center'), rad = g.arg('radius');
    const m = make3(g, k => `r.Origin.${k} - c.${k}`, { r, c });
    const a = g.math('r.Direction.X * r.Direction.X + r.Direction.Y * r.Direction.Y + r.Direction.Z * r.Direction.Z', { r });
    const b = g.math('m.X * r.Direction.X + m.Y * r.Direction.Y + m.Z * r.Direction.Z', { m, r });
    const cc = g.math('m.X * m.X + m.Y * m.Y + m.Z * m.Z - s * s', { m, s: rad });
    const disc = g.math('b * b - a * c', { a, b, c: cc });
    const hit = g.math('a > 0.0f && disc >= 0.0f && !(c > 0.0f && b > 0.0f)', { a, b, c: cc, disc });
    const tt = g.math('h ? Max((-b - Sqrt(disc)) / a, 0.0f) : 0.0f', { h: hit, b, disc, a });
    g.ret(hit, { t: tt });
  });
  t.fn('IntersectTriangle', { ret: 'bool', params: [['a', 'Vec3'], ['b', 'Vec3'], ['c', 'Vec3']], outs: [['t', 'float']], doc: 'True when the ray meets the triangle a, b, c from either side (the Moller-Trumbore test).' }, g => {
    const r = g.self(), a = g.arg('a');
    const e1 = g.op('-', g.arg('b'), a), e2 = g.op('-', g.arg('c'), a);
    const dir = g.math('r.Direction', { r });
    const p = g.call('Core.Vec3.Cross', { receiver: dir, b: e2 });
    const det = g.call('Core.Vec3.Dot', { receiver: e1, b: p });
    const inv = g.math('1.0f / d', { d: det });
    const s = g.op('-', g.math('r.Origin', { r }), a);
    const u = g.math('(s.X * p.X + s.Y * p.Y + s.Z * p.Z) * i', { s, p, i: inv });
    const q = g.call('Core.Vec3.Cross', { receiver: s, b: e1 });
    const v = g.math('(d.X * q.X + d.Y * q.Y + d.Z * q.Z) * i', { d: dir, q, i: inv });
    const tt = g.math('(e.X * q.X + e.Y * q.Y + e.Z * q.Z) * i', { e: e2, q, i: inv });
    const hit = g.math('Abs(d) > 0.00000001f && u >= 0.0f && u <= 1.0f && v >= 0.0f && u + v <= 1.0f && t >= 0.0f', { d: det, u, v, t: tt });
    g.ret(hit, { t: g.math('h ? t : 0.0f', { h: hit, t: tt }) });
  });
  return t;
}

function transform() {
  const t = new TypeFile('Transform', 'struct', ['namespace Core', 'attr CRepr',
    'doc "A position, rotation and scale (40 bytes): scale first, then rotate, then move. parent * child places a child in its parent\'s space. Every function is Pure."']);
  t.field('Translation', 'Vec3'); t.field('Rotation', 'Quat'); t.field('Scale', 'Vec3');
  const B = (g, v) => g.brk('Core.Transform', v);
  t.prop('Identity', { type: 'Transform', static: true, doc: 'No move, no rotation, scale 1.' },
    g => g.make('Transform', { Translation: g.get('Core.Vec3.Zero'), Rotation: g.get('Core.Quat.Identity'), Scale: g.get('Core.Vec3.One') }));
  t.fn('ToMat4', { ret: 'Mat4', doc: 'The same transform as a matrix (Translation * Rotation * Scale).' }, g => {
    const x = B(g, g.self());
    return g.call('Core.Mat4.FromTRS', { translation: x('Translation'), rotation: x('Rotation'), scale: x('Scale') });
  });
  const point = (g, x, p, withT) => {
    const sp = g.op('*', x('Scale'), p);
    const rp = g.call('Core.Quat.Rotate', { receiver: x('Rotation'), v: sp });
    return withT ? g.op('+', x('Translation'), rp) : rp;
  };
  t.fn('TransformPoint', { ret: 'Vec3', params: [['point', 'Vec3']], doc: 'The point scaled, rotated and moved.' }, g => point(g, B(g, g.self()), g.arg('point'), true));
  t.fn('TransformVector', { ret: 'Vec3', params: [['vector', 'Vec3']], doc: 'The direction scaled and rotated (not moved).' }, g => point(g, B(g, g.self()), g.arg('vector'), false));
  t.fn('Inverse', { ret: 'Transform', doc: 'The transform that undoes this one (exact for a uniform scale; a non-uniform scale with a rotation loses its shear). A zero scale component stays zero.' }, g => {
    const x = B(g, g.self());
    const s = make3(g, c => `s.${c} != 0.0f ? 1.0f / s.${c} : 0.0f`, { s: x('Scale') });
    const r = g.call('Core.Quat.Inverse', { receiver: x('Rotation') });
    const tr = g.call('Core.Quat.Rotate', { receiver: r, v: g.op('*', s, x('Translation')) });
    return g.make('Transform', { Translation: g.op('neg', tr), Rotation: r, Scale: s });
  });
  const compose = (g, pa, ch) => {
    const p = B(g, pa), c = B(g, ch);
    return g.make('Transform', { Translation: point(g, p, c('Translation'), true), Rotation: g.op('*', p('Rotation'), c('Rotation')), Scale: g.op('*', p('Scale'), c('Scale')) });
  };
  t.op('*', { ret: 'Transform', params: [['parent', 'Transform'], ['child', 'Transform']], doc: 'The child placed in the parent\'s space: child first, then parent (a non-uniform parent scale with a rotation loses the shear).' },
    g => compose(g, g.arg('parent'), g.arg('child')));
  t.fn('Compose', { ret: 'Transform', params: [['child', 'Transform']], doc: 'This (as the parent) * `child`: the child placed in this transform\'s space.' }, g => compose(g, g.self(), g.arg('child')));
  t.fn('Lerp', { ret: 'Transform', params: [['to', 'Transform'], ['t', 'float']], doc: 'The transform `t` of the way to `to`: translation and scale straight, rotation by Slerp.' }, g => {
    const a = B(g, g.self()), b = B(g, g.arg('to')), tt = g.arg('t');
    return g.make('Transform', {
      Translation: g.call('Core.Vec3.Lerp', { receiver: a('Translation'), to: b('Translation'), t: tt }),
      Rotation: g.call('Core.Quat.Slerp', { receiver: a('Rotation'), to: b('Rotation'), t: tt }),
      Scale: g.call('Core.Vec3.Lerp', { receiver: a('Scale'), to: b('Scale'), t: tt }),
    });
  });
  t.fn('ApproxEquals', { ret: 'bool', params: [['other', 'Transform'], ['epsilon', 'float', '0.00001f']], doc: 'True when translation, rotation (q and -q alike) and scale are each within `epsilon` (absolute).' }, g => {
    const a = B(g, g.self()), b = B(g, g.arg('other')), e = g.arg('epsilon');
    const x = g.call('Core.Vec3.ApproxEquals', { receiver: a('Translation'), other: b('Translation'), epsilon: e });
    const y = g.call('Core.Quat.ApproxEquals', { receiver: a('Rotation'), other: b('Rotation'), epsilon: e });
    const z = g.call('Core.Vec3.ApproxEquals', { receiver: a('Scale'), other: b('Scale'), epsilon: e });
    return g.math('x && y && z', { x, y, z });
  });
  return t;
}

module.exports = { color, color32, rect, aabb, plane, ray, transform };
