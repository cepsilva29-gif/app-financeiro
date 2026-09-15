# Plano exploratório: app_financeiro (controle de gastos/receitas, multi-tenant desde o início)

> **Status: planejamento inicial.** Diferente do `app_agendamento` — que nasceu single-tenant e
> só depois foi migrado (ver `plano-multi-tenant.md` daquele projeto) — o `app_financeiro` já
> nasce como produto multi-tenant. A lição aprendida lá (workflows n8n duplicados por empresa
> viram dívida técnica pesada: um bug sistêmico virou 4 edições manuais numa instalação single-
> tenant, e escalaria pra 40+ com 10 empresas na Opção A) é aplicada aqui desde o design inicial,
> não como retrofit.

## Escopo do produto

- **Público**: multi-tenant — várias empresas usando a mesma instalação, cada uma vendo só os
  próprios dados.
- **Núcleo funcional (v1)**: controle de gastos e receitas com categorização — lançamentos
  (entrada/saída), categorias, e visão consolidada por período.
- **Stack**: Supabase (dados + RLS) + n8n (workflows/API) — mesma stack do `app_agendamento`,
  reaproveitando padrões já validados naquele projeto (resolução de tenant no início de cada
  workflow, RLS como camada extra e não como isolamento primário enquanto o n8n usar
  `service_role`).

## Peça 1 — Modelo de dados (Supabase)

Tabela `empresas` (mesmo papel da do `app_agendamento`, adaptada ao domínio financeiro):

```sql
create table empresas (
  id           bigint generated always as identity primary key,
  slug         text not null unique,        -- usado na URL/subdominio, ex: 'empresa-da-ana'
  nome         text not null,
  timezone     text not null default 'America/Sao_Paulo',
  moeda        text not null default 'BRL',
  ativo        boolean not null default true,
  criado_em    timestamptz not null default now()
);
```

Tabelas do domínio, todas com `empresa_id bigint not null references empresas(id)` desde a
criação (sem retrofit de FK, como aconteceu no `app_agendamento`):

```sql
create table categorias (
  id          bigint generated always as identity primary key,
  empresa_id  bigint not null references empresas(id),
  nome        text not null,
  tipo        text not null check (tipo in ('receita','despesa')),
  cor         text,
  unique (empresa_id, nome, tipo)         -- unique já nasce escopado por empresa
);

create table contas (
  id          bigint generated always as identity primary key,
  empresa_id  bigint not null references empresas(id),
  nome        text not null,              -- ex: "Caixa", "Banco X", "Cartão Y"
  tipo        text not null check (tipo in ('caixa','banco','cartao')),
  saldo_inicial numeric(14,2) not null default 0,
  ativo       boolean not null default true
);

create table transacoes (
  id          bigint generated always as identity primary key,
  empresa_id  bigint not null references empresas(id),
  conta_id    bigint not null references contas(id),
  categoria_id bigint references categorias(id),
  tipo        text not null check (tipo in ('receita','despesa')),
  valor       numeric(14,2) not null,
  descricao   text,
  data        date not null,
  status      text not null default 'confirmado' check (status in ('previsto','confirmado')),
  criado_em   timestamptz not null default now()
);

create index idx_transacoes_empresa_conta_data on transacoes (empresa_id, conta_id, data);
create index idx_transacoes_empresa_categoria_data on transacoes (empresa_id, categoria_id, data);
```

RLS: habilitar nas 4 tabelas desde o início, mesmo sabendo que o n8n vai usar `service_role` (que
ignora RLS) — o isolamento real vem de **todo workflow resolver `empresa_id` no primeiro passo e
filtrar por ele em toda query**, exatamente como no `app_agendamento`. Registrar isso como risco
conhecido, não como algo resolvido pelo RLS sozinho.

## Peça 2 — Identificação de tenant

