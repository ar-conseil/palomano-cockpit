-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v21 : chiffres du jour en € HT et TTC pour toute l'équipe.
--   Décision de la direction (09/11/2026) : le bandeau et l'onglet En direct montrent les montants
--   à tous les collaborateurs. Ajout du HT (ventes : amount_ex_taxes ; lignes de facture quand Qweekle le donne).
--   Les autres montants (paiements des anniversaires, privatisations, objectifs en €) restent réservés.
-- À exécuter après schema_v20.sql (Supabase › SQL Editor › Run). Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════
-- Lignes d'une facture Qweekle (structure exacte encore inconnue : on essaie les formes courantes)
drop function if exists public.qw_lignes(jsonb);
create or replace function public.qw_lignes(p jsonb)
returns table (label text, cat text, qty numeric, amount numeric, ht numeric)
language plpgsql immutable as $$
declare arr jsonb; l jsonb; q numeric;
begin
  for arr in
    select v from (values (p->'lines'), (p->'items'), (p->'invoice_lines'), (p->'products'), (p->'details'),
                          (p->'order_lines'), (p#>'{invoice,lines}'), (p#>'{data,lines}'), (p#>'{order,lines}'),
                          (p#>'{invoice,items}'), (p#>'{data,items}')) t(v)
     where jsonb_typeof(v) = 'array'
  loop
    for l in select * from jsonb_array_elements(arr) loop
      if jsonb_typeof(l) <> 'object' then continue; end if;
      q := coalesce(nullif(l->>'qty', '')::numeric, nullif(l->>'quantity', '')::numeric, 1);
      label := regexp_replace(btrim(coalesce(l->>'label', l->>'name', l->>'product_name', l#>>'{product,label}',
                                             l#>>'{product,name}', l->>'designation', '')), '^\[[^\]]*\]\s*', '');
      cat := coalesce(l->>'category', l#>>'{category,label}', l#>>'{category,name}', l->>'category_label',
                      l#>>'{product,category}', l#>>'{product,category,label}', l#>>'{product,category,name}', l->>'family');
      qty := q;
      amount := coalesce(nullif(l->>'amount', '')::numeric, nullif(l->>'total', '')::numeric,
                         nullif(l->>'amount_ttc', '')::numeric, nullif(l->>'total_ttc', '')::numeric,
                         nullif(l->>'amount_with_taxes', '')::numeric,
                         nullif(l->>'price_ttc', '')::numeric * q, nullif(l->>'unit_price', '')::numeric * q,
                         nullif(l->>'price', '')::numeric * q);
      ht := coalesce(nullif(l->>'amount_ex_taxes', '')::numeric, nullif(l->>'amount_ht', '')::numeric,
                     nullif(l->>'total_ht', '')::numeric, nullif(l->>'total_ex_taxes', '')::numeric,
                     nullif(l->>'amount_without_taxes', '')::numeric, nullif(l->>'price_ht', '')::numeric * q,
                     nullif(l->>'unit_price_ex_taxes', '')::numeric * q);
      return next;
    end loop;
    return;
  end loop;
exception when others then return;
end $$;

-- ── Chiffres du jour en direct ──
create or replace function public.live_jour(d date default null) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  jour date := coalesce(d, (now() at time zone 'Europe/Paris')::date);
  mgr boolean := true;   -- v21 : montants HT et TTC visibles par toute l'équipe (décision de la direction, 09/11/2026)
  res json;
begin
  if not public.is_member() then return null; end if;
  with ventes as (
    select distinct on (coalesce(payload->>'id', id::text)) payload, received_at
      from qweekle_events
     where event_type = 'sale.created'
       and (coalesce((payload->>'created_at')::timestamptz, received_at) at time zone 'Europe/Paris')::date = jour
     order by coalesce(payload->>'id', id::text), received_at),
  inv as (
    select distinct on (coalesce(payload->>'id', id::text)) payload
      from qweekle_events
     where event_type = 'invoice.created'
       and (coalesce((payload->>'created_at')::timestamptz, received_at) at time zone 'Europe/Paris')::date = jour
     order by coalesce(payload->>'id', id::text), received_at),
  lignes as (
    select coalesce(public.famille_cat(l.cat), pf.famille, 'autre') as fam, l.label, l.qty, l.amount, l.ht
      from inv, lateral public.qw_lignes(inv.payload) l
      left join produit_famille pf on pf.nom = lower(l.label)),
  famx as (
    select fam, sum(qty) art, round(sum(amount), 2) ttc, case when count(ht) = count(*) then round(sum(ht), 2) end ht from lignes group by fam),
  top as (
    select fam, label, sum(qty) q, round(sum(amount), 2) m,
           row_number() over (partition by fam order by sum(qty) desc, sum(amount) desc) rk
      from lignes where fam in ('snack', 'boutique') group by fam, label),
  heures as (
    select extract(hour from coalesce((payload->>'created_at')::timestamptz, received_at) at time zone 'Europe/Paris')::int h,
           count(*) n, round(sum((payload->>'amount')::numeric), 2) m, round(sum((payload->>'amount_ex_taxes')::numeric), 2) mh
      from ventes group by 1)
  select json_build_object(
    'jour', jour,
    'maj', now(),
    'montants', mgr,
    'resa', json_build_object(
      'anniv', (select count(*) from anniversaires where date = jour and statut <> 'annule'),
      'anniv_enfants', (select coalesce(sum(nb_enfants), 0) from anniversaires where date = jour and statut <> 'annule'),
      'centre', (select count(*) from groupes where date = jour and type = 'centre' and statut <> 'annule'),
      'centre_enfants', (select coalesce(sum(nb_enfants), 0) from groupes where date = jour and type = 'centre' and statut <> 'annule'),
      'ecole', (select count(*) from groupes where date = jour and type = 'ecole' and statut <> 'annule'),
      'ecole_enfants', (select coalesce(sum(nb_enfants), 0) from groupes where date = jour and type = 'ecole' and statut <> 'annule'),
      'privat', (select count(*) from privatisations where date = jour and statut <> 'annule'),
      'privat_pers', (select coalesce(sum(coalesce(nb_enfants, 0) + coalesce(nb_adultes, 0)), 0) from privatisations where date = jour and statut <> 'annule')),
    'ventes', json_build_object(
      'nb', (select count(*) from ventes),
      'ttc', case when mgr then (select round(sum((payload->>'amount')::numeric), 2) from ventes) end,
      'ht', case when mgr then (select round(sum((payload->>'amount_ex_taxes')::numeric), 2) from ventes) end,
      'derniere', (select max(received_at) from ventes)),
    'snack', json_build_object(
      'articles', (select art from famx where fam = 'snack'),
      'ttc', case when mgr then (select ttc from famx where fam = 'snack') end,
      'ht', case when mgr then (select ht from famx where fam = 'snack') end,
      'top', (select json_agg(json_build_object('label', label, 'q', q, 'm', case when mgr then m end) order by rk) from top where fam = 'snack' and rk <= 5)),
    'boutique', json_build_object(
      'articles', (select art from famx where fam = 'boutique'),
      'ttc', case when mgr then (select ttc from famx where fam = 'boutique') end,
      'ht', case when mgr then (select ht from famx where fam = 'boutique') end,
      'top', (select json_agg(json_build_object('label', label, 'q', q, 'm', case when mgr then m end) order by rk) from top where fam = 'boutique' and rk <= 5)),
    'entrees', (select art from famx where fam = 'entrees'),
    'heures', (select json_agg(json_build_object('h', h, 'n', n, 'm', case when mgr then m end, 'mh', case when mgr then mh end) order by h) from heures),
    'lignes_ok', exists (select 1 from lignes),
    'factures', (select count(*) from inv),
    'yavin', (select json_build_object('nb', y.nb, 'cb', case when mgr then y.cb_total end, 'maj', y.synced_at)
                from yavin_jour y where y.date = jour),
    'webhook_depuis', (select min(received_at) from qweekle_events where event_type in ('sale.created', 'invoice.created'))
  ) into res;
  return res;
end $$;
revoke all on function public.live_jour(date) from public, anon;
grant execute on function public.live_jour(date) to authenticated;


select (public.live_jour() is null) as pret_hors_session;
