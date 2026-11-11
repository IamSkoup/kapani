// Test the failure mode that the isolated tour mock missed, and ensure that
// delivery never expands a thousand marketplace listings above the order form.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const root=path.resolve(__dirname,'..');
const read=name=>fs.readFileSync(path.join(root,name),'utf8');
const main=read('assets/kapani-main-classic.js');
const tour=read('assets/kapani-onboarding.js');
const css=read('assets/kapani-onboarding.css');
const html=read('index.html');
const fixture=read('tests/onboarding-real-app.html');
const deliveryFixture=read('tests/delivery-real-app.html');

assert.match(tour,/document\.createElement\('dialog'\)/);
assert.match(tour,/root\.showModal\(\)/);
assert.match(css,/\.kp-tour-overlay::backdrop\s*\{\s*background:\s*transparent/);
assert.match(css,/max-width: none !important/);
assert.match(tour,/root\.addEventListener\('cancel'/);
assert.match(main,/localStorage\.getItem\(pendingKey\) === '1'\) return true/);
assert.match(fixture,/src="\.\.\/index\.html"/);
assert.match(deliveryFixture,/length:1000/);
assert.match(deliveryFixture,/script\.slice\(start,end\)/);
assert.match(deliveryFixture,/await actions\.render\(\)/);
assert.match(html,/kapani-onboarding\.js\?v=38/);

const start=main.indexOf('const deliveryCatalogView=');
const end=main.indexOf('window.renderDeliveryOrderOptions=renderDeliveryOrderOptions=',start);
assert.ok(start>0&&end>start,'paginated catalogue is present');
const entries=Array.from({length:1000},(_,i)=>({id:`id-${i}`,title:`Товар ${i}`,seller:'Продавец',price:150+i,status:'active'}));
const nodes={v8DeliveryCatalogItems:{innerHTML:''},v8DeliveryCatalogPages:{innerHTML:''}};
const ctx={window:{},qs:id=>nodes[id],deliveryMarketplaceOptions:()=>entries,html:v=>String(v),jsEsc:v=>v,money:v=>`${v} ₽`,button:(label)=>`<button>${label}</button>`,Math,String};
vm.runInNewContext(main.slice(start,end)+'this.paintDirectory=paintDeliveryMarketplaceDirectory;',ctx);
ctx.paintDirectory();
assert.equal((nodes.v8DeliveryCatalogItems.innerHTML.match(/class="v8-listing-delivery"/g)||[]).length,8,'only eight cards rendered');
assert.match(nodes.v8DeliveryCatalogPages.innerHTML,/1 из 125/);
ctx.window.kpDeliveryCatalogPage(1);
assert.match(nodes.v8DeliveryCatalogPages.innerHTML,/2 из 125/);
ctx.window.kpDeliveryCatalogFilter('Товар 999');
assert.equal((nodes.v8DeliveryCatalogItems.innerHTML.match(/class="v8-listing-delivery"/g)||[]).length,1,'search narrows to one');
assert.match(main.slice(end,end+1000),/orderForm\.after\(host\)/,'directory is after form');
assert.match(main.slice(end,end+2000),/<details class="v8-delivery-directory"/,'directory is collapsed by default');
console.log('OK: native tour in top layer, real-page test harness, and paginated delivery catalogue');
