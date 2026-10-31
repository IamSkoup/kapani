const fs=require('node:fs');
const vm=require('node:vm');
const assert=require('node:assert/strict');
const source=fs.readFileSync('assets/kapani-main-classic.js','utf8');
const start=source.indexOf('async function renderDeliveryCustomOrders(){');
const end=source.indexOf('window.showCustomDeliveryPoint=',start);
assert.ok(start>=0&&end>start);
assert.match(source,/deliveryPage:\{q:\(\)=>\[deliveryCustomOrdersRef\(\)\],render:\(\)=>renderDeliveryCustomOrders\(\)\}/);
const queue={innerHTML:'',querySelectorAll:()=>[]};
const page={appendChild:()=>{}};
const orders={
  order_without_embedded_id:{status:'waiting',source:'business',from:'Кафе',items:'Обед',client:'Клиент',address:'Площадь',deliveryPrice:150},
  active_order:{id:'active_order',status:'client_confirmed',source:'marketplace',from:'Магазин',items:'Книга',client:'Друг',worker:'Курьер',address:'Улица',priceOffer:100,deliveryLat:52.6,deliveryLng:38.4}
};
const ctx={
  currentNick:'Курьер',ADMIN:'Кайон',
  get:async ref=>({exists:()=>true,val:()=>ref==='user'?{job:'Доставщик'}:orders}),
  userRef:()=> 'user',deliveryCustomOrdersRef:()=> 'orders',
  hasMunicipalJob:(u,role)=>u.job===role,
  qs:id=>id==='deliveryList'?page:id==='kapaniCustomDeliveryQueue'?queue:null,
  document:{createElement:()=>({})},
  deliveryDistancePrice:()=>100,
  escHtml:x=>String(x??''),escAttr:x=>String(x??''),jsEsc:x=>String(x??''),
  point:(lat,lng)=>Number.isFinite(Number(lat))&&Number.isFinite(Number(lng))&&lat!=null&&lng!=null
};
(async()=>{
  await vm.runInNewContext(source.slice(start,end)+'renderDeliveryCustomOrders()',ctx);
  assert.match(queue.innerHTML,/data-delivery-order-id="order_without_embedded_id"/);
  assert.match(queue.innerHTML,/Взять заказ/);
  assert.match(queue.innerHTML,/data-delivery-order-id="active_order"/);
  assert.match(queue.innerHTML,/Начать доставку/);
  assert.match(queue.innerHTML,/Показать точку на карте/);
  ctx.get=async ref=>{if(ref==='orders')throw new Error('read failed');return {exists:()=>true,val:()=>({job:'Доставщик'})};};
  ctx.console={warn:()=>{}};
  await vm.runInNewContext(source.slice(start,end)+'renderDeliveryCustomOrders()',ctx);
  assert.match(queue.innerHTML,/Не удалось загрузить заказы/);
  console.log('OK: waiting and assigned deliveries appear in courier queue.');
})().catch(e=>{console.error(e);process.exitCode=1});
