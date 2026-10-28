// Static regression for the authenticated migration boundary. Live SQL still requires Supabase.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const root=path.resolve(__dirname,'..');
const read=p=>fs.readFileSync(path.join(root,p),'utf8');
const sql=read('supabase/020_tasks_and_transaction_receipts.sql');
const installer=read('INSTALL.sql');
const js=read('assets/kapani-main-classic.js');
const html=read('index.html');
const css=read('assets/kapani-v16.css');
assert.ok(installer.includes(sql.trim()),'standalone migration must also be in INSTALL');
for(const id of ['transfer','shop','taxi_req','prime_listing','prime_transfer_big','prime_taxi2','prime_shop_big']){
  assert.match(sql,new RegExp(`'${id}'`),`server must verify ${id}`);
}
assert.match(sql,/where l\.user_id=auth\.uid\(\)/,'ledger proof must be scoped to caller');
assert.match(sql,/if claimed \? p_task_id then return/,'daily claim must be idempotent');
assert.match(sql,/l\.created_at>=to_timestamp\(day_start\/1000\.0\)/,'daily proof must use the server date');
assert.match(sql,/jsonb_build_object\(\s*'id'/,'receipts must retain operation IDs');
assert.match(sql,/'details',details/,'the UI needs service and commission details');
assert.match(js,/pendingTaskClaims\.has\(claimKey\)/,'duplicate claims must be blocked');
assert.match(js,/address\.length<3\|\|address\.length>120/,'dispatch validation must match server bounds');
assert.doesNotMatch(js,/sheet\.addEventListener\('touchend', onTouchEnd/,'list swipes must not close history');
assert.doesNotMatch(html,/onclick="kapaniPushRepair\(\)"/,'repair control removed from profile');
assert.doesNotMatch(html,/id="pushWorkerStatus"/,'raw diagnostics removed from profile');
assert.match(css,/#messages #chatMessages,#messages #dmMessages \{/,'message stream has independent scroll region');
assert.match(html,/kapani-v16\.css\?v=16/);
console.log('OK: v16 migration, receipts, dispatch validation and chat shell contracts.');
