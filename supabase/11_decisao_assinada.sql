-- Destina · 11 · a decisão que inicia o plano é assinada pela autoridade
-- 1) Só a Reitoria e a Pró-Reitoria de Administração decidem. A decisão exige a mesma
--    confirmação de identidade da assinatura dos termos (senha recente + código por e-mail,
--    quando o envio estiver ligado) e fica registrada com a evidência.
-- 2) A Divisão de Patrimônio, o Almoxarifado e o gestor do sistema podem propor uma destinação.
--    A proposta vai para a Reitoria/PRA; o plano só nasce quando uma delas assina a decisão.
-- Rode depois de 01 a 10. Pode ser rodado de novo sem problema.

alter table public.determinacoes drop constraint if exists determinacoes_papel_check;
alter table public.determinacoes add constraint determinacoes_papel_check check (papel in ('PRA','REITORIA','ADMIN','PATRIMONIO','ALMOXARIFADO'));
alter table public.determinacoes drop constraint if exists determinacoes_situacao_check;
alter table public.determinacoes add constraint determinacoes_situacao_check check (situacao in ('PROPOSTA','ABERTA','ATENDIDA','CANCELADA','RECUSADA'));
alter table public.determinacoes add column if not exists proposto_por uuid references public.perfis(id);
alter table public.determinacoes add column if not exists proposto_papel text;
alter table public.determinacoes add column if not exists proposto_em timestamptz;
alter table public.determinacoes add column if not exists assinatura jsonb;
alter table public.determinacoes add column if not exists motivo_recusa text;

-- valida itens e devolve a lista normalizada + resumo em HTML
create or replace function public._det_itens(p_itens jsonb, out itens jsonb, out resumo text)
language plpgsql security definer set search_path = '' as $$
declare it jsonb; v_desc text; v_disp int;
begin
  itens := '[]'::jsonb; resumo := '';
  if jsonb_array_length(coalesce(p_itens, '[]'::jsonb)) = 0 then raise exception 'Informe ao menos um bem a destinar.'; end if;
  for it in select * from jsonb_array_elements(p_itens) loop
    select descricao into v_desc from public.materiais where id = (it->>'material_id')::uuid;
    if v_desc is null then raise exception 'Material não encontrado.'; end if;
    if coalesce((it->>'quantidade')::int, 0) <= 0 then raise exception 'Quantidade inválida para "%".', v_desc; end if;
    v_disp := public.disponivel((it->>'material_id')::uuid);
    if (it->>'quantidade')::int > v_disp then raise exception 'Só há % disponíveis de "%".', v_disp, v_desc; end if;
    itens := itens || jsonb_build_array(jsonb_build_object('material_id', it->>'material_id', 'descricao', v_desc, 'quantidade', (it->>'quantidade')::int));
    resumo := resumo || '<li>' || (it->>'quantidade') || ' × ' || v_desc || '</li>';
  end loop;
end $$;

create or replace function public._det_numero() returns text
language plpgsql security definer set search_path = '' as $$
declare v_ano int := extract(year from now())::int;
begin
  perform pg_advisory_xact_lock(hashtext('destina_determinacao'));
  return 'DT ' || lpad(((select count(*) from public.determinacoes where extract(year from criado_em) = v_ano) + 1)::text, 4, '0') || '/' || v_ano;
end $$;

