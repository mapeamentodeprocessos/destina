-- Destina · 19 · documento autorizativo anexado ao plano
-- A Formalização envia o documento (PDF ou imagem) que comprova a autorização. O arquivo fica no
-- armazenamento privado do Supabase (bucket "documentos"), e o registro, com o hash SHA-256, em plano_anexos.
-- Os anexos não podem ser alterados nem apagados pelo sistema: uma correção entra como nova versão.
-- A formalização só é aceita com um documento autorizativo anexado.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('documentos', 'documentos', false, 10485760, array['application/pdf','image/jpeg','image/png'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "destina documentos leitura" on storage.objects;
create policy "destina documentos leitura" on storage.objects for select to authenticated
  using (bucket_id = 'documentos' and public.aprovado());
drop policy if exists "destina documentos envio" on storage.objects;
create policy "destina documentos envio" on storage.objects for insert to authenticated
  with check (bucket_id = 'documentos' and (public.tem_papel('FORMALIZACAO') or public.tem_papel('ADMIN')));

create table if not exists public.plano_anexos (
  id uuid primary key default gen_random_uuid(),
  plano_id uuid not null references public.planos(id) on delete cascade,
  tipo text not null default 'AUTORIZACAO' check (tipo in ('AUTORIZACAO','OUTRO')),
  nome text not null,
  descricao text not null default '',
  mime text not null,
  tamanho bigint not null,
  sha256 text not null,
  caminho text not null unique,
  enviado_por uuid references auth.users(id),
  papel text,
  enviado_em timestamptz not null default now()
);
create index if not exists plano_anexos_plano on public.plano_anexos(plano_id);
alter table public.plano_anexos enable row level security;
drop policy if exists "aprovados leem anexos" on public.plano_anexos;
create policy "aprovados leem anexos" on public.plano_anexos for select to authenticated using (public.aprovado());
revoke all on public.plano_anexos from anon, public;
grant select on public.plano_anexos to authenticated;

create or replace function public.anexar_documento(p_papel text, p_plano uuid, p_tipo text, p_nome text, p_descricao text,
                                                    p_mime text, p_tamanho bigint, p_sha256 text, p_caminho text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_num text; v_st text;
begin
  perform public._exigir(p_papel, array['FORMALIZACAO','ADMIN']);
  select numero, status into v_num, v_st from public.planos where id = p_plano;
  if v_num is null then raise exception 'Plano não encontrado.'; end if;
  if v_st in ('CANCELADO') then raise exception 'O plano está cancelado.'; end if;
  if p_tipo not in ('AUTORIZACAO','OUTRO') then raise exception 'Tipo de documento inválido.'; end if;
  if coalesce(p_sha256, '') !~ '^[0-9a-f]{64}$' then raise exception 'Hash do arquivo inválido.'; end if;
  if p_caminho not like p_plano::text || '/%' then raise exception 'Caminho do arquivo inválido.'; end if;
  if not exists (select 1 from storage.objects where bucket_id = 'documentos' and name = p_caminho) then
    raise exception 'O arquivo não chegou ao armazenamento. Envie de novo.';
  end if;
  insert into public.plano_anexos (plano_id, tipo, nome, descricao, mime, tamanho, sha256, caminho, enviado_por, papel)
  values (p_plano, p_tipo, left(trim(p_nome), 200), left(coalesce(trim(p_descricao), ''), 300), p_mime, p_tamanho, p_sha256, p_caminho, auth.uid(), p_papel)
  returning id into v_id;
  perform public._evento(p_plano, p_papel, 'documento',
    (case when p_tipo = 'AUTORIZACAO' then 'Documento autorizativo anexado: ' else 'Documento anexado: ' end)
    || left(trim(p_nome), 120) || ' · SHA-256 ' || substr(p_sha256, 1, 16) || '…');
  return v_id;
end $$;
revoke all on function public.anexar_documento(text, uuid, text, text, text, text, bigint, text, text) from public, anon;
grant execute on function public.anexar_documento(text, uuid, text, text, text, text, bigint, text, text) to authenticated;

-- formalização exige o documento autorizativo
do $$ declare src text; begin
  select pg_get_functiondef('public.formalizar_plano(text,uuid,text,text,text)'::regprocedure) into src;
  if position('plano_anexos' in src) = 0 then
    src := replace(src, 'perform public._validar_saldo(p_id);',
      'perform public._validar_saldo(p_id);
  if not exists (select 1 from public.plano_anexos where plano_id = p_id and tipo = ''AUTORIZACAO'') then
    raise exception ''Anexe o documento autorizativo antes de formalizar.'';
  end if;');
    execute src;
  end if;
end $$;

select position('plano_anexos' in pg_get_functiondef('public.formalizar_plano(text,uuid,text,text,text)'::regprocedure)) > 0 as formalizacao_exige_documento;
