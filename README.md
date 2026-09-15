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
  `demo2` sem editar nada no banco na mão. **Envia email de boas-vindas automaticamente** (via
  Resend) pro `email` informado no cadastro, com o link de acesso já pronto — não depende de você
  copiar/colar o token pro cliente manualmente.
- **Frontend em produção**: https://financeiro.engenhariadedadosn8n.shop/ (domínio próprio, via
  Cloudflare com proxy ligado) — também acessível pelo domínio padrão do Easypanel,
  https://app_financeiro-frontend.y7ycus.easypanel.host/. Build automático a partir deste repo
  (`frontend/`, `Dockerfile` com nginx).
- **Cadastro público de empresa nova** direto no frontend (link "Ainda não tem cadastro?" na tela
  de login) — chama `POST /webhook/financeiro/cadastro-publico`, sem nenhuma autenticação (é assim
  de propósito, pra poder ser chamado pelo navegador de qualquer visitante). Cria a empresa com
  categorias/conta padrão e manda o link de acesso por email — não devolve o `access_token` na
  resposta (diferente do onboarding via admin). **Sem proteção contra abuso ainda** (sem captcha,
  sem limite de tentativas) — decisão consciente por enquanto, revisar se virar problema.
- **Matriz vendo filiais**: uma empresa pode ser cadastrada como filial de outra
  (`empresas.matriz_id`). O token da matriz continua sendo um token só, mas pode agir em nome de
  qualquer filial dela passando `empresa_id` na requisição — o backend verifica a permissão a
  cada chamada. No frontend, aparece um seletor no cabeçalho pra trocar entre a própria empresa e
  as filiais, sem precisar logar de novo. Só 2 níveis (uma filial não pode ter filiais). Testado:
  matriz criando/vendo dados de uma filial, filial vendo os próprios dados normalmente, e todo
  acesso cruzado não autorizado (empresa não relacionada, filial tentando acessar a matriz)
  rejeitado com 403.

## Endpoints (n8n)

Toda requisição exige o header `X-Empresa-Token: <token da empresa>` — é ele, e só ele, que
resolve qual empresa está sendo acessada (não o `slug`, que é só cosmético). A exceção é o
onboarding, que usa um token de admin à parte (ver `CLAUDE.md`).

Qualquer endpoint (exceto onboarding/cadastro-publico) aceita opcionalmente `empresa_id` (query
no GET, body no POST) pra agir em nome de outra empresa — só funciona se essa empresa for filial
da empresa do token; senão, 403. Ver "Matriz vendo filiais" acima.

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
| POST | `/webhook/financeiro/cadastro-publico` | **cria empresa nova, self-service** — sem autenticação nenhuma; usado pelo botão "Criar conta da empresa" do frontend |

## Cadastrando uma empresa nova

```bash
curl -X POST https://n8n.engenhariadedadosn8n.shop/webhook/financeiro/onboarding \
  -H "X-Admin-Token: <onboarding_admin_token do .env>" \
  -H "Content-Type: application/json" \
  -d '{"slug": "empresa-nova", "nome": "Empresa Nova Ltda", "email": "dono@empresanova.com.br"}'
```

`email` é obrigatório — é pra onde o link de acesso é mandado automaticamente (via Resend), assim
que a empresa é criada. `categorias` e `conta_inicial` continuam opcionais; sem eles, usa o mesmo
conjunto padrão da `demo` (Vendas/Serviços/receita, Fornecedores/despesa, conta "Caixa"). Pra
cadastrar como **filial** de uma empresa já existente, adicione `"matriz_slug": "slug-da-matriz"`
— rejeita se a matriz não existir, estiver inativa, ou ela mesma já for uma filial (só 2 níveis).

A resposta traz `email_enviado: true/false` — se `false`, vem `email_erro` com o motivo (ex:
domínio do Resend não verificado, endereço inválido). A empresa é criada **mesmo se o email
falhar** — o `access_token` sempre volta na resposta como plano B, pra você mandar manualmente.

**Alternativa self-service**: a própria empresa pode se cadastrar direto pelo frontend, sem você
precisar rodar nada — botão "Ainda não tem cadastro?" na tela de login. Usa
`POST /webhook/financeiro/cadastro-publico` (sem `X-Admin-Token`, sem nenhuma autenticação),
sempre com categorias/conta padrão (não dá pra customizar nesse fluxo), e a resposta **não**
inclui o `access_token` — só uma mensagem confirmando que o email foi (ou não) enviado.

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

## Deploy (produção)

- **Repositório**: `github.com/cepsilva29-gif/app-financeiro` — **público**, deliberadamente: a
  integração GitHub desta instância do Easypanel só alcança repositórios públicos (sem GitHub App
  instalado), mesma limitação que já vale para o `app-agendamento-salao`. Não tem segredo real no
  código (o `.env` nunca é commitado).
- **Easypanel**: projeto `app_financeiro`, serviço `frontend`, fonte GitHub apontando pra
  `/frontend` deste repo (build via `frontend/Dockerfile`, nginx servindo estático).
  `autoDeploy: true` está setado, mas isso não confirma que o Easypanel realmente reconstrói a
  cada push (ver nota de `autoDeploy` não confiável no `CLAUDE.md` do `App_Agendamento`) — depois
  de um `git push`, confirmar/disparar o rebuild.
- **Domínio**: `financeiro.engenhariadedadosn8n.shop` (registro A na Cloudflare, DNS only — mesmo
  padrão dos outros subdomínios) apontando pro mesmo serviço no Easypanel. Certificado HTTPS real
  (Let's Encrypt, emitido pelo Traefik). Também acessível pelo domínio padrão do Easypanel
  (`app_financeiro-frontend.y7ycus.easypanel.host`).
- **Email de onboarding**: domínio `engenhariadedadosn8n.shop` verificado no Resend (DKIM + SPF +
  MX, registros na Cloudflare) — necessário pra mandar email a partir de
  `financeiro@engenhariadedadosn8n.shop`. Ver seção "Cadastrando uma empresa nova" abaixo.

## Configuração local

Copie `.env.example` para `.env` e preencha com as credenciais do projeto Supabase próprio deste
app. Nunca commitar `.env` — já está no `.gitignore`.
