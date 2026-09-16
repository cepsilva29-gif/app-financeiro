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
- **Fase 5 — done, later extended.** `POST /webhook/financeiro/onboarding` (admin-only, see below)
  creates an empresa + default categorias + an initial conta in one call. Verified live: created a
  real second empresa (`demo2`) this way with zero manual database edits — the plan's own Fase 5
  acceptance test — and confirmed rejection of a duplicate slug and of invalid input. **Extended
  post-launch** (2026-09-15) to also send a welcome email with the ready-to-click access link via
  Resend — see "Onboarding email (Resend)" below; `empresas.email` is now a required onboarding
  field.
- **Fase 6 (extensões pós-v1) — deliberately out of scope**, see below.
- **Frontend deployed to production** (2026-09-15) — see "Deployment" below.
- **Public self-service signup added** (2026-09-15) — a "cadastrar empresa" flow in the frontend
  itself, calling a new, deliberately unauthenticated `12-cadastro-publico` workflow. See "Public
  self-service signup" below — in particular, this has **no abuse protection** (no captcha, no
  rate limit) by explicit, informed user decision; don't assume that's an oversight to "fix".
- **Matriz/filial (parent/branch) support added** (2026-09-15) — one empresa can be a filial of
  another (`empresas.matriz_id`). A matriz's own token can act on behalf of any of its filiais by
  passing `empresa_id` in the request; every workflow's shared auth prefix verifies that
  permission server-side on every call. See "Matriz/filial" below — this touched
  `buildAuthPrefix()` and therefore **every one of the 10 workflows that use it** had to be
  recreated, not just edited. A real bug was caught and fixed during this work (an inverted
  IF-branch in the new logic that made *every* request take the "verify a different empresa"
  path, including ones with no override at all) — see that section for what to watch for if this
  logic is ever touched again.
- **Multi-select combined view** (2026-09-15, same day, extending the matriz switcher above right
  after it shipped) — the header selector became a checkbox panel; selecting 2+ empresas shows
  lançamentos and Resumo **summed across all of them** instead of switching one at a time, with
  creation forms disabled in that mode. Frontend-only change (no new backend workflow) — see
  "Matriz multi-select switcher" under Frontend below.
- **Self-service matriz/filial linking added to public signup** (2026-09-15, same day) — the
  `12-cadastro-publico` form gained an optional `token_matriz` field so a filial can link itself
  to an existing matriz *without* an admin running `11-onboarding`. Security-load-bearing detail:
  it's the matriz's real `access_token`, not its (public, guessable) slug — see "Public
  self-service signup" below for why that distinction is the whole point.
- **Color palette changed to "Gestão de Patrimônio / Alta Renda"** (2026-09-15, same day) — user
  explicitly requested a luxury wealth-management look with 4 exact hex values, replacing the
  earlier professional navy (slate-800/900) theme from the same day. See "Color palette" under
  Frontend below.

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
Fase 4 — nome, **email** — nullable, only required going through `11-onboarding`; older rows like
`demo2` predate this column and have it null — timezone, moeda), `categorias`
(receita/despesa, scoped-unique per empresa via `unique(empresa_id, nome, tipo)`), `contas`
(caixa/banco/cartão, with saldo_inicial), `transacoes` (the ledger: tipo, valor, data, status
previsto/confirmado, origem manual/importado, FKs to conta+categoria). Two composite indexes on
`transacoes`: `(empresa_id, conta_id, data)` and `(empresa_id, categoria_id, data)`.

### Deployed workflows (`n8n-workflows/`)

