-- Destina · 05 · assinatura reforçada (senha confirmada + código por e-mail), comprovante,
-- verificação pública do termo (QR Code) e infraestrutura de envio de e-mail (Brevo).
-- Rode depois de 01 a 04. Pode ser rodado de novo sem problema.
--
-- Para ligar o envio de e-mails, rode UMA vez no SQL Editor (com os seus dados):
--   select vault.create_secret('SUA-CHAVE-API-DO-BREVO', 'brevo_api_key');
--   select vault.create_secret('remetente@verificado-no-brevo', 'brevo_remetente');
-- Enquanto essas chaves não existirem, o sistema exige só a confirmação de senha.

create extension if not exists pg_net;

-- ---------- envio de e-mail ----------
create or replace function public._segredo(p_nome text) returns text
language sql stable security definer set search_path = '' as $$
  select decrypted_secret from vault.decrypted_secrets where name = p_nome limit 1;
$$;

create or replace function public._email_ativo() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(public._segredo('brevo_api_key'), '') <> '' and coalesce(public._segredo('brevo_remetente'), '') <> '';
$$;

create or replace function public._url_sistema() returns text
language sql stable security definer set search_path = '' as $$
  select coalesce(nullif(public._cfg()->>'url_sistema', ''), 'https://mapeamentodeprocessos.github.io/destina/');
$$;

create table if not exists public.emails_enviados (
  id bigserial primary key,
  para text not null, assunto text not null, motivo text,
  plano_id uuid references public.planos(id) on delete set null,
  pedido_id bigint, em timestamptz not null default now()
);
alter table public.emails_enviados enable row level security;
drop policy if exists "administrador consulta" on public.emails_enviados;
create policy "administrador consulta" on public.emails_enviados for select to authenticated using (public.tem_papel('ADMIN'));
revoke all on public.emails_enviados from anon, public;
grant select on public.emails_enviados to authenticated;

-- Moldura padrão dos e-mails do Destina
create or replace function public._email_html(p_titulo text, p_corpo text, p_botao text default null, p_link text default null) returns text
language sql immutable set search_path = '' as $$
  select '<div style="font-family:Arial,Helvetica,sans-serif;max-width:560px;margin:0 auto;color:#1B2433">'
    || '<div style="background:#0B3A75;color:#fff;padding:16px 20px;border-radius:10px 10px 0 0"><b style="font-size:16px">Destina</b><span style="opacity:.8"> · Gestão da Reserva Técnica · UFPB</span></div>'
    || '<div style="border:1px solid #E1E6EE;border-top:0;padding:20px;border-radius:0 0 10px 10px">'
    || '<h2 style="font-size:18px;margin:0 0 12px">' || p_titulo || '</h2>' || p_corpo
    || case when p_link is not null then '<p style="margin:22px 0 6px"><a href="' || p_link || '" style="background:#0B3A75;color:#fff;text-decoration:none;padding:11px 18px;border-radius:8px;font-weight:bold;display:inline-block">' || coalesce(p_botao, 'Abrir no Destina') || '</a></p>' else '' end
    || '<p style="font-size:12px;color:#6B7586;margin-top:22px">Mensagem automática do sistema Destina. Não responda este e-mail.</p></div></div>';
$$;

create or replace function public._enviar_email(p_para text, p_nome text, p_assunto text, p_html text, p_motivo text default null, p_plano uuid default null) returns boolean
language plpgsql security definer set search_path = '' as $$
declare v_key text := public._segredo('brevo_api_key'); v_de text := public._segredo('brevo_remetente'); v_id bigint;
begin
  if coalesce(v_key, '') = '' or coalesce(v_de, '') = '' or coalesce(p_para, '') = '' then return false; end if;
  select net.http_post(
    url := 'https://api.brevo.com/v3/smtp/email',
    headers := jsonb_build_object('api-key', v_key, 'content-type', 'application/json', 'accept', 'application/json'),
    body := jsonb_build_object('sender', jsonb_build_object('name', 'Destina · UFPB', 'email', v_de),
                               'to', jsonb_build_array(jsonb_build_object('email', p_para, 'name', coalesce(nullif(p_nome, ''), p_para))),
                               'subject', p_assunto, 'htmlContent', p_html)) into v_id;
  insert into public.emails_enviados (para, assunto, motivo, plano_id, pedido_id) values (p_para, p_assunto, p_motivo, p_plano, v_id);
  return true;
