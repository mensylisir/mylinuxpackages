#!/usr/bin/env node
/*
 * mylinuxpackages: disable CatPaw's invisible overlay window on Linux (own code).
 *
 * The overlay is a shown-but-transparent fixed window hidden via setOpacity(0),
 * which only works on macOS/Windows; on Linux (esp. Wayland) it maps as an
 * empty, non-movable window. We rewrite the Linux branch to hide()/show() and
 * repack the ASAR. Every anchor must match exactly once so an upstream change
 * fails the build rather than silently shipping a broken overlay.
 * Usage: node overlay-linux.cjs <app.asar>
 */
'use strict';
const fs = require('node:fs');
const MARKER = 'mlp-overlay-linux';
const asarPath = process.argv[2];
if (!asarPath) { console.error('usage: overlay-linux.cjs <app.asar>'); process.exit(2); }

function readHeader(file) {
  const fd = fs.openSync(file, 'r');
  const p = Buffer.alloc(16); fs.readSync(fd, p, 0, 16, 0);
  if (p.readUInt32LE(0) !== 4) throw new Error('unexpected asar prefix');
  const hs = p.readUInt32LE(4), jl = p.readUInt32LE(12);
  const json = Buffer.alloc(jl); fs.readSync(fd, json, 0, jl, 16);
  return { fd, header: JSON.parse(json.toString('utf8')), dataOffset: 8 + hs };
}
function collectPacked(root) {
  const out = [];
  (function walk(node, base) {
    for (const [name, e] of Object.entries(node.files || {})) {
      const rel = base ? `${base}/${name}` : name;
      if (e.files) walk(e, rel);
      else if (!e.link && !e.unpacked) out.push({ rel, entry: e });
    }
  })(root, '');
  return out;
}
function readEntry(fd, base, e) {
  const size = Number(e.size), buf = Buffer.alloc(size);
  let pos = Number(e.offset), left = size;
  while (left > 0) {
    const n = fs.readSync(fd, buf, size - left, left, base + pos);
    if (!n) throw new Error('short read at ' + pos);
    pos += n; left -= n;
  }
  return buf;
}
const RULES = [
  { old: "this.overlayWindow.loadURL(`about:blank`),this.makeOverlayInvisible(),this.overlayWindow.showInactive(),",
    new: "this.overlayWindow.loadURL(`about:blank`),this.makeOverlayInvisible(),process.platform!==`linux`&&this.overlayWindow.showInactive(),",
    must: 'process.platform!==`linux`&&this.overlayWindow.showInactive()' },
  { old: 'this.overlayWindow.setOpacity(0)',
    new: 'process.platform===`linux`&&this.overlayWindow.hide(),this.overlayWindow.setOpacity(0)',
    must: 'this.overlayWindow.hide()' },
  { old: 'this.overlayWindow.setIgnoreMouseEvents(!1)',
    new: 'this.overlayWindow.setIgnoreMouseEvents(!1),process.platform===`linux`&&!this.overlayWindow.isVisible()&&this.overlayWindow.showInactive()',
    must: '&&!this.overlayWindow.isVisible()&&this.overlayWindow.showInactive()' },
  { old: 'process.platform===`darwin`&&!r.isVisible()&&r.showInactive()',
    new: '(process.platform===`darwin`||process.platform===`linux`)&&!r.isVisible()&&r.showInactive()',
    must: '(process.platform===`darwin`||process.platform===`linux`)&&!r.isVisible()&&r.showInactive()' },
];

try {
  const { fd, header, dataOffset } = readHeader(asarPath);
  const packed = collectPacked(header);
  let target = null, targetBuf = null;
  for (const item of packed) {
    if (!item.rel.startsWith('dist-electron/') || !item.rel.endsWith('.js')) continue;
    const buf = readEntry(fd, dataOffset, item.entry);
    if (buf.includes('makeOverlayInvisible(t){')) {
      if (target) throw new Error('multiple overlay bundles found');
      target = item; targetBuf = buf;
    }
  }
  if (!target) throw new Error('overlay bundle not found in dist-electron/');
  let source = targetBuf.toString('utf8');
  for (const r of RULES) {
    const count = source.split(r.old).length - 1;
    if (count !== 1) throw new Error(`anchor count ${count}: ${r.old.slice(0, 50)}`);
    source = source.replace(r.old, r.new);
    if (!source.includes(r.must)) throw new Error('replacement verification failed');
  }
  const patched = Buffer.from(source, 'utf8');
  console.log(`  patched ${target.rel} (${targetBuf.length} -> ${patched.length})`);
  let offset = 0;
  for (const item of packed) {
    delete item.entry.integrity;
    item.srcOffset = Number(item.entry.offset);
    item.srcSize = Number(item.entry.size);
    item.entry.offset = String(offset);
    offset += item.rel === target.rel ? patched.length : item.srcSize;
    if (item.rel === target.rel) item.entry.size = patched.length;
  }
  const json = Buffer.from(JSON.stringify(header), 'utf8'), J = json.length;
  const padded = (4 + J + 3) & ~3, padding = padded - (4 + J), headerSize = padded + 4;
  const prefix = Buffer.alloc(16);
  prefix.writeUInt32LE(4, 0); prefix.writeUInt32LE(headerSize, 4);
  prefix.writeUInt32LE(headerSize - 4, 8); prefix.writeUInt32LE(J, 12);
  const tmp = `${asarPath}.${MARKER}.tmp`, out = fs.openSync(tmp, 'w');
  fs.writeSync(out, prefix); fs.writeSync(out, json);
  if (padding) fs.writeSync(out, Buffer.alloc(padding));
  const chunk = Buffer.alloc(4 * 1024 * 1024);
  for (const item of packed) {
    if (item.rel === target.rel) { fs.writeSync(out, patched); continue; }
    let pos = item.srcOffset, left = item.srcSize;
    while (left > 0) {
      const n = fs.readSync(fd, chunk, 0, Math.min(chunk.length, left), dataOffset + pos);
      fs.writeSync(out, chunk, 0, n); pos += n; left -= n;
    }
  }
  fs.fsyncSync(out); fs.closeSync(out); fs.closeSync(fd);
  fs.chmodSync(tmp, 0o644); fs.renameSync(tmp, asarPath);
  console.log(`  asar repacked: ${packed.length} entries, payload ${offset} bytes`);
} catch (e) {
  console.error(`error: ${MARKER}: ${e.message}`); process.exit(1);
}
