-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v31 : plus de personne en double au planning.
--   Cause (Emma, semaine du 9/11/2026) : avant la création de son compte, Emma avait une ligne provisoire
--   (« salarié · compte pas encore créé »). À la création du compte, ses services ont bien été rattachés au
--   compte ; mais des services ont ensuite été ajoutés sur l'ancienne ligne provisoire (page restée ouverte),
--   d'où deux lignes « Emma ».
--   · Désormais, un service posé sur une ligne provisoire dont la personne a un compte est rattaché au compte.
--   · Nettoyage : pour ces personnes, un service provisoire qui double un service du compte le même jour est
--     supprimé (les horaires saisis en dernier sont conservés) ; les autres sont rattachés au compte.
-- À exécuter après schema_v30.sql (Supabase › SQL Editor › Run). Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public.shift_vers_compte() returns trigger
language plpgsql security definer set search_path = public as $$
declare pid uuid;
begin
  if new.intervenant_id is not null then
    select p.id into pid from intervenants i join profiles p on lower(p.email) = lower(i.email)
     where i.id = new.intervenant_id and i.email is not null limit 1;
    if pid is not null then new.user_id := pid; new.intervenant_id := null; end if;
  end if;
  return new;
end $$;
drop trigger if exists shift_vers_compte on public.shifts;
create trigger shift_vers_compte before insert or update of intervenant_id on public.shifts
  for each row execute function public.shift_vers_compte();

-- Nettoyage des doublons existants
with paires as (
  select b.id as prov, a.id as compte, b.start_time, b.end_time
    from shifts b
    join intervenants i on i.id = b.intervenant_id and i.email is not null
    join profiles p on lower(p.email) = lower(i.email)
    join shifts a on a.user_id = p.id and a.day = b.day)
update shifts a set start_time = x.start_time, end_time = x.end_time
  from paires x
 where a.id = x.compte and x.prov > x.compte and (a.start_time, a.end_time) is distinct from (x.start_time, x.end_time);

delete from shifts b
 using intervenants i, profiles p
 where i.id = b.intervenant_id and i.email is not null and lower(p.email) = lower(i.email)
   and exists (select 1 from shifts a where a.user_id = p.id and a.day = b.day);

update shifts b set user_id = p.id, intervenant_id = null
  from intervenants i, profiles p
 where i.id = b.intervenant_id and i.email is not null and lower(p.email) = lower(i.email);

select (select count(*) from shifts b join intervenants i on i.id = b.intervenant_id join profiles p on lower(p.email) = lower(i.email)) as services_provisoires_restants,
       (select count(*) from shifts s join profiles p on p.id = s.user_id where p.full_name ilike 'emma%' and s.day >= current_date - 7) as services_emma_7_jours;
