-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — v39 : COLORHISTO HEBDOMADAIRE DANS L'ESPACE ÉQUIPE (26/11/2026).
-- Remplace le fichier Excel « Colorhisto_PALOMANO_Lille.xlsx » (feuille Colorhisto hebdo).
--   · colorhisto_kpi      : les indicateurs et leur barème de 1 (vraiment nul) à 6 (parfait)
--   · colorhisto_notes    : une note par indicateur et par semaine (lundi). source = auto (calculée
--                            par publish_kpis.py), saisie (direction / Jean-Baptiste) ou excel (historique repris).
--                            Le calcul automatique ne remplace jamais une note saisie à la main.
--   · colorhisto_semaines : commentaire et plan d'action de la semaine (Yannika)
-- Accès : profiles.colorhisto = 'saisie' (remplit la grille) ou 'lecture' (consulte et commente).
-- La direction a d'office l'accès « saisie ». Pré-réglé : Yannika → lecture, Jean-Baptiste → saisie.
-- À exécuter après schema_v38.sql. Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════
alter table public.profiles add column if not exists colorhisto text check (colorhisto in ('saisie','lecture'));

-- seule la direction donne ou retire l'accès au Colorhisto (comme pour les rôles)
create or replace function public.guard_profile() returns trigger
language plpgsql as $$
begin
  if not public.is_direction() and auth.uid() is not null and
     (new.role is distinct from old.role or new.active is distinct from old.active
      or new.can_validate_planning is distinct from old.can_validate_planning
      or new.colorhisto is distinct from old.colorhisto) then
    raise exception 'Seule la direction peut modifier les rôles et les accès';
  end if;
  return new;
end $$;

create or replace function public.colorhisto_role() returns text
language sql stable security definer set search_path = public as $$
  select case when role = 'direction' then 'saisie' else colorhisto end
  from profiles where id = auth.uid() and active
$$;
grant execute on function public.colorhisto_role() to authenticated;

create table if not exists public.colorhisto_kpi (
  key text primary key,
  theme text not null,
  label text not null,
  unite text not null default '',
  auto boolean not null default false,       -- calculé chaque jour à partir des chiffres
  bareme jsonb not null default '[]',        -- libellés des notes 1 → 6
  position int not null default 0,
  active boolean not null default true
);
create table if not exists public.colorhisto_notes (
  semaine date not null check (extract(isodow from semaine) = 1),   -- lundi de la semaine
  kpi text not null references public.colorhisto_kpi on update cascade,
  note smallint check (note between 1 and 6),
  valeur numeric,                            -- mesure ayant donné la note (calcul automatique)
  detail text not null default '',
  source text not null default 'saisie' check (source in ('auto','saisie','excel')),
  saisi_par uuid references public.profiles on delete set null,
  updated_at timestamptz not null default now(),
  primary key (semaine, kpi)
);
create table if not exists public.colorhisto_semaines (
  semaine date primary key check (extract(isodow from semaine) = 1),
  commentaire text not null default '',
  plan_action text not null default '',
  par uuid references public.profiles on delete set null,
  updated_at timestamptz not null default now()
);

alter table public.colorhisto_kpi enable row level security;
alter table public.colorhisto_notes enable row level security;
alter table public.colorhisto_semaines enable row level security;
drop policy if exists colorhisto_kpi_lire on public.colorhisto_kpi;
create policy colorhisto_kpi_lire on public.colorhisto_kpi for select using (public.colorhisto_role() is not null);
drop policy if exists colorhisto_kpi_dir on public.colorhisto_kpi;
create policy colorhisto_kpi_dir on public.colorhisto_kpi for all using (public.is_direction()) with check (public.is_direction());
drop policy if exists colorhisto_notes_lire on public.colorhisto_notes;
create policy colorhisto_notes_lire on public.colorhisto_notes for select using (public.colorhisto_role() is not null);
drop policy if exists colorhisto_notes_saisie on public.colorhisto_notes;
create policy colorhisto_notes_saisie on public.colorhisto_notes for all
  using (public.colorhisto_role() = 'saisie') with check (public.colorhisto_role() = 'saisie');
drop policy if exists colorhisto_semaines_lire on public.colorhisto_semaines;
create policy colorhisto_semaines_lire on public.colorhisto_semaines for select using (public.colorhisto_role() is not null);
drop policy if exists colorhisto_semaines_ecrire on public.colorhisto_semaines;
create policy colorhisto_semaines_ecrire on public.colorhisto_semaines for all
  using (public.colorhisto_role() is not null) with check (public.colorhisto_role() is not null);
