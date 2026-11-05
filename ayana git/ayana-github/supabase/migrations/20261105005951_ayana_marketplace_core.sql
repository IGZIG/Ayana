-- Ayana production foundation — Niger (XOF)
-- Apply to a NEW Ayana Supabase project only. Never run against unrelated projects.
create extension if not exists pgcrypto;
create schema if not exists private;

create type public.user_role as enum ('customer','seller','courier','support','admin');
create type public.store_status as enum ('pending_review','active','suspended','rejected');
create type public.subscription_status as enum ('trialing','active','past_due','expired','cancelled');
create type public.order_status as enum ('pending_confirmation','confirmed','processing','partially_shipped','shipped','delivered','cancelled','disputed');
create type public.payment_method as enum ('mobile_money','cash_on_delivery');
create type public.payment_status as enum ('pending','authorized','paid','failed','refunded','partially_refunded','collected_cash');
create type public.seller_order_status as enum ('pending','accepted','preparing','ready_for_pickup','in_transit','delivered','cancelled','returned','disputed');
create type public.shipment_status as enum ('unassigned','assigned','pickup_scheduled','picked_up','in_transit','out_for_delivery','delivered','delivery_failed','returned','cancelled');
create type public.delivery_event_type as enum ('created','assigned','pickup_scheduled','picked_up','in_transit','out_for_delivery','delivered','delivery_failed','returned','note');

-- Roles and profiles. Role assignment is restricted to trusted server/admin flows.
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  phone text,
  role public.user_role not null default 'customer',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.stores (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id),
  name text not null,
  slug text not null unique,
  description text,
  phone text not null,
  city text not null default 'Niamey',
  address text,
  status public.store_status not null default 'pending_review',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index stores_owner_idx on public.stores(owner_id);
create index stores_status_idx on public.stores(status);

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  parent_id uuid references public.categories(id),
  name text not null,
  slug text not null unique,
  active boolean not null default true,
  sort_order int not null default 0
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores(id) on delete cascade,
  category_id uuid references public.categories(id),
  name text not null,
  slug text not null,
  description text,
  price_xof bigint not null check (price_xof >= 0),
  stock_qty integer not null default 0 check (stock_qty >= 0),
  attributes jsonb not null default '{}'::jsonb,
  active boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(store_id, slug)
);
create index products_store_idx on public.products(store_id);
create index products_category_active_idx on public.products(category_id, active);

