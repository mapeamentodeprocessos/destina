-- Destina · 08 · a decisão da Reitora / do Pró-Reitor inicia o plano de destinação
-- Ao registrar a determinação, o sistema já cria o plano e o envia para a instrução documental
-- (Formalização). Os servidores com perfil Formalização recebem e-mail (quando o envio estiver ligado).
-- Rode depois de 01 a 07. Pode ser rodado de novo sem problema.

drop function if exists public.registrar_determinacao(text, jsonb);
create or replace function public.registrar_determinacao(p_papel text, p_dados jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_det uuid; v_num text; v_plano uuid; v_pnum text; v_ano int := extract(year from now())::int; it jsonb; v_disp int; v_desc text;
        v_itens jsonb := '[]'::jsonb; c jsonb := public._cfg(); v_cargo text; v_resumo text := ''; f record; v_notif int := 0; v_link text;
begin
  perform public._exigir(p_papel, array['PRA','REITORIA','ADMIN']);
  if coalesce(trim(p_dados->>'unidade'), '') = '' then raise exception 'Informe a unidade de destino.'; end if;
  if jsonb_array_length(coalesce(p_dados->'itens', '[]'::jsonb)) = 0 then raise exception 'Informe ao menos um bem a destinar.'; end if;
  for it in select * from jsonb_array_elements(p_dados->'itens') loop
    select descricao into v_desc from public.materiais where id = (it->>'material_id')::uuid;
    if v_desc is null then raise exception 'Material não encontrado.'; end if;
    if coalesce((it->>'quantidade')::int, 0) <= 0 then raise exception 'Quantidade inválida para "%".', v_desc; end if;
    v_disp := public.disponivel((it->>'material_id')::uuid);
    if (it->>'quantidade')::int > v_disp then raise exception 'Só há % disponíveis de "%".', v_disp, v_desc; end if;
    v_itens := v_itens || jsonb_build_array(jsonb_build_object('material_id', it->>'material_id', 'descricao', v_desc, 'quantidade', (it->>'quantidade')::int));
    v_resumo := v_resumo || '<li>' || (it->>'quantidade') || ' × ' || v_desc || '</li>';
  end loop;
  v_cargo := coalesce(c->'signatarios'->p_papel->>'cargo', case p_papel when 'ADMIN' then 'Gestão do sistema' else p_papel end);

  -- 1) determinação
  perform pg_advisory_xact_lock(hashtext('destina_determinacao'));
  v_num := 'DT ' || lpad(((select count(*) from public.determinacoes where extract(year from criado_em) = v_ano) + 1)::text, 4, '0') || '/' || v_ano;
  insert into public.determinacoes (numero, papel, autor, unidade, unidade_code, itens, observacao, origem)
  values (v_num, p_papel, auth.uid(), trim(p_dados->>'unidade'), coalesce(p_dados->>'unidadeCode', ''), v_itens, coalesce(p_dados->>'observacao', ''), coalesce(nullif(p_dados->>'origem', ''), 'tela'))
  returning id into v_det;

  -- 2) plano criado e enviado para instrução
  v_pnum := 'PD ' || lpad(public._proximo(v_ano)::text, 4, '0') || '/' || v_ano;
  insert into public.planos (numero, unidade, unidade_code, orgao_code, finalidade, justificativa, demanda, criado_por)
  values (v_pnum, trim(p_dados->>'unidade'), nullif(p_dados->>'unidadeCode', ''), nullif(p_dados->>'orgaoCode', ''),
          left('Determinação ' || v_num, 70),
          'Destinação determinada pela ' || v_cargo || ' (' || v_num || ', ' || to_char(now() at time zone 'America/Fortaleza', 'DD/MM/YYYY') || ').' || case when coalesce(p_dados->>'observacao', '') <> '' then ' ' || (p_dados->>'observacao') else '' end,
          v_num, auth.uid())
  returning id into v_plano;
  insert into public.plano_etapas (plano_id, status) values (v_plano, 'RASCUNHO');
  for it in select * from jsonb_array_elements(v_itens) loop
    insert into public.plano_itens (plano_id, material_id, qtd, vu, codigo, descricao)
    select v_plano, m.id, (it->>'quantidade')::int, public.valor_medio(m.id), m.codigo, m.descricao from public.materiais m where m.id = (it->>'material_id')::uuid;
  end loop;
  perform public._evento(v_plano, p_papel, 'criacao', 'Plano iniciado pela decisão da ' || v_cargo || ' (' || v_num || ')' || case when p_dados->>'origem' = 'chat' then ' pelo assistente' else '' end);
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
           '<p>A <b>' || v_cargo || '</b> determinou a destinação abaixo para <b>' || trim(p_dados->>'unidade') || '</b>. O plano <b>' || v_pnum || '</b> já está em instrução documental e aguarda a formalização (processo SIPAC e documentos).</p><ul>' || v_resumo || '</ul>'
           || case when coalesce(p_dados->>'observacao', '') <> '' then '<p><i>' || (p_dados->>'observacao') || '</i></p>' else '' end,
           'Abrir o plano ' || v_pnum, v_link), 'nova_destinacao', v_plano) then v_notif := v_notif + 1; end if;
  end loop;

  return jsonb_build_object('determinacao_id', v_det, 'determinacao', v_num, 'plano_id', v_plano, 'plano', v_pnum, 'notificados', v_notif,
    'formalizadores', (select count(*) from public.perfis where aprovado and 'FORMALIZACAO' = any(papeis)));
end $$;

revoke all on function public.registrar_determinacao(text, jsonb) from public, anon, authenticated;
grant execute on function public.registrar_determinacao(text, jsonb) to authenticated;