Mesma recomendação do `app_agendamento`: **subdomínio para o frontend**
(`app.<slug>.dominio`), **prefixo de path para os webhooks do n8n**
(`/webhook/<slug>/criar-transacao`). Motivo igual: subdomínio é mais amigável pro cliente final,
path-prefix é mais simples de configurar e não é visível pra ninguém fora do sistema.

## Peça 3 — n8n: workflows compartilhados desde o início

Diferente do `app_agendamento` (que teve Opção A vs B como decisão a se tomar), aqui a decisão já
está tomada antes de existir código: **um workflow set só, parametrizado por `empresa_id`**, com
o mesmo padrão:

1. Todo webhook recebe o slug (path) ou resolve por outro identificador do evento.
2. Primeiro node de cada workflow é "Resolver Empresa" — `select * from empresas where slug = ...`.
3. Todo node Supabase seguinte usa `empresa_id eq {{ $('Resolver Empresa').first().json.id }}`.
4. Nenhum `$env.*` específico de empresa — o que no `app_agendamento` era `SALON_NAME`,
   `EVOLUTION_INSTANCE` etc. vira coluna em `empresas` (aqui, inicialmente só `nome`, `timezone`,
   `moeda`).

Workflows previstos na v1 (estimativa, ajustar durante o desenvolvimento):

- `criar-transacao` (POST) — cria lançamento, valida conta/categoria da mesma empresa.
- `listar-transacoes` (GET) — filtros por período, conta, categoria, tipo.
- `resumo-periodo` (GET) — saldo por conta + total receita/despesa/categoria no período.
- `criar-categoria`, `criar-conta` (CRUD básico).
- `editar-transacao`, `excluir-transacao`.

## Peça 4 — Onboarding de empresa nova

1. Inserir a linha em `empresas` (slug, nome, moeda, timezone).
2. Cadastrar categorias e contas iniciais dela.
3. Apontar `app.<slug>` no Caddy/Easypanel pro mesmo par de containers de frontend.

Nenhum passo manual no n8n, pelo mesmo motivo do `app_agendamento`: workflows já nascem
compartilhados.

## Peça 5 — Autenticação

Diferente do `app_agendamento` (onde o painel admin começou sem autenticação nenhuma e isso ficou
registrado como pendência crítica), aqui a recomendação é **não repetir esse ponto**: definir
autenticação antes de abrir o produto pra mais de uma empresa de teste — login por empresa
(Supabase Auth ou token por subdomínio, a decidir na Peça 3 do `plan-app-financeiro.md`).

## Peça 6 — O que fica em aberto

- **Import de extratos** (OFX/CSV de banco) — fora do escopo da v1, mas é um pedido comum nesse
  tipo de produto; vale já deixar `transacoes` com um campo de origem (`manual` vs `importado`)
  pensando nisso.
- **Recorrência** (lançamentos fixos mensais) — não modelado ainda; decidir se é campo em
  `transacoes` (`recorrencia_id`) ou tabela separada.
- **Billing/limites do próprio produto** — igual ao `app_agendamento`, fora de escopo deste doc,
  relevante se isso virar produto vendável.
- **Migração de dados** — não se aplica aqui como aplicava no `app_agendamento` (não existe
  instalação single-tenant anterior a migrar); a "empresa 1" já nasce como uma linha normal em
  `empresas`.

## Esforço aproximado (ordem de grandeza)

| Peça | Esforço |
|---|---|
| Schema Supabase (empresas + domínio + índices) | Pequeno |
| Workflows n8n (CRUD + resumo, já multi-tenant) | Médio |
| Frontend dinâmico por subdomínio | Médio |
| Auth no painel | Médio |
| Onboarding automatizado de empresa nova | Pequeno, depois que o resto existe |

**Recomendação geral**: por nascer multi-tenant desde o schema e os workflows, o `app_financeiro`
evita o custo que o `app_agendamento` teve que pagar depois (reescrever ~14 nós Supabase e ~6
nós HTTP pra sair de single- pra multi-tenant). O próximo passo é o `plan-app-financeiro.md`, com
as fases de desenvolvimento em ordem de execução.
