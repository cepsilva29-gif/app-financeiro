# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A multi-tenant financial control app (gastos/receitas — expense and revenue tracking) for small
Brazilian businesses: several empresas (companies) share one installation, each seeing only its
own data. All business logic lives in n8n workflows; the data store is Supabase (Postgres + RLS).
This is a standalone product — it does not share code, schema, or business logic with any other
project in this workspace, even though it happens to run on the same n8n instance as some of them
(see "Shared n8n instance" below).

Design and planning docs (read in this order):
- `init-app-financeiro.md` — product scope, full data model DDL, tenant-identification strategy,
  n8n workflow strategy, onboarding flow, auth approach, and known open items (why).
- `plan-app-financeiro.md` — the same work broken into 6 ordered phases, each with a concrete
  "Critério de pronto" and a phase dependency table (what order).

When implementing, follow the phase order in the plan doc — later phases assume earlier ones'
"Critério de pronto" is actually met, not just started. Note: the init/plan docs describe
path-prefix webhooks (`/webhook/<slug>/...`) for tenant identification; this was superseded during
Fase 2 (see below) — trust this file and the deployed workflows over that detail in the docs.

Both docs, and all UI copy, are in Portuguese (pt-BR) — the target user is a Brazilian business
owner. Keep new docs and UI copy in Portuguese too.

## Status

- **Fase 1 — done.** Schema live in Supabase project `vussdcsiqtsvzdicfrez` (`supabase/schema.sql`):
  `empresas`, `categorias`, `contas`, `transacoes`, RLS enabled on all four, seed empresa `demo`
  (2 contas, 3 categorias, 2 transações — safe to query/extend, not safe to assume empty).
- **Fase 2 — done.** All 6 core workflows from the plan, plus 4 read-only ones added during Fase 3
  because the frontend needed them (`empresa-info`, `listar-categorias`, `listar-contas` — see
  below), built, active on the shared n8n instance, and verified end-to-end via webhook calls
  (happy path + tenant-isolation/validation failure paths) — see `n8n-workflows/*.json` and
  "Deployed workflows" below.
- **Fase 3 — done.** `frontend/index.html`: single static page, tabs for Lançamentos (create/list/
  delete + filters), Resumo (period totals + saldo por conta), Categorias & Contas (create +
  list). Verified in a real browser against the live workflows (not just read — see "Frontend"
  below for what was actually exercised).
- **Fase 4 — done.** Token-per-empresa auth (`empresas.access_token`), chosen over Supabase Auth
  because nothing in this project implies multiple individually-logged-in users per empresa — see
  "Auth" below for the tradeoff and how it's wired.
- **Fase 5 — done.** `POST /webhook/financeiro/onboarding` (admin-only, see below) creates an
  empresa + default categorias + an initial conta in one call. Verified live: created a real
  second empresa (`demo2`) this way with zero manual database edits — the plan's own Fase 5
  acceptance test — and confirmed rejection of a duplicate slug and of invalid input.
- **Fase 6 (extensões pós-v1) — deliberately out of scope**, see below.
- **Frontend deployed to production** (2026-09-15) — see "Deployment" below.

## Architecture

- **Stack**: Supabase (Postgres + RLS) for data, n8n for all business logic/API — no separate
  backend service, no build step. Frontend is (planned to be) static HTML/JS.
- **Tenant isolation**: every table carries `empresa_id` from its very first migration (no
  retrofit). Every n8n workflow resolves `empresa_id` in its first nodes and filters every
  subsequent query by it explicitly — verified by testing that a `conta_id`/`categoria_id`
  belonging to a different empresa is rejected (422), not silently accepted. RLS is enabled on
  every table as a second layer, but is **not** the primary isolation mechanism while n8n uses the
  Supabase `service_role` key (which bypasses RLS) — the app-level filter in each workflow is what
  actually prevents cross-tenant access; RLS is defense in depth.
