-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v33 : plus de validation des plannings par Alex (18/11/2026).
-- Yannika (et les managers) publient le planning directement : il est visible par l'équipe tout de suite
-- et reste modifiable après publication (changements visibles en direct).
-- À exécuter après schema_v32.sql (Supabase › SQL Editor › Run). Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public.submit_planning(w date) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_manager() then raise exception 'Accès refusé'; end if;
  update plannings set status = 'valide', submitted_by = auth.uid(), submitted_at = now(),
         validated_by = auth.uid(), validated_at = now(), comment = '', updated_at = now()
   where week_start = w and status in ('brouillon', 'refuse', 'soumis');
  if not found then raise exception 'Planning introuvable ou déjà publié'; end if;
end $$;

-- un planning publié reste modifiable par les managers (et plus seulement par la direction)
create or replace function public.planning_editable(w date) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_manager() and coalesce((select status in ('brouillon', 'refuse', 'valide') from plannings where week_start = w), true)
$$;

create or replace function public.reopen_planning(w date) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_manager() then raise exception 'Accès refusé'; end if;
  update plannings set status = 'brouillon', updated_at = now() where week_start = w;
end $$;

-- les plannings restés « en attente de validation d'Alex » sont publiés
update plannings set status = 'valide', validated_at = coalesce(validated_at, now()), updated_at = now() where status = 'soumis';

select status, count(*) from plannings group by status order by status;
