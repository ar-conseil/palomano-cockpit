-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v28 : ventes de caisse du jour par catégorie (lues dans Qweekle par sync_ventes.py).
--   · ventes_jour : une ligne par jour, niveau (cat / sub / prod) et libellé — quantité, visiteurs, ventes, HT.
--   · caisse_jour(jour) : les catégories ramenées aux rubriques de la saisie du jour, HT et TTC
--     (TVA : entrées, scolaires et groupes 10 % · anniversaires, boutique et évènements 20 % ·
--     snacking : taux moyen constaté dans les saisies précédentes). Acomptes et bons cadeaux à part.
--   · saisie_auto(jour) : ajoute « caisse » → la saisie du jour se pré-remplit, il reste à vérifier.
--   · live_caisse(jour) : ventes, snacking, boutique et meilleures ventes pour « En direct ».
-- À exécuter après schema_v27.sql (Supabase › SQL Editor › Run). Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════
create table if not exists public.ventes_jour (
  date date not null,
  niveau text not null check (niveau in ('cat', 'sub', 'prod')),
  label text not null,
  nbr numeric, visiteurs numeric, ventes numeric, ht numeric,
  synced_at timestamptz not null default now(),
  primary key (date, niveau, label)
);
alter table public.ventes_jour enable row level security;   -- lue par les fonctions ci-dessous

-- Rubrique de la saisie du jour pour une catégorie de caisse
create or replace function public.vj_rubrique(label text) returns text
language sql immutable as $$
  select case
    when lower(label) like '%acompte%' then 'acompte'
    when lower(label) ~ '(cadeau|billetterie)' then 'cadeau'
    when lower(label) like '%snack%' then 'snack'
    when lower(label) like '%boutique%' then 'boutique'
    when lower(label) like '%anniv%' then 'anniv'
    when lower(label) like '%scol%' or lower(label) like '%school%' then 'scolaire'
    when lower(label) ~ '(loisirs|groupe|assistante)' then 'groupe'
    when lower(label) like 'entr%e au parc%' or lower(label) like 'entr%' then 'parc'
    when lower(label) ~ '(v[èeé]n|atelier|privatis|palo-bouh|palo-boom)' then 'event'
    else 'autre' end
$$;

create or replace function public.caisse_jour(d date) returns json
language sql stable security definer set search_path = public as $$
  with c as (
    select public.vj_rubrique(label) r, sum(ht) ht, sum(nbr) nbr, sum(visiteurs) vis, sum(ventes) ventes, max(synced_at) maj
      from ventes_jour where date = d and niveau = 'cat' group by 1),
  tx as (select coalesce((select round(avg(snack_ttc / snack_ht), 4) from saisie_jour
                           where snack_ht > 0 and snack_ttc > 0 and snack_ttc / snack_ht between 1.03 and 1.2), 1.08) snack),
  v as (select r, ht, nbr, vis, ventes,
               round(ht * case r when 'parc' then 1.10 when 'scolaire' then 1.10 when 'groupe' then 1.10
                                 when 'snack' then (select snack from tx) else 1.20 end, 2) ttc
          from c)
  select case when exists (select 1 from c) then json_build_object(
    'maj', (select max(maj) from c),
    'parc_ttc', (select ttc from v where r = 'parc'), 'parc_ht', (select round(ht, 2) from v where r = 'parc'),
    'parc_nb', (select nbr::int from v where r = 'parc'),
    'anniv_ttc', (select ttc from v where r = 'anniv'), 'anniv_ht', (select round(ht, 2) from v where r = 'anniv'),
    'scolaire_ttc', (select ttc from v where r = 'scolaire'),
    'groupe_ttc', (select ttc from v where r = 'groupe'),
    'snack_ht', (select round(ht, 2) from v where r = 'snack'), 'snack_ttc', (select ttc from v where r = 'snack'),
    'snack_nb', (select nbr from v where r = 'snack'),
    'boutique_ht', (select round(ht, 2) from v where r = 'boutique'), 'boutique_ttc', (select ttc from v where r = 'boutique'),
    'boutique_nb', (select nbr from v where r = 'boutique'),
    'event_ttc', (select ttc from v where r = 'event'),
    'total_ht', (select round(sum(ht), 2) from v where r not in ('acompte', 'cadeau')),
    'total_ttc', (select round(sum(ttc), 2) from v where r not in ('acompte', 'cadeau')),
    'ventes_nb', (select sum(ventes) from v where r not in ('acompte', 'cadeau')),
    'exclus_ht', (select round(abs(sum(ht)), 2) from v where r in ('acompte', 'cadeau')),
    'exclus_nb', (select sum(ventes) from v where r in ('acompte', 'cadeau'))
  ) end
$$;
revoke all on function public.caisse_jour(date) from public, anon, authenticated;

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
    'yavin',         (select row_to_json(y) from yavin_jour y where y.date = d),
    'caisse',        public.caisse_jour(d)
  ) end
$$;
grant execute on function public.saisie_auto(date) to authenticated;

create or replace function public.live_caisse(d date default null) returns json
language plpgsql stable security definer set search_path = public as $$
declare jour date := coalesce(d, (now() at time zone 'Europe/Paris')::date); c json;
begin
  if not public.is_member() then return null; end if;
  c := public.caisse_jour(jour);
  if c is null then return null; end if;
  return json_build_object(
    'maj', c->'maj',
    'ventes', json_build_object('nb', c->'ventes_nb', 'ttc', c->'total_ttc', 'ht', c->'total_ht', 'source', 'caisse'),
    'exclus', json_build_object('nb', c->'exclus_nb', 'ttc', c->'exclus_ht'),
    'snack', json_build_object('articles', c->'snack_nb', 'ttc', c->'snack_ttc', 'ht', c->'snack_ht',
      'top', (select json_agg(json_build_object('label', label, 'q', nbr, 'm', round(ht, 2)) order by nbr desc nulls last)
                from (select v.label, v.nbr, v.ht from ventes_jour v join produit_famille pf on pf.nom = lower(v.label)
                       where v.date = jour and v.niveau = 'prod' and pf.famille = 'snack' order by v.nbr desc nulls last limit 5) t)),
    'boutique', json_build_object('articles', c->'boutique_nb', 'ttc', c->'boutique_ttc', 'ht', c->'boutique_ht',
      'top', (select json_agg(json_build_object('label', label, 'q', nbr, 'm', round(ht, 2)) order by nbr desc nulls last)
                from (select v.label, v.nbr, v.ht from ventes_jour v join produit_famille pf on pf.nom = lower(v.label)
                       where v.date = jour and v.niveau = 'prod' and pf.famille = 'boutique' order by v.nbr desc nulls last limit 5) t)),
    'entrees', c->'parc_nb');
end $$;
revoke all on function public.live_caisse(date) from public, anon;
grant execute on function public.live_caisse(date) to authenticated;

select public.vj_rubrique('Entrée au parc') as parc, public.vj_rubrique('Palo-Snack') as snack, public.vj_rubrique('Acomptes') as acompte,
       public.vj_rubrique('Billetterie et bons cadeaux') as cadeau, public.vj_rubrique('Accueil de loisirs') as groupe,
       (select count(*) from public.ventes_jour) as lignes;
