const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');

const root=path.resolve(__dirname,'..');
const main=fs.readFileSync(path.join(root,'assets/kapani-main-classic.js'),'utf8');
const bridge=fs.readFileSync(path.join(root,'assets/supabase-bridge-classic.js'),'utf8');
const html=fs.readFileSync(path.join(root,'index.html'),'utf8');

function section(start,end){
  const a=main.indexOf(start), b=main.indexOf(end,a);
  assert(a!==-1&&b>a,`missing section ${start}`);
  return main.slice(a,b);
}

const ensureSource=section('async function ensureAuth(){','async function ensureFunctions(){');
function harness(state){
  const counters={session:0,user:0,profile:0};
  const supabase={
    auth:{
      signOut:async()=>{},
      getSession:async()=>{
        counters.session++;
        return {data:{session:state.session?{access_token:'token'}:null},error:state.sessionError||null};
      },
      getUser:async()=>{
        counters.user++;
        if(state.userGate)await state.userGate;
        return {data:{user:state.user||null},error:state.userError||null};
      }
    },
    from:()=>({select:()=>({eq:()=>({maybeSingle:async()=>{
      counters.profile++;
      return {data:{nickname:state.nick},error:state.profileError||null};
    }})})})
  };
  const context=vm.createContext({supabase,console});
  vm.runInContext(`let authInstance=null; let authModule=null; let authInitPromise=null;
    let kapaniVerifiedIdentity=null; ${ensureSource}
    globalThis.ensureAuthTest=ensureAuth;
    globalThis.readVerified=()=>authInstance?.currentUser;
  `,context);
  return {context,counters};
}

(async()=>{
  const state={session:true,user:{id:'owner-uuid',email:'user@example.com'},nick:'Кайон'};
  const {context,counters}=harness(state);
  const first=await context.ensureAuthTest();
  assert.equal(first.currentUser.uid,'Кайон','owner nickname is verified from Supabase profile');
  assert.equal(first.currentUser.id,'owner-uuid');
  assert.equal(counters.profile,1);

  state.userError=new Error('Failed to fetch');
  await assert.rejects(context.ensureAuthTest(),/Failed to fetch/);
  assert.equal(context.readVerified().uid,'Кайон','temporary network errors preserve confirmed identity');
  state.userError=null;

  state.session=false;
  assert.equal((await context.ensureAuthTest()).currentUser,null,'actually missing session logs out in memory');
  assert.equal(counters.user,2,'missing token is never treated as authenticated');

  let resume;
  const pending={session:true,user:{id:'other-id',email:'x@example.com'},nick:'Лёха',userGate:new Promise(resolve=>{resume=resolve;})};
  const concurrent=harness(pending);
  const calls=[concurrent.context.ensureAuthTest(),concurrent.context.ensureAuthTest()];
  resume();
  await Promise.all(calls);
  assert.equal(concurrent.counters.user,1,'concurrent checks share one validation request');

  const bootstrap=section('async function bootstrapKapaniAuthAndApp(){','// ─── SAFER STRING HELPERS');
  const start=section('function startApp() {','function handleKapaniPushDeepLink(');
  assert(!bootstrap.includes('if(!currentNick){'),'startup must check Supabase even without a cached nickname');
  assert(bootstrap.includes('rememberVerifiedKapaniIdentity(auth.currentUser)'));
  assert(!start.includes("JSON.parse(localStorage.getItem('kp_auth')"),'stale local nickname must not overwrite verified identity');
  assert(bootstrap.includes("window.addEventListener('online'"),'offline startup must retry on reconnection');
  assert(bridge.includes("persistSession: true")&&bridge.includes("autoRefreshToken: true"));
  assert(!bridge.includes('controller.abort()'),'browser lock must not abort a queued token refresh');
  assert(html.includes('supabase-bridge-classic.js?v=18')&&html.includes('kapani-main-classic.js?v=22'));
  console.log('OK: Supabase session recovery, profile ownership, single-flight, and cache update.');
})().catch(error=>{console.error(error);process.exitCode=1;});
