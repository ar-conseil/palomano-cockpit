-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v12 : réservations Qweekle en direct (webhooks).
--   Qweekle envoie chaque réservation créée / modifiée / supprimée à la fonction Supabase
--   « qweekle-webhook », qui appelle qweekle_event() ci-dessous : l'anniversaire, le centre
--   ou l'école apparaît (ou bouge, ou passe en annulé) dans l'espace équipe à la seconde.
--   L'export Qweekle déposé dans SharePoint reste un filet de sécurité (import_qweekle.py).
--   Sécurité : l'adresse du webhook contient une clé secrète, créée par la direction dans
--   Réglages › Webhook Qweekle ; seule son empreinte est gardée ici.
-- À exécuter après schema_v11.sql (Supabase › SQL Editor › Run). Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════
create extension if not exists pgcrypto with schema extensions;

alter table public.anniversaires add column if not exists qweekle_order text;
alter table public.anniversaires add column if not exists webhook_at timestamptz;
alter table public.groupes add column if not exists qweekle_order text;
alter table public.groupes add column if not exists webhook_at timestamptz;
create index if not exists anniversaires_qorder on public.anniversaires (qweekle_order);
create index if not exists groupes_qorder on public.groupes (qweekle_order);

-- ───────────── Clé du webhook ─────────────
create table if not exists public.webhook_keys (
  id uuid primary key default gen_random_uuid(),
  key_hash text not null unique,
  active boolean not null default true,
  created_by uuid references public.profiles on delete set null,
  created_at timestamptz not null default now(),
  last_seen timestamptz
);
alter table public.webhook_keys enable row level security;   -- aucune politique : fonctions uniquement

create or replace function public.webhook_creer() returns text
language plpgsql security definer set search_path = public as $$
declare k text := encode(extensions.gen_random_bytes(24), 'hex');
begin
  if not public.is_direction() then raise exception 'Seule la direction peut créer l''adresse du webhook'; end if;
  update webhook_keys set active = false where active;           -- une seule adresse valable à la fois
  insert into webhook_keys (key_hash, created_by) values (encode(extensions.digest(k, 'sha256'), 'hex'), auth.uid());
  return k;
end $$;

-- ───────────── Journal des événements reçus (30 jours, direction) ─────────────
create table if not exists public.qweekle_events (
  id bigint generated always as identity primary key,
  received_at timestamptz not null default now(),
  event_type text, order_id text, label text, result text,
  payload jsonb
);
create index if not exists qweekle_events_at on public.qweekle_events (received_at desc);
alter table public.qweekle_events enable row level security;
drop policy if exists qev_select on public.qweekle_events;
create policy qev_select on public.qweekle_events for select using (public.is_direction());

create or replace function public.webhook_etat() returns json
language sql security definer set search_path = public as $$
  select case when public.is_direction() then json_build_object(
    'cree', (select max(created_at) from webhook_keys where active),
    'vu', (select max(last_seen) from webhook_keys where active),
    'jour', (select count(*) from qweekle_events where received_at > now() - interval '24 hours'),
    'erreurs', (select count(*) from qweekle_events where received_at > now() - interval '24 hours' and result like 'erreur%'))
  end
$$;

-- « Alia-Thorey Perrine » et « Perrine ALIA THOREY » → même clé
create or replace function public.nom_cle(t text) returns text
language sql immutable as $$
  select coalesce(string_agg(distinct w, ' ' order by w), '')
    from regexp_split_to_table(lower(translate(coalesce(t, ''),
         'ÀÂÄÁÃÇÉÈÊËÍÌÎÏÑÓÒÔÖÕÚÙÛÜÝàâäáãçéèêëíìîïñóòôöõúùûüýÿ',
         'AAAAACEEEEIIIINOOOOOUUUUYaaaaaceeeeiiiinooooouuuuyy')), '[^a-z]+') w
   where length(w) > 1
$$;

