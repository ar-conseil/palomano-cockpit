-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v35 : l'onglet Heures et le compteur d'heures ouverts aux responsables (Yannika), 21/11/2026.
-- À exécuter après schema_v34.sql (Supabase › SQL Editor › Run). Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════
drop policy if exists ca_select on public.compteur_ajust;
create policy ca_select on public.compteur_ajust for select using (public.is_manager());
drop policy if exists ca_insert on public.compteur_ajust;
create policy ca_insert on public.compteur_ajust for insert with check (public.is_manager() and by_user = auth.uid());
drop policy if exists ca_delete on public.compteur_ajust;
create policy ca_delete on public.compteur_ajust for delete using (public.is_manager());

select policyname, cmd from pg_policies where tablename = 'compteur_ajust' order by cmd;
