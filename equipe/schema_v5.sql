-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v5 : état de paiement des réservations Qweekle.
-- À exécuter après schema_v4.sql (Supabase › SQL Editor › Run). Ré-exécutable.
-- Rempli par import_qweekle.py depuis la colonne « Statut » de l'export :
--   sold → paye · partially_paid → acompte · accepted → non_paye · proposal → option
-- Pas de montant : l'export Qweekle n'en contient pas (et l'équipe n'en voit jamais).
-- ═══════════════════════════════════════════════════════════════════════════
alter table public.anniversaires add column if not exists paiement text;
alter table public.groupes add column if not exists paiement text;
do $$ begin
  alter table public.anniversaires add constraint anniversaires_paiement check (paiement in ('paye','acompte','non_paye','option'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.groupes add constraint groupes_paiement check (paiement in ('paye','acompte','non_paye','option'));
exception when duplicate_object then null; end $$;

select 'anniversaires' as t, paiement, count(*) from public.anniversaires group by paiement
union all select 'groupes', paiement, count(*) from public.groupes group by paiement order by 1, 2;
