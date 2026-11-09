-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v14 : télétravail (rare, prévu au planning).
--   · Un service du planning peut être marqué « Télétravail ».
--   · Pendant ce créneau (à 15 min près), et seulement si le planning de la semaine est VALIDÉ,
--     la personne pointe sans le code de la borne : pointer_distance(). Le pointage est marqué
--     « à distance ». En dehors, rien ne change : code de la borne obligatoire.
--   · Personne ne peut s'accorder du télétravail : le créneau doit figurer dans un planning validé.
-- À exécuter après schema_v13.sql (Supabase › SQL Editor › Run). Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════
alter table public.shifts add column if not exists teletravail boolean not null default false;
alter table public.pointages add column if not exists a_distance boolean not null default false;

-- Créneau de télétravail en cours pour la personne connectée (ou null)
create or replace function public.teletravail_maintenant() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('id', s.id, 'debut', s.start_time, 'fin', s.end_time)
    from shifts s join plannings p on p.week_start = s.week_start
   where s.user_id = auth.uid() and s.teletravail and p.status = 'valide'
     and s.day = (now() at time zone 'Europe/Paris')::date
     and (now() at time zone 'Europe/Paris')::time >= s.start_time - interval '15 minutes'
     and (now() at time zone 'Europe/Paris')::time <= s.end_time + interval '15 minutes'
   order by s.start_time limit 1
$$;
grant execute on function public.teletravail_maintenant() to authenticated;

-- Règles du pointage (v10) + pointage à distance
create or replace function public.guard_pointage() returns trigger
language plpgsql security definer set search_path = public as $$
declare cible text;
        borne boolean := coalesce(current_setting('palo.borne', true), '') = '1';
        distance boolean := coalesce(current_setting('palo.distance', true), '') = '1';
begin
  if tg_op = 'DELETE' then
    if not public.is_direction() then raise exception 'Seule la direction peut supprimer un pointage'; end if;
    return old;
  end if;
  -- Pointage « à l'instant » : borne de l'accueil, ou télétravail prévu au planning
  if borne then
    if tg_op = 'INSERT' then
      if exists (select 1 from pointages where user_id = auth.uid() and end_at is null) then raise exception 'Vous avez déjà commencé : pointez d''abord la fin'; end if;
      new.user_id := auth.uid(); new.start_at := clock_timestamp(); new.end_at := null; new.kind := 'travail';
      new.via_borne := not distance; new.a_distance := distance;
    else
      if old.user_id <> auth.uid() or old.end_at is not null then raise exception 'Pointage introuvable'; end if;
      new.user_id := old.user_id; new.start_at := old.start_at; new.kind := old.kind; new.hors_ok := old.hors_ok;
      new.via_borne := old.via_borne; new.a_distance := old.a_distance;
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
  if tg_op = 'UPDATE' then new.user_id := old.user_id; new.via_borne := old.via_borne; new.a_distance := old.a_distance;
  else new.a_distance := false; end if;
  new.corrected_by := auth.uid();
  return new;
end $$;

-- Pointer en télétravail (sans code), seulement pendant un créneau prévu au planning validé
create or replace function public.pointer_distance() returns json
language plpgsql security definer set search_path = public as $$
declare r pointages;
begin
  if not public.is_member() then raise exception 'Accès refusé'; end if;
  if public.teletravail_maintenant() is null then
    raise exception 'Pas de télétravail prévu au planning en ce moment : pointez avec le code de la borne de l''accueil';
  end if;
  perform set_config('palo.borne', '1', true);
  perform set_config('palo.distance', '1', true);
  update pointages set end_at = clock_timestamp() where user_id = auth.uid() and end_at is null returning * into r;
  if found then return json_build_object('action', 'fin', 'start_at', r.start_at, 'end_at', r.end_at); end if;
  insert into pointages (user_id) values (auth.uid()) returning * into r;
  return json_build_object('action', 'debut', 'start_at', r.start_at);
end $$;
grant execute on function public.pointer_distance() to authenticated;

select (select count(*) from public.shifts where teletravail) as creneaux_teletravail,
       (select count(*) from public.pointages where a_distance) as pointages_a_distance;
