-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v26 : réservations par créneau sans doubles comptages.
--   · Anniversaires : la ligne « Anniversaire formule… / goûter… » est un produit (mêmes enfants que
--     « Entrée Enfant Anniversaire ») : elle n'ajoute plus de personnes, elle signale la fête (« fete »).
--   · Réservations : une famille (ligne Enfant + ligne Adulte) compte pour une réservation, pas deux.
-- À exécuter après schema_v25.sql (Supabase › SQL Editor › Run). Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public.creneau_fam(label text) returns text
language sql immutable as $$
  select case
    when lower(label) like '%privatis%' then 'privat'
    when lower(label) like 'anniversaire%' then 'fete'
    when lower(label) like '%anniversaire%' then 'anniv'
    when lower(label) like 'scolaire%' then 'ecole'
    when lower(label) like 'accueil de loisirs%' or lower(label) like 'groupe%' then 'centre'
    when lower(label) like '%adulte%' or lower(label) like '%accompagn%' then 'adulte'
    when lower(label) ~ '(enfant|b[ée]b[ée]|baby|kid)' then 'enfant'
    else 'autre' end
$$;

create or replace function public.creneaux_jour(d date default null) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  jour date := coalesce(d, (now() at time zone 'Europe/Paris')::date);
  ex timestamptz := (select max(exported_at) from creneaux_export);
  res json;
begin
  if not public.is_member() then return null; end if;
  with neuf as (   -- réservations arrivées par webhook après le dernier export
    select heure, label, qty, coalesce(order_id, id) as ord from creneaux_live
     where date = jour and not supprime and (ex is null or cree_le > ex)),
  annule as (      -- réservations de l'export annulées depuis
    select heure, label, qty, coalesce(order_id, id) as ord from creneaux_live
     where date = jour and supprime and ex is not null and cree_le <= ex and maj > ex),
  l as (
    select heure, activite as label, nb from creneaux_export where date = jour
    union all select heure, label, qty from neuf
    union all select heure, label, -qty from annule),
  f as (select heure, public.creneau_fam(label) fam, greatest(sum(nb), 0) nb from l group by 1, 2),
  r as (
    select heure, sum(n) resas from (
      select heure, sum(resas) n from creneaux_export where date = jour group by heure
      union all select heure, count(distinct ord) from neuf group by heure
      union all select heure, -count(distinct ord) from annule group by heure) x group by heure),
  c as (
    select f.heure, coalesce(sum(f.nb) filter (where f.fam <> 'fete'), 0) nb,
           greatest(coalesce(max(r.resas), 0), 0) resas,
           json_object_agg(f.fam, f.nb) filter (where f.nb > 0) fams
      from f left join r on r.heure = f.heure
     group by f.heure having sum(f.nb) > 0)
  select json_build_object(
    'jour', jour, 'export', ex,
    'direct_depuis', (select min(cree_le) from creneaux_live),
    'personnes', (select coalesce(sum(nb), 0) from c),
    'resas', (select coalesce(sum(resas), 0) from c),
    'creneaux', (select coalesce(json_agg(json_build_object('h', to_char(heure, 'HH24:MI'), 'nb', nb, 'resas', resas, 'fams', fams) order by heure), '[]'::json) from c)
  ) into res;
  return res;
end $$;
revoke all on function public.creneaux_jour(date) from public, anon;
grant execute on function public.creneaux_jour(date) to authenticated;

select public.creneau_fam('Anniversaire formule unique') as formule, public.creneau_fam('Entrée Enfant Anniversaire') as entree_anniv;
