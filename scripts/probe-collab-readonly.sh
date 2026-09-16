#!/usr/bin/env bash
# Read-only route acceptance for ai-collaboration-mcp.
#
# Runs against any base URL that serves the prototype — the local Worker during
# development, a throwaway test deployment later. It never writes to the normal
# route unless COLLAB_ALLOW_WRITE_PROBE=1, so pointing it at a deployment that
# shares a workspace with anything real stays safe by default.
#
# Prints no token values.
set -uo pipefail

PASS=0
FAIL=0
SKIP=0
pass() { echo "PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL  $1${2:+ -- $2}"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP  $1${2:+ -- $2}"; SKIP=$((SKIP + 1)); }

BASE="${COLLAB_BASE:-}"
RO="${COLLAB_RO_TOKEN:-}"
RW="${COLLAB_RW_TOKEN:-}"

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"collab-readonly-probe","version":"0.1.0"}}}'

WRITE_TOOLS=(post_message create_task record_decision create_handoff create_discussion update_task accept_handoff record_plan resolve_decision)

http_code() {
  curl -sS --max-time 30 -o /dev/null -w '%{http_code}' -X POST "$1" \
    ${2:+-H "Authorization: Bearer $2"} \
    -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
    -d "$INIT" 2>/dev/null
}

# Responses arrive as SSE frames on the MCP routes and as plain JSON on errors.
mcp() {
  curl -sS --max-time 30 -X POST "$1" -H "Authorization: Bearer $2" \
    -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
    -d "$3" 2>/dev/null | sed -n 's/^data: //p' | head -1
}

echo "== COLLAB READ-ONLY ROUTE ACCEPTANCE =="
echo "run-at: $(date -Is)"
for cmd in curl jq; do command -v "$cmd" >/dev/null || { echo "missing required command: $cmd"; exit 1; }; done

if [ -z "$BASE" ] || [ -z "$RO" ] || [ -z "$RW" ]; then
  echo "set COLLAB_BASE, COLLAB_RO_TOKEN and COLLAB_RW_TOKEN"
  exit 1
fi
echo "base: ${BASE}"

# --------------------------------------------------------- route × credential
code="$(http_code "${BASE}/mcp-readonly" "$RO")"
[ "$code" = "200" ] && pass "read-only token on the read-only route (200)" || fail "read-only token on read-only route -> $code"
code="$(http_code "${BASE}/mcp" "$RO")"
[ "$code" = "401" ] && pass "read-only token refused on the normal route (401)" || fail "read-only token on normal route -> $code" "expected 401"
code="$(http_code "${BASE}/mcp" "$RW")"
[ "$code" = "200" ] && pass "normal token on the normal route (200)" || fail "normal token on normal route -> $code"
code="$(http_code "${BASE}/mcp-readonly" "$RW")"
[ "$code" = "401" ] && pass "normal token refused on the read-only route (401)" || fail "normal token on read-only route -> $code" "expected 401"
code="$(http_code "${BASE}/mcp-readonly" "")"
[ "$code" = "401" ] && pass "no credential refused (401)" || fail "no credential -> $code" "expected 401"
code="$(http_code "${BASE}/mcp-readonly" "not-a-real-token")"
[ "$code" = "401" ] && pass "wrong credential refused (401)" || fail "wrong credential -> $code" "expected 401"

# The read-only route is not wired to the OAuth provider; a bad credential must
# be answered here, not handed to the flow that belongs to the writable route.
body="$(curl -sS --max-time 30 -X POST "${BASE}/mcp-readonly" -H 'Authorization: Bearer not-a-real-token' \
  -H 'content-type: application/json' -d "$INIT" 2>/dev/null)"
echo "$body" | grep -q 'MCP_READONLY_TOKENS' \
  && pass "read-only route answers 401 itself instead of falling through to OAuth" \
  || fail "read-only 401 body does not look like the route's own" "$(echo "$body" | head -c 120)"

# ----------------------------------------------------------------- discovery
ro_tools="$(mcp "${BASE}/mcp-readonly" "$RO" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')"
rw_tools="$(mcp "${BASE}/mcp" "$RW" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')"
ro_names="$(echo "$ro_tools" | jq -r '[.result.tools[].name] | join(" ")' 2>/dev/null)"
rw_count="$(echo "$rw_tools" | jq -r '.result.tools | length' 2>/dev/null)"
ro_count="$(echo "$ro_tools" | jq -r '.result.tools | length' 2>/dev/null)"

