#!/usr/bin/env node
/*
 * mylinuxpackages: Kimi Work region pin (own implementation).
 *
 * Pins the runtime region to a constant, points resource lookups at our own
 * /opt prefix via KIMI_WORK_RESOURCES, and gives each edition a distinct
 * window class. Shortcut suppression is handled separately by
 * kimi-work-shortcut.cjs for all three variants. Every patch point must match
 * exactly once so an upstream layout change fails the build loudly.
 *
 * Usage: node kimi-work-region.cjs <asar-dir> <china|overseas> <app-name>
 */
'use strict';
const fs = require('fs');
const path = require('path');
const root = process.argv[2], region = process.argv[3], appName = process.argv[4];
if (!root || !['china', 'overseas'].includes(region) || !appName) {
  console.error('usage: kimi-work-region.cjs <dir> <china|overseas> <app-name>');
  process.exit(1);
}

const pkgPath = path.join(root, 'package.json');
const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
pkg.name = appName;
pkg.desktopName = region === 'china' ? 'kimi-work-cn.desktop' : 'kimi-work-intl.desktop';
fs.writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + '\n');

const mainPath = path.join(root, pkg.main);
let source = fs.readFileSync(mainPath, 'utf8');
function replaceOnce(re, replacement, label) {
  const hits = [...source.matchAll(re)];
  if (hits.length !== 1) { console.error(`${label}: ${hits.length} matches (expected 1)`); process.exit(1); }
  source = source.replace(re, replacement);
}

// 1. Region getter -> constant.
replaceOnce(
  /function (_0x[0-9a-f]+)\(\) \{\n  if \(_0x[0-9a-f]+\) return _0x[0-9a-f]+;\n  if \(_0x[0-9a-f]+\) return _0x[0-9a-f]+;\n  return _0x[0-9a-f]+;\n\}/g,
  (_m, name) => `function ${name}() {\n  return "${region}";\n}`, 'region getter');

// 2. Persisted RegionState seed (used directly by KimiEnv for domain choice).
replaceOnce(
  /(_0x[0-9a-f]+) = _0x[0-9a-f]+\[_0x[0-9a-f]+\(\d+\)\], (_0x[0-9a-f]+) = _0x[0-9a-f]+\["lastEffective"\];/g,
  (_m, a, b) => `${a} = null, ${b} = "${region}";`, 'region seed');

// 3. resourcesPath -> our own /opt prefix (string-table id for 3.2.27).
const rpRe = /process\[(_0x[0-9a-f]+)\(24573\)\]/g;
if ((source.match(rpRe) || []).length === 0) {
  console.error('resourcesPath patch point: 0 matches'); process.exit(1);
}
source = source.replace(rpRe, '(process.env["KIMI_WORK_RESOURCES"] || process[$1(24573)])');

// 4. Runtime desktopName (string-table ids for "appId"/".desktop" in 3.2.27).
const desktopName = region === 'china' ? 'kimi-work-cn.desktop' : 'kimi-work-intl.desktop';
replaceOnce(
  /const (_0x[0-9a-f]+) = _0x[0-9a-f]+\[_0x[0-9a-f]+\(10689\)\] \+ _0x[0-9a-f]+\(12514\);/g,
  (_m, v) => `const ${v} = "${desktopName}";`, 'runtime desktopName');

fs.writeFileSync(mainPath, source);
console.log(`patched ${pkg.main}: region=${region}, name=${appName}`);
