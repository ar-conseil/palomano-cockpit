-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v13 : n° de réservation Qweekle de l'anniversaire (« ABXX… »), reçu par
-- webhook, pour que la fonction qweekle-webhook relise la commande à chaque paiement (sale.created).
-- À exécuter après schema_v12.sql. Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════
alter table public.anniversaires add column if not exists qweekle_booking text;

select count(*) filter (where qweekle_booking is not null) as avec_reservation, count(*) as anniversaires
  from public.anniversaires;
