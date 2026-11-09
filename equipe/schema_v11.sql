-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v11 : commande Qweekle de chaque anniversaire.
--   · anniversaires.commande : produits de la commande Qweekle (quantité + nom, SANS montant),
--     visibles par toute l'équipe : Animateur, sirops, bonbons, gâteau, goodies, chaussettes…
--   · anniversaires_paiement : total, acompte encaissé et reste à payer de la commande,
--     lisibles par la direction et les responsables seulement (l'équipe ne voit jamais de montant).
-- Rempli par sync_commandes.py (GitHub Actions, compte Qweekle dédié). Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════
alter table public.anniversaires add column if not exists commande jsonb;
alter table public.anniversaires add column if not exists commande_sync_at timestamptz;

create table if not exists public.anniversaires_paiement (
  anniversaire_id bigint primary key references public.anniversaires on delete cascade,
  commande text default '',            -- n° de commande Qweekle (O-…)
  total numeric,
  encaisse numeric,                    -- acompte(s) et paiements déjà encaissés
  reste numeric,                       -- reste à payer
  lignes jsonb,                        -- [{q, p, m}] produits avec leur montant
  synced_at timestamptz not null default now()
);
alter table public.anniversaires_paiement enable row level security;
drop policy if exists annpay_select on public.anniversaires_paiement;
create policy annpay_select on public.anniversaires_paiement for select using (public.is_manager());
-- aucune politique d'écriture : seule la synchronisation (clé de service) écrit

select count(*) as anniversaires, count(commande) as avec_commande,
       (select count(*) from public.anniversaires_paiement) as montants
  from public.anniversaires;
