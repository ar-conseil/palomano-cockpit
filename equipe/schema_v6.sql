-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v6 : planning ouvert aux personnes sans compte.
--   · intérimaires (animateurs, staffeurs) : des lignes de planning sans compte ;
--   · salariés invités qui n'ont pas encore créé leur compte : ils apparaissent tout de suite
--     dans le planning ; à leur inscription, leurs services leur sont rattachés automatiquement.
-- À exécuter après schema_v5.sql (Supabase › SQL Editor › Run). Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════

create table if not exists public.intervenants (
  id uuid primary key default gen_random_uuid(),
  full_name text not null,
  type text not null default 'animateur' check (type in ('animateur','staffeur','salarie','autre')),
  agence text default '',
  email text,
  poste text default '',
  color text default '#c8d68e',
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index if not exists intervenants_email on public.intervenants (lower(email)) where email is not null;

alter table public.intervenants enable row level security;
drop policy if exists int_select on public.intervenants;
create policy int_select on public.intervenants for select using (public.is_member());
drop policy if exists int_write on public.intervenants;
create policy int_write on public.intervenants for all using (public.is_manager()) with check (public.is_manager());

-- Un service est pour un salarié (compte) OU pour un intervenant
alter table public.shifts alter column user_id drop not null;
alter table public.shifts add column if not exists intervenant_id uuid references public.intervenants on delete cascade;
alter table public.shifts drop constraint if exists shifts_qui;
alter table public.shifts add constraint shifts_qui check (num_nonnulls(user_id, intervenant_id) = 1);

-- Chaque invitation crée sa ligne de planning (tant que la personne n'a pas de compte)
create or replace function public.invitation_to_planning() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.used_at is null and not exists (select 1 from profiles where lower(email) = lower(new.email)) then
    insert into intervenants (full_name, type, email, poste, color)
    values (initcap(replace(replace(split_part(new.email, '@', 1), '.', ' '), '_', ' ')), 'salarie',
            lower(new.email), coalesce(new.poste, ''), coalesce(new.color, '#c1daf3'))
    on conflict (lower(email)) where email is not null do nothing;
  end if;
  return new;
end $$;
drop trigger if exists invitation_to_planning on public.invitations;
create trigger invitation_to_planning after insert on public.invitations
  for each row execute function public.invitation_to_planning();

-- À l'inscription : les services prévus sont rattachés au nouveau compte, la ligne provisoire disparaît
create or replace function public.claim_planning() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update shifts set user_id = new.id, intervenant_id = null
   where intervenant_id in (select id from intervenants where type = 'salarie' and lower(email) = lower(new.email));
  update intervenants set active = false where type = 'salarie' and lower(email) = lower(new.email);
  return new;
end $$;
drop trigger if exists claim_planning on public.profiles;
create trigger claim_planning after insert on public.profiles
  for each row execute function public.claim_planning();

-- Invitations déjà envoyées : lignes provisoires
insert into public.intervenants (full_name, type, email, poste, color)
select initcap(replace(replace(split_part(i.email, '@', 1), '.', ' '), '_', ' ')), 'salarie', lower(i.email), coalesce(i.poste, ''), coalesce(i.color, '#c1daf3')
  from public.invitations i
 where i.used_at is null and not exists (select 1 from public.profiles p where lower(p.email) = lower(i.email))
on conflict (lower(email)) where email is not null do nothing;
update public.intervenants set full_name = 'Yasmine Sizine' where lower(email) = 'yasminesizine320@gmail.com' and full_name ilike 'yasminesizine%';
update public.intervenants set full_name = 'Emma Di Giovanni' where lower(email) = 'emma.digiovanni@palomano.com' and full_name = 'Emma Digiovanni';

select full_name, type, email, poste from public.intervenants order by type, full_name;
