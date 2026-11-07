// Revision 28 offline contract checks. Live SQL and actual UI require separate verification.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const main = read('assets/kapani-main-classic.js');
const html = read('index.html');
const sw = read('firebase-messaging-sw.js');
const cron = read('supabase/028_savings_cron.sql');
const perf = read('supabase/029_rls_and_foreign_key_indexes.sql');
const manifest = JSON.parse(read('manifest.json'));

assert.match(main, /kp_pending_savings:\$\{currentNick\}:\$\{direction\}:\$\{amount\}/);
assert.match(main, /sessionStorage\.setItem\(key,operationId\)/);
assert.match(main, /sessionStorage\.removeItem\(key\)/);
assert.match(main, /if\(savingsMoveBusy\)return/);
assert.match(main, /Number\.isSafeInteger\(amount\)/);
assert.match(main, /window\.addEventListener\('load',\(\)=>\{void getSwReg\(\)/);
assert.match(main, /if\(!data\?\.ok\)throw new Error/);
assert.match(html, /id="savingsOperationStatus"[^>]*role="status"/);
assert.match(html, /rel="manifest" href="\.\/manifest\.json"/);
assert.match(html, /kapani-main-classic\.js\?v=(?:28|29|30)/);
assert.match(html, /kapani-v28\.css\?v=28/);
assert.equal(manifest.id, '/kapani/');
assert.equal(manifest.background_color, '#071811');
for(const icon of manifest.icons){
  const bytes = fs.readFileSync(path.join(root, icon.src));
  assert.equal(bytes.toString('hex', 0, 8), '89504e470d0a1a0a');
  assert.equal(bytes.readUInt32BE(16), Number(icon.sizes.split('x')[0]));
  assert.equal(bytes.readUInt32BE(20), Number(icon.sizes.split('x')[1]));
}
assert.match(sw, /addEventListener\('fetch'/);
assert.match(sw, /event\.request\.mode === 'navigate'/);
assert.match(sw, /url\.origin !== self\.location\.origin/);
assert.match(sw, /cache\.put\(event\.request, response\.clone\(\)\)/);
assert.match(cron, /if current_user <> 'postgres'/);
assert.match(cron, /for update/);
assert.match(cron, /kp_savings_math_v14\(current_profile, now_ms\)/);
assert.match(cron, /revoke all on function kp_internal\.accrue_all_savings\(\)/);
assert.match(cron, /'\*\/10 \* \* \* \*'/);
assert.equal((perf.match(/create index if not exists/g)||[]).length,9);
assert.equal((perf.match(/alter policy /g)||[]).length,10);
new Function(main);
new Function(sw);
console.log('OK: revision 28 bank retries, PWA icons/cache, Cron and RLS contracts.');
