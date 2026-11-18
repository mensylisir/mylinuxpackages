#!/usr/bin/env node
/*
 * kimi-code region pin (mylinuxpackages own implementation).
 *
 * Kimi Code decides its API region at runtime from env / login state. For a
 * deterministic CN vs international build we replace that decision with a
 * fixed constant, isolate the Electron userData directory (package name),
 * and give each edition its own WM_CLASS / custom URL scheme.
 *
 * Usage: node kimi-code-region.cjs <asar-extract-dir> <mainland-cn|global> <app-name>
 */
'use strict';
const fs = require('fs');
const path = require('path');

const root = process.argv[2];
const region = process.argv[3];
const appName = process.argv[4];
if (!root || !['mainland-cn', 'global'].includes(region) || !appName) {
  console.error('usage: kimi-code-region.cjs <dir> <mainland-cn|global> <app-name>');
  process.exit(1);
}

const outDir = path.join(root, 'out');
const jsFiles = fs.readdirSync(outDir)
  .filter(f => f.endsWith('.cjs') || f.endsWith('.js'))
  .map(f => path.join(outDir, f));

// 1. userData isolation: Electron derives the config dir from package.name.
const pkgPath = path.join(root, 'package.json');
const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
pkg.name = appName;
pkg.desktopName = region === 'mainland-cn'
  ? 'kimi-code-cn.desktop' : 'kimi-code-intl.desktop';
fs.writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + '\n');

// 2. Region decision: 1.3.4+ minifies it to a single function reading oauth
//    host env vars. Locate by its distinctive signature + first return, and
//    require exactly one candidate so an upstream change fails loudly.
const regionRe =
  /function ([A-Za-z_$][\w$]*)\(e\)\{let t=e\.env\?\?process\.env,n=t\.KIMI_CODE_OAUTH_HOST\?\?t\.KIMI_OAUTH_HOST;if\(n!==void 0&&n\.length>0\)return\{region:/;
const candidates = [];
for (const file of jsFiles) {
  const src = fs.readFileSync(file, 'utf8');
  if (regionRe.test(src)) candidates.push({ file, src });
}
if (candidates.length !== 1) {
  console.error(`region function candidates: ${candidates.length} (expected 1)`);
  process.exit(1);
}
const { file, src } = candidates[0];
const m = src.match(regionRe);
const start = m.index;
const next = src.indexOf('function ', start + m[0].length);
if (next < 0) { console.error('cannot find region function boundary'); process.exit(1); }
const replacement =
  `function ${m[1]}(e){return{region:\`${region}\`,source:\`env\`}}`;
fs.writeFileSync(file, src.slice(0, start) + replacement + src.slice(next));
console.log(`region pinned: ${region} in ${path.basename(file)}`);

// 3. CN build uses a separate custom scheme so xdg-handler registration does
//    not collide with the international edition.
if (region === 'mainland-cn') {
  const schemeRe = /const ([A-Za-z_$][\w$]*)=`kimi-code`;/g;
  let registered = 0, checks = 0;
  for (const file of jsFiles) {
    let src = fs.readFileSync(file, 'utf8');
    const n = (src.match(schemeRe) || []).length;
    const c = src.split('protocol===`kimi-code:`').length - 1;
    if (!n && !c) continue;
    src = src.replace(schemeRe, (_all, name) => `const ${name}=\`kimi-code-cn\`;`);
    src = src.split('protocol===`kimi-code:`').join('protocol===`kimi-code-cn:`');
    fs.writeFileSync(file, src);
    registered += n; checks += c;
  }
  if (registered !== 1 || checks === 0) {
    console.error(`scheme patch counts: register=${registered} check=${checks}`);
    process.exit(1);
  }
  console.log(`scheme isolated: kimi-code-cn (${registered} register, ${checks} checks)`);
}
