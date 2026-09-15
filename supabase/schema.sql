-- app_financeiro — schema inicial (Fase 1)
-- Multi-tenant desde a criação: toda tabela de domínio carrega empresa_id sem retrofit.
-- RLS habilitado como camada extra; o isolamento real é responsabilidade de cada workflow n8n
-- resolver empresa_id primeiro e filtrar toda query por ele (service_role ignora RLS).

create table empresas (
  id           bigint generated always as identity primary key,
  slug         text not null unique,        -- usado na URL/subdominio, ex: 'empresa-da-ana' — display/routing only, NAO e a fronteira de seguranca (ver Fase 4)
  access_token text not null unique,        -- gerado no onboarding; e o unico campo que os workflows usam pra resolver a empresa numa request autenticada
  nome         text not null,
  email        text,                        -- pra onde o link de acesso e mandado no onboarding (Fase 5+); nullable pq empresas antigas (demo/demo2) nao tinham esse campo
  timezone     text not null default 'America/Sao_Paulo',
  moeda        text not null default 'BRL',
  ativo        boolean not null default true,
  criado_em    timestamptz not null default now(),
  matriz_id    bigint references empresas(id)  -- null = independente ou e a propria matriz; setado = e filial dessa matriz. So 2 niveis (uma filial nao pode ter filiais) — validado na aplicacao (workflow de onboarding), nao por constraint aqui.
);

create index idx_empresas_matriz_id on empresas (matriz_id);

create table categorias (
  id          bigint generated always as identity primary key,
  empresa_id  bigint not null references empresas(id),
  nome        text not null,
  tipo        text not null check (tipo in ('receita','despesa')),
  cor         text,
  unique (empresa_id, nome, tipo)
);

create table contas (
  id            bigint generated always as identity primary key,
  empresa_id    bigint not null references empresas(id),
  nome          text not null,              -- ex: "Caixa", "Banco X", "Cartão Y"
  tipo          text not null check (tipo in ('caixa','banco','cartao')),
  saldo_inicial numeric(14,2) not null default 0,
  ativo         boolean not null default true
);

create table transacoes (
  id           bigint generated always as identity primary key,
  empresa_id   bigint not null references empresas(id),
  conta_id     bigint not null references contas(id),
  categoria_id bigint references categorias(id),
  tipo         text not null check (tipo in ('receita','despesa')),
  valor        numeric(14,2) not null,
  descricao    text,
  data         date not null,
  status       text not null default 'confirmado' check (status in ('previsto','confirmado')),
  origem       text not null default 'manual' check (origem in ('manual','importado')),
  criado_em    timestamptz not null default now()
);

create index idx_transacoes_empresa_conta_data on transacoes (empresa_id, conta_id, data);
create index idx_transacoes_empresa_categoria_data on transacoes (empresa_id, categoria_id, data);

-- RLS habilitado desde o início nas 4 tabelas, sem policy ainda (ver nota no CLAUDE.md /
-- init-app-financeiro.md: n8n usa service_role, que ignora RLS — o isolamento real é aplicado
-- pelos workflows filtrando por empresa_id resolvido a cada request).
alter table empresas    enable row level security;
alter table categorias  enable row level security;
alter table contas      enable row level security;
alter table transacoes  enable row level security;

-- Seed: empresa de teste para desenvolver os workflows contra dados reais.
-- access_token abaixo e so pra essa empresa demo (sem dado real por tras) — nunca reusar um
-- token fixo desses pra uma empresa de verdade; gerar aleatorio no onboarding real (Fase 5).
insert into empresas (slug, access_token, nome, email, timezone, moeda)
values ('demo', 'fin_5f31c80a2b2e1fe83d45ff5b0d4690f5adcb46d02d0846f7', 'Empresa Demo', 'demo@example.com', 'America/Sao_Paulo', 'BRL');

insert into categorias (empresa_id, nome, tipo)
select id, 'Vendas', 'receita' from empresas where slug = 'demo'
union all
select id, 'Serviços', 'receita' from empresas where slug = 'demo'
union all
select id, 'Fornecedores', 'despesa' from empresas where slug = 'demo';

insert into contas (empresa_id, nome, tipo, saldo_inicial)
select id, 'Caixa', 'caixa', 0 from empresas where slug = 'demo';
