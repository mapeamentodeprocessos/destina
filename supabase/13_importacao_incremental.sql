-- Destina · 13 · importação da planilha com a reserva já em uso
-- Antes: só importava com a reserva vazia. Agora soma ao que existe, sem duplicar:
--   • material com o mesmo nome (sem diferença de maiúsculas, acentos ou espaços) é o mesmo material;
--   • entrada igual (mesmo material, data, quantidade, valor, empenho e processo) não entra de novo;
--   • saída igual (mesmo processo, destino e data) não entra de novo.
-- Se, depois de somar, algum material ficar com saldo negativo, nada é gravado.
-- Pode ser rodado de novo sem problema.

create or replace function public._nome_norm(t text) returns text
language sql immutable set search_path = '' as $$
  select translate(upper(regexp_replace(trim(coalesce(t, '')), '\s+', ' ', 'g')), 'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ', 'AAAAAEEEEIIIIOOOOOUUUUC') $$;

create or replace function public.importar_reserva(p_dados jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare m jsonb; l jsonb; s jsonb; it jsonb; v_mat uuid; v_pl uuid; v_ano int; v_data timestamptz; v_orgao text;
        n_novos int := 0; n_exist int := 0; n_lotes int := 0; n_lotes_dup int := 0; n_s int := 0; n_s_dup int := 0; v_neg text;
begin
  perform public._exigir('ADMIN', array['ADMIN']);
  for m in select * from jsonb_array_elements(coalesce(p_dados->'materiais', '[]')) loop
    select id into v_mat from public.materiais where public._nome_norm(descricao) = public._nome_norm(m->>'nome') order by criado_em limit 1;
    if v_mat is null then
      v_ano := extract(year from now())::int;
      insert into public.materiais (codigo, descricao, especificacao, categoria, unidade_medida, localizacao, foto, origem, criado_por)
      values ('RT-' || lpad(public._proximo(-v_ano)::text, 4, '0'), regexp_replace(trim(m->>'nome'), '\s+', ' ', 'g'), coalesce(m->>'especificacao', ''), coalesce(m->>'categoria', 'Outros'),
              coalesce(nullif(m->>'unidade', ''), 'UNIDADE'), 'Almoxarifado Central', m->>'foto', 'planilha', auth.uid())
      returning id into v_mat;
      n_novos := n_novos + 1;
    else
      n_exist := n_exist + 1;
      update public.materiais set foto = coalesce(foto, m->>'foto'),
             especificacao = case when coalesce(especificacao, '') = '' then coalesce(m->>'especificacao', '') else especificacao end
       where id = v_mat;
    end if;
    for l in select * from jsonb_array_elements(coalesce(m->'lotes', '[]')) loop
      if exists (select 1 from public.lotes x where x.material_id = v_mat and x.data = (l->>'data')::date and x.qtd = (l->>'qtd')::int
                   and x.vu = coalesce(nullif(l->>'vu', '')::numeric, 0) and coalesce(x.empenho, '') = coalesce(l->>'empenho', '') and coalesce(x.processo, '') = coalesce(l->>'processo', '')) then
        n_lotes_dup := n_lotes_dup + 1; continue;
      end if;
      insert into public.lotes (material_id, data, qtd, vu, pregao, requisicao, empenho, processo, obs, origem, criado_por)
      values (v_mat, (l->>'data')::date, (l->>'qtd')::int, coalesce(nullif(l->>'vu', '')::numeric, 0), coalesce(l->>'pregao', ''), coalesce(l->>'requisicao', ''),
              coalesce(l->>'empenho', ''), coalesce(l->>'processo', ''), coalesce(l->>'obs', ''), 'planilha', auth.uid());
      n_lotes := n_lotes + 1;
    end loop;
  end loop;

  for s in select * from jsonb_array_elements(coalesce(p_dados->'saidas', '[]')) order by (value->>'data') loop
    v_data := ((s->>'data')::date + time '12:00')::timestamptz;
    if exists (select 1 from public.planos p where p.legado and coalesce(p.processo, '') = coalesce(s->>'processo', '')
                 and public._nome_norm(p.unidade) = public._nome_norm(s->>'destino') and p.criado_em::date = (s->>'data')::date) then
      n_s_dup := n_s_dup + 1; continue;
    end if;
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
      where public._nome_norm(mm.descricao) = public._nome_norm(it->>'nome')
      order by mm.criado_em limit 1
      on conflict (plano_id, material_id) do update set qtd = public.plano_itens.qtd + excluded.qtd;
    end loop;
    insert into public.plano_etapas (plano_id, status, em) values (v_pl, 'ENTREGUE', v_data);
    insert into public.entregas (plano_id, data, recebedor, siape, cargo, local, registrado_por)
    values (v_pl, v_data, 'Não informado (registro da planilha)', '—', '—', s->>'destino', auth.uid());
    insert into public.eventos (plano_id, em, por, papel, tipo, msg) values (v_pl, v_data, auth.uid(), 'ADMIN', 'importacao', 'Saída importada da planilha de controle anterior · processo ' || coalesce(nullif(s->>'processo', ''), 'não informado'));
    n_s := n_s + 1;
  end loop;

  select string_agg(descricao, ', ') into v_neg from public.materiais mm where public.disponivel(mm.id) < 0;
  if v_neg is not null then
    raise exception 'A importação deixaria saldo negativo em: %. Nada foi gravado. Confira se as saídas da planilha já foram registradas no Destina de outra forma.', v_neg;
  end if;
  return jsonb_build_object('materiais', n_novos + n_exist, 'novos', n_novos, 'existentes', n_exist, 'lotes', n_lotes, 'lotes_repetidos', n_lotes_dup, 'saidas', n_s, 'saidas_repetidas', n_s_dup);
end $$;

revoke all on function public._nome_norm(text) from public, anon, authenticated;
revoke all on function public.importar_reserva(jsonb) from public, anon;
grant execute on function public.importar_reserva(jsonb) to authenticated;
