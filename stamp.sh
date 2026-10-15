#!/bin/sh
# Fingerprints the CSS and JS in index.html (?v=<hash of the file>) so a
# browser holding a cached copy fetches the new one as soon as it changes.
# GitHub Pages serves everything with a 10-minute cache. Run before each
# commit that touches style.css, page.js or math.js.
set -e
cd "$(dirname "$0")"
hash() { shasum "$1" | cut -c1-10; }
# math.js first: its fingerprint goes into page.js, which changes page.js's.
sed -i '' -E "s#from \"\\./math\\.js(\\?v=[0-9a-f]+)?\"#from \"./math.js?v=$(hash math.js)\"#" page.js
CSS=$(hash style.css)
JS=$(hash page.js)
sed -i '' -E "s#href=\"style\\.css(\\?v=[0-9a-f]+)?\"#href=\"style.css?v=$CSS\"#" index.html
sed -i '' -E "s#src=\"page\\.js(\\?v=[0-9a-f]+)?\"#src=\"page.js?v=$JS\"#" index.html
echo "style.css?v=$CSS page.js?v=$JS"
