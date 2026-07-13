#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
node -e "
var haml = require('haml');
var fs = require('fs');
var input = fs.readFileSync('priv/static/index.haml', 'utf8');
var output = haml.render(input);
fs.writeFileSync('priv/static/index.html', output);
"
echo "haml: index.haml -> index.html"
