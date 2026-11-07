begin;
-- New uploads only. Existing public media requires a separate, audited copy migration.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('kapani-messages','kapani-messages',false,51380224,
 array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm','audio/webm','audio/ogg','audio/mp4','audio/mpeg'])
on conflict(id) do nothing;
create table if not exists public.kp_message_file_access (
 object_path text not null, audience text not null, primary key(object_path,audience)
);
alter table public.kp_message_file_access enable row level security;
revoke all on public.kp_message_file_access from public,anon,authenticated;
grant select on public.kp_message_file_access to authenticated;
drop policy if exists message_file_access_read on public.kp_message_file_access;
create policy message_file_access_read on public.kp_message_file_access for select to authenticated
using (audience=(select auth.uid())::text or audience='general');

-- Path: sender UUID / recipient UUID (or general) / random filename.
drop policy if exists kapani_messages_insert on storage.objects;
create policy kapani_messages_insert on storage.objects for insert to authenticated
with check (bucket_id='kapani-messages'
 and (storage.foldername(name))[1]=(select auth.uid())::text
 and ((storage.foldername(name))[2]='general' or exists(
   select 1 from public.kp_profiles p where p.user_id::text=(storage.foldername(name))[2])));
drop policy if exists kapani_messages_read on storage.objects;
create policy kapani_messages_read on storage.objects for select to authenticated
using (bucket_id='kapani-messages' and (
 (storage.foldername(name))[1]=(select auth.uid())::text or
 (storage.foldername(name))[2]=(select auth.uid())::text or
 (storage.foldername(name))[2]='general' or exists(select 1 from public.kp_message_file_access a where a.object_path=name and (a.audience=(select auth.uid())::text or a.audience='general'))));
drop policy if exists kapani_messages_delete on storage.objects;
create policy kapani_messages_delete on storage.objects for delete to authenticated
using (bucket_id='kapani-messages' and (storage.foldername(name))[1]=(select auth.uid())::text);

CREATE OR REPLACE FUNCTION public.kp_message_v8(p_action text, p_kind text, p_peer text DEFAULT NULL::text, p_id text DEFAULT NULL::text, p_data jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare media_path text; media_parts text[]; viewer text; a text:=public.kp_v8_actor(); b text; conv text; path text[]; root jsonb; msg jsonb; users jsonb; attachment jsonb; reply jsonb; emoji text; target jsonb; idx jsonb; at_ms bigint:=(extract(epoch from now())*1000)::bigint;
begin
 if a is null or p_kind not in ('chat','dm') or coalesce(p_id,'')!~ '^[A-Za-z0-9_-]{8,100}$' then raise exception 'Invalid message request'; end if;
 if p_kind='dm' then
   if p_peer is null or not exists(select 1 from public.kp_profiles where nickname=p_peer) then raise exception 'Recipient missing'; end if;
   conv:=case when a collate "C" < p_peer collate "C" then a||'__dm__'||p_peer else p_peer||'__dm__'||a end;
   b:='dms';path:=array[conv,'messages',p_id];
 else b:='chat';path:=array[p_id];end if;
 select document into users from public.kp_tree_roots where branch='users';
 insert into public.kp_tree_roots(branch) values(b) on conflict do nothing;
 select document into root from public.kp_tree_roots where branch=b for update;
 msg:=root #> path;
 if p_action='send' then
   if msg is not null then
     if msg->>'nick'<>a then raise exception 'Message identifier collision'; end if;
     return msg;
   end if;
   if length(coalesce(p_data->>'text',''))>4000 or jsonb_typeof(coalesce(p_data->'attachments','[]'))<>'array' or jsonb_array_length(coalesce(p_data->'attachments','[]'))>6 then raise exception 'Message limit exceeded'; end if;
   for attachment in select value from jsonb_array_elements(coalesce(p_data->'attachments','[]')) loop
     if attachment->>'type' is null or attachment->>'type' not in ('image','video','voice','video_circle','sticker') or coalesce(attachment->>'url','')!~ '^https://' or length(attachment->>'url')>2000 then raise exception 'Invalid attachment'; end if;
   end loop;
   msg:=jsonb_build_object('nick',a,'avatar',users->a->>'avatar','text',left(coalesce(p_data->>'text',''),4000),'attachments',coalesce(p_data->'attachments','[]'),'createdAt',at_ms,'time',to_char(now() at time zone 'Europe/Moscow','HH24:MI'));
   if p_data ? 'replyId' then
     reply:=root #> (case when p_kind='chat' then array[p_data->>'replyId'] else array[conv,'messages',p_data->>'replyId'] end);
     if reply is not null then msg:=msg||jsonb_build_object('reply',jsonb_build_object('id',p_data->>'replyId','nick',reply->>'nick','text',left(coalesce(reply->>'text','Вложение'),180)));end if;
   end if;
   if p_data ? 'forward' then
     target:=public.kp_tree_access('read',p_data->'forward'->>'path');reply:=target->'value';
     if (p_data->'forward'->>'path') !~ '^(chat/[^/]+|dms/[^/]+/messages/[^/]+)$' or reply is null or reply->>'nick' is null then raise exception 'Forwarded message unavailable'; end if;
     msg:=msg||jsonb_build_object('text',reply->>'text','attachments',coalesce(reply->'attachments',case when reply->>'mediaData' is not null then jsonb_build_array(jsonb_build_object('url',reply->>'mediaData','type',reply->>'msgType')) else '[]'::jsonb end),'forwardedFrom',reply->>'nick');
   end if;
   if coalesce(msg->>'text','')='' and jsonb_array_length(msg->'attachments')=0 then raise exception 'Empty message'; end if;
   -- Forwarding a readable private attachment explicitly grants its new audience.
   -- A guessed file path never grants access. Signed URLs are not stored.
   viewer:=case when p_kind='chat' then 'general' else
     (select user_id::text from public.kp_profiles where nickname=p_peer) end;
   for attachment in select value from jsonb_array_elements(msg->'attachments') loop
     media_path:=substring(attachment->>'url' from '^https://[^/]+/storage/v1/object/authenticated/kapani-messages/(.+)$');
     if media_path is null then continue; end if;
     media_parts:=string_to_array(media_path,'/');
     if not exists(select 1 from storage.objects where bucket_id='kapani-messages' and name=media_path)
       or not (media_parts[1]=auth.uid()::text or media_parts[2]=auth.uid()::text or media_parts[2]='general'
         or exists(select 1 from public.kp_message_file_access x where x.object_path=media_path and x.audience in (auth.uid()::text,'general'))) then
       raise exception 'Private attachment access denied';
     end if;
     insert into public.kp_message_file_access(object_path,audience) values(media_path,viewer) on conflict do nothing;
   end loop;

 elsif p_action='reaction' then
   if msg is null then raise exception 'Message missing'; end if;
   emoji:=p_data->>'emoji';if emoji not in ('👍','❤️','😂','🔥','😮','😢') then raise exception 'Unsupported reaction'; end if;
   target:=coalesce(msg->'reactions','{}');
   if target->>a=emoji then target:=target-a;else target:=jsonb_set(target,array[a],to_jsonb(emoji),true);end if;
   msg:=msg||jsonb_build_object('reactions',target);
 elsif p_action='edit' then
   if msg is null or msg->>'nick'<>a then raise exception 'Only author can edit'; end if;
   if length(trim(coalesce(p_data->>'text',''))) not between 1 and 4000 then raise exception 'Invalid message text';end if;
   msg:=msg||jsonb_build_object('text',trim(p_data->>'text'),'caption',trim(p_data->>'text'),'edited',true);
 elsif p_action='delete' then
   if msg is null then return jsonb_build_object('ok',true);end if;
   if msg->>'nick'<>a then raise exception 'Only author can delete'; end if;
   root:=root #- path;perform public.kp_v8_put(b,root);return jsonb_build_object('ok',true);
 else raise exception 'Unknown message action';end if;
 root:=public.kp_tree_set_deep(root,path,msg);perform public.kp_v8_put(b,root);
 if p_kind='dm' and p_action='send' then
   insert into public.kp_tree_roots(branch) values('dmIndex') on conflict do nothing;
   select document into idx from public.kp_tree_roots where branch='dmIndex' for update;
   target:=jsonb_build_object('lastTs',at_ms,'latest',msg);
   idx:=public.kp_tree_set_deep(idx,array[a,p_peer],target||'{"unread":false}');
   idx:=public.kp_tree_set_deep(idx,array[p_peer,a],target||'{"unread":true}');
   perform public.kp_v8_put('dmIndex',idx);
 end if;
 return msg;
end; $function$
;
commit;
