const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {join} = require('node:path');
const vm = require('node:vm');

const main = readFileSync(join(__dirname,'../assets/kapani-main-classic.js'),'utf8');
const start = main.indexOf('function paintEventMarkets(');
const end = main.indexOf('window.kpCreateEventForm=',start);
const event = {
  id:'fixture', status:'open', closes_at:new Date(Date.now()+86_400_000).toISOString(),
  title:'Лесной забег', sides:[{name:'Рухнет <ветка>',odds:20},{name:'Не рухнет',odds:3}]
};
const calls = [];
const host = {innerHTML:'',insertAdjacentHTML(_position,markup){this.innerHTML+=markup;}};
const scope = {
  window:{renderEventsSection(){},kpCloseSheet(){},kpLoadEvents(){}},
  currentNick:'resident', ADMIN:'mayor',eventViews:new Map(),MAX_EVENT_STAKE:2500,
  html:value=>String(value).replaceAll('<','&lt;').replaceAll('>','&gt;'),money:value=>`${value} ₽`,
  qs:id=>id==='v8BetStake'?{value:scope.stake}:null,
  modal:(_title,markup)=>{scope.modal=markup;},toast:message=>calls.push(message),button:label=>label,
  rpc:async(name,args)=>calls.push([name,args]),refreshBalance(){},
  requestID:()=> 'fixture-op',v8:{requests:new Map()},action:(_key,fn)=>fn(), console:{warn(){}}
};
vm.runInNewContext(main.slice(start,end)+'\nthis.render=paintEventMarkets;',scope);
(async()=>{
  const data={events:[event],bets:[{event_id:event.id,status:'pending',stake:200}]};
  scope.eventViews.set(scope.currentNick,{data});
  scope.render(host,data);
  assert.equal((host.innerHTML.match(/disabled>/g)||[]).length,2);
  assert.match(host.innerHTML,/Рухнет &lt;ветка&gt;/);
  assert.match(host.innerHTML,/<b>20<\/b>/);
  assert.doesNotMatch(host.innerHTML,/&lt;b&gt;/);
  scope.window.kpBet(event.id,0);
  assert.match(calls.pop(),/уже поставили/);
  data.bets.length=0;
  scope.window.kpBet(event.id,1);
  assert.match(scope.modal,/max="2500"/);
  scope.stake=2501;
  await assert.rejects(scope.window.kpSubmitBet(event.id,1),/2 500/);
  scope.stake=2500;
  await scope.window.kpSubmitBet(event.id,1);
  assert.equal(calls.find(Array.isArray)[1].p_data.stake,2500);
  console.log('OK: event card, escaped text, one bet per user and visible stake ceiling.');
})().catch(error=>{console.error(error);process.exitCode=1;});
