-- Destina · contas de teste, uma por perfil, para validar o fluxo no ambiente oficial.
-- 1) Troque TROQUE-ESTA-SENHA pela senha que você quiser (mínimo 8 caracteres). Não salve este arquivo com a senha.
-- 2) Rode no SQL Editor do Supabase.
-- As contas entram já aprovadas e confirmadas, com nome "TESTE · …" e marcadas como teste.
-- Tudo o que elas assinarem fica registrado como [CONTA DE TESTE]. Para apagar depois: supabase/remover_contas_teste.sql

do $$
declare
  senha text := 'TROQUE-ESTA-SENHA';
  c record; v_id uuid;
begin
  if senha = 'TROQUE-ESTA-SENHA' or length(senha) < 8 then
    raise exception 'Defina uma senha de pelo menos 8 caracteres na linha "senha text := ...".';
  end if;
  for c in select * from (values
      ('teste.gestor@destina.teste',       'TESTE · Gestão do sistema',        'ADMIN'),
      ('teste.patrimonio@destina.teste',   'TESTE · Divisão de Patrimônio',    'PATRIMONIO'),
      ('teste.almoxarifado@destina.teste', 'TESTE · Almoxarifado',             'ALMOXARIFADO'),
      ('teste.formalizacao@destina.teste', 'TESTE · Formalização',             'FORMALIZACAO'),
      ('teste.autorizador1@destina.teste', 'TESTE · Autorizador nível 1',      'PRA'),
      ('teste.autorizador2@destina.teste', 'TESTE · Autorizador nível 2',      'REITORIA'),
      ('teste.consulta@destina.teste',     'TESTE · Consulta e auditoria',     'CONSULTA')) as t(email, nome, papel)
  loop
    insert into public.emails_permitidos (email) values (c.email) on conflict do nothing;
    select id into v_id from auth.users where email = c.email;
    if v_id is null then
      v_id := gen_random_uuid();
      insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                              raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                              confirmation_token, recovery_token, email_change_token_new, email_change)
      values ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', c.email,
              extensions.crypt(senha, extensions.gen_salt('bf')), now(),
              '{"provider":"email","providers":["email"]}', jsonb_build_object('nome', c.nome), now(), now(), '', '', '', '');
      insert into auth.identities (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
      values (gen_random_uuid(), v_id::text, v_id, jsonb_build_object('sub', v_id::text, 'email', c.email, 'email_verified', true), 'email', now(), now(), now());
    else
      update auth.users set encrypted_password = extensions.crypt(senha, extensions.gen_salt('bf')), email_confirmed_at = coalesce(email_confirmed_at, now()), updated_at = now() where id = v_id;
    end if;
    insert into public.perfis (id, email, nome) values (v_id, c.email, c.nome) on conflict (id) do nothing;
    update public.perfis set nome = c.nome, papeis = array[c.papel], aprovado = true, teste = true where id = v_id;
  end loop;
end $$;

select p.email, p.nome, p.papeis, p.aprovado from public.perfis p where p.teste order by p.email;
