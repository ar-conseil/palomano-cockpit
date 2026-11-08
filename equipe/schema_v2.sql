-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v2 : anniversaires, centres de loisirs et écoles.
-- À exécuter après schema.sql (Supabase › SQL Editor › Run). Ré-exécutable.
-- Toute l'équipe consulte (pour préparer), responsable et direction modifient.
-- ═══════════════════════════════════════════════════════════════════════════

create table if not exists public.anniversaires (
  id bigint generated always as identity primary key,
  date date not null,
  heure time not null,
  duree_min int not null default 120,
  enfant text not null,
  age int,
  nb_enfants int,
  formule text default '',
  salle text default '',
  theme text default '',
  parent_nom text default '',
  parent_tel text default '',
  parent_email text default '',
  allergies text default '',
  notes text default '',
  montant numeric,
  acompte numeric default 0,
  statut text not null default 'confirme' check (statut in ('option','confirme','termine','annule')),
  animateur uuid references public.profiles on delete set null,
  created_by uuid default auth.uid() references public.profiles on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists anniversaires_date on public.anniversaires (date, heure);

create table if not exists public.groupes (
  id bigint generated always as identity primary key,
  type text not null check (type in ('centre','ecole')),
  structure text not null,
  ville text default '',
  niveau text default '',              -- classe (école) ou tranche d'âge (centre)
  date date not null,
  heure_arrivee time,
  heure_depart time,
  nb_enfants int,
  nb_encadrants int,
  formule text default '',
  contact_nom text default '',
  contact_tel text default '',
  contact_email text default '',
  montant numeric,
  statut text not null default 'confirme' check (statut in ('devis','option','confirme','termine','annule')),
  notes text default '',
  referent uuid references public.profiles on delete set null,
  created_by uuid default auth.uid() references public.profiles on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists groupes_date on public.groupes (type, date);

alter table public.anniversaires enable row level security;
alter table public.groupes enable row level security;
drop policy if exists anniv_select on public.anniversaires;
create policy anniv_select on public.anniversaires for select using (public.is_member());
drop policy if exists anniv_write on public.anniversaires;
create policy anniv_write on public.anniversaires for all using (public.is_manager()) with check (public.is_manager());
drop policy if exists groupes_select on public.groupes;
create policy groupes_select on public.groupes for select using (public.is_member());
drop policy if exists groupes_write on public.groupes;
create policy groupes_write on public.groupes for all using (public.is_manager()) with check (public.is_manager());

-- ───────────── Indicateurs réservés (objectifs chiffrés de la directrice) ─────────────
alter table public.kpi_feed add column if not exists restricted boolean not null default false;
drop policy if exists kpi_select on public.kpi_feed;
create policy kpi_select on public.kpi_feed for select
  using (public.is_member() and (not restricted or public.is_manager()));

-- ───────────── Pointage (heures réellement faites) ─────────────
alter table public.profiles add column if not exists contrat_h numeric;   -- heures hebdomadaires du contrat

create table if not exists public.pointages (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references public.profiles on delete cascade,
  start_at timestamptz not null default now(),
  end_at timestamptz,
  note text default '',
  corrected_by uuid references public.profiles on delete set null,
  created_at timestamptz not null default now(),
  check (end_at is null or end_at > start_at)
);
create index if not exists pointages_user on public.pointages (user_id, start_at desc);

-- Un salarié ne peut pointer qu'« à l'instant » : heure du serveur, pas d'antidate, une seule journée ouverte.
-- Les responsables et la direction peuvent corriger librement (traçé dans corrected_by).
create or replace function public.guard_pointage() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_manager() then
    if tg_op = 'UPDATE' or new.user_id <> auth.uid() then new.corrected_by := auth.uid(); end if;
    return new;
  end if;
  if not public.is_member() then raise exception 'Accès refusé'; end if;
  if tg_op = 'INSERT' then
    if exists (select 1 from pointages where user_id = auth.uid() and end_at is null) then
      raise exception 'Vous avez déjà commencé : pointez d''abord la fin';
    end if;
    new.user_id := auth.uid(); new.start_at := clock_timestamp(); new.end_at := null; new.corrected_by := null; new.kind := 'travail';
  else
    if old.user_id <> auth.uid() or old.end_at is not null then raise exception 'Seul un responsable peut corriger un pointage terminé'; end if;
    new.user_id := old.user_id; new.start_at := old.start_at; new.end_at := greatest(clock_timestamp(), old.start_at + interval '1 second'); new.corrected_by := null;
  end if;
  return new;
end $$;
drop trigger if exists guard_pointage on public.pointages;
create trigger guard_pointage before insert or update on public.pointages
  for each row execute function public.guard_pointage();

alter table public.pointages enable row level security;
drop policy if exists pt_select on public.pointages;
create policy pt_select on public.pointages for select using (user_id = auth.uid() or public.is_manager());
drop policy if exists pt_insert on public.pointages;
create policy pt_insert on public.pointages for insert with check (public.is_member());
drop policy if exists pt_update on public.pointages;
create policy pt_update on public.pointages for update using (user_id = auth.uid() or public.is_manager());
drop policy if exists pt_delete on public.pointages;
create policy pt_delete on public.pointages for delete using (public.is_manager());

-- ───────────── Invitations : adresses pré-autorisées par la direction ─────────────
-- Quand la personne crée son compte avec cette adresse, elle reçoit directement son rôle.
create table if not exists public.invitations (
  email text primary key,
  role text not null default 'equipe' check (role in ('direction','responsable','equipe')),
  poste text default '',
  contrat_h numeric,
  color text default '#c1daf3',
  created_by uuid default auth.uid() references public.profiles on delete set null,
  created_at timestamptz not null default now(),
  used_at timestamptz
);
alter table public.invitations enable row level security;
drop policy if exists inv_all on public.invitations;
create policy inv_all on public.invitations for all using (public.is_direction()) with check (public.is_direction());

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare inv invitations%rowtype;
begin
  select * into inv from invitations where lower(email) = lower(new.email) and used_at is null;
  insert into profiles (id, full_name, email, role, poste, contrat_h, color, can_validate_planning)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
          new.email,
          coalesce(inv.role, case when not exists (select 1 from profiles where role = 'direction') then 'direction' end),
          coalesce(inv.poste, ''), inv.contrat_h, coalesce(inv.color, '#c1daf3'), false)
  on conflict (id) do nothing;
  if inv.email is not null then update invitations set used_at = now() where email = inv.email; end if;
  return new;
end $$;

insert into public.invitations (email, role, poste, color) values
  ('yannika.zoa-tsama@palomano.com', 'responsable', 'Directrice', '#ef818e'),
  ('camille.pille@palomano.com', 'equipe', 'Groupes, écoles & privatisations', '#e1ebbd'),
  ('emma.digiovanni@palomano.com', 'equipe', 'Événements', '#f7d589')
on conflict (email) do nothing;

-- ───────────── Paie : type de contrat, apprentis, heures d'école ─────────────
alter table public.profiles add column if not exists apprenti boolean not null default false;
alter table public.profiles add column if not exists mineur boolean not null default false;
alter table public.profiles add column if not exists modulation boolean not null default false;
alter table public.invitations add column if not exists apprenti boolean not null default false;
alter table public.invitations add column if not exists mineur boolean not null default false;
-- « ecole » : heures de cours CFA / IUT d'une apprentie, saisies par un responsable (temps de travail, art. L6222-24)
alter table public.pointages add column if not exists kind text not null default 'travail';
do $$ begin
  alter table public.pointages add constraint pointages_kind check (kind in ('travail','ecole'));
exception when duplicate_object then null; end $$;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare inv invitations%rowtype;
begin
  select * into inv from invitations where lower(email) = lower(new.email) and used_at is null;
  insert into profiles (id, full_name, email, role, poste, contrat_h, color, apprenti, mineur, can_validate_planning)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
          new.email,
          coalesce(inv.role, case when not exists (select 1 from profiles where role = 'direction') then 'direction' end),
          coalesce(inv.poste, ''), inv.contrat_h, coalesce(inv.color, '#c1daf3'),
          coalesce(inv.apprenti, false), coalesce(inv.mineur, false), false)
  on conflict (id) do nothing;
  if inv.email is not null then update invitations set used_at = now() where email = inv.email; end if;
  return new;
