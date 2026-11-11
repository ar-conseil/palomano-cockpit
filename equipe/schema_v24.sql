-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v24 : réservations du jour par créneau, en direct.
--   · creneaux_export : réservations de l'export Qweekle regroupées par jour, créneau et activité
--     (toutes les activités, entrées individuelles comprises), réécrites à chaque import (import_qweekle.py).
--   · creneaux_live : chaque réservation reçue par webhook (booking.created / updated / deleted).
--   · creneaux_jour(jour) : les deux réunis — l'export, plus ce que les webhooks ont apporté depuis.
-- À exécuter après schema_v23.sql (Supabase › SQL Editor › Run). Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════
create table if not exists public.creneaux_export (
  date date not null,
  heure time not null,
  activite text not null,
  nb int not null default 0,        -- participants
  resas int not null default 0,     -- réservations (client + date de réservation)
  exported_at timestamptz not null,
  primary key (date, heure, activite)
);
alter table public.creneaux_export enable row level security;   -- lue par creneaux_jour()

create table if not exists public.creneaux_live (
  id text primary key,              -- n° de réservation Qweekle
  date date not null,
  heure time not null,
  label text not null default '',
  qty int not null default 0,
  order_id text,
  statut text,
  supprime boolean not null default false,
  cree_le timestamptz not null default now(),
  maj timestamptz not null default now()
);
create index if not exists creneaux_live_date on public.creneaux_live (date);
alter table public.creneaux_live enable row level security;

create or replace function public.creneau_fam(label text) returns text
language sql immutable as $$
  select case
    when lower(label) like '%privatis%' then 'privat'
    when lower(label) like '%anniversaire%' then 'anniv'
    when lower(label) like 'scolaire%' then 'ecole'
    when lower(label) like 'accueil de loisirs%' or lower(label) like 'groupe%' then 'centre'
    when lower(label) like '%adulte%' or lower(label) like '%accompagn%' then 'adulte'
    when lower(label) ~ '(enfant|b[ée]b[ée]|baby|kid)' then 'enfant'
    else 'autre' end
$$;

create or replace function public.creneau_from_event(et text, p jsonb, recu timestamptz) returns void
language plpgsql security definer set search_path = public as $$
declare st timestamp;
begin
  if et not like 'booking.%' or coalesce(p->>'id', '') = '' or coalesce(p->>'start_at', '') = '' then return; end if;
  st := (p->>'start_at')::timestamptz at time zone 'Europe/Paris';
  insert into creneaux_live (id, date, heure, label, qty, order_id, statut, supprime, cree_le, maj)
  values (p->>'id', st::date, st::time, coalesce(p->>'label', ''), coalesce((p->>'qty')::numeric, 0)::int, p->>'order_id',
          p->>'global_status', et = 'booking.deleted', coalesce((p->>'created_at')::timestamptz, recu), recu)
  on conflict (id) do update set date = excluded.date, heure = excluded.heure, label = excluded.label, qty = excluded.qty,
    order_id = excluded.order_id, statut = excluded.statut, supprime = excluded.supprime, maj = excluded.maj
  where creneaux_live.maj <= excluded.maj;
end $$;
revoke all on function public.creneau_from_event(text, jsonb, timestamptz) from public, anon, authenticated;

create or replace function public.qweekle_creneau_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  begin perform public.creneau_from_event(new.event_type, new.payload, new.received_at);
  exception when others then null; end;   -- ne jamais bloquer la réception du webhook
  return null;
end $$;
drop trigger if exists qweekle_creneau on public.qweekle_events;
create trigger qweekle_creneau after insert on public.qweekle_events
  for each row execute function public.qweekle_creneau_trg();

-- Reprise des réservations déjà reçues par webhook
do $$ declare e record; begin
  for e in select event_type, payload, received_at from qweekle_events where event_type like 'booking.%' order by received_at loop
    begin perform public.creneau_from_event(e.event_type, e.payload, e.received_at); exception when others then null; end;
  end loop;
end $$;

create or replace function public.creneaux_jour(d date default null) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  jour date := coalesce(d, (now() at time zone 'Europe/Paris')::date);
  ex timestamptz := (select max(exported_at) from creneaux_export);
  res json;
begin
  if not public.is_member() then return null; end if;
  with l as (
    select heure, activite as label, nb, resas from creneaux_export where date = jour
    union all   -- réservations arrivées par webhook après le dernier export
    select heure, label, qty, 1 from creneaux_live
     where date = jour and not supprime and (ex is null or cree_le > ex)
    union all   -- réservations de l'export annulées depuis
    select heure, label, -qty, -1 from creneaux_live
     where date = jour and supprime and ex is not null and cree_le <= ex and maj > ex),
  f as (
    select heure, public.creneau_fam(label) fam, greatest(sum(nb), 0) nb, greatest(sum(resas), 0) resas
      from l group by 1, 2),
  c as (
    select heure, sum(nb) nb, sum(resas) resas,
           json_object_agg(fam, nb) filter (where nb > 0) fams
      from f group by heure having sum(nb) > 0 or sum(resas) > 0)
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

select (select count(*) from public.creneaux_live) as reservations_webhook,
       (select count(distinct date) from public.creneaux_live) as jours,
       public.creneau_fam('Entrée Enfant (1-10 ans) Illimitée') as fam_enfant, public.creneau_fam('Entrée Adulte (11 ans +) Illimitée') as fam_adulte;