- **Tenant identification — superseded twice since the init doc, current state below.** The init
  doc's plan (path-prefix webhooks) never shipped — n8n's dynamic `:param` webhook path segment
  only matches its own internal `webhookId` (built for resuming a paused execution, not general
  request routing), confirmed by testing. Fase 2 instead used `slug` as a query param (GET) or
  body field (POST). **Fase 4 replaced that too**: every workflow now resolves the empresa from an
  **`X-Empresa-Token` request header** (checked against `empresas.access_token`), and `slug` is no
  longer read by any workflow at all — sending a `slug` is harmless (ignored), and cannot be used
  to reach another empresa's data no matter what value it holds. Confirmed by testing: a request
  carrying empresa A's token and empresa B's slug still resolves (and only ever touches) empresa
  A. `slug` still exists as a column and is still returned by `empresa-info` for **display**
  purposes (and was the basis of the still-live `app.<slug>.dominio` subdomain idea from the init
  doc), but carries no security meaning — never reintroduce slug-based resolution into a workflow.
- **Workflow set is shared, not per-empresa**: one parameterized n8n workflow per operation serves
  every empresa; nothing empresa-specific lives in `$env.*` — anything that varies by empresa
  (name, timezone, moeda) is a column on the `empresas` row, resolved at request time.

### Data model (`supabase/schema.sql`)

Four tables: `empresas` (tenant registry: slug, **access_token** — the sole auth credential, see
Fase 4 — nome, timezone, moeda), `categorias`
(receita/despesa, scoped-unique per empresa via `unique(empresa_id, nome, tipo)`), `contas`
(caixa/banco/cartão, with saldo_inicial), `transacoes` (the ledger: tipo, valor, data, status
previsto/confirmado, origem manual/importado, FKs to conta+categoria). Two composite indexes on
`transacoes`: `(empresa_id, conta_id, data)` and `(empresa_id, categoria_id, data)`.

### Deployed workflows (`n8n-workflows/`)

Every workflow starts the same shared auth prefix (`Token Presente? (IF) → Resolver Empresa
(Supabase getAll empresas by access_token+ativo) → Checar Empresa (Code, collapses to {encontrada,
empresa_id}) → Empresa Encontrada? (IF)`), 401s on either false branch (`Token de acesso ausente.`
vs `Token de acesso invalido.`) — built once as `buildAuthPrefix()` in the build scripts so all 10
workflows share the exact same check. Files are the exact JSON exported after live testing
(nodes/connections/settings only — n8n-managed fields like `versionId`/`shared` stripped).

- **`01-criar-categoria`** (`POST /webhook/financeiro/criar-categoria`) — validates
  `nome`+`tipo`, rejects a duplicate (empresa_id, nome, tipo) with 409 before insert.
- **`02-criar-conta`** (`POST /webhook/financeiro/criar-conta`) — validates `nome`+`tipo`
  (caixa/banco/cartao)+`saldo_inicial`.
