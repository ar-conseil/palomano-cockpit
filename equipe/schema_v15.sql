-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — Espace équipe, v15 : dashboard financier actualisé de façon fiable et quasi instantanée.
--   GitHub ne respecte pas ses propres horaires (« toutes les 30 min » → 2 à 4 fois par jour).
--   C'est donc Supabase qui déclenche l'actualisation (workflow « refresh.yml ») :
--     · toutes les 15 minutes de 6 h à 23 h (pg_cron) ;
--     · tout de suite quand la saisie du jour est enregistrée (déclencheur sur saisie_jour).
--   Le jeton GitHub (droit « Actions : lecture et écriture » sur le seul dépôt palomano-cockpit) est rangé
--   dans le coffre-fort Supabase (Vault) sous le nom « github_dispatch_token » : il ne figure nulle part ailleurs.
-- À exécuter après schema_v14.sql (Supabase › SQL Editor › Run). Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

create or replace function public.dash_refresh(reason text default 'planifié', min_gap interval default '10 minutes')
returns text language plpgsql security definer set search_path = public, extensions as $$
declare tok text; last timestamptz; st text;
begin
  select synced_at into last from sync_state where key = 'dashboard_demande';
  if last is not null and last > now() - min_gap then return 'déjà demandé'; end if;
  select decrypted_secret into tok from vault.decrypted_secrets where name = 'github_dispatch_token' limit 1;
  if tok is null then
    st := 'jeton GitHub absent (coffre-fort Supabase, nom github_dispatch_token)';
  else
    perform net.http_post(
      url := 'https://api.github.com/repos/ar-conseil/palomano-cockpit/actions/workflows/refresh.yml/dispatches',
      body := '{"ref":"main"}'::jsonb,
      headers := jsonb_build_object('Authorization', 'Bearer ' || tok, 'Accept', 'application/vnd.github+json',
                                    'X-GitHub-Api-Version', '2022-11-28', 'User-Agent', 'palomano-supabase',
                                    'Content-Type', 'application/json'));
    st := 'actualisation demandée (' || reason || ')';
  end if;
  insert into sync_state (key, ok, message, synced_at) values ('dashboard_demande', tok is not null, st, now())
  on conflict (key) do update set ok = excluded.ok, message = excluded.message, synced_at = excluded.synced_at;
  return st;
end $$;
revoke all on function public.dash_refresh(text, interval) from public, anon, authenticated;

-- Saisie du jour enregistrée → actualisation dans la minute (les saisies rapprochées n'en déclenchent qu'une)
create or replace function public.dash_refresh_saisie() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.dash_refresh('saisie du jour', interval '1 minute');
  return null;
exception when others then return null;          -- ne jamais bloquer la saisie
end $$;
drop trigger if exists dash_refresh_saisie on public.saisie_jour;
create trigger dash_refresh_saisie after insert or update on public.saisie_jour
  for each statement execute function public.dash_refresh_saisie();

-- Toutes les 15 min de 6 h à 23 h, heure de Paris (le serveur est en UTC : 5 h–21 h 45 l'hiver)
do $$ begin
  if exists (select 1 from cron.job where jobname = 'palomano-dashboard') then perform cron.unschedule('palomano-dashboard'); end if;
end $$;
select cron.schedule('palomano-dashboard', '*/15 5-21 * * *', $$select public.dash_refresh('planifié', interval '10 minutes')$$);

select jobname, schedule, active from cron.job where jobname = 'palomano-dashboard';
