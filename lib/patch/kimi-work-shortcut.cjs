#!/usr/bin/env node
/*
 * mylinuxpackages: Kimi Work launcher-shortcut suppression (own implementation).
 *
 * Disables the launcher global shortcut by default so Wayland's XDG
 * GlobalShortcuts portal does not prompt with an "Add keyboard" / shortcut
 * authorization dialog on first launch. Applied to all three Kimi Work
 * variants, including the default region build.
 *
 * Usage: node kimi-work-shortcut.cjs <asar-dir>
 */
'use strict';
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
if (!root) {
  console.error('usage: kimi-work-shortcut.cjs <asar-dir>');
  process.exit(1);
}

const pkg = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
const mainPath = path.join(root, pkg.main);
let source = fs.readFileSync(mainPath, 'utf8');

function replaceOnce(re, replacement, label) {
  const hits = [...source.matchAll(re)];
  if (hits.length !== 1) {
    console.error(`${label}: ${hits.length} matches (expected 1)`);
    process.exit(1);
  }
  source = source.replace(re, replacement);
}

replaceOnce(/"launcherEnabled": !!\[\], "launcherShortcut": /g,
  '"launcherEnabled": ![], "launcherShortcut": ', 'launcher default');
replaceOnce(/"launcherEnabled": ([^,\n]+) !== !\[\],/g,
  '"launcherEnabled": $1 === !![],', 'launcher read');

fs.writeFileSync(mainPath, source);
console.log(`patched ${pkg.main}: launcher global shortcut disabled`);
