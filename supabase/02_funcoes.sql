-- =====================================================================
-- DESTINA — 02_funcoes.sql — rode DEPOIS do 01_schema.sql
-- Todas as gravações do app passam por estas funções (RPC).
-- Cada função recebe o perfil ativo (p_papel) e confere no servidor se o
-- usuário realmente tem esse perfil e se a etapa do plano permite a ação.
-- =====================================================================

-- ---------- utilitários internos ----------
create or replace function public._exigir(p_papel text, permitidos text[]) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null or not public.aprovado() then
    raise exception 'Seu acesso ainda não foi aprovado pelo gestor do sistema.';
  end if;
  if p_papel is null or not (p_papel = any(permitidos)) or not public.tem_papel(p_papel) then
    raise exception 'O perfil "%" não pode executar esta ação.', coalesce(p_papel, '—');
  end if;
end $$;

create or replace function public._evento(p_plano uuid, p_papel text, p_tipo text, p_msg text) returns void
language sql security definer set search_path = '' as $$
  insert into public.eventos (plano_id, por, papel, tipo, msg) values (p_plano, auth.uid(), p_papel, p_tipo, p_msg);
$$;

create or replace function public._etapa(p_plano uuid, p_status text) returns void
language sql security definer set search_path = '' as $$
  update public.planos set status = p_status, etapa_em = now() where id = p_plano;
  insert into public.plano_etapas (plano_id, status) values (p_plano, p_status);
$$;

create or replace function public._plano(p_id uuid, p_status text[]) returns public.planos
language plpgsql security definer set search_path = '' as $$
declare r public.planos;
begin
  select * into r from public.planos where id = p_id for update;
  if not found then raise exception 'Plano não encontrado.'; end if;
  if r.legado then raise exception 'Registros históricos não podem ser alterados.'; end if;
  if p_status is not null and not (r.status = any(p_status)) then
    raise exception 'O plano % está em "%", e esta ação não se aplica a essa etapa.', r.numero, r.status;
  end if;
  return r;
end $$;

create or replace function public._proximo(p_ano int) returns int
language sql security definer set search_path = '' as $$
  insert into public.contadores (ano, ultimo) values (p_ano, 1)
  on conflict (ano) do update set ultimo = public.contadores.ultimo + 1
  returning ultimo;
$$;

-- Valor unitário médio dos lotes com valor
create or replace function public.valor_medio(p_material uuid) returns numeric
language sql stable security definer set search_path = '' as $$
  select coalesce(round(sum(qtd * vu) / nullif(sum(qtd), 0), 2), 0) from public.lotes where material_id = p_material and vu > 0;
$$;

-- Saldo livre: recebido − tudo o que está em trâmite, reservado ou entregue
create or replace function public.disponivel(p_material uuid, p_excluir uuid default null) returns int
language sql stable security definer set search_path = '' as $$
  select coalesce((select sum(qtd) from public.lotes where material_id = p_material), 0)::int
       - coalesce((select sum(i.qtd) from public.plano_itens i join public.planos p on p.id = i.plano_id
                   where i.material_id = p_material and p.status in ('INSTRUCAO','AUTORIZACAO','AUTORIZADO','SEPARACAO','PRONTO','ENTREGUE')
                     and (p_excluir is null or p.id <> p_excluir)), 0)::int;
$$;

create or replace function public._validar_saldo(p_plano uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r record; d int;
begin
  perform pg_advisory_xact_lock(7413);   -- serializa reservas de saldo
  for r in select i.material_id, i.qtd, coalesce(m.descricao, i.descricao) as descricao from public.plano_itens i left join public.materiais m on m.id = i.material_id where i.plano_id = p_plano loop
    d := public.disponivel(r.material_id, p_plano);
    if r.qtd > d then raise exception 'Saldo insuficiente de "%": pedido %, disponível %.', r.descricao, r.qtd, greatest(d, 0); end if;
  end loop;
end $$;

-- Texto canônico do termo: base do hash do documento
create or replace function public.doc_canonico(p_plano uuid) returns text
language sql stable security definer set search_path = '' as $$
  select concat_ws('|', p.numero, p.unidade, coalesce(p.unidade_code, ''), p.finalidade, p.justificativa, coalesce(p.processo, ''), coalesce(p.fundamentacao, ''),
         array_to_string(p.assinaturas_exigidas, ','),
         (select string_agg(coalesce(i.codigo, '') || ':' || i.qtd || ':' || i.vu, ';' order by i.codigo, i.material_id) from public.plano_itens i where i.plano_id = p.id),
         (select coalesce(sum(i.qtd * i.vu), 0) from public.plano_itens i where i.plano_id = p.id))
  from public.planos p where p.id = p_plano;
$$;
create or replace function public._sha(t text) returns text
language sql immutable set search_path = '' as $$ select encode(extensions.digest(t, 'sha256'), 'hex') $$;

create or replace function public._cfg() returns jsonb
language sql stable security definer set search_path = '' as $$ select dados from public.config where id = 1 $$;

-- ---------- perfis ----------
create or replace function public.existe_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.perfis where aprovado and 'ADMIN' = any(papeis));
$$;

