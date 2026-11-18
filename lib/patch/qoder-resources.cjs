/*
 * mylinuxpackages: Qoder resourcesPath override (own implementation).
 *
 * Qoder's upstream rpm installs its app under /usr/lib/<name>/resources and
 * launches via the system electron. We ship our own Electron instead, so
 * process.resourcesPath would point at Electron's own resources dir. This
 * preload rewrites it to our app dir and redirects Electron-resources-relative
 * fs lookups into the app dir so product.json / icons / builtin extensions
 * resolve correctly.
 *
 * Usage: injected with `electron --require <this-file> --app <appdir>/app.asar`.
 * The app dir is read from _APPDIR (set by the launcher).
 */
'use strict';
try {
  const path = require('path');
  const fs = require('fs');
  const appDir = process.env._APPDIR;
  if (!appDir || !fs.existsSync(appDir)) return;

  if (process.resourcesPath !== appDir) {
    Object.defineProperty(process, 'resourcesPath', {
      value: appDir, writable: false, configurable: true, enumerable: true,
    });
  }
  if (!process.env.ELECTRON_IS_DEV && !process.env.NODE_ENV) {
    process.env.ELECTRON_IS_DEV = '0';
    process.env.NODE_ENV = 'production';
  }
  if (process.env._APPDIR_NO_FS_REDIRECT) return;

  const electronRes = path.join(path.dirname(process.execPath), 'resources');
  if (electronRes === appDir || !fs.existsSync(appDir)) return;
  let top = null;
  try { top = new Set(fs.readdirSync(appDir)); } catch (_) { return; }
  const prefix = electronRes + path.sep;
  const redirect = p => {
    if (typeof p !== 'string' || !p.startsWith(prefix)) return p;
    const rel = p.slice(prefix.length);
    if (rel.split(path.sep).includes('..')) return p;
    if (!top.has(rel.split(path.sep)[0])) return p;
    return appDir + path.sep + rel;
  };
  const wrap = (obj, name) => {
    const orig = obj[name];
    if (typeof orig !== 'function') return;
    obj[name] = function (p, ...rest) { return orig.call(this, redirect(p), ...rest); };
  };
  for (const n of ['readFile','readFileSync','existsSync','createReadStream','statSync',
                   'lstatSync','accessSync','openSync','realpathSync','readdirSync','opendirSync'])
    wrap(fs, n);
  for (const n of ['readFile','stat','lstat','access','open','realpath','readdir','opendir'])
    wrap(fs.promises, n);
} catch (e) {
  console.error('[resources-override] warning: ' + e.message);
}
