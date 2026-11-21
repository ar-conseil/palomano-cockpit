-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v36 : type de service « Repos » au planning (jour de repos, 0 h comptée), 21/11/2026.
-- À exécuter après schema_v35.sql (Supabase › SQL Editor › Run). Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════
alter table public.shifts drop constraint if exists shifts_absence_check;
alter table public.shifts add constraint shifts_absence_check
  check (absence is null or absence in ('maladie', 'accident', 'enfant', 'formation', 'ferie', 'repos', 'autre'));

select conname, pg_get_constraintdef(oid) from pg_constraint where conname = 'shifts_absence_check';
