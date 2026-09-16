# trueforge-poc

Proof of concept for team `monthop-gmail/trueforge`: reach the two internal MCP servers
(`ai-collaboration-mcp` and `itops-mcp-hub`) from the TrueForge harness, with auth, RBAC and
an identity we can explain.

Verdict: direct path **PASS**, gateway path **PASS** on a free TrueFoundry Developer tenant —
but gateway *authorization* is still untested, and gateway OAuth is blocked by a PKCE rule.
Read `docs/poc/dual-mcp-results.md` first — it carries the acceptance matrix and the
findings. `docs/poc/dual-mcp-overview.md` has the topology and version pins,
`docs/poc/dual-mcp-runbook.md` reproduces everything from scratch.

```
scripts/smoke-bearer.sh      direct Bearer baseline for both servers + negative auth/RBAC
scripts/probe-oauth.sh       OAuth discovery for both; full code+PKCE+refresh flow on a sandbox
scripts/probe-trueforge.sh   the same two servers, reached by the TrueForge harness itself
scripts/probe-gateway.sh     both servers reached through the TrueFoundry AI Gateway
evidence/                    raw output of the three runs
```

No script prints a token; secrets are compared by SHA-256 prefix. The flows that register an
OAuth client are opt-in (`ITOPS_RUN_FLOW=1`) and are meant for a sandbox you own.

Upstream checkouts live under `vendor/` and are not committed — they are pinned by SHA in the
overview doc.
