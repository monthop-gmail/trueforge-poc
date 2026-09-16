# Dual MCP PoC — results

Round 1 run 16 Sep 2026 (direct paths). Round 2 the same evening, after the owner opened a
free TrueFoundry Developer tenant, closed the gateway path. Raw output: `evidence/`.
Every number below came from a script in `scripts/`; nothing is inferred from source.

## Status by path

| Path | Status | Basis |
| --- | --- | --- |
| **Direct Bearer** (with and without the TrueForge harness) | **PASS** | `smoke-bearer.sh` 14/0, `probe-trueforge.sh` 11/0 |
| **Direct OAuth** — IT Ops hub | **PASS** | `probe-oauth.sh` 13/0 + a full code flow driven by TrueForge itself |
| **Direct OAuth** — Collaboration | **NOT RUN** | discovery PASS; DCR would register a client on the shared production Worker |
| **Gateway Bearer** (header credential on the connector) | **PASS** | `probe-gateway.sh` 12/0 — both servers, live tenant |
| **Gateway OAuth** | **BLOCKED** | the gateway does not send PKCE and its redirect host is not on the hub's trusted list — see finding 6 |
| **Gateway authorization** (a principal who should be refused) | **NOT RUN** | needs a second TrueFoundry principal without access to the connector — see finding 8 |

## Acceptance criteria

| AC | Verdict | Evidence |
| --- | --- | --- |
| AC1 topology + versions + repeatable start | **PASS** | `dual-mcp-overview.md` §2, `dual-mcp-runbook.md`; one gap: the deployed Collaboration Worker is not pinnable to a commit |
| AC2 initialize + tools/list + one read call, both servers | **PASS (direct and gateway)** / **PARTIAL (harness)** | direct and through the gateway: 15 collab tools + 24 IT tools, real read calls on both. Through TrueForge: same counts discovered, but tool *execution* is **NOT RUN** — the harness has no call API outside an agent turn, which needs a model provider |
| AC3 missing/wrong token rejected; IT token rejected at admin and accounting | **PASS (direct)** / **PARTIAL (gateway)** | direct: 401 on missing and wrong token at both servers, 403 for the IT token at `/mcp/admin` and `/mcp/accounting`. Gateway: 401 on missing and wrong PAT for both connectors, and a connector pointing the IT token at the admin path was refused `403 "This token cannot access this MCP path"`. That 403 is **upstream RBAC surfacing through the gateway, not gateway policy** — gateway policy itself is the NOT RUN row above |
| AC4 IT tool list exposes no privileged shell | **PASS (direct and gateway)** | 24 tools, none matching `run_shell`/`exec`/`command`; no shell tool was called |
| AC5 collaboration identity is the team identity | **PASS, with a caveat that matters** | `you_are=monthop-gmail/trueforge` on both the direct and the gateway path, and the handoff was accepted under that same name. It is a **service/team identity, not a human or model identity** — and see finding 1 |
| AC6 OAuth exercised on both servers, refresh and restart recorded | **PASS (IT Ops, direct)** / **NOT RUN (collab)** / **BLOCKED (gateway)** | direct: DCR → PKCE S256 → consent → code → token → tools/list → refresh, all green; replayed code with a wrong verifier rejected; restart behaviour in finding 3. Gateway OAuth: finding 6 |
| AC7 evidence separable per layer, no credentials in logs | **PASS** | hub, harness and gateway evidence in separate files; scripts print no token values and compare secrets by SHA-256 prefix |
| AC8 demo: IT read → finding → recorded in collaboration | **PARTIAL** | the IT read and the write-back both happened (this report). The write landed on the **shared** workspace, because no test deployment of the collaboration MCP exists |
| AC9 teardown does not disturb anything real | **PASS** | sandbox is its own compose project on shifted ports with its own generated tokens; the one connector created for the cross-role test was deleted afterwards, leaving the tenant with exactly the two intended connectors |

Run totals: `smoke-bearer` 14/0 · `probe-oauth` 13/0 · `probe-trueforge` 11/0 · `probe-gateway` 12/0.

## Findings

### 1. On the collaboration MCP, a static Bearer does not fix who you are

Same token, three requests, three different answers from `get_workspace_context.you_are`:

| `X-Client-Name` sent | identity reported |
| --- | --- |
| `monthop-gmail/trueforge` | `monthop-gmail/trueforge` |
| *(header omitted)* | `Claude Code` |
| `poc-identity-probe` | `poc-identity-probe` |

The name is **asserted by the caller and not bound to the token**. Authorship in the
workspace is therefore only as trustworthy as every holder of that one token. The probe
deliberately used a name nobody owns; no existing participant's name was borrowed.

Round 2 makes this sharper, not milder: the gateway now sends that header on behalf of
everyone who calls the connector, so upstream sees one name for the whole team. Per-caller
attribution exists only in the gateway's own records.

*Recommendation:* bind identity to the token server-side, and treat `X-Client-Name` as a hint
that can only narrow, never choose, the identity.

### 2. The hub's OAuth access_token *is* the shared role token

After a complete authorization-code exchange, the issued `access_token` has the same SHA-256
prefix as the static `IT_TOKEN`. The response advertises `expires_in: 28800`, but the value
handed out is the same long-lived secret Nginx matches on, so the expiry is descriptive only:
one client cannot be revoked without revoking all of them, the expiry cannot be enforced at
the Nginx layer, and an OAuth-issued token is indistinguishable from a pasted one in an audit
trail.

