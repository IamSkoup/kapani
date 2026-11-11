const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const read = name => fs.readFileSync(path.join(root,name),'utf8');
const index = read('index.html');
const main = read('assets/kapani-main-classic.js');
const sql = read('supabase/030_scooter_review_and_advertiser_salary.sql');
const installer = read('INSTALL.sql');
const worker = read('firebase-messaging-sw.js');

const scooter = index.match(/window\.kapaniReviewScooter=async function\(nick,approve\)\{[\s\S]*?finally\{ delete _scooterReviewBusy\[nick\]; \}/);
assert.ok(scooter, 'scooter review handler must exist');
assert.doesNotMatch(scooter[0],/runTransaction\(/, 'mayor must not overwrite entire user records');
assert.match(scooter[0],/kp_civic_v8/,'modern applications use protected civic RPC');
assert.match(scooter[0],/kp_mayor_review_scooter_legacy/,'legacy exam applications use guarded RPC');
assert.match(sql,/actor is distinct from 'Кайон'/,'only mayor may approve legacy scooter applications');
assert.match(sql,/Scooter exam has not been passed/,'legacy exam result must be checked');
assert.match(sql,/perform public\.kp_v8_put\('licenses'/,'license branch remains canonical');

assert.match(main,/supabase\.rpc\('kp_advertiser_weekly_salary_v30'\)/);
assert.doesNotMatch(main,/Начисление пока не подключено к защищённому серверу/);
assert.doesNotMatch(main,/runTransaction\(userRef\(nick\), current =>/);
assert.match(sql,/referrals>=4 then 3900\+\(referrals-4\)\*500/);
assert.match(sql,/public\.kp_v8_money\(actor,salary,operation,'advertiser_weekly_salary'/);
assert.match(sql,/operation_id=operation/,'financial credits must be idempotent');
assert.match(sql,/exists\(select 1 from public\.kp_profiles/,'only actual registered users count');
assert.match(sql,/next_week<current_week/,'current week is not paid prematurely');
assert.match(sql,/revoke all on function public\.kp_advertiser_weekly_salary_v30\(\)/);
assert.ok(installer.includes(sql.trim()),'full installer contains the exact new migration');
assert.match(index,/kapani-main-classic\.js\?v=36/);
assert.match(worker,/kapani-static-v36/);

console.log('OK: guarded scooter approval and weekly advertiser salary contracts.');
