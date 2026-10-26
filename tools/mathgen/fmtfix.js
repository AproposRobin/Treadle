'use strict';
// node fmtfix.js <fixtures/core dir>: math-format, the exact text String.Append and AppendF write for the math types.
const fs = require('fs');
const path = require('path');
const { TypeFile } = require('./lib');
const { lit } = require('./dsl');
const out = process.argv[2];
const t = new TypeFile('MathFormatMain', 'class', ['namespace Cx', 'static',
  'doc "The core math library\'s text: String.Append of every math type (vectors as (1, 2, 3), matrices as rows), and AppendF with math values as its arguments."']);
const lines = [];
t.fn('Main', { static: true, pure: false, ret: 'int' }, g => {
  const s = g.flow('Local', 'String', {}, ['set ctor ()']) + '.object';
  const show = (type, pin, text) => {
    g.flow('Call', 'String.Clear', { receiver: s });
    g.flow('Call', `String.Append(${type})`, { receiver: s, value: pin });
    g.flow('Call', 'Console.WriteLine(StringView)', { text: s });
    lines.push(text);
  };
  const L = (type, ...v) => lit(type, ...v).pin(g);
  show('Vec2', L('Vec2', 1.5, -2), '(1.5, -2)');
  show('Vec3', L('Vec3', 1, 2.25, -0.5), '(1, 2.25, -0.5)');
  show('Vec4', L('Vec4', 0, 1, 2, 3), '(0, 1, 2, 3)');
  show('Vec2d', L('Vec2d', 0.1, 2), '(0.1, 2)');
  show('Vec3d', L('Vec3d', 1e-3, 123456789, -7), '(0.001, 123456789, -7)');
  show('Vec4d', L('Vec4d', 0.5, 0.25, 0.125, 1), '(0.5, 0.25, 0.125, 1)');
  show('Mat3', g.get('Core.Mat3.Identity'), '[(1, 0, 0), (0, 1, 0), (0, 0, 1)]');
  show('Mat4', g.call('Core.Mat4.Translation', { offset: L('Vec3', 1, 2, 3) }), '[(1, 0, 0, 1), (0, 1, 0, 2), (0, 0, 1, 3), (0, 0, 0, 1)]');
  show('Quat', g.get('Core.Quat.Identity'), '(0, 0, 0, 1)');
  show('Color', g.get('Core.Color.Gray'), '(0.5, 0.5, 0.5, 1)');
  show('Color32', g.call('Core.Color32.FromHex', { rrggbbaa: '0x12AB7F01' }), '(18, 171, 127, 1)');
  show('Rect', L('Rect', 1, 2, 4, 3), '(1, 2, 4, 3)');
  show('RectI', L('RectI', -1, 0, 640, 480), '(-1, 0, 640, 480)');
  show('AABB', L('AABB', -1, 0, 2, 3, 4, 5), '[(-1, 0, 2), (3, 4, 5)]');
  show('Plane', L('Plane', 0, 0.6, 0.8, -2), '(0, 0.6, 0.8, -2)');
  show('Ray', L('Ray', 1, 2, 3, 0, 0, -1), '[(1, 2, 3), (0, 0, -1)]');
  show('Transform', g.get('Core.Transform.Identity'), '[(0, 0, 0), (0, 0, 0, 1), (1, 1, 1)]');
  // AppendF: math values as arguments, written through their Append
  g.flow('Call', 'String.Clear', { receiver: s });
  g.flow('Call', 'String.AppendF', { receiver: s, format: '"v = {0}, q = {1}, n = {2}"', arg0: L('Vec3', 1, 2.25, -0.5), arg1: g.get('Core.Quat.Identity'), arg2: '3' });
  g.flow('Call', 'Console.WriteLine(StringView)', { text: s });
  lines.push('v = (1, 2.25, -0.5), q = (0, 0, 0, 1), n = 3');
  g.ret('0');
});
t.save(out);
fs.renameSync(path.join(out, 'MathFormatMain.treadle'), path.join(out, 'math-format.treadle'));
fs.writeFileSync(path.join(out, 'math-format.expected'), '== exit\n0\n== stdout\n' + lines.join('\n') + '\n');