-- ───────────── Traitement d'un événement Qweekle ─────────────
create or replace function public.qweekle_event(k text, p jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare
  et text := p->>'event_type';
  lab text := coalesce(p->>'label', '');
  low text := lower(coalesce(p->>'label', ''));
  ord text := p->>'order_id';
  gs text := p->>'global_status';
  kind text; st timestamp; client text; qty int; pay text; stat text; res text;
  a anniversaires; g groupes; found_row boolean := false;
begin
  update webhook_keys set last_seen = now()
   where active and key_hash = encode(extensions.digest(coalesce(k, ''), 'sha256'), 'hex');
  if not found then raise exception 'clé de webhook invalide'; end if;

  kind := case when low like '%anniversaire%' then 'anniv'
               when low like 'scolaire%' then 'ecole'
               when low like 'accueil de loisirs%' or low like 'groupe%' then 'centre' end;
  if et is null or et not like 'booking.%' then
    res := 'ignoré (' || coalesce(et, '?') || ')';
  elsif kind is null then
    res := 'ignoré (entrée individuelle)';
  else
    st := (p->>'start_at')::timestamptz at time zone 'Europe/Paris';
    client := trim(coalesce(nullif(p#>>'{client,society}', ''),
                            trim(coalesce(p#>>'{client,lastname}', '') || ' ' || coalesce(p#>>'{client,firstname}', ''))));
    qty := coalesce((p->>'qty')::numeric, 0)::int;
    pay := case gs when 'sold' then 'paye' when 'partially_paid' then 'acompte' when 'accepted' then 'non_paye'
                   when 'proposal' then 'option' end;
    stat := case when gs = 'proposal' then case when kind <> 'anniv' and p->>'source' = 'quote_order' then 'devis' else 'option' end
                 else 'confirme' end;
    if st::date < (now() at time zone 'Europe/Paris')::date and stat = 'confirme' then stat := 'termine'; end if;

    if kind = 'anniv' then
      select * into a from anniversaires where qweekle_order = ord order by id limit 1;
      found_row := found;
      if not found_row then
        select * into a from anniversaires
         where date = st::date and nom_cle(parent_nom) = nom_cle(client) and statut <> 'annule'
         order by abs(extract(epoch from (heure - st::time))) limit 1;
        found_row := found;
      end if;
      if et = 'booking.deleted' then
        if found_row and low like 'anniversaire%' then
          update anniversaires set statut = 'annule', webhook_at = now(), qweekle_sync_at = now(), updated_at = now() where id = a.id;
          res := 'anniversaire annulé';
        else res := 'suppression ignorée'; end if;
      elsif found_row then
        update anniversaires set
          qweekle_order = ord,
          date = st::date,
          heure = case when low like 'anniversaire%' or a.qweekle_order is null then st::time else heure end,
          nb_enfants = case when qty > 0 then greatest(qty, case when a.qweekle_order = ord then coalesce(nb_enfants, 0) else 0 end) else nb_enfants end,
          formule = case when low like 'anniversaire%' then (upper(left(trim(substr(lab, 13)), 1)) || lower(substr(trim(substr(lab, 13)), 2))) else formule end,
          parent_nom = coalesce(nullif(client, ''), parent_nom),
          parent_tel = coalesce(nullif(p#>>'{client,phone}', ''), parent_tel),
          parent_email = coalesce(nullif(p#>>'{client,email}', ''), parent_email),
          statut = case when statut = 'termine' then statut else stat end,
          paiement = coalesce(pay, paiement),
          webhook_at = now(), qweekle_sync_at = now(), updated_at = now()
         where id = a.id;
        res := 'anniversaire mis à jour';
      else
        insert into anniversaires (enfant, date, heure, nb_enfants, formule, parent_nom, parent_tel, parent_email,
                                   statut, paiement, qweekle_id, qweekle_order, webhook_at, qweekle_sync_at)
        values ('Enfant de ' || client, st::date, st::time, nullif(qty, 0),
                case when low like 'anniversaire%' then (upper(left(trim(substr(lab, 13)), 1)) || lower(substr(trim(substr(lab, 13)), 2))) else '' end,
                client, coalesce(p#>>'{client,phone}', ''), coalesce(p#>>'{client,email}', ''),
                stat, pay, 'wh-' || ord, ord, now(), now());
        res := 'anniversaire ajouté';
      end if;
    else
      select * into g from groupes where qweekle_order = ord order by id limit 1;
      found_row := found;
      if not found_row then
        select * into g from groupes
         where date = st::date and type = kind and nom_cle(structure) = nom_cle(client) and statut <> 'annule' limit 1;
        found_row := found;
      end if;
      if et = 'booking.deleted' then
        if found_row then
          update groupes set statut = 'annule', webhook_at = now(), qweekle_sync_at = now(), updated_at = now() where id = g.id;
          res := 'groupe annulé';
        else res := 'suppression ignorée'; end if;
      elsif found_row then
        update groupes set
          qweekle_order = ord, date = st::date,
          heure_arrivee = least(coalesce(case when g.qweekle_order = ord then heure_arrivee end, st::time), st::time),
          nb_enfants = case when low like '%adulte%' or qty = 0 then nb_enfants else qty end,
          nb_encadrants = case when low like '%adulte%' and qty > 0 then qty else nb_encadrants end,
          contact_tel = coalesce(nullif(p#>>'{client,phone}', ''), contact_tel),
          contact_email = coalesce(nullif(p#>>'{client,email}', ''), contact_email),
          statut = case when statut = 'termine' then statut else stat end,
          paiement = coalesce(pay, paiement),
          webhook_at = now(), qweekle_sync_at = now(), updated_at = now()
         where id = g.id;
        res := 'groupe mis à jour';
      else
        insert into groupes (type, structure, date, heure_arrivee, nb_enfants, nb_encadrants, contact_nom, contact_tel,
                             contact_email, statut, paiement, niveau, qweekle_id, qweekle_order, webhook_at, qweekle_sync_at)
        values (kind, client, st::date, st::time,
                case when low like '%adulte%' then null else nullif(qty, 0) end,
                case when low like '%adulte%' then nullif(qty, 0) end,
                client, coalesce(p#>>'{client,phone}', ''), coalesce(p#>>'{client,email}', ''),
                stat, pay, case when low like 'groupe%' then 'Groupe' else '' end, 'wh-' || ord, ord, now(), now());
        res := 'groupe ajouté';
      end if;
    end if;
  end if;

  insert into qweekle_events (event_type, order_id, label, result, payload) values (et, ord, lab, res, p);
  delete from qweekle_events where received_at < now() - interval '30 days';
  insert into sync_state (key, ok, message, synced_at)
  values ('qweekle_webhook', true, 'dernier événement : ' || coalesce(et, '?') || ' · ' || res, now())
  on conflict (key) do update set ok = excluded.ok, message = excluded.message, synced_at = excluded.synced_at;
  return res;
exception when others then
  if sqlerrm = 'clé de webhook invalide' then raise; end if;
  insert into qweekle_events (event_type, order_id, label, result, payload) values (et, ord, lab, 'erreur : ' || sqlerrm, p);
  return 'erreur : ' || sqlerrm;
end $$;
revoke all on function public.qweekle_event(text, jsonb) from public, anon, authenticated;
grant execute on function public.qweekle_event(text, jsonb) to service_role;

select (select count(*) from public.webhook_keys) as cles, (select count(*) from public.qweekle_events) as evenements;
