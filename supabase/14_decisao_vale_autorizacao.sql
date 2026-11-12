-- Destina · 14 · a decisão assinada do autorizador já é a autorização
-- Quando o plano nasce da decisão assinada de um autorizador, ele não volta para a assinatura do termo:
-- ao concluir a formalização, a assinatura da decisão é registrada como a autorização do termo e o plano
-- segue direto para "Autorizado".
--   • Autorizador nível 2 (que assina acima da alçada) cobre o termo inteiro.
--   • Autorizador nível 1 cobre até o limite de alçada; acima dele, o termo ainda espera o nível 2.
--   • Se a Formalização mudar os bens ou as quantidades decididos, a decisão deixa de cobrir o termo
--     e ele volta para a assinatura normal.
-- Pode ser rodado de novo sem problema.

create or replace function public.formalizar_plano(p_papel text, p_id uuid, p_processo text, p_fundamentacao text, p_despacho text) returns void
language plpgsql security definer set search_path = '' as $$
declare c jsonb := public._cfg(); v_total numeric; v_exig text[]; d public.determinacoes; r public.planos; v_igual boolean;
        v_em timestamptz; v_sig text; v_cv text; v_pend text[];
begin
  perform public._exigir(p_papel, array['FORMALIZACAO','ADMIN']);
  perform public._plano(p_id, array['INSTRUCAO']);
  if coalesce(trim(p_processo), '') = '' then raise exception 'Informe o número do processo.'; end if;
  perform public._validar_saldo(p_id);
  select coalesce(sum(qtd * vu), 0) into v_total from public.plano_itens where plano_id = p_id;
  v_exig := case when coalesce((c->>'exigirAmbos')::boolean, false) or v_total > coalesce((c->>'limiteAlcada')::numeric, 50000) then array['PRA','REITORIA'] else array['PRA'] end;

  -- decisão assinada que originou o plano
  select * into d from public.determinacoes where plano_id = p_id and situacao = 'ATENDIDA' and assinatura is not null and papel in ('PRA','REITORIA') order by atualizado_em desc limit 1;
  if d.id is not null then
    -- a decisão só cobre o termo se os bens e as quantidades forem os mesmos
    select coalesce(bool_and(x.ok), false) into v_igual from (
      select (pi.qtd is not null and di.qtd is not null and pi.qtd = di.qtd) as ok
      from (select material_id, sum(qtd) qtd from public.plano_itens where plano_id = p_id group by material_id) pi
      full join (select (e->>'material_id')::uuid material_id, sum((e->>'quantidade')::int) qtd from jsonb_array_elements(d.itens) e group by 1) di using (material_id)) x;
    if v_igual and d.papel = 'REITORIA' then v_exig := array['REITORIA']; end if; -- o nível 2 cobre o termo inteiro
  end if;

  update public.planos set processo = trim(p_processo), fundamentacao = coalesce(p_fundamentacao, ''), despacho = coalesce(p_despacho, ''), assinaturas_exigidas = v_exig where id = p_id;
  update public.planos set doc_hash = public._sha(public.doc_canonico(p_id)) where id = p_id;
  perform public._etapa(p_id, 'AUTORIZACAO');
  perform public._evento(p_id, p_papel, 'formalizacao', 'Instrução concluída · Processo ' || trim(p_processo));

  if d.id is not null and v_igual and d.papel = any(v_exig) then
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
    select array_agg(x) into v_pend from unnest(v_exig) x where not exists (select 1 from public.assinaturas a where a.plano_id = p_id and a.papel = x);
    if v_pend is null then
      perform public._etapa(p_id, 'AUTORIZADO');
      perform public._evento(p_id, d.papel, 'autorizado', 'Destinação autorizada · bens reservados para a unidade');
    else
      perform public._evento(p_id, p_papel, 'formalizacao', 'Valor acima do limite de alçada: falta a assinatura de ' || coalesce(c->'signatarios'->v_pend[1]->>'cargo', v_pend[1]));
    end if;
  elsif d.id is not null then
    perform public._evento(p_id, p_papel, 'formalizacao', 'Os bens mudaram em relação à decisão ' || d.numero || ': o termo segue para assinatura');
  end if;
end $$;

revoke all on function public.formalizar_plano(text, uuid, text, text, text) from public, anon;
grant execute on function public.formalizar_plano(text, uuid, text, text, text) to authenticated;