grant select, insert, update, delete on public.colorhisto_kpi, public.colorhisto_notes, public.colorhisto_semaines to authenticated;

-- le calcul automatique n'écrase jamais une note saisie (ni l'historique repris de l'Excel)
create or replace function public.colorhisto_garde_auto() returns trigger
language plpgsql as $$
begin
  if new.source = 'auto' and old.source <> 'auto' then return null; end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists colorhisto_garde_auto on public.colorhisto_notes;
create trigger colorhisto_garde_auto before update on public.colorhisto_notes
  for each row execute function public.colorhisto_garde_auto();

-- accès pré-réglés
update public.profiles set colorhisto = 'lecture' where colorhisto is null and (full_name ilike '%yannika%' or email ilike '%yannika%');
update public.profiles set colorhisto = 'saisie' where colorhisto is null and (full_name ~* 'jean[ -]?baptiste' or email ~* 'jean[.-]?baptiste|^jb[.@]');

-- indicateurs et barème (feuille « Légende & méthode »)
insert into public.colorhisto_kpi (key, theme, label, unite, auto, bareme, position) values
  ('ca', 'Fréquentation & chiffre d''affaires', 'CA de la semaine', '% objectif', true, '["< 70 % de l''objectif hebdo", "70 → 80 %", "80 → 90 %", "90 → 100 %", "100 → 110 %", "> 110 %"]'::jsonb, 1),
  ('entrees', 'Fréquentation & chiffre d''affaires', 'Nombre d''entrées', '% objectif', true, '["< 60 % de l''objectif", "60 → 75 %", "75 → 85 %", "85 → 100 %", "100 → 115 %", "> 115 %"]'::jsonb, 2),
  ('occupation', 'Fréquentation & chiffre d''affaires', 'Taux d''occupation', '%', true, '["< 15 %", "15 → 22 %", "22 → 30 %", "30 → 38 % (objectif)", "38 → 50 %", "> 50 %"]'::jsonb, 3),
  ('snack', 'Pôles d''activité', 'Snack moyen par visiteur', '€ HT', true, '["< 0,90 €", "0,90 → 0,95 €", "0,95 → 1€", "1 → 1,05 €", "1,05 → 1,10 €", "> 1,10 €"]'::jsonb, 4),
  ('pass', 'Pôles d''activité', 'Palo-Pass vendus', 'nb', true, '["0", "1", "2", "3", "4", "> 4"]'::jsonb, 5),
  ('anniv', 'Pôles d''activité', 'Taux de remplissage anniversaires', '%', true, '["< 30 %", "30 → 45 %", "45 → 60 %", "60 → 75 %", "75 → 90 %", "> 90 %"]'::jsonb, 6),
  ('devis_env', 'Pôles d''activité', 'Devis B2B envoyés', 'nb', false, '["0 devis", "1 → 2", "3 → 4", "5 → 7", "8 → 10", "> 10"]'::jsonb, 7),
  ('devis_val', 'Pôles d''activité', 'Devis B2B validés', 'nb', false, '["0 devis", "1 → 2", "3 → 4", "5 → 7", "8 → 10", "> 10"]'::jsonb, 8),
  ('google_note', 'Qualité & satisfaction client', 'Note Google de la semaine', '/5', false, '["< 3,0", "3,0 → 3,5", "3,5 → 4,0", "4,0 → 4,3", "4,3 → 4,7", "> 4,7"]'::jsonb, 9),
  ('google_nb', 'Qualité & satisfaction client', 'Nombre d''avis Google', 'nb', false, '["< 10", "10 → 12", "12 → 14", "14 → 16", "16 → 18", "> 18"]'::jsonb, 10),
  ('google_neg', 'Qualité & satisfaction client', 'Nombre d''avis négatifs', 'nb', false, '["> 5", "4 → 5", "3", "2", "1", "0"]'::jsonb, 11),
  ('climat', 'Équipe & RH', 'Climat d''équipe', 'note', false, '["Très mauvais · tensions ouvertes", "Mauvais · démotivation visible", "Tendu · plaintes répétées", "Correct · pas de problème majeur", "Bon · équipe engagée", "Excellent · cohésion forte"]'::jsonb, 12),
  ('mood', 'Équipe & RH', 'Mood de la directrice', 'note', false, '["Très mauvais", "Mauvais", "Tendu", "Correct", "Bon", "Excellent"]'::jsonb, 13),
  ('retards', 'Équipe & RH', 'Retards / no-show', 'nb', false, '["> 5", "4", "3", "2", "1", "0"]'::jsonb, 14),
  ('recrutement', 'Équipe & RH', 'Avancée recrutement', 'note', false, '["Bloqué · aucune piste", "En retard · pistes faibles", "Lent · entretiens en cours", "OK · candidats qualifiés", "Bien avancé · offres faites", "Tout est pourvu"]'::jsonb, 15),
  ('reunion', 'Équipe & RH', 'Réunion mensuelle', 'note', false, '["Vraiment nul", "Pas bien", "Moyen moins", "Moyen plus", "Bien", "Parfait"]'::jsonb, 16),
  ('casses', 'Exploitation & sécurité', 'Casses / démarque', 'nb', false, '["> 5", "4 → 5", "3", "2", "1", "0"]'::jsonb, 17),
  ('proprete', 'Exploitation & sécurité', 'Propreté & tenue du parc', 'note', false, '["Sale · plaintes clients", "Pas top · zones négligées", "Moyen · à améliorer", "OK · standard tenu", "Très bien · soigné", "Impeccable · au-delà du standard"]'::jsonb, 18),
  ('securite', 'Exploitation & sécurité', 'Sécurité (contrôles à jour)', 'note', false, '["Plusieurs contrôles en retard", "1 ou 2 contrôles en retard", "À jour partiellement", "À jour", "À jour · anticipation", "Tout à jour + audits OK"]'::jsonb, 19),
  ('inventaire', 'Exploitation & sécurité', 'Inventaire parc pré-vacances', 'note', false, '["Vraiment nul", "Pas bien", "Moyen moins", "Moyen plus", "Bien", "Parfait"]'::jsonb, 20),
  ('dlc', 'Exploitation & sécurité', 'Suivi DLC (chaîne du froid)', 'note', false, '["Vraiment nul", "Pas bien", "Moyen moins", "Moyen plus", "Bien", "Parfait"]'::jsonb, 21)
