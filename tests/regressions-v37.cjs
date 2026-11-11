// Marketplace delivery must see active listings; event forms must explain
// invalid inputs locally before any money-reserving RPC is sent.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const root=path.resolve(__dirname,'..');
const main=fs.readFileSync(path.join(root,'assets/kapani-main-classic.js'),'utf8');
const tourCss=fs.readFileSync(path.join(root,'assets/kapani-onboarding.css'),'utf8');

const selectSource=main.match(/deliveryMarketplaceOptions=\(\)=>[^;]+;/)?.[0];
assert.ok(selectSource,'marketplace selector override exists');
const market={
  available:{id:'available',title:'Bike',status:'active',category:'electronics',seller:'seller',sellerLat:52,sellerLng:39,price:3000},
  paid:{id:'paid',title:'Bought',status:'sold',category:'other',seller:'seller',buyer:'buyer'},
  pending:{id:'pending',status:'meeting_requested',category:'other',seller:'seller',buyer:'buyer'},
  service:{id:'service',status:'active',category:'service',seller:'seller'},
  own:{id:'own',status:'active',category:'other',seller:'buyer'},
  hidden:{id:'hidden',status:'active',category:'other',seller:'seller',archived:true},
  someoneElses:{id:'someoneElses',status:'sold',category:'other',seller:'seller',buyer:'someoneElse'}
};
const ctx={lastMarketListings:market,currentNick:'buyer',Object,Number};
vm.runInNewContext('let deliveryMarketplaceOptions;'+selectSource+'this.options=deliveryMarketplaceOptions;',ctx);
const ids=ctx.options().map(x=>x.id);
assert.deepEqual(ids,['available','paid','pending']);
assert.match(main,/if\(listing\.status==='active'\)throw new Error\('Сначала договоритесь с продавцом/);
assert.match(main,/if\(listing\.status!=='sold'\|\|listing\.buyer!==currentNick\)/);

const start=main.indexOf("window.kpCreateEvent=()=>action('event-create'");
const end=main.indexOf('\nwindow.kpSettleEvent=',start);
assert.ok(start>0&&end>start,'event form handler exists');
const fields={v8EventTitle:'Лесной забег',v8EventKind:'sport',v8SideA:'Команда А',v8SideB:'Команда Б',v8OddA:'1.9',v8OddB:'1.9',v8EventClose:new Date(Date.now()+86400000).toISOString().slice(0,16),v8EventBudget:'5000'};
const messages=[],calls=[];
const scope={
  window:{kpCloseSheet(){}},v8:{requests:new Map()},
  qs:id=>({value:fields[id]}),requestID:()=> '00000000-0000-4000-8000-000000000001',
  rpc:async(name,data)=>{calls.push({name,data});return{ok:true};},
  action:async(_,fn)=>{try{return await fn();}catch(e){messages.push(e.message);}},
  toast(){},Number,Date,Object,JSON
};
vm.runInNewContext(main.slice(start,end),scope);
(async()=>{
  for(const [field,value,expected] of [
    ['v8EventTitle','А','название'],
    ['v8SideB','','обеих сторон'],
    ['v8OddA','44','коэффициенты'],
    ['v8EventClose','','время окончания'],
    ['v8EventBudget','42','Резерв выплат']
  ]){
    const original=fields[field];fields[field]=value;
    await scope.window.kpCreateEvent();
    assert.match(messages.pop(),new RegExp(expected,'i'));
    assert.equal(calls.length,0,`${field}: no server call for invalid field`);
    fields[field]=original;
  }
  await scope.window.kpCreateEvent();
  assert.equal(calls.length,1,'valid form reaches the protected event RPC');
  assert.equal(calls[0].data.p_data.kind,'sport');
  assert.match(tourCss,/110vmax rgba\(1, 11, 8, \.85\)/,'spotlight dims entire viewport');
  assert.match(tourCss,/touch-action: pan-y/,'mobile onboarding text can scroll');
  console.log('OK: active marketplace goods, paid-only delivery, explanatory event form errors, fullscreen spotlight.');
})().catch(e=>{console.error(e);process.exitCode=1;});
