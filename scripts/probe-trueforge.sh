#!/usr/bin/env bash
# Topology-A probe: does the TrueForge harness itself reach both MCP servers?
#
# Registers (idempotently, via PUT) three connectors on a local TrueForge and
# asks TrueForge — not curl — to list each server's tools:
#   ai-collab        header auth  -> collaboration MCP
#   itops-it         header auth  -> IT Ops hub, IT role
#   itops-it-oauth   DCR auth     -> IT Ops hub, IT role, full OAuth code flow
#   itops-admin-neg  header auth  -> IT token pointed at the admin path (must fail)
#
# The OAuth leg scripts the consent step (an operator pasting the role token into
# the hub's consent form), so it only runs against a sandbox you own.
# Prints no token values.
set -uo pipefail

PASS=0
FAIL=0
SKIP=0
pass() { echo "PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL  $1${2:+ -- $2}"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP  $1${2:+ -- $2}"; SKIP=$((SKIP + 1)); }
note() { echo "NOTE  $1"; }

TF="${TRUEFORGE_URL:-http://localhost:8790}"
API="${TF}/api/v1"

put_server() {
  curl -sS --max-time 30 -o /dev/null -w '%{http_code}' -X PUT "${API}/settings/mcp-servers" \
    -H 'content-type: application/json' -d "$1" 2>/dev/null
}

# TrueForge answers with the tool list only after it has completed initialize +
# tools/list against the upstream, so a count here is harness-level evidence.
tool_count() {
  curl -sS --max-time 90 "${API}/mcp-servers/$1/tools" 2>/dev/null | jq -r '.data | length' 2>/dev/null
}

echo "== TRUEFORGE HARNESS PROBE =="
echo "run-at: $(date -Is)"
for cmd in curl jq openssl python3; do
  command -v "$cmd" >/dev/null || { echo "missing required command: $cmd"; exit 1; }
done

code="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' "${TF}/healthz" 2>/dev/null)"
if [ "$code" != "200" ]; then
  echo "TrueForge is not answering at ${TF} (HTTP ${code}). Start it first — see docs/poc/dual-mcp-runbook.md."
  exit 1
fi
pass "TrueForge /healthz 200 at ${TF}"

# ------------------------------------------------------------------- collab
if [ -z "${COLLAB_MCP_URL:-}" ] || [ -z "${COLLAB_TOKEN:-}" ]; then
  skip "collab connector: COLLAB_MCP_URL / COLLAB_TOKEN not set"
else
  code="$(put_server "{\"manifest\":{\"type\":\"remote\",\"name\":\"ai-collab\",\"url\":\"${COLLAB_MCP_URL}\",\"description\":\"Shared AI collaboration workspace (discussions, tasks, handoffs).\",\"auth\":{\"type\":\"header\",\"headers\":{\"Authorization\":\"Bearer ${COLLAB_TOKEN}\",\"X-Client-Name\":\"${COLLAB_CLIENT_NAME:-monthop-gmail/trueforge}\"}}}}")"
  [ "$code" = "200" ] || [ "$code" = "201" ] && pass "collab connector registered (HTTP $code)" \
    || fail "collab connector registration -> HTTP $code"
  n="$(tool_count ai-collab)"
  [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null && pass "TrueForge listed ${n} tools from collab" \
    || fail "TrueForge could not list collab tools"
fi

# -------------------------------------------------------------------- it ops
if [ -z "${ITOPS_BASE_URL:-}" ] || [ -z "${ITOPS_IT_TOKEN:-}" ]; then
  skip "itops connectors: ITOPS_BASE_URL / ITOPS_IT_TOKEN not set"
  echo
  echo "Summary: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
  [ "$FAIL" -eq 0 ]
  exit $?
fi

IT_URL="${ITOPS_BASE_URL}/mcp/it/mcp"
code="$(put_server "{\"manifest\":{\"type\":\"remote\",\"name\":\"itops-it\",\"url\":\"${IT_URL}\",\"description\":\"IT operations read-only tools (Zabbix, MeshCentral, RAG) via the hub IT role.\",\"auth\":{\"type\":\"header\",\"headers\":{\"Authorization\":\"Bearer ${ITOPS_IT_TOKEN}\"}}}}")"
[ "$code" = "200" ] || [ "$code" = "201" ] && pass "itops IT connector registered (HTTP $code)" \
  || fail "itops IT connector registration -> HTTP $code"
n="$(tool_count itops-it)"
[ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null && pass "TrueForge listed ${n} tools from itops IT" \
  || fail "TrueForge could not list itops IT tools"

# Same token, admin path: the hub must refuse and TrueForge must surface it.
code="$(put_server "{\"manifest\":{\"type\":\"remote\",\"name\":\"itops-admin-negative\",\"url\":\"${ITOPS_BASE_URL}/mcp/admin/mcp\",\"description\":\"Negative RBAC test: IT-role token pointed at the admin hub path.\",\"auth\":{\"type\":\"header\",\"headers\":{\"Authorization\":\"Bearer ${ITOPS_IT_TOKEN}\"}}}}")"
neg="$(curl -sS --max-time 60 "${API}/mcp-servers/itops-admin-negative/tools" 2>/dev/null)"
if echo "$neg" | grep -q '403\|forbidden'; then
  pass "TrueForge surfaces the hub's 403 for the IT token on the admin path"
else
  fail "TrueForge did not surface a 403 on the admin path" "$(echo "$neg" | head -c 160)"
fi

# --------------------------------------------------- oauth (dcr) through the harness
if [ "${ITOPS_RUN_FLOW:-0}" != "1" ]; then
  skip "itops OAuth connector through TrueForge" "set ITOPS_RUN_FLOW=1 against a sandbox you own"
else
  OAUTH_NAME="${ITOPS_OAUTH_SERVER_NAME:-itops-it-oauth}"
  code="$(put_server "{\"manifest\":{\"type\":\"remote\",\"name\":\"${OAUTH_NAME}\",\"url\":\"${IT_URL}\",\"description\":\"IT operations hub via OAuth DCR (PoC direct OAuth connector).\",\"auth\":{\"type\":\"dcr\"}}}")"
  [ "$code" = "200" ] || [ "$code" = "201" ] && pass "itops OAuth connector registered (HTTP $code)" \
    || fail "itops OAuth connector registration -> HTTP $code"

  auth="$(curl -sS --max-time 30 "${API}/mcp-servers/${OAUTH_NAME}/authorize?return_to=/" 2>/dev/null)"
  URL="$(echo "$auth" | jq -r '.authorization_url // empty')"
  if [ -z "$URL" ] && [ "$(echo "$auth" | jq -r '.status // empty')" = "authenticated" ]; then
    # A connector that already holds a token issues no new authorize URL. Re-run
    # the consent leg from scratch with ITOPS_OAUTH_SERVER_NAME=<fresh name>.
    note "${OAUTH_NAME} already holds an OAuth token — consent leg skipped this run"
    n="$(tool_count "$OAUTH_NAME")"
    [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null \
      && pass "TrueForge listed ${n} tools from itops IT over the existing OAuth connector" \
      || fail "TrueForge could not list itops IT tools over the OAuth connector"
  elif [ -z "$URL" ]; then
    fail "TrueForge returned no authorization_url" "$(echo "$auth" | head -c 200)"
  else
    pass "TrueForge ran DCR against the hub and built an authorize URL"
    note "TrueForge authorize params: $(printf '%s' "$URL" | grep -o 'code_challenge_method=[^&]*') redirect_uri=$(printf '%s' "$URL" | sed -n 's/.*redirect_uri=\([^&]*\).*/\1/p' | python3 -c 'import sys,urllib.parse;print(urllib.parse.unquote(sys.stdin.read().strip()))')"

    param() { printf '%s' "$URL" | sed -n "s/.*[?&]$1=\([^&]*\).*/\1/p"; }
    urldec() { python3 -c 'import sys,urllib.parse;print(urllib.parse.unquote(sys.argv[1]))' "$1"; }

    loc="$(curl -sS --max-time 30 -o /dev/null -D - -X POST "${ITOPS_BASE_URL}/authorize" \
      --data-urlencode "client_id=$(param client_id)" \
      --data-urlencode "redirect_uri=$(urldec "$(param redirect_uri)")" \
      --data-urlencode "state=$(param state)" \
      --data-urlencode "code_challenge=$(param code_challenge)" \
      --data-urlencode "code_challenge_method=S256" \
      --data-urlencode "resource=$(urldec "$(param resource)")" \
      --data-urlencode "scope=mcp:it" \
      --data-urlencode "token=${ITOPS_IT_TOKEN}" 2>/dev/null | tr -d '\r' | sed -n 's/^[Ll]ocation: //p' | head -1)"
    if [ -z "$loc" ]; then
      fail "hub consent step returned no redirect"
    else
      pass "hub consent step redirected back to the TrueForge callback"
      cb="$(curl -sS --max-time 30 -o /dev/null -w '%{redirect_url}' "$loc" 2>/dev/null)"
      case "$cb" in
        *isSuccess=true*) pass "TrueForge callback completed the token exchange" ;;
        *) fail "TrueForge callback did not report success" "${cb:-no redirect}" ;;
      esac
      n="$(tool_count "$OAUTH_NAME")"
      [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null \
        && pass "TrueForge listed ${n} tools from itops IT over the OAuth connector" \
        || fail "TrueForge could not list itops IT tools over the OAuth connector"
    fi
  fi
fi

echo
echo "Summary: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
[ "$FAIL" -eq 0 ]
