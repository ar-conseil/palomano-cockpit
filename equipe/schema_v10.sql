-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v10 : pointage anti-triche et planning modifiable après validation.
--   1. Pointage sur place : on pointe avec le code de la borne (tablette à l'accueil), qui change
--      toutes les 30 secondes. Impossible de pointer depuis chez soi.
--   2. Corrections verrouillées : personne ne corrige ses propres heures ; seule la direction corrige
--      celles des responsables ; motif obligatoire ; chaque correction est historisée.
--   3. Heures hors planning : validées une à une par la direction (sinon non comptées dans l'export paie).
--   4. La direction peut modifier directement un planning validé.
-- À exécuter après schema_v9.sql (Supabase › SQL Editor › Run). Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════
create extension if not exists pgcrypto with schema extensions;

-- ───────────── 1. Bornes de pointage ─────────────
create table if not exists public.bornes (
  id uuid primary key default gen_random_uuid(),
  nom text not null default 'Accueil',
  key_hash text not null unique,
  secret text not null default encode(extensions.gen_random_bytes(32), 'hex'),
  active boolean not null default true,
  created_by uuid references public.profiles on delete set null,
  created_at timestamptz not null default now(),
  last_seen timestamptz
);
alter table public.bornes enable row level security;   -- aucune politique : accès uniquement par les fonctions ci-dessous

create or replace function public.borne_code_at(sec text, slot bigint) returns text
language sql immutable as $$
  select lpad(((('x' || substr(encode(extensions.hmac(slot::text, sec, 'sha256'), 'hex'), 1, 7))::bit(28)::int) % 1000000)::text, 6, '0')
$$;
revoke all on function public.borne_code_at(text, bigint) from public, anon, authenticated;

-- Activer une tablette (direction) : renvoie une clé unique, gardée sur la tablette
create or replace function public.borne_activer(p_nom text default 'Accueil') returns text
language plpgsql security definer set search_path = public as $$
declare k text := encode(extensions.gen_random_bytes(24), 'hex');
begin
  if not public.is_direction() then raise exception 'Seule la direction peut activer une borne'; end if;
  insert into bornes (nom, key_hash, created_by) values (coalesce(nullif(trim(p_nom), ''), 'Accueil'), encode(extensions.digest(k, 'sha256'), 'hex'), auth.uid());
  return k;
end $$;

-- Code affiché par la borne (appelé par la tablette, sans compte)
create or replace function public.borne_code(k text) returns json
language plpgsql security definer set search_path = public as $$
declare b bornes; slot bigint := floor(extract(epoch from clock_timestamp()) / 30);
begin
  select * into b from bornes where key_hash = encode(extensions.digest(k, 'sha256'), 'hex') and active;
  if not found then return json_build_object('ok', false); end if;
  update bornes set last_seen = now() where id = b.id;
  return json_build_object('ok', true, 'nom', b.nom, 'code', public.borne_code_at(b.secret, slot),
    'reste', 30 - (floor(extract(epoch from clock_timestamp()))::bigint % 30));
end $$;
grant execute on function public.borne_code(text) to anon, authenticated;

create or replace function public.bornes_liste() returns table (id uuid, nom text, active boolean, created_at timestamptz, last_seen timestamptz)
language sql security definer set search_path = public as $$
  select id, nom, active, created_at, last_seen from bornes where public.is_direction() order by created_at desc
$$;
create or replace function public.borne_revoquer(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_direction() then raise exception 'Accès refusé'; end if;
  update bornes set active = false where id = p_id;
end $$;

-- ───────────── 2. Pointage : colonnes, historique, règles ─────────────
alter table public.pointages add column if not exists hors_ok boolean not null default false;      -- heures hors planning validées
alter table public.pointages add column if not exists hors_ok_by uuid references public.profiles on delete set null;
alter table public.pointages add column if not exists via_borne boolean not null default false;

create table if not exists public.pointages_log (
  id bigint generated always as identity primary key,
  pointage_id bigint,
  user_id uuid references public.profiles on delete cascade,
  action text not null,                    -- ajout, correction, suppression, validation
  old_start timestamptz, old_end timestamptz, new_start timestamptz, new_end timestamptz,
  motif text default '',
  by_user uuid references public.profiles on delete set null,
  at timestamptz not null default now()
);
create index if not exists pointages_log_user on public.pointages_log (user_id, at desc);
alter table public.pointages_log enable row level security;
drop policy if exists ptlog_select on public.pointages_log;
create policy ptlog_select on public.pointages_log for select using (public.is_direction() or (public.is_manager() and by_user = auth.uid()));

create or replace function public.guard_pointage() returns trigger
language plpgsql security definer set search_path = public as $$
declare cible text; borne boolean := coalesce(current_setting('palo.borne', true), '') = '1';
begin
  if tg_op = 'DELETE' then
    if not public.is_direction() then raise exception 'Seule la direction peut supprimer un pointage'; end if;
    return old;
  end if;
  -- Pointage « à l'instant » par la borne (seul moyen pour l'équipe et les responsables de pointer pour soi)
  if borne then
    if tg_op = 'INSERT' then
      if exists (select 1 from pointages where user_id = auth.uid() and end_at is null) then raise exception 'Vous avez déjà commencé : pointez d''abord la fin'; end if;
      new.user_id := auth.uid(); new.start_at := clock_timestamp(); new.end_at := null; new.kind := 'travail'; new.via_borne := true;
    else
      if old.user_id <> auth.uid() or old.end_at is not null then raise exception 'Pointage introuvable'; end if;
      new.user_id := old.user_id; new.start_at := old.start_at; new.kind := old.kind; new.hors_ok := old.hors_ok;
      new.end_at := greatest(clock_timestamp(), old.start_at + interval '1 second');
    end if;
    new.corrected_by := null; new.hors_ok_by := null;
    return new;
  end if;
  -- Validation des heures hors planning : direction uniquement, rien d'autre ne change
  if tg_op = 'UPDATE' and new.hors_ok is distinct from old.hors_ok then
    if not public.is_direction() then raise exception 'Seule la direction valide les heures hors planning'; end if;
    if new.start_at is distinct from old.start_at or new.end_at is distinct from old.end_at or new.user_id <> old.user_id then
      raise exception 'Validez les heures sans modifier le pointage';
    end if;
    new.hors_ok_by := case when new.hors_ok then auth.uid() end;
    return new;
  end if;
  -- Correction (ajout ou modification hors borne)
  if not public.is_manager() then raise exception 'Pointez avec le code de la borne à l''accueil'; end if;
  if new.user_id = auth.uid() and not public.is_direction() then raise exception 'Vous ne pouvez pas corriger vos propres heures : demandez à la direction'; end if;
  select role into cible from profiles where id = new.user_id;
  if cible in ('responsable', 'direction') and not public.is_direction() then raise exception 'Seule la direction corrige les heures d''un responsable'; end if;
  if coalesce(trim(new.note), '') = '' then raise exception 'Indiquez le motif de la correction'; end if;
  if tg_op = 'UPDATE' then new.user_id := old.user_id; new.via_borne := old.via_borne; end if;
  new.corrected_by := auth.uid();
  return new;
end $$;
drop trigger if exists guard_pointage on public.pointages;
create trigger guard_pointage before insert or update or delete on public.pointages
  for each row execute function public.guard_pointage();

create or replace function public.log_pointage() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    insert into pointages_log (pointage_id, user_id, action, old_start, old_end, motif, by_user) values (old.id, old.user_id, 'suppression', old.start_at, old.end_at, '', auth.uid());
    return old;
  end if;
  if coalesce(current_setting('palo.borne', true), '') = '1' then return new; end if;   -- pointage normal : pas une correction
  if tg_op = 'UPDATE' and new.hors_ok is distinct from old.hors_ok then
    insert into pointages_log (pointage_id, user_id, action, new_start, new_end, motif, by_user)
    values (new.id, new.user_id, case when new.hors_ok then 'validation' else 'validation retirée' end, new.start_at, new.end_at, 'Heures hors planning', auth.uid());
    return new;
  end if;
  insert into pointages_log (pointage_id, user_id, action, old_start, old_end, new_start, new_end, motif, by_user)
  values (new.id, new.user_id, case when tg_op = 'INSERT' then 'ajout' else 'correction' end,
          case when tg_op = 'UPDATE' then old.start_at end, case when tg_op = 'UPDATE' then old.end_at end, new.start_at, new.end_at, new.note, auth.uid());
  return new;
end $$;
drop trigger if exists log_pointage on public.pointages;
create trigger log_pointage after insert or update or delete on public.pointages
  for each row execute function public.log_pointage();

-- Pointer avec le code de la borne (code en cours ou précédent : 30 à 60 s de validité)
create or replace function public.pointer(code text) returns json
language plpgsql security definer set search_path = public as $$
declare slot bigint := floor(extract(epoch from clock_timestamp()) / 30); ok boolean; r pointages;
begin
  if not public.is_member() then raise exception 'Accès refusé'; end if;
  select exists (select 1 from bornes where active and trim(code) in (public.borne_code_at(secret, slot), public.borne_code_at(secret, slot - 1))) into ok;
  if not ok then raise exception 'Code incorrect ou expiré : scannez le code affiché sur la borne de l''accueil'; end if;
  perform set_config('palo.borne', '1', true);
  update pointages set end_at = clock_timestamp() where user_id = auth.uid() and end_at is null returning * into r;
  if found then return json_build_object('action', 'fin', 'start_at', r.start_at, 'end_at', r.end_at); end if;
  insert into pointages (user_id) values (auth.uid()) returning * into r;
  return json_build_object('action', 'debut', 'start_at', r.start_at);
end $$;
grant execute on function public.pointer(text) to authenticated;

-- ───────────── 4. Planning validé modifiable par la direction ─────────────
create or replace function public.planning_editable(w date) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_manager() and coalesce((select status in ('brouillon','refuse') or (status = 'valide' and public.is_direction()) from plannings where week_start = w), true)
$$;

select (select count(*) from public.bornes) as bornes, (select count(*) from public.pointages) as pointages;
