-- Destina · 16 · toda destinação tem o código organizacional (SIPAC) da unidade de destino
-- Vale para propostas, decisões e planos (exceto saídas históricas importadas da planilha e rascunhos).
-- Quando a estrutura organizacional está carregada, o código precisa existir nela, e o nome da unidade
-- passa a ser o nome oficial do código.
-- Pode ser rodado de novo sem problema.

create or replace function public._exigir_codigo_unidade() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_nome text; j jsonb := to_jsonb(new);
begin
  if tg_table_name = 'planos' and (coalesce((j->>'legado')::boolean, false) or j->>'status' = 'RASCUNHO') then return new; end if;
  if tg_table_name = 'determinacoes' and j->>'situacao' in ('CANCELADA','RECUSADA') then return new; end if;
  if coalesce(trim(new.unidade_code), '') = '' then
    raise exception 'Informe o código organizacional (SIPAC) da unidade de destino.';
  end if;
  if exists (select 1 from public.unidades) then
    select name into v_nome from public.unidades where code = trim(new.unidade_code);
    if v_nome is null then raise exception 'O código organizacional % não existe na estrutura da instituição.', new.unidade_code; end if;
    if coalesce(trim(new.unidade), '') = '' then new.unidade := v_nome; end if;
  end if;
  new.unidade_code := trim(new.unidade_code);
  return new;
end $$;

drop trigger if exists exigir_codigo_unidade on public.determinacoes;
create trigger exigir_codigo_unidade before insert or update of unidade, unidade_code, situacao on public.determinacoes
  for each row execute function public._exigir_codigo_unidade();
drop trigger if exists exigir_codigo_unidade on public.planos;
create trigger exigir_codigo_unidade before insert or update of unidade, unidade_code, status on public.planos
  for each row execute function public._exigir_codigo_unidade();

-- a decisão grava o código vazio como nulo no plano: corrige para passar o código adiante
do $$ declare src text; begin
  select pg_get_functiondef('public.registrar_determinacao(text,jsonb)'::regprocedure) into src;
  src := replace(src, 'values (v_pnum, v_uni, nullif(v_unic, ''''),', 'values (v_pnum, v_uni, nullif(trim(v_unic), ''''),');
  execute src;
end $$;

revoke all on function public._exigir_codigo_unidade() from public, anon, authenticated;
select (select count(*) from public.unidades) as unidades_na_estrutura;
