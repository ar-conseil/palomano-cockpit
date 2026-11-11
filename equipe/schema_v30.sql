-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v30 : un anniversaire déplacé dans Qweekle ne repart plus à son ancienne date.
--   Cause (11/11/2026, commande Yeritsian) : Qweekle envoie deux lignes par anniversaire. Après un report,
--   la ligne « Entrée Enfant Anniversaire » portait encore l'ancien créneau (04/11) et la ligne
--   « Anniversaire formule unique » le nouveau (11/11) : la dernière reçue l'emportait.
--   Désormais seule la ligne « Anniversaire … » fixe la date et l'heure.
--   + réparation : chaque anniversaire reçu par webhook reprend le créneau de sa dernière ligne « Anniversaire … ».
-- À exécuter après schema_v29.sql (Supabase › SQL Editor › Run). Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════
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
          -- la date ne suit que la ligne « Anniversaire … » : la ligne « Entrée Enfant Anniversaire » garde parfois
          -- l'ancien créneau quand la fête a été déplacée, et renvoyait l'anniversaire à l'ancienne date
          date = case when low like 'anniversaire%' or a.qweekle_order is null then st::date else date end,
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

-- Réparation des anniversaires déjà décalés
with dern as (
  select distinct on (order_id) order_id,
         ((payload->>'start_at')::timestamptz at time zone 'Europe/Paris') st
    from qweekle_events
   where event_type in ('booking.created', 'booking.updated') and lower(label) like 'anniversaire%'
     and coalesce(payload->>'start_at', '') <> '' and order_id is not null
   order by order_id, received_at desc)
update anniversaires a set date = d.st::date, heure = d.st::time, updated_at = now()
  from dern d
 where a.qweekle_order = d.order_id and a.statut <> 'annule' and (a.date <> d.st::date or a.heure <> d.st::time);

select count(*) filter (where date = (now() at time zone 'Europe/Paris')::date) as anniversaires_aujourdhui,
       count(*) filter (where date = (now() at time zone 'Europe/Paris')::date - 1) as anniversaires_hier
  from anniversaires where statut <> 'annule';
