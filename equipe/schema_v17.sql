-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v17 : bilan du jour pré-rempli et temps de fermeture.
--   · saisie_auto(jour) : chiffres proposés pour la saisie du jour — anniversaires, enfants, scolaires,
--     groupes (réservations), ventes encaissées dans Qweekle (webhook sale.created), cartes Yavin.
--   · yavin_jour : total des paiements carte du terminal Yavin par jour (rempli par sync_yavin.py).
--   · fermeture_preuves(du, au) : heure à laquelle chaque personne a validé la checklist de fermeture
--     ou le bilan du jour → son temps de fermeture après la fin du service est compté (1 h max, dans l'app).
-- À exécuter après schema_v16.sql (Supabase › SQL Editor › Run). Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════
create table if not exists public.yavin_jour (
  date date primary key,
  cb_total numeric,          -- paiements acceptés (montant + pourboire), en euros
  nb int,                    -- nombre de paiements acceptés
  rembourse numeric default 0,
  nb_refus int default 0,
  synced_at timestamptz not null default now()
);
alter table public.yavin_jour enable row level security;
drop policy if exists yavin_select on public.yavin_jour;
create policy yavin_select on public.yavin_jour for select using (public.can_saisie());

create or replace function public.saisie_auto(d date) returns json
language sql stable security definer set search_path = public as $$
  with ventes as (
    select distinct on (payload->>'id') payload
      from qweekle_events
     where event_type = 'sale.created'
       and ((payload->>'created_at')::timestamptz at time zone 'Europe/Paris')::date = d
     order by payload->>'id', received_at)
  select case when public.can_saisie() then json_build_object(
    'anniv_nb',      (select count(*) from anniversaires where date = d and statut <> 'annule'),
    'anniv_entrees', (select coalesce(sum(nb_enfants), 0) from anniversaires where date = d and statut <> 'annule'),
    'scolaire_nb',   (select coalesce(sum(nb_enfants), 0) from groupes where date = d and type = 'ecole' and statut <> 'annule'),
    'groupe_nb',     (select coalesce(sum(nb_enfants), 0) from groupes where date = d and type = 'centre' and statut <> 'annule'),
    'ventes_nb',     (select count(*) from ventes),
    'ventes_ttc',    (select round(sum((payload->>'amount')::numeric), 2) from ventes),
    'ventes_ht',     (select round(sum((payload->>'amount_ex_taxes')::numeric), 2) from ventes),
    'webhook_depuis',(select min(received_at) from qweekle_events where event_type = 'sale.created'),
    'yavin',         (select row_to_json(y) from yavin_jour y where y.date = d)
  ) end
$$;
grant execute on function public.saisie_auto(date) to authenticated;

create or replace function public.fermeture_preuves(du date, au date)
returns table (user_id uuid, day date, at timestamptz)
language sql stable security definer set search_path = public as $$
  select user_id, day, max(at) from (
    select c.done_by as user_id, c.day, c.done_at as at
      from checklist_done c join checklist_items i on i.id = c.item_id
     where i.moment = 'fermeture' and c.day between du and au and c.done_by is not null
    union all
    select s.saisi_par, s.date, s.updated_at from saisie_jour s
     where s.date between du and au and s.saisi_par is not null
  ) p
  where public.is_manager() and p.day is not null
  group by user_id, day
$$;
grant execute on function public.fermeture_preuves(date, date) to authenticated;

select public.saisie_auto(current_date) is not null as pret;