end $$;

update public.invitations set apprenti = true where email in ('camille.pille@palomano.com','emma.digiovanni@palomano.com');
insert into public.invitations (email, role, poste, contrat_h, color) values
  ('yasminesizine320@gmail.com', 'equipe', 'CDD saisonnier', 17, '#c8d68e')
on conflict (email) do nothing;

-- ───────────── Invitation de l'associé (validateur du planning) ─────────────
alter table public.invitations add column if not exists can_validate_planning boolean not null default false;
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare inv invitations%rowtype;
begin
  select * into inv from invitations where lower(email) = lower(new.email) and used_at is null;
  insert into profiles (id, full_name, email, role, poste, contrat_h, color, apprenti, mineur, can_validate_planning)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
          new.email,
          coalesce(inv.role, case when not exists (select 1 from profiles where role = 'direction') then 'direction' end),
          coalesce(inv.poste, ''), inv.contrat_h, coalesce(inv.color, '#c1daf3'),
          coalesce(inv.apprenti, false), coalesce(inv.mineur, false),
          coalesce(inv.can_validate_planning and inv.role = 'direction', false))
  on conflict (id) do nothing;
  if inv.email is not null then update invitations set used_at = now() where email = inv.email; end if;
  return new;
end $$;
insert into public.invitations (email, role, poste, color, can_validate_planning) values
  ('alexandre.pelut@palomano.com', 'direction', 'Associé', '#8ab5d7', true)
on conflict (email) do update set role = 'direction', poste = 'Associé', can_validate_planning = true;
select email, role, poste, contrat_h, apprenti, can_validate_planning from public.invitations where used_at is null order by role, email;
