-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v19 : accès au dashboard financier (/pilotage) depuis l'espace équipe,
-- réservé à la direction, sans partager le mot de passe.
--   · pilotage_cle : clé de déchiffrement du dashboard (dérivée du mot de passe), écrite par
--     encrypt_page.py à chaque actualisation. Aucune politique : lisible seulement via pilotage_acces().
--   · pilotage_acces() : renvoie la clé à un membre de la direction (et note l'ouverture dans le journal).
-- À exécuter après schema_v18.sql (Supabase › SQL Editor › Run). Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════
create table if not exists public.pilotage_cle (
  id int primary key default 1 check (id = 1),
  salt text not null,
  cle text not null,
  updated_at timestamptz not null default now()
);
alter table public.pilotage_cle enable row level security;

create table if not exists public.pilotage_acces_log (
  id bigint generated always as identity primary key,
  user_id uuid references public.profiles on delete set null,
  at timestamptz not null default now()
);
alter table public.pilotage_acces_log enable row level security;
drop policy if exists pal_select on public.pilotage_acces_log;
create policy pal_select on public.pilotage_acces_log for select using (public.is_direction());

create or replace function public.pilotage_acces() returns json
language plpgsql security definer set search_path = public as $$
declare k pilotage_cle;
begin
  if not public.is_direction() then raise exception 'Accès réservé à la direction'; end if;
  select * into k from pilotage_cle where id = 1;
  if not found then raise exception 'Clé du dashboard pas encore publiée : attendez la prochaine actualisation'; end if;
  insert into pilotage_acces_log (user_id) values (auth.uid());
  return json_build_object('salt', k.salt, 'cle', k.cle);
end $$;
revoke all on function public.pilotage_acces() from public, anon;
grant execute on function public.pilotage_acces() to authenticated;

select count(*) as cle_publiee from public.pilotage_cle;
