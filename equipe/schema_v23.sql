-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v23 : les achats en ligne (site public Qweekle, source « front ») ne comptent
-- pas dans les chiffres du jour. Constaté le 09/11/2026 (parc fermé) : billets d'entrée achetés sur le site
-- pour une visite les 11 et 14/11, partiellement payés (acomptes), webhook sale.created avec source = « front »
-- et réservations avec source = « front_order ».
-- À exécuter après schema_v22.sql (Supabase › SQL Editor › Run). Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public.qw_vente_comptee(p jsonb) returns boolean
language sql immutable as $$
  select coalesce((p->>'amount')::numeric, 0) > 0
     and lower(coalesce(p->>'source', '')) !~ '(\mfront|online|web|shop|e-?commerce|widget|site|internet|booking|marketplace)'
     and not public.qw_exclu(coalesce(p->>'label', '') || ' ' || coalesce(p->>'type', ''), p->>'category')
$$;

select public.qw_vente_comptee('{"amount": 39.6, "source": "front"}') as achat_en_ligne_compte,
       public.qw_vente_comptee('{"amount": 12, "source": "pos"}') as vente_caisse_comptee,
       (select count(*) from qweekle_events where event_type = 'sale.created'
          and public.qw_vente_comptee(payload)
          and (received_at at time zone 'Europe/Paris')::date = '2026-11-09') as ventes_comptees_le_9;
