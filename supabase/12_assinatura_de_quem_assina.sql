-- Destina · 12 · a assinatura registra quem de fato assinou
-- Antes, o termo gravava o nome do signatário configurado (ex.: o titular do cargo), mesmo que outra
-- conta tivesse assinado. Agora grava o nome do perfil que assinou; o cargo continua o da configuração.
-- Também marca contas de teste, para que apareçam como tal e possam ser removidas depois.
-- Pode ser rodado de novo sem problema.

alter table public.perfis add column if not exists teste boolean not null default false;

do $$ declare src text; begin
  select pg_get_functiondef('public.assinar_plano(text,uuid)'::regprocedure) into src;
  if position('c->''signatarios''->p_papel->>''nome'', c->''signatarios''->p_papel->>''cargo'', v_ev' in src) > 0 then
    execute replace(src,
      'c->''signatarios''->p_papel->>''nome'', c->''signatarios''->p_papel->>''cargo'', v_ev',
      'coalesce((select nullif(trim(nome), '''') || case when teste then '' [CONTA DE TESTE]'' else '''' end from public.perfis where id = auth.uid()), c->''signatarios''->p_papel->>''nome''), c->''signatarios''->p_papel->>''cargo'', v_ev');
  end if;
end $$;

select position('CONTA DE TESTE' in pg_get_functiondef('public.assinar_plano(text,uuid)'::regprocedure)) > 0 as assinatura_com_nome_de_quem_assina;
