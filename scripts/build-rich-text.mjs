import { build } from 'esbuild';
import { copyFile, mkdir } from 'node:fs/promises';
await Promise.all(['markdown', 'highlight-all'].map(name => build({
  entryPoints: [`web/${name}.js`], outfile: `priv/static/${name}.js`,
  bundle: true, minify: true, format: 'iife', target: ['es2020'], legalComments: 'eof'
})));
await mkdir('priv/static/licenses', { recursive: true });
await Promise.all(['markdown-it', 'highlight.js'].map(name => copyFile(`node_modules/${name}/LICENSE`, `priv/static/licenses/${name}.txt`)));
