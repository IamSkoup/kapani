// Static regression checks for business and delivery fixes. PostgreSQL execution
// and cross-device Web Push must still be tested against the owner's project.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const base=path.resolve(__dirname,'..');
const read=p=>fs.readFileSync(path.join(base,p),'utf8');
const main=read('assets/kapani-main-classic.js');
const finishes=read('assets/kapani-finishes.js');
const css=read('assets/kapani-v18-business.css');
const html=read('index.html');
const migration=read('supabase/022_business_inbox_and_delivery_cart.sql');

const check=(label,condition)=>assert.ok(condition,label);
check('new styles loaded after legacy styles',html.includes('assets/kapani-v18-business.css?v=18') &&
  html.indexOf('assets/kapani-v18-business.css')>html.indexOf('assets/kapani-v14-fixes.css'));
check('new JS is cache-busted',html.includes('kapani-main-classic.js?v=18') && html.includes('kapani-finishes.js?v=18'));

check('user can remove a final item from business basket',main.includes('if(nextQty <= 0) delete cart[prodId]'));
check('zero quantity does not clamp to one',main.includes('Math.max(0, Math.min(100, parseInt(value,10)||0))'));
check('business inbox SQL owner guard',migration.includes("business_doc->>'owner' is distinct from actor"));
check('complaints clear is scoped to target business',migration.includes("branch_name:='bizComplaints'") && migration.includes('inbox_root-p_biz'));
check('job requests clear has dedicated server branch',migration.includes("branch_name:='bizJobApps'") && main.includes("p_kind:'applications'"));
check('business inbox actions use protected RPC',main.includes("supabase.rpc('kp_business_inbox_clear_v22'"));
check('effects handled by safe server finance',finishes.includes("businessFinance('effect',effect,price)"));
check('already selected effect is not repurchased',finishes.includes('current.bgEffect === effect'));
check('effect visuals confined to banner',css.includes('#bizDetailBgWrap') && css.includes('contain:paint'));
check('mobile employee names do not break per character',css.includes('.biz-employee-nick') && css.includes('word-break:normal !important'));
check('mobile bell shown',css.includes('#gHeader .h-notify {display:flex !important'));
check('notification badge in header',html.includes('id="notifyBadge"'));

check('multi-item delivery editor available',html.includes('kpOpenDeliveryCartCatalog()') && html.includes('deliveryCartSummary'));
check('delivery quantity can reach zero',main.includes('if(next)basket[pid]=next;else delete basket[pid]'));
check('multi-item cart submitted to SQL',main.includes("rpc('kp_delivery_cart_v22'"));
check('server authenticates cart actor',migration.includes('actor text:=public.kp_v8_actor()'));
check('server validates each product against live catalogue',migration.includes('item:=products->entry.key'));
check('server controls prices',migration.includes("item_price:=(item->>'price')::bigint"));
check('server charges wallet once',migration.includes("perform public.kp_v8_money(actor,-total,(md5('delivery'||p_id||':reserve'))::uuid"));
check('server persists escrow',migration.includes("'escrowAmount',total"));
check('basket includes item details',migration.includes("'cartItems',cart_items"));
check('delivery note is stored',migration.includes("'notes',coalesce(p_notes,'')"));
check('driver sees comment',main.includes('Комментарий клиента — ${escHtml(o.notes)}'));
check('driver queue is deduplicated',main.includes('new Map([...waiting,...proposed,...myActive]'));
check('driver queue is replaced, not appended',main.includes('host.innerHTML=html;'));
check('driver queue take uses protected server action',main.includes("service('delivery','take',id)"));
check('delivery server-side role check already exists',read('supabase/009_services.sql').includes("public.kp_v8_role(a,case when p_kind='taxi' then 'Водитель' else 'Доставщик' end)"));
check('business cart creation alerts municipal workers',migration.includes("'delivery_'||p_id||'_new"));
check('marketplace delivery sends one guarded server alert',migration.includes('function public.kp_delivery_alert_v22(p_id text)') && migration.includes("order_doc->>'deliveryStaffNotified'='true'"));
check('marketplace sends server alert after create',main.includes("rpc('kp_delivery_alert_v22',{p_id:order.id})"));
check('browser push remains optional',main.includes("console.warn('[delivery push]',error)"));
check('map reused after changing cart quantities',main.includes('if(deliveryBusinessMapSignature===signature)return;'));

console.log('OK: v18 business, delivery, notification and mobile regression contracts.');
