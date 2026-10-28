-- Kapani 022. Apply after migration 020 (021 for the self-resignation fix).
-- Does not delete existing orders, balances, employees or conversations.
begin;

create or replace function public.kp_business_inbox_clear_v22(p_biz text,p_kind text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor text:=public.kp_v8_actor(); branch_name text; business_doc jsonb;
 inbox_root jsonb; deleted_count integer;
begin
 if actor is null then raise exception 'Authentication required'; end if;
 if coalesce(length(p_biz),0) not between 1 and 100 then raise exception 'Invalid business'; end if;
 if p_kind='complaints' then branch_name:='bizComplaints';
 elsif p_kind='applications' then branch_name:='bizJobApps';
 else raise exception 'Unsupported inbox'; end if;
 select document->p_biz into business_doc from public.kp_tree_roots where branch='businesses';
 if business_doc is null or business_doc->>'owner' is distinct from actor then
   raise exception 'Business owner required';
 end if;
 select document into inbox_root from public.kp_tree_roots where branch=branch_name for update;
 inbox_root:=coalesce(inbox_root,'{}'::jsonb);
 select count(*) into deleted_count from jsonb_object_keys(coalesce(inbox_root->p_biz,'{}'::jsonb));
 if deleted_count>0 then
   perform public.kp_v8_put(branch_name,inbox_root-p_biz);
 end if;
 return jsonb_build_object('ok',true,'deleted',deleted_count);
end; $$;
revoke all on function public.kp_business_inbox_clear_v22(text,text) from public,anon;
grant execute on function public.kp_business_inbox_clear_v22(text,text) to authenticated;

-- Multi-item delivery uses the same escrow, assignment, cancellation and
-- settlement state machine as kp_service_v8. It only creates the order;
-- take/start/finish/confirm/cancel still use the existing service RPC.
create or replace function public.kp_delivery_cart_v22(
 p_id text,p_biz text,p_cart jsonb,p_dest_lat numeric,p_dest_lng numeric,
 p_address text default '',p_notes text default '',p_contact text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 actor text:=public.kp_v8_actor();
 users_doc jsonb; profile jsonb; orders jsonb; existing jsonb;
 business_doc jsonb; item jsonb; products jsonb; entry record;
 cart_items jsonb:='[]'::jsonb; summary_items text:='';
 line_count integer; quantity integer; item_price bigint;
 goods_total bigint:=0; distance numeric; delivery_price bigint; total bigint;
 item_count integer:=0; at_ms bigint:=(extract(epoch from now())*1000)::bigint;
 order_doc jsonb; resident record;
begin
 if actor is null then raise exception 'Authentication required'; end if;
 if p_id is null or length(p_id) not between 8 and 100 then raise exception 'Invalid delivery request'; end if;
 if coalesce(length(p_biz),0) not between 1 and 100 then raise exception 'Select a business'; end if;
 if not public.kp_v8_point(p_dest_lat::text,p_dest_lng::text) then raise exception 'Select destination on map'; end if;
 if jsonb_typeof(p_cart) is distinct from 'object' then raise exception 'Select products for delivery'; end if;
 select count(*) into line_count from jsonb_object_keys(p_cart);
 if line_count not between 1 and 20 then raise exception 'Choose 1 to 20 different products'; end if;
 if length(coalesce(p_address,''))>200 or length(coalesce(p_notes,''))>1000
   or length(coalesce(p_contact,''))>100 then raise exception 'Delivery details too long'; end if;

 select document into users_doc from public.kp_tree_roots where branch='users' for update;
 profile:=users_doc->actor;
 if profile is null or profile->>'accountVerified' is distinct from 'true'
   or coalesce(profile->>'accountFrozen','false')='true' then
   raise exception 'Verified active account required';
 end if;
 select document into orders from public.kp_tree_roots where branch='deliveryCustomOrders' for update;
 orders:=coalesce(orders,'{}'::jsonb);
 existing:=orders->p_id;
 if existing is not null then
   if existing->>'client' is distinct from actor then raise exception 'Order belongs to another user'; end if;
   return existing;
 end if;

 select document->p_biz into business_doc from public.kp_tree_roots where branch='businesses';
 if business_doc is null or business_doc->>'status'<>'active'
   or business_doc->>'delivery' is distinct from 'true'
   or business_doc->>'owner'=actor
   or not public.kp_v8_point(business_doc->>'lat',business_doc->>'lng') then
   raise exception 'Business unavailable for delivery';
 end if;
 products:=coalesce(business_doc->'products','{}'::jsonb);
 for entry in select key,value from jsonb_each(p_cart) loop
   if entry.value is null or jsonb_typeof(entry.value)<>'number'
     or entry.value::text !~ '^[0-9]{1,2}$' then raise exception 'Invalid product quantity'; end if;
   quantity:=entry.value::text::integer;
   if quantity not between 1 and 20 then raise exception 'Choose 1 to 20 units per product'; end if;
   item:=products->entry.key;
   if item is null or item->>'available'='false' then raise exception 'Product is no longer available'; end if;
   if coalesce(item->>'price','') !~ '^[0-9]{1,8}$' then raise exception 'Invalid product price'; end if;
   item_price:=(item->>'price')::bigint;
   if item_price not between 1 and 100000 then raise exception 'Invalid product price'; end if;
   goods_total:=goods_total+item_price*quantity;
   if goods_total>1000000 then raise exception 'Cart total exceeds 1 000 000'; end if;
   item_count:=item_count+quantity;
   cart_items:=cart_items||jsonb_build_array(jsonb_build_object(
     'id',entry.key,'name',left(coalesce(item->>'name','Товар'),120),
     'price',item_price,'qty',quantity));
   summary_items:=summary_items||case when summary_items='' then '' else ', ' end||
     left(coalesce(item->>'name','Товар'),120)||' × '||quantity;
 end loop;
 distance:=public.kp_v8_distance((business_doc->>'lat')::numeric,
   (business_doc->>'lng')::numeric,p_dest_lat,p_dest_lng);
 if distance<=0 or distance>100 then raise exception 'Route must be between 0 and 100 km'; end if;
 delivery_price:=greatest(1,round(distance*200)::bigint);
 total:=goods_total+delivery_price;

 order_doc:=jsonb_build_object(
   'id',p_id,'source','business','sourceLabel','Бизнес','client',actor,
   'bizId',p_biz,'supplier',business_doc->>'owner','from',business_doc->>'name',
   'items',summary_items,'productName',summary_items,'cartItems',cart_items,
   'itemCount',item_count,'productPrice',goods_total,
   'pickupLat',business_doc->'lat','pickupLng',business_doc->'lng',
   'deliveryLat',p_dest_lat,'deliveryLng',p_dest_lng,
   'destLat',p_dest_lat,'destLng',p_dest_lng,
   'deliveryPrice',delivery_price,'priceOffer',delivery_price,'price',delivery_price,
   'distanceKm',distance,'address',coalesce(nullif(trim(p_address),''),'Точка на карте'),
   'notes',coalesce(p_notes,''),'contact',coalesce(p_contact,''),
   'status','waiting','escrowAmount',total,
   'deliveryStaffNotified',true,
   'clientConfirmed',false,'workerConfirmed',false,
   'createdAt',at_ms,'updatedAt',at_ms);
 perform public.kp_v8_money(actor,-total,(md5('delivery'||p_id||':reserve'))::uuid,
   'service_reserve',jsonb_build_object('service','delivery','order',p_id,'products',item_count));
 perform public.kp_v8_put('deliveryCustomOrders',jsonb_set(orders,array[p_id],order_doc,true));
 perform public.kp_v8_notify(actor,'Доставка: заказ создан, оплата зарезервирована',
   'system','delivery_'||p_id||'_create');
 -- Deliver an in-app notification even when the buyer closes the browser
 -- before the best-effort Web Push dispatch finishes.
 for resident in select key,value from jsonb_each(users_doc) loop
   if resident.key<>actor and (
      resident.value->>'job'='Доставщик'
      or exists (select 1 from jsonb_array_elements(
         case when jsonb_typeof(resident.value->'employments')='array'
           then resident.value->'employments' else '[]'::jsonb end) as employment(job)
         where job->>'type'='municipal' and job->>'role'='Доставщик')
   ) then
     perform public.kp_v8_notify(resident.key,
       'Новая доставка из «'||coalesce(business_doc->>'name','бизнеса')||'»: '||summary_items,
       'delivery_orders','delivery_'||p_id||'_new');
   end if;
 end loop;
 return order_doc;
end; $$;
revoke all on function public.kp_delivery_cart_v22(text,text,jsonb,numeric,numeric,text,text,text)
 from public,anon;
grant execute on function public.kp_delivery_cart_v22(text,text,jsonb,numeric,numeric,text,text,text)
 to authenticated;

-- Marketplace deliveries go through the older kp_service_v8 creator, which
-- only notifies the customer. This authenticated, idempotent follow-up also
-- notifies delivery workers, without letting a stranger send fake alerts.
create or replace function public.kp_delivery_alert_v22(p_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor text:=public.kp_v8_actor(); users_doc jsonb; root_doc jsonb;
 order_doc jsonb; resident record; notified integer:=0;
begin
 if actor is null or length(coalesce(p_id,'')) not between 8 and 100 then
   raise exception 'Invalid delivery request';
 end if;
 select document into users_doc from public.kp_tree_roots where branch='users' for update;
 select document into root_doc from public.kp_tree_roots where branch='deliveryCustomOrders' for update;
 order_doc:=root_doc->p_id;
 if order_doc is null or order_doc->>'client' is distinct from actor then
   raise exception 'Delivery owner required';
 end if;
 if order_doc->>'deliveryStaffNotified'='true' or order_doc->>'status'<>'waiting' then
   return jsonb_build_object('ok',true,'alreadyNotified',true,'recipients',0);
 end if;
 if order_doc->>'source' not in ('business','marketplace') then
   raise exception 'Unsupported delivery source';
 end if;
 order_doc:=order_doc||jsonb_build_object('deliveryStaffNotified',true);
 perform public.kp_v8_put('deliveryCustomOrders',jsonb_set(root_doc,array[p_id],order_doc,true));
 for resident in select key,value from jsonb_each(coalesce(users_doc,'{}'::jsonb)) loop
   if resident.key<>actor and (
      resident.value->>'job'='Доставщик'
      or exists (select 1 from jsonb_array_elements(
         case when jsonb_typeof(resident.value->'employments')='array'
           then resident.value->'employments' else '[]'::jsonb end) as employment(job)
         where job->>'type'='municipal' and job->>'role'='Доставщик')
   ) then
     perform public.kp_v8_notify(resident.key,
       'Новая доставка: '||left(coalesce(order_doc->>'items','заказ'),250),
       'delivery_orders','delivery_'||p_id||'_new');
     notified:=notified+1;
   end if;
 end loop;
 return jsonb_build_object('ok',true,'alreadyNotified',false,'recipients',notified);
end; $$;
revoke all on function public.kp_delivery_alert_v22(text) from public,anon;
grant execute on function public.kp_delivery_alert_v22(text) to authenticated;
commit;
