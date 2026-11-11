-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v25 : onglet « Mes chiffres » (direction et responsables).
--   chiffres_feed : CA HT du mois et de l'année par activité, comparé à l'an dernier, publié à chaque
--   actualisation par publish_kpis.py. Montants : lecture réservée à la direction et aux responsables.
-- À exécuter après schema_v24.sql (Supabase › SQL Editor › Run). Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════
create table if not exists public.chiffres_feed (
  key text primary key,
  data jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.chiffres_feed enable row level security;
drop policy if exists chiffres_select on public.chiffres_feed;
create policy chiffres_select on public.chiffres_feed for select using (public.is_manager());

select count(*) as lignes from public.chiffres_feed;
