-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v20 : direct du jour, alertes de réservation, privatisations.
--   · privatisations (+ privatisations_paiement, montants réservés direction/responsables) :
--     saisies dans l'espace équipe, et créées / mises à jour par le webhook Qweekle quand une
--     réservation porte « privatisation » dans son libellé.
--   · produit_famille : produit de caisse → famille (snack, boutique, …), publié par publish_kpis.py
--     depuis l'export caisse ; sert à ranger les lignes des factures reçues en direct.
--   · live_jour(jour) : chiffres du jour en direct (réservations, ventes, snacking, boutique, cartes).
--     L'équipe ne reçoit que des volumes ; les montants en € seulement pour direction et responsables.
--   · resa_nouvelles() : dernières réservations enregistrées (fil des alertes).
--   · live_ping + temps réel Supabase : l'espace équipe se met à jour tout seul et sonne à chaque
--     nouvelle réservation (anniversaire, centre, école, privatisation).
-- À exécuter après schema_v19.sql (Supabase › SQL Editor › Run). Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── Privatisations ──
create table if not exists public.privatisations (
  id bigint generated always as identity primary key,
  date date not null,
  heure_debut time not null default '18:00',
  heure_fin time not null default '21:00',
  client text not null default '',
  societe text default '',
  contact_tel text default '',
  contact_email text default '',
  type text not null default 'particulier' check (type in ('particulier','entreprise','association','ecole','autre')),
  occasion text default '',
  nb_enfants int,
  nb_adultes int,
  espaces text default 'Parc entier',
  formule text default '',
  options text default '',
  traiteur text default '',
  allergies text default '',
  notes text default '',
  responsable uuid references public.profiles on delete set null,
  equipe uuid[] not null default '{}',
  checklist jsonb not null default '[]',
  statut text not null default 'option' check (statut in ('demande','devis','option','confirme','termine','annule')),
  paiement text,
  qweekle_id text unique,
  qweekle_order text,
  webhook_at timestamptz,
  created_by uuid default auth.uid() references public.profiles on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists privatisations_date on public.privatisations (date);
alter table public.privatisations enable row level security;
drop policy if exists privat_select on public.privatisations;
create policy privat_select on public.privatisations for select using (public.is_member());
drop policy if exists privat_write on public.privatisations;
create policy privat_write on public.privatisations for all using (public.is_manager()) with check (public.is_manager());

create table if not exists public.privatisations_paiement (
  privatisation_id bigint primary key references public.privatisations on delete cascade,
  devis numeric,          -- montant du devis TTC
  total numeric,          -- montant final TTC
  acompte numeric,        -- déjà encaissé
  facture text default '',
  updated_at timestamptz not null default now()
);
alter table public.privatisations_paiement enable row level security;
drop policy if exists privpay_all on public.privatisations_paiement;
create policy privpay_all on public.privatisations_paiement for all using (public.is_manager()) with check (public.is_manager());

-- ── Signal « quelque chose a changé » pour le direct ──
create table if not exists public.live_ping (
  key text primary key,
  at timestamptz not null default now()
);
alter table public.live_ping enable row level security;
drop policy if exists live_ping_select on public.live_ping;
create policy live_ping_select on public.live_ping for select using (public.is_member());

create or replace function public.live_touch(k text) returns void
language sql security definer set search_path = public as $$
  insert into live_ping (key, at) values (k, now()) on conflict (key) do update set at = excluded.at;
$$;
revoke all on function public.live_touch(text) from public, anon, authenticated;

-- ── Produits de caisse → famille ──
create table if not exists public.produit_famille (
  nom text primary key,          -- nom du produit en minuscules, sans le préfixe [..]
  famille text not null,         -- snack, boutique, entrees, anniv, b2b, event, autre
  groupe text default '',
  updated_at timestamptz not null default now()
);
alter table public.produit_famille enable row level security;   -- aucune politique : lue par live_jour()

create or replace function public.famille_cat(cat text) returns text
language sql immutable as $$
  select case
    when cat is null or btrim(cat) = '' then null
    when lower(cat) like '%snack%' then 'snack'
    when lower(cat) like '%boutique%' then 'boutique'
    when lower(cat) like 'entrée au parc%' or lower(cat) like 'entree au parc%' then 'entrees'
    when lower(cat) like '%anniv%' then 'anniv'
    when lower(cat) ~ '(loisirs|scolaire|groupe|assistante|school)' then 'b2b'
    when lower(cat) ~ '(évèn|évén|evèn|even|atelier|privatisation|palo-bouh|palo-boom)' then 'event'
  end
$$;

-- Lignes d'une facture Qweekle (structure exacte encore inconnue : on essaie les formes courantes)
create or replace function public.qw_lignes(p jsonb)
returns table (label text, cat text, qty numeric, amount numeric)
language plpgsql immutable as $$
declare arr jsonb; l jsonb; q numeric;
begin
  for arr in
    select v from (values (p->'lines'), (p->'items'), (p->'invoice_lines'), (p->'products'), (p->'details'),
                          (p->'order_lines'), (p#>'{invoice,lines}'), (p#>'{data,lines}'), (p#>'{order,lines}'),
                          (p#>'{invoice,items}'), (p#>'{data,items}')) t(v)
     where jsonb_typeof(v) = 'array'
  loop
    for l in select * from jsonb_array_elements(arr) loop
      if jsonb_typeof(l) <> 'object' then continue; end if;
      q := coalesce(nullif(l->>'qty', '')::numeric, nullif(l->>'quantity', '')::numeric, 1);
      label := regexp_replace(btrim(coalesce(l->>'label', l->>'name', l->>'product_name', l#>>'{product,label}',
                                             l#>>'{product,name}', l->>'designation', '')), '^\[[^\]]*\]\s*', '');
      cat := coalesce(l->>'category', l#>>'{category,label}', l#>>'{category,name}', l->>'category_label',
                      l#>>'{product,category}', l#>>'{product,category,label}', l#>>'{product,category,name}', l->>'family');
      qty := q;
      amount := coalesce(nullif(l->>'amount', '')::numeric, nullif(l->>'total', '')::numeric,
                         nullif(l->>'amount_ttc', '')::numeric, nullif(l->>'total_ttc', '')::numeric,
                         nullif(l->>'amount_with_taxes', '')::numeric,
                         nullif(l->>'price_ttc', '')::numeric * q, nullif(l->>'unit_price', '')::numeric * q,
                         nullif(l->>'price', '')::numeric * q);
      return next;
    end loop;
    return;
  end loop;
exception when others then return;
end $$;

-- ── Chiffres du jour en direct ──
create or replace function public.live_jour(d date default null) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  jour date := coalesce(d, (now() at time zone 'Europe/Paris')::date);
  mgr boolean := public.is_manager();
  res json;
begin
  if not public.is_member() then return null; end if;
  with ventes as (
    select distinct on (coalesce(payload->>'id', id::text)) payload, received_at
      from qweekle_events
     where event_type = 'sale.created'
       and (coalesce((payload->>'created_at')::timestamptz, received_at) at time zone 'Europe/Paris')::date = jour
     order by coalesce(payload->>'id', id::text), received_at),
  inv as (
    select distinct on (coalesce(payload->>'id', id::text)) payload
      from qweekle_events
     where event_type = 'invoice.created'
       and (coalesce((payload->>'created_at')::timestamptz, received_at) at time zone 'Europe/Paris')::date = jour
     order by coalesce(payload->>'id', id::text), received_at),
  lignes as (
    select coalesce(public.famille_cat(l.cat), pf.famille, 'autre') as fam, l.label, l.qty, l.amount
      from inv, lateral public.qw_lignes(inv.payload) l
      left join produit_famille pf on pf.nom = lower(l.label)),
  famx as (
    select fam, sum(qty) art, round(sum(amount), 2) ttc from lignes group by fam),
  top as (
    select fam, label, sum(qty) q, round(sum(amount), 2) m,
           row_number() over (partition by fam order by sum(qty) desc, sum(amount) desc) rk
      from lignes where fam in ('snack', 'boutique') group by fam, label),
  heures as (
    select extract(hour from coalesce((payload->>'created_at')::timestamptz, received_at) at time zone 'Europe/Paris')::int h,
           count(*) n, round(sum((payload->>'amount')::numeric), 2) m
      from ventes group by 1)
  select json_build_object(
    'jour', jour,
    'maj', now(),
    'montants', mgr,
    'resa', json_build_object(
      'anniv', (select count(*) from anniversaires where date = jour and statut <> 'annule'),
      'anniv_enfants', (select coalesce(sum(nb_enfants), 0) from anniversaires where date = jour and statut <> 'annule'),
      'centre', (select count(*) from groupes where date = jour and type = 'centre' and statut <> 'annule'),
      'centre_enfants', (select coalesce(sum(nb_enfants), 0) from groupes where date = jour and type = 'centre' and statut <> 'annule'),
      'ecole', (select count(*) from groupes where date = jour and type = 'ecole' and statut <> 'annule'),
      'ecole_enfants', (select coalesce(sum(nb_enfants), 0) from groupes where date = jour and type = 'ecole' and statut <> 'annule'),
      'privat', (select count(*) from privatisations where date = jour and statut <> 'annule'),
      'privat_pers', (select coalesce(sum(coalesce(nb_enfants, 0) + coalesce(nb_adultes, 0)), 0) from privatisations where date = jour and statut <> 'annule')),
    'ventes', json_build_object(
      'nb', (select count(*) from ventes),
      'ttc', case when mgr then (select round(sum((payload->>'amount')::numeric), 2) from ventes) end,
      'derniere', (select max(received_at) from ventes)),
    'snack', json_build_object(
      'articles', (select art from famx where fam = 'snack'),
      'ttc', case when mgr then (select ttc from famx where fam = 'snack') end,
      'top', (select json_agg(json_build_object('label', label, 'q', q, 'm', case when mgr then m end) order by rk) from top where fam = 'snack' and rk <= 5)),
    'boutique', json_build_object(
      'articles', (select art from famx where fam = 'boutique'),
      'ttc', case when mgr then (select ttc from famx where fam = 'boutique') end,
      'top', (select json_agg(json_build_object('label', label, 'q', q, 'm', case when mgr then m end) order by rk) from top where fam = 'boutique' and rk <= 5)),
    'entrees', (select art from famx where fam = 'entrees'),
    'heures', (select json_agg(json_build_object('h', h, 'n', n, 'm', case when mgr then m end) order by h) from heures),
    'lignes_ok', exists (select 1 from lignes),
    'factures', (select count(*) from inv),
    'yavin', (select json_build_object('nb', y.nb, 'cb', case when mgr then y.cb_total end, 'maj', y.synced_at)
                from yavin_jour y where y.date = jour),
    'webhook_depuis', (select min(received_at) from qweekle_events where event_type in ('sale.created', 'invoice.created'))
  ) into res;
  return res;
end $$;
revoke all on function public.live_jour(date) from public, anon;
grant execute on function public.live_jour(date) to authenticated;

-- ── Dernières réservations enregistrées (fil des alertes) ──
create or replace function public.resa_nouvelles(n int default 30)
returns table (kind text, id bigint, date date, heure time, titre text, nb int, statut text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select * from (
    select 'anniv'::text, a.id, a.date, a.heure,
           'Anniversaire de ' || a.enfant || coalesce(' · ' || a.age || ' ans', ''), a.nb_enfants, a.statut, a.created_at
      from anniversaires a where a.created_at > now() - interval '14 days'
    union all
    select g.type, g.id, g.date, g.heure_arrivee, case g.type when 'ecole' then 'École · ' else 'Centre · ' end || g.structure,
           g.nb_enfants, g.statut, g.created_at
      from groupes g where g.created_at > now() - interval '14 days'
    union all
    select 'privat', p.id, p.date, p.heure_debut,
           'Privatisation · ' || coalesce(nullif(p.societe, ''), p.client) || coalesce(' · ' || nullif(p.occasion, ''), ''),
           coalesce(p.nb_enfants, 0) + coalesce(p.nb_adultes, 0), p.statut, p.created_at
      from privatisations p where p.created_at > now() - interval '14 days'
  ) x
  where public.is_member()
  order by created_at desc
  limit least(greatest(n, 1), 100)
$$;
grant execute on function public.resa_nouvelles(int) to authenticated;

-- ── Webhook Qweekle : privatisations + signal du direct (déclencheur, sans toucher à qweekle_event) ──
create or replace function public.qweekle_after_event() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  p jsonb := new.payload;
  low text := lower(coalesce(new.label, ''));
  gs text := new.payload->>'global_status';
  st timestamp; fin timestamp; cli text; v privatisations; stat text; pay text;
begin
  begin
    if new.event_type like 'booking.%' and low like '%privatis%' then
      st := (p->>'start_at')::timestamptz at time zone 'Europe/Paris';
      fin := coalesce((p->>'end_at')::timestamptz at time zone 'Europe/Paris', st + interval '3 hours');
      cli := trim(coalesce(nullif(p#>>'{client,society}', ''),
                              trim(coalesce(p#>>'{client,firstname}', '') || ' ' || coalesce(p#>>'{client,lastname}', ''))));
      pay := case gs when 'sold' then 'paye' when 'partially_paid' then 'acompte' when 'accepted' then 'non_paye' end;
      stat := case when gs = 'proposal' then case when p->>'source' = 'quote_order' then 'devis' else 'option' end else 'confirme' end;
      select * into v from privatisations where qweekle_order = new.order_id order by id limit 1;
      if new.event_type = 'booking.deleted' then
        if found then update privatisations set statut = 'annule', webhook_at = now(), updated_at = now() where id = v.id; end if;
      elsif found then
        update privatisations set date = st::date, heure_debut = st::time, heure_fin = fin::time,
          client = coalesce(nullif(cli, ''), privatisations.client),
          contact_tel = coalesce(nullif(p#>>'{client,phone}', ''), contact_tel),
          contact_email = coalesce(nullif(p#>>'{client,email}', ''), contact_email),
          nb_adultes = coalesce(nullif((p->>'qty')::numeric, 0)::int, nb_adultes),
          statut = case when statut in ('termine', 'annule') then statut else stat end,
          paiement = coalesce(pay, paiement), webhook_at = now(), updated_at = now()
         where id = v.id;
      else
        insert into privatisations (date, heure_debut, heure_fin, client, societe, contact_tel, contact_email, type,
                                    formule, nb_adultes, statut, paiement, qweekle_id, qweekle_order, webhook_at, created_by)
        values (st::date, st::time, fin::time, cli, coalesce(p#>>'{client,society}', ''),
                coalesce(p#>>'{client,phone}', ''), coalesce(p#>>'{client,email}', ''),
                case when coalesce(p#>>'{client,society}', '') <> '' then 'entreprise' else 'particulier' end,
                coalesce(new.label, ''), nullif((p->>'qty')::numeric, 0)::int, stat, pay,
                'wh-' || coalesce(new.order_id, p->>'id'), new.order_id, now(), null);
      end if;
    end if;
    perform public.live_touch('qweekle');
  exception when others then
    null;   -- ne jamais bloquer la réception du webhook
  end;
  return null;
end $$;
drop trigger if exists qweekle_after_event on public.qweekle_events;
create trigger qweekle_after_event after insert on public.qweekle_events
  for each row execute function public.qweekle_after_event();

create or replace function public.live_touch_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin perform public.live_touch(tg_table_name); return null; end $$;
drop trigger if exists yavin_live on public.yavin_jour;
create trigger yavin_live after insert or update on public.yavin_jour for each statement execute function public.live_touch_trg();

-- ── Temps réel Supabase ──
do $$
declare t text;
begin
  foreach t in array array['anniversaires', 'groupes', 'privatisations', 'live_ping'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

select (select count(*) from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public'
         and tablename in ('anniversaires', 'groupes', 'privatisations', 'live_ping')) as tables_temps_reel,
       public.famille_cat('Snacking') as test_famille;
