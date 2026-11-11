const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const root=path.resolve(__dirname,'..');
const read=file=>fs.readFileSync(path.join(root,file),'utf8');
const index=read('index.html');
const main=read('assets/kapani-main-classic.js');
const css=read('assets/kapani-forest.css');
const sql=read('supabase/031_mayor_orders_referrals_and_display_job.sql');
const installer=read('INSTALL.sql');
const sw=read('firebase-messaging-sw.js');

assert.match(main,/supabase\.rpc\('kp_mayor_delete_order_v31'/);
assert.doesNotMatch(main,/window\.adminDeleteOrder=async function\(id\)\{await remove\(orderRef\(id\)\)/);
assert.match(main,/Не удалось удалить заказ:/,'mayor sees server errors');
assert.match(sql,/kp_mayor_delete_order_v31/);
assert.match(sql,/refund_amount>0/,'unsettled escrow is refunded');
assert.match(sql,/public\.kp_v8_money\(customer,refund_amount/,'refund uses protected ledger');
assert.match(sql,/kp_mayor_order_archive/,'removed orders retain audit copy');
assert.match(sql,/actor is distinct from 'Кайон'/);

assert.match(main,/supabase\.rpc\('kp_set_display_job_v31'/);
assert.match(sql,/You do not have this active job/,'profile cannot impersonate another job');
assert.match(main,/getUserBusinessRoleLabel\(allUsersCache\[currentNick\]/,'visible job refreshes');

assert.match(main,/supabase\.rpc\('kp_claim_signup_referrer_v31'/);
assert.match(main,/window\.repairSignupReferral=/);
assert.match(sql,/Referrer has already been recorded/,'inviter may be recorded once');
assert.match(sql,/now_ms-created_ms>259200000/,'recovery expires after three days');
assert.match(sql,/kp_v8_role\(advertiser\.key,'Рекламщик'\)/,'mayor lists every active job');
assert.match(index,/id="inviterRepairWrap"/);
assert.match(index,/id="firstVisitTourLauncher"/);
assert.match(main,/scheduleFirstVisitTour\(profileSnapshot/);
assert.match(main,/profile startup failed/,'network timeout reveals app shell');
assert.match(css,/\.kp-first-visit-launcher\[hidden\]/);

assert.match(main,/for\(let attempt=0;attempt<2;attempt\+\+\)/,'bank retries idempotent reads');
assert.match(main,/renderRecentTransfers\(\)/);
assert.match(main,/Сайт открыт как локальный файл/,'file protocol diagnostic');
assert.match(sw,/kapani-static-v36/);
assert.match(index,/kapani-main-classic\.js\?v=36/);
assert.ok(installer.includes(sql.trim()),'installer contains v31 migration');

console.log('OK: mayor order removal, referral recovery, displayed jobs, onboarding and bank retries.');
