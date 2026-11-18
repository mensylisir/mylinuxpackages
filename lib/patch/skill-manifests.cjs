#!/usr/bin/env node
/*
 * mylinuxpackages: generate Linux skill dependency manifests (own code).
 * Upstream skill manifests pin darwin/win32 artifacts; the app resolves
 * dependencies.<platform>.json at runtime, so we emit a linux variant that
 * lets pip/npm resolve the current platform instead of forcing macOS wheels.
 * Usage: node skill-manifests.cjs <skills-dir>
 */
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const skillsDir = process.argv[2];
if (!skillsDir) { console.error('usage: skill-manifests.cjs <skills-dir>'); process.exit(2); }
const FOREIGN = /darwin|win32|windows|macosx/i;
let written = 0;
for (const skill of fs.readdirSync(skillsDir)) {
  const src = path.join(skillsDir, skill, 'dependencies.json');
  if (!fs.existsSync(src)) continue;
  const m = JSON.parse(fs.readFileSync(src, 'utf8'));
  for (const layer of Object.values(m.layers || {})) {
    for (const kind of ['pip', 'npm']) {
      if (!Array.isArray(layer[kind])) continue;
      layer[kind] = layer[kind].filter(dep => {
        if (FOREIGN.test(dep.name || '')) return false;
        if (dep.artifact && FOREIGN.test(dep.artifact.path || '')) delete dep.artifact;
        return true;
      });
    }
    for (const tool of layer.system || []) {
      if (!tool.linux) tool.linux = { method: 'unsupported' };
    }
  }
  fs.writeFileSync(path.join(skillsDir, skill, 'dependencies.linux.json'),
    JSON.stringify(m, null, 2) + '\n');
  written++;
}
console.log(`linux skill manifests written: ${written}`);
