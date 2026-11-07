// Casino performance and retry semantics: no real wagers or account mutations.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const read=p=>fs.readFileSync(path.resolve(__dirname,'..',p),'utf8');
const main=read('assets/kapani-main-classic.js');
const html=read('index.html');
const css=read('assets/kapani-casino-performance.css');
const sw=read('firebase-messaging-sw.js');

assert.match(html,/kapani-casino-performance\.css\?v=30/);
assert.match(html,/kapani-main-classic\.js\?v=30/);
assert.match(sw,/kapani-static-v30/);
assert.match(sw,/kapani-casino-performance\.css\?v=30/);
assert.match(main,/if\(host\.dataset\.kpCasinoBuilt!=='1'\|\|!host\.querySelector\('#v8CasinoBalance'\)\)/);
assert.match(main,/host\.dataset\.kpCasinoBuilt='1'/);
assert.match(main,/if\(casinoViewRequest\)return casinoViewRequest/);
assert.match(main,/casinoStateRevision!==revisionAtStart/);
assert.match(main,/casinoLastViewAt<3000/);
assert.match(main,/window\.kpCasinoMove=kind=>action\('casino-op'/);
assert.match(main,/window\.kpPlayGame=\(\)=>action\('casino-op'/);
assert.match(main,/p_id:requestID\(key\)/);
assert.match(main,/v8\.requests\.delete\(key\)/);
assert.match(main,/let casinoAudio=null/);
assert.match(main,/function stopCasinoAudio\(\)/);
assert.match(main,/casinoAudio=new Audio\(\)/);
assert.match(css,/#kpV8Sheet \.v8-game-stage\.playing > img/);
assert.match(css,/animation: none !important/);
assert.match(css,/#v8CasinoPlay\[disabled\]/);

// Run the actual RPC timeout helper in isolation to verify its happy path,
// confirmed failure and AbortController cancellation behavior.
const from=main.indexOf('const CASINO_REQUEST_TIMEOUT_MS=');
const to=main.indexOf('window.kapaniRenderCasino=',from);
assert.ok(from>0&&to>from,'casino RPC helper boundaries');
const factory=new Function('supabase','setTimeout','clearTimeout',main.slice(from,to)+'\nreturn casinoRpc;');
const normalRpc=factory({rpc:(name,args)=>({abortSignal:async signal=>{
  assert.equal(name,'kp_casino_v8');
  assert.equal(args.p_action,'play');
  assert.equal(args.p_id,'stable-id');
  assert.equal(signal.aborted,false);
  return {data:{balance:120,payout:20},error:null};
}})},setTimeout,clearTimeout);

(async()=>{
  assert.deepEqual(await normalRpc('play',{p_id:'stable-id'}),{balance:120,payout:20});
  const slowRpc=factory({rpc:()=>({abortSignal:signal=>new Promise(resolve=>{
    signal.addEventListener('abort',()=>resolve({data:null,error:{message:'cancelled'}}),{once:true});
  })})},fn=>{queueMicrotask(fn);return 1;},()=>{});
  await assert.rejects(slowRpc('play',{p_id:'stable-id'}),/Повторите действие с той же суммой/);
  const emptyRpc=factory({rpc:()=>({abortSignal:async()=>({data:null,error:null})})},setTimeout,clearTimeout);
  await assert.rejects(emptyRpc('view'),/Нет подтверждения сервера/);
  console.log('OK: revision 30 casino request timeout, stable retry IDs, lazy audio, single DOM build, lightweight game sheets.');
})().catch(error=>{console.error(error);process.exitCode=1;});