if [ -n "$ro_count" ] && [ "$ro_count" -gt 0 ] 2>/dev/null; then
  pass "read-only route lists ${ro_count} tools (normal route lists ${rw_count})"
else
  fail "read-only tools/list" "$(echo "$ro_tools" | head -c 160)"
fi

leaked=""
for tool in "${WRITE_TOOLS[@]}"; do
  case " $ro_names " in *" $tool "*) leaked="${leaked} ${tool}";; esac
done
[ -z "$leaked" ] && pass "no write tool appears in the read-only tool list" \
  || fail "write tools visible on the read-only route" "$leaked"

# --------------------------------------------------------------- enforcement
# Hiding a tool is not enforcement. Every write tool is called by name, with
# arguments that would be valid, and must still be refused.
declare -A ARGS=(
  [post_message]='{"discussion_id":"dis-probe","body":"probe"}'
  [create_task]='{"title":"probe","detail":"probe"}'
  [record_decision]='{"title":"probe","detail":"probe"}'
  [create_handoff]='{"task_id":"task-probe","to":"probe","context":"probe"}'
  [create_discussion]='{"title":"probe"}'
  [update_task]='{"task_id":"task-probe","status":"done"}'
  [accept_handoff]='{"handoff_id":"ho-probe"}'
  [record_plan]='{"title":"probe","body":"probe"}'
  [resolve_decision]='{"decision_id":"dec-probe","status":"approved"}'
)
denied=0
for tool in "${WRITE_TOOLS[@]}"; do
  result="$(mcp "${BASE}/mcp-readonly" "$RO" \
    "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"${tool}\",\"arguments\":${ARGS[$tool]}}}")"
  if echo "$result" | grep -q 'disabled'; then
    denied=$((denied + 1))
  else
    fail "write tool ${tool} was not refused on the read-only route" "$(echo "$result" | head -c 120)"
  fi
done
[ "$denied" -eq "${#WRITE_TOOLS[@]}" ] && pass "all ${denied} write tools refused by name on a direct tools/call"

for tool in get_workspace_context get_tasks; do
  result="$(mcp "${BASE}/mcp-readonly" "$RO" \
    "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"${tool}\",\"arguments\":{\"limit\":1}}}")"
  echo "$result" | jq -e '.result' >/dev/null 2>&1 && pass "read tool ${tool} still works" \
    || fail "read tool ${tool}" "$(echo "$result" | head -c 120)"
done

# ------------------------------------------------------------------- bypass
for path in "/mcp-readonly/../mcp" "/mcp-readonly/%2e%2e/mcp" "//mcp" "/MCP" "/mcp/" "/mcp%20" "/mcp-readonly-extra"; do
  code="$(http_code "${BASE}${path}" "$RO")"
  case "$code" in
    200) fail "read-only credential reached ${path} (200)" ;;
    *) pass "read-only credential cannot reach ${path} (${code})" ;;
  esac
done

# ------------------------------------------------- handler cache isolation
# Touch the writable route first: if the handler cache key omits the route, the
# next read-only request gets the writable server and the tool list leaks.
http_code "${BASE}/mcp" "$RW" >/dev/null
after="$(mcp "${BASE}/mcp-readonly" "$RO" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | jq -r '[.result.tools[].name] | join(" ")' 2>/dev/null)"
case " $after " in
  *" post_message "*) fail "read-only tool list leaked write tools after the normal route was used" ;;
  *) pass "read-only tool list stays read-only after the normal route was used" ;;
esac

# ---------------------------------------------------------- optional write
if [ "${COLLAB_ALLOW_WRITE_PROBE:-0}" = "1" ]; then
  result="$(mcp "${BASE}/mcp" "$RW" '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"create_discussion","arguments":{"title":"read-only route acceptance probe"}}}')"
  echo "$result" | jq -e '.result' >/dev/null 2>&1 && pass "normal route still writes (regression)" \
    || fail "normal route write" "$(echo "$result" | head -c 160)"
else
  skip "normal-route write regression" "set COLLAB_ALLOW_WRITE_PROBE=1 against a throwaway workspace"
fi

echo
echo "Summary: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
[ "$FAIL" -eq 0 ]