-- proposta: DIPA, Almoxarifado ou gestor
create or replace function public.propor_destinacao(p_papel text, p_dados jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_num text; v jsonb; v_res text; f record; v_notif int := 0; v_quem text; c jsonb := public._cfg();
begin
  perform public._exigir(p_papel, array['PATRIMONIO','ALMOXARIFADO','ADMIN']);
  if coalesce(trim(p_dados->>'unidade'), '') = '' then raise exception 'Informe a unidade de destino.'; end if;
  select x.itens, x.resumo into v, v_res from public._det_itens(p_dados->'itens') x;
  v_num := public._det_numero();
  insert into public.determinacoes (numero, papel, autor, unidade, unidade_code, itens, observacao, origem, situacao, proposto_por, proposto_papel, proposto_em)
  values (v_num, p_papel, auth.uid(), trim(p_dados->>'unidade'), coalesce(p_dados->>'unidadeCode', ''), v, coalesce(p_dados->>'observacao', ''),
          coalesce(nullif(p_dados->>'origem', ''), 'tela'), 'PROPOSTA', auth.uid(), p_papel, now())
  returning id into v_id;
  select coalesce(nome, '') into v_quem from public.perfis where id = auth.uid();
  for f in select u.email, coalesce(p.nome, u.email) as nome from public.perfis p join auth.users u on u.id = p.id
           where p.aprovado and (p.papeis && array['REITORIA','PRA']) and u.email is not null loop
    if public._enviar_email(f.email, f.nome, 'Destinação aguardando a sua decisão · ' || v_num,
         public._email_html('Destinação aguardando a sua decisão',
           '<p>' || coalesce(nullif(v_quem, ''), 'Um servidor') || ' propôs a destinação abaixo para <b>' || trim(p_dados->>'unidade') || '</b>:</p><ul>' || v_res || '</ul>'
           || '<p>O plano só é iniciado depois da sua assinatura no Destina.</p>',
           'Analisar a proposta', public._url_sistema() || '#planos'), 'proposta_destinacao', null) then v_notif := v_notif + 1; end if;
  end loop;
  return jsonb_build_object('determinacao_id', v_id, 'determinacao', v_num, 'notificados', v_notif,
    'decisores', (select count(*) from public.perfis where aprovado and papeis && array['REITORIA','PRA']));
end $$;

-- decisão assinada: nova (p_dados com unidade/itens) ou sobre uma proposta (p_dados->>'proposta_id')
drop function if exists public.registrar_determinacao(text, jsonb);
create or replace function public.registrar_determinacao(p_papel text, p_dados jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_det uuid; v_num text; v_plano uuid; v_pnum text; v_ano int := extract(year from now())::int; it jsonb;
        v_itens jsonb; v_res text; c jsonb := public._cfg(); v_cargo text; f record; v_notif int := 0; v_link text;
        v_senha timestamptz := public._senha_recente(); v_cod public.assinatura_codigos; v_email text; v_nome text; v_ev jsonb;
        d public.determinacoes; v_uni text; v_unic text; v_obs text; v_origem text;
begin
  perform public._exigir(p_papel, array['PRA','REITORIA']);
  -- assinatura: mesma confirmação de identidade dos termos de autorização
  if v_senha is null then raise exception 'DESTINA_CONFIRMAR_SENHA: confirme a sua senha para assinar a decisão.'; end if;
  if public._email_ativo() then
    select * into v_cod from public.assinatura_codigos
      where usuario = auth.uid() and papel = p_papel and conferido_em is not null and expira_em > now()
      order by conferido_em desc limit 1;
    if not found then raise exception 'DESTINA_CODIGO: confirme o código enviado ao seu e-mail.'; end if;
  end if;

  if nullif(p_dados->>'proposta_id', '') is not null then
    select * into d from public.determinacoes where id = (p_dados->>'proposta_id')::uuid for update;
    if not found or d.situacao <> 'PROPOSTA' then raise exception 'Esta proposta não está mais aguardando decisão.'; end if;
    v_uni := d.unidade; v_unic := d.unidade_code; v_obs := d.observacao; v_origem := d.origem;
    select x.itens, x.resumo into v_itens, v_res from public._det_itens(coalesce(p_dados->'itens', d.itens)) x;
  else
    if coalesce(trim(p_dados->>'unidade'), '') = '' then raise exception 'Informe a unidade de destino.'; end if;
    v_uni := trim(p_dados->>'unidade'); v_unic := coalesce(p_dados->>'unidadeCode', ''); v_obs := coalesce(p_dados->>'observacao', ''); v_origem := coalesce(nullif(p_dados->>'origem', ''), 'tela');
    select x.itens, x.resumo into v_itens, v_res from public._det_itens(p_dados->'itens') x;
  end if;
  v_cargo := coalesce(c->'signatarios'->p_papel->>'cargo', p_papel);

  select u.email, coalesce(p.nome, u.email) into v_email, v_nome from auth.users u left join public.perfis p on p.id = u.id where u.id = auth.uid();
  v_ev := jsonb_strip_nulls(jsonb_build_object(
    'assinado_em', (extract(epoch from now()) * 1000)::bigint,
    'por', auth.uid(), 'nome', v_nome, 'cargo', v_cargo, 'papel', p_papel,
    'senha_confirmada_em', (extract(epoch from v_senha) * 1000)::bigint,
    'codigo_email', v_cod.id is not null,
    'codigo_conferido_em', case when v_cod.id is not null then (extract(epoch from v_cod.conferido_em) * 1000)::bigint end,
    'email', public._mascarar_email(v_email),
    'hash', public._sha(v_uni || '|' || v_itens::text || '|' || auth.uid()::text || '|' || now()::text)));

  -- 1) determinação (nova ou a proposta)
  if d.id is null then
    v_num := public._det_numero();
    insert into public.determinacoes (numero, papel, autor, unidade, unidade_code, itens, observacao, origem, assinatura)
    values (v_num, p_papel, auth.uid(), v_uni, v_unic, v_itens, v_obs, v_origem, v_ev)
    returning id into v_det;
  else
    v_det := d.id; v_num := d.numero;
    update public.determinacoes set papel = p_papel, autor = auth.uid(), itens = v_itens, assinatura = v_ev, atualizado_em = now() where id = v_det;
  end if;

  -- 2) plano iniciado e enviado para instrução
  v_pnum := 'PD ' || lpad(public._proximo(v_ano)::text, 4, '0') || '/' || v_ano;
  insert into public.planos (numero, unidade, unidade_code, orgao_code, finalidade, justificativa, demanda, criado_por)
  values (v_pnum, v_uni, nullif(v_unic, ''), nullif(p_dados->>'orgaoCode', ''),
          left('Determinação ' || v_num, 70),
          'Destinação determinada por decisão assinada — ' || v_cargo || ' (' || v_num || ', ' || to_char(now() at time zone 'America/Fortaleza', 'DD/MM/YYYY') || ').'
            || case when d.id is not null then ' Proposta de ' || coalesce((select nome from public.perfis where id = d.proposto_por), d.proposto_papel) || '.' else '' end
            || case when coalesce(v_obs, '') <> '' then ' ' || v_obs else '' end,
          v_num, auth.uid())
  returning id into v_plano;
  insert into public.plano_etapas (plano_id, status) values (v_plano, 'RASCUNHO');
  for it in select * from jsonb_array_elements(v_itens) loop
    insert into public.plano_itens (plano_id, material_id, qtd, vu, codigo, descricao)
    select v_plano, m.id, (it->>'quantidade')::int, public.valor_medio(m.id), m.codigo, m.descricao from public.materiais m where m.id = (it->>'material_id')::uuid;
  end loop;
  if d.id is not null then
    perform public._evento(v_plano, d.proposto_papel, 'proposta', 'Destinação proposta por ' || coalesce((select nome from public.perfis where id = d.proposto_por), d.proposto_papel) || ' (' || v_num || ')');
  end if;
  perform public._evento(v_plano, p_papel, 'assinatura', 'Decisão assinada eletronicamente — ' || v_cargo || ' (' || v_num || '). Plano iniciado' || case when v_origem = 'chat' then ' pelo assistente' else '' end);
  perform public._validar_saldo(v_plano);
  perform public._etapa(v_plano, 'INSTRUCAO');
  perform public._evento(v_plano, p_papel, 'envio', 'Enviado para instrução documental (Formalização)');
  update public.determinacoes set situacao = 'ATENDIDA', plano_id = v_plano, atualizado_em = now() where id = v_det;

  -- 3) e-mail para quem formaliza
  v_link := public._url_sistema() || '#plano-' || v_plano;
  for f in select u.email, coalesce(p.nome, u.email) as nome from public.perfis p join auth.users u on u.id = p.id
           where p.aprovado and 'FORMALIZACAO' = any(p.papeis) and u.email is not null loop
    if public._enviar_email(f.email, f.nome, 'Nova destinação para formalizar · ' || v_pnum,
         public._email_html('Nova destinação para formalizar',
           '<p>Por decisão assinada de <b>' || v_cargo || '</b>, foi determinada a destinação abaixo para <b>' || v_uni || '</b>. O plano <b>' || v_pnum || '</b> já está em instrução documental.</p><ul>' || v_res || '</ul>'
           || case when coalesce(v_obs, '') <> '' then '<p><i>' || v_obs || '</i></p>' else '' end,
           'Abrir o plano ' || v_pnum, v_link), 'nova_destinacao', v_plano) then v_notif := v_notif + 1; end if;
  end loop;
  -- aviso a quem propôs
  if d.id is not null then
    for f in select u.email, coalesce(p.nome, u.email) as nome from public.perfis p join auth.users u on u.id = p.id where p.id = d.proposto_por and u.email is not null loop
      perform public._enviar_email(f.email, f.nome, 'Sua proposta foi aprovada · ' || v_pnum,
        public._email_html('Proposta aprovada', '<p>' || v_cargo || ' assinou a decisão da proposta ' || v_num || '. O plano <b>' || v_pnum || '</b> foi iniciado.</p>', 'Acompanhar o plano', v_link), 'proposta_aprovada', v_plano);
    end loop;
  end if;

  return jsonb_build_object('determinacao_id', v_det, 'determinacao', v_num, 'plano_id', v_plano, 'plano', v_pnum, 'notificados', v_notif,
    'formalizadores', (select count(*) from public.perfis where aprovado and 'FORMALIZACAO' = any(papeis)));
