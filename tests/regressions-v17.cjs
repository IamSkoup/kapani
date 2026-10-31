// Static guard for secure resignation and persistent Supabase authentication.
// A live database integration test still requires the owner's Supabase project.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const root=path.resolve(__dirname,'..');
const read=relative=>fs.readFileSync(path.join(root,relative),'utf8');
const main=read('assets/kapani-main-classic.js');
const bridge=read('assets/supabase-bridge-classic.js');
const sql=read('supabase/021_secure_quit_job.sql');
const html=read('index.html');

const quitCode=main.split('window.quitJob = async function(){')[1].split('\n};')[0];
assert.match(quitCode,/supabase\.rpc\('kp_quit_job',\s*\{/);
assert.match(quitCode,/p_employment_id:\s*targetEmp\.id/);
assert.doesNotMatch(quitCode,/update\(userRef\(nick\)/,'resignation must not patch protected user roles');
assert.doesNotMatch(quitCode,/update\(bizItemRef\(/,'business membership must be changed atomically on server');
assert.match(quitCode,/if\(quitError\) throw/,'must fail if the server rejects resignation');

assert.match(sql,/where user_id=auth\.uid\(\)/,'server must derive ownership from auth UID');
assert.match(sql,/where branch='users' for update/,'server must lock the user record');
assert.match(sql,/where branch='businesses' for update/,'server must lock business membership');
assert.match(sql,/perform public\.kp_v8_put\('users'/);
assert.match(sql,/perform public\.kp_v8_put\('businesses'/);
assert.match(sql,/grant execute on function public\.kp_quit_job\(text\) to authenticated/);
assert.doesNotMatch(sql,/kp_wallets|kp_ledger|service_role/,'resignation must not touch the protected wallet');

assert.doesNotMatch(bridge,/timeout\s*>\s*0\s*\?\s*Math\.max\(1500,\s*timeout\)\s*:\s*10000/);
const ensureAuth=main.split('async function ensureAuth(){')[1].split('\nasync function ensureFunctions()')[0];
assert.match(ensureAuth,/throw error/,'failed auth verification must not invalidate local identity');
assert.match(ensureAuth,/throw profileError/,'failed profile lookup must not look like signout');
const boot=main.split('async function bootstrapKapaniAuthAndApp(){')[1].split('\n\/\/ DO NOT hide')[0];
assert.doesNotMatch(boot,/localStorage\.removeItem\('kp_s'\)/,'bootstrap must not erase remembered nick');
assert.match(boot,/withKapaniAuthRetry\(/);
assert.match(boot,/if\(!appStarted && currentNick===expectedNick\)/);
assert.match(html,/supabase-bridge-classic\.js\?v=17/);
assert.match(html,/kapani-main-classic\.js\?v=20/);

console.log('OK: v17 secure resignation and persistent session regression contracts.');
