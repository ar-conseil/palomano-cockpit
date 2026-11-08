-- Test des droits de l'espace équipe : simule 5 profils (aucun vrai compte, tout est effacé à la fin).
-- À exécuter dans Supabase › SQL Editor. Le résultat liste chaque contrôle avec ok = true/false.
reset role;
create temp table if not exists t (n serial, test text, ok boolean, detail text);
truncate t;
grant all on t to authenticated;
grant usage, select on sequence t_n_seq to authenticated;

delete from auth.users where email like '%@test.palomano';
insert into auth.users (id, email, raw_user_meta_data, aud, role) values
 ('00000000-0000-0000-0000-00000000000a', 'dir@test.palomano',  '{"full_name":"T Direction"}',   'authenticated', 'authenticated'),
 ('00000000-0000-0000-0000-00000000000b', 'alex@test.palomano', '{"full_name":"T Alex"}',        'authenticated', 'authenticated'),
 ('00000000-0000-0000-0000-00000000000c', 'resp@test.palomano', '{"full_name":"T Responsable"}', 'authenticated', 'authenticated'),
 ('00000000-0000-0000-0000-00000000000d', 'emp@test.palomano',  '{"full_name":"T Equipe"}',      'authenticated', 'authenticated'),
 ('00000000-0000-0000-0000-00000000000e', 'new@test.palomano',  '{"full_name":"T Attente"}',     'authenticated', 'authenticated');
insert into t (test, ok, detail) select 'Inscription : nouveau compte sans rôle', role is null, coalesce(role, 'rôle ' || role)
  from profiles where id = '00000000-0000-0000-0000-00000000000e';
update profiles set role = 'direction' where id in ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000b');
update profiles set can_validate_planning = true where id = '00000000-0000-0000-0000-00000000000b';
update profiles set role = 'responsable' where id = '00000000-0000-0000-0000-00000000000c';
update profiles set role = 'equipe' where id = '00000000-0000-0000-0000-00000000000d';
insert into stock_items (kind, name, min_qty) values ('snack', 'TEST Cookie', 5);

set role authenticated;

-- ── Équipe ──
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000d","role":"authenticated"}', false);
do $$ begin
  begin update profiles set role = 'direction' where id = auth.uid();
    insert into t (test, ok, detail) values ('Équipe ne peut pas se promouvoir', false, 'promotion acceptée !');
  exception when others then insert into t (test, ok, detail) values ('Équipe ne peut pas se promouvoir', true, sqlerrm); end;
  begin insert into plannings (week_start) values ('2030-01-07');
    insert into t (test, ok, detail) values ('Équipe ne peut pas créer de planning', false, 'créé !');
  exception when others then insert into t (test, ok, detail) values ('Équipe ne peut pas créer de planning', true, sqlerrm); end;
  begin insert into stock_moves (item_id, move, qty) select id, 'comptage', 12 from stock_items where name = 'TEST Cookie';
    insert into t (test, ok, detail) select 'Équipe peut faire un comptage de stock', current_qty = 12, 'stock = ' || current_qty from stock_items where name = 'TEST Cookie';
  exception when others then insert into t (test, ok, detail) values ('Équipe peut faire un comptage de stock', false, sqlerrm); end;
  begin insert into stock_items (kind, name) values ('snack', 'TEST pirate');
    insert into t (test, ok, detail) values ('Équipe ne peut pas créer d''article', false, 'créé !');
  exception when others then insert into t (test, ok, detail) values ('Équipe ne peut pas créer d''article', true, sqlerrm); end;
  begin insert into leaves (start_date, end_date) values ('2030-02-01', '2030-02-03');
    insert into t (test, ok, detail) values ('Équipe peut demander un congé', true, 'ok');
  exception when others then insert into t (test, ok, detail) values ('Équipe peut demander un congé', false, sqlerrm); end;
  begin insert into leaves (start_date, end_date, status) values ('2030-03-01', '2030-03-03', 'acceptee');
    insert into t (test, ok, detail) values ('Équipe ne peut pas s''auto-accepter un congé', false, 'accepté !');
  exception when others then insert into t (test, ok, detail) values ('Équipe ne peut pas s''auto-accepter un congé', true, sqlerrm); end;
  begin insert into posts (title) values ('pirate');
    insert into t (test, ok, detail) values ('Équipe ne peut pas publier de consigne', false, 'publiée !');
  exception when others then insert into t (test, ok, detail) values ('Équipe ne peut pas publier de consigne', true, sqlerrm); end;