- **`03-criar-transacao`** (`POST /webhook/financeiro/criar-transacao`) — validates
  `conta_id` belongs to the resolved empresa (422 if not), and `categoria_id` too when provided
  (it's optional on `transacoes`).
- **`04-listar-transacoes`** (`GET /webhook/financeiro/listar-transacoes`) — fetches all of the
  empresa's `transacoes` then filters in-workflow by optional `conta_id`/`categoria_id`/`tipo`/
  `periodo_inicio`/`periodo_fim` query params (simple linear scan — fine at this data volume, not
  meant to scale past it without moving the filtering into the Supabase query itself).
- **`05-editar-transacao`** (`POST /webhook/financeiro/editar-transacao`) — partial update by
  `id` (merges provided fields onto the existing row); re-validates `conta_id`/`categoria_id`
  ownership **only when those fields are part of the request** (`contaAlterada`/
  `categoriaAlterada` flags in `Validar Dados Edicao`), not on every edit.
- **`06-excluir-transacao`** (`POST /webhook/financeiro/excluir-transacao`) — hard delete by
  `id`, scoped to the resolved empresa; 404 if the id doesn't exist or belongs to another empresa
  (same-status response whether it's absent or foreign — don't use this to probe existence).
- **`07-resumo-periodo`** (`GET /webhook/financeiro/resumo-periodo`) — saldo per conta
  (`saldo_inicial` + confirmed receitas − despesas up to `periodo_fim`, or all-time if omitted)
  and totals by categoria/tipo **within** `periodo_inicio`..`periodo_fim` (both optional; omitted
  = all-time). **Gotcha fixed during build**: `Buscar Contas` and `Buscar Transacoes` must run as
  **parallel branches** off `Empresa Encontrada?`, not chained — n8n nodes re-execute once per
  input item, so chaining `Buscar Transacoes` after a multi-row `Buscar Contas` output ran the
  transaction query once per conta and silently duplicated every total. `Calcular Resumo` (Code)
  pulls both node's data by name via `$('Buscar Contas (Supabase)').all()`, which works across
  parallel branches without a direct edge — only the actual graph shape (chained vs. parallel)
  needed fixing.

Only `previsto` vs `confirmado` status exists; `resumo-periodo` and account balances count
`confirmado` only.

- **`08-listar-categorias`** / **`09-listar-contas`** (`GET .../listar-categorias`,
  `GET .../listar-contas`) — added during Fase 3; not in the original plan, but the transaction
  form has no way to populate its conta/categoria selects without them. Same
  `Webhook → Resolver Empresa → Checar Empresa → Empresa Encontrada?` shell as every other
  workflow, `matchType: allFilters` on `empresa_id` only, no filters beyond that.
- **`10-empresa-info`** (`GET /webhook/financeiro/empresa-info`) — also added during Fase 3, for
  the page header (empresa nome) and currency formatting (`moeda`). Returns
  `{slug, nome, timezone, moeda}` for the resolved empresa.
- **`11-onboarding`** (`POST /webhook/financeiro/onboarding`, Fase 5) — the one workflow that does
  **not** use `buildAuthPrefix()`/`X-Empresa-Token`, because it creates an empresa rather than
  acting on one that already exists. Protected instead by n8n's built-in webhook `authentication:
  "headerAuth"` (checked by n8n itself before the workflow runs, no custom node needed) against a
  separate `httpHeaderAuth` credential (`X-Admin-Token`, credential id `0Ge9oeKKwekA6ZI3`, name
  "Admin - app_financeiro onboarding"; the secret value lives in `.env` as
  `onboarding_admin_token:`, never in this repo's workflow JSON — same "credential, not env var,
  not hardcoded" pattern as the Supabase key). **Never confuse this admin token with an empresa's
  `access_token`** — the admin token can create empresas; an empresa token can only touch its own
  data. Body: `{slug, nome, moeda?, timezone?, categorias?: [{nome,tipo}], conta_inicial?: {nome,
  tipo, saldo_inicial}}` — `categorias`/`conta_inicial` default to the same starter set `demo` has
  in `schema.sql` if omitted. Generates the new empresa's `access_token` itself (`'fin_' +
  randomBytes(16).toString('hex')`, with a `Math.random()` fallback in case `require('crypto')`
  ever gets sandboxed in this Code node — confirmed `require('crypto')` works today, but the
  fallback costs nothing to keep). Rejects a taken `slug` with 409, invalid input with 400.
  **Graph shape gotcha** (same class as `07-resumo-periodo`'s): categoria creation is a genuine
  multi-item fan-out (`Preparar Categorias` turns 1 item into N, `Criar Categorias` inserts once
  per item) and is deliberately left as a **dead-end branch** off `Criar Empresa` — nothing reads
  its output. The response-building branch (`Criar Conta Inicial` → `Montar Resposta`) runs in
  parallel from the same single-item `Criar Empresa` node and never references the categorias
  branch, specifically to avoid depending on ordering between two parallel branches (unlike
  `resumo-periodo`, which does read a sibling branch's output and relies on it having already run
  — that pattern is only safe because it was verified working, not because n8n guarantees it).

### Frontend (`frontend/index.html`)

Single static file, vanilla JS, Tailwind via CDN, no build step. Gated behind a token screen
(`#appGate`, hidden/shown via the `hidden` Tailwind class, never real navigation) — see "Auth"
below for how the token itself works; nothing else in the page loads until `iniciarApp()` runs.
All API calls go through one `api(path, {method, query, body})` helper in the `CONFIG.API_BASE` =
`https://n8n.engenhariadedadosn8n.shop/webhook/financeiro` namespace, which attaches the stored
token as the `X-Empresa-Token` header on every call automatically — no call site needs to remember
auth, and none of them send `slug` anywhere (there's nothing left in this project that reads it).

Client-side joins: `state.categorias`/`state.contas` are loaded once on boot and looked up by id
(`nomeCategoria()`/`nomeConta()`) to render names in the lançamentos table and resumo — the backend
returns bare `categoria_id`/`conta_id` on every transação, by design (`listar-transacoes` doesn't
join). If `criar-categoria`/`criar-conta` are called from elsewhere, the frontend's cached lists go
stale until next reload — there's no realtime sync.

Deletion uses a native `confirm()` before calling `excluir-transacao` — fine for a real user, but
means this page **cannot be driven through Claude in Chrome (or similar) past that point**: clicking
excluir blocks the tab on a modal dialog. Test deletes against the API directly (`curl`) instead of
through the UI.

Verified live (2026-09-15, server via `python -m http.server` — `file://` doesn't work here since
Chrome's `null` origin still needs the webhook's fetch calls to succeed, which local static-file
serving avoids relying on entirely): empresa header/moeda loaded correctly, created a real
transação through the form (select-filtering by tipo→categoria confirmed working), it appeared in
the table with joined conta/categoria names, Resumo tab's totals and saldo-por-conta matched the
transactions present, Categorias & Contas tab listed seeded data correctly. Also verified after
Fase 4 landed: wrong token shows an inline error and does not store anything, correct token
unlocks and persists across a reload, `?token=...` in the URL logs in and then strips itself from
the address bar, "trocar código de acesso" clears `localStorage` and returns to the gate (its
`.click()` didn't register through a couple of raw-coordinate clicks from the browser-automation
tool during testing — confirmed via direct DOM inspection that this was a click-targeting issue in
that tool, not a bug in the handler, which fired correctly once triggered). Test data was cleaned
up via direct API/SQL calls afterward, not through the UI (see confirm() note above re: deletes).

### Auth (Fase 4 — done)

**Token per empresa**, not Supabase Auth — chosen because nothing in this project implies
multiple, individually-logged-in employees per empresa; it's "the company's owner (or the 1-2
people who use this) has the company's access credential," closer to an API key than a user
account. Revisit toward Supabase Auth only if per-user login/audit trail becomes an actual
requirement — that's a bigger rework (login/signup UI, password reset, a user↔empresa link table,
JWT verification in every workflow instead of one header check), not a tweak of this scheme.

How it works end to end:
- `empresas.access_token` (`text not null unique`) is the **only** thing any workflow uses to
  resolve the empresa — see the "superseded" note under Tenant identification above. Generated as
  `'fin_' + 16 random bytes in hex`; `11-onboarding` (Fase 5) generates a fresh one for every new
  empresa automatically — there's still no rotation workflow for an *existing* empresa's token
  (see "known gaps" below).
- The frontend sends it as the `X-Empresa-Token` header on every request (see "Frontend" above).
  It's captured once via the `#appGate` screen (typed in, or via `?token=...` in a URL you hand
  the client), stored in `localStorage` (key `financeiro_access_token`), and reused until
  "trocar código de acesso" clears it.
