import { createClient } from 'npm:@supabase/supabase-js@2.49.8';
import webpush from 'npm:web-push@3.6.7';
const cors = {'access-control-allow-origin':'*','access-control-allow-methods':'GET,POST,OPTIONS','access-control-allow-headers':'authorization,apikey,content-type,x-client-info'};
const json = (body:unknown,status=200) => new Response(JSON.stringify(body),{status,headers:{...cors,'content-type':'application/json'}});
const base=Deno.env.get('SUPABASE_URL')||'', key=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')||'';
const pub=Deno.env.get('VAPID_PUBLIC_KEY')||'',priv=Deno.env.get('VAPID_PRIVATE_KEY')||'',subject=Deno.env.get('VAPID_SUBJECT')||'';
const configured=!!(pub&&priv&&/^mailto:[^@\s]+@[^@\s]+$/.test(subject));
const admin=createClient(base,key,{auth:{persistSession:false}});
if(configured) webpush.setVapidDetails(subject,pub,priv);
const nick=(x:unknown)=>String(x||'').trim().slice(0,120);
const endpointAllowed=(x:string)=>{try{const h=new URL(x);return h.protocol==='https:'&&/^(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|.*\.push\.apple\.com|.*\.notify\.windows\.com)$/i.test(h.hostname);}catch{return false;}};
async function caller(req:Request){const token=/^Bearer (.+)$/i.exec(req.headers.get('authorization')||'')?.[1];if(!token)return null;const {data,error}=await admin.auth.getUser(token);if(error||!data.user)return null;const {data:p}=await admin.from('kp_profiles').select('nickname').eq('user_id',data.user.id).maybeSingle();return p?.nickname?{id:data.user.id,nick:p.nickname}:null;}
async function targetId(name:string){const {data}=await admin.from('kp_profiles').select('user_id').eq('nickname',name).maybeSingle();return data?.user_id||null;}
async function register(req:Request,b:Record<string,unknown>){
 const n=nick(b.nick),password=String(b.password||'');
 if(n.length<3||n.length>30||!/^[\p{L}\p{N}_ -]+$/u.test(n))return json({error:'Ник должен содержать 3–30 букв или цифр'},400);
 if(password.length<8||password.length>128)return json({error:'Пароль от 8 до 128 символов'},400);
 const ip=req.headers.get('cf-connecting-ip')||req.headers.get('x-forwarded-for')?.split(',')[0]||'unknown';
 const hashed=new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(ip)));
 const ipHash=[...hashed].map(i=>i.toString(16).padStart(2,'0')).join('');
 const {count,error:limitError}=await admin.from('kp_signup_attempts').select('id',{head:true,count:'exact'}).eq('ip_hash',ipHash).gte('attempted_at',new Date(Date.now()-3600000).toISOString());
 if(limitError)throw limitError;
 if((count||0)>=5)return json({error:'Не больше пяти регистраций в час'},429);
 await admin.from('kp_signup_attempts').insert({ip_hash:ipHash});
 if(await targetId(n))return json({error:'Ник занят'},409);
 const digest=[...new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(n.normalize('NFC'))))].map(i=>i.toString(16).padStart(2,'0')).join('');
 const email='u'+digest.slice(0,48)+'@users.kapani.invalid';
 const created=await admin.auth.admin.createUser({email,password,email_confirm:true,user_metadata:{nick:n}});
 if(created.error||!created.data.user)return json({error:created.error?.message||'Ошибка регистрации'},400);
 const id=created.data.user.id;
 try{
   const profile=await admin.from('kp_profiles').insert({user_id:id,nickname:n});if(profile.error)throw profile.error;
   const wallet=await admin.from('kp_wallets').insert({user_id:id});if(wallet.error)throw wallet.error;
   const boot=await admin.rpc('kp_tree_bootstrap_user',{p_nick:n,p_profile:{displayName:String((b.profile as Record<string,unknown>)?.displayName||n)}});if(boot.error||!boot.data)throw boot.error||new Error('Bootstrap failed');
   return json({ok:true,created:true,nick:n});
 }catch(e){await admin.auth.admin.deleteUser(id);return json({error:String((e as Error).message||e).slice(0,200)},500);}
}
async function pushTo(n:string,data:Record<string,unknown>){
 const id=await targetId(n);if(!id)return{sent:0,devices:0,reason:'Recipient missing'};
 const {data:devices,error}=await admin.from('kp_push_devices').select('subscription_id,subscription,prefs').eq('user_id',id);
 if(error)throw error;if(!configured)return{sent:0,devices:devices?.length||0,reason:'VAPID not configured'};
 let sent=0,skipped=0;const statuses:unknown[]=[];
 for(const d of (devices||[]).slice(0,5)){
  const prefs=d.prefs||{};if(prefs.enabled===false||prefs[String(data.category||'system')]===false){skipped++;continue;}
  try{await webpush.sendNotification(d.subscription,JSON.stringify(data),{TTL:86400});sent++;statuses.push({id:d.subscription_id,status:201});}
  catch(e){const code=Number((e as {statusCode?:number}).statusCode||0);if(code===404||code===410)await admin.from('kp_push_devices').delete().eq('subscription_id',d.subscription_id);statuses.push({id:d.subscription_id,status:code});}
 }
 return{sent,skipped,devices:devices?.length||0,statuses};
}

