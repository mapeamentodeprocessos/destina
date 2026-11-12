# Destina — Gestão da Reserva Técnica

Sistema web (computador, tablet e celular) para gestão e controle da reserva técnica de bens permanentes: planos de destinação com alçada de assinatura, formalização documental, separação, entrega com tombamento, termos com código de autenticidade, painel, alertas e assistente.

- **Front-end:** um único `index.html` (sem build), hospedado no GitHub Pages.
- **Back-end:** Supabase (Postgres + Auth), acessado por REST puro (`fetch`), sem SDK.
- **Modo demonstração:** funciona sem servidor, com dados fictícios guardados no navegador.

## Estrutura

```
index.html                 aplicação completa
config.js                  URL e chave pública do Supabase (você preenche)
supabase/01_schema.sql     tabelas, regras de acesso (RLS), gatilhos de auditoria
supabase/02_funcoes.sql    funções do fluxo (toda gravação passa por elas)
supabase/03_unidades.sql   hierarquia SIPAC/UFPB (1.653 unidades, emitida em 19/07/2026)
```

## Implantação (cerca de 20 minutos)

### 1. Supabase
1. Crie um projeto novo em supabase.com (região São Paulo).
2. Em **SQL Editor**, rode os arquivos **nesta ordem**: `01_schema.sql`, `02_funcoes.sql`, `03_unidades.sql`.
   Se um arquivo for grande demais para colar no editor, rode-o direto do repositório:
   ```sql
   create extension if not exists http with schema extensions;
   do $$ begin execute (select content from extensions.http_get(
     'https://raw.githubusercontent.com/SEU-USUARIO/destina/main/supabase/02_funcoes.sql')); end $$;
   ```
   Os scripts já retiram de `anon`/`public` o acesso às tabelas e às funções internas; só usuários autenticados e aprovados leem dados, e toda gravação passa pelas funções.
3. Em **Authentication › Sign In / Providers › Email**, mantenha o e-mail ativo. Recomendado: deixar "Confirm email" ligado.
4. Em **Authentication › URL Configuration**, informe em *Site URL* o endereço do GitHub Pages (passo 2), por exemplo `https://SEU-USUARIO.github.io/destina/`, e inclua o mesmo endereço em *Redirect URLs*. É para lá que vão os links de confirmação e de nova senha.
5. Em **Project Settings › API**, copie a *Project URL* e a chave **anon public**.

### 2. GitHub
1. Crie um repositório (ex.: `destina`) e envie todos os arquivos desta pasta.
2. Edite `config.js` com a URL e a chave **anon** do passo 1.5.
3. Em **Settings › Pages**, publique a partir da branch `main`, pasta `/ (root)`.

> A chave **anon** é pública por definição: a segurança está nas regras do banco. **Nunca** coloque a chave `service_role` no `config.js` nem no repositório.

### 3. Primeiro acesso
1. Abra o endereço do GitHub Pages, clique em **Entrar no ambiente oficial › Criar conta**.
2. Na tela "Cadastro recebido", clique em **Assumir como administrador**. Essa opção só existe enquanto o sistema não tem administrador.
3. Em **Configurações**: preencha a instituição, os nomes e cargos da Reitora e do Pró-Reitor, a alçada e os prazos.
4. Peça aos servidores que criem suas contas; em **Configurações › Usuários e perfis**, marque *Aprovado* e o perfil de cada um.
5. Em **Reserva técnica › Importar planilha**, envie a planilha de controle atual (.xlsx). A importação inicial só é aceita com a reserva vazia.

## Perfis

| Perfil | Pode |
|---|---|
| Gestão do sistema | configurar, aprovar usuários, importar, cancelar planos em qualquer etapa |
| Autorizador (nível 1 e nível 2) | decidir a destinação (assinatura que inicia o plano) e assinar ou indeferir termos da sua alçada; o nível 2 assina acima do limite de alçada |
| Formalização documental | instruir (processo SIPAC, fundamentação, despacho), devolver para ajustes |
| Divisão de Patrimônio | registrar entradas, criar planos, registrar entregas e tombamentos |
| Almoxarifado Central | registrar entradas, criar planos, separar e conferir |
| Consulta e auditoria | ver tudo, sem alterar |

## Garantias do servidor

- Ninguém grava direto nas tabelas: cada ação é uma função que confere **o perfil do usuário** e **a etapa do plano**.
- **Saldo:** reservas são serializadas no banco; dois planos não conseguem reservar o mesmo saldo.
- **Numeração** (PD 0001/2026) por sequência no banco, sem duplicidade.
- **Tombamento:** número único em todo o sistema.
- **Trilha de auditoria:** data/hora do servidor e encadeamento por hash SHA-256; eventos e assinaturas não podem ser editados nem apagados.
- **Assinatura:** vinculada ao hash do conteúdo do termo; qualquer alteração posterior é detectada em *Documentos › Verificar autenticidade*.
- Funções internas não ficam expostas pela API.

## Assistente

Responde, com cálculo exato sobre os dados, perguntas como "quantos ar-condicionados temos?", "quais termos aguardam a minha assinatura?", "o que foi entregue para o CCS este ano?", "monte um plano com 20 cadeiras para a Biblioteca Central" e oferece botões de ação. Perguntas, sugestões e cliques ficam no registro do assistente (Monitoramento). Funciona sem IA externa.

## Atualizar a hierarquia organizacional

Em **Configurações › Estrutura organizacional › Atualizar estrutura**, envie a exportação do SIPAC (.xlsx, .csv ou .json com código, nome e, opcionalmente, unidade superior).

## Limitações conhecidas e próximos passos

- A assinatura é eletrônica interna (autoria + hash). Para valor jurídico pleno, anexe o termo ao processo no SIPAC ou integre assinatura gov.br.
- Ainda não há: entrega parcial, devolução/ajuste de estoque, pedidos das unidades, avisos por e-mail e modo offline.
- LGPD: o sistema guarda nome e SIAPE de recebedores e o registro do assistente; publique um aviso de privacidade e defina prazo de retenção.

## Testes do assistente

Toda mudança no `index.html` roda automaticamente no GitHub (aba **Actions → Testes do assistente**):

- `tests/chat-casos.json`: conversas reais, incluindo cada bug já reportado, com o que deve e o que não pode aparecer na resposta.
- `tests/variacoes.py`: centenas de variações geradas (jeitos de pedir destinação, de perguntar saldo, cumprimentos). Regra: pedido de destinação começa pela disponibilidade; pergunta de saldo responde saldo; cumprimento não traz pendências.

- `tests/rodar_massa.py N`: gera N perguntas com erros de digitação, sem acento, abreviações ("vc", "qts", "p/"), nomes populares e frases de enfeite, em 14 tipos de pedido, e confere cada resposta. O GitHub roda 20 mil a cada mudança e exige 98,5% de acerto.

Para rodar no computador: `pip install playwright && python -m playwright install chromium`, depois `python tests/rodar_chat.py` e `python tests/variacoes.py`.

**Bug novo no chat:** clique em "Resposta errada?" embaixo da resposta e descreva o que deveria acontecer. O gestor baixa os reportes em Monitoramento → Registro do assistente ("Baixar reportes como casos de teste"). Cada reporte vira um caso em `tests/chat-casos.json`, e a correção só é aceita quando todos os casos passam.
