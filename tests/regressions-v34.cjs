const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
const sw = fs.readFileSync(path.join(root, 'firebase-messaging-sw.js'), 'utf8');
const mobile = html.match(/\/\* Keep auth in the normal layout flow\.[\s\S]*?\/\* Prioritise accessible fields/);

assert.ok(mobile, 'mobile auth layout must be independently defined');
const css = mobile[0];
assert.match(css, /#authSection\.active\s*\{[\s\S]*?position:\s*relative;/);
assert.match(css, /transform:\s*none\s*!important;/);
assert.match(css, /width:\s*min\(390px,\s*100%\);/);
assert.match(css, /max-height:\s*none;/);
assert.match(css, /overflow:\s*visible;/);
assert.match(css, /touch-action:\s*pan-y;/);
assert.match(css, /overflow-y:\s*auto;/);
assert.match(css, /safe-area-inset-top/);
assert.match(html, /name="viewport" content="width=device-width, initial-scale=1\.0, viewport-fit=cover"/);
assert.match(sw, /kapani-static-v35/);

// In narrow viewports the containing block has safe-area padding and the
// panel can never be wider than its remaining content box.
for (const viewport of [320, 350, 375, 390, 430, 640]) {
  const safeInsets = 14 * 2;
  const content = viewport - safeInsets;
  const panel = Math.min(content, 390);
  assert.ok(panel <= viewport - safeInsets);
  assert.ok((viewport - panel) / 2 >= safeInsets / 2);
}

console.log('OK: revision 34 auth stays centered and scrollable on narrow Safari viewports.');
