-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v3 : facturation écoles & centres (synchronisée avec
-- l'Excel SharePoint « SUIVI FACTURATION ECOLES CENTRES ») et factures fournisseurs.
-- À exécuter après schema_v2.sql. Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════

-- ───────────── Factures écoles & centres (miroir de l'Excel) ─────────────
-- Une ligne = une facture (clé : n° de facture). Répartition reprise du mode d'emploi de l'Excel :
--   colonnes bleues (directrice) : date, organisme, n°, montant, commentaire, envoi mail, Chorus, relances, prochaine action
--   colonnes vertes (direction)  : statut, date d'encaissement, mode, libellé CIC, fiabilité
-- « dirty » = modifiée sur le site, à recopier dans l'Excel par la synchronisation.
create table if not exists public.factures_groupes (
  numero text primary key,
  annee int not null,
  excel_row int,
  date_facture date,
  organisme text not null default '',
  montant_ttc numeric,
  statut text default '',
  date_encaissement date,
  mode text default '',
  libelle_releve text default '',
  fiabilite text default '',
  commentaire text default '',
  envoi_mail text default '',
  depot_chorus text default '',
  relance1 date,
  relance2 date,
  prochaine_action text default '',
  dirty boolean not null default false,
  updated_by uuid references public.profiles on delete set null,
  updated_at timestamptz not null default now(),
  synced_at timestamptz
);
create index if not exists factures_groupes_annee on public.factures_groupes (annee, date_facture);

create or replace function public.guard_facture_groupe() returns trigger
language plpgsql as $$
begin
  if auth.uid() is null then return new; end if;        -- synchronisation (clé de service)
  if not public.is_manager() then raise exception 'Accès refusé'; end if;
  if not public.is_direction() and tg_op = 'UPDATE' and (
       new.statut is distinct from old.statut or new.date_encaissement is distinct from old.date_encaissement
    or new.mode is distinct from old.mode or new.libelle_releve is distinct from old.libelle_releve
    or new.fiabilite is distinct from old.fiabilite) then
    raise exception 'Le pointage des encaissements est réservé à la direction';
  end if;
  if tg_op = 'UPDATE' then new.excel_row := old.excel_row; end if;
  new.dirty := true; new.updated_by := auth.uid(); new.updated_at := now();
  return new;
end $$;
drop trigger if exists guard_facture_groupe on public.factures_groupes;
create trigger guard_facture_groupe before insert or update on public.factures_groupes
  for each row execute function public.guard_facture_groupe();

alter table public.factures_groupes enable row level security;
drop policy if exists fg_select on public.factures_groupes;
create policy fg_select on public.factures_groupes for select using (public.is_manager());
drop policy if exists fg_insert on public.factures_groupes;
create policy fg_insert on public.factures_groupes for insert with check (public.is_manager());
drop policy if exists fg_update on public.factures_groupes;
create policy fg_update on public.factures_groupes for update using (public.is_manager());

-- État de la synchronisation, affiché sur le site
create table if not exists public.sync_state (
  key text primary key,
  ok boolean,
  message text default '',
  synced_at timestamptz default now()
);
alter table public.sync_state enable row level security;
drop policy if exists sync_select on public.sync_state;
create policy sync_select on public.sync_state for select using (public.is_manager());

-- ───────────── Factures fournisseurs (animateurs, staffeurs, jouets…) ─────────────
create table if not exists public.factures_fournisseurs (
  id bigint generated always as identity primary key,
  categorie text not null default 'animation' check (categorie in ('animation','staffing','jouets','autre')),
  fournisseur text not null,
  numero text default '',
  date_facture date,
  periode text default '',            -- mois concerné (AAAA-MM)
  montant_ht numeric,
  montant_ttc numeric,
  echeance date,
  fichier_path text,
  notes text default '',
  statut text not null default 'a_payer' check (statut in ('a_payer','paye','refusee')),
  paye_le date,
  decision_note text default '',
  created_by uuid default auth.uid() references public.profiles on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create or replace function public.guard_facture_fournisseur() returns trigger
language plpgsql as $$
begin
  if not public.is_manager() then raise exception 'Accès refusé'; end if;
  if tg_op = 'INSERT' then new.created_by := auth.uid(); new.statut := 'a_payer'; new.paye_le := null; return new; end if;
  if not public.is_direction() then
    if old.statut <> 'a_payer' then raise exception 'Facture déjà traitée par la direction'; end if;
    if new.statut <> old.statut or new.paye_le is distinct from old.paye_le then
      raise exception 'Seule la direction marque une facture comme payée ou refusée';
    end if;
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists guard_facture_fournisseur on public.factures_fournisseurs;
create trigger guard_facture_fournisseur before insert or update on public.factures_fournisseurs
  for each row execute function public.guard_facture_fournisseur();

alter table public.factures_fournisseurs enable row level security;
drop policy if exists ff_select on public.factures_fournisseurs;
create policy ff_select on public.factures_fournisseurs for select using (public.is_manager());
drop policy if exists ff_insert on public.factures_fournisseurs;
create policy ff_insert on public.factures_fournisseurs for insert with check (public.is_manager());
drop policy if exists ff_update on public.factures_fournisseurs;
create policy ff_update on public.factures_fournisseurs for update using (public.is_manager());
drop policy if exists ff_delete on public.factures_fournisseurs;
create policy ff_delete on public.factures_fournisseurs for delete using (public.is_direction());

-- PDF des factures : bucket privé, accès direction et responsables uniquement
insert into storage.buckets (id, name, public) values ('factures', 'factures', false) on conflict (id) do nothing;
drop policy if exists factures_read on storage.objects;
create policy factures_read on storage.objects for select using (bucket_id = 'factures' and public.is_manager());
drop policy if exists factures_upload on storage.objects;
create policy factures_upload on storage.objects for insert with check (bucket_id = 'factures' and public.is_manager());