exception when others then
  return false;  -- e-mail nunca impede o fluxo
end $$;

-- ---------- código de assinatura ----------
create table if not exists public.assinatura_codigos (
  id bigserial primary key,
  usuario uuid not null references auth.users(id) on delete cascade,
  papel text not null,
  codigo_hash text not null,
  criado_em timestamptz not null default now(),
  expira_em timestamptz not null,
  tentativas int not null default 0,
  conferido_em timestamptz
);
create index if not exists assinatura_codigos_usuario on public.assinatura_codigos (usuario, criado_em desc);
alter table public.assinatura_codigos enable row level security;  -- sem políticas: só as funções acessam
revoke all on public.assinatura_codigos from anon, authenticated, public;

alter table public.assinaturas add column if not exists evidencias jsonb;

-- A senha foi digitada nos últimos 10 minutos? (o token do Supabase registra quando houve login por senha)
create or replace function public._senha_recente() returns timestamptz
language sql stable set search_path = '' as $$
  select to_timestamp(max((x->>'timestamp')::bigint))
  from jsonb_array_elements(coalesce(auth.jwt()->'amr', '[]'::jsonb)) x
  where x->>'method' = 'password'
  having max((x->>'timestamp')::bigint) > extract(epoch from now()) - 600;
$$;

create or replace function public._mascarar_email(p text) returns text
language sql immutable set search_path = '' as $$
  select case when p like '%@%' then left(split_part(p, '@', 1), 2) || '•••@' || split_part(p, '@', 2) else p end;
$$;