-- O primeiro usuário a chamar esta função vira administrador (só funciona enquanto não houver nenhum)
create or replace function public.reivindicar_admin() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Entre com sua conta primeiro.'; end if;
  perform pg_advisory_xact_lock(7414);
  if public.existe_admin() then raise exception 'O sistema já tem um administrador. Peça a ele a aprovação do seu acesso.'; end if;
  update public.perfis set aprovado = true, papeis = array['ADMIN'] where id = auth.uid();
end $$;

create or replace function public.definir_perfil(p_usuario uuid, p_papeis text[], p_aprovado boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.tem_papel('ADMIN') then raise exception 'Somente o gestor do sistema altera perfis.'; end if;
  update public.perfis set papeis = coalesce(p_papeis, '{}'), aprovado = p_aprovado where id = p_usuario;
  if not public.existe_admin() then raise exception 'O sistema precisa manter pelo menos um administrador aprovado.'; end if;
end $$;

create or replace function public.atualizar_meu_nome(p_nome text) returns void
language sql security definer set search_path = '' as $$
  update public.perfis set nome = left(trim(p_nome), 120) where id = auth.uid();
$$;

-- ---------- configuração e estrutura ----------
create or replace function public.salvar_config(p_dados jsonb) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.tem_papel('ADMIN') then raise exception 'Somente o gestor do sistema altera as configurações.'; end if;
  update public.config set dados = p_dados, atualizado_em = now() where id = 1;
end $$;

create or replace function public.substituir_unidades(p_lista jsonb, p_fonte text, p_data text) returns int
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  if not public.tem_papel('ADMIN') then raise exception 'Somente o gestor do sistema altera a estrutura.'; end if;
  create temp table _u on commit drop as
    select (e->>0) as code, (e->>1) as name, nullif(e->>2, '') as parent_code, (ord - 1)::int as ordem
    from jsonb_array_elements(p_lista) with ordinality as t(e, ord);
  insert into public.unidades (code, name, parent_code, ordem)
    select code, name, parent_code, ordem from _u
    on conflict (code) do update set name = excluded.name, parent_code = excluded.parent_code, ordem = excluded.ordem;
  -- unidades que saíram da estrutura: removidas se nenhum plano aponta para elas
  delete from public.unidades u where not exists (select 1 from _u where _u.code = u.code)
    and not exists (select 1 from public.planos p where p.unidade_code = u.code);
  insert into public.estrutura_meta (id, fonte, atualizado_em) values (1, p_fonte, p_data)
    on conflict (id) do update set fonte = excluded.fonte, atualizado_em = excluded.atualizado_em;
  select count(*) into n from _u; return n;
end $$;

-- ---------- materiais e entradas ----------
create or replace function public.salvar_material(p_papel text, p_id uuid, p_dados jsonb) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_ano int := extract(year from now())::int;
begin
  perform public._exigir(p_papel, array['PATRIMONIO','ALMOXARIFADO','ADMIN']);
  if coalesce(trim(p_dados->>'descricao'), '') = '' then raise exception 'Informe a descrição do material.'; end if;
  if p_id is null then
    insert into public.materiais (codigo, descricao, especificacao, categoria, unidade_medida, localizacao, marca, modelo, fornecedor, garantia_ate, exige_tombamento, foto, obs, origem, criado_por)
    values ('RT-' || v_ano || '-' || lpad(public._proximo(-v_ano)::text, 4, '0'), trim(p_dados->>'descricao'), coalesce(p_dados->>'especificacao', ''), coalesce(p_dados->>'categoria', 'Outros'),
            coalesce(nullif(p_dados->>'unidadeMedida', ''), 'UNIDADE'), coalesce(p_dados->>'localizacao', ''), coalesce(p_dados->>'marca', ''), coalesce(p_dados->>'modelo', ''),
            coalesce(p_dados->>'fornecedor', ''), nullif(p_dados->>'garantiaAte', '')::date, coalesce((p_dados->>'exigeTombamento')::boolean, true), p_dados->>'foto',
            coalesce(p_dados->>'obs', ''), coalesce(p_dados->>'origem', ''), auth.uid())
    returning id into v_id;
  else
    update public.materiais set descricao = trim(p_dados->>'descricao'), especificacao = coalesce(p_dados->>'especificacao', ''), categoria = coalesce(p_dados->>'categoria', 'Outros'),
      unidade_medida = coalesce(nullif(p_dados->>'unidadeMedida', ''), 'UNIDADE'), localizacao = coalesce(p_dados->>'localizacao', ''), marca = coalesce(p_dados->>'marca', ''),
      modelo = coalesce(p_dados->>'modelo', ''), fornecedor = coalesce(p_dados->>'fornecedor', ''), garantia_ate = nullif(p_dados->>'garantiaAte', '')::date,
      exige_tombamento = coalesce((p_dados->>'exigeTombamento')::boolean, true), foto = p_dados->>'foto', obs = coalesce(p_dados->>'obs', ''), atualizado_em = now()
    where id = p_id returning id into v_id;
    if v_id is null then raise exception 'Material não encontrado.'; end if;
  end if;
  return v_id;
exception when unique_violation then
  raise exception 'Já existe um material com essa descrição. Registre a entrada no material existente.';
end $$;

-- Registra um lote. Se p_material for nulo, procura pelo nome (ignorando espaços e maiúsculas) ou cadastra.
create or replace function public.registrar_entrada(p_papel text, p_material uuid, p_dados_material jsonb, p_lote jsonb) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid := p_material;
begin
  perform public._exigir(p_papel, array['PATRIMONIO','ALMOXARIFADO','ADMIN']);
  if v_id is null then
    select id into v_id from public.materiais where upper(regexp_replace(trim(descricao), '\s+', ' ', 'g')) = upper(regexp_replace(trim(p_dados_material->>'descricao'), '\s+', ' ', 'g'));
    if v_id is null then v_id := public.salvar_material(p_papel, null, p_dados_material); end if;
  end if;
  if coalesce((p_lote->>'qtd')::int, 0) <= 0 then raise exception 'Informe uma quantidade maior que zero.'; end if;
  insert into public.lotes (material_id, data, qtd, vu, pregao, requisicao, empenho, processo, nf, obs, origem, criado_por)
  values (v_id, coalesce(nullif(p_lote->>'data', '')::date, current_date), (p_lote->>'qtd')::int, coalesce(nullif(p_lote->>'vu', '')::numeric, 0),
          coalesce(p_lote->>'pregao', ''), coalesce(p_lote->>'requisicao', ''), coalesce(p_lote->>'empenho', ''), coalesce(p_lote->>'processo', ''),
          coalesce(p_lote->>'nf', ''), coalesce(p_lote->>'obs', ''), coalesce(p_lote->>'origem', ''), auth.uid());
  update public.materiais set atualizado_em = now() where id = v_id;
  return v_id;
end $$;

create or replace function public.excluir_material(p_papel text, p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public._exigir(p_papel, array['PATRIMONIO','ALMOXARIFADO','ADMIN']);
  if exists (select 1 from public.plano_itens where material_id = p_id) then raise exception 'Este material já foi usado em planos e não pode ser excluído.'; end if;
  delete from public.materiais where id = p_id;
end $$;

-- ---------- planos de destinação ----------
create or replace function public.salvar_plano(p_papel text, p_id uuid, p_dados jsonb, p_enviar boolean) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid := p_id; v_ano int := extract(year from now())::int; r public.planos; it jsonb; n int;
begin
  perform public._exigir(p_papel, array['PATRIMONIO','ALMOXARIFADO','FORMALIZACAO','ADMIN']);
  if coalesce(trim(p_dados->>'unidade'), '') = '' then raise exception 'Escolha a unidade de destino.'; end if;
  if jsonb_array_length(coalesce(p_dados->'itens', '[]'::jsonb)) = 0 then raise exception 'Adicione pelo menos um bem ao plano.'; end if;
  if v_id is null then
    insert into public.planos (numero, unidade, unidade_code, orgao_code, finalidade, justificativa, demanda, criado_por)
    values ('PD ' || lpad(public._proximo(v_ano)::text, 4, '0') || '/' || v_ano, trim(p_dados->>'unidade'), nullif(p_dados->>'unidadeCode', ''), nullif(p_dados->>'orgaoCode', ''),
            coalesce(p_dados->>'finalidade', ''), coalesce(p_dados->>'justificativa', ''), coalesce(p_dados->>'demanda', ''), auth.uid())
    returning id into v_id;
    insert into public.plano_etapas (plano_id, status) values (v_id, 'RASCUNHO');
    perform public._evento(v_id, p_papel, 'criacao', case when (p_dados->>'origemAssistente')::boolean then 'Plano de destinação criado a partir de sugestão do assistente' else 'Plano de destinação criado' end);
  else
    r := public._plano(v_id, array['RASCUNHO']);
    update public.planos set unidade = trim(p_dados->>'unidade'), unidade_code = nullif(p_dados->>'unidadeCode', ''), orgao_code = nullif(p_dados->>'orgaoCode', ''),
      finalidade = coalesce(p_dados->>'finalidade', ''), justificativa = coalesce(p_dados->>'justificativa', ''), demanda = coalesce(p_dados->>'demanda', ''), devolucao = null
    where id = v_id;
    delete from public.plano_itens where plano_id = v_id;
  end if;
  for it in select * from jsonb_array_elements(p_dados->'itens') loop
    insert into public.plano_itens (plano_id, material_id, qtd, vu, codigo, descricao)
    select v_id, m.id, greatest(1, (it->>'qtd')::int), public.valor_medio(m.id), m.codigo, m.descricao from public.materiais m where m.id = (it->>'itemId')::uuid;
  end loop;
  select count(*) into n from public.plano_itens where plano_id = v_id;
  if n = 0 then raise exception 'Nenhum dos bens informados existe na reserva.'; end if;
  if p_id is not null then
    perform public._evento(v_id, p_papel, 'edicao', 'Plano editado · ' || (select sum(qtd) from public.plano_itens where plano_id = v_id) || ' bem(ns)');
  end if;
  if p_enviar then perform public.enviar_instrucao(p_papel, v_id); end if;
  return v_id;
end $$;

create or replace function public.enviar_instrucao(p_papel text, p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public._exigir(p_papel, array['PATRIMONIO','ALMOXARIFADO','FORMALIZACAO','ADMIN']);
  perform public._plano(p_id, array['RASCUNHO']);
  perform public._validar_saldo(p_id);
  update public.planos set devolucao = null where id = p_id;
  perform public._etapa(p_id, 'INSTRUCAO');
  perform public._evento(p_id, p_papel, 'envio', 'Enviado para instrução documental');
end $$;

create or replace function public.devolver_plano(p_papel text, p_id uuid, p_motivo text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public._exigir(p_papel, array['FORMALIZACAO','ADMIN']);
  perform public._plano(p_id, array['INSTRUCAO']);
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Descreva o ajuste necessário.'; end if;
  update public.planos set devolucao = trim(p_motivo) where id = p_id;
  perform public._etapa(p_id, 'RASCUNHO');
  perform public._evento(p_id, p_papel, 'devolucao', 'Devolvido para ajustes: ' || trim(p_motivo));
end $$;

create or replace function public.formalizar_plano(p_papel text, p_id uuid, p_processo text, p_fundamentacao text, p_despacho text) returns void
language plpgsql security definer set search_path = '' as $$
declare c jsonb := public._cfg(); v_total numeric; v_exig text[];
begin
  perform public._exigir(p_papel, array['FORMALIZACAO','ADMIN']);
  perform public._plano(p_id, array['INSTRUCAO']);
  if coalesce(trim(p_processo), '') = '' then raise exception 'Informe o número do processo.'; end if;
  perform public._validar_saldo(p_id);
  select coalesce(sum(qtd * vu), 0) into v_total from public.plano_itens where plano_id = p_id;
  v_exig := case when coalesce((c->>'exigirAmbos')::boolean, false) or v_total > coalesce((c->>'limiteAlcada')::numeric, 50000) then array['PRA','REITORIA'] else array['PRA'] end;
  update public.planos set processo = trim(p_processo), fundamentacao = coalesce(p_fundamentacao, ''), despacho = coalesce(p_despacho, ''), assinaturas_exigidas = v_exig where id = p_id;
  update public.planos set doc_hash = public._sha(public.doc_canonico(p_id)) where id = p_id;
  perform public._etapa(p_id, 'AUTORIZACAO');
  perform public._evento(p_id, p_papel, 'formalizacao', 'Instrução concluída e submetida à autorização · Processo ' || trim(p_processo));
end $$;

create or replace function public.assinar_plano(p_papel text, p_id uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare r public.planos; c jsonb := public._cfg(); v_pend text[]; v_sig text; v_em timestamptz := now();
begin
  perform public._exigir(p_papel, array['PRA','REITORIA']);
  r := public._plano(p_id, array['AUTORIZACAO']);
  if not (p_papel = any(r.assinaturas_exigidas)) then raise exception 'Este plano não exige a assinatura deste perfil.'; end if;
  if exists (select 1 from public.assinaturas where plano_id = p_id and papel = p_papel) then raise exception 'Este perfil já assinou o plano.'; end if;
  select array_agg(x order by ord) into v_pend from unnest(r.assinaturas_exigidas) with ordinality as t(x, ord)
    where not exists (select 1 from public.assinaturas a where a.plano_id = p_id and a.papel = x);
  if coalesce((c->>'sequencial')::boolean, true) and v_pend[1] <> p_papel then raise exception 'Aguarde a assinatura de % antes.', v_pend[1]; end if;
  if public._sha(public.doc_canonico(p_id)) <> r.doc_hash then raise exception 'O conteúdo do termo mudou depois da formalização. Indefira e peça nova instrução.'; end if;
  v_sig := public._sha(r.doc_hash || '|' || auth.uid() || '|' || p_papel || '|' || (extract(epoch from v_em) * 1000)::bigint);
  insert into public.assinaturas (plano_id, papel, por, em, doc_hash, sig, nome, cargo)
  values (p_id, p_papel, auth.uid(), v_em, r.doc_hash, v_sig, c->'signatarios'->p_papel->>'nome', c->'signatarios'->p_papel->>'cargo');
  perform public._evento(p_id, p_papel, 'assinatura', 'Autorização assinada eletronicamente por ' || coalesce(c->'signatarios'->p_papel->>'cargo', p_papel) || ' · código ' || upper(substr(v_sig, 1, 4) || '-' || substr(v_sig, 5, 4) || '-' || substr(v_sig, 9, 4)));
  if array_length(v_pend, 1) = 1 then
    perform public._etapa(p_id, 'AUTORIZADO');
    perform public._evento(p_id, p_papel, 'autorizado', 'Destinação autorizada · bens reservados para a unidade');
  end if;
  return v_sig;
end $$;

create or replace function public.indeferir_plano(p_papel text, p_id uuid, p_motivo text) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.planos; c jsonb := public._cfg();
begin
  perform public._exigir(p_papel, array['PRA','REITORIA']);
  r := public._plano(p_id, array['AUTORIZACAO']);
  if not (p_papel = any(r.assinaturas_exigidas)) then raise exception 'Este plano não está na alçada deste perfil.'; end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Informe o motivo do indeferimento.'; end if;
  update public.planos set indeferimento = jsonb_build_object('por', auth.uid(), 'role', p_papel, 'at', (extract(epoch from now()) * 1000)::bigint, 'motivo', trim(p_motivo)) where id = p_id;
  perform public._etapa(p_id, 'INDEFERIDO');
  perform public._evento(p_id, p_papel, 'indeferimento', 'Indeferido por ' || coalesce(c->'signatarios'->p_papel->>'cargo', p_papel) || ': ' || trim(p_motivo));
end $$;

create or replace function public.iniciar_separacao(p_papel text, p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public._exigir(p_papel, array['ALMOXARIFADO','ADMIN']);
  perform public._plano(p_id, array['AUTORIZADO']);
  update public.planos set conferencia = '{}'::jsonb where id = p_id;
  perform public._etapa(p_id, 'SEPARACAO');
  perform public._evento(p_id, p_papel, 'separacao', 'Separação iniciada no Almoxarifado Central');
end $$;

create or replace function public.salvar_conferencia(p_papel text, p_id uuid, p_conf jsonb, p_concluir boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public._exigir(p_papel, array['ALMOXARIFADO','ADMIN']);
  perform public._plano(p_id, array['SEPARACAO']);
  update public.planos set conferencia = coalesce(p_conf, '{}'::jsonb) where id = p_id;
  if p_concluir then
    if exists (select 1 from public.plano_itens i where i.plano_id = p_id and coalesce((p_conf->>(i.material_id::text))::boolean, false) = false) then
      raise exception 'Confira todos os itens antes de marcar como pronto.';
    end if;
    perform public._etapa(p_id, 'PRONTO');
    perform public._evento(p_id, p_papel, 'conferencia', 'Conferência concluída: itens separados e prontos para entrega');
  end if;
end $$;

-- p_dados: {data, recebedor, siape, cargo, local, tombamentos: {material_id: ["300100", ...]}}
create or replace function public.registrar_entrega(p_papel text, p_id uuid, p_dados jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare i record; arr jsonb; n int; v_total int;
begin
  perform public._exigir(p_papel, array['PATRIMONIO','ALMOXARIFADO','ADMIN']);
  perform public._plano(p_id, array['PRONTO']);
  if coalesce(trim(p_dados->>'recebedor'), '') = '' or coalesce(trim(p_dados->>'siape'), '') = '' then raise exception 'Informe o recebedor e o SIAPE.'; end if;
  for i in select pi.material_id, pi.qtd, m.exige_tombamento, m.descricao from public.plano_itens pi join public.materiais m on m.id = pi.material_id where pi.plano_id = p_id loop
    arr := coalesce(p_dados->'tombamentos'->(i.material_id::text), '[]'::jsonb);
    if i.exige_tombamento then
      select count(*) into n from jsonb_array_elements_text(arr) x where trim(x) <> '';
      if n <> i.qtd then raise exception 'Informe % número(s) de tombamento para "%" (recebidos: %).', i.qtd, i.descricao, n; end if;
      insert into public.tombamentos (numero, plano_id, material_id) select trim(x), p_id, i.material_id from jsonb_array_elements_text(arr) x where trim(x) <> '';
    end if;
  end loop;
  insert into public.entregas (plano_id, data, recebedor, siape, cargo, local, registrado_por)
  values (p_id, coalesce(nullif(p_dados->>'data', '')::timestamptz, now()), trim(p_dados->>'recebedor'), trim(p_dados->>'siape'),
          coalesce(nullif(trim(p_dados->>'cargo'), ''), 'Responsável pela unidade'), coalesce(nullif(trim(p_dados->>'local'), ''), 'Sede da unidade'), auth.uid());
  select coalesce(sum(qtd), 0) into v_total from public.plano_itens where plano_id = p_id;
  perform public._etapa(p_id, 'ENTREGUE');
  perform public._evento(p_id, p_papel, 'entrega', 'Entrega registrada · Recebedor ' || trim(p_dados->>'recebedor') || ' · ' || v_total || ' bem(ns)');
exception when unique_violation then
  raise exception 'Há número de tombamento já usado em outra entrega. Confira os números.';
end $$;

create or replace function public.cancelar_plano(p_papel text, p_id uuid, p_motivo text) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.planos;
begin
  r := public._plano(p_id, array['RASCUNHO','INSTRUCAO','AUTORIZACAO','AUTORIZADO','SEPARACAO','PRONTO']);
  if r.status = 'RASCUNHO' then perform public._exigir(p_papel, array['PATRIMONIO','ALMOXARIFADO','FORMALIZACAO','ADMIN']);
  else perform public._exigir(p_papel, array['ADMIN']); end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Informe o motivo do cancelamento.'; end if;
  update public.planos set cancelamento = jsonb_build_object('motivo', trim(p_motivo), 'por', auth.uid(), 'at', (extract(epoch from now()) * 1000)::bigint) where id = p_id;
  perform public._etapa(p_id, 'CANCELADO');
  perform public._evento(p_id, p_papel, 'cancelamento', 'Plano cancelado: ' || trim(p_motivo));
end $$;

-- ---------- verificação de integridade e autenticidade ----------
create or replace function public.verificar_plano(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare e record; v_prev text := repeat('0', 64); v_ok boolean := true; n int := 0; r public.planos;
begin
  if not public.aprovado() then raise exception 'Acesso não aprovado.'; end if;
  select * into r from public.planos where id = p_id;
  for e in select * from public.eventos where plano_id = p_id order by id loop
    n := n + 1;
    if e.prev <> v_prev or e.hash <> public._sha(e.prev || '|' || (extract(epoch from e.em) * 1000)::bigint || '|' || coalesce(e.por::text, '') || '|' || coalesce(e.papel, '') || '|' || e.tipo || '|' || e.msg) then v_ok := false; end if;
    v_prev := e.hash;
  end loop;
  return jsonb_build_object('eventos', n, 'cadeia_ok', v_ok,
    'conteudo_ok', r.doc_hash is null or r.status in ('RASCUNHO','INSTRUCAO') or public._sha(public.doc_canonico(p_id)) = r.doc_hash);
end $$;

create or replace function public.verificar_codigo(p_codigo text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare c text := lower(regexp_replace(coalesce(p_codigo, ''), '[^0-9A-Fa-f]', '', 'g')); a public.assinaturas; r public.planos;
begin
  if not public.aprovado() then raise exception 'Acesso não aprovado.'; end if;
  if length(c) < 8 then return jsonb_build_object('encontrado', false); end if;
  select * into a from public.assinaturas where sig like c || '%' order by em limit 1;
  if not found then return jsonb_build_object('encontrado', false); end if;
  select * into r from public.planos where id = a.plano_id;
  return jsonb_build_object('encontrado', true, 'plano_id', r.id, 'numero', r.numero, 'unidade', r.unidade, 'cargo', a.cargo, 'por', a.por, 'em', (extract(epoch from a.em) * 1000)::bigint,
    'conteudo_ok', public._sha(public.doc_canonico(r.id)) = a.doc_hash,
    'assinatura_ok', public._sha(a.doc_hash || '|' || a.por || '|' || a.papel || '|' || (extract(epoch from a.em) * 1000)::bigint) = a.sig,
    'registro_ok', true);
end $$;

-- ---------- importação inicial da planilha de controle ----------
-- p_dados: {materiais:[{nome, especificacao, categoria, unidade, foto, lotes:[{data,qtd,vu,pregao,requisicao,empenho,processo,obs}]}],
--           saidas:[{processo, destino, unidadeCode, data, itens:[{nome, qtd}]}]}
create or replace function public.importar_reserva(p_dados jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare m jsonb; l jsonb; s jsonb; it jsonb; v_mat uuid; v_pl uuid; n_m int := 0; n_s int := 0; v_ano int; v_data timestamptz; v_orgao text;
begin
  perform public._exigir('ADMIN', array['ADMIN']);
  if exists (select 1 from public.materiais) or exists (select 1 from public.planos) then
    raise exception 'A importação inicial só pode ser feita com a reserva vazia, para não duplicar saldos.';
  end if;
  for m in select * from jsonb_array_elements(coalesce(p_dados->'materiais', '[]')) loop
    v_ano := extract(year from now())::int;
    insert into public.materiais (codigo, descricao, especificacao, categoria, unidade_medida, localizacao, foto, origem, criado_por)
    values ('RT-' || lpad(public._proximo(-v_ano)::text, 4, '0'), trim(m->>'nome'), coalesce(m->>'especificacao', ''), coalesce(m->>'categoria', 'Outros'),
            coalesce(nullif(m->>'unidade', ''), 'UNIDADE'), 'Almoxarifado Central', m->>'foto', 'planilha', auth.uid())
    returning id into v_mat;
    for l in select * from jsonb_array_elements(coalesce(m->'lotes', '[]')) loop
      insert into public.lotes (material_id, data, qtd, vu, pregao, requisicao, empenho, processo, obs, origem, criado_por)
      values (v_mat, (l->>'data')::date, (l->>'qtd')::int, coalesce(nullif(l->>'vu', '')::numeric, 0), coalesce(l->>'pregao', ''), coalesce(l->>'requisicao', ''),
              coalesce(l->>'empenho', ''), coalesce(l->>'processo', ''), coalesce(l->>'obs', ''), 'planilha', auth.uid());
    end loop;
    n_m := n_m + 1;
  end loop;
  for s in select * from jsonb_array_elements(coalesce(p_dados->'saidas', '[]')) order by (value->>'data') loop
    v_data := ((s->>'data')::date + time '12:00')::timestamptz;
    v_ano := extract(year from v_data)::int;
    select u.code into v_orgao from public.unidades u where u.code = s->>'orgaoCode';
    insert into public.planos (numero, legado, status, unidade, unidade_code, orgao_code, finalidade, justificativa, processo, criado_por, criado_em, etapa_em)
    values ('HIST ' || lpad(public._proximo(v_ano + 100000)::text, 4, '0') || '/' || v_ano, true, 'ENTREGUE', s->>'destino',
            (select code from public.unidades where code = s->>'unidadeCode'), v_orgao, 'Saída registrada na planilha',
            'Destinação realizada antes da implantação do Destina e importada da planilha de controle.', coalesce(s->>'processo', ''), auth.uid(), v_data, v_data)
    returning id into v_pl;
    for it in select * from jsonb_array_elements(s->'itens') loop
      insert into public.plano_itens (plano_id, material_id, qtd, vu, codigo, descricao)
      select v_pl, mm.id, (it->>'qtd')::int, public.valor_medio(mm.id), mm.codigo, mm.descricao from public.materiais mm
      where upper(regexp_replace(trim(mm.descricao), '\s+', ' ', 'g')) = upper(regexp_replace(trim(it->>'nome'), '\s+', ' ', 'g'))
      on conflict (plano_id, material_id) do update set qtd = public.plano_itens.qtd + excluded.qtd;
    end loop;
    insert into public.plano_etapas (plano_id, status, em) values (v_pl, 'ENTREGUE', v_data);
    insert into public.entregas (plano_id, data, recebedor, siape, cargo, local, registrado_por)
    values (v_pl, v_data, 'Não informado (registro da planilha)', '—', '—', s->>'destino', auth.uid());
    insert into public.eventos (plano_id, em, por, papel, tipo, msg) values (v_pl, v_data, auth.uid(), 'ADMIN', 'importacao', 'Saída importada da planilha de controle anterior · processo ' || coalesce(nullif(s->>'processo', ''), 'não informado'));
    n_s := n_s + 1;
  end loop;
  return jsonb_build_object('materiais', n_m, 'saidas', n_s);
end $$;

-- ---------- permissões de execução ----------
-- No Supabase, o papel "authenticated" recebe EXECUTE em toda função nova por padrão.
-- Revogamos tudo e liberamos só as funções de uso do app; as internas (_etapa, _evento,
-- _plano etc.) ficam inacessíveis pela API e só rodam dentro das funções públicas.
revoke all on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
grant execute on function public.aprovado(), public.tem_papel(text), public.existe_admin(), public.reivindicar_admin(), public.definir_perfil(uuid, text[], boolean),
  public.atualizar_meu_nome(text), public.salvar_config(jsonb), public.substituir_unidades(jsonb, text, text), public.salvar_material(text, uuid, jsonb),
  public.registrar_entrada(text, uuid, jsonb, jsonb), public.excluir_material(text, uuid), public.salvar_plano(text, uuid, jsonb, boolean), public.enviar_instrucao(text, uuid),
  public.devolver_plano(text, uuid, text), public.formalizar_plano(text, uuid, text, text, text), public.assinar_plano(text, uuid), public.indeferir_plano(text, uuid, text),
  public.iniciar_separacao(text, uuid), public.salvar_conferencia(text, uuid, jsonb, boolean), public.registrar_entrega(text, uuid, jsonb), public.cancelar_plano(text, uuid, text),
  public.verificar_plano(uuid), public.verificar_codigo(text), public.importar_reserva(jsonb), public.disponivel(uuid, uuid), public.valor_medio(uuid)
  to authenticated;