- Every workflow's shared auth prefix responds **401** (not 404) for both "no header sent" and
  "header doesn't match any empresa" — deliberately not distinguishing the two in the response
  message content beyond "ausente" vs "invalido", so a caller can't use the error to enumerate
  valid tokens.
- **Verified as the actual acceptance test from the plan** ("empresa A não consegue, nem trocando
  o slug, ver dados da empresa B"): created a second empresa with its own token, called
  `criar-transacao` using empresa A's token while also sending `"slug": "empresab"` in the body —
  the transaction was created under empresa A (`empresa_id` from the token), not B. `slug` in a
  request body/query is now inert.
- **Still not done / known gaps**: no rotation or revocation workflow (only a direct SQL
  `update empresas set access_token = ...`); no rate limiting on the token check itself (a brute
  force against `access_token` isn't mitigated beyond the token's own entropy); the token is a
  bearer credential with no expiry — treat leaking one as equivalent to leaking that empresa's
  data, same as an API key.

### Explicitly out of scope for v1 (Fase 6)

Bank statement import (OFX/CSV) — `transacoes.origem` (`manual`/`importado`) already exists for
this. Also out of scope: recurring transactions, billing/plan limits.

## Shared n8n instance

The n8n instance (`n8n.engenhariadedadosn8n.shop`) hosts workflows for several unrelated
projects/experiments, not just this one — expect `GET /api/v1/workflows` to return 50+ entries
with no relation to app_financeiro. Everything belonging to this project is namespaced to avoid
collisions:
- **Webhook paths** all start with `financeiro/` (e.g. `financeiro/criar-transacao`).
- **Workflow names** in the n8n UI are prefixed `financeiro - ...`.
- **Supabase credential** is a dedicated one named `Supabase - app_financeiro` (n8n credential id
  `aYsNFdB5mXwMqYVO`), pointed at this project's own Supabase project
  (`vussdcsiqtsvzdicfrez.supabase.co`) via its `service_role` key. **Do not** reuse the credentials
  named `Supabase account` / `Supabase account 2` on this n8n instance — those belong to other
  projects' Supabase databases (confirmed by testing: reusing the wrong one is a real cross-project
  data leak, not just a naming mixup).
