-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v18 : accès cachés (personnes qui testent l'application).
--   Une invitation « cachée » donne le rôle prévu, mais la personne n'apparaît nulle part dans les
--   listes de l'équipe : planning, heures, export paie, choix d'animateur. Pas de ligne provisoire au planning.
--   Premier accès caché : Oriane (oriane@palomano.com), rôle direction, pour tester.
-- À exécuter après schema_v17.sql (Supabase › SQL Editor › Run). Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════
alter table public.invitations add column if not exists hidden boolean not null default false;
alter table public.profiles add column if not exists hidden boolean not null default false;

-- À l'inscription : le profil hérite du caractère « caché » de son invitation
create or replace function public.profile_hidden() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from invitations where lower(email) = lower(new.email) and hidden) then new.hidden := true; end if;
  return new;
end $$;
drop trigger if exists profile_hidden on public.profiles;
create trigger profile_hidden before insert on public.profiles
  for each row execute function public.profile_hidden();

-- Une invitation cachée ne crée pas de ligne provisoire dans le planning
create or replace function public.invitation_to_planning() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.hidden then return new; end if;
  if new.used_at is null and not exists (select 1 from profiles where lower(email) = lower(new.email)) then
    insert into intervenants (full_name, type, email, poste, color)
    values (initcap(replace(replace(split_part(new.email, '@', 1), '.', ' '), '_', ' ')), 'salarie',
            lower(new.email), coalesce(new.poste, ''), coalesce(new.color, '#c1daf3'))
    on conflict (lower(email)) where email is not null do nothing;
  end if;
  return new;
end $$;

-- Oriane : accès direction caché, pour tester l'application
insert into public.invitations (email, role, poste, color, hidden)
values ('oriane@palomano.com', 'direction', 'Test de l''application (accès caché)', '#e5e3df', true)
on conflict (email) do update set role = excluded.role, poste = excluded.poste, hidden = true, used_at = null;
update public.profiles set hidden = true where lower(email) = 'oriane@palomano.com';

select email, role, hidden, used_at from public.invitations where email = 'oriane@palomano.com';
