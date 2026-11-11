-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v27 : absences au planning (arrêt maladie, accident du travail, enfant malade,
-- formation, jour férié chômé…). Un service marqué « absence » compte dans le total d'heures de la semaine,
-- mais n'est ni une présence au parc ni un créneau à pointer.
-- À exécuter après schema_v26.sql (Supabase › SQL Editor › Run). Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════
alter table public.shifts add column if not exists absence text
  check (absence is null or absence in ('maladie', 'accident', 'enfant', 'formation', 'ferie', 'autre'));

select count(*) as services, count(absence) as absences from public.shifts;