- **Admin credential** `Admin - app_financeiro onboarding` (`httpHeaderAuth`, id
  `0Ge9oeKKwekA6ZI3`) guards only `11-onboarding` — see that workflow's entry above.
- No `$env.*` variables are used by these workflows (unlike some other workflows on this instance)
  — every value they need comes from the webhook payload or the credential above, so nothing
  requires editing the shared n8n container's environment.

## Deployment

This directory is its **own git repo** (`git init` run directly inside `App_Financeiro/`, not part
of the outer `workpace` repo — same pattern `App_Agendamento` already uses, see its own nested
`.git`), pushed to `github.com/cepsilva29-gif/app-financeiro`.

- **Repo is public, deliberately.** This Easypanel instance's GitHub integration can only pull
  **public** repos (no GitHub App installed — confirmed by testing: `services.app.updateSourceGithub`
  against a private repo fails with `"Cannot find public repository and your Github token is
  invalid"`). Matches the existing `app-agendamento-salao` setup. There is no real secret in this
  repo's tracked files (`.env` is git-ignored, n8n workflow JSON references credentials by
  id/name only, never by value) — going public was a deliberate, user-confirmed tradeoff, not an
  oversight.
- **Easypanel** (same instance as the n8n container, `179.197.233.123:3000`, project
  `app_financeiro`, service `frontend`): builds from this repo's `frontend/` path (`Dockerfile` →
  `nginx:alpine` serving the static SPA), source type `github`, `ref: master`. Configured via the
  Easypanel tRPC API (`POST /api/trpc/<router>.<procedure>`, bearer token from
  `POST /api/trpc/auth.login` with the Easypanel `USUARIO`/`SENHA` in `.env`) — same
  login-then-bearer-token pattern as documented for `App_Agendamento`'s Easypanel work; no browser
  login was used. `services.app.createService` (not documented anywhere findable in the panel's
  own JS bundle, unlike every other procedure used in this project — found by guessing the obvious
  name and it worked first try) creates a service; `services.app.updateSourceGithub` points it at
  a repo; `services.app.deployService` triggers a build. `autoDeploy: true` was set on the source,
  but per `App_Agendamento`'s own notes that flag doesn't reliably persist/apply — don't assume a
  `git push` alone redeploys; call `deployService` (or re-check `inspectService`'s `commit.sha`
  against the repo's latest) after pushing.
- **Live URL**: `https://app_financeiro-frontend.y7ycus.easypanel.host/` — Easypanel's own
  managed subdomain (created via `domains.createDomain` with `certificateResolver: ""`, no
  external DNS needed; this is why bringing the service up didn't require touching Cloudflare).
  Verified live in a real browser: gate screen renders, matches local testing exactly.
- **Custom domain live**: `https://financeiro.engenhariadedadosn8n.shop/` — Cloudflare A record
  (`→ 179.197.233.123`) plus a matching `domains.createDomain` entry in Easypanel for the
  `frontend` service. Both of those DNS/domain steps are **behind an explicit-confirmation gate in
  this environment** and were done by the user directly (in the Cloudflare and Easypanel dashboards
  — not by an API call from this session), after being given exact click-by-click instructions.
  One detail that diverges from every other subdomain on this zone: this record's Cloudflare proxy
  is **on** (orange cloud) — every other `*.engenhariadedadosn8n.shop` record is "DNS only". It
  still resolves and serves correctly (verified via `curl --resolve` against Cloudflare's edge IP
  and confirmed in a real browser), so this isn't broken, just inconsistent with the zone's usual
  pattern — worth knowing if a future cert/routing issue only affects this one domain and not the
  others, since proxied traffic terminates TLS at Cloudflare's edge rather than passing straight
  through to Traefik. `domains.listDomains` for this service now lists both this and the
  `y7ycus.easypanel.host` domain.
- Making the GitHub repo public was **also** behind an explicit-confirmation gate (a private→public
  visibility flip reads as a potential data-exposure action) — it happened only after the user was
  asked directly and said yes. Don't flip a repo's visibility without that same explicit ask.

## Working with this repo

- **This directory is its own git repo** (see "Deployment" above) — it is *also* physically nested
  inside the parent `workpace` directory, which is a *separate, unrelated* git repo shared with
  sibling projects. Two independent `.git` histories, one inside the other; `App_Financeiro/`'s own
  history is what matters for this project, `workpace`'s only sees it (if at all) as an opaque
  directory. Don't confuse `git status`/`git log` output from one with the other — always confirm
  which repo a shell is actually in before trusting its output.
- **`.env` in this directory holds real, live infrastructure credentials** (Hostinger, Easypanel,
  Cloudflare, Supabase, n8n — including a Supabase Management API personal access token and this
  project's n8n API key) — not placeholders. It's excluded via `.gitignore`; never remove that
  entry or commit a real `.env`. Use `.env.example` as the template for what variables are
  expected, without real values.
- **Applying schema changes**: there's no local Postgres/CLI — `supabase/schema.sql` was applied to
  the live project via the Supabase Management API (`POST
  /v1/projects/vussdcsiqtsvzdicfrez/database/query`) using the `token:` (personal access token,
  `sbp_...`) in `.env`, not a direct psql connection (no DB password is stored there — the
  `postgresql://postgres:[YOUR-PASSWORD]@...` line is an unfilled placeholder). Future schema
  changes: write the migration SQL, run it the same way, and append it to `schema.sql` (or start a
  `supabase/migrations/` folder if changes get more frequent than that).
- **Editing/adding n8n workflows**: same Management-API-style approach — no browser login is used
  to manage this n8n instance; workflows are created/activated via its REST API
  (`X-N8N-API-KEY` header, the `api n8n:` token in `.env`) using `POST /api/v1/workflows` +
  `POST /api/v1/workflows/{id}/activate` (PATCHing an active workflow in place does **not**
  reliably reload it — create a new version and activate it instead). After confirming a workflow
  behaves correctly via a live webhook call, export the clean `{name, nodes, connections,
  settings}` shape into `n8n-workflows/` so the JSON in this repo stays the source of truth
  alongside what's actually deployed.
- No package manager, build step, tests, or lint config — expect this to stay that way: static
  frontend files, n8n workflow JSON as the backend source of truth. "Testing" a workflow change
  means creating/activating it via the API and exercising it end-to-end with `curl` against the
  real webhook (→ row appears in Supabase → response matches expectation) — that's how every
  workflow in `n8n-workflows/` was actually validated, including the cross-tenant-rejection cases.
