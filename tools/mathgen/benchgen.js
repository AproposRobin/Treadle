'use strict';
// node benchgen.js <samples/bench dir>: the nbody-mathlib kernel (Treadle graph + C twin).
const fs = require('fs');
const path = require('path');
const { TypeFile } = require('./lib');
const dir = process.argv[2];
const N = 4096, STEPS = 20;

const t = new TypeFile('Program', 'class', ['namespace Bench', 'static',
  `doc ${JSON.stringify(`Benchmark nbody-mathlib: ${N} bodies, ${STEPS} steps of O(n^2) gravity on the core math library: positions and velocities are Core.Vec3 arrays, the forces use Vec3's operators (-, +, * by a float) and LengthSquared; masses a float array. The checksum is the sum of the final coordinates times 1000.`)}`]);
t.fn('Main', { static: true, pure: false, ret: 'int', locals: [['acc', 'Core.Vec3'], ['sum', 'double']] }, g => {
  const arr = (sub, n) => g.flow('Construct', sub, { count: String(n) }, ['set count']) + '.object';
  const pos = arr('Core.Vec3[]', N), vel = arr('Core.Vec3[]', N), mass = arr('float[]', N);
  // initial state: integer patterns made floats (the same in the C twin)
  const init = g.flow('For', null, { start: '0', count: String(N) }, null, 'done');
  const after = g.flowAt;
  g.flowAt = init + '.body';
  const i = init + '.index';
  const coord = (a, m, o) => g.math('x * 0.1f', { x: g.cast('float', g.math(`i * ${a} % ${m} - ${o}`, { i })) });
  g.flow('Call', 'Arrays.Set', { array: pos, index: i, value: g.make('Core.Vec3', { X: coord(37, 101, 50), Y: coord(59, 103, 51), Z: coord(71, 107, 53) }) });
  g.flow('Call', 'Arrays.Set', { array: vel, index: i, value: g.get('Core.Vec3.Zero') });
  g.flow('Call', 'Arrays.Set', { array: mass, index: i, value: g.math('1.0f + x * 0.25f', { x: g.cast('float', g.math('i % 7', { i })) }) });
  g.flowAt = after;
  const sw = g.flow('Local', 'Stopwatch', { startNow: 'true' }, ['set ctor (bool)']) + '.object';
  const steps = g.flow('For', null, { start: '0', count: String(STEPS) }, null, 'done');
  const afterSteps = g.flowAt;
  g.flowAt = steps + '.body';
  {
    // velocities
    const li = g.flow('For', null, { start: '0', count: String(N) }, null, 'done');
    const afterI = g.flowAt;
    g.flowAt = li + '.body';
    const ii = li + '.index';
    g.flow('Set', 'local:acc', { value: g.get('Core.Vec3.Zero') });
    const lj = g.flow('For', null, { start: '0', count: String(N) }, null, 'done');
    const afterJ = g.flowAt;
    g.flowAt = lj + '.body';
    const jj = lj + '.index';
    const ix = (a, k) => { const id = g.node('Index'); g.feed(id, 'collection', a); g.feed(id, 'index', k); return id + '.value'; };
    const d = g.op('-', ix(pos, jj), ix(pos, ii));
    const r2 = g.math('l + 0.01f', { l: g.call('Core.Vec3.LengthSquared', { receiver: d }) });
    const inv = g.math('1.0f / Sqrt(r)', { r: r2 });
    const s = g.math('m * (k * k * k)', { m: ix(mass, jj), k: inv });
    g.flow('Set', 'local:acc', { value: g.math('a + d * s', { a: g.get('local:acc'), d, s }) });
    g.flowAt = afterJ;
    g.flow('Call', 'Arrays.Set', { array: vel, index: ii, value: g.math('v + a * 0.01f', { v: ix(vel, ii), a: g.get('local:acc') }) });
    g.flowAt = afterI;
    // positions
    const lp = g.flow('For', null, { start: '0', count: String(N) }, null, 'done');
    const afterP = g.flowAt;
    g.flowAt = lp + '.body';
    const pi = lp + '.index';
    g.flow('Call', 'Arrays.Set', { array: pos, index: pi, value: g.math('p + v * 0.01f', { p: ix(pos, pi), v: ix(vel, pi) }) });
    g.flowAt = afterP;
  }
  g.flowAt = afterSteps;
  const sumLoop = g.flow('For', null, { start: '0', count: String(N) }, null, 'done');
  const afterSum = g.flowAt;
  g.flowAt = sumLoop + '.body';
  {
    const id = g.node('Index'); g.feed(id, 'collection', pos); g.feed(id, 'index', sumLoop + '.index');
    const b = g.brk('Core.Vec3', id + '.value');
    const asD = c => g.cast('double', b(c));
    g.flow('Set', 'local:sum', { value: g.math('x + y + z', { x: asD('X'), y: asD('Y'), z: asD('Z') }) }, ['set op +=']);
  }
  g.flowAt = afterSum;
  const us = g.flow('Call', 'Stopwatch.ElapsedMicroseconds', { receiver: sw });
  g.flow('Call', 'this.Report', { checksum: g.cast('int', g.math('s * 1000.0', { s: g.get('local:sum') })), micros: us + '.result' });
  for (const a of [pos, vel, mass]) g.flow('Delete', null, { object: a });
  g.ret('0');
});
t.fn('Report', { static: true, pure: false, params: [['checksum', 'int'], ['micros', 'int']], doc: 'Prints the checksum and the elapsed microseconds, one line each.' }, g => {
  g.flow('Call', 'Console.Write(StringView)', { text: '"checksum "' });
  g.flow('Call', 'Console.WriteLine(int)', { value: g.arg('checksum') });
  g.flow('Call', 'Console.Write(StringView)', { text: '"us "' });
  g.flow('Call', 'Console.WriteLine(int)', { value: g.arg('micros') });
  g.ret();
});
const kdir = path.join(dir, 'nbody-mathlib');
fs.mkdirSync(kdir, { recursive: true });
t.save(kdir);
fs.writeFileSync(path.join(kdir, 'NbodyMathlib.tproj'), '# tproj 1\nproject NbodyMathlib\n\tkind console\n\tentry Bench.Program\n\tversion 0.1.0\nconfig Debug\n\tchecks on\n\toptimize 0\nconfig Release\n\toptimize 2\n\tchecks off\n');
