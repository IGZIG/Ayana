-- Tighten execute grants after Supabase default privileges exposed RPCs to anon.
revoke all on function public.submit_store_application(text,text,text,text,text,text) from public, anon;
revoke all on function public.create_marketplace_order(jsonb,jsonb,uuid,text,public.payment_method) from public, anon;
grant execute on function public.submit_store_application(text,text,text,text,text,text) to authenticated;
grant execute on function public.create_marketplace_order(jsonb,jsonb,uuid,text,public.payment_method) to authenticated;
