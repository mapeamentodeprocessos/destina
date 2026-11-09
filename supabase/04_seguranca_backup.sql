-- Destina · 04 · cadastro só com e-mail institucional, exceções autorizadas e sinal de atividade
-- Rode depois de 01, 02 e 03. Pode ser rodado de novo sem problema.

-- E-mails fora do domínio ufpb.br que o administrador autorizou a se cadastrar
create table if not exists public.emails_permitidos (
  email text primary key check (email = lower(email)),
  incluido_por uuid references auth.users(id) on delete set null,
  incluido_em timestamptz not null default now()
);
alter table public.emails_permitidos enable row level security;
drop policy if exists "administrador consulta" on public.emails_permitidos;
create policy "administrador consulta" on public.emails_permitidos for select to authenticated using (public.tem_papel('ADMIN'));
revoke all on public.emails_permitidos from anon, public;
grant select on public.emails_permitidos to authenticated;

-- Aceita @ufpb.br e subdomínios (@academico.ufpb.br, @ccs.ufpb.br...) ou e-mail autorizado
create or replace function public._email_aceito(p text) returns boolean
language sql stable security definer set search_path = '' as $$
  select lower(coalesce(p, '')) ~ '@([a-z0-9-]+\.)*ufpb\.br$'
      or exists (select 1 from public.emails_permitidos where email = lower(p));
$$;

-- Barreira no próprio banco: nenhum cadastro passa sem e-mail aceito
create or replace function public._validar_email_cadastro() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.email is not null and not public._email_aceito(new.email) then
    raise exception 'DESTINA_EMAIL_NAO_INSTITUCIONAL' using errcode = 'check_violation';
  end if;
  return new;
end $$;
drop trigger if exists validar_email_cadastro on auth.users;
create trigger validar_email_cadastro before insert or update of email on auth.users
  for each row execute function public._validar_email_cadastro();

create or replace function public.autorizar_email(p_email text) returns void
language plpgsql security definer set search_path = '' as $$
declare e text := lower(trim(coalesce(p_email, '')));
begin
  if not public.tem_papel('ADMIN') then raise exception 'Somente o gestor do sistema autoriza e-mails externos.'; end if;
  if e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'E-mail inválido.'; end if;
  insert into public.emails_permitidos (email, incluido_por) values (e, auth.uid()) on conflict (email) do nothing;
end $$;

create or replace function public.remover_email(p_email text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.tem_papel('ADMIN') then raise exception 'Somente o gestor do sistema remove e-mails externos.'; end if;
  delete from public.emails_permitidos where email = lower(trim(p_email));
end $$;

-- Sinal de atividade: usado pela rotina automática que evita a pausa do projeto gratuito
create or replace function public.ping() returns timestamptz language sql stable as $$ select now() $$;

revoke all on function public._email_aceito(text), public._validar_email_cadastro(), public.autorizar_email(text), public.remover_email(text), public.ping() from public, anon, authenticated;
grant execute on function public.autorizar_email(text), public.remover_email(text) to authenticated;
grant execute on function public.ping() to anon, authenticated;

-- Contas que já existem continuam valendo; o e-mail do primeiro administrador fica autorizado
insert into public.emails_permitidos (email)
  select lower(email) from auth.users where email is not null and lower(email) !~ '@([a-z0-9-]+\.)*ufpb\.br$'
  on conflict do nothing;
