-- Destina · 15 · autorizadores no mesmo nível
-- Os dois autorizadores configurados (hoje, Reitora e Pró-Reitor de Administração) têm o mesmo nível:
-- a assinatura de qualquer um deles autoriza a destinação, de qualquer valor.
-- A configuração ainda permite exigir as duas assinaturas: sempre ("exigirAmbos") ou acima de um valor
-- ("limiteAlcada" maior que zero). Com limiteAlcada = 0, uma assinatura basta.
-- Pode ser rodado de novo sem problema.

alter table public.planos add column if not exists assinaturas_minimas int not null default 1;

-- padrão desta instalação: uma assinatura basta, de qualquer autorizador
update public.config set dados = dados || jsonb_build_object('limiteAlcada', 0, 'exigirAmbos', false) where id = 1;

create or replace function public._min_assinaturas(p_total numeric) returns int
language sql stable security definer set search_path = '' as $$
  select case when coalesce((c.dados->>'exigirAmbos')::boolean, false)
                or (coalesce((c.dados->>'limiteAlcada')::numeric, 0) > 0 and p_total > (c.dados->>'limiteAlcada')::numeric) then 2 else 1 end
  from public.config c where c.id = 1
$$;

create or replace function public.formalizar_plano(p_papel text, p_id uuid, p_processo text, p_fundamentacao text, p_despacho text) returns void
language plpgsql security definer set search_path = '' as $$
declare c jsonb := public._cfg(); v_total numeric; v_exig text[] := array['PRA','REITORIA']; v_min int; d public.determinacoes; r public.planos; v_igual boolean;
        v_em timestamptz; v_sig text; v_cv text; v_feitas int;
begin
  perform public._exigir(p_papel, array['FORMALIZACAO','ADMIN']);
  perform public._plano(p_id, array['INSTRUCAO']);
  if coalesce(trim(p_processo), '') = '' then raise exception 'Informe o número do processo.'; end if;
  perform public._validar_saldo(p_id);
  select coalesce(sum(qtd * vu), 0) into v_total from public.plano_itens where plano_id = p_id;
  v_min := public._min_assinaturas(v_total);

  select * into d from public.determinacoes where plano_id = p_id and situacao = 'ATENDIDA' and assinatura is not null and papel in ('PRA','REITORIA') order by atualizado_em desc limit 1;
  if d.id is not null then
    select coalesce(bool_and(x.ok), false) into v_igual from (
      select (pi.qtd is not null and di.qtd is not null and pi.qtd = di.qtd) as ok
      from (select material_id, sum(qtd) qtd from public.plano_itens where plano_id = p_id group by material_id) pi
      full join (select (e->>'material_id')::uuid material_id, sum((e->>'quantidade')::int) qtd from jsonb_array_elements(d.itens) e group by 1) di using (material_id)) x;
  end if;

  update public.planos set processo = trim(p_processo), fundamentacao = coalesce(p_fundamentacao, ''), despacho = coalesce(p_despacho, ''),
         assinaturas_exigidas = v_exig, assinaturas_minimas = v_min where id = p_id;
  update public.planos set doc_hash = public._sha(public.doc_canonico(p_id)) where id = p_id;
  perform public._etapa(p_id, 'AUTORIZACAO');
  perform public._evento(p_id, p_papel, 'formalizacao', 'Instrução concluída · Processo ' || trim(p_processo));

  if d.id is not null and v_igual then
    select * into r from public.planos where id = p_id;
    v_em := coalesce(to_timestamp(((d.assinatura->>'assinado_em')::bigint) / 1000.0), d.atualizado_em);
    v_sig := public._sha(r.doc_hash || '|' || d.autor || '|' || d.papel || '|' || (extract(epoch from v_em) * 1000)::bigint || '|decisao');
    insert into public.assinaturas (plano_id, papel, por, em, doc_hash, sig, nome, cargo, evidencias)
    values (p_id, d.papel, d.autor, v_em, r.doc_hash, v_sig,
            coalesce(d.assinatura->>'nome', c->'signatarios'->d.papel->>'nome'), coalesce(d.assinatura->>'cargo', c->'signatarios'->d.papel->>'cargo'),
            d.assinatura || jsonb_build_object('origem', 'decisao_assinada', 'determinacao', d.numero, 'aplicada_em', (extract(epoch from now()) * 1000)::bigint))
    on conflict (plano_id, papel) do nothing;
    v_cv := upper(substr(v_sig, 1, 4) || '-' || substr(v_sig, 5, 4) || '-' || substr(v_sig, 9, 4));
    perform public._evento(p_id, d.papel, 'assinatura', 'Autorização dada pela decisão assinada de ' || coalesce(d.assinatura->>'cargo', d.papel) || ' (' || d.numero || ') · código ' || v_cv);
    select count(*) into v_feitas from public.assinaturas where plano_id = p_id;
    if v_feitas >= v_min then
      perform public._etapa(p_id, 'AUTORIZADO');
      perform public._evento(p_id, d.papel, 'autorizado', 'Destinação autorizada · bens reservados para a unidade');
    else
      perform public._evento(p_id, p_papel, 'formalizacao', 'A configuração exige as duas assinaturas: falta a do outro autorizador');
    end if;
  elsif d.id is not null then
    perform public._evento(p_id, p_papel, 'formalizacao', 'Os bens mudaram em relação à decisão ' || d.numero || ': o termo segue para assinatura');
  end if;
end $$;

-- assinatura do termo: com uma assinatura mínima, qualquer autorizador assina e não há ordem
do $$ declare src text; begin
  select pg_get_functiondef('public.assinar_plano(text,uuid)'::regprocedure) into src;
  src := replace(src, 'if coalesce((c->>''sequencial'')::boolean, true) and v_pend[1] <> p_papel then',
                      'if coalesce(r.assinaturas_minimas, 2) > 1 and coalesce((c->>''sequencial'')::boolean, true) and v_pend[1] <> p_papel then');
  src := replace(src, 'if array_length(v_pend, 1) = 1 then',
                      'if (select count(*) from public.assinaturas a2 where a2.plano_id = p_id) >= coalesce(r.assinaturas_minimas, array_length(r.assinaturas_exigidas, 1)) then');
  execute src;
end $$;

grant execute on function public.formalizar_plano(text, uuid, text, text, text) to authenticated;
revoke all on function public._min_assinaturas(numeric) from public, anon, authenticated;
select position('assinaturas_minimas' in pg_get_functiondef('public.assinar_plano(text,uuid)'::regprocedure)) > 0 as qualquer_autorizador_assina;
