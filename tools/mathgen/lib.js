// Type file writer for the math library generator (its output is canonicalised by Treadle.exe --format).
'use strict';
const fs = require('fs');

function b36(n, w) { let s = n.toString(36); while (s.length < w) s = '0' + s; return s; }
function q(s) { return '"' + s.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"'; }

class Sheet {
  constructor(prefix, kind) {
    this.prefix = prefix; this.kind = kind || 'body';
    this.nodes = []; this.wires = []; this.n = 0;
    this.entry = this.node('Entry');
    this.flowAt = this.entry + '.then';
    this._self = null;
  }
  node(kind, subject, lines) {
    const id = this.prefix + b36(this.n++, 2);
    this.nodes.push({ id, kind, subject, lines: lines || [] });
    return id;
  }
  find(id) { return this.nodes.find(n => n.id === id); }
  wire(from, to) { this.wires.push([from, to]); }
  // an input: a pin reference ("id.pin") or a literal (number / string token)
  feed(id, pin, v) {
    if (v === undefined || v === null) return;
    if (v instanceof String) v = String(v);
    if (typeof v === 'object' && v.pin) { this.wire(v.pin, id + '.' + pin); return; }
    if (typeof v === 'string' && /^[a-z0-9]+\.[A-Za-z0-9_.:]+$/.test(v) && this.find(v.split('.')[0])) { this.wire(v, id + '.' + pin); return; }
    this.find(id).lines.push('in ' + pin + ' ' + v);
  }
  arg(name) { return this.entry + '.' + name; }
  self() { if (!this._self) this._self = this.node('This') + '.value'; return this._self; }
  math(expr, inputs) {
    const id = this.node('Math', null, ['set expr ' + q(expr)]);
    // only the names the expression reads (not field names after a dot, not function names)
    const used = new Set();
    const re = /(^|[^.A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)(?![A-Za-z0-9_]|\s*\()/g;
    let mm;
    while ((mm = re.exec(expr))) used.add(mm[2]);
    for (const k of Object.keys(inputs || {})) if (used.has(k)) this.feed(id, k, inputs[k]);
    return id + '.result';
  }
  make(type, fields) {
    const id = this.node('Make', type);
    for (const k of Object.keys(fields)) this.feed(id, k, fields[k]);
    return id + '.value';
  }
  brk(type, v) {
    const id = this.node('Break', type);
    this.feed(id, 'value', v);
    return f => id + '.' + f;
  }
  get(subject, receiver) {
    const id = this.node('Get', subject);
    if (receiver) this.feed(id, 'receiver', receiver);
    return id + '.value';
  }
  op(sym, a, b) {
    const id = this.node('Operator', sym);
    this.feed(id, 'a', a); if (b !== undefined) this.feed(id, 'b', b);
    return id + '.result';
  }
  select(c, t, f) {
    const id = this.node('Select');
    this.feed(id, 'condition', c); this.feed(id, 'true', t); this.feed(id, 'false', f);
    return id + '.result';
  }
  cast(type, v) {
    const id = this.node('Cast', type);
    this.feed(id, 'value', v);
    return id + '.result';
  }
  // a pure call: returns the result pin; outs via id
  call(subject, args, extra) {
    const id = this.node('Call', subject, extra);
    for (const k of Object.keys(args || {})) this.feed(id, k, args[k]);
    const r = id + '.result';
    return Object.assign(new String(r), { id, out: n => id + '.' + n });
  }
  // a flow node in the chain (Call, Set, ...): wired from the current flow position
  flow(kind, subject, args, extra, thenPin) {
    const id = this.node(kind, subject, extra);
    this.wire(this.flowAt, id + '.in');
    for (const k of Object.keys(args || {})) this.feed(id, k, args[k]);
    this.flowAt = id + '.' + (thenPin || 'then');
    return id;
  }
  ret(value, outs) {
    const id = this.node('Return');
    this.wire(this.flowAt, id + '.in');
    if (value !== undefined && value !== null) this.feed(id, 'value', value);
    for (const k of Object.keys(outs || {})) this.feed(id, k, outs[k]);
    return id;
  }
  write(out) {
    out.push('sheet ' + this.kind);
    for (const n of this.nodes) {
      out.push('node ' + n.id + ' ' + n.kind + (n.subject ? ' ' + n.subject : ''));
      for (const l of n.lines) out.push('\t' + l);
    }
    for (const [a, b] of this.wires) out.push('wire ' + String(a) + ' ' + String(b));
  }
}

class TypeFile {
  constructor(name, kind, props) {
    this.name = name; this.kind = kind; this.props = props || [];
    this.members = []; this.m = 0;
    const code = name.toLowerCase().replace(/[^a-z0-9]/g, '');
    this.code = code.slice(0, 1);
  }
  pfx() { return this.code + b36(this.m++, 3); }
  field(name, type, props) { this.members.push({ text: ['field ' + name + ' ' + type, ...(props || []).map(p => '\t' + p)] }); }
  // kind: function | operator | ctor | property
  member(kind, name, opts, body) {
    const id = this.pfx();
    const lines = [];
    if (kind === 'function') lines.push('function ' + id + ' ' + name);
    else if (kind === 'operator') lines.push('operator ' + id + ' ' + name);
    else if (kind === 'ctor') lines.push('ctor ' + id);
    else if (kind === 'property') lines.push('property ' + id + ' ' + name + ' ' + opts.type);
    const P = [];
    if (opts.static) P.push('static');
    if (opts.pure !== false && kind !== 'ctor' && kind !== 'property') P.push('pure');
    if (opts.mutating) P.push('mutating');
    if (opts.unsafe) P.push('unsafe');
    if (opts.ret && kind !== 'property') P.push('returns ' + opts.ret);
    for (const g of opts.generic || []) P.push('generic ' + g);
    for (const a of opts.attrs || []) P.push('attr ' + a);
    if (opts.doc) P.push('doc ' + q(opts.doc));
    for (const p of P) lines.push('\t' + p);
    for (const p of opts.params || []) {
      lines.push('param ' + p[0] + ' ' + p[1]);
      if (p[2] !== undefined) lines.push('\tdefault ' + p[2]);
    }
    for (const o of opts.outs || []) lines.push('out ' + o[0] + ' ' + o[1]);
    for (const l of opts.locals || []) lines.push('local ' + l[0] + ' ' + l[1] + (l[2] !== undefined ? '\n\tinit ' + l[2] : ''));
    if (body) {
      const s = new Sheet('n' + id.slice(1), kind === 'property' ? 'get' : 'body');
      const v = body(s);
      if (v !== undefined && !s.nodes.some(n => n.kind === 'Return')) s.ret(v);
      if (v === undefined && !s.nodes.some(n => n.kind === 'Return')) s.ret();
      s.write(lines);
    }
    this.members.push({ text: lines });
  }
  fn(name, opts, body) { this.member('function', name, opts, body); }
  op(sym, opts, body) { this.member('operator', sym, Object.assign({ static: true }, opts), body); }
  prop(name, opts, body) { this.member('property', name, opts, body); }
  ctor(opts, body) { this.member('ctor', null, Object.assign({ pure: false }, opts), body); }
  text() {
    const out = ['# treadle 1', 'type ' + this.name + ' ' + this.kind];
    for (const p of this.props) out.push('\t' + p);
    for (const m of this.members) { out.push(''); out.push(...m.text); }
    return out.join('\n') + '\n';
  }
  save(dir) { fs.writeFileSync(dir + '/' + this.name + '.treadle', this.text()); }
}

module.exports = { TypeFile, Sheet, q };
