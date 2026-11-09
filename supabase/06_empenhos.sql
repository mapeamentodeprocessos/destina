-- Destina · 06 · controle por empenho e tombamento
-- Fluxo: o Almoxarifado recebe os bens e registra o empenho (manual ou por arquivo) → os itens entram no
-- saldo da reserva → o processo de pagamento vai à DIPA → a DIPA gera os tombamentos de cada item →
-- agenda e conclui o emplaquetamento. Na entrega, os números informados baixam os bens tombados da reserva.
-- Rode depois de 01 a 05. Pode ser rodado de novo sem problema.

create table if not exists public.empenhos (
  id uuid primary key default gen_random_uuid(),
  numero text not null,                       -- ex.: 2026NE000442
  nf text not null default '',                -- nota fiscal do recebimento (um empenho pode chegar em várias NFs)
  nf_data date, data_empenho date,
  fornecedor text not null default '', cnpj text not null default '',
  processo text not null default '', pregao text not null default '', requisicao text not null default '',
  recebido_em date not null default current_date,
  local_recebimento text not null default 'Almoxarifado Central',
  situacao text not null default 'RECEBIDO'
    check (situacao in ('RECEBIDO','NA_DIPA','TOMBADO','EMPLAQUETAMENTO_AGENDADO','EMPLAQUETADO')),
  encaminhado_dipa_em date, emplaquetamento_data date, emplaquetado_em date,
  obs text not null default '', arquivo text not null default '',
  historico jsonb not null default '[]'::jsonb,
  criado_por uuid references public.perfis(id),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  unique (numero, nf)
);
create table if not exists public.empenho_itens (
  id uuid primary key default gen_random_uuid(),
  empenho_id uuid not null references public.empenhos(id) on delete cascade,
  seq int not null default 1,
  descricao text not null,
  unidade_medida text not null default 'UNIDADE',
  qtd int not null check (qtd > 0),
  vu numeric(14,2) not null default 0 check (vu >= 0),
  material_id uuid not null references public.materiais(id),
  lote_id uuid references public.lotes(id) on delete set null
);
create index if not exists empenho_itens_empenho on public.empenho_itens(empenho_id);
create index if not exists empenho_itens_material on public.empenho_itens(material_id);

-- Cada bem tombado que está (ou esteve) na reserva
create table if not exists public.bens (
  numero text primary key,
  empenho_item_id uuid not null references public.empenho_itens(id) on delete cascade,
  material_id uuid not null references public.materiais(id),
  situacao text not null default 'EM_RESERVA' check (situacao in ('EM_RESERVA','ENTREGUE')),
  plano_id uuid references public.planos(id) on delete set null,
  gerado_por uuid references public.perfis(id),
  gerado_em timestamptz not null default now(),
  entregue_em timestamptz
);
create index if not exists bens_material on public.bens(material_id, situacao);
create index if not exists bens_item on public.bens(empenho_item_id);