-- Seller SaaS subscription: 5,000 XOF per 40-day billing period, no sales commission.
create table public.store_subscriptions (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores(id) on delete cascade,
  status public.subscription_status not null default 'trialing',
  price_xof bigint not null default 5000 check (price_xof >= 0),
  period_days integer not null default 40 check (period_days > 0),
  trial_ends_at timestamptz,
  current_period_start timestamptz,
  current_period_end timestamptz,
  auto_renew boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index subscriptions_store_status_idx on public.store_subscriptions(store_id, status);

create table public.subscription_payments (
  id uuid primary key default gen_random_uuid(),
  subscription_id uuid not null references public.store_subscriptions(id),
  amount_xof bigint not null check (amount_xof > 0),
  method public.payment_method not null default 'mobile_money',
  status public.payment_status not null default 'pending',
  provider_code text,
  provider_reference text unique,
  paid_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.customer_addresses (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.profiles(id) on delete cascade,
  label text,
  recipient_name text not null,
  phone text not null,
  region text not null,
  city text not null,
  district text,
  address_line text not null,
  landmark text,
  latitude numeric(10,7),
  longitude numeric(10,7),
  created_at timestamptz not null default now()
);

-- An order is the customer's checkout. It is split into one seller_order and shipment per store.
create table public.orders (
  id uuid primary key default gen_random_uuid(),
  order_number text not null unique,
  customer_id uuid not null references public.profiles(id),
  address_snapshot jsonb not null,
  payment_method public.payment_method not null,
  status public.order_status not null default 'pending_confirmation',
  subtotal_xof bigint not null check (subtotal_xof >= 0),
  delivery_total_xof bigint not null default 0 check (delivery_total_xof >= 0),
  total_xof bigint not null check (total_xof >= 0),
  customer_phone text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index orders_customer_date_idx on public.orders(customer_id, created_at desc);

create table public.seller_orders (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  store_id uuid not null references public.stores(id),
  status public.seller_order_status not null default 'pending',
  subtotal_xof bigint not null check (subtotal_xof >= 0),
  delivery_fee_xof bigint not null default 0 check (delivery_fee_xof >= 0),
  seller_amount_xof bigint not null check (seller_amount_xof >= 0),
  no_sales_commission boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(order_id, store_id)
);
create index seller_orders_store_idx on public.seller_orders(store_id, created_at desc);

create table public.seller_order_items (
  id uuid primary key default gen_random_uuid(),
  seller_order_id uuid not null references public.seller_orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  product_name_snapshot text not null,
  unit_price_xof bigint not null check (unit_price_xof >= 0),
  quantity integer not null check (quantity > 0),
  line_total_xof bigint not null check (line_total_xof >= 0)
);

create table public.order_payments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  method public.payment_method not null,
  status public.payment_status not null default 'pending',
  amount_xof bigint not null check (amount_xof > 0),
  provider_code text,
  provider_reference text unique,
  idempotency_key text unique,
  paid_at timestamptz,
  created_at timestamptz not null default now()
);

-- Delivery partners are manually managed until a contracted carrier API is selected.
create table public.delivery_partners (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  contact_name text,
  phone text not null,
  email text,
  coverage_regions text[] not null default '{}',
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- Admin-configurable prices/capacity by Niger delivery zone. No unverified route prices are seeded.
create table public.delivery_zones (
  id uuid primary key default gen_random_uuid(),
  region text not null,
  city text not null,
  district text,
  fee_xof bigint not null check (fee_xof >= 0),
  estimated_days_min integer not null default 1 check (estimated_days_min > 0),
  estimated_days_max integer not null default 3 check (estimated_days_max >= estimated_days_min),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(region, city, district)
);

create table public.shipments (
  id uuid primary key default gen_random_uuid(),
  tracking_code text not null unique,
  seller_order_id uuid not null unique references public.seller_orders(id) on delete cascade,
  partner_id uuid references public.delivery_partners(id),
  zone_id uuid references public.delivery_zones(id),
  status public.shipment_status not null default 'unassigned',
  fee_xof bigint not null default 0 check (fee_xof >= 0),
  partner_reference text,
  recipient_phone text not null,
  assigned_at timestamptz,
  picked_up_at timestamptz,
  delivered_at timestamptz,
  failed_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index shipments_status_created_idx on public.shipments(status, created_at);
create index shipments_partner_status_idx on public.shipments(partner_id, status);

create table public.delivery_events (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references public.shipments(id) on delete cascade,
  event_type public.delivery_event_type not null,
  note text,
  location_text text,
  latitude numeric(10,7),
  longitude numeric(10,7),
  actor_id uuid references public.profiles(id),
  created_at timestamptz not null default now()
);
create index delivery_events_shipment_date_idx on public.delivery_events(shipment_id, created_at);

create table public.audit_log (
  id bigint generated always as identity primary key,
  actor_id uuid references public.profiles(id),
  action text not null,
  entity_type text not null,
  entity_id uuid,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- Subscription entitlement is checked on the server and in database policies.
create or replace function private.store_subscription_is_live(p_store_id uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from public.store_subscriptions sub
    where sub.store_id = p_store_id
      and ((sub.status = 'active' and sub.current_period_end > now())
        or (sub.status = 'trialing' and sub.trial_ends_at > now()))
  );
$$;
create or replace function private.store_can_sell(p_store_id uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from public.stores s
    where s.id = p_store_id and s.owner_id = auth.uid() and s.status = 'active'
  ) and private.store_subscription_is_live(p_store_id);
$$;
revoke all on function private.store_subscription_is_live(uuid) from public;
revoke all on function private.store_can_sell(uuid) from public;
grant usage on schema private to anon, authenticated;
grant execute on function private.store_subscription_is_live(uuid) to anon, authenticated;
grant execute on function private.store_can_sell(uuid) to authenticated;

-- Restrict access by default. Service-role/server-side code performs privileged transitions.
alter table public.profiles enable row level security;
alter table public.stores enable row level security;
alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.store_subscriptions enable row level security;
alter table public.subscription_payments enable row level security;
alter table public.customer_addresses enable row level security;
alter table public.orders enable row level security;
alter table public.seller_orders enable row level security;
alter table public.seller_order_items enable row level security;
alter table public.order_payments enable row level security;
alter table public.delivery_partners enable row level security;
alter table public.delivery_zones enable row level security;
alter table public.shipments enable row level security;
alter table public.delivery_events enable row level security;
alter table public.audit_log enable row level security;

create policy "profiles_read_self" on public.profiles for select to authenticated using (id = auth.uid());
-- Role/profile writes are performed only by trusted server-side provisioning flows.
create policy "categories_public_read" on public.categories for select to anon, authenticated using (active);
create policy "stores_public_read_active" on public.stores for select to anon, authenticated using (status = 'active');
create policy "stores_owner_read" on public.stores for select to authenticated using (owner_id = auth.uid());
create policy "stores_owner_update" on public.stores for update to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());
-- Column grants below prevent owners from changing owner_id/status even when the row policy matches.
create policy "products_public_read_active" on public.products for select to anon, authenticated using (active and exists(select 1 from public.stores s where s.id = store_id and s.status = 'active') and private.store_subscription_is_live(store_id));
create policy "products_owner_read" on public.products for select to authenticated using (exists(select 1 from public.stores s where s.id = store_id and s.owner_id = auth.uid()));
create policy "products_owner_insert" on public.products for insert to authenticated with check (exists(select 1 from public.stores s where s.id = store_id and s.owner_id = auth.uid()) and (not active or private.store_can_sell(store_id)));
create policy "products_owner_update" on public.products for update to authenticated using (exists(select 1 from public.stores s where s.id = store_id and s.owner_id = auth.uid())) with check (exists(select 1 from public.stores s where s.id = store_id and s.owner_id = auth.uid()) and (not active or private.store_can_sell(store_id)));
create policy "addresses_customer_access" on public.customer_addresses for all to authenticated using (customer_id = auth.uid()) with check (customer_id = auth.uid());
create policy "orders_customer_read" on public.orders for select to authenticated using (customer_id = auth.uid());
create policy "seller_orders_store_owner_read" on public.seller_orders for select to authenticated using (exists(select 1 from public.stores s where s.id = store_id and s.owner_id = auth.uid()));
create policy "seller_order_items_owner_read" on public.seller_order_items for select to authenticated using (exists(select 1 from public.seller_orders so join public.stores s on s.id = so.store_id where so.id = seller_order_id and s.owner_id = auth.uid()));
create policy "subscriptions_owner_read" on public.store_subscriptions for select to authenticated using (exists(select 1 from public.stores s where s.id = store_id and s.owner_id = auth.uid()));
create policy "subscription_payments_owner_read" on public.subscription_payments for select to authenticated using (exists(select 1 from public.store_subscriptions sub join public.stores s on s.id = sub.store_id where sub.id = subscription_id and s.owner_id = auth.uid()));
create policy "delivery_zones_public_active_read" on public.delivery_zones for select to anon, authenticated using (active);
create policy "shipment_customer_read" on public.shipments for select to authenticated using (exists(select 1 from public.seller_orders so join public.orders o on o.id = so.order_id where so.id = seller_order_id and o.customer_id = auth.uid()));
create policy "shipment_seller_read" on public.shipments for select to authenticated using (exists(select 1 from public.seller_orders so join public.stores s on s.id = so.store_id where so.id = seller_order_id and s.owner_id = auth.uid()));
create policy "delivery_events_customer_read" on public.delivery_events for select to authenticated using (exists(select 1 from public.shipments sh join public.seller_orders so on so.id = sh.seller_order_id join public.orders o on o.id = so.order_id where sh.id = shipment_id and o.customer_id = auth.uid()));
create policy "delivery_events_seller_read" on public.delivery_events for select to authenticated using (exists(select 1 from public.shipments sh join public.seller_orders so on so.id = sh.seller_order_id join public.stores s on s.id = so.store_id where sh.id = shipment_id and s.owner_id = auth.uid()));

-- Restrict owner edits to non-privileged store columns; they cannot self-approve or transfer ownership.
revoke update on table public.stores from authenticated;
grant update (name, description, phone, city, address) on table public.stores to authenticated;

-- No client-side INSERT/UPDATE policies for profiles/roles, subscriptions, payments, delivery assignment,
-- order state, delivery events, or audit records. These writes must go through authenticated server routes /
-- Edge Functions using service credentials, with role checks, idempotency, signed carrier callbacks,
-- and immutable audit events. Never put service-role credentials in the browser.

-- Starter categories. Add the full taxonomy through admin UI; product-specific fields live in attributes JSON.
insert into public.categories(name,slug,sort_order) values
 ('Alimentation','alimentation',10),('Mode','mode',20),('Maison','maison',30),
 ('Électronique','electronique',40),('Beauté','beaute',50),('Sport','sport',60),
 ('Livres','livres',70),('Enfants','enfants',80)
on conflict(slug) do nothing;

