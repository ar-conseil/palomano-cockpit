-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v7 : animateur d'un anniversaire choisi aussi parmi
-- les intérimaires et les salariés invités (sans compte).
-- À exécuter après schema_v6.sql (Supabase › SQL Editor › Run). Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════
alter table public.anniversaires add column if not exists animateur_ext uuid references public.intervenants on delete set null;

-- À l'inscription d'un salarié invité : ses services ET ses anniversaires lui sont rattachés
create or replace function public.claim_planning() returns trigger
language plpgsql security definer set search_path = public as $$
declare ids uuid[];
begin
  select array_agg(id) into ids from intervenants where type = 'salarie' and lower(email) = lower(new.email);
  if ids is null then return new; end if;
  update shifts set user_id = new.id, intervenant_id = null where intervenant_id = any(ids);
  update anniversaires set animateur = new.id, animateur_ext = null where animateur_ext = any(ids);
  update intervenants set active = false where id = any(ids);
  return new;
end $$;

select count(*) as anniversaires_a_venir, count(*) filter (where animateur is null and animateur_ext is null) as sans_animateur
  from public.anniversaires where date >= current_date and statut <> 'annule';
