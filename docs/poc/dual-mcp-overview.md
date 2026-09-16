# Dual MCP PoC — topology, versions, credential ownership

Team `monthop-gmail/trueforge`. Round 1 (direct paths) and round 2 (gateway), both 16 Sep 2026.
Plan of record: `plan-5584d6e3-f822-4cc4-8921-1c594c77b9f2` · thread `dis-bc779b20-aa97-421c-ba49-4623abe8123e`.

## 1. The two topologies, both now exercised

```
A — direct
   operator ─┬─ curl / MCP client ───────────────┐
             └─ TrueForge harness (local) ───────┤
                                                 ├─→ Collaboration MCP  (Cloudflare Worker)  /mcp
                                                 └─→ IT Ops Nginx (RBAC enforcement point)   /mcp/it/mcp
                                                        └─→ mcp-hub-it → sub-mcp-* (fixtures)

B — gateway
   client ─→ TrueFoundry AI Gateway ─→ (per-connector outbound credential) ─┬─→ Collaboration MCP
             inbound: TrueFoundry PAT                                       └─→ IT Ops hub at the IT Ops site
             https://gateway.truefoundry.ai/<tenant>/mcp/<connector>/server
```

Topology B is not something TrueForge brings with it. The OSS harness models it as a separate
manifest type — `MCPServerManifest` is a `oneOf` over `remote` and `truefoundry`, and the
`truefoundry` variant's `url` is the *"Resolved AI Gateway proxy URL"* the control plane hands
out (`listGatewayInstallations` → `resolveDefaultGatewayUrl`, `packages/trueforge/src/truefoundry/`).
Round 2 used the gateway directly rather than through the harness, so **"the gateway works"
and "the harness works" are two separate results in `dual-mcp-results.md`, not one.**

## 2. Version matrix (what was actually running)

| Component | Pin | How it ran |
| --- | --- | --- |
| TrueFoundry AI Gateway | installation `gateway-default` → `https://gateway.truefoundry.ai`, tenant `<tenant>` | SaaS, **Developer (free)** plan; control plane `https://<tenant>.truefoundry.cloud` |
| TrueForge harness | `@truefoundry/trueforge` **0.1.4** (npx, standalone/SQLite) | `localhost:8790`, `PUBLIC_BASE_URL=http://localhost:8790` |
| TrueForge source (read for the auth claims) | `truefoundry/trueforge` @ `ffcd60d8949c55527319fa912eeb0f11fb7e0475` (2026-09-16) | not built |
| IT Ops hub — sandbox | `monthop-gmail/itops-mcp-hub` @ `da63143431b1929f4e9ca2743263821faa3ee88d` | compose project `itops-poc`, `127.0.0.1:19080` |
| IT Ops hub — the IT Ops site | deployed by the site team, `https://<itops-site-host>` | reached only over the gateway, IT role, read-only |
| Collaboration MCP | deployed Worker, `serverInfo` `ai-collaboration` **0.1.0** | shared deployment (see §4) |
| Collaboration MCP source | `monthop-gmail/ai-collaboration-mcp` @ `55fdc5944cc4a0338bd771fd829f5a41a1f5765c` | reference only |
| MCP protocol | `2025-06-18` negotiated on every path | — |
| Host | Node v22.22.2, Docker Compose v5.0.2 | — |

**Gap to close:** the deployed Collaboration Worker's build is not pinnable from outside —
`serverInfo.version` is a hand-written `0.1.0`, not a commit. The source SHA above is what we
*read*, not provably what the Worker *runs*. The <site> hub is likewise pinned only by what the
site team reported.

## 3. What the sandbox runs (and does not)

Brought up from the hub repo with `--no-deps`, so only the MCP-facing half exists: `nginx`,
`mcp-oauth`, `mcp-hub-it`, `mcp-hub-admin`, and the five read-only sub-servers (`zabbix`,
`meshcentral`, `rag`, `zktime`, `pstack`). Every sub-server is on its **fixture** backend — no
Zabbix, no MeshCentral, no accounting hub, no tunnel, no site data. Ports are shifted off the
hub defaults (`19080`, `19443`, `19051`, `19444`, `14433`) so the sandbox cannot collide with a
real site deployment on the same host.

The sandbox is also where both gateway-OAuth dead ends were reproduced on unmodified upstream
code, so no experiment had to be run against a site to establish finding 6.

## 4. Credential ownership

| Credential | Issued by | Held by | Scope of blast radius |
| --- | --- | --- | --- |
| Sandbox `IT_TOKEN` / `ADMIN_TOKEN` / `ACCOUNTING_TOKEN` | generated for the sandbox only | sandbox `.env`, gitignored | the sandbox; no site token was copied into it |
| <site> `IT_TOKEN` | site deployment | entered by the owner into `.env.tfy` (gitignored, `0600`) and stored on the gateway connector | read-only IT role at one site; a shared secret with no per-client revocation (finding 2) |
| Collaboration static Bearer | pre-existing, owner-issued | this session's environment, and the gateway connector | **the shared production workspace** |
| TrueFoundry PAT | owner, free Developer tenant | `.env.tfy`, gitignored | the whole tenant — rotate when the PoC closes |
| OAuth client registrations on the hub | minted by DCR during the probes | hub `MemoryStore`, lost on restart | sandbox only |
| TrueForge connector secrets | copies of the above | local SQLite under `.local/` | redacted in every API response |

Two of these are not sandboxed — the collaboration Bearer and the <site> IT token — and both
now sit on a third-party gateway. That is the trade the gateway topology asks for, and it is
why the data-path note at the end of `dual-mcp-results.md` exists.

## 5. Dependencies still open

1. **A second TrueFoundry principal** — without one, gateway *authorization* is untested
   (finding 8). Free tier allows three users, so this is a decision, not a purchase.
2. **Collaboration test deployment** — blocks collaboration OAuth and any write test.
3. **A model provider credential for TrueForge** — the harness has no "call this tool" API;
   execution happens inside an agent turn, which needs a model. Discovery needs none, which is
   why discovery is proven and execution is not.
4. **A ruling on the hub's redirect allowlist** — gateway OAuth stays blocked until then
   (finding 6).
