-- Destina · 07 · determinações de destinação (Reitoria e Pró-Reitoria, inclusive pelo chat)
-- A Reitora ou o Pró-Reitor determinam "destinar X bens para a unidade Y"; a Formalização (ou a DIPA)
-- monta o plano a partir da determinação; o plano segue o fluxo normal até a autorização.
-- Também ajusta quem cria planos: Formalização, Patrimônio e o gestor do sistema.
-- Rode depois de 01 a 06. Pode ser rodado de novo sem problema.

create table if not exists public.determinacoes (
  id uuid primary key default gen_random_uuid(),
  numero text not null unique,
  papel text not null check (papel in ('PRA','REITORIA','ADMIN')),
  autor uuid references public.perfis(id),
  unidade text not null,
  unidade_code text not null default '',
  itens jsonb not null default '[]'::jsonb,     -- [{material_id, descricao, quantidade}]
  observacao text not null default '',
  situacao text not null default 'ABERTA' check (situacao in ('ABERTA','ATENDIDA','CANCELADA')),
  plano_id uuid references public.planos(id) on delete set null,
  origem text not null default 'tela',          -- 'chat' ou 'tela'
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
alter table public.determinacoes enable row level security;
drop policy if exists "leitura aprovados" on public.determinacoes;
create policy "leitura aprovados" on public.determinacoes for select to authenticated using (public.aprovado());
revoke all on public.determinacoes from anon, public;
grant select on public.determinacoes to authenticated;

create or replace function public.registrar_determinacao(p_papel text, p_dados jsonb) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_num text; it jsonb; v_disp int; v_desc text; v_itens jsonb := '[]'::jsonb;
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
  end loop;
  perform pg_advisory_xact_lock(hashtext('destina_determinacao'));
  v_num := 'DT ' || lpad(((select count(*) from public.determinacoes where extract(year from criado_em) = extract(year from now())) + 1)::text, 4, '0') || '/' || extract(year from now())::int;
  insert into public.determinacoes (numero, papel, autor, unidade, unidade_code, itens, observacao, origem)
  values (v_num, p_papel, auth.uid(), trim(p_dados->>'unidade'), coalesce(p_dados->>'unidadeCode', ''), v_itens, coalesce(p_dados->>'observacao', ''), coalesce(nullif(p_dados->>'origem', ''), 'tela'))
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.atender_determinacao(p_papel text, p_id uuid, p_plano uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public._exigir(p_papel, array['FORMALIZACAO','PATRIMONIO','ADMIN']);
  update public.determinacoes set situacao = 'ATENDIDA', plano_id = p_plano, atualizado_em = now() where id = p_id and situacao = 'ABERTA';
  if not found then raise exception 'Esta determinação não está mais aberta.'; end if;
  perform public._evento(p_plano, p_papel, 'determinacao', 'Plano montado a partir da determinação ' || (select numero from public.determinacoes where id = p_id));
end $$;

create or replace function public.cancelar_determinacao(p_papel text, p_id uuid, p_motivo text default '') returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public._exigir(p_papel, array['PRA','REITORIA','ADMIN']);
  update public.determinacoes set situacao = 'CANCELADA', observacao = trim(observacao || ' ' || coalesce('[Cancelada: ' || nullif(p_motivo, '') || ']', '[Cancelada]')), atualizado_em = now()
   where id = p_id and situacao = 'ABERTA' and (autor = auth.uid() or public.tem_papel('ADMIN'));
  if not found then raise exception 'Só quem determinou (ou o gestor) pode cancelar uma determinação aberta.'; end if;
end $$;

-- quem cria planos: Formalização, Patrimônio e o gestor
do $$ declare src text; begin
  select pg_get_functiondef('public.salvar_plano(text,uuid,jsonb,boolean)'::regprocedure) into src;
  if src like '%''ALMOXARIFADO'',''FORMALIZACAO''%' then
    execute replace(src, 'array[''PATRIMONIO'',''ALMOXARIFADO'',''FORMALIZACAO'',''ADMIN'']', 'array[''PATRIMONIO'',''FORMALIZACAO'',''ADMIN'']');
  end if;
end $$;

revoke all on function public.registrar_determinacao(text, jsonb), public.atender_determinacao(text, uuid, uuid), public.cancelar_determinacao(text, uuid, text) from public, anon, authenticated;
grant execute on function public.registrar_determinacao(text, jsonb), public.atender_determinacao(text, uuid, uuid), public.cancelar_determinacao(text, uuid, text) to authenticated;
