-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v9 : options des anniversaires et fiche modifiable par toute l'équipe.
--   · options : gâteau, goodies, soft, bonbons… (cochées à la main, ou ajoutées par l'import
--     Qweekle quand elles sont vendues en caisse ; l'import n'en retire jamais)
--   · maj_anniv_equipe() : chaque membre peut modifier options, animateur prévu, salle, thème,
--     allergies et commentaires (jamais les montants ni les données Qweekle)
-- À exécuter après schema_v8.sql (Supabase › SQL Editor › Run). Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════
alter table public.anniversaires add column if not exists options text[] not null default '{}';

create or replace function public.maj_anniv_equipe(p_id bigint, p_options text[], p_option_animateur boolean,
  p_salle text, p_theme text, p_allergies text, p_notes text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_member() then raise exception 'Accès refusé'; end if;
  update anniversaires set options = coalesce(p_options, '{}'), option_animateur = coalesce(p_option_animateur, false),
         salle = coalesce(p_salle, ''), theme = coalesce(p_theme, ''), allergies = coalesce(p_allergies, ''),
         notes = coalesce(p_notes, ''), updated_at = now()
   where id = p_id;
  if not found then raise exception 'Anniversaire introuvable'; end if;
end $$;
grant execute on function public.maj_anniv_equipe(bigint, text[], boolean, text, text, text, text) to authenticated;

select count(*) filter (where cardinality(options) > 0) as avec_options, count(*) as anniversaires from public.anniversaires;
