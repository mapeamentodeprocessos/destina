-- =====================================================================
-- DESTINA — Gestão da Reserva Técnica
-- 01_schema.sql — rode PRIMEIRO no SQL Editor do Supabase (projeto novo)
--
-- Princípios:
--   * Todo usuário aprovado LÊ os dados (transparência interna).
--   * NINGUÉM grava direto nas tabelas: toda mudança passa por funções
--     (RPC) que conferem o perfil, a etapa do plano e o saldo.
--   * Data/hora, numeração, hash da trilha e assinatura são gerados no
--     servidor. Assinaturas e eventos não podem ser editados nem apagados.
-- =====================================================================
create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Perfis de acesso
-- ---------------------------------------------------------------------
create table public.perfis (
  id uuid primary key references auth.users(id) on delete cascade,
  nome text not null default '',
  email text,
  papeis text[] not null default '{}',
  aprovado boolean not null default false,
  criado_em timestamptz not null default now(),
  constraint papeis_validos check (papeis <@ array['ADMIN','REITORIA','PRA','FORMALIZACAO','PATRIMONIO','ALMOXARIFADO','CONSULTA']::text[])
);

create or replace function public.ao_criar_usuario() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.perfis (id, email, nome)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'nome', split_part(new.email, '@', 1)))
  on conflict (id) do nothing;
  return new;
end $$;
create trigger ao_criar_usuario after insert on auth.users
  for each row execute function public.ao_criar_usuario();

create or replace function public.aprovado() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select aprovado from public.perfis where id = auth.uid()), false)
$$;
create or replace function public.tem_papel(p text) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select aprovado and p = any(papeis) from public.perfis where id = auth.uid()), false)
$$;

-- ---------------------------------------------------------------------
-- Configuração (linha única) e estrutura organizacional (SIPAC)
-- ---------------------------------------------------------------------
create table public.config (
  id int primary key default 1 check (id = 1),
  dados jsonb not null default '{}'::jsonb,
  atualizado_em timestamptz not null default now()
);
insert into public.config (id, dados) values (1, jsonb_build_object(
  'instituicao', 'Universidade Federal da Paraíba', 'sigla', 'UFPB',
  'orgao', 'Pró-Reitoria de Administração — Divisão de Patrimônio',
  'signatarios', jsonb_build_object(
     'PRA', jsonb_build_object('nome', 'George Beltrão', 'cargo', 'Pró-Reitor de Administração'),
     'REITORIA', jsonb_build_object('nome', 'Terezinha Domiciano', 'cargo', 'Reitora')),
  'limiteAlcada', 50000, 'exigirAmbos', false, 'sequencial', true,
  'diasParado', 180, 'diasGarantia', 90,
  'sla', jsonb_build_object('RASCUNHO',5,'INSTRUCAO',5,'AUTORIZACAO',7,'AUTORIZADO',5,'SEPARACAO',3,'PRONTO',5),
  'fundamentacao', 'Instrução Normativa SEDAP nº 205/1988, que disciplina a racionalização e a distribuição de material na Administração Pública Federal, e normas internas de gestão patrimonial da UFPB.'
)) on conflict do nothing;

create table public.unidades (
  code text primary key,
  name text not null,
  parent_code text,
  ordem int not null default 0
);
create index unidades_parent on public.unidades(parent_code);
create table public.estrutura_meta (
  id int primary key default 1 check (id = 1),
  fonte text, atualizado_em text
);

