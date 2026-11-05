-- Authenticated seller application and atomic multi-seller checkout for Ayana.

alter table public.orders add column idempotency_key text;
create unique index orders_customer_idempotency_uidx on public.orders(customer_id, idempotency_key) where idempotency_key is not null;

create or replace function private.on_auth_user_created()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into public.profiles(id, full_name, phone)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name',''), nullif(new.raw_user_meta_data->>'phone',''))
  on conflict (id) do nothing;
  return new;
end;
$$;
revoke all on function private.on_auth_user_created() from public;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute function private.on_auth_user_created();

create or replace function public.submit_store_application(
  p_name text, p_slug text, p_phone text, p_city text, p_address text, p_description text default null
) returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  v_user uuid := auth.uid();
  v_store_id uuid;
  v_slug text := lower(trim(p_slug));
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if length(trim(coalesce(p_name,''))) < 2 or length(trim(p_name)) > 100 then raise exception 'STORE_NAME_INVALID'; end if;
  if v_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' or length(v_slug) > 80 then raise exception 'STORE_SLUG_INVALID'; end if;
  if length(trim(coalesce(p_phone,''))) < 7 or length(trim(coalesce(p_city,''))) < 2 or length(trim(coalesce(p_address,''))) < 4 then raise exception 'STORE_CONTACT_INVALID'; end if;
  if exists(select 1 from public.stores where owner_id=v_user and status in ('pending_review','active')) then
    raise exception 'STORE_APPLICATION_ALREADY_EXISTS';
  end if;
  insert into public.stores(owner_id,name,slug,description,phone,city,address,status)
  values(v_user,trim(p_name),v_slug,nullif(trim(coalesce(p_description,'')),''),trim(p_phone),trim(p_city),trim(p_address),'pending_review')
  returning id into v_store_id;
  return jsonb_build_object('store_id',v_store_id,'status','pending_review');
end;
$$;
revoke all on function public.submit_store_application(text,text,text,text,text,text) from public;
grant execute on function public.submit_store_application(text,text,text,text,text,text) to authenticated;

