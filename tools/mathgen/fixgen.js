'use strict';
// node fixgen.js <fixtures/core dir> [only-fixture-name]
// 1. writes refs.c (every check's C reference), builds and runs it; 2. writes each fixture's Main and .expected.
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { TypeFile } = require('./lib');
const { PRINT, SCALAR, leaves, makeLit, numLit } = require('./dsl');
const { F } = require('./checks');

const outDir = process.argv[2];
const only = process.argv[3];
const work = path.join(require('os').tmpdir(), 'treadle-mathgen');
fs.mkdirSync(work, { recursive: true });
const clang = process.env.TREADLE_CLANG || path.join(__dirname, '..', 'llvm-mingw', 'bin', 'clang.exe');

// ---- 1. the C references
let c = '#include "' + path.join(__dirname, 'mathref.h').replace(/\\/g, '/') + '"\nint main(void)\n{\n';
for (const name of Object.keys(F)) {
  for (const k of F[name]) {
    c += `\tprintf("%s", ${JSON.stringify(name + '|' + k.label)}); ${PRINT[k.x.type]}(${k.x.c}); printf("\\n");\n`;
  }
}
c += '\treturn 0;\n}\n';
fs.writeFileSync(path.join(work, 'refs.c'), c);
execFileSync(clang, ['-O1', '-ffp-contract=off', '-Wno-missing-braces', '-Wno-unused-function', '-o', path.join(work, 'refs.exe'), path.join(work, 'refs.c')], { stdio: 'inherit' });
const refs = {};
for (const line of execFileSync(path.join(work, 'refs.exe')).toString().split(/\r?\n/)) {
  if (!line) continue;
  const parts = line.trim().split(' ');
  refs[parts[0]] = parts.slice(1).map(Number).map(v => (process.env.MUTATE && Number.isFinite(v) ? v + 0.001 * (1 + Math.abs(v)) : v));
}

// the C twin of mathlib-glm, kept beside the fixture (the reference math inline)
if (F['mathlib-glm']) {
  let tw = `/* mathlib-glm: the C twin of the fixture (hand-written double-precision math with GLM's conventions: column-major,
   right-handed, depth 0 to 1). Each line is a check's name and its reference values; the fixture holds them as
   literals and compares within 1e-5 of the larger of 1 and the value. */
`;
  tw += fs.readFileSync(path.join(__dirname, 'mathref.h'), 'utf8').replace(/^\/\*[\s\S]*?\*\/\n/, '');
  tw += '\nint main(void)\n{\n';
  for (const k of F['mathlib-glm']) tw += `\tprintf("%s", ${JSON.stringify(k.label)}); ${PRINT[k.x.type]}(${k.x.c}); printf("\\n");\n`;
  tw += '\treturn 0;\n}\n';
  fs.writeFileSync(path.join(outDir, 'mathlib-glm.c'), tw);
}

// ---- 2. the fixtures
const camel = s => s.split(/[-.]/).map(w => w[0].toUpperCase() + w.slice(1)).join('');
for (const name of Object.keys(F)) {
  if (only && name !== only) continue;
  const t = new TypeFile(camel(name) + 'Main', 'class', ['namespace Cx', 'static',
    `doc ${JSON.stringify(`The core math library, ${name.replace('math-', '')}: every check compares the result with a reference computed in double precision by a separate C implementation (Gauss-Jordan inverse, Rodrigues rotations, the GLM conventions), within 1e-5 of the larger of 1 and the reference's size; each line is the check's name and true.`)}`]);
  const expected = [];
  t.fn('Main', { static: true, pure: false, ret: 'int' }, g => {
    const s = g.flow('Local', 'String', {}, ['set ctor ()']) + '.object';
    for (const k of F[name]) {
      const key = name + '|' + k.label;
      const vals = refs[key];
      if (!vals) throw new Error('no reference for ' + key);
      const type = k.x.type;
      const v = k.x.pin(g);
      const ref = makeLit(g, type, vals);
      const L = leaves(type, '');
      let maxAbs = 1;
      for (const x of vals) if (Number.isFinite(x)) maxAbs = Math.max(maxAbs, Math.abs(x));
      let cond;
      if (['bool', 'int', 'int32', 'uint32', 'uint8', 'Color32', 'RectI'].includes(type)) cond = g.op('==', v, ref);
      else if (type === 'Quat' || type === 'Transform') {
        cond = g.call(`Core.${type}.ApproxEquals`, { receiver: v, other: ref, epsilon: numLit('float', (k.eps || 1e-5) * maxAbs) });
      } else {
        const parts = L.map(([p, lt]) => {
          const e = numLit(lt, (lt === 'double' ? 1e-9 : (k.eps || 1e-5)) * maxAbs);
          return SCALAR.has(type) ? `Abs(a - b) <= ${e}` : `Abs(a.${p} - b.${p}) <= ${e}`;
        });
        cond = g.math(parts.join(' && '), { a: v, b: ref });
      }
      g.flow('Call', 'String.Clear', { receiver: s });
      g.flow('Call', 'String.Append(StringView)', { receiver: s, text: JSON.stringify(k.label + ' ') });
      g.flow('Call', 'String.Append(bool)', { receiver: s, value: cond });
      g.flow('Call', 'Console.WriteLine(StringView)', { text: s });
      expected.push(k.label + ' true');
    }
    g.ret('0');
  });
  t.save(outDir);
  fs.renameSync(path.join(outDir, t.name + '.treadle'), path.join(outDir, name + '.treadle'));
  fs.writeFileSync(path.join(outDir, name + '.expected'), '== exit\n0\n== stdout\n' + expected.join('\n') + '\n');
  console.log(name, F[name].length, 'checks');
}
