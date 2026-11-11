-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v29 : TTC calculé avec la TVA réellement appliquée par la caisse Qweekle.
--   L'export caisse donne, pour chaque vente, le TTC et le HT : publish_kpis.py publie le coefficient
--   TTC / HT constaté par catégorie (tva_categorie) et par produit (produit_famille.coef).
--   caisse_jour() : TTC = HT × coefficient de la catégorie ; pour le snacking (taux mélangés 5,5 / 10 / 20 %),
--   coefficient pondéré par les produits réellement vendus ce jour-là.
-- À exécuter après schema_v28.sql (Supabase › SQL Editor › Run). Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════
alter table public.produit_famille add column if not exists coef numeric;
create table if not exists public.tva_categorie (
  cat text primary key,          -- catégorie de caisse en minuscules
  coef numeric not null,         -- TTC / HT constaté
  updated_at timestamptz not null default now()
);
alter table public.tva_categorie enable row level security;

create or replace function public.caisse_jour(d date) returns json
language sql stable security definer set search_path = public as $$
  with mix as (   -- coefficient du jour par famille, pondéré par les produits vendus
    select pf.famille, sum(v.ht * pf.coef) / nullif(sum(v.ht), 0) coef
      from ventes_jour v join produit_famille pf on pf.nom = lower(v.label)
     where v.date = d and v.niveau = 'prod' and v.ht > 0 and pf.coef between 1 and 1.25 and pf.famille in ('snack', 'boutique')
     group by 1),
  l as (
    select public.vj_rubrique(j.label) r, j.ht, j.nbr, j.visiteurs, j.ventes, j.synced_at,
           coalesce(case public.vj_rubrique(j.label) when 'snack' then (select coef from mix where famille = 'snack')
                                                     when 'boutique' then (select coef from mix where famille = 'boutique') end,
                    t.coef,
                    case public.vj_rubrique(j.label) when 'anniv' then 1.20 when 'boutique' then 1.20 when 'snack' then 1.09 else 1.10 end) coef
      from ventes_jour j left join tva_categorie t on t.cat = lower(btrim(j.label))
     where j.date = d and j.niveau = 'cat'),
  v as (select r, sum(ht) ht, sum(nbr) nbr, sum(ventes) ventes, round(sum(ht * coef), 2) ttc, max(synced_at) maj from l group by r)
  select case when exists (select 1 from v) then json_build_object(
    'maj', (select max(maj) from v),
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
    'exclus_nb', (select sum(ventes) from v where r in ('acompte', 'cadeau')),
    'tva_source', case when exists (select 1 from tva_categorie) then 'caisse' else 'defaut' end
  ) end
$$;
revoke all on function public.caisse_jour(date) from public, anon, authenticated;

select (select count(*) from public.tva_categorie) as categories_tva, public.caisse_jour((now() at time zone 'Europe/Paris')::date) as caisse_du_jour;