create or replace function public.create_marketplace_order(
  p_items jsonb,
  p_address jsonb,
  p_zone_id uuid,
  p_idempotency_key text,
  p_payment_method public.payment_method default 'cash_on_delivery'
) returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  v_user uuid := auth.uid();
  v_zone public.delivery_zones%rowtype;
  v_item jsonb;
  v_product record;
  v_order_id uuid;
  v_order_number text;
  v_seller_order_id uuid;
  v_subtotal bigint := 0;
  v_delivery_total bigint := 0;
  v_line_total bigint;
  v_parcel_count integer := 0;
  v_qty integer;
  v_product_id uuid;
  v_existing record;
  v_store_orders jsonb := '[]'::jsonb;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_payment_method <> 'cash_on_delivery' then raise exception 'MOBILE_MONEY_NOT_CONFIGURED'; end if;
  if p_idempotency_key is null or length(p_idempotency_key) < 16 or length(p_idempotency_key) > 120 then raise exception 'IDEMPOTENCY_KEY_INVALID'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 30 then raise exception 'CART_INVALID'; end if;
  if jsonb_typeof(p_address) <> 'object'
     or nullif(trim(p_address->>'recipient_name'),'') is null
     or nullif(trim(p_address->>'phone'),'') is null
     or nullif(trim(p_address->>'region'),'') is null
     or nullif(trim(p_address->>'city'),'') is null
     or nullif(trim(p_address->>'address_line'),'') is null then raise exception 'ADDRESS_INCOMPLETE'; end if;

  perform pg_advisory_xact_lock(hashtextextended(v_user::text || ':' || p_idempotency_key, 0));
  select id,order_number,total_xof into v_existing from public.orders where customer_id=v_user and idempotency_key=p_idempotency_key;
  if found then return jsonb_build_object('order_id',v_existing.id,'order_number',v_existing.order_number,'total_xof',v_existing.total_xof,'replayed',true); end if;

  select * into v_zone from public.delivery_zones where id=p_zone_id and active=true;
  if not found then raise exception 'DELIVERY_ZONE_UNAVAILABLE'; end if;
  if lower(v_zone.region) <> lower(trim(p_address->>'region')) or lower(v_zone.city) <> lower(trim(p_address->>'city')) then
    raise exception 'ADDRESS_OUTSIDE_ZONE';
  end if;
  if v_zone.district is not null and lower(v_zone.district) <> lower(trim(coalesce(p_address->>'district',''))) then
    raise exception 'ADDRESS_OUTSIDE_ZONE';
  end if;

  v_order_number := 'AY-' || upper(substr(encode(gen_random_bytes(6),'hex'),1,12));
  insert into public.orders(order_number,customer_id,idempotency_key,address_snapshot,payment_method,status,subtotal_xof,delivery_total_xof,total_xof,customer_phone)
  values(v_order_number,v_user,p_idempotency_key,p_address,p_payment_method,'pending_confirmation',0,0,0,trim(p_address->>'phone'))
  returning id into v_order_id;

  for v_item in select elem from jsonb_array_elements(p_items) as t(elem) loop
    begin
      v_product_id := (v_item->>'product_id')::uuid;
      v_qty := (v_item->>'quantity')::integer;
    exception when others then raise exception 'CART_ITEM_INVALID';
    end;
    if v_qty is null or v_qty < 1 or v_qty > 50 then raise exception 'CART_QUANTITY_INVALID'; end if;

    select p.id,p.store_id,p.name,p.price_xof,p.stock_qty,s.status as store_status
      into v_product
      from public.products p join public.stores s on s.id=p.store_id
      where p.id=v_product_id and p.active=true
      for update of p;
    if not found then raise exception 'PRODUCT_UNAVAILABLE'; end if;
    if v_product.store_status <> 'active' or not private.store_subscription_is_live(v_product.store_id) then raise exception 'STORE_NOT_ENTITLED'; end if;
    if v_product.stock_qty < v_qty then raise exception 'INSUFFICIENT_STOCK'; end if;
    v_line_total := v_product.price_xof * v_qty;
    if v_line_total <= 0 then raise exception 'PRODUCT_PRICE_INVALID'; end if;

    select id into v_seller_order_id from public.seller_orders where order_id=v_order_id and store_id=v_product.store_id;
    if v_seller_order_id is null then
      insert into public.seller_orders(order_id,store_id,status,subtotal_xof,delivery_fee_xof,seller_amount_xof,no_sales_commission)
      values(v_order_id,v_product.store_id,'pending',0,v_zone.fee_xof,0,true) returning id into v_seller_order_id;
      insert into public.shipments(tracking_code,seller_order_id,zone_id,status,fee_xof,recipient_phone)
      values('AYD-'||upper(substr(encode(gen_random_bytes(6),'hex'),1,12)),v_seller_order_id,v_zone.id,'unassigned',v_zone.fee_xof,trim(p_address->>'phone'));
      v_parcel_count := v_parcel_count + 1;
    end if;

    insert into public.seller_order_items(seller_order_id,product_id,product_name_snapshot,unit_price_xof,quantity,line_total_xof)
    values(v_seller_order_id,v_product.id,v_product.name,v_product.price_xof,v_qty,v_line_total);
    update public.seller_orders set subtotal_xof=subtotal_xof+v_line_total,seller_amount_xof=seller_amount_xof+v_line_total,updated_at=now() where id=v_seller_order_id;
    update public.products set stock_qty=stock_qty-v_qty,updated_at=now() where id=v_product.id;
    v_subtotal := v_subtotal + v_line_total;
  end loop;

  if v_parcel_count = 0 then raise exception 'CART_INVALID'; end if;
  v_delivery_total := v_parcel_count * v_zone.fee_xof;
  update public.orders set subtotal_xof=v_subtotal,delivery_total_xof=v_delivery_total,total_xof=v_subtotal+v_delivery_total,updated_at=now() where id=v_order_id;
  insert into public.order_payments(order_id,method,status,amount_xof,idempotency_key)
  values(v_order_id,p_payment_method,'pending',v_subtotal+v_delivery_total,p_idempotency_key);
  insert into public.delivery_events(shipment_id,event_type,actor_id,note)
  select sh.id,'created',v_user,'Commande créée ; en attente d’affectation du partenaire.'
  from public.shipments sh join public.seller_orders so on so.id=sh.seller_order_id where so.order_id=v_order_id;
  select coalesce(jsonb_agg(jsonb_build_object('seller_order_id',so.id,'store_id',so.store_id,'shipment_status',sh.status)), '[]'::jsonb)
    into v_store_orders from public.seller_orders so join public.shipments sh on sh.seller_order_id=so.id where so.order_id=v_order_id;
  return jsonb_build_object('order_id',v_order_id,'order_number',v_order_number,'subtotal_xof',v_subtotal,'delivery_total_xof',v_delivery_total,'total_xof',v_subtotal+v_delivery_total,'seller_orders',v_store_orders,'replayed',false);
end;
$$;
revoke all on function public.create_marketplace_order(jsonb,jsonb,uuid,text,public.payment_method) from public;
grant execute on function public.create_marketplace_order(jsonb,jsonb,uuid,text,public.payment_method) to authenticated;
