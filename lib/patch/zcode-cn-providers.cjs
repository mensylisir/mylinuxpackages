#!/usr/bin/env node
/*
 * mylinuxpackages: domestic ZCode build pins the built-in provider catalogue
 * so a fresh profile starts on BigModel / 智谱 instead of Z.ai. Only the
 * bundled provider metadata order changes; no application code is touched and
 * every provider remains selectable in the UI.
 * Usage: node zcode-cn-providers.cjs <app-dir>
 */
'use strict';
const fs = require('node:fs');
const path = require('node:path');

const appDir = process.argv[2];
if (!appDir) { console.error('usage: zcode-cn-providers.cjs <app-dir>'); process.exit(2); }

const file = path.join(appDir, 'resources', 'config', 'provider', 'zcode-builtin.json');
const doc = JSON.parse(fs.readFileSync(file, 'utf8'));
const rules = doc && doc.config && doc.config.providerConfigRules;
if (!rules || !Array.isArray(rules.templateRules) || !Array.isArray(rules.providerRules)) {
  console.error('provider rules not found; upstream layout changed');
  process.exit(1);
}
const isDomestic = id => typeof id === 'string' && /bigmodel/.test(id);
function hoist(list, key) {
  const first = list.findIndex(x => isDomestic(x[key]));
  if (first < 0) throw new Error(`no BigModel entry (${key})`);
  if (first === 0) return false;
  const head = list.filter(x => isDomestic(x[key]));
  const rest = list.filter(x => !isDomestic(x[key]));
  list.splice(0, list.length, ...head, ...rest);
  return true;
}
const changed = [hoist(rules.templateRules, 'templateId'), hoist(rules.providerRules, 'providerId')].some(Boolean);
if (changed) fs.writeFileSync(file, JSON.stringify(doc, null, 2) + '\n');
console.log(changed ? 'BigModel providers moved to front' : 'BigModel already first');
for (const [list, key] of [[rules.templateRules, 'templateId'], [rules.providerRules, 'providerId']]) {
  if (!isDomestic(list[0] && list[0][key])) {
    console.error(`${key}[0] is not a BigModel entry; refusing to ship unpatched app`);
    process.exit(1);
  }
}
