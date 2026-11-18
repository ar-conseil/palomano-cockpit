-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v32 : fiche des anniversaires (demande de Yannika, 18/11/2026).
--   · Prénom et âge de l'enfant : Qweekle les envoie dans chaque réservation d'anniversaire
--     (subclients : prénom + date de naissance). Ils remplacent « Enfant de <parent> » ; un prénom
--     saisi à la main dans l'espace équipe n'est jamais écrasé.
--   · Heure du goûter : nouvelle colonne heure_gouter (facultative ; vide = au milieu de la fête).
--   · Durée d'un anniversaire : 2 h 30 (150 min) par défaut, et pour les fêtes à venir encore à 2 h.
-- À exécuter après schema_v31.sql (Supabase › SQL Editor › Run). Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════
alter table public.anniversaires add column if not exists heure_gouter time;
alter table public.anniversaires alter column duree_min set default 150;
update public.anniversaires set duree_min = 150 where duree_min = 120 and date >= current_date;

create or replace function public.anniv_enfant_depuis(p jsonb, ord text) returns void
language plpgsql security definer set search_path = public as $$
declare prenoms text; naiss date;
begin
  if ord is null or jsonb_typeof(p->'subclients') <> 'array' then return; end if;
  select string_agg(btrim(c->>'firstname'), ' & ' order by c->>'birthday_at'),
         min(((c->>'birthday_at')::timestamptz at time zone 'Europe/Paris')::date)
    into prenoms, naiss
    from jsonb_array_elements(p->'subclients') c
   where coalesce(c->>'type', 'children') = 'children' and btrim(coalesce(c->>'firstname', '')) <> '';
  if prenoms is null then return; end if;
  update anniversaires a
     set enfant = case when a.enfant ilike 'enfant de%' or btrim(coalesce(a.enfant, '')) = '' then prenoms else a.enfant end,
         age = case when naiss is not null and (a.age is null or a.enfant ilike 'enfant de%')
                    then extract(year from age(a.date, naiss))::int else a.age end,
         updated_at = now()
   where a.qweekle_order = ord and a.statut <> 'annule'
     and (a.enfant ilike 'enfant de%' or btrim(coalesce(a.enfant, '')) = '' or (a.age is null and naiss is not null));
end $$;
revoke all on function public.anniv_enfant_depuis(jsonb, text) from public, anon, authenticated;

create or replace function public.anniv_enfant_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.event_type like 'booking.%' then
    begin perform public.anniv_enfant_depuis(new.payload, new.order_id); exception when others then null; end;
  end if;
  return null;
end $$;
drop trigger if exists anniv_enfant on public.qweekle_events;
create trigger anniv_enfant after insert on public.qweekle_events
  for each row execute function public.anniv_enfant_trg();

-- Reprise des réservations déjà reçues
do $$ declare e record; begin
  for e in select distinct on (order_id) order_id, payload from qweekle_events
            where event_type like 'booking.%' and jsonb_typeof(payload->'subclients') = 'array'
              and jsonb_array_length(payload->'subclients') > 0
            order by order_id, received_at desc loop
    perform public.anniv_enfant_depuis(e.payload, e.order_id);
  end loop;
end $$;

select count(*) filter (where enfant not ilike 'enfant de%') as avec_prenom,
       count(*) filter (where enfant ilike 'enfant de%') as sans_prenom,
       count(age) as avec_age,
       count(*) filter (where duree_min = 150) as en_2h30
  from public.anniversaires where date >= current_date and statut <> 'annule';
