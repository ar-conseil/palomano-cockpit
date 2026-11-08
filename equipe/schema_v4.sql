-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v4 : import automatique des réservations Qweekle.
-- À exécuter après schema_v3.sql (Supabase › SQL Editor › Run). Ré-exécutable.
--
-- import_qweekle.py (GitHub Actions, clé de service) recopie les réservations à venir
-- dans anniversaires et groupes. Chaque réservation importée porte une clé stable
-- (qweekle_id) : l'import met à jour la même ligne à chaque passage, sans jamais toucher
-- aux champs remplis par l'équipe (notes, salle, thème, animateur, référent).
-- Aucun montant n'est importé : l'équipe ne voit jamais de montants.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.anniversaires add column if not exists qweekle_id text;
alter table public.anniversaires add column if not exists qweekle_sync_at timestamptz;
alter table public.groupes add column if not exists qweekle_id text;
alter table public.groupes add column if not exists qweekle_sync_at timestamptz;
-- « Note en ligne » laissée par le client sur Qweekle (souvent allergies, prénom, thème) : distincte des notes de l'équipe
alter table public.anniversaires add column if not exists qweekle_note text default '';
alter table public.groupes add column if not exists qweekle_note text default '';

-- Clé d'upsert (les lignes saisies à la main gardent qweekle_id vide : plusieurs NULL sont permis)
do $$ begin
  alter table public.anniversaires add constraint anniversaires_qweekle_id unique (qweekle_id);
exception when duplicate_object or duplicate_table then null; end $$;
do $$ begin
  alter table public.groupes add constraint groupes_qweekle_id unique (qweekle_id);
exception when duplicate_object or duplicate_table then null; end $$;

-- La date du dernier import Qweekle est visible de toute l'équipe (les autres états restent réservés)
drop policy if exists sync_select on public.sync_state;
create policy sync_select on public.sync_state for select
  using (public.is_manager() or (key = 'qweekle' and public.is_member()));

select 'anniversaires' as t, count(*) filter (where qweekle_id is not null) as importees from public.anniversaires
union all select 'groupes', count(*) filter (where qweekle_id is not null) from public.groupes;
