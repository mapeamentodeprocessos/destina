-- DESTINA — quem inicia o plano de destinação
-- Via de regra, a decisão da Reitoria ou da PRA (registrar_determinacao) inicia o plano.
-- A Divisão de Patrimônio e o Almoxarifado também podem iniciar; a Formalização continua editando na instrução.
do $$ declare src text; begin
  select pg_get_functiondef('public.salvar_plano(text,uuid,jsonb,boolean)'::regprocedure) into src;
  if src like '%array[''PATRIMONIO'',''FORMALIZACAO'',''ADMIN'']%' then
    execute replace(src, 'array[''PATRIMONIO'',''FORMALIZACAO'',''ADMIN'']', 'array[''PATRIMONIO'',''ALMOXARIFADO'',''FORMALIZACAO'',''ADMIN'']');
  end if;
end $$;
select position('ALMOXARIFADO' in pg_get_functiondef('public.salvar_plano(text,uuid,jsonb,boolean)'::regprocedure)) > 0 as almox_pode_iniciar;
