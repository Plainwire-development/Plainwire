import * as sass from 'sass';
import less from 'less';
import { readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(fileURLToPath(new URL('..', import.meta.url)));
const version = (await readFile(resolve(root, 'VERSION'), 'utf8')).trim();
if (!/^\d+\.\d+\.\d+(?:-\d+)?$/.test(version)) throw new Error('invalid VERSION');

const base = sass.compile(resolve(root, 'priv/static/style.scss'), {});
const layerSource = await readFile(resolve(root, 'priv/static/style.less'), 'utf8');
const layer = await less.render(layerSource, {
  filename: resolve(root, 'priv/static/style.less'),
  paths: [resolve(root, 'priv/static')],
});

const fingerprint = `/* Plainwire ${version} workspace */\n`;
const css = fingerprint + base.css.trim() + '\n' + layer.css.trim() + '\n';
await writeFile(resolve(root, 'priv/static/app.css'), css);
console.log(`css: app.css (${css.length} bytes; scss ${base.css.length} + less ${layer.css.length}; version ${version})`);
