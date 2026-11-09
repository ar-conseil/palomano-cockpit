-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v16 : pause prévue sur chaque service du planning.
--   La pause (non payée) est déduite automatiquement des heures pointées pendant ce service,
--   sauf si elle a été pointée (calcul dans l'app : page Heures et export paie).
-- À exécuter après schema_v15.sql (Supabase › SQL Editor › Run). Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════
alter table public.shifts add column if not exists pause_min int not null default 0;
do $$ begin
  alter table public.shifts add constraint shifts_pause check (pause_min between 0 and 240);
exception when duplicate_object then null; end $$;

select count(*) as services, count(*) filter (where pause_min > 0) as avec_pause from public.shifts;
