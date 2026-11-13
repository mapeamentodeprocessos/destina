-- Destina · 17 · o autorizador pode alterar a proposta antes de assinar
-- Na decisão sobre uma proposta, o autorizador pode mudar a unidade de destino, os bens, as quantidades e
-- a observação. A proposta original fica guardada (proposta_original) e o plano registra o que mudou.
-- Pode ser rodado de novo sem problema.

alter table public.determinacoes add column if not exists proposta_original jsonb;

-- o nome da unidade é sempre o nome oficial do código organizacional
do $$ declare src text; begin
  select pg_get_functiondef('public._exigir_codigo_unidade()'::regprocedure) into src;
  execute replace(src, 'if coalesce(trim(new.unidade), '''') = '''' then new.unidade := v_nome; end if;', 'new.unidade := v_nome;');
end $$;

create or replace function public._resumo_itens(p jsonb) returns text
language sql immutable set search_path = '' as $$
  select coalesce(string_agg((e->>'quantidade') || ' × ' || coalesce(e->>'descricao', 'bem'), '; ' order by e->>'descricao'), '') from jsonb_array_elements(coalesce(p, '[]')) e
$$;

do $$ declare src text; n int := 0; begin
  select pg_get_functiondef('public.registrar_determinacao(text,jsonb)'::regprocedure) into src;
  if position('proposta_original' in src) > 0 then return; end if;
  -- 1) a unidade e a observação podem vir da decisão (alterada) em vez da proposta
  src := replace(src, 'v_uni := d.unidade; v_unic := d.unidade_code; v_obs := d.observacao; v_origem := d.origem;',
    'v_uni := coalesce(nullif(trim(p_dados->>''unidade''), ''''), d.unidade); v_unic := coalesce(nullif(trim(p_dados->>''unidadeCode''), ''''), d.unidade_code); v_obs := coalesce(p_dados->>''observacao'', d.observacao); v_origem := d.origem;');
  -- 2) a determinação passa a refletir o que foi decidido, guardando a proposta original quando mudou
  src := replace(src, 'update public.determinacoes set papel = p_papel, autor = auth.uid(), itens = v_itens, assinatura = v_ev, atualizado_em = now() where id = v_det;',
    'update public.determinacoes set proposta_original = case when d.unidade_code is distinct from v_unic or public._resumo_itens(d.itens) <> public._resumo_itens(v_itens) or coalesce(d.observacao, '''') <> coalesce(v_obs, '''') then jsonb_build_object(''unidade'', d.unidade, ''unidade_code'', d.unidade_code, ''itens'', d.itens, ''observacao'', d.observacao) end,
       papel = p_papel, autor = auth.uid(), unidade = v_uni, unidade_code = v_unic, observacao = v_obs, itens = v_itens, assinatura = v_ev, atualizado_em = now() where id = v_det;');
  -- 3) o histórico do plano registra a alteração
  src := replace(src, 'perform public._evento(v_plano, p_papel, ''assinatura'', ''Decisão assinada eletronicamente',
    'if d.id is not null and (d.unidade_code is distinct from v_unic or public._resumo_itens(d.itens) <> public._resumo_itens(v_itens)) then
    perform public._evento(v_plano, p_papel, ''alteracao'', ''Proposta alterada pelo autorizador antes de assinar: ''
      || case when d.unidade_code is distinct from v_unic then ''destino '' || d.unidade || '' → '' || v_uni || ''; '' else '''' end
      || case when public._resumo_itens(d.itens) <> public._resumo_itens(v_itens) then ''bens '' || public._resumo_itens(d.itens) || '' → '' || public._resumo_itens(v_itens) else '''' end);
  end if;
  perform public._evento(v_plano, p_papel, ''assinatura'', ''Decisão assinada eletronicamente');
  execute src;
end $$;

revoke all on function public._resumo_itens(jsonb) from public, anon, authenticated;
select position('proposta_original' in pg_get_functiondef('public.registrar_determinacao(text,jsonb)'::regprocedure)) > 0 as autorizador_pode_alterar;