This is also why choosing header auth at the gateway (finding 7) costs nothing in security
terms — the OAuth path would have delivered the same secret.

### 3. OAuth client state is in memory; restart wipes it, Bearer keeps working

A refresh token minted before `docker compose restart mcp-oauth` returns `invalid_client`
after it. Static Bearer traffic answers 200 across the same restart. During the seconds the
service is down, `/authorize` and `/token` return 502 while `/mcp/it/mcp` keeps serving.

An OAuth-connected agent loses its connection on every deploy; a Bearer-connected one does
not. Expected limitation of MemoryStore, not a regression — but it makes OAuth the less
reliable of the two paths today, which is the opposite of what a reader would assume.

### 4. The harness handles the two servers well — with one misleading status

TrueForge 0.1.4 reached both servers, redacted stored header secrets in every API response,
ran DCR + PKCE S256 on its own, and surfaced the hub's 403 verbatim instead of swallowing it.

But a connector configured with a credential that is refused upstream still reports
`auth_status: authenticated`. The field tracks *"a credential is attached"*, not *"the
credential works"*. Worth knowing before anyone builds a health view on it.

### 5. TrueForge is not a gateway, and the gateway is not TrueForge

The harness connects to MCP servers; it never serves MCP. Its API has 47 routes and none
speaks the protocol — `/api/v1/mcp-servers*` manages connectors. There is no
`StreamableHTTPServerTransport` or `new McpServer()` in the server packages; the MCP server it
does construct is handed into the agent sandbox. And tool calls happen only inside an agent
turn, which needs a model provider, so a gateway built on it would bill an LLM round trip per
tool read.

The gateway is a separate installation in the TrueFoundry control plane
(`listGatewayInstallations` → `resolveDefaultGatewayUrl`), which is what round 2 used.

### 6. The gateway's OAuth cannot satisfy the hub's PKCE rule

The hub requires PKCE unless the caller is *publicish*
(`publicish = isPublicClient(clientId) || isTrustedRedirectUri(redirectUri)`, `app.ts:362`).
The gateway's redirect host is not on the hub's trusted list — a short allowlist of AI vendor
hosts plus loopback, kept so that clients which cannot do PKCE can still connect — and the
gateway sends no `code_challenge`. Both escape routes were tried and both dead-end, each
reproduced against the local sandbox on unmodified upstream code:

| connector config | result |
| --- | --- |
| DCR (`registration_url`) + gateway redirect + no PKCE | `400` "ไคลเอนต์ต้องส่ง code_challenge (PKCE)" |
| the hub's seeded public client + gateway redirect + no PKCE | `400 invalid_client` — that client carries `redirectUris: []` and only *trusted* hosts get auto-added |
| the same public client + a redirect host already on the allowlist + no PKCE | `200`, consent page renders |

The third row isolates the variable: the only difference is the host allowlist. Setting
`use_pkce` / `pkce` / `code_challenge_method` on the connector changes nothing — the API
stores unknown fields silently (even `__unknown_probe__` is accepted), so acceptance is not
evidence of support.

Adding the gateway's host to that allowlist would unblock both checks at once, and is the same
trust already granted to the AI vendor hosts on it. **It was not applied to
any site** — it is a production change and a deliberate PKCE exemption, so it belongs to the
owner, not to a PoC.

### 7. What the gateway connectors actually run on

Both connectors use `auth_data.type: "header"` with `auth_level: "global"`. Collaboration
carries `Authorization` plus `X-Client-Name`; the IT Ops connector carries `Authorization`
with the site's IT role token. Given finding 2, this is not a weaker choice than OAuth — it is
the same secret with fewer moving parts.

Discovered while configuring, since it is not in the public docs: `auth_data.type` accepts
exactly `header`, `passthrough` and `oauth2`, and `header` accepts exactly one `auth_level`,
`global` — every other value is rejected with `Unsupported header auth_level`.

### 8. The one thing a gateway is for is still untested

Every gateway call in this round was made by a single principal that is allowed everywhere.
So "the gateway refuses a caller who has no business on this connector" — the property that
makes a gateway worth having, and the half of AC3 that upstream RBAC cannot stand in for — is
**NOT RUN**. Closing it needs a second TrueFoundry principal (a virtual account or a second
user's PAT) with no permission on these connectors. The free Developer tier allows three
users, so this costs nothing but a decision.

## Go / No-go for round 3

**Go** for internal team use over either path: direct for anything running on the office
network, gateway for anything that should reach both systems through one door with one
inbound credential.

**No-go** for anything that depends on per-caller authorization, per-client revocation, or
trustworthy authorship in the shared workspace, until:

1. finding 8 is closed — until then "the gateway enforces access" is an assumption;
2. finding 1 is decided — token-bound identity, or an explicit ruling that workspace
   authorship is advisory;
3. the owner rules on finding 6 — allowlist the gateway host and get real OAuth, or stay on
   header credentials and accept a shared secret per connector;
4. the hub gets durable OAuth storage if OAuth is to be the recommended path (finding 3).

Also still open from round 1: a throwaway collaboration deployment (unblocks collaboration
OAuth and write tests) and a model provider credential (turns AC2's harness half into PASS).

**Data-path note for whoever signs off:** on the gateway path, tool traffic for both systems
transits TrueFoundry's cloud. Everything measured here was fixture data — the <site> RAG
backend reports `backend=fixture sample=true` — so no site data left the network during this
PoC. Pointing the gateway at a hub with real site data is a separate decision.
