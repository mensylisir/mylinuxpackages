#!/usr/bin/env node
/*
 * mylinuxpackages: minimal ASAR tooling (own implementation, no npm deps).
 *   unpack <app.asar> <out-dir>     expand an archive including sidecars
 *   shadow <app-dir> <app.asar>     write an archive whose entries all point
 *                                   at the unpacked sidecar tree
 *
 * The shadow form lets us ship a plain directory as <app.asar>.unpacked:
 * Electron reads the index but loads every file from the sidecar, so native
 * module swaps and patches never require rewriting an ASAR payload.
 */
'use strict';
const fs = require('node:fs');
const path = require('node:path');

const FOREIGN =
  /(?:^|[^a-z0-9])(?:darwin|win32|linux|freebsd|openbsd|android|musl|mac|win)(?:[^a-z0-9]|$)/i;

function readArchive(file) {
  const fd = fs.openSync(file, 'r');
  const head = Buffer.alloc(8);
  fs.readSync(fd, head, 0, 8, 0);
  const headerSize = head.readUInt32LE(4);
  const header = Buffer.alloc(headerSize);
  fs.readSync(fd, header, 0, headerSize, 8);
  const jsonLength = header.readUInt32LE(4);
  const tree = JSON.parse(header.subarray(8, 8 + jsonLength).toString('utf8'));
  return { fd, tree, dataStart: 8 + headerSize };
}
function safeJoin(root, rel) {
  const parts = rel.split('/');
  if (parts.some(p => !p || p === '.' || p === '..' || p.includes('\\')))
    throw new Error(`unsafe ASAR path: ${rel}`);
  return path.join(root, ...parts);
}
function unpack(archive, outDir) {
  const sidecar = archive + '.unpacked';
  const { fd, tree, dataStart } = readArchive(archive);
  fs.rmSync(outDir, { recursive: true, force: true });
  fs.mkdirSync(outDir, { recursive: true });
  let packed = 0, copied = 0, skipped = 0;
  const walk = (node, prefix) => {
    for (const [name, e] of Object.entries(node.files || {})) {
      const rel = prefix ? `${prefix}/${name}` : name;
      const target = safeJoin(outDir, rel);
      if (e.files) { fs.mkdirSync(target, { recursive: true }); walk(e, rel); }
      else if (e.link) { fs.mkdirSync(path.dirname(target), { recursive: true }); fs.symlinkSync(e.link, target); }
      else if (e.unpacked) {
        const src = path.join(sidecar, ...rel.split('/'));
        if (!fs.existsSync(src)) {
          if (!FOREIGN.test(rel)) throw new Error(`missing sidecar: ${rel}`);
          skipped++; continue;
        }
        fs.mkdirSync(path.dirname(target), { recursive: true });
        // copyFileSync also clones metadata, which fails with EPERM under
        // sandboxes that deny futimens(); a plain read/write keeps contents only.
        fs.writeFileSync(target, fs.readFileSync(src));
        fs.chmodSync(target, fs.statSync(src).mode & 0o777);
        copied++;
      } else {
        fs.mkdirSync(path.dirname(target), { recursive: true });
        const buf = Buffer.alloc(e.size);
        fs.readSync(fd, buf, 0, e.size, dataStart + Number(e.offset));
        fs.writeFileSync(target, buf);
        if (e.executable) fs.chmodSync(target, 0o755);
        packed++;
      }
    }
  };
  walk(tree, '');
  fs.closeSync(fd);
  console.log(`unpack: ${packed} packed, ${copied} sidecar, ${skipped} foreign sidecars skipped`);
}
function shadow(sourceDir, archive) {
  const u32 = v => { const b = Buffer.alloc(4); b.writeUInt32LE(v); return b; };
  const build = dir => {
    const files = {};
    for (const name of fs.readdirSync(dir).sort()) {
      const full = path.join(dir, name), st = fs.lstatSync(full);
      if (st.isDirectory()) files[name] = { files: build(full).files };
      else if (st.isSymbolicLink()) files[name] = { link: fs.readlinkSync(full) };
      else if (st.isFile()) {
        const e = { size: st.size, unpacked: true };
        if (st.mode & 0o111) e.executable = true;
        files[name] = e;
      }
    }
    return { files };
  };
  const tree = build(sourceDir);
  const json = Buffer.from(JSON.stringify(tree));
  let payload = Buffer.concat([u32(json.length), json]);
  payload = Buffer.concat([payload, Buffer.alloc((4 - (payload.length % 4)) % 4)]);
  const block = Buffer.concat([u32(payload.length), payload]);
  fs.mkdirSync(path.dirname(archive), { recursive: true });
  fs.writeFileSync(archive, Buffer.concat([u32(4), u32(block.length), block]));
  console.log(`shadow: ${archive} (${Object.keys(tree.files).length} top-level entries)`);
}
const [, , cmd, ...args] = process.argv;
if (cmd === 'unpack' && args.length === 2) unpack(args[0], args[1]);
else if (cmd === 'shadow' && args.length === 2) shadow(args[0], args[1]);
else { console.error('usage: asar-tool.cjs unpack <asar> <dir> | shadow <dir> <asar>'); process.exit(2); }