Every workflow starts the same shared auth prefix, built once as `buildAuthPrefix()` in
`n8n_lib.mjs` so all 10 workflows that need per-empresa auth share the exact same check (the other
2 — `11-onboarding`, `12-cadastro-publico` — don't, see their own entries below). As of the
matriz/filial work (2026-09-15) the prefix is longer than just token resolution — see "Matriz/filial"
below for the full graph and why. The one invariant every downstream workflow script relies on:
**the prefix always ends at a node literally named `Checar Empresa`**, carrying at minimum
`{encontrada: true, empresa_id}` (plus every other column of whichever empresa row was ultimately
resolved) — every workflow's own code references `$('Checar Empresa').first().json.empresa_id`
(or other fields on it) without needing to know or care whether an override happened upstream.
Files are the exact JSON exported after live testing (nodes/connections/settings only —
n8n-managed fields like `versionId`/`shared` stripped).

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
  form has no way to populate its conta/categoria selects without them. Same shared
  `buildAuthPrefix()` shell as every other workflow, `matchType: allFilters` on `empresa_id` only,
  no filters beyond that.
- **`10-empresa-info`** (`GET /webhook/financeiro/empresa-info`) — also added during Fase 3.
  Returns `{id, slug, nome, timezone, moeda, filiais}` for the **resolved** empresa (the active
  one — itself or, via `empresa_id` override, a filial being viewed as the matriz) — reads
  `$('Checar Empresa')`, not `$('Resolver Empresa')` (which is always the *token's own* row,
  wrong once matriz/filial override exists). `filiais` (`[{id, slug, nome}]`) is a parallel
  dead-end branch off `Checar Empresa` (`Buscar Filiais`, same "read a sibling branch's output by
  name" pattern as `07-resumo-periodo`) filtered by `matriz_id eq` the **token's own** empresa_id
  (via `$('Checar Empresa Token')`, not the resolved one) — deliberately constant regardless of
  which filial is currently being viewed, so the frontend's switcher doesn't lose its own list of
  options the moment you switch away from the matriz.
- **`11-onboarding`** (`POST /webhook/financeiro/onboarding`, Fase 5) — the one workflow that does
  **not** use `buildAuthPrefix()`/`X-Empresa-Token`, because it creates an empresa rather than
  acting on one that already exists. Protected instead by n8n's built-in webhook `authentication:
  "headerAuth"` (checked by n8n itself before the workflow runs, no custom node needed) against a
  separate `httpHeaderAuth` credential (`X-Admin-Token`, credential id `0Ge9oeKKwekA6ZI3`, name
  "Admin - app_financeiro onboarding"; the secret value lives in `.env` as
  `onboarding_admin_token:`, never in this repo's workflow JSON — same "credential, not env var,
  not hardcoded" pattern as the Supabase key). **Never confuse this admin token with an empresa's
  `access_token`** — the admin token can create empresas; an empresa token can only touch its own
  data. Body: `{slug, nome, email, matriz_slug?, moeda?, timezone?, categorias?: [{nome,tipo}],
  conta_inicial?: {nome, tipo, saldo_inicial}}` — `email` is **required** (see "Onboarding email"
  below for why); `categorias`/`conta_inicial` default to the same starter set `demo` has in
  `schema.sql` if omitted; `matriz_slug` optionally links the new empresa as a filial (see
  "Matriz/filial" below — resolved and validated, 400 if the named matriz doesn't exist, is
  inactive, or is itself a filial, *before* `Criar Empresa` runs, via the same
  resolve-then-normalize-to-one-node-name pattern used for the auth prefix's target check, here
  named `Matriz Resolvida`). Generates the new empresa's `access_token` itself (`'fin_' +
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

### Onboarding email (Resend)

Added post-launch (2026-09-15) so the operator doesn't have to manually copy/paste the new
empresa's `access_token` to the client. In `11-onboarding`, after `Criar Conta Inicial` →
`Montar Resposta` (which now also carries `empresa.email`): `Enviar Email Boas Vindas` (HTTP
Request node, `POST https://api.resend.com/emails`, `authentication: "genericCredentialType"` +
`genericAuthType: "httpHeaderAuth"` against credential `Resend - app_financeiro`, id
`1wGIJB3O2aPKsiOi` — header `Authorization: Bearer <sending-only Resend key>`, value never in this
repo's JSON) → `Registrar Envio` (Code, folds the HTTP result into the response as
`email_enviado`/`email_erro`) → `Responder Sucesso`.

- **`continueOnFail: true`** on the email node, deliberately — a Resend outage or bad email
  address must not make empresa creation fail; the empresa, its categorias, and conta are already
  committed by that point regardless. `Registrar Envio` reads `$json.error` (present when
  `continueOnFail` catches a non-2xx) to decide `email_enviado`.
- **Two Resend API keys exist, on purpose, with different scopes**: `resend_api_key_sending` in
  `.env` (Sending-access only — this is the one wired into the n8n credential above, used for every
  real send) and `resend_api_key_full` (Full access — used once to add/verify the domain via
  Resend's API, not referenced by any workflow). Resend enforces this split server-side: a
  sending-only key gets a hard 401 on `POST /domains` or `POST /api-keys` (confirmed by testing) —
  don't "simplify" this back down to one key thinking it's redundant.
- **Sending domain**: `engenhariadedadosn8n.shop`, verified in Resend via DKIM (TXT
  `resend._domainkey`) + SPF (MX and TXT on `send`) + a `rsend` CNAME, all as Cloudflare DNS
  records (DNS only, matching the zone's usual pattern). From address hardcoded in the workflow:
  `app_financeiro <financeiro@engenhariadedadosn8n.shop>` — no real inbox behind that address,
  it's send-only. Domain verification is **not instant**: Resend's own check lags behind actual
  DNS propagation by anywhere from minutes to about an hour even after `POST
  /domains/{id}/verify` — confirmed by testing (DNS was correct and resolving via 1.1.1.1 well
  before Resend's `status` flipped from `pending` to `verified`). Before that flip, every send
  fails with a `403`/`"domain not verified"` from Resend — this is expected transient behavior
  right after first setting up the domain, not a bug to chase.
- **Email body** is a hardcoded HTML string built in the request's `jsonBody` expression (not a
  template file) with the empresa's nome and a `{APP_URL}/?token=<access_token>` link plus the
  raw token as a fallback. `APP_URL` is a constant in `build_onboarding.mjs`
  (`https://financeiro.engenhariadedadosn8n.shop`) — if the production frontend domain ever
  changes, this needs updating and the workflow needs re-deploying (create+activate, per the usual
  pattern — see "Working with this repo").
- **Known gap**: no retry/resend mechanism if `email_enviado: false` — the operator has to notice
  the response field and fall back to manually sending the `access_token` that's still in the same
  response.

### Public self-service signup (`12-cadastro-publico`)

Added post-launch (2026-09-15), same day as the Resend integration — user explicitly asked for a
frontend "cadastrar empresa" button, was told the tradeoff, and chose to accept it: **this
workflow has no authentication of any kind**, unlike every other workflow in this project. That's
deliberate, not an oversight — `11-onboarding` requires `X-Admin-Token`, which can never be
embedded in frontend JS (anyone viewing page source could copy it and create empresas using the
operator's own admin credential). So this is a second, separate, intentionally-public workflow
that does almost the same thing as `11-onboarding` but hardcodes the categoria/conta defaults
(no `categorias`/`conta_inicial` override — a public caller doesn't get that much control) and,
critically, **never returns `access_token` in the response** — only `{sucesso, email_enviado,
mensagem}`. The token only ever leaves the system via the Resend email. This is intentional: an
admin calling `11-onboarding` from a trusted context (`curl`, `X-Admin-Token` in hand) can
reasonably see the token as a fallback if email fails; an anonymous public caller should not get a
working credential handed back in the same HTTP response that has no rate limiting on it.

- **No abuse protection exists today** — no captcha, no rate limiting, no disposable-email
  blocking. Anyone can call `POST /webhook/financeiro/cadastro-publico` as many times as they want
  and create unlimited empresas (each just needs a unique `slug`). Known, accepted gap — revisit
  if it actually gets abused, not preemptively.
- Body: `{nome, slug, email, token_matriz?}`. Same validation rules as `11-onboarding` for each
  required field. Structurally the workflow is a near-duplicate of `11-onboarding`'s graph (same
  auth-less-but-still-validated shape, same parallel-branch categorias/conta-inicial pattern, same
  Resend HTTP node) — deliberately **not** refactored into a shared sub-workflow, because the two
  have different security postures (admin vs. public) and different response shapes; keeping them
  as separate, independently-readable workflow files was judged safer than a shared abstraction
  that could accidentally leak the wrong behavior into the wrong caller if edited carelessly later.
- **`token_matriz` — self-service matriz/filial linking, added 2026-09-15** (same day as the
  matriz/filial feature itself; the user asked specifically for a way to do this from the signup
  screen). Deliberately named/shaped differently from `11-onboarding`'s `matriz_slug`: this one
  takes the matriz's actual **`access_token`**, not its slug. A slug is public (visible in any
  URL/link for that empresa) and proves nothing; an `access_token` is a real credential, so
  providing it is proof of actually controlling the matriz — the only ownership check this public,
  unauthenticated endpoint can rely on. Resolution: `Verificar Matriz Por Token` (Supabase getAll
  `empresas` by `access_token eq` + `ativo eq true`) → `Checar Matriz Token` (valid only if found
  **and** `matriz_id is null`, i.e. the token's own empresa isn't itself a filial — same 2-level
  enforcement as `11-onboarding`) → `Matriz Token Valida?` → 400 `"Token de matriz invalido ou
  essa empresa ja e uma filial"` on failure (deliberately one message for "token doesn't match any
  empresa" and "token matches a filial" — no reason to help a caller distinguish those). Same
  resolve-then-converge-to-one-node pattern (`Matriz Resolvida`) as `11-onboarding`'s
  `matriz_slug` handling. Verified by testing: valid matriz token → filial created with the right
  `matriz_id` (checked directly in the DB and via the frontend's switcher); omitted → independent
  empresa (`matriz_id` null, unchanged default); a filial's own token used as `token_matriz` → 400
  (can't create a 3rd level); a fabricated/nonexistent token → 400.
- Frontend wiring: `frontend/index.html`'s `#appGate` now has two toggled panels
  (`#painelEntrar`/`#painelCadastro`, plain `hidden`-class toggling, no routing) — "Ainda não tem
  cadastro?" / "Já tem cadastro?" links swap between them. The signup form's `slug` field
  auto-fills from `nome` via a local `slugificar()` (strips accents, lowercases, replaces
  non-alphanumerics with `-`) **until the user edits `slug` by hand** (`slugEditadoManualmente`
  flag on its `input` event) — don't reintroduce a naive two-way binding that would stomp a
  manually-typed slug on every keystroke in `nome`. The submit handler calls `cadastro-publico`
  directly with a bare `fetch` (not the `api()` helper — there's no empresa token to attach yet,
  and this call must never send one), shows the response `mensagem` in place (green
  `#sucessoCadastro` / red `#erroCadastro`), and resets the form on success. The `token_matriz`
  field lives inside a `<details>` element ("É filial de uma empresa que já usa o sistema?"),
  collapsed by default since most signups aren't filiais — no JS needed for the collapse/expand
  itself (native `<details>` behavior), and the field's value is still included in the submitted
  `FormData` whether the `<details>` is open or closed (confirmed by testing: setting the input's
  value while collapsed and submitting without ever expanding it still sent `token_matriz`
  correctly — don't assume it needs to be visibly open to work). Empty input submits as `""`,
  which `Validar Dados` on the backend already treats as "not provided" (falsy check) — no
  frontend-side conversion to `null`/omission needed.

### Matriz/filial

Added 2026-09-15, after the user asked specifically for "my empresa can see all its branches"
and confirmed the tradeoffs (touches every workflow; negligible perf cost — one extra indexed
lookup, only on requests that actually specify an override). Two-level only: `empresas.matriz_id`
(nullable self-FK) — null means independent or *is* a matriz; set means "is a filial of that row."
A filial cannot itself have filiais (enforced in `11-onboarding`'s `Checar Matriz` node, not by a
DB constraint — checks the target's own `matriz_id is null` before allowing it to be used as a
new empresa's matriz).

**How a matriz acts on a filial's behalf**: its own `access_token` stays the single credential
(no separate "matriz mode" token). Any request to any of the 10 `buildAuthPrefix()` workflows can
include `empresa_id` (body field on POST, query param on GET) naming a *different* empresa than
the one the token resolves to. The extended prefix (in `n8n_lib.mjs`, replacing the old
token-only version):

```
Token Presente? →(false) Responder Token Ausente (401)
  →(true) Resolver Empresa (by access_token) → Checar Empresa Token (Code: {empresa_id, empresa: <full row>})
  → Empresa Encontrada? →(false) Responder Token Invalido (401)
    →(true) Determinar Alvo (Code: reads body/query.empresa_id; if absent or === token's own id,
             {precisaVerificar:false, empresa_id: token's, empresa: token's row};
             else {precisaVerificar:true, empresa_id_alvo, empresa_token_id})
    → Precisa Verificar Alvo? →(true, index 0) Resolver Empresa Alvo (by id+ativo)
        → Checar Permissao Filial (Code: permitido = alvo.matriz_id === empresa_token_id)
        → Permitido? →(true) Checar Empresa   →(false) Responder Sem Permissao (403)
      →(false, index 1) Checar Empresa   ← both paths converge here
```

- **The convergence trick**: the final node is deliberately named `Checar Empresa` — same name
  the old (pre-matriz) prefix used for token resolution — specifically so every downstream
  workflow's existing `$('Checar Empresa').first().json.empresa_id` (and now, other fields too;
  see below) keeps working with **zero changes to the 10 individual workflow build scripts**. Only
  `n8n_lib.mjs` changed; re-running every script picked up the new prefix automatically. This is
  why the token-resolution step itself got renamed to `Checar Empresa Token` — freeing up
  `Checar Empresa` to mean "the final resolved empresa for this request" instead of "the token's
  empresa." `Checar Empresa`'s body is now just `{ encontrada: true, empresa_id: $json.empresa_id,
  ...$json.empresa }` — it spreads the *entire resolved empresa row* through, not just the id, so
  anything downstream that wants `nome`/`moeda`/`slug`/etc. of whichever empresa is actually being
  acted on can read it from the same node it already references (used by `10-empresa-info`).
  Fan-in (two different IF branches both targeting the same node name) is a normal, supported n8n
  pattern here — exactly one branch fires per request since they're mutually exclusive, so
  `Checar Empresa` runs exactly once regardless of which path was taken.
- **Bug caught during this work, now fixed**: n8n IF-node output index 0 is the *true* branch,
  index 1 is *false* (confirmed and relied on throughout this project). The first version of
  `Precisa Verificar Alvo?`'s wiring had this backwards — index 0 (true, "needs verification") was
  wired to `Checar Empresa` (skip) and index 1 (false, "no override") was wired to `Resolver
  Empresa Alvo` (go verify), which crashed *every* request, including ones with no override at
  all, on `invalid input syntax for type bigint: "undefined"` (from `empresa_id_alvo` being
  undefined). Caught immediately by testing (`empresa-info` and `listar-categorias` both returned
  HTTP 200 with an empty body — silent-looking failure, only visible via `GET
  /api/v1/executions/{id}?includeData=true`'s `resultData.error`, not from the HTTP response
  itself). The exact same inversion was independently made in `11-onboarding`'s new `Tem Matriz?`
  IF node and fixed the same way. **If you add a new IF node to this codebase, double-check which
  index is wired to which branch before assuming it's right** — this bug produced no error at the
  HTTP layer, only in the n8n execution log.
- **Permission check is per-request, not cached**: every call re-verifies `alvo.matriz_id ===
  token's empresa_id` against the live DB row — a filial removed from a matriz (if that ever
  becomes possible; no workflow does it today) would lose matriz access on the very next request,
  no token rotation needed.
- **Security properties verified by testing** (all with real created-then-deleted matriz/filial
  pairs, not just read-through of the logic): matriz token + filial's `empresa_id` → succeeds,
  writes land on the filial (confirmed by then reading them back with the *filial's own* token);
  unrelated empresa's token + filial's `empresa_id` → 403; filial's own token + its matriz's
  `empresa_id` → 403 (a filial is never anyone's matriz); matriz token + a totally unrelated
  empresa's `empresa_id` → 403; matriz token + its *own* `empresa_id` explicitly → identical to
  omitting it entirely (no-op case, confirmed working).
- **`10-empresa-info`'s `filiais` list** is what the frontend's switcher renders — see "Matriz
  switcher" under Frontend below.

### Frontend (`frontend/index.html`)

Single static file, vanilla JS, Tailwind via CDN, no build step. Gated behind a token screen
(`#appGate`, hidden/shown via the `hidden` Tailwind class, never real navigation) — see "Auth"
below for how the token itself works; nothing else in the page loads until `iniciarApp()` runs.
All API calls go through one `api(path, {method, query, body})` helper in the `CONFIG.API_BASE` =
`https://n8n.engenhariadedadosn8n.shop/webhook/financeiro` namespace, which attaches the stored
token as the `X-Empresa-Token` header on every call automatically — no call site needs to remember
auth, and none of them send `slug` anywhere (there's nothing left in this project that reads it).
`api()` accepts an `empresaId` option that, when passed, overrides `state.empresaAtivaId` for
*that one call only* — attached as `empresa_id` (query for GET, body for POST). Without it, falls
back to `state.empresaAtivaId`. This explicit-override-beats-shared-state design is deliberate:
see the "no shared-mutable-state race" note below.

**Matriz multi-select switcher** (extended 2026-09-15 from an earlier single-select version — the
user explicitly asked to view several empresas' data *combined*, not just switch one at a time).
State: `state.empresaHome` (`{id, nome}`, captured once from the token's own identity, never
changes), `state.empresasDisponiveis` (`[{id, nome}]` = home + every filial, constant per
session), `state.empresasSelecionadasIds` (array, **always ≥ 1** — enforced in the checkbox
handler, which silently re-checks a box if unchecking it would leave zero selected), and
`state.empresaAtivaId` (only meaningful — and only set — when exactly one id is selected; `null`
whenever 2+ are, which is what forces every multi-fetch loop to pass `empresaId` explicitly rather
than accidentally relying on stale shared state).

- **UI**: `#botaoSeletorEmpresa` (hidden unless `empresasDisponiveis.length > 1`) toggles
  `#painelSeletorEmpresa`, a checkbox list (one per available empresa, "(própria)" suffix on
  home). A document-level click listener closes the panel on any click outside it —
  **when testing this by driving the page programmatically, close the panel (click elsewhere)
  before clicking anything else in the header/nav**, since the open panel visually overlaps that
  area and a coordinate-based click can land on a checkbox instead of, say, the "Resumo" tab
  (this happened during testing — not a bug, just a reason to prefer `find`/ref-based clicks or an
  explicit close-panel step over blind coordinates here).
- **Single selected (the common case, and the only case for any empresa with no filiais)**:
  behavior is unchanged from before this feature existed — `state.empresaAtivaId` is set, one
  `empresa-info` call populates `state.empresa` and the header (nome/slug), and
  `[data-form-empresa-unica]`-marked elements (the lançamento form, and the categoria/conta
  creation forms — see below) are visible.
- **2+ selected → combined view, read-only**: `state.empresaAtivaId` is set to `null`;
  `#avisoMultiEmpresa` ("visualização somada... selecione só uma pra adicionar") and
  `#colEmpresaHeader` (an extra "Empresa" column in the lançamentos table) become visible; every
  `[data-form-empresa-unica]` element (lançamento form + both cadastro forms in Categorias &
  Contas) is hidden — creating a new row while 2+ empresas are selected is deliberately not
  supported, since which empresa it would belong to is ambiguous. `carregarCategorias()`,
  `carregarContas()`, and `carregarTransacoes()` each loop over `empresasSelecionadasIds`, calling
  `api(path, { empresaId: id })` once per id and concatenating the results (tagging each
  transação with `_empresaId` for the "Empresa" column and for `excluir-transacao`, which needs to
  know which empresa a given row belongs to once `state.empresaAtivaId` is no longer reliable).
  `carregarResumo()` does the same per-empresa loop and **sums** `totais` client-side, prefixes
  each `saldo_por_conta`/`por_categoria` row with the empresa's nome (own + filiais share one flat
  `contas`/`categorias` id space — Postgres `identity` columns are global per table, not
  per-empresa, so no id collisions are possible when merging — but nomes like "Caixa" or "Vendas"
  very plausibly repeat across companies, hence the prefix). **Assumes every selected empresa
  shares one moeda** (defaults display to BRL in this mode) — there's no UI or backend support for
  mixing currencies in one combined total; not a concern today since nothing in this project
  actually varies `moeda` per empresa yet, but would need real handling if that ever changes.
- **No shared-mutable-state race**: the multi-fetch loops inside `carregarCategorias()` /
  `carregarContas()` / `carregarTransacoes()` / `carregarResumo()` run under `Promise.all` (or
  sequential `await` in a loop) — if `empresaId` were threaded through a shared field like the old
  single-select `state.empresaAtivaId` instead of passed as an explicit `api()` option, concurrent
  calls could read each other's in-flight mutation and attach the wrong empresa_id to a request.
  This is *why* `api()` grew the explicit `empresaId` parameter during this change rather than
  reusing the existing shared-state mechanism for multi-select too.
- **Persistence**: `localStorage` key `financeiro_empresa_ativa_id` now stores a JSON array of
  ids (was a single number before this change — `getEmpresasSelecionadasSalvas()` tolerates a lone
  number for backward compatibility, treating it as a 1-element array). `carregarEmpresa()` on
  boot filters the saved array down to ids that are still in the fresh `empresasDisponiveis` list
  (handles a filial being unlinked since last visit, *and* a completely different token logging in
  on the same browser leaving behind a saved selection that means nothing to it — confirmed by
  testing both). If filtering leaves zero valid ids, falls back to `[home.id]`. `clearToken()`
  (logout) also clears this key.

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
Also verified after adding public signup: nome→slug auto-fill, duplicate-slug error rendering,
panel toggling both directions, and the full loop (signup → real email received → link → logged
into the freshly-created empresa with its default categorias/conta present).

Also verified after adding the matriz switcher (single-select version, since superseded): switcher
hidden for an empresa with no filiais (`demo`); visible and correctly populated for a matriz;
switching to a filial updates nome/slug/categorias/contas/transacoes all at once and a lançamento
created there lands on the filial (confirmed via the filial's *own* token separately); switching
back shows zero lançamentos (no leak); choice persists across reload; a filial's own token ignores
a stale matriz-scoped `localStorage` value from a prior session.

Also verified after extending to multi-select (real matriz + 2 filiais, each seeded with one
transação): checking a 2nd/3rd box switches into combined view — "N empresas selecionadas" header,
"Empresa" column appears in the lançamentos table with the right name per row, `#avisoMultiEmpresa`
shows and `#cardNovoLancamento`/the two cadastro forms all hide; Resumo's totals summed correctly
(R$100+R$200 receitas = R$300 across two companies, confirmed by direct addition) and
`saldo_por_conta`/`por_categoria` rows carried the right empresa-name prefix per row; unchecking
back down to one selection restored the ordinary single-empresa view (form visible again, no
"Empresa" column). One non-bug caught while testing: with the checkbox panel left open, a
coordinate-based click meant for the "Resumo" tab landed on a checkbox underneath it instead
(unchecked a filial) — confirms the "close the panel first" testing note above; the page's own
click-outside-closes-panel handling was not itself at fault.

### Color palette

Changed 2026-09-15 from the earlier professional navy theme (slate-800/900) to a luxury
wealth-management palette, on explicit user request with 4 exact hex values — applied via Tailwind
arbitrary-value classes (`bg-[#...]`, `text-[#...]`) since none of these map to a stock Tailwind
color:
- **Primary** (`#1E3A2F`, dark olive green) — every primary action button (`Entrar`, `Cadastrar`,
  `Adicionar`, the categoria/conta `+` buttons), `hover:bg-[#16281F]` (a manually darkened shade,
  not a Tailwind-generated one, since arbitrary hex values have no built-in hover scale).
- **Secondary/accent** (`#D4AF37`, champagne gold) — used *only* for the active tab's bottom
  border in `.tab-btn.active` (see the `<style>` block), matching the user's own framing ("usado
  cirurgicamente em detalhes") — deliberately not used anywhere else (no gold buttons/backgrounds).
- **Background** (`#FDFBF7`, soft sand) — `<body>`.
- **Main text** (`#111111`, charcoal) — `<body>` text color plus every heading (`text-slate-900`
  was replaced with this everywhere it appeared).
- **Deliberately left unchanged**: secondary/muted text and borders (`text-slate-500`/`400`,
  `border-slate-200`/`100`) and the semantic receita/despesa colors (`emerald`/`red` for
  income/expense badges and totals) — the user's request specified only these 4 roles, and
  green/red for receita/despesa is a separate semantic convention, not part of the brand palette.
- Verified by rendering the gate screen locally (`python -m http.server` + browser screenshot):
  sand background, olive buttons/heading, charcoal text all confirmed. The authenticated app view
  (`#app`) reuses the exact same Tailwind classes verified on the gate screen, so it wasn't
  re-screenshotted individually.

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
