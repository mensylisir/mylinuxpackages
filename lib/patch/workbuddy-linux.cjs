#!/usr/bin/env node
/*
 * mylinuxpackages: WorkBuddy Linux compatibility patch (own implementation).
 * Upstream's enterprise IM channel backend is instantiated for non-overseas
 * builds but its native binding has no Linux build, so the daemon fails to
 * boot. Upstream ships a headless fallback for the overseas edition; take
 * that path on Linux too.
 * Usage: node workbuddy-linux.cjs <unpacked-app-dir>
 */
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const appDir = process.argv[2];
if (!appDir) { console.error('usage: workbuddy-linux.cjs <app-dir>'); process.exit(2); }
const file = path.join(appDir, 'main', 'daemon-bootstrap.js');
let source = fs.readFileSync(file, 'utf8');
const anchor =
  /(function createDesktopImChannelsBackend\([^)]*\)\{)if\(([^;]+?isOversea===!0)\)return (create(?:Headless|Unavailable)ImChannelsBackend)\(\);/;
if (/function createDesktopImChannelsBackend\([^)]*\)\{if\(process\.platform===`linux`\|\|/.test(source)) {
  console.log('patch: already applied'); process.exit(0);
}
if (!anchor.test(source)) {
  console.error('createDesktopImChannelsBackend anchor not found; upstream layout changed');
  process.exit(1);
}
source = source.replace(anchor,
  (_m, head, cond, factory) => `${head}if(process.platform===\`linux\`||${cond})return ${factory}();`);
try { new vm.Script(source); }
catch (e) { console.error(`patched bundle does not parse: ${e.message}`); process.exit(1); }
fs.writeFileSync(file, source);
console.log('patch: Linux uses headless IM channel backend');