do $$ declare t text; begin
  foreach t in array array['empenhos','empenho_itens','bens'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "leitura aprovados" on public.%I', t);
    execute format('create policy "leitura aprovados" on public.%I for select to authenticated using (public.aprovado())', t);
    execute format('revoke all on public.%I from anon, public', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end $$;

-- ---------- auxiliares ----------
create or replace function public._empenho_hist(p_id uuid, p_papel text, p_texto text) returns void
language sql security definer set search_path = '' as $$
  update public.empenhos set atualizado_em = now(),
    historico = historico || jsonb_build_array(jsonb_build_object('em', (extract(epoch from now()) * 1000)::bigint, 'por', auth.uid(), 'papel', p_papel, 'texto', p_texto))
  where id = p_id;
$$;

create or replace function public._norm(p text) returns text
language sql immutable set search_path = '' as $$ select upper(regexp_replace(trim(coalesce(p, '')), '\s+', ' ', 'g')) $$;

-- ---------- 1. recebimento: registra o empenho e dá entrada dos itens na reserva ----------
create or replace function public.registrar_empenho(p_papel text, p_dados jsonb) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; it jsonb; v_mat uuid; v_lote uuid; v_seq int := 0; v_num text := upper(regexp_replace(trim(coalesce(p_dados->>'numero', '')), '\s+', '', 'g'));
        v_nf text := trim(coalesce(p_dados->>'nf', '')); v_rec date := coalesce(nullif(p_dados->>'recebidoEm', '')::date, current_date); v_qtd int; v_desc text;
begin
  perform public._exigir(p_papel, array['ALMOXARIFADO','PATRIMONIO','ADMIN']);
  if v_num = '' then raise exception 'Informe o número do empenho.'; end if;
  if jsonb_array_length(coalesce(p_dados->'itens', '[]'::jsonb)) = 0 then raise exception 'O empenho precisa ter pelo menos um item.'; end if;
  if exists (select 1 from public.empenhos where numero = v_num and nf = v_nf) then
    raise exception 'O empenho % % já foi registrado.', v_num, case when v_nf <> '' then 'com a NF ' || v_nf else '(sem NF)' end;
  end if;
  insert into public.empenhos (numero, nf, nf_data, data_empenho, fornecedor, cnpj, processo, pregao, requisicao, recebido_em, local_recebimento, obs, arquivo, criado_por)
  values (v_num, v_nf, nullif(p_dados->>'nfData', '')::date, nullif(p_dados->>'dataEmpenho', '')::date,
          trim(coalesce(p_dados->>'fornecedor', '')), trim(coalesce(p_dados->>'cnpj', '')), trim(coalesce(p_dados->>'processo', '')),
          trim(coalesce(p_dados->>'pregao', '')), trim(coalesce(p_dados->>'requisicao', '')), v_rec,
          coalesce(nullif(trim(p_dados->>'localRecebimento'), ''), 'Almoxarifado Central'), coalesce(p_dados->>'obs', ''), coalesce(p_dados->>'arquivo', ''), auth.uid())
  returning id into v_id;
  for it in select * from jsonb_array_elements(p_dados->'itens') loop
    v_seq := v_seq + 1;
    v_desc := trim(coalesce(it->>'descricao', ''));
    v_qtd := coalesce(nullif(it->>'qtd', '')::numeric, 0)::int;
    if v_desc = '' then raise exception 'Item % sem descrição.', v_seq; end if;
    if v_qtd <= 0 then raise exception 'Item % ("%") sem quantidade.', v_seq, left(v_desc, 40); end if;
    v_mat := nullif(it->>'materialId', '')::uuid;
    if v_mat is null then select id into v_mat from public.materiais where public._norm(descricao) = public._norm(v_desc) limit 1; end if;
    if v_mat is null then
      v_mat := public.salvar_material(p_papel, null, jsonb_build_object('descricao', v_desc, 'categoria', coalesce(nullif(it->>'categoria', ''), 'Outros'),
                 'unidadeMedida', coalesce(nullif(it->>'unidadeMedida', ''), 'UNIDADE'), 'fornecedor', trim(coalesce(p_dados->>'fornecedor', '')),
                 'especificacao', coalesce(it->>'especificacao', ''), 'origem', 'Empenho ' || v_num));
    end if;
    insert into public.lotes (material_id, data, qtd, vu, pregao, requisicao, empenho, processo, nf, obs, origem, criado_por)
    values (v_mat, v_rec, v_qtd, coalesce(nullif(it->>'vu', '')::numeric, 0), trim(coalesce(p_dados->>'pregao', '')), trim(coalesce(p_dados->>'requisicao', '')),
            v_num, trim(coalesce(p_dados->>'processo', '')), v_nf, '', 'empenho', auth.uid())
    returning id into v_lote;
    insert into public.empenho_itens (empenho_id, seq, descricao, unidade_medida, qtd, vu, material_id, lote_id)
    values (v_id, coalesce(nullif(it->>'seq', '')::int, v_seq), v_desc, coalesce(nullif(it->>'unidadeMedida', ''), 'UNIDADE'), v_qtd,
            coalesce(nullif(it->>'vu', '')::numeric, 0), v_mat, v_lote);
    update public.materiais set atualizado_em = now() where id = v_mat;
  end loop;
  perform public._empenho_hist(v_id, p_papel, 'Recebimento registrado · ' || v_seq || ' item(ns)' || case when coalesce(p_dados->>'arquivo', '') <> '' then ' · importado de ' || (p_dados->>'arquivo') else '' end);
  return v_id;
end $$;

-- ---------- 2. processo de pagamento encaminhado à DIPA ----------
create or replace function public.encaminhar_empenho_dipa(p_papel text, p_id uuid, p_data date default null) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public._exigir(p_papel, array['ALMOXARIFADO','PATRIMONIO','ADMIN']);
  update public.empenhos set situacao = 'NA_DIPA', encaminhado_dipa_em = coalesce(p_data, current_date) where id = p_id and situacao = 'RECEBIDO';
  if not found then raise exception 'Este empenho não está aguardando encaminhamento.'; end if;
  perform public._empenho_hist(p_id, p_papel, 'Processo de pagamento encaminhado à Divisão de Patrimônio');
end $$;

-- ---------- 3. DIPA gera os tombamentos ----------
-- p_faixas: {"<item_id>": "300120"}  (número inicial: gera a sequência para a quantidade do item)
--        ou {"<item_id>": ["300120","300125",...]}  (lista exata)
create or replace function public.tombar_empenho(p_papel text, p_id uuid, p_faixas jsonb) returns int
language plpgsql security definer set search_path = '' as $$
declare e public.empenhos; i record; v jsonb; v_ini text; v_nums text[]; v_ja int; v_falta int; v_dup text; v_total int := 0; k int;
begin
  perform public._exigir(p_papel, array['PATRIMONIO','ADMIN']);
  select * into e from public.empenhos where id = p_id for update;
  if not found then raise exception 'Empenho não encontrado.'; end if;
  if e.situacao not in ('RECEBIDO','NA_DIPA','TOMBADO') then raise exception 'Os tombamentos deste empenho já foram concluídos.'; end if;
  for i in select * from public.empenho_itens where empenho_id = p_id order by seq loop
    v := p_faixas->(i.id::text);
    if v is null or v = 'null'::jsonb or v = '""'::jsonb then continue; end if;
    select count(*) into v_ja from public.bens where empenho_item_id = i.id;
    v_falta := i.qtd - v_ja;
    if v_falta <= 0 then raise exception 'O item % já está todo tombado.', i.seq; end if;
    if jsonb_typeof(v) = 'array' then
      select array_agg(trim(x)) into v_nums from jsonb_array_elements_text(v) x where trim(x) <> '';
      if coalesce(array_length(v_nums, 1), 0) <> v_falta then raise exception 'Item %: informe % número(s) de tombamento (recebidos: %).', i.seq, v_falta, coalesce(array_length(v_nums, 1), 0); end if;
    else
      v_ini := regexp_replace(v #>> '{}', '\s', '', 'g');
      if v_ini !~ '^\d{1,15}$' then raise exception 'Item %: o tombamento inicial deve ter só números.', i.seq; end if;
      v_nums := array(select lpad((v_ini::bigint + g)::text, length(v_ini), '0') from generate_series(0, v_falta - 1) g);
    end if;
    select x into v_dup from unnest(v_nums) x where exists (select 1 from public.bens b where b.numero = x) or exists (select 1 from public.tombamentos t where t.numero = x) limit 1;
    if v_dup is not null then raise exception 'O tombamento % já existe no sistema (item %).', v_dup, i.seq; end if;
    if (select count(distinct x) from unnest(v_nums) x) <> array_length(v_nums, 1) then raise exception 'Item %: há números repetidos na lista.', i.seq; end if;
    insert into public.bens (numero, empenho_item_id, material_id, gerado_por) select x, i.id, i.material_id, auth.uid() from unnest(v_nums) x;
    v_total := v_total + array_length(v_nums, 1);
  end loop;
  if v_total = 0 then raise exception 'Informe o tombamento inicial de pelo menos um item.'; end if;
  select count(*) into k from public.empenho_itens it where it.empenho_id = p_id and (select count(*) from public.bens b where b.empenho_item_id = it.id) < it.qtd;
  update public.empenhos set situacao = case when k = 0 then 'TOMBADO' else 'NA_DIPA' end,
         encaminhado_dipa_em = coalesce(encaminhado_dipa_em, current_date) where id = p_id;
  perform public._empenho_hist(p_id, p_papel, v_total || ' tombamento(s) gerado(s)' || case when k = 0 then ' · empenho todo tombado' else ' · faltam itens' end);
  return v_total;
exception when unique_violation then
  raise exception 'Há número de tombamento já usado. Confira a faixa informada.';
end $$;

-- ---------- 4. emplaquetamento ----------
create or replace function public.agendar_emplaquetamento(p_papel text, p_id uuid, p_data date, p_obs text default '') returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public._exigir(p_papel, array['PATRIMONIO','ADMIN']);
  if p_data is null then raise exception 'Informe a data do emplaquetamento.'; end if;
  update public.empenhos set situacao = 'EMPLAQUETAMENTO_AGENDADO', emplaquetamento_data = p_data where id = p_id and situacao in ('TOMBADO','EMPLAQUETAMENTO_AGENDADO');
  if not found then raise exception 'Gere todos os tombamentos antes de agendar o emplaquetamento.'; end if;
  perform public._empenho_hist(p_id, p_papel, 'Emplaquetamento agendado para ' || to_char(p_data, 'DD/MM/YYYY') || case when coalesce(p_obs, '') <> '' then ' · ' || p_obs else '' end);
end $$;

create or replace function public.concluir_emplaquetamento(p_papel text, p_id uuid, p_data date default null) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public._exigir(p_papel, array['PATRIMONIO','ADMIN']);
  update public.empenhos set situacao = 'EMPLAQUETADO', emplaquetado_em = coalesce(p_data, current_date) where id = p_id and situacao in ('TOMBADO','EMPLAQUETAMENTO_AGENDADO');
  if not found then raise exception 'Gere todos os tombamentos antes de concluir o emplaquetamento.'; end if;
  perform public._empenho_hist(p_id, p_papel, 'Emplaquetamento concluído em ' || to_char(coalesce(p_data, current_date), 'DD/MM/YYYY'));
end $$;

-- ---------- 5. excluir um registro feito por engano (só o gestor, e só se nada saiu da reserva) ----------
create or replace function public.excluir_empenho(p_papel text, p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare i record;
begin
  perform public._exigir(p_papel, array['ADMIN']);
  if exists (select 1 from public.bens b join public.empenho_itens it on it.id = b.empenho_item_id where it.empenho_id = p_id and b.situacao <> 'EM_RESERVA') then
    raise exception 'Há bens deste empenho já entregues. Não é possível excluir.';
  end if;
  for i in select it.*, m.descricao as mdesc from public.empenho_itens it join public.materiais m on m.id = it.material_id where it.empenho_id = p_id loop
    if public.disponivel(i.material_id) < i.qtd then raise exception 'Parte de "%" já está em planos de destinação. Ajuste os planos antes de excluir.', i.mdesc; end if;
  end loop;
  delete from public.lotes where id in (select lote_id from public.empenho_itens where empenho_id = p_id and lote_id is not null);
  delete from public.empenhos where id = p_id;
end $$;

-- ---------- 6. na entrega, o número informado baixa o bem tombado da reserva ----------
create or replace function public._baixar_bem() returns trigger
language plpgsql security definer set search_path = '' as $$
declare b public.bens;
begin
  select * into b from public.bens where numero = new.numero;
  if not found then return new; end if;                 -- tombamento antigo, sem registro de empenho
  if b.material_id <> new.material_id then
    raise exception 'O tombamento % pertence a outro material da reserva.', new.numero;
  end if;
  if b.situacao <> 'EM_RESERVA' then raise exception 'O tombamento % já foi entregue.', new.numero; end if;
  update public.bens set situacao = 'ENTREGUE', plano_id = new.plano_id, entregue_em = now() where numero = new.numero;
  return new;
end $$;
drop trigger if exists baixar_bem on public.tombamentos;
create trigger baixar_bem after insert on public.tombamentos for each row execute function public._baixar_bem();

-- ---------- permissões ----------
revoke all on function public._empenho_hist(uuid, text, text), public._norm(text), public._baixar_bem(),
  public.registrar_empenho(text, jsonb), public.encaminhar_empenho_dipa(text, uuid, date), public.tombar_empenho(text, uuid, jsonb),
  public.agendar_emplaquetamento(text, uuid, date, text), public.concluir_emplaquetamento(text, uuid, date), public.excluir_empenho(text, uuid)
  from public, anon, authenticated;
grant execute on function public.registrar_empenho(text, jsonb), public.encaminhar_empenho_dipa(text, uuid, date), public.tombar_empenho(text, uuid, jsonb),
  public.agendar_emplaquetamento(text, uuid, date, text), public.concluir_emplaquetamento(text, uuid, date), public.excluir_empenho(text, uuid)
  to authenticated;