end $$;

-- recusar uma proposta (Reitoria/PRA) ou retirá-la (quem propôs / gestor)
create or replace function public.recusar_proposta(p_papel text, p_id uuid, p_motivo text) returns void
language plpgsql security definer set search_path = '' as $$
declare d public.determinacoes; f record; c jsonb := public._cfg();
begin
  perform public._exigir(p_papel, array['PRA','REITORIA','PATRIMONIO','ALMOXARIFADO','ADMIN']);
  select * into d from public.determinacoes where id = p_id for update;
  if not found or d.situacao <> 'PROPOSTA' then raise exception 'Esta proposta não está mais aguardando decisão.'; end if;
  if p_papel in ('PRA','REITORIA') then
    if coalesce(trim(p_motivo), '') = '' then raise exception 'Informe o motivo da recusa.'; end if;
    update public.determinacoes set situacao = 'RECUSADA', motivo_recusa = trim(p_motivo), atualizado_em = now() where id = p_id;
    for f in select u.email, coalesce(p.nome, u.email) as nome from public.perfis p join auth.users u on u.id = p.id where p.id = d.proposto_por and u.email is not null loop
      perform public._enviar_email(f.email, f.nome, 'Proposta não aprovada · ' || d.numero,
        public._email_html('Proposta não aprovada', '<p>' || coalesce(c->'signatarios'->p_papel->>'cargo', p_papel) || ' não aprovou a proposta ' || d.numero || ' para ' || d.unidade || '.</p><p><i>' || trim(p_motivo) || '</i></p>'), 'proposta_recusada', null);
    end loop;
  else
    if d.proposto_por <> auth.uid() and p_papel <> 'ADMIN' then raise exception 'Só quem propôs (ou o gestor) pode retirar a proposta.'; end if;
    update public.determinacoes set situacao = 'CANCELADA', motivo_recusa = coalesce(nullif(trim(p_motivo), ''), 'Retirada por quem propôs'), atualizado_em = now() where id = p_id;
  end if;
end $$;

revoke all on function public._det_itens(jsonb), public._det_numero() from public, anon, authenticated;
revoke all on function public.propor_destinacao(text, jsonb), public.registrar_determinacao(text, jsonb), public.recusar_proposta(text, uuid, text) from public, anon, authenticated;
grant execute on function public.propor_destinacao(text, jsonb), public.registrar_determinacao(text, jsonb), public.recusar_proposta(text, uuid, text) to authenticated;