on conflict (key) do update set theme = excluded.theme, label = excluded.label, unite = excluded.unite,
  auto = excluded.auto, bareme = excluded.bareme, position = excluded.position;

-- historique repris de la feuille « Colorhisto hebdo » (10 semaines, 167 notes) ;
-- chaque colonne, datée du lundi où elle a été remplie, est rangée sur la semaine précédente qu'elle note
insert into public.colorhisto_notes (semaine, kpi, note, source) values
  ('2026-04-27', 'ca', 1, 'excel'),
  ('2026-05-04', 'ca', 2, 'excel'),
  ('2026-05-11', 'ca', 6, 'excel'),
  ('2026-05-18', 'ca', 1, 'excel'),
  ('2026-05-25', 'ca', 1, 'excel'),
  ('2026-06-01', 'ca', 5, 'excel'),
  ('2026-06-08', 'ca', 4, 'excel'),
  ('2026-06-15', 'ca', 4, 'excel'),
  ('2026-06-22', 'ca', 5, 'excel'),
  ('2026-10-05', 'ca', 2, 'excel'),
  ('2026-04-27', 'entrees', 1, 'excel'),
  ('2026-05-04', 'entrees', 2, 'excel'),
  ('2026-05-11', 'entrees', 6, 'excel'),
  ('2026-05-18', 'entrees', 1, 'excel'),
  ('2026-05-25', 'entrees', 1, 'excel'),
  ('2026-06-01', 'entrees', 5, 'excel'),
  ('2026-06-08', 'entrees', 2, 'excel'),
  ('2026-06-15', 'entrees', 3, 'excel'),
  ('2026-06-22', 'entrees', 5, 'excel'),
  ('2026-10-05', 'entrees', 2, 'excel'),
  ('2026-04-27', 'occupation', 1, 'excel'),
  ('2026-05-04', 'occupation', 2, 'excel'),
  ('2026-05-11', 'occupation', 5, 'excel'),
  ('2026-05-18', 'occupation', 1, 'excel'),
  ('2026-05-25', 'occupation', 1, 'excel'),
  ('2026-06-01', 'occupation', 5, 'excel'),
  ('2026-06-08', 'occupation', 3, 'excel'),
  ('2026-06-15', 'occupation', 3, 'excel'),
  ('2026-06-22', 'occupation', 4, 'excel'),
  ('2026-10-05', 'occupation', 2, 'excel'),
  ('2026-04-27', 'snack', 6, 'excel'),
  ('2026-05-04', 'snack', 6, 'excel'),
  ('2026-05-11', 'snack', 1, 'excel'),
  ('2026-05-18', 'snack', 6, 'excel'),
  ('2026-05-25', 'snack', 6, 'excel'),
  ('2026-06-01', 'snack', 6, 'excel'),
  ('2026-06-08', 'snack', 6, 'excel'),
  ('2026-06-15', 'snack', 6, 'excel'),
  ('2026-06-22', 'snack', 6, 'excel'),
  ('2026-10-05', 'snack', 5, 'excel'),
  ('2026-04-27', 'pass', 1, 'excel'),
  ('2026-05-04', 'pass', 1, 'excel'),
  ('2026-05-11', 'pass', 2, 'excel'),
  ('2026-05-18', 'pass', 1, 'excel'),
  ('2026-05-25', 'pass', 1, 'excel'),
  ('2026-06-01', 'pass', 1, 'excel'),
  ('2026-06-08', 'pass', 2, 'excel'),
  ('2026-06-15', 'pass', 1, 'excel'),
  ('2026-06-22', 'pass', 1, 'excel'),
  ('2026-10-05', 'pass', 1, 'excel'),
  ('2026-04-27', 'anniv', 1, 'excel'),
  ('2026-05-04', 'anniv', 1, 'excel'),
  ('2026-05-11', 'anniv', 1, 'excel'),
  ('2026-05-18', 'anniv', 1, 'excel'),
  ('2026-05-25', 'anniv', 1, 'excel'),
  ('2026-06-01', 'anniv', 3, 'excel'),
  ('2026-06-08', 'anniv', 5, 'excel'),
  ('2026-06-15', 'anniv', 4, 'excel'),
  ('2026-06-22', 'anniv', 5, 'excel'),
  ('2026-10-05', 'anniv', 3, 'excel'),
  ('2026-04-27', 'devis_env', 5, 'excel'),
  ('2026-05-04', 'devis_env', 6, 'excel'),
  ('2026-05-11', 'devis_env', 5, 'excel'),
  ('2026-05-18', 'devis_env', 5, 'excel'),
  ('2026-05-25', 'devis_env', 5, 'excel'),
  ('2026-06-01', 'devis_env', 5, 'excel'),
  ('2026-06-08', 'devis_env', 6, 'excel'),
  ('2026-06-15', 'devis_env', 2, 'excel'),
  ('2026-06-22', 'devis_env', 6, 'excel'),
  ('2026-10-05', 'devis_env', 4, 'excel'),
  ('2026-06-01', 'devis_val', 3, 'excel'),
  ('2026-06-08', 'devis_val', 5, 'excel'),
  ('2026-06-15', 'devis_val', 3, 'excel'),
  ('2026-06-22', 'devis_val', 1, 'excel'),
  ('2026-10-05', 'devis_val', 2, 'excel'),
  ('2026-04-27', 'google_note', 5, 'excel'),
  ('2026-05-04', 'google_note', 4, 'excel'),
  ('2026-05-11', 'google_note', 5, 'excel'),
  ('2026-05-18', 'google_note', 3, 'excel'),
  ('2026-05-25', 'google_note', 1, 'excel'),
  ('2026-06-01', 'google_note', 6, 'excel'),
  ('2026-06-08', 'google_note', 5, 'excel'),
  ('2026-06-15', 'google_note', 6, 'excel'),
  ('2026-06-22', 'google_note', 6, 'excel'),
  ('2026-10-05', 'google_note', 6, 'excel'),
  ('2026-05-25', 'google_nb', 1, 'excel'),
  ('2026-06-01', 'google_nb', 6, 'excel'),
  ('2026-06-08', 'google_nb', 1, 'excel'),
  ('2026-06-15', 'google_nb', 1, 'excel'),
  ('2026-06-22', 'google_nb', 1, 'excel'),
  ('2026-10-05', 'google_nb', 1, 'excel'),
  ('2026-04-27', 'google_neg', 6, 'excel'),
  ('2026-05-04', 'google_neg', 5, 'excel'),
  ('2026-05-11', 'google_neg', 4, 'excel'),
  ('2026-05-18', 'google_neg', 4, 'excel'),
  ('2026-05-25', 'google_neg', 1, 'excel'),
  ('2026-06-01', 'google_neg', 6, 'excel'),
  ('2026-06-08', 'google_neg', 1, 'excel'),
  ('2026-06-15', 'google_neg', 6, 'excel'),
  ('2026-06-22', 'google_neg', 6, 'excel'),
  ('2026-10-05', 'google_neg', 6, 'excel'),
  ('2026-04-27', 'climat', 5, 'excel'),
  ('2026-05-04', 'climat', 5, 'excel'),
  ('2026-05-11', 'climat', 5, 'excel'),
  ('2026-05-18', 'climat', 5, 'excel'),
  ('2026-05-25', 'climat', 3, 'excel'),
  ('2026-06-01', 'climat', 5, 'excel'),
  ('2026-06-08', 'climat', 5, 'excel'),
  ('2026-06-15', 'climat', 5, 'excel'),
  ('2026-06-22', 'climat', 5, 'excel'),
  ('2026-10-05', 'climat', 6, 'excel'),
  ('2026-04-27', 'mood', 5, 'excel'),
  ('2026-05-04', 'mood', 5, 'excel'),
  ('2026-05-11', 'mood', 4, 'excel'),
  ('2026-05-18', 'mood', 4, 'excel'),
  ('2026-05-25', 'mood', 3, 'excel'),
  ('2026-06-01', 'mood', 4, 'excel'),
  ('2026-06-08', 'mood', 4, 'excel'),
  ('2026-06-15', 'mood', 4, 'excel'),
  ('2026-06-22', 'mood', 4, 'excel'),
  ('2026-10-05', 'mood', 6, 'excel'),
  ('2026-04-27', 'retards', 5, 'excel'),
  ('2026-05-04', 'retards', 6, 'excel'),
  ('2026-05-11', 'retards', 6, 'excel'),
  ('2026-05-18', 'retards', 5, 'excel'),
  ('2026-05-25', 'retards', 4, 'excel'),
  ('2026-06-01', 'retards', 6, 'excel'),
  ('2026-06-08', 'retards', 6, 'excel'),
  ('2026-06-15', 'retards', 6, 'excel'),
  ('2026-06-22', 'retards', 6, 'excel'),
  ('2026-10-05', 'retards', 6, 'excel'),
  ('2026-04-27', 'recrutement', 4, 'excel'),
  ('2026-05-04', 'recrutement', 3, 'excel'),
  ('2026-05-11', 'recrutement', 3, 'excel'),
  ('2026-05-18', 'recrutement', 4, 'excel'),
  ('2026-05-25', 'recrutement', 3, 'excel'),
  ('2026-06-01', 'recrutement', 5, 'excel'),
  ('2026-06-08', 'recrutement', 5, 'excel'),
  ('2026-06-15', 'recrutement', 5, 'excel'),
  ('2026-06-22', 'recrutement', 5, 'excel'),
  ('2026-10-05', 'recrutement', 6, 'excel'),
  ('2026-04-27', 'casses', 1, 'excel'),
  ('2026-05-04', 'casses', 1, 'excel'),
  ('2026-05-11', 'casses', 5, 'excel'),
  ('2026-05-18', 'casses', 4, 'excel'),
  ('2026-05-25', 'casses', 3, 'excel'),
  ('2026-06-01', 'casses', 4, 'excel'),
  ('2026-06-08', 'casses', 3, 'excel'),
  ('2026-06-15', 'casses', 3, 'excel'),
  ('2026-06-22', 'casses', 4, 'excel'),
  ('2026-10-05', 'casses', 4, 'excel'),
  ('2026-04-27', 'proprete', 3, 'excel'),
  ('2026-05-04', 'proprete', 2, 'excel'),
  ('2026-05-11', 'proprete', 4, 'excel'),
  ('2026-05-18', 'proprete', 4, 'excel'),
  ('2026-05-25', 'proprete', 2, 'excel'),
  ('2026-06-01', 'proprete', 1, 'excel'),
  ('2026-06-08', 'proprete', 4, 'excel'),
  ('2026-06-15', 'proprete', 2, 'excel'),
  ('2026-06-22', 'proprete', 2, 'excel'),
  ('2026-10-05', 'proprete', 5, 'excel'),
  ('2026-04-27', 'securite', 6, 'excel'),
  ('2026-05-04', 'securite', 6, 'excel'),
  ('2026-05-11', 'securite', 6, 'excel'),
  ('2026-05-18', 'securite', 6, 'excel'),
  ('2026-05-25', 'securite', 6, 'excel'),
  ('2026-06-01', 'securite', 6, 'excel')
on conflict (semaine, kpi) do nothing;

select (select count(*) from colorhisto_kpi) as indicateurs, (select count(*) from colorhisto_notes) as notes,
  (select string_agg(full_name || ' → ' || colorhisto, ', ') from profiles where colorhisto is not null) as acces;
