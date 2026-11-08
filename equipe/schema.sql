-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe (Supabase / Postgres)
-- À coller une fois dans Supabase › SQL Editor › Run. Ré-exécutable sans risque.
--
-- Rôles : direction (tout, Alex valide le planning) · responsable (stocks, planning
-- brouillon, consignes) · equipe (consultation et saisies simples).
-- Un compte qui s'inscrit est « en attente » (rôle vide = aucun accès) jusqu'à ce
-- que la direction lui donne un rôle. Le tout premier compte devient direction.
-- Toutes les règles d'accès sont appliquées par la base (RLS), pas par la page.
-- ═══════════════════════════════════════════════════════════════════════════

-- ───────────── Profils & rôles ─────────────
create table if not exists public.profiles (
  id uuid primary key references auth.users on delete cascade,
  full_name text not null default '',
  email text,
  role text check (role in ('direction','responsable','equipe')),
  can_validate_planning boolean not null default false,
  poste text default '',
  color text default '#2a78d6',
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from profiles where id = auth.uid() and active
$$;
create or replace function public.is_member() returns boolean
language sql stable as $$ select public.my_role() is not null $$;
create or replace function public.is_manager() returns boolean
language sql stable as $$ select coalesce(public.my_role() in ('direction','responsable'), false) $$;
create or replace function public.is_direction() returns boolean
language sql stable as $$ select coalesce(public.my_role() = 'direction', false) $$;
create or replace function public.can_validate() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select can_validate_planning from profiles
                   where id = auth.uid() and active and role = 'direction'), false)
$$;

-- Création automatique du profil à l'inscription (le 1er compte = direction)
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, full_name, email, role, can_validate_planning)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
          new.email,
          case when not exists (select 1 from profiles where role = 'direction') then 'direction' end,
          false)
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Seule la direction change un rôle, l'activation ou le droit de valider
create or replace function public.guard_profile() returns trigger
language plpgsql as $$
begin
  if not public.is_direction() and auth.uid() is not null and
     (new.role is distinct from old.role or new.active is distinct from old.active
      or new.can_validate_planning is distinct from old.can_validate_planning) then
    raise exception 'Seule la direction peut modifier les rôles et les accès';
  end if;
  return new;
end $$;
drop trigger if exists guard_profile on public.profiles;
create trigger guard_profile before update on public.profiles
  for each row execute function public.guard_profile();

alter table public.profiles enable row level security;
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select
  using (id = auth.uid() or public.is_member());
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update
  using (id = auth.uid() or public.is_direction());
drop policy if exists profiles_delete on public.profiles;
create policy profiles_delete on public.profiles for delete using (public.is_direction());

-- ───────────── Stocks (jouets/boutique & snack) ─────────────
create table if not exists public.stock_items (
  id bigint generated always as identity primary key,
  kind text not null check (kind in ('jouets','snack')),
  name text not null,
  category text default '',
  unit text default 'pièce',
  min_qty numeric not null default 0,
  current_qty numeric not null default 0,
  active boolean not null default true,
  updated_at timestamptz not null default now()
);
create table if not exists public.stock_moves (
  id bigint generated always as identity primary key,
  item_id bigint not null references public.stock_items on delete cascade,
  move text not null check (move in ('comptage','entree','sortie','casse')),
  qty numeric not null check (qty >= 0),          -- quantité comptée (comptage) ou mouvement
  delta numeric,
  qty_after numeric,
  note text default '',
  user_id uuid default auth.uid() references public.profiles,
  created_at timestamptz not null default now()
);
create index if not exists stock_moves_item on public.stock_moves (item_id, created_at desc);

