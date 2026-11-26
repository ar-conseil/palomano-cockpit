-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — v37 : COMPTABILITÉ (onglet du dashboard financier /pilotage, réservé à la direction), 26/11/2026.
--   · compta_plan      : plan de comptes (repris de l'onglet BDD du fichier « 2026 LPP PALOMANO LILLE »)
--   · compta_ecritures : le grand livre (une ligne = une facture / une charge / un CA), même logique que le LPP
--   · compta_banque    : lignes des relevés CIC importés (compte courant + carte), pour le rapprochement et la trésorerie
--   · compta_bp        : repères du Business Plan par mois (CA, EBE, résultat, amortissements, trésorerie prévue)
--   · factures déposées par l'équipe (factures_fournisseurs) → écriture créée automatiquement (déclencheur)
-- Les données (montants) ne sont jamais dans ce fichier : elles sont importées depuis le dashboard.
-- À exécuter après schema_v36.sql (Supabase › SQL Editor › Run). Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════
create table if not exists public.compta_plan (
  compte text primary key, libelle text, rgpmt1 text, rgpmt2 text, rgpmt3 text
);
create table if not exists public.compta_ecritures (
  id bigint generated always as identity primary key,
  date date not null,
  compte text not null,
  fournisseur text not null default '',
  libelle text not null default '',
  taux numeric,                         -- taux de TVA (0,055 / 0,1 / 0,2), null = TVA mixte
  sens text not null default 'D' check (sens in ('D','C')),   -- D = charge (débit), C = produit (crédit)
  ht numeric not null default 0,
  tva numeric not null default 0,
  commentaire text not null default '',
  statut text not null default 'ok' check (statut in ('ok','a_verifier','provisoire')),
  source text not null default 'manuel' check (source in ('grand_livre','facture','banque','carte','ca','manuel')),
  facture_id bigint unique references public.factures_fournisseurs on delete set null,
  banque_cle text,
  created_by uuid default auth.uid() references public.profiles on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists compta_ecr_date on public.compta_ecritures (date);
create table if not exists public.compta_banque (
  cle text primary key,                 -- date|montant|libellé|n° d'ordre : un ré-import ne crée pas de doublon
  compte text not null default 'cic' check (compte in ('cic','cb')),
  date date not null,
  libelle text not null,
  montant numeric not null,             -- négatif = sortie, positif = entrée
  solde numeric,                        -- solde du compte après l'opération (compte courant)
  ordre int not null default 0,          -- position dans le relevé (pour retrouver le dernier solde du jour)
  ecriture_id bigint references public.compta_ecritures on delete set null,
  ignore boolean not null default false,
  note text not null default '',
  importe_le timestamptz not null default now()
);
alter table public.compta_banque add column if not exists ordre int not null default 0;
create index if not exists compta_bq_date on public.compta_banque (date);
create table if not exists public.compta_bp (
  mois text not null, ligne text not null, montant numeric,
  primary key (mois, ligne)
);

do $$ declare t text; begin
  foreach t in array array['compta_plan','compta_ecritures','compta_banque','compta_bp'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t||'_dir', t);
    execute format('create policy %I on public.%I for all using (public.is_direction()) with check (public.is_direction())', t||'_dir', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
  end loop;
end $$;

insert into public.compta_plan (compte, libelle, rgpmt1, rgpmt2, rgpmt3) values
('604000','Achats Etudes/prestations services','04. Frais Généraux','Sous-traitance externe & autres','Sous-traitance externe & autres'),
('606100','Fournitures non stockables','04. Frais Généraux','Fournitures Administratives et Petits Equipements','Fournitures Administratives et Petits Equipements'),
('606110','Energie (Eau / Electricité / Gaz)','04. Frais Généraux','Energie','Energie'),
('606140','Carburant / IK','04. Frais Généraux','Carburant / IK','- Carburant / IK'),
('606300','Fournitures Entretien, petit équip.','04. Frais Généraux','Fournitures Administratives et Petits Equipements','Fournitures Administratives et Petits Equipements'),
('606400','Fournitures administratives','04. Frais Généraux','Fournitures Administratives et Petits Equipements','Fournitures Administratives et Petits Equipements'),
('606410','Fournitures parc','04. Frais Généraux','Fournitures parc','Fournitures parc'),
('606500','Matériel Informatique','04. Frais Généraux','Matériel Informatique','Matériel Informatique'),
('606800','Autres matières et fournitures','04. Frais Généraux','Fournitures Administratives et Petits Equipements','Fournitures Administratives et Petits Equipements'),
('607100','Achat snacking / Alimentaire','02. COGS','Achat snacking / Alimentaire','Achat snacking / Alimentaire'),
('607200','Achat boutique','02. COGS','Achat boutique','Achat boutique'),
('607300','Achats anniversaires','02. COGS','Achats anniversaires','Achats anniversaires'),
('611000','Sous-traitance générale','04. Frais Généraux','03. Frais Généraux','03. Frais Généraux'),
('613100','Loyer','04. Frais Généraux','Loyer','Loyer'),
('613510','Locations machine à café','04. Frais Généraux','Locations machine à café','Locations machine à café'),
('613520','Location matériel de paiement','04. Frais Généraux','Location matériel de paiement','Location matériel de paiement'),
('613530','Location Vehicules','04. Frais Généraux','Locations Véhicules','Locations Véhicules'),
('613540','Location de matériel de sécurité temporaire','04. Frais Généraux','Caméras – sécurité ouverture / exploitation','Caméras – sécurité ouverture / exploitation'),
('613550','Palomano - Location décors','03. Frais PaloMano','Palomano - Redevance décors, costumes et jouets','Palomano - Redevance décors, costumes et jouets'),
('614000','Charges locatives et copropriété','04. Frais Généraux','Charges Locatives','Charges Locatives'),
('615000','Entretien et réparations','04. Frais Généraux','Entretien & Réparations','Entretien & Réparations'),
('615100','Prestation Informatiqe','04. Frais Généraux','Prestations Informatiques','Prestations Informatiques'),
('615210','Nettoyage des Locaux','04. Frais Généraux','Nettoyage des locaux','Nettoyage des locaux'),
('615520','Entretien Flotte','04. Frais Généraux','Entretien & Réparations','Entretien & Réparations'),
('615600','Maintenance Informatique','04. Frais Généraux','Maintenance Informatiques','Maintenance Informatiques'),
('615650','Maintenance Logiciel','04. Frais Généraux','Maintenance Informatiques','Maintenance Informatiques'),
('615660','Licences Logiciels','04. Frais Généraux','Licences Logiciels','Licences Logiciels'),
('615710','Maintenance installation électrique','04. Frais Généraux','Entretien & Réparations','Entretien & Réparations'),
('615730','Maintenance matériel Incendie','04. Frais Généraux','Entretien & Réparations','Entretien & Réparations'),
('616100','Assurance Flotte Véhicules','04. Frais Généraux','Assurances Véhicules','Assurances Véhicules'),
('616110','Franchise d''Assurance','04. Frais Généraux','Assurances Véhicules','Assurances Véhicules'),
('616200','Assurance Local','04. Frais Généraux','Assurance Local','Assurance Local'),
('616210','Assurance Responsabilité Civile','04. Frais Généraux','Assurance RC','Assurance RC'),
('616230','Assurance Dirigeant','04. Frais Généraux','Assurance Homme-clé','Assurance Homme-clé'),
('616300','Assurance Couverture','04. Frais Généraux','Assurance Couverture','Assurance Couverture'),
('616240','Assurance emprunt (prêt) ','04. Frais Généraux','Assurance Emprunt','Assurance Emprunt'),
('618100','Documentation Générale','04. Frais Généraux','Documentation Générale','Documentation Générale'),
('621600','Prestations extérieures – animateurs','04. Frais Généraux','Animateurs','Animateurs'),
('621700','Prestations extérieures – staffeurs','04. Frais Généraux','Staffeurs','Staffeurs'),
('622600','Honoraires Comptales','04. Frais Généraux','Honoraires Comptables','Honoraires Comptables'),
('622610','Honoraires Juridiques','04. Frais Généraux','Honoraires Avocats','Honoraires Avocats'),
('622613','Honoraires CAC','04. Frais Généraux','Honoraires CAC','Honoraires CAC'),
('622620','Honoraires Immobiliers','04. Frais Généraux','Honoraires Immobiliers','Honoraires Immobiliers'),
('622630','Honoraires divers','04. Frais Généraux','Honoraires Autres','Honoraires Autres'),
('622700','Frais d''actes & contentieux','04. Frais Généraux','Frais d''actes & contentieux','Frais d''actes & contentieux'),
('623000','Publicité, publications, relations','04. Frais Généraux','Publications & Publicité','Publications & Publicité'),
('623110','Marketing Digital','04. Frais Généraux','Marketing Digital','Marketing Digital'),
('623120','Agence Communication','04. Frais Généraux','Agence communication','Agence communication'),
('623200','Salons Expositions','04. Frais Généraux','Publications & Publicité','Publications & Publicité'),
('623400','Cadeaux à la clientèle','04. Frais Généraux','Cadeaux Clientèle','Cadeaux Clientèle'),
('623800','DIVERS (Dons,..)','04. Frais Généraux','Autres (dont irrécouvrables)','Autres (dont irrécouvrables)'),
('625000','Déplacements, missions, réceptions','04. Frais Généraux','Réceptions & Séminaires','Réceptions & Séminaires'),
('625002','Autoroute','04. Frais Généraux','Péages & Parking','Péages & Parking'),
('625010','Repas','04. Frais Généraux','Repas','Repas'),
('625101','Hebergements Hotel','04. Frais Généraux','Hébergement','Hébergement'),
('625108','Indemnités Kilométriques','04. Frais Généraux','Carburant / IK','Carburant / IK'),
('625109','Parking','04. Frais Généraux','Péages & Parking','Péages & Parking'),
('625110','FRAIS TAXI','04. Frais Généraux','Transport / Avions','Autres'),
('625120','Frais d''Avion','04. Frais Généraux','Transport / Avions','Transport / Avions'),
('625130','Frais Sncf-Ratp','04. Frais Généraux','Autres','Autres'),
('625700','Réception','04. Frais Généraux','Réunions & Séminaires','Réunions & Séminaires'),
('626000','Frais postaux et télécom.','04. Frais Généraux','Télécomunication & Frais Postaux','Télécomunication & Frais Postaux'),
('626200','Téléphone','04. Frais Généraux','Télécomunication & Frais Postaux','Télécomunication & Frais Postaux'),
('626300','internet Hébergement','04. Frais Généraux','Télécomunication & Frais Postaux','Télécomunication & Frais Postaux'),
('626400','Noms de domaine','04. Frais Généraux','Noms de domaine','Noms de domaine'),
('627100','Commissions Qweekle','04. Frais Généraux','Commissions QWEEKLE','Frais Qweekle'),
('627800','Frais de Banque','04. Frais Généraux','Frais bancaires','Frais bancaires'),
('627900','Commissions logiciels','04. Frais Généraux','Frais liés aux ventes','Plateformes de réservation / encaissement'),
('628000','Divers','04. Frais Généraux','Honoraires Autres','Honoraires Autres'),
('628100','Cotisation','04. Frais Généraux','Cotisations','Cotisations'),
('628110','Palomano - Forfait DSI','03. Frais PaloMano','Palomano - Forfait DSI','PaloMano - Forfait DSI'),
('628120','Palomano - Forfait Formation','03. Frais PaloMano','Palomano - Redevance de formation continue','Palomano - Redevance de formation continue'),
('628200','Redevances droits d''auteurs','04. Frais Généraux','Divers (Sacem etc.)','Divers'),
('631200','Taxe d''apprentissage','Impôts et Taxes','Taxe d''apprentissage','Taxe d''apprentissage'),
('633300','Formation Continue','Impôts et Taxes','Formation Continue','Formation Continue'),
('635120','Taxe foncière','Impôts et Taxes','Impots, taxes et versements assimilés','Impots, taxes et versements assimilés'),
('635112','CVAE','Impôts et Taxes','Impots, taxes et versements assimilés','Impots, taxes et versements assimilés'),
('635140','TVTS','Impôts et Taxes','TVTS','TVTS'),
('641100','Salaires appointements','05. Masse Salariale','Salaires et traitements','Salaires et traitements'),
('641200','Congés payés','05. Masse Salariale','Salaires et traitements','Salaires et traitements'),
('641300','Primes et gratifications','05. Masse Salariale','Salaires et traitements','Salaires et traitements'),
('641700','Avantages en Nature','05. Masse Salariale','Salaires et traitements','Salaires et traitements'),
('645100','Cotisations URSSAF','05. Masse Salariale','Charges Sociales et Patronnales','Charges Sociales et Patronnales'),
('645200','Cot. mutuelles','05. Masse Salariale','Charges Sociales et Patronnales','Charges Sociales et Patronnales'),
('645300','Cot. caisse retraite employés','05. Masse Salariale','Charges Sociales et Patronnales','Charges Sociales et Patronnales'),
('645500','Prévoyance','05. Masse Salariale','Charges Sociales et Patronnales','Charges Sociales et Patronnales'),
('645820','Charges Sociales / CP','05. Masse Salariale','Conges Payes','Conges Payes'),
('645830','Charges Sociales / Primes','05. Masse Salariale','Charges Sociales et Patronnales','Charges Sociales et Patronnales'),
('648000','Autres charges de personnel','05. Masse Salariale','- Autres Charges de Personnel','- Autres Charges de Personnel'),
('648100','FORMATION','Frais Généraux','Honoraires Autres','Honoraires Autres'),
('648500','A Chg personnel Participation resto','05. Masse Salariale','Autres Charges de Personnel','Autres Charges de Personnel'),
('649000','Crédit d''impôt CICE','05. Masse Salariale','CICE','CICE'),
('651000','Palomano - Redevance Franchise','03. Frais PaloMano','Palomano - Redevance Franchise','Redevance de franchise'),
('651100','Palomano - Redevance Marketing','03. Frais PaloMano','Palomano - Redevance Marketing','Redevance de Marketing'),
('651200','PaloMano- Redevance Marque','03. Frais PaloMano','PaloMano- Redevance Marque','Redevance de licence de marque'),
('658000','Charges de gestion courante','Autres Produits et Charges','Autres Produits et Charges','Autres Produits et Charges'),
('661001','Intérêts Obligataires','Résultat Financier','Charges Financières','Intérêts'),
('661100','Intérêts d''emprunt','Résultat Financier','Charges Financières','Intérêts'),
('661200','Charges de Couverture d''Emprunt','Résultat Financier','Charges Financières','Intérêts'),
('671200','Amendes & pénalités','Exceptionnel','Charges Exceptionnelles','Charges Exceptionnelles'),
('681110','Dot/amort. immob. incoporelles','Amortissements immobilisations','Amortissements immobilisations','Amortissements immobilisations'),
('681120','Dot/amort. immob. corporelles','Amortissements immobilisations','Amortissements immobilisations','Amortissements immobilisations'),
('687250','Dot /amortissements dérogatoires','Amortissements immobilisations','Amortissements immobilisations','Amortissements immobilisations'),
('706010','Prestation de services','01. Marge Brute','CA','Prestations de Services'),
('706100','Commissions Apporteurs Affaires','01. Marge Brute','CA','- Commissions d''apporteurs d''affaires'),
('706200','Rémunération Mandats Président','01. Marge Brute','CA','Rémunérations Mandats'),
('706300','Entree parc / Billeterie','01. CA','CA - Entree parc / Billeterie','CA - Entree parc / Billeterie'),
('706400','Prestation anniversaire','01. CA','CA - Prestation anniversaire','CA - Prestation anniversaire'),
('706500','Accueil groupe / scolaire','01. CA','CA - Accueil groupe / scolaire','CA - Accueil groupe / scolaire'),
('706600','Entrées parc – Tarif AM agréées','01. CA','CA - Entrées parc – Tarif AM agréées','CA - Entrées parc – Tarif AM agréées'),
('707100','Vente Snacking','01. CA','CA - Vente Snacking','CA - Vente Snacking'),
('707200','Vente Boutique','01. CA','CA - Vente Boutique','CA - Vente Boutique'),
('741100','Subvention d''exploitation','Subvention d''exploitation','Subvention d''exploitation','Subvention d''exploitation'),
('758000','Produits divers de gestion courante','Produits Exceptionnels','Produits Exceptionnels','Produits Exceptionnels'),
('761000','Produits de participations','Résultat Financier','Produits Financiers','Produits Financiers'),
('761010','Produits Participation C/C','Résultat Financier','Produits Financiers','Produits Financiers'),
('768000','Autre produits financiers','Résultat Financier','Produits Financiers','Produits Financiers'),
('791000','Transferts de charges exploitation','Transferts de Charges','Transferts de Charges','Transferts de Charges'),
('791100','Transfert de Charges IJSS','Masse Salariale','Salaires Bruts','Salaires Bruts'),
('791400','Transfert de Charges Véhicules','Masse Salariale','Avantages','Avantages'),
('Capitaux Propres','Capitaux Propres','BILAN','Capitaux Propres','Capitaux Propres'),
('Compte Courant','Compte Courant','BILAN','Compte Courant','Compte Courant'),
('Depot Garantie','Depot Garantie','BILAN','Depot Garantie','Depot Garantie'),
('IMMO','IMMO','BILAN','IMMO','IMMO'),
('Pret','Pret','BILAN','Pret','Pret'),
('TRESO','TRESO','BILAN','TRESO','TRESO'),
('TVA','TVA','BILAN','TVA','TVA')
on conflict (compte) do update set libelle = excluded.libelle, rgpmt1 = excluded.rgpmt1, rgpmt2 = excluded.rgpmt2, rgpmt3 = excluded.rgpmt3;

-- Facture déposée par l'équipe → écriture (mise à jour si la facture change, supprimée si elle est refusée)
create or replace function public.compta_depuis_facture() returns trigger
language plpgsql security definer set search_path = public as $$
declare cpt text; d date; vht numeric;
begin
  if tg_op = 'DELETE' or new.statut = 'refusee' then
    delete from compta_ecritures where facture_id = coalesce(new.id, old.id) and source = 'facture';
    return null;
  end if;
  -- facture déjà saisie dans le grand livre repris (même montant, même mois) : on la relie au lieu de la doubler
  if exists (select 1 from compta_ecritures where facture_id = new.id) then null;
  else
    update compta_ecritures e set facture_id = new.id
     where e.id = (select id from compta_ecritures x where x.facture_id is null and x.source <> 'ca'
                     and abs(x.ht - coalesce(new.montant_ht, new.montant_ttc)) < 0.02
                     and x.date between coalesce(new.date_facture, current_date) - 75 and coalesce(new.date_facture, current_date) + 45
                   order by abs(x.date - coalesce(new.date_facture, current_date)) limit 1);
    if found then return null; end if;
  end if;
  cpt := case new.categorie when 'animation' then '621600' when 'staffing' then '621700' when 'jouets' then '607200' else null end;
  if cpt is null then   -- « autre » : le compte habituel de ce fournisseur, sinon fournitures parc à vérifier
    select compte into cpt from compta_ecritures where lower(fournisseur) = lower(new.fournisseur) and source <> 'ca'
     group by compte order by count(*) desc limit 1;
  end if;
  d := case when coalesce(new.periode, '') ~ '^\d{4}-\d{2}$' then (to_date(new.periode || '-01', 'YYYY-MM-DD') + interval '1 month - 1 day')::date
            else coalesce(new.date_facture, current_date) end;
  vht := coalesce(new.montant_ht, new.montant_ttc);
  if exists (select 1 from compta_ecritures where facture_id = new.id and source <> 'facture') then return null; end if;
  insert into compta_ecritures (date, compte, fournisseur, libelle, taux, sens, ht, tva, commentaire, statut, source, facture_id, created_by)
  values (d, coalesce(cpt, '606410'), new.fournisseur, coalesce(nullif(new.numero, ''), 'Facture'),
          case when vht > 0 and new.montant_ttc is not null then round((new.montant_ttc - vht) / vht, 3) end, 'D', vht,
          greatest(coalesce(new.montant_ttc, vht) - vht, 0),
          'Facture déposée dans le dashboard' || case when new.statut = 'paye' then ' - payée le ' || to_char(new.paye_le, 'DD/MM/YYYY') else ' - à payer' end,
          case when cpt is null then 'a_verifier' else 'ok' end, 'facture', new.id, new.created_by)
  on conflict (facture_id) do update set date = excluded.date, compte = case when compta_ecritures.statut = 'a_verifier' then excluded.compte else compta_ecritures.compte end,
     fournisseur = excluded.fournisseur, ht = excluded.ht, tva = excluded.tva, taux = excluded.taux, commentaire = excluded.commentaire, updated_at = now();
  return null;
end $$;
drop trigger if exists compta_facture on public.factures_fournisseurs;
create trigger compta_facture after insert or update or delete on public.factures_fournisseurs
  for each row execute function public.compta_depuis_facture();

select (select count(*) from compta_plan) as comptes, (select count(*) from compta_ecritures) as ecritures, (select count(*) from compta_banque) as lignes_banque;
