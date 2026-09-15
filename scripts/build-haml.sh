#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
node -e "
var haml = require('haml');
var fs = require('fs');
var version = fs.readFileSync('VERSION', 'utf8').trim();
if (!/^\\d+\\.\\d+\\.\\d+(?:-\\d+)?$/.test(version)) throw new Error('invalid VERSION');
var input = fs.readFileSync('priv/static/index.haml', 'utf8').replaceAll('__PLAINWIRE_VERSION__', version);
var output = haml.render(input);
fs.writeFileSync('priv/static/index.html', output);
"
echo "haml: index.haml -> index.html"