end $$;

-- ── Responsable : prépare et soumet ──
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000c","role":"authenticated"}', false);
do $$ begin
  begin insert into plannings (week_start) values ('2030-01-07');
    insert into shifts (week_start, user_id, day, start_time, end_time) values ('2030-01-07', '00000000-0000-0000-0000-00000000000d', '2030-01-08', '09:30', '18:00');
    insert into t (test, ok, detail) values ('Responsable crée le planning et un service', true, 'ok');
  exception when others then insert into t (test, ok, detail) values ('Responsable crée le planning et un service', false, sqlerrm); end;
  begin perform submit_planning('2030-01-07');
    insert into t (test, ok, detail) values ('Responsable soumet le planning', true, 'ok');
  exception when others then insert into t (test, ok, detail) values ('Responsable soumet le planning', false, sqlerrm); end;
  begin insert into shifts (week_start, user_id, day, start_time, end_time) values ('2030-01-07', '00000000-0000-0000-0000-00000000000d', '2030-01-09', '09:30', '18:00');
    insert into t (test, ok, detail) values ('Planning soumis non modifiable', false, 'modifié !');
  exception when others then insert into t (test, ok, detail) values ('Planning soumis non modifiable', true, sqlerrm); end;
  begin perform decide_planning('2030-01-07', true, '');
    insert into t (test, ok, detail) values ('Responsable ne peut pas valider', false, 'validé !');
  exception when others then insert into t (test, ok, detail) values ('Responsable ne peut pas valider', true, sqlerrm); end;
end $$;

-- ── Équipe ne voit pas un planning non validé ──
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000d","role":"authenticated"}', false);
insert into t (test, ok, detail) select 'Équipe ne voit pas le planning en attente', count(*) = 0, count(*) || ' service(s) visibles'
  from shifts where week_start = '2030-01-07';

-- ── Direction sans droit de validation ──
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000a","role":"authenticated"}', false);
do $$ begin
  begin perform decide_planning('2030-01-07', true, '');
    insert into t (test, ok, detail) values ('Seul Alex valide (autre direction refusée)', false, 'validé !');
  exception when others then insert into t (test, ok, detail) values ('Seul Alex valide (autre direction refusée)', true, sqlerrm); end;
end $$;

-- ── Alex valide ──
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000b","role":"authenticated"}', false);
do $$ begin
  begin perform decide_planning('2030-01-07', true, '');
    insert into t (test, ok, detail) select 'Alex valide le planning', status = 'valide', status from plannings where week_start = '2030-01-07';
  exception when others then insert into t (test, ok, detail) values ('Alex valide le planning', false, sqlerrm); end;
end $$;

-- ── Équipe voit le planning validé ──
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000d","role":"authenticated"}', false);
insert into t (test, ok, detail) select 'Équipe voit le planning validé', count(*) = 1, count(*) || ' service(s) visibles'
  from shifts where week_start = '2030-01-07';
insert into t (test, ok, detail) select 'Équipe ne voit pas les congés des autres', count(*) = 0, count(*) || ' visibles'
  from leaves where user_id <> auth.uid();

-- ── Compte en attente : aucun accès ──
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000e","role":"authenticated"}', false);
insert into t (test, ok, detail) select 'Compte en attente ne voit pas les stocks', count(*) = 0, count(*) || ' article(s)' from stock_items;
do $$ begin
  begin insert into incidents (title) values ('pirate');
    insert into t (test, ok, detail) values ('Compte en attente ne peut rien signaler', false, 'accepté !');
  exception when others then insert into t (test, ok, detail) values ('Compte en attente ne peut rien signaler', true, sqlerrm); end;
end $$;

-- ── Nettoyage ──
reset role;
select set_config('request.jwt.claims', '', false);
delete from plannings where week_start = '2030-01-07';
delete from stock_items where name like 'TEST %';
delete from auth.users where email like '%@test.palomano';
insert into t (test, ok, detail) select 'Nettoyage : comptes de test effacés', count(*) = 0, count(*) || ' restant(s)'
  from profiles where email like '%@test.palomano';
select n, ok, test, detail from t order by n;
