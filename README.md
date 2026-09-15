# app_financeiro

Controle de gastos e receitas multi-tenant: cada empresa vê só os próprios lançamentos,
categorias e contas, numa única instalação compartilhada.

Projeto independente — stack própria (Supabase + n8n), sem dependência de código ou schema de
qualquer outro projeto.

## Status

- **Fase 1 — concluída**: schema aplicado no projeto Supabase (`supabase/schema.sql`), RLS
  habilitado nas 4 tabelas, empresa `demo` (com categorias e conta iniciais) seedada.
- **Fase 2 — concluída**: 10 workflows n8n criados e ativados (6 do plano original + 4 endpoints
  de leitura necessários pro frontend), testados de ponta a ponta via chamada HTTP real (caminho
  feliz + isolamento entre empresas + validações) — ver `n8n-workflows/` e a seção "Deployed
  workflows" do `CLAUDE.md`.
- **Fase 3 — concluída**: frontend estático (`frontend/index.html`), testado no navegador contra
  os workflows reais (criar lançamento, listar, resumo, cadastrar categoria/conta).
- **Fase 4 — concluída**: autenticação por token de acesso por empresa (`empresas.access_token`).
  Todo workflow exige o header `X-Empresa-Token`; sem ele, ou com um token que não bate com
  nenhuma empresa, responde 401. Testado explicitamente que o token de uma empresa não vaza dados
  de outra mesmo forçando outro `slug` na requisição — ver "Auth" no `CLAUDE.md`.
- **Fase 5 — concluída**: onboarding de empresa nova via `POST /webhook/financeiro/onboarding`
  (protegido por um token de admin separado, não pelo `X-Empresa-Token`) — cria a empresa, o
  `access_token` dela, as categorias padrão e a conta inicial numa chamada só. Testado criando a
  `demo2` sem editar nada no banco na mão.

## Endpoints (n8n)

Toda requisição exige o header `X-Empresa-Token: <token da empresa>` — é ele, e só ele, que
resolve qual empresa está sendo acessada (não o `slug`, que é só cosmético). A exceção é o
onboarding, que usa um token de admin à parte (ver `CLAUDE.md`).

| Método | Path | Descrição |
|---|---|---|
| GET | `/webhook/financeiro/empresa-info` | dados da empresa (nome, moeda, timezone) |
| GET | `/webhook/financeiro/listar-categorias` | lista categorias da empresa |
| GET | `/webhook/financeiro/listar-contas` | lista contas da empresa |
| POST | `/webhook/financeiro/criar-categoria` | cria categoria |
| POST | `/webhook/financeiro/criar-conta` | cria conta |
| POST | `/webhook/financeiro/criar-transacao` | cria lançamento |
| GET | `/webhook/financeiro/listar-transacoes` | lista lançamentos (filtros: período, conta, categoria, tipo) |
| POST | `/webhook/financeiro/editar-transacao` | edita lançamento (parcial, por `id`) |
| POST | `/webhook/financeiro/excluir-transacao` | exclui lançamento (por `id`) |
| GET | `/webhook/financeiro/resumo-periodo` | saldo por conta + totais por categoria/tipo no período |
| POST | `/webhook/financeiro/onboarding` | **cria empresa nova** — requer `X-Admin-Token`, não `X-Empresa-Token` |

## Cadastrando uma empresa nova

```bash
curl -X POST https://n8n.engenhariadedadosn8n.shop/webhook/financeiro/onboarding \
  -H "X-Admin-Token: <onboarding_admin_token do .env>" \
  -H "Content-Type: application/json" \
  -d '{"slug": "empresa-nova", "nome": "Empresa Nova Ltda"}'
```

Retorna o `access_token` gerado pra essa empresa — é isso que você manda pro cliente (por exemplo,
como `.../frontend/?token=<access_token>`). `categorias` e `conta_inicial` são opcionais no body;
sem eles, usa o mesmo conjunto padrão da `demo` (Vendas/Serviços/receita, Fornecedores/despesa,
conta "Caixa").

## Documentação

- [`init-app-financeiro.md`](init-app-financeiro.md) — escopo do produto, modelo de dados
  completo, estratégia de multi-tenant, decisões de design.
- [`plan-app-financeiro.md`](plan-app-financeiro.md) — plano de execução em 6 fases, com critério
  de pronto e dependências entre elas.
- [`CLAUDE.md`](CLAUDE.md) — guia de arquitetura para desenvolvimento assistido por IA.

## Stack

- **Supabase** (Postgres + RLS) — armazenamento de dados.
- **n8n** — toda a lógica de negócio/API, exposta via webhooks.
- **Frontend** — HTML/JS estático, Tailwind via CDN, sem build step.

## Estrutura

```
supabase/schema.sql   — schema do banco (empresas, categorias, contas, transacoes)
n8n-workflows/         — exports JSON dos workflows n8n (fonte de verdade versionada)
frontend/index.html    — SPA estática (gate de token, lançamentos, resumo, categorias & contas)
```

## Rodando o frontend localmente

Sem build step — mas precisa ser servido por HTTP (não `file://`), porque o navegador restringe
`fetch` em origem `file:`. Qualquer servidor estático serve:

```bash
cd frontend
python -m http.server 8765
# abrir http://localhost:8765/index.html
```

Primeiro acesso pede o código de acesso (token) da empresa — o da `demo` está em
`supabase/schema.sql` (linha do `insert into empresas`). Pra pular a telinha, abra com
`?token=<token>` na URL (o token é lido, guardado no navegador, e removido da URL automaticamente).
Depois de entrar uma vez, o token fica salvo no `localStorage` — "trocar código de acesso" no
cabeçalho limpa e pede de novo.

## Configuração local

Copie `.env.example` para `.env` e preencha com as credenciais do projeto Supabase próprio deste
app. Nunca commitar `.env` — já está no `.gitignore`.
