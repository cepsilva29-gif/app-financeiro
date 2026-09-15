# Plano de desenvolvimento: app_financeiro

> Continuação de `init-app-financeiro.md` — aquele documento mapeia o problema e as decisões de
> design (multi-tenant desde o início, stack Supabase + n8n, workflows compartilhados). Este
> documento quebra a execução em fases, na ordem em que fazem sentido para implementar.

## Fase 1 — Schema Supabase

- Criar `empresas`, `categorias`, `contas`, `transacoes` conforme Peça 1 do init.
- Habilitar RLS nas 4 tabelas (sem policy ainda, mesmo modelo do `app_agendamento`: isolamento
  real fica a cargo dos workflows, RLS é camada extra).
- Seed de uma empresa de teste (slug `demo`) com 2-3 categorias e 1 conta, pra desenvolver os
  workflows da Fase 2 contra dados reais.
- **Critério de pronto**: consigo inserir uma transação via SQL direto no Supabase Studio
  filtrando por `empresa_id` e o índice `idx_transacoes_empresa_conta_data` é usado no `explain`.

## Fase 2 — Workflows n8n (core CRUD)

Nesta ordem (cada um depende do anterior existir pra testar):

1. `resolver-empresa` — não é um workflow exposto, é o sub-fluxo/node padrão que os outros vão
   reusar (via node "Execute Workflow" ou snippet copiado) para resolver `empresa_id` a partir do
   slug do path.
2. `criar-categoria`, `criar-conta` — CRUD simples, valida `unique (empresa_id, nome, tipo)`.
3. `criar-transacao` — valida que `conta_id` e `categoria_id` pertencem à mesma `empresa_id`
   resolvida (não só que existem).
4. `listar-transacoes` — filtros por período/conta/categoria/tipo, sempre com `empresa_id` fixo.
5. `editar-transacao`, `excluir-transacao`.
6. `resumo-periodo` — agrega saldo por conta e totais por categoria/tipo no período.

- **Critério de pronto**: os 6 workflows funcionam contra a empresa `demo` via chamada HTTP
  (Postman/curl), incluindo o caso de erro (tentar usar `conta_id` de outra empresa deve falhar).

## Fase 3 — Frontend dinâmico por subdomínio

- Extrair slug de `location.hostname` (mesmo padrão recomendado no init do `app_agendamento`,
  Peça 2 daquele doc).
- Tela de lançamentos (listar + criar transação) e tela de resumo (saldo por conta, totais por
  categoria).
- **Critério de pronto**: acessar `app.demo.dominio` (ou equivalente local) mostra só os dados da
  empresa `demo`, sem nenhum hardcode de nome/categoria no HTML/JS.

## Fase 4 — Autenticação do painel

- Decidir entre Supabase Auth (login usuário/senha por empresa) ou token de acesso por
  subdomínio — ao contrário do `app_agendamento`, essa decisão é tomada **antes** de abrir pra
  mais de uma empresa, não depois.
- Middleware/checagem no frontend e nos webhooks que exigem autenticação (lançamentos e resumo
  não devem ser acessíveis sem sessão válida da empresa correta).
- **Critério de pronto**: usuário da empresa A não consegue, nem trocando o slug na URL, ver
  dados da empresa B — testar isso explicitamente como caso de aceite.

## Fase 5 — Onboarding automatizado de empresa nova

- Script ou workflow n8n dedicado que faz os passos da Peça 4 do init (inserir empresa, seed de
  categorias padrão, criar conta inicial) de forma repetível.
- **Critério de pronto**: dar alta a uma segunda empresa de teste (`slug=demo2`) sem editar nada
  manualmente no banco além de rodar o onboarding.

## Fase 6 — Extensões pós-v1 (não bloqueiam lançamento)

- Import de extratos (OFX/CSV).
- Lançamentos recorrentes.
- Billing/limites por plano.

Essas ficam registradas como próximos passos, não como parte da v1 — mantê-las fora do escopo
inicial é o que permite fechar as Fases 1-5 num ciclo enxuto.

## Resumo de dependências entre fases

| Fase | Depende de | Pode paralelizar com |
|---|---|---|
| 1. Schema | — | — |
| 2. Workflows core | Fase 1 | — |
| 3. Frontend | Fase 2 (ao menos criar/listar) | Fase 4 (parcialmente) |
| 4. Auth | Fase 2 | Fase 3 |
| 5. Onboarding | Fases 1-4 completas | — |
| 6. Extensões | Fase 5 | — |
