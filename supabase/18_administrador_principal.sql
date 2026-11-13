-- Destina · 18 · administrador principal (permanente)
-- A conta marcada como principal não pode perder o perfil de administrador, ser desaprovada nem excluída pelo sistema.
-- Só o dono do projeto, no editor SQL do Supabase, pode mudar isso. Também impede ficar sem nenhum administrador.
alter table public.perfis add column if not exists principal boolean not null default false;

create or replace function public._proteger_admin() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then -- editor SQL / manutenção: liberado
    return coalesce(new, old);
  end if;
  if tg_op = 'DELETE' then
    if old.principal then raise exception 'O administrador principal não pode ser excluído.'; end if;
    return old;
  end if;
  if new.principal is distinct from old.principal then
    raise exception 'A marcação de administrador principal só pode ser alterada pelo dono do projeto.';
  end if;
  if old.principal and (not new.aprovado or not ('ADMIN' = any(new.papeis))) then
    raise exception 'O administrador principal não pode perder o acesso de administrador.';
  end if;
  if 'ADMIN' = any(old.papeis) and old.aprovado and (not new.aprovado or not ('ADMIN' = any(new.papeis)))
     and not exists (select 1 from public.perfis where id <> old.id and aprovado and 'ADMIN' = any(papeis)) then
    raise exception 'O sistema precisa de pelo menos um administrador.';
  end if;
  return new;
end $$;

drop trigger if exists proteger_admin on public.perfis;
create trigger proteger_admin before update or delete on public.perfis
  for each row execute function public._proteger_admin();
