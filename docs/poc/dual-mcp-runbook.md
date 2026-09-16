# Dual MCP PoC — runbook

Reproduces every result in `dual-mcp-results.md` from a clean host. Nothing here touches a
site deployment, a production credential, or a privileged tool.

## 0. Prerequisites

`docker`, `docker compose`, `node` 22.14+, `curl`, `jq`, `openssl`, `python3`.

```bash
git clone https://github.com/monthop-gmail/itops-mcp-hub vendor/itops-mcp-hub   # pin: da63143
cp .env.example .env    # then fill in COLLAB_* for your deployment
```

## 1. IT Ops sandbox

```bash
cd vendor/itops-mcp-hub
cp .env.example .env
# three DIFFERENT tokens, sandbox-only — never copy a site token here
for k in IT_TOKEN ADMIN_TOKEN ACCOUNTING_TOKEN; do
  sed -i "s|^${k}=.*|${k}=$(openssl rand -hex 32)|" .env
done
sed -i 's|^MCP_LAN_PORT=.*|MCP_LAN_PORT=19080|;
        s|^PUBLIC_MCP_ORIGIN=.*|PUBLIC_MCP_ORIGIN=http://127.0.0.1:19080|;
        s|^PUBLIC_MCP_HOSTNAME=.*|PUBLIC_MCP_HOSTNAME=127.0.0.1:19080|;
        s|^ZABBIX_WEB_LAN_PORT=.*|ZABBIX_WEB_LAN_PORT=19443|;
        s|^ZABBIX_SERVER_LAN_PORT=.*|ZABBIX_SERVER_LAN_PORT=19051|;
        s|^MESHCENTRAL_HTTPS_PORT=.*|MESHCENTRAL_HTTPS_PORT=19444|;
        s|^MESHCENTRAL_AGENT_PORT=.*|MESHCENTRAL_AGENT_PORT=14433|' .env
chmod 600 .env

# --no-deps keeps Zabbix, MeshCentral, the accounting hub and the tunnel out of the sandbox.
docker compose -p itops-poc build sub-mcp-zabbix mcp-hub-it nginx mcp-oauth
docker compose -p itops-poc up -d --no-deps \
  sub-mcp-zabbix sub-mcp-meshcentral sub-mcp-rag sub-mcp-zktime sub-mcp-pstack \
  mcp-hub-it mcp-hub-admin mcp-oauth nginx
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:19080/healthz   # expect 200
```

## 2. TrueForge harness (standalone, SQLite, no infra)

```bash
mkdir -p .local/trueforge-data
SQLITE_PATH="$PWD/.local/trueforge-data/trueforge.db" PORT=8790 \
  PUBLIC_BASE_URL=http://localhost:8790 \
  npx -y @truefoundry/trueforge@latest    # pin used: 0.1.4
```

Two things that cost time if you don't know them:

- It binds **IPv6 loopback only**. `http://localhost:8790` works, `http://127.0.0.1:8790` does not.
- `PUBLIC_BASE_URL` must be the *same* spelling, or the OAuth callback it hands to the MCP
  server points somewhere the browser cannot reach.

## 3. Run the direct probes

```bash
set -a; . vendor/itops-mcp-hub/.env; . ./.env; set +a
export ITOPS_BASE_URL=http://127.0.0.1:19080 ITOPS_IT_TOKEN="$IT_TOKEN"

./scripts/smoke-bearer.sh                      # topology A, no harness: both servers + negative auth
ITOPS_RUN_FLOW=1 ./scripts/probe-oauth.sh      # discovery both servers; full code flow on the sandbox
ITOPS_RUN_FLOW=1 ./scripts/probe-trueforge.sh  # the harness itself reaching both servers
```

`ITOPS_RUN_FLOW=1` registers an OAuth client on the target. Set it only against a sandbox you
own. To re-run the consent leg after a connector already holds a token, pass a fresh name:
`ITOPS_OAUTH_SERVER_NAME=itops-it-oauth-run3`.

## 4. Gateway path (topology B)

Needs a TrueFoundry tenant. The free Developer plan is enough — this PoC used it.

```bash
cat >> .env.tfy <<'ENV'
TRUEFOUNDRY_SERVICEFOUNDRY_SERVER_URL=https://<tenant>.truefoundry.cloud/api/svc
TRUEFOUNDRY_API_KEY=<personal access token>
ENV
chmod 600 .env.tfy
```

Register one connector per server. `auth_data.type` accepts only `header`, `passthrough` and
`oauth2`, and `header` accepts only `auth_level: global`:

```bash
set -a; . ./.env.tfy; set +a
S="$TRUEFOUNDRY_SERVICEFOUNDRY_SERVER_URL"

# collaboration — the X-Client-Name header is what the workspace records as the author
jq -n --arg tok "Bearer $COLLAB_TOKEN" '{manifest:{type:"mcp-server/remote",
  name:"ai-collaboration-mcp",description:"Shared AI collaboration workspace.",
  url:"https://<collab-host>/mcp",
  auth_data:{type:"header",auth_level:"global",
    headers:{"Authorization":$tok,"X-Client-Name":"monthop-gmail/trueforge"}}}}' \
| curl -sS -X PUT "$S/v1/mcp" -H "Authorization: Bearer $TRUEFOUNDRY_API_KEY" \
       -H 'content-type: application/json' -d @-

# IT Ops site hub — same shape, the site's IT role token
jq -n --arg tok "Bearer $RYNST_IT_TOKEN" '{manifest:{type:"mcp-server/remote",
  name:"<itops-connector>",description:"IT operations hub at the IT Ops site, IT role, read-only.",
  url:"https://<itops-site-host>/mcp/it/mcp",
  auth_data:{type:"header",auth_level:"global",headers:{"Authorization":$tok}}}}' \
| curl -sS -X PUT "$S/v1/mcp" -H "Authorization: Bearer $TRUEFOUNDRY_API_KEY" \
       -H 'content-type: application/json' -d @-
```

Then probe:

```bash
TFY_TENANT=<tenant> ./scripts/probe-gateway.sh
```

Do **not** configure these connectors with `oauth2` against an itops hub: the gateway sends no
`code_challenge` and its redirect host is not on the hub's trusted list, so both the DCR and
the seeded-public-client variants fail. Finding 6 in `dual-mcp-results.md` has the reproduction.

A new connector can take a few seconds to become routable at the gateway; a first call may
answer `MCP server not found for integration ID`. Retry before diagnosing.

## 5. Optional: the OAuth state-loss experiment

```bash
docker compose -p itops-poc restart mcp-oauth
# a refresh_token minted before the restart now returns invalid_client;
# the static Bearer path keeps answering 200 throughout.
```

## 6. Teardown

```bash
docker compose -p itops-poc down -v          # removes the sandbox and its volumes
pkill -f '@truefoundry/trueforge'            # stops the harness
rm -rf .local/trueforge-data                 # drops its SQLite state and stored connector secrets
rm -f vendor/itops-mcp-hub/.env
```

Nothing outside this directory and the `itops-poc` compose project is created, so teardown
cannot disturb a site deployment. The one exception is the **collaboration workspace**: the
probes read it and the PoC report was posted to it. Those are workspace records, not
infrastructure, and are removed by editing the thread, not by this teardown.