-- ---------------------------------------------------------------------
-- Reserva técnica: materiais e lotes de entrada
-- ---------------------------------------------------------------------
create table public.materiais (
  id uuid primary key default gen_random_uuid(),
  codigo text unique not null,
  descricao text not null,
  especificacao text default '',
  categoria text not null default 'Outros',
  unidade_medida text not null default 'UNIDADE',
  localizacao text default '',
  marca text default '', modelo text default '', fornecedor text default '',
  garantia_ate date,
  exige_tombamento boolean not null default true,
  foto text,                      -- miniatura (data URL JPEG)
  obs text default '',
  origem text default '',
  criado_por uuid references public.perfis(id),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create unique index materiais_nome_unico on public.materiais (upper(regexp_replace(trim(descricao), '\s+', ' ', 'g')));

create table public.lotes (
  id uuid primary key default gen_random_uuid(),
  material_id uuid not null references public.materiais(id) on delete cascade,
  data date not null,
  qtd int not null check (qtd > 0),
  vu numeric(14,2) not null default 0 check (vu >= 0),
  pregao text default '', requisicao text default '', empenho text default '',
  processo text default '', nf text default '', obs text default '', origem text default '',
  criado_por uuid references public.perfis(id),
  criado_em timestamptz not null default now()
);
create index lotes_material on public.lotes(material_id);

-- ---------------------------------------------------------------------
-- Planos de destinação
-- ---------------------------------------------------------------------
create table public.contadores (ano int primary key, ultimo int not null default 0);

create table public.planos (
  id uuid primary key default gen_random_uuid(),
  numero text unique not null,
  legado boolean not null default false,
  status text not null default 'RASCUNHO'
    check (status in ('RASCUNHO','INSTRUCAO','AUTORIZACAO','AUTORIZADO','SEPARACAO','PRONTO','ENTREGUE','INDEFERIDO','CANCELADO')),
  unidade text not null,
  unidade_code text references public.unidades(code) on update cascade on delete set null,
  orgao_code text,
  finalidade text not null default '',
  justificativa text not null default '',
  demanda text default '',
  processo text default '', fundamentacao text default '', despacho text default '',
  assinaturas_exigidas text[] not null default '{}',
  doc_hash text,
  conferencia jsonb not null default '{}'::jsonb,
  devolucao text, indeferimento jsonb, cancelamento jsonb,
  criado_por uuid references public.perfis(id),
  criado_em timestamptz not null default now(),
  etapa_em timestamptz not null default now()
);
create index planos_status on public.planos(status);

create table public.plano_itens (
  plano_id uuid not null references public.planos(id) on delete cascade,
  material_id uuid not null references public.materiais(id),
  qtd int not null check (qtd > 0),
  vu numeric(14,2) not null default 0,
  codigo text, descricao text,
  primary key (plano_id, material_id)
);
create index plano_itens_material on public.plano_itens(material_id);

create table public.plano_etapas (
  id bigserial primary key,
  plano_id uuid not null references public.planos(id) on delete cascade,
  status text not null,
  em timestamptz not null default now()
);
create index plano_etapas_plano on public.plano_etapas(plano_id);

-- Trilha de auditoria encadeada por hash (append-only)
create table public.eventos (
  id bigserial primary key,
  plano_id uuid not null references public.planos(id) on delete cascade,
  em timestamptz not null default now(),
  por uuid references public.perfis(id),
  papel text,
  tipo text not null,
  msg text not null,
  prev text,
  hash text
);
create index eventos_plano on public.eventos(plano_id, id);

create or replace function public.eventos_hash() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_prev text;
begin
  perform pg_advisory_xact_lock(hashtext(new.plano_id::text));
  select hash into v_prev from public.eventos where plano_id = new.plano_id order by id desc limit 1;
  new.prev := coalesce(v_prev, repeat('0', 64));
  new.em := coalesce(new.em, now());
  new.hash := encode(extensions.digest(new.prev || '|' || (extract(epoch from new.em) * 1000)::bigint || '|' || coalesce(new.por::text, '') || '|' || coalesce(new.papel, '') || '|' || new.tipo || '|' || new.msg, 'sha256'), 'hex');
  return new;
end $$;
create trigger eventos_hash before insert on public.eventos for each row execute function public.eventos_hash();

create table public.assinaturas (
  id bigserial primary key,
  plano_id uuid not null references public.planos(id) on delete cascade,
  papel text not null check (papel in ('PRA','REITORIA')),
  por uuid not null references public.perfis(id),
  em timestamptz not null default now(),
  doc_hash text not null,
  sig text not null unique,
  nome text, cargo text,
  unique (plano_id, papel)
);

create table public.entregas (
  plano_id uuid primary key references public.planos(id) on delete cascade,
  data timestamptz not null,
  recebedor text not null, siape text not null, cargo text, local text,
  registrado_por uuid references public.perfis(id),
  registrado_em timestamptz not null default now()
);
create table public.tombamentos (
  numero text primary key,                 -- impede tombamento repetido
  plano_id uuid not null references public.planos(id) on delete cascade,
  material_id uuid not null references public.materiais(id)
);
create index tombamentos_plano on public.tombamentos(plano_id);

-- Registro do assistente
create table public.log_assistente (
  id bigserial primary key,
  em timestamptz not null default now(),
  por uuid not null default auth.uid() references public.perfis(id),
  papel text, tipo text not null, texto text, acao jsonb
);
create index log_assistente_em on public.log_assistente(em desc);

-- Bloqueio de edição/remoção em registros que precisam ser imutáveis
create or replace function public.imutavel() returns trigger language plpgsql as $$
begin raise exception 'Registro imutável: % não pode ser alterado nem apagado.', tg_table_name; end $$;
create trigger eventos_imutavel before update or delete on public.eventos for each row
  when (pg_trigger_depth() = 0) execute function public.imutavel();
create trigger assinaturas_imutavel before update or delete on public.assinaturas for each row
  when (pg_trigger_depth() = 0) execute function public.imutavel();

-- ---------------------------------------------------------------------
-- RLS: leitura para aprovados; escrita só por funções
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['config','unidades','estrutura_meta','materiais','lotes','planos','plano_itens','plano_etapas','eventos','assinaturas','entregas','tombamentos','log_assistente','contadores'] loop
    execute format('alter table public.%I enable row level security', t);
    if t <> 'contadores' then
      execute format('create policy "leitura aprovados" on public.%I for select to authenticated using (public.aprovado())', t);
    end if;
  end loop;
end $$;
alter table public.perfis enable row level security;
create policy "perfil proprio ou aprovados" on public.perfis for select to authenticated
  using (id = auth.uid() or public.aprovado());
create policy "registrar log proprio" on public.log_assistente for insert to authenticated
  with check (por = auth.uid() and public.aprovado());

-- Permissões explícitas da API (não dependem da opção "expor novas tabelas" do painel).
-- O RLS acima continua decidindo o que cada usuário vê; gravações só pelas funções.
revoke all on all tables in schema public from anon;
grant usage on schema public to authenticated;
grant select on all tables in schema public to authenticated;
grant insert on public.log_assistente to authenticated;
grant usage on all sequences in schema public to authenticated;
