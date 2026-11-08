-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v8 : saisie des résultats du jour en ligne, option animateur des anniversaires.
-- Les chiffres saisis sur le site (page « Saisie du jour ») sont recopiés par sync_saisie.py
-- dans l'onglet du mois de « Objectifs Palomano Lille.xlsx » (mêmes colonnes que le tableau).
-- Accès : direction, responsables, et les personnes listées dans saisie_acces.
-- À exécuter après schema_v7.sql (Supabase › SQL Editor › Run). Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════

-- Personnes autorisées à saisir (en plus de la direction et des responsables)
create table if not exists public.saisie_acces (email text primary key);
insert into public.saisie_acces (email) values
  ('yannika.zoa-tsama@palomano.com'), ('camille.pille@palomano.com'), ('emma.digiovanni@palomano.com')
on conflict (email) do nothing;
alter table public.saisie_acces enable row level security;
drop policy if exists sa_all on public.saisie_acces;
create policy sa_all on public.saisie_acces for all using (public.is_direction()) with check (public.is_direction());

create or replace function public.can_saisie() returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_manager() or exists (
    select 1 from profiles p join saisie_acces a on lower(a.email) = lower(p.email)
    where p.id = auth.uid() and p.active and p.role is not null)
$$;

-- Une ligne par jour, colonnes du tableau mensuel (montants tels qu'en caisse)
create table if not exists public.saisie_jour (
  date date primary key,
  parc_ttc numeric, parc_nb int,                                   -- ENTRÉE PARC   (F, G)
  anniv_ttc numeric, anniv_entrees int, anniv_nb int,              -- ANNIVERSAIRE  (J, K, L)
  scolaire_ttc numeric, scolaire_nb int,                           -- SCOLAIRE      (O, P)
  groupe_ttc numeric, groupe_nb int,                               -- GROUPE/CENTRE (S, T)
  snack_ht numeric, snack_ttc numeric,                             -- SNACKING      (V, W)
  boutique_ht numeric, boutique_ttc numeric,                       -- BOUTIQUE      (Y, Z)
  event_ttc numeric,                                               -- ÉVÈNEMENT     (AC)
  note text default '',
  saisi_par uuid default auth.uid() references public.profiles on delete set null,
  updated_at timestamptz not null default now(),
  dirty boolean not null default true,     -- à recopier dans l'Excel
  synced_at timestamptz,
  sync_error text
);
alter table public.saisie_jour enable row level security;
drop policy if exists sj_select on public.saisie_jour;
create policy sj_select on public.saisie_jour for select using (public.can_saisie());
drop policy if exists sj_insert on public.saisie_jour;
create policy sj_insert on public.saisie_jour for insert with check (public.can_saisie());
drop policy if exists sj_update on public.saisie_jour;
create policy sj_update on public.saisie_jour for update using (public.can_saisie()) with check (public.can_saisie());
drop policy if exists sj_delete on public.saisie_jour;
create policy sj_delete on public.saisie_jour for delete using (public.is_direction());

-- État de la recopie dans l'Excel : visible des personnes qui saisissent
drop policy if exists sync_select on public.sync_state;
create policy sync_select on public.sync_state for select
  using (public.is_manager() or (key = 'qweekle' and public.is_member()) or (key = 'saisie' and public.can_saisie()));

-- Option « Animateur » des anniversaires (rempli par import_qweekle.py depuis l'export caisse)
alter table public.anniversaires add column if not exists option_animateur boolean not null default false;

select email from public.saisie_acces order by email;
