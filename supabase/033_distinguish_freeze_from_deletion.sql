begin;

create or replace function public.kp_mayor_review_delete_request(p_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  actor text;
  requests jsonb;
  request_doc jsonb;
  result jsonb;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select nickname into actor from public.kp_profiles where user_id=auth.uid();
  if actor is distinct from 'Кайон' then raise exception 'Mayor access required'; end if;
  if length(coalesce(p_id,'')) not between 8 and 100 then raise exception 'Invalid request ID'; end if;
  select document into requests from public.kp_tree_roots
    where branch='policeRequests' for update;
  request_doc:=requests->p_id;
  if request_doc is null or request_doc->>'status'<>'pending'
     or request_doc->>'type' is distinct from 'delete' then
    raise exception 'Pending deletion request not found';
  end if;
  result:=public.kp_mayor_delete_account(request_doc->>'target');
  request_doc:=request_doc||jsonb_build_object('status','approved',
    'reviewedAt',(extract(epoch from clock_timestamp())*1000)::bigint);
  perform public.kp_v8_put('policeRequests',jsonb_set(requests,array[p_id],request_doc,true));
  return result||jsonb_build_object('request',p_id);
end;
$$;
revoke all on function public.kp_mayor_review_delete_request(text) from public,anon;
grant execute on function public.kp_mayor_review_delete_request(text) to authenticated;

commit;
