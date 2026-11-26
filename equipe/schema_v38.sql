-- ═══════════════════════════════════════════════════════════════════════════
-- PALOMANO — v38 : AGENT FACTURES (26/11/2026).
-- Chaque jour, l'agent lit les factures reçues en pièce jointe sur lille@palomano.com, en relève le contenu
-- (fournisseur, n°, date, HT, TVA, TTC, compte) et crée les écritures de la comptabilité.
--   · compta_pieces : une ligne par pièce jointe lue (fichier rangé dans le stockage « factures », dossier compta/)
--   · compta_mails  : e-mails déjà examinés (pour ne jamais lire deux fois le même)
--   · compta_ecritures.piece_id : la facture d'origine d'une écriture
-- Réservé à la direction (l'agent écrit avec la clé de service). À exécuter après schema_v37.sql. Ré-exécutable.
-- ═══════════════════════════════════════════════════════════════════════════
create table if not exists public.compta_pieces (
  id bigint generated always as identity primary key,
  empreinte text unique not null,            -- sha256 du fichier : une même pièce n'est jamais traitée deux fois
  source text not null default 'mail',
  message_id text,
  expediteur text not null default '',
  sujet text not null default '',
  recu_le timestamptz,
  nom_fichier text not null default '',
  fichier_path text,
  est_facture boolean,
  fournisseur text not null default '',
  numero text not null default '',
  date_piece date,
  total_ttc numeric,
  extrait jsonb,                             -- ce que l'agent a lu dans la pièce
  statut text not null default 'traitee' check (statut in ('traitee','a_verifier','ignoree','doublon','erreur')),
  note text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists compta_pieces_recu on public.compta_pieces (recu_le);
create table if not exists public.compta_mails (
  message_id text primary key,
  recu_le timestamptz,
  expediteur text not null default '',
  sujet text not null default '',
  pieces int not null default 0,
  vu_le timestamptz not null default now()
);
alter table public.compta_ecritures add column if not exists piece_id bigint references public.compta_pieces on delete set null;

do $$ declare t text; begin
  foreach t in array array['compta_pieces','compta_mails'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t||'_dir', t);
    execute format('create policy %I on public.%I for all using (public.is_direction()) with check (public.is_direction())', t||'_dir', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
  end loop;
end $$;

-- état de l'agent, visible dans l'onglet Comptabilité
insert into public.sync_state (key, ok, message, synced_at)
values ('agent_factures', true, 'Agent installé : première lecture des e-mails à la prochaine actualisation', now())
on conflict (key) do nothing;

select (select count(*) from compta_pieces) as pieces, (select count(*) from compta_mails) as mails;
