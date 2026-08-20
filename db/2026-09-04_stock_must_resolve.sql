-- Inventory is authoritative: an order line that cannot resolve to a canonical
-- product_variants row must reject the whole transaction, never bypass stock.
-- Apply after 2026-09-01 and 2026-09-03.

create or replace function public.cupai_require_stock_product(
  p_item jsonb,
  p_user_id uuid
)
returns uuid
language plpgsql
stable
set search_path = public
as $$
declare
  v_product uuid;
begin
  v_product := public.cupai_resolve_product(p_item, p_user_id);
  if v_product is null then
    raise exception using
      errcode = 'P0001',
      message = 'inventory_product_unresolved',
      detail = coalesce(p_item->>'product_name', 'unknown product');
  end if;
  return v_product;
end;
$$;

grant execute on function public.cupai_require_stock_product(jsonb, uuid) to service_role;

-- Replace every silent resolver skip in the current stock RPC definitions.
-- Keeping this mechanical replacement in a migration ensures future installs
-- and already-running databases receive the same fail-closed behavior.
do $$
declare
  v_proc regprocedure;
  v_definition text;
begin
  for v_proc in
    select p.oid::regprocedure
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'check_order_stock',
        'create_order_with_stock',
        'confirm_order_payment',
        'update_order_with_stock'
      )
  loop
    v_definition := pg_get_functiondef(v_proc);
    v_definition := replace(
      v_definition,
      'v_product := public.cupai_resolve_product(v_item, v_user_id);',
      'v_product := public.cupai_require_stock_product(v_item, v_user_id);'
    );
    v_definition := regexp_replace(
      v_definition,
      E'\\n[[:space:]]*if v_product is null then\\n[[:space:]]*continue;[^\\n]*\\n[[:space:]]*end if;',
      '',
      'g'
    );
    execute v_definition;
  end loop;
end;
$$;