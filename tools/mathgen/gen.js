'use strict';
// node gen.js <core dir> [overloads] [vectors]
const fs = require('fs');
const common = require('./common');
const dir = process.argv[2];
common.opts.overloads = process.argv.includes('overloads');
common.opts.vectors = process.argv.includes('vectors');
const { vector } = require('./vec');
const { matrix } = require('./mat');
const { quat } = require('./quat');
const misc = require('./misc');
const { mathFormat } = require('./fmt');
const { mathAdditions } = require('./mathadd');

const types = [];
for (const n of Object.keys(common.VECS)) types.push(vector(n));
types.push(matrix(3), matrix(4), quat(), misc.color(), misc.color32(), misc.rect(false), misc.rect(true), misc.aabb(), misc.plane(), misc.ray(), misc.transform(), mathFormat());
for (const t of types) t.save(dir);
fs.writeFileSync(dir + '/Math.treadle', mathAdditions());
console.log(types.map(t => t.name + '.treadle').join(' '));