-- Chaque mouvement met le stock à jour (même pour l'équipe, qui ne modifie pas les articles)
create or replace function public.apply_stock_move() returns trigger
language plpgsql security definer set search_path = public as $$
declare cur numeric;
begin
  if not public.is_member() then raise exception 'Accès refusé'; end if;
  select current_qty into cur from stock_items where id = new.item_id for update;
  new.delta := case new.move when 'comptage' then new.qty - cur
                             when 'entree' then new.qty else -new.qty end;
  new.qty_after := cur + new.delta;
  new.user_id := auth.uid();
  update stock_items set current_qty = new.qty_after, updated_at = now() where id = new.item_id;
  return new;
end $$;
drop trigger if exists apply_stock_move on public.stock_moves;
create trigger apply_stock_move before insert on public.stock_moves
  for each row execute function public.apply_stock_move();

alter table public.stock_items enable row level security;
alter table public.stock_moves enable row level security;
drop policy if exists items_select on public.stock_items;
create policy items_select on public.stock_items for select using (public.is_member());
drop policy if exists items_write on public.stock_items;
create policy items_write on public.stock_items for all
  using (public.is_manager()) with check (public.is_manager());
drop policy if exists moves_select on public.stock_moves;
create policy moves_select on public.stock_moves for select using (public.is_member());
drop policy if exists moves_insert on public.stock_moves;
create policy moves_insert on public.stock_moves for insert with check (public.is_member());
drop policy if exists moves_delete on public.stock_moves;
create policy moves_delete on public.stock_moves for delete using (public.is_direction());

-- ───────────── Planning hebdomadaire avec validation ─────────────
create table if not exists public.plannings (
  week_start date primary key check (extract(isodow from week_start) = 1),
  status text not null default 'brouillon' check (status in ('brouillon','soumis','valide','refuse')),
  comment text default '',
  submitted_by uuid references public.profiles, submitted_at timestamptz,
  validated_by uuid references public.profiles, validated_at timestamptz,
  updated_at timestamptz not null default now()
);
create table if not exists public.shifts (
  id bigint generated always as identity primary key,
  week_start date not null references public.plannings on delete cascade,
  user_id uuid not null references public.profiles on delete cascade,
  day date not null,
  start_time time not null,
  end_time time not null,
  label text default '',
  check (day >= week_start and day < week_start + 7),
  check (end_time > start_time)
);
create index if not exists shifts_week on public.shifts (week_start, day);

create or replace function public.planning_editable(w date) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_manager() and coalesce((select status in ('brouillon','refuse') from plannings where week_start = w), true)
$$;

alter table public.plannings enable row level security;
alter table public.shifts enable row level security;
drop policy if exists plannings_select on public.plannings;
create policy plannings_select on public.plannings for select
  using (public.is_manager() or (public.is_member() and status = 'valide'));
drop policy if exists plannings_insert on public.plannings;
create policy plannings_insert on public.plannings for insert
  with check (public.is_manager() and status = 'brouillon');
-- (pas de politique UPDATE : les changements de statut passent par les fonctions ci-dessous)
drop policy if exists shifts_select on public.shifts;
create policy shifts_select on public.shifts for select
  using (public.is_manager() or (public.is_member() and exists
         (select 1 from plannings p where p.week_start = shifts.week_start and p.status = 'valide')));
drop policy if exists shifts_write on public.shifts;
create policy shifts_write on public.shifts for all
  using (public.planning_editable(week_start)) with check (public.planning_editable(week_start));

create or replace function public.submit_planning(w date) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_manager() then raise exception 'Accès refusé'; end if;
  update plannings set status = 'soumis', submitted_by = auth.uid(), submitted_at = now(), updated_at = now()
   where week_start = w and status in ('brouillon','refuse');
  if not found then raise exception 'Planning introuvable ou déjà soumis'; end if;
end $$;
create or replace function public.decide_planning(w date, ok boolean, note text default '') returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.can_validate() then raise exception 'Seul le validateur du planning (Alex) peut décider'; end if;
  update plannings set status = case when ok then 'valide' else 'refuse' end, comment = coalesce(note, ''),
         validated_by = auth.uid(), validated_at = now(), updated_at = now()
   where week_start = w and status = 'soumis';
  if not found then raise exception 'Ce planning n''est pas en attente de validation'; end if;
end $$;
create or replace function public.reopen_planning(w date) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_direction() then raise exception 'Accès refusé'; end if;
  update plannings set status = 'brouillon', updated_at = now() where week_start = w;
end $$;

-- ───────────── Checklists ouverture / fermeture ─────────────
create table if not exists public.checklist_items (
  id bigint generated always as identity primary key,
  moment text not null check (moment in ('ouverture','fermeture')),
  label text not null,
  position int not null default 0,
  active boolean not null default true
);
create table if not exists public.checklist_done (
  id bigint generated always as identity primary key,
  day date not null default current_date,
  item_id bigint not null references public.checklist_items on delete cascade,
  done_by uuid default auth.uid() references public.profiles,
  done_at timestamptz not null default now(),
  unique (day, item_id)
);
alter table public.checklist_items enable row level security;
alter table public.checklist_done enable row level security;
drop policy if exists cli_select on public.checklist_items;
create policy cli_select on public.checklist_items for select using (public.is_member());
drop policy if exists cli_write on public.checklist_items;
create policy cli_write on public.checklist_items for all using (public.is_manager()) with check (public.is_manager());
drop policy if exists cld_select on public.checklist_done;
create policy cld_select on public.checklist_done for select using (public.is_member());
drop policy if exists cld_insert on public.checklist_done;
create policy cld_insert on public.checklist_done for insert with check (public.is_member() and done_by = auth.uid());
drop policy if exists cld_delete on public.checklist_done;
create policy cld_delete on public.checklist_done for delete
  using ((done_by = auth.uid() and day = current_date) or public.is_manager());

-- ───────────── Consignes & transmissions ─────────────
create table if not exists public.posts (
  id bigint generated always as identity primary key,
  day date not null default current_date,
  title text not null,
  body text default '',
  important boolean not null default false,
  author uuid default auth.uid() references public.profiles,
  created_at timestamptz not null default now()
);
create table if not exists public.post_reads (
  post_id bigint references public.posts on delete cascade,
  user_id uuid default auth.uid() references public.profiles on delete cascade,
  read_at timestamptz not null default now(),
  primary key (post_id, user_id)
);
alter table public.posts enable row level security;
alter table public.post_reads enable row level security;
drop policy if exists posts_select on public.posts;
create policy posts_select on public.posts for select using (public.is_member());
drop policy if exists posts_insert on public.posts;
create policy posts_insert on public.posts for insert with check (public.is_manager() and author = auth.uid());
drop policy if exists posts_change on public.posts;
create policy posts_change on public.posts for update using (author = auth.uid() or public.is_direction());
drop policy if exists posts_delete on public.posts;
create policy posts_delete on public.posts for delete using (author = auth.uid() or public.is_direction());
drop policy if exists reads_select on public.post_reads;
create policy reads_select on public.post_reads for select using (user_id = auth.uid() or public.is_manager());
drop policy if exists reads_insert on public.post_reads;
create policy reads_insert on public.post_reads for insert with check (public.is_member() and user_id = auth.uid());

-- ───────────── Congés & absences ─────────────
create table if not exists public.leaves (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references public.profiles on delete cascade,
  start_date date not null,
  end_date date not null,
  kind text not null default 'conges' check (kind in ('conges','recup','absence','autre')),
  comment text default '',
  status text not null default 'en_attente' check (status in ('en_attente','acceptee','refusee')),
  decided_by uuid references public.profiles, decided_at timestamptz, decision_note text default '',
  created_at timestamptz not null default now(),
  check (end_date >= start_date)
);
alter table public.leaves enable row level security;
drop policy if exists leaves_select on public.leaves;
create policy leaves_select on public.leaves for select using (user_id = auth.uid() or public.is_manager());
drop policy if exists leaves_insert on public.leaves;
create policy leaves_insert on public.leaves for insert
  with check (public.is_member() and user_id = auth.uid() and status = 'en_attente');
drop policy if exists leaves_delete on public.leaves;
create policy leaves_delete on public.leaves for delete
  using ((user_id = auth.uid() and status = 'en_attente') or public.is_direction());
create or replace function public.decide_leave(lid bigint, ok boolean, note text default '') returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_direction() then raise exception 'Seule la direction valide les congés'; end if;
  update leaves set status = case when ok then 'acceptee' else 'refusee' end,
         decided_by = auth.uid(), decided_at = now(), decision_note = coalesce(note, '')
   where id = lid;
end $$;

-- ───────────── Incidents & maintenance ─────────────
create table if not exists public.incidents (
  id bigint generated always as identity primary key,
  title text not null,
  description text default '',
  location text default '',
  severity text not null default 'moyenne' check (severity in ('faible','moyenne','urgente')),
  status text not null default 'ouvert' check (status in ('ouvert','en_cours','resolu')),
  photo_path text,
  resolution text default '',
  reported_by uuid default auth.uid() references public.profiles,
  assigned_to uuid references public.profiles,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  resolved_at timestamptz
);
alter table public.incidents enable row level security;
drop policy if exists inc_select on public.incidents;
create policy inc_select on public.incidents for select using (public.is_member());
drop policy if exists inc_insert on public.incidents;
create policy inc_insert on public.incidents for insert
  with check (public.is_member() and reported_by = auth.uid() and status = 'ouvert');
drop policy if exists inc_update on public.incidents;
create policy inc_update on public.incidents for update
  using (public.is_manager() or assigned_to = auth.uid());
drop policy if exists inc_delete on public.incidents;
create policy inc_delete on public.incidents for delete using (public.is_direction());

-- Photos d'incidents (bucket privé)
insert into storage.buckets (id, name, public) values ('photos', 'photos', false)
  on conflict (id) do nothing;
drop policy if exists photos_read on storage.objects;
create policy photos_read on storage.objects for select
  using (bucket_id = 'photos' and public.is_member());
drop policy if exists photos_upload on storage.objects;
create policy photos_upload on storage.objects for insert
  with check (bucket_id = 'photos' and public.is_member());

-- ───────────── Objectifs ─────────────
-- kpi_feed : indicateurs publiés automatiquement par le dashboard (en % / volumes, pas de montants)
create table if not exists public.kpi_feed (
  key text primary key,
  label text not null,
  value numeric,
  target numeric,
  unit text default '',
  period text default '',
  updated_at timestamptz not null default now()
);
create table if not exists public.objectives (
  id bigint generated always as identity primary key,
  title text not null,
  description text default '',
  scope text not null default 'equipe' check (scope in ('equipe','individuel')),
  user_id uuid references public.profiles on delete cascade,
  unit text default '',
  target numeric,
  current numeric default 0,
  kpi_key text references public.kpi_feed,   -- si renseigné : valeur suivie automatiquement
  start_date date default current_date,
  end_date date,
  active boolean not null default true,
  created_by uuid default auth.uid() references public.profiles,
  updated_at timestamptz not null default now(),
  check (scope = 'equipe' or user_id is not null)
);
alter table public.kpi_feed enable row level security;
alter table public.objectives enable row level security;
drop policy if exists kpi_select on public.kpi_feed;
create policy kpi_select on public.kpi_feed for select using (public.is_member());
drop policy if exists obj_select on public.objectives;
create policy obj_select on public.objectives for select
  using (public.is_manager() or (public.is_member() and (scope = 'equipe' or user_id = auth.uid())));
drop policy if exists obj_write on public.objectives;
create policy obj_write on public.objectives for all using (public.is_manager()) with check (public.is_manager());

-- ───────────── Données de départ (modifiables dans l'onglet Réglages) ─────────────
insert into public.checklist_items (moment, label, position)
select * from (values
  ('ouverture','Tour de sécurité des structures et des univers',1),
  ('ouverture','Sols, toilettes et coin bébé propres',2),
  ('ouverture','Caisse ouverte et fond de caisse vérifié',3),
  ('ouverture','Snack : vitrine remplie, machines à café allumées',4),
  ('ouverture','Chaussettes et casiers prêts à l''accueil',5),
  ('ouverture','Salles anniversaires préparées (selon réservations)',6),
  ('fermeture','Ronde de fin : plus aucun enfant dans le parc',1),
  ('fermeture','Univers rangés, jouets remis en place',2),
  ('fermeture','Snack nettoyé, invendus notés, machines éteintes',3),
  ('fermeture','Caisse clôturée et comptée',4),
  ('fermeture','Poubelles sorties, lumières et chauffage coupés',5),
  ('fermeture','Alarme activée',6)
) v(moment, label, position)
where not exists (select 1 from public.checklist_items);

insert into public.kpi_feed (key, label, unit) values
  ('entrees_mois','Entrées du mois vs objectif','%'),
  ('ca_mois','Atteinte de l''objectif du mois','%'),
  ('snack_visiteur','Snack par visiteur','€'),
  ('anniv_mois','Anniversaires du mois','nb'),
  ('note_google','Note Google','note')
on conflict (key) do nothing;