async function notify(from:{id:string,nick:string},b:Record<string,unknown>){
 const to=nick(b.targetNick||b.to),message=String(b.text||b.body||'').trim().slice(0,500);
 if(!to||!message)return json({error:'Recipient and text required'},400);
 if(!await targetId(to))return json({error:'Recipient missing'},404);
 const {data:quota,error:quotaError}=await admin.rpc('kp_consume_notify_quota',{p_sender:from.id});
 if(quotaError)throw quotaError;if(!quota)return json({error:'Превышен суточный лимит уведомлений'},429);
 const createdAt=Date.now(),notificationId=crypto.randomUUID();
 const url=String(b.url||'/kapani/');const safe=/^\/kapani\/(?:\?[^#]*)?(?:#.*)?$/.test(url)?url:'/kapani/';
 const record={text:message,title:'От '+from.nick,category:'social',cat:'social',source:'user_notification',from:from.nick,sourceMessageId:String(b.sourceMessageId||'').slice(0,120),url:safe,createdAt,time:new Intl.DateTimeFormat('ru-RU',{timeZone:'Europe/Moscow',hour:'2-digit',minute:'2-digit'}).format(createdAt)};
 const {data:ok,error}=await admin.rpc('kp_tree_push_notification',{p_nick:to,p_id:notificationId,p_record:record});
 if(error||!ok)throw error||new Error('Notification storage failed');
 const sent=await pushTo(to,{title:record.title,body:message,category:'social',notificationId,url:safe,createdAt});
 return json({ok:true,notificationId,...sent});
}
async function event(from:{id:string,nick:string},b:Record<string,unknown>){
 const job=(b.job||{}) as Record<string,unknown>;
 if(job.type!=='chat')return json({ok:true,sent:0,reason:'Unsupported event'});
 const id=String(job.id||'');if(!id)return json({error:'Missing message ID'},400);
 const {data:root}=await admin.from('kp_tree_roots').select('document').eq('branch','chat').maybeSingle();
 const message=root?.document?.[id];if(!message||message.nick!==from.nick)return json({error:'Chat author mismatch'},403);
 const {error:duplicate}=await admin.from('kp_push_events').insert({event_id:'chat:'+id,sender:from.id});
 if(duplicate){if(duplicate.code==='23505')return json({ok:true,sent:0,reason:'Already notified'});throw duplicate;}
 const preview=String(message.text||'').slice(0,100)||({video:'Видео',image:'Фото',voice:'Голосовое',video_circle:'Видеосообщение'}[message.msgType as 'video'|'image'|'voice'|'video_circle']||'Новое сообщение');
 const {data:people,error}=await admin.from('kp_profiles').select('nickname').neq('user_id',from.id).limit(200);
 if(error)throw error;
 let sent=0;
 for(const recipient of people||[]){
   const nid=crypto.randomUUID(),createdAt=Date.now(),body=from.nick+': '+preview;
   const record={text:body,title:'Общий чат',cat:'messages',category:'messages',source:'general_chat',from:from.nick,createdAt,url:'/kapani/?kpSection=messages'};
   await admin.rpc('kp_tree_push_notification',{p_nick:recipient.nickname,p_id:nid,p_record:record});
   const result=await pushTo(recipient.nickname,{title:record.title,body,category:'messages',notificationId:nid,url:record.url,createdAt});sent+=result.sent;
 }
 return json({ok:true,sent});
}
async function bankTransferPush(from:{id:string,nick:string},body:Record<string,unknown>){
 const id=String(body.transferId||'');
 if(!/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(id))return json({error:'Invalid transfer'},400);
 const {data:debit,error}=await admin.from('kp_ledger').select('details')
   .eq('operation_id',id).eq('user_id',from.id).eq('kind','bank_transfer').lt('amount',0).maybeSingle();
 if(error)throw error;
 const to=nick(debit?.details?.to);
 if(!to)return json({error:'Transfer missing'},404);
 const userId=await targetId(to);
 if(!userId)return json({error:'Transfer missing'},404);
 const credit=await admin.from('kp_ledger').select('amount')
   .eq('user_id',userId).eq('kind','bank_transfer').eq('details->>transferId',id).gt('amount',0).maybeSingle();
 if(credit.error)throw credit.error;
 if(!credit.data)return json({error:'Transfer missing'},404);
 const {error:dedupe}=await admin.from('kp_push_events').insert({event_id:'transfer:'+id,sender:from.id});
 if(dedupe?.code==='23505')return json({ok:true,sent:0});
 if(dedupe)throw dedupe;
 const data={title:'Капани Банк',body:'Перевод от '+from.nick+': +'+Number(credit.data.amount).toLocaleString('ru-RU')+' ₽',
   category:'money',notificationId:'transfer_'+id,url:'/kapani/?kpSection=bank',createdAt:Date.now()};
 return json({ok:true,...await pushTo(to,data)});
}

Deno.serve(async(req:Request)=>{
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers:cors});
 const action=new URL(req.url).pathname.split('/').filter(Boolean).at(-1)||'';
 if(action==='health')return json({ok:true,backend:'supabase',vapid:configured});
 if(action==='register'){
  if(req.method!=='POST')return json({error:'Use POST'},405);
  const body=await req.json().catch(()=>null);
  if(!body||typeof body!=='object'||Array.isArray(body))return json({error:'Invalid JSON'},400);
  try{return await register(req,body);}catch(e){return json({error:String((e as Error).message||e).slice(0,250)},500);}
 }
 const from=await caller(req);if(!from)return json({error:'Unauthorized Supabase session'},401);
 if(req.method!=='POST')return json({error:'Use POST'},405);
 const b=await req.json().catch(()=>null);if(!b||typeof b!=='object'||Array.isArray(b))return json({error:'Bad JSON'},400);
 try{
  if(action==='subscribe'){
   const s=b.subscription;if(!s?.endpoint||!s?.keys?.p256dh||!s?.keys?.auth||!endpointAllowed(s.endpoint))return json({error:'Invalid push subscription'},400);
   const digest=new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(s.endpoint)));
   const id=[...digest].map(x=>x.toString(16).padStart(2,'0')).join('').slice(0,32);
   const {error}=await admin.from('kp_push_devices').upsert({subscription_id:id,user_id:from.id,endpoint:s.endpoint,subscription:s,prefs:b.prefs||{},user_agent:String(b.userAgent||'').slice(0,250),updated_at:new Date().toISOString()});if(error)throw error;
   return json({ok:true,success:true,subscriptionId:id});
  }
  if(action==='unsubscribe'){
   const {error}=await admin.from('kp_push_devices').delete().eq('subscription_id',String(b.subscriptionId||'')).eq('user_id',from.id);if(error)throw error;return json({ok:true,success:true});
  }
  if(action==='prefs'){
   const {error}=await admin.from('kp_push_devices').update({prefs:b.prefs||{}}).eq('subscription_id',String(b.subscriptionId||'')).eq('user_id',from.id);if(error)throw error;return json({ok:true,success:true});
  }
  if(action==='notify')return await notify(from,b);
  if(action==='bank-transfer')return await bankTransferPush(from,b);
  if(action==='event')return await event(from,b);
  if(action==='test'){const delivery=await pushTo(from.nick,{title:'Капани — проверка Push',body:'Тестовое уведомление доставлено',category:'system',notificationId:crypto.randomUUID(),url:'/kapani/',createdAt:Date.now()});return json({ok:true,...delivery});}
  if(action==='debug'){const {count}=await admin.from('kp_push_devices').select('subscription_id',{head:true,count:'exact'}).eq('user_id',from.id);return json({ok:true,yourDevices:count||0,diagnosis:{hint:configured?'VAPID configured':'Configure VAPID secrets'}});}
  return json({error:'Unknown action'},404);
 }catch(e){console.error('[kapani-push]',e);return json({error:String((e as Error).message||e).slice(0,280)},500);}
});
