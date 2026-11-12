-- Destina · desativa as contas de teste (não apaga o que elas registraram: a trilha de auditoria é imutável).
-- As contas deixam de entrar no sistema; o que assinaram continua marcado como [CONTA DE TESTE].
update public.perfis set aprovado = false, papeis = '{}' where teste;
update auth.users set banned_until = 'infinity' where id in (select id from public.perfis where teste);
select email, aprovado from public.perfis where teste order by email;
