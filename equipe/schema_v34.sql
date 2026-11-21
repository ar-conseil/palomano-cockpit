-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v34 : compteur d'heures (heures sup. à récupérer / heures à rattraper), 21/11/2026.
-- Le compteur est calculé dans l'onglet Heures (semaines terminées : heures faites − contrat).
-- Cette table garde les mouvements saisis par la direction : solde de départ, heures payées,
-- récupération accordée, correction. Visible et modifiable par la direction uniquement.
-- À exécuter après schema_v33.sql (Supabase › SQL Editor › Run). Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════
create table if not exists public.compteur_ajust (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles on delete cascade,
  day date not null default current_date,
  type text not null default 'correction' check (type in ('depart','paye','recup','correction')),
  heures numeric(6,2) not null check (heures <> 0),
  motif text not null default '',
  by_user uuid default auth.uid() references public.profiles,
  created_at timestamptz not null default now()
);
create index if not exists compteur_ajust_user on public.compteur_ajust (user_id, day);
alter table public.compteur_ajust enable row level security;
drop policy if exists ca_select on public.compteur_ajust;
create policy ca_select on public.compteur_ajust for select using (public.is_direction());
drop policy if exists ca_insert on public.compteur_ajust;
create policy ca_insert on public.compteur_ajust for insert with check (public.is_direction() and by_user = auth.uid());
drop policy if exists ca_delete on public.compteur_ajust;
create policy ca_delete on public.compteur_ajust for delete using (public.is_direction());
grant select, insert, delete on public.compteur_ajust to authenticated;

select count(*) as mouvements from public.compteur_ajust;