-- Envia um código de 6 dígitos para o e-mail do signatário (vale 10 minutos)
create or replace function public.pedir_codigo_assinatura(p_papel text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_email text; v_nome text; v_cod text; v_ult timestamptz; v_hora int;
begin
  perform public._exigir(p_papel, array['PRA','REITORIA']);
  if not public._email_ativo() then return jsonb_build_object('exige_codigo', false); end if;
  select max(criado_em), count(*) filter (where criado_em > now() - interval '1 hour') into v_ult, v_hora
    from public.assinatura_codigos where usuario = auth.uid();
  if v_ult > now() - interval '45 seconds' then raise exception 'Aguarde alguns segundos para pedir um novo código.'; end if;
  if v_hora >= 6 then raise exception 'Muitos códigos pedidos na última hora. Tente mais tarde.'; end if;
  select u.email, coalesce(p.nome, u.email) into v_email, v_nome from auth.users u left join public.perfis p on p.id = u.id where u.id = auth.uid();
  v_cod := lpad((((('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::int) & 2147483647) % 1000000)::text, 6, '0');
  insert into public.assinatura_codigos (usuario, papel, codigo_hash, expira_em)
    values (auth.uid(), p_papel, public._sha(v_cod || '|' || auth.uid()), now() + interval '10 minutes');
  perform public._enviar_email(v_email, v_nome, 'Código para assinar no Destina: ' || v_cod,
    public._email_html('Seu código de assinatura',
      '<p>Use o código abaixo para confirmar a sua assinatura eletrônica no Destina. Ele vale por 10 minutos.</p>'
      || '<p style="font-size:30px;letter-spacing:6px;font-weight:bold;margin:16px 0">' || v_cod || '</p>'
      || '<p style="color:#6B7586;font-size:13px">Se não foi você quem pediu, ignore este e-mail e avise a Divisão de Patrimônio.</p>'),
    'codigo_assinatura');
  return jsonb_build_object('exige_codigo', true, 'enviado_para', public._mascarar_email(v_email));
end $$;

-- Confere o código digitado (não lança erro, para registrar as tentativas erradas)
create or replace function public.conferir_codigo_assinatura(p_papel text, p_codigo text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c public.assinatura_codigos;
begin
  perform public._exigir(p_papel, array['PRA','REITORIA']);
  select * into c from public.assinatura_codigos
    where usuario = auth.uid() and papel = p_papel and conferido_em is null and expira_em > now()
    order by criado_em desc limit 1;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'Código vencido ou inexistente. Peça um novo código.'); end if;
  if c.tentativas >= 5 then return jsonb_build_object('ok', false, 'motivo', 'Muitas tentativas erradas. Peça um novo código.'); end if;
  if c.codigo_hash <> public._sha(regexp_replace(coalesce(p_codigo, ''), '\D', '', 'g') || '|' || auth.uid()) then
    update public.assinatura_codigos set tentativas = tentativas + 1 where id = c.id;
    return jsonb_build_object('ok', false, 'motivo', 'Código incorreto. Restam ' || (4 - c.tentativas) || ' tentativas.');
  end if;
  update public.assinatura_codigos set conferido_em = now(), expira_em = now() + interval '15 minutes' where id = c.id;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- assinatura com as novas exigências ----------
drop function if exists public.assinar_plano(text, uuid);
create or replace function public.assinar_plano(p_papel text, p_id uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare r public.planos; c jsonb := public._cfg(); v_pend text[]; v_sig text; v_em timestamptz := now();
        v_senha timestamptz := public._senha_recente(); v_cod public.assinatura_codigos; v_email text; v_nome text; v_hdr json; v_ev jsonb; v_cv text;
begin
  perform public._exigir(p_papel, array['PRA','REITORIA']);
  r := public._plano(p_id, array['AUTORIZACAO']);
  if v_senha is null then raise exception 'DESTINA_CONFIRMAR_SENHA: confirme a sua senha para assinar.'; end if;
  if public._email_ativo() then
    select * into v_cod from public.assinatura_codigos
      where usuario = auth.uid() and papel = p_papel and conferido_em is not null and expira_em > now()
      order by conferido_em desc limit 1;
    if not found then raise exception 'DESTINA_CODIGO: confirme o código enviado ao seu e-mail.'; end if;
  end if;
  if not (p_papel = any(r.assinaturas_exigidas)) then raise exception 'Este plano não exige a assinatura deste perfil.'; end if;
  if exists (select 1 from public.assinaturas where plano_id = p_id and papel = p_papel) then raise exception 'Este perfil já assinou o plano.'; end if;
  select array_agg(x order by ord) into v_pend from unnest(r.assinaturas_exigidas) with ordinality as t(x, ord)
    where not exists (select 1 from public.assinaturas a where a.plano_id = p_id and a.papel = x);
  if coalesce((c->>'sequencial')::boolean, true) and v_pend[1] <> p_papel then raise exception 'Aguarde a assinatura de % antes.', v_pend[1]; end if;
  if public._sha(public.doc_canonico(p_id)) <> r.doc_hash then raise exception 'O conteúdo do termo mudou depois da formalização. Indefira e peça nova instrução.'; end if;
  select u.email, coalesce(p.nome, u.email) into v_email, v_nome from auth.users u left join public.perfis p on p.id = u.id where u.id = auth.uid();
  begin v_hdr := current_setting('request.headers', true)::json; exception when others then v_hdr := null; end;
  v_ev := jsonb_strip_nulls(jsonb_build_object(
    'senha_confirmada_em', (extract(epoch from v_senha) * 1000)::bigint,
    'codigo_email', v_cod.id is not null,
    'codigo_conferido_em', case when v_cod.id is not null then (extract(epoch from v_cod.conferido_em) * 1000)::bigint end,
    'email', public._mascarar_email(v_email),
    'ip', split_part(coalesce(v_hdr->>'x-forwarded-for', v_hdr->>'x-real-ip', ''), ',', 1),
    'navegador', left(v_hdr->>'user-agent', 200)));
  v_sig := public._sha(r.doc_hash || '|' || auth.uid() || '|' || p_papel || '|' || (extract(epoch from v_em) * 1000)::bigint);
  insert into public.assinaturas (plano_id, papel, por, em, doc_hash, sig, nome, cargo, evidencias)
  values (p_id, p_papel, auth.uid(), v_em, r.doc_hash, v_sig, c->'signatarios'->p_papel->>'nome', c->'signatarios'->p_papel->>'cargo', v_ev);
  v_cv := upper(substr(v_sig, 1, 4) || '-' || substr(v_sig, 5, 4) || '-' || substr(v_sig, 9, 4));
  perform public._evento(p_id, p_papel, 'assinatura', 'Autorização assinada eletronicamente por ' || coalesce(c->'signatarios'->p_papel->>'cargo', p_papel)
    || case when v_cod.id is not null then ' (senha + código por e-mail)' else ' (senha confirmada)' end || ' · código ' || v_cv);
  if array_length(v_pend, 1) = 1 then
    perform public._etapa(p_id, 'AUTORIZADO');
    perform public._evento(p_id, p_papel, 'autorizado', 'Destinação autorizada · bens reservados para a unidade');
  end if;
  -- comprovante ao signatário
  perform public._enviar_email(v_email, v_nome, 'Comprovante de assinatura · ' || r.numero,
    public._email_html('Você assinou o termo ' || r.numero,
      '<p>Registramos a sua assinatura eletrônica como <b>' || coalesce(c->'signatarios'->p_papel->>'cargo', p_papel) || '</b>.</p>'
      || '<table style="font-size:14px;border-collapse:collapse"><tr><td style="padding:4px 12px 4px 0;color:#6B7586">Unidade</td><td>' || coalesce(r.unidade, '') || '</td></tr>'
      || '<tr><td style="padding:4px 12px 4px 0;color:#6B7586">Data e hora</td><td>' || to_char(v_em at time zone 'America/Fortaleza', 'DD/MM/YYYY HH24:MI') || '</td></tr>'
      || '<tr><td style="padding:4px 12px 4px 0;color:#6B7586">Código de verificação</td><td><b>' || v_cv || '</b></td></tr></table>'
      || '<p style="color:#6B7586;font-size:13px;margin-top:14px">Se você não reconhece esta assinatura, avise imediatamente a Divisão de Patrimônio.</p>',
      'Verificar o termo', public._url_sistema() || '#verificar-' || v_cv),
    'comprovante_assinatura', p_id);
  return v_sig;
end $$;

-- ---------- verificação pública (QR Code do termo), sem login ----------
create or replace function public.verificar_publico(p_codigo text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare c text := lower(regexp_replace(coalesce(p_codigo, ''), '[^0-9A-Fa-f]', '', 'g')); a public.assinaturas; r public.planos; v_todas jsonb;
begin
  if length(c) < 12 then return jsonb_build_object('encontrado', false); end if;
  select * into a from public.assinaturas where sig like c || '%' order by em limit 1;
  if not found then return jsonb_build_object('encontrado', false); end if;
  select * into r from public.planos where id = a.plano_id;
  select jsonb_agg(jsonb_build_object('cargo', x.cargo, 'nome', x.nome, 'em', (extract(epoch from x.em) * 1000)::bigint,
           'codigo', upper(substr(x.sig, 1, 4) || '-' || substr(x.sig, 5, 4) || '-' || substr(x.sig, 9, 4)),
           'reforcada', coalesce((x.evidencias->>'codigo_email')::boolean, false) or x.evidencias ? 'senha_confirmada_em') order by x.em)
    into v_todas from public.assinaturas x where x.plano_id = r.id;
  return jsonb_build_object('encontrado', true, 'numero', r.numero, 'unidade', r.unidade, 'situacao', r.status,
    'conteudo_ok', public._sha(public.doc_canonico(r.id)) = a.doc_hash,
    'assinatura_ok', public._sha(a.doc_hash || '|' || a.por || '|' || a.papel || '|' || (extract(epoch from a.em) * 1000)::bigint) = a.sig,
    'hash', a.doc_hash, 'assinaturas', coalesce(v_todas, '[]'::jsonb));
end $$;

-- ---------- permissões ----------
revoke all on function public._segredo(text), public._email_ativo(), public._url_sistema(), public._email_html(text, text, text, text),
  public._enviar_email(text, text, text, text, text, uuid), public._senha_recente(), public._mascarar_email(text),
  public.pedir_codigo_assinatura(text), public.conferir_codigo_assinatura(text, text), public.assinar_plano(text, uuid), public.verificar_publico(text)
  from public, anon, authenticated;
grant execute on function public.pedir_codigo_assinatura(text), public.conferir_codigo_assinatura(text, text), public.assinar_plano(text, uuid) to authenticated;
grant execute on function public.verificar_publico(text) to anon, authenticated;
