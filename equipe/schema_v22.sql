-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v22 : chiffres du jour SANS acomptes (réservations en ligne), avoirs ni
-- cartes / bons cadeaux (même règle que le dashboard financier : famille « autre » hors CA).
--   · qw_exclu(libellé, catégorie) : ligne d'acompte, d'avoir, de carte ou de bon cadeau.
--   · qw_vente_comptee(vente) : écarte les avoirs (montant ≤ 0) et les ventes en ligne (acomptes).
--   · live_jour() et saisie_auto() appliquent ces règles.
-- À exécuter après schema_v21.sql (Supabase › SQL Editor › Run). Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public.qw_exclu(label text, cat text) returns boolean
language sql immutable as $$
  select lower(coalesce(label, '') || ' ' || coalesce(cat, '')) ~
    '(acompte|arrhes|\mavoirs?\M|rembours|carte[ -]?cadeau|bon[ -]?cadeau|ch[eè]que[ -]?cadeau|e-?carte|gift|voucher|paiement)'
$$;

create or replace function public.qw_vente_comptee(p jsonb) returns boolean
language sql immutable as $$
  select coalesce((p->>'amount')::numeric, 0) > 0
     and lower(coalesce(p->>'source', '')) !~ '(online|web|shop|e-?commerce|widget|site|internet|booking|marketplace)'
     and not public.qw_exclu(coalesce(p->>'label', '') || ' ' || coalesce(p->>'type', ''), p->>'category')
$$;

-- ── Chiffres du jour en direct ──
create or replace function public.live_jour(d date default null) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  jour date := coalesce(d, (now() at time zone 'Europe/Paris')::date);
  mgr boolean := true;   -- v21 : montants HT et TTC visibles par toute l'équipe (décision de la direction, 09/11/2026)
  res json;
begin
  if not public.is_member() then return null; end if;
  with ventes_all as (
    select distinct on (coalesce(payload->>'id', id::text)) payload, received_at
      from qweekle_events
     where event_type = 'sale.created'
       and (coalesce((payload->>'created_at')::timestamptz, received_at) at time zone 'Europe/Paris')::date = jour
     order by coalesce(payload->>'id', id::text), received_at),
  ventes as (select * from ventes_all where public.qw_vente_comptee(payload)),
  inv as (
    select distinct on (coalesce(payload->>'id', id::text)) payload
      from qweekle_events
     where event_type = 'invoice.created'
       and (coalesce((payload->>'created_at')::timestamptz, received_at) at time zone 'Europe/Paris')::date = jour
     order by coalesce(payload->>'id', id::text), received_at),
  lignes as (
    select case when public.qw_exclu(l.label, l.cat) or coalesce(l.amount, 0) < 0 then 'exclu'
                else coalesce(public.famille_cat(l.cat), pf.famille, 'autre') end as fam, l.label, l.qty, l.amount, l.ht, inv.payload->>'id' as fid
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
    -- CA du jour : sans acomptes (réservations en ligne), avoirs ni cartes / bons cadeaux.
    -- Détail des factures quand Qweekle le donne, sinon ventes filtrées.
    'ventes', case when exists (select 1 from lignes) then json_build_object(
        'nb', (select count(distinct fid) from lignes where fam not in ('exclu', 'autre')),
        'ttc', case when mgr then (select round(sum(amount), 2) from lignes where fam not in ('exclu', 'autre')) end,
        'ht', case when mgr then (select case when count(ht) = count(*) then round(sum(ht), 2) end from lignes where fam not in ('exclu', 'autre')) end,
        'derniere', (select max(received_at) from ventes), 'source', 'factures')
      else json_build_object(
        'nb', (select count(*) from ventes),
        'ttc', case when mgr then (select round(sum((payload->>'amount')::numeric), 2) from ventes) end,
        'ht', case when mgr then (select round(sum((payload->>'amount_ex_taxes')::numeric), 2) from ventes) end,
        'derniere', (select max(received_at) from ventes), 'source', 'ventes') end,
    'exclus', json_build_object(
      'nb', (select count(*) from ventes_all where not public.qw_vente_comptee(payload)) + (select count(*) from lignes where fam = 'exclu'),
      'ttc', case when mgr then coalesce((select round(sum((payload->>'amount')::numeric), 2) from ventes_all where not public.qw_vente_comptee(payload)), 0)
                              + coalesce((select round(sum(amount), 2) from lignes where fam = 'exclu'), 0) end),
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


-- Saisie du jour : « Encaissé dans Qweekle » sans acomptes, avoirs ni cartes cadeaux
create or replace function public.saisie_auto(d date) returns json
language sql stable security definer set search_path = public as $$
  with ventes as (
    select distinct on (payload->>'id') payload
      from qweekle_events
     where event_type = 'sale.created'
       and ((payload->>'created_at')::timestamptz at time zone 'Europe/Paris')::date = d
       and public.qw_vente_comptee(payload)
     order by payload->>'id', received_at)
  select case when public.can_saisie() then json_build_object(
    'anniv_nb',      (select count(*) from anniversaires where date = d and statut <> 'annule'),
    'anniv_entrees', (select coalesce(sum(nb_enfants), 0) from anniversaires where date = d and statut <> 'annule'),
    'scolaire_nb',   (select coalesce(sum(nb_enfants), 0) from groupes where date = d and type = 'ecole' and statut <> 'annule'),
    'groupe_nb',     (select coalesce(sum(nb_enfants), 0) from groupes where date = d and type = 'centre' and statut <> 'annule'),
    'ventes_nb',     (select count(*) from ventes),
    'ventes_ttc',    (select round(sum((payload->>'amount')::numeric), 2) from ventes),
    'ventes_ht',     (select round(sum((payload->>'amount_ex_taxes')::numeric), 2) from ventes),
    'webhook_depuis',(select min(received_at) from qweekle_events where event_type = 'sale.created'),
    'yavin',         (select row_to_json(y) from yavin_jour y where y.date = d)
  ) end
$$;
grant execute on function public.saisie_auto(date) to authenticated;

select public.qw_exclu('Acompte anniversaire', null) as acompte_exclu, public.qw_exclu('Carte cadeau 30 €', null) as carte_exclue,
       public.qw_exclu('Crêpe sucre', 'Snacking') as crepe_exclue,
       public.qw_vente_comptee('{"amount": 12, "source": "pos"}') as vente_caisse_comptee,
       public.qw_vente_comptee('{"amount": 50, "source": "online"}') as acompte_en_ligne_compte,
       public.qw_vente_comptee('{"amount": -8}') as avoir_compte;
