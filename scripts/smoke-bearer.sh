#!/usr/bin/env bash
# Direct-Bearer baseline for the Dual MCP PoC (topology A, no gateway).
#
# Proves, against whatever deployment the env points at:
#   - Streamable HTTP initialize + tools/list + one read tool call, per server
#   - unauthenticated and wrong-token requests are rejected
#   - the IT token cannot reach /mcp/admin or /mcp/accounting
#   - the IT tool list exposes no privileged shell tool
#
# Reads config from the environment (see .env.example). Prints no token values.
set -uo pipefail

PASS=0
FAIL=0
SKIP=0
MCP_CLIENT_NAME=""

pass() { echo "PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL  $1${2:+ -- $2}"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP  $1${2:+ -- $2}"; SKIP=$((SKIP + 1)); }

# Streamable HTTP responses come back as SSE frames; the JSON payload is the
# first `data:` line. Keeping this in one place means every call site can treat
# a tool call as "give me JSON".
mcp_call() {
  local url="$1" token="$2" body="$3" session="${4:-}"
  curl -sS --max-time 20 -X POST "$url" \
    -H "Authorization: Bearer ${token}" \
    -H 'content-type: application/json' \
    -H 'accept: application/json, text/event-stream' \
    ${MCP_CLIENT_NAME:+-H "X-Client-Name: ${MCP_CLIENT_NAME}"} \
    ${session:+-H "mcp-session-id: ${session}"} \
    -d "$body" 2>/dev/null | sed -n 's/^data: //p' | head -1
}

mcp_session_id() {
  local url="$1" token="$2"
  curl -sS --max-time 20 -o /dev/null -D - -X POST "$url" \
    -H "Authorization: Bearer ${token}" \
    -H 'content-type: application/json' \
    ${MCP_CLIENT_NAME:+-H "X-Client-Name: ${MCP_CLIENT_NAME}"} \
    -H 'accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"trueforge-poc-smoke","version":"0.1.0"}}}' \
    2>/dev/null | tr -d '\r' | sed -n 's/^[Mm]cp-[Ss]ession-[Ii]d: //p' | head -1
}

http_code() {
  local url="$1" token="$2"
  curl -sS --max-time 20 -o /dev/null -w '%{http_code}' -X POST "$url" \
    ${token:+-H "Authorization: Bearer ${token}"} \
    ${MCP_CLIENT_NAME:+-H "X-Client-Name: ${MCP_CLIENT_NAME}"} \
    -H 'content-type: application/json' \
    -H 'accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"trueforge-poc-smoke","version":"0.1.0"}}}' \
    2>/dev/null
}

# initialize -> notifications/initialized -> tools/list, returning the tool names.
list_tools() {
  local url="$1" token="$2" out_names="$3"
  local session tools
  # Stateless servers (Cloudflare Worker collab) return no mcp-session-id and
  # accept every request on its own; session-bound servers (Nginx + hub) require
  # the header. An empty session id here means the former, not a failure.
  session="$(mcp_session_id "$url" "$token")"
  mcp_call "$url" "$token" '{"jsonrpc":"2.0","method":"notifications/initialized"}' "$session" >/dev/null
  tools="$(mcp_call "$url" "$token" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' "$session")"
  [ -n "$tools" ] || return 1
  echo "$tools" | jq -r '.result.tools[]?.name' > "$out_names"
  echo "$session"
}

echo "== DUAL MCP DIRECT-BEARER SMOKE =="
echo "run-at: $(date -Is)"

for cmd in curl jq; do
  command -v "$cmd" >/dev/null || { echo "missing required command: $cmd"; exit 1; }
done

# ---------------------------------------------------------------- collaboration
if [ -z "${COLLAB_MCP_URL:-}" ] || [ -z "${COLLAB_TOKEN:-}" ]; then
  skip "collaboration: COLLAB_MCP_URL / COLLAB_TOKEN not set"
else
  echo "-- collaboration: ${COLLAB_MCP_URL}"
  MCP_CLIENT_NAME="${COLLAB_CLIENT_NAME:-}"
  code="$(http_code "$COLLAB_MCP_URL" "")"
  [ "$code" = "401" ] && pass "collab rejects missing token (401)" || fail "collab missing token -> HTTP $code" "expected 401"

  code="$(http_code "$COLLAB_MCP_URL" "invalid-token-for-negative-test")"
  [ "$code" = "401" ] && pass "collab rejects wrong token (401)" || fail "collab wrong token -> HTTP $code" "expected 401"

  names="$(mktemp)"
  if session="$(list_tools "$COLLAB_MCP_URL" "$COLLAB_TOKEN" "$names")" && [ -s "$names" ]; then
    pass "collab initialize + tools/list ($(wc -l < "$names") tools)"
    if grep -qx 'get_workspace_context' "$names"; then
      pass "collab exposes get_workspace_context"
      read_result="$(mcp_call "$COLLAB_MCP_URL" "$COLLAB_TOKEN" \
        '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_workspace_context","arguments":{"limit":1}}}' "$session")"
      you_are="$(echo "$read_result" | jq -r '.result.content[0].text' 2>/dev/null | jq -r '.you_are' 2>/dev/null)"
      if [ -n "$you_are" ] && [ "$you_are" != "null" ]; then
        pass "collab read tool call returned identity: you_are=${you_are}"
        [ -n "${COLLAB_EXPECT_IDENTITY:-}" ] && {
          [ "$you_are" = "$COLLAB_EXPECT_IDENTITY" ] \
            && pass "collab identity matches expected team identity" \
            || fail "collab identity is ${you_are}" "expected ${COLLAB_EXPECT_IDENTITY}"
        }
      else
        fail "collab read tool call returned no identity" "$(echo "$read_result" | head -c 200)"
      fi
    else
      fail "collab tool list has no get_workspace_context"
    fi
  else
    fail "collab initialize + tools/list"
  fi
  rm -f "$names"

  # Read-only probe of what actually decides the caller's identity. Opt-in because
  # it is a finding, not a health check. It never claims an existing participant's
  # name — see finding 1 in docs/poc/dual-mcp-results.md.
  if [ "${COLLAB_IDENTITY_PROBE:-0}" = "1" ]; then
    identity_for() {
      MCP_CLIENT_NAME="$1" mcp_call "$COLLAB_MCP_URL" "$COLLAB_TOKEN" \
        '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_workspace_context","arguments":{"limit":1}}}' \
        | jq -r '.result.content[0].text' 2>/dev/null | jq -r '.you_are' 2>/dev/null
    }
    declared="$(identity_for "${COLLAB_CLIENT_NAME:-monthop-gmail/trueforge}")"
    omitted="$(identity_for "")"
    invented="$(identity_for "poc-identity-probe")"
    echo "NOTE  collab identity with declared name: ${declared}"
    echo "NOTE  collab identity with no name header: ${omitted}"
    echo "NOTE  collab identity with an invented name: ${invented}"
    if [ "$invented" = "poc-identity-probe" ]; then
      echo "NOTE  collab identity is client-asserted: one token can present any name"
    else
      echo "NOTE  collab identity did not follow the client-sent name"
    fi
  fi
fi

# ------------------------------------------------------------------- it ops hub
if [ -z "${ITOPS_BASE_URL:-}" ] || [ -z "${ITOPS_IT_TOKEN:-}" ]; then
  skip "itops: ITOPS_BASE_URL / ITOPS_IT_TOKEN not set"
else
  echo "-- itops: ${ITOPS_BASE_URL}"
  MCP_CLIENT_NAME=""
  code="$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' "${ITOPS_BASE_URL}/healthz" 2>/dev/null)"
  [ "$code" = "200" ] && pass "itops /healthz 200" || fail "itops /healthz -> HTTP $code" "expected 200"

  it_url="${ITOPS_BASE_URL}/mcp/it/mcp"
  code="$(http_code "$it_url" "")"
  [ "$code" = "401" ] && pass "itops IT path rejects missing token (401)" || fail "itops missing token -> HTTP $code" "expected 401"

  code="$(http_code "$it_url" "invalid-token-for-negative-test")"
  [ "$code" = "401" ] && pass "itops IT path rejects wrong token (401)" || fail "itops wrong token -> HTTP $code" "expected 401"

  # The IT token must not be able to cross into the other two roles. This is the
  # Nginx enforcement point, so it answers before any hub is reached.
  for role in admin accounting; do
    code="$(http_code "${ITOPS_BASE_URL}/mcp/${role}/mcp" "$ITOPS_IT_TOKEN")"
    [ "$code" = "403" ] && pass "itops IT token denied at /mcp/${role} (403)" \
      || fail "itops IT token at /mcp/${role} -> HTTP $code" "expected 403"
  done

  names="$(mktemp)"
  if session="$(list_tools "$it_url" "$ITOPS_IT_TOKEN" "$names")" && [ -s "$names" ]; then
    pass "itops IT initialize + tools/list ($(wc -l < "$names") tools)"
    if grep -qiE 'run_shell|exec|command' "$names"; then
      fail "itops IT tool list exposes a privileged execution tool" "$(grep -iE 'run_shell|exec|command' "$names" | tr '\n' ' ')"
    else
      pass "itops IT tool list exposes no privileged shell tool"
    fi
    read_tool="$(head -1 "$names")"
    if [ -n "${ITOPS_READ_TOOL:-}" ]; then read_tool="$ITOPS_READ_TOOL"; fi
    read_result="$(mcp_call "$it_url" "$ITOPS_IT_TOKEN" \
      "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"${read_tool}\",\"arguments\":{}}}" "$session")"
    if echo "$read_result" | jq -e '.result' >/dev/null 2>&1; then
      pass "itops IT read tool call succeeded: ${read_tool}"
    else
      fail "itops IT read tool call failed: ${read_tool}" "$(echo "$read_result" | head -c 200)"
    fi
  else
    fail "itops IT initialize + tools/list"
  fi
  rm -f "$names"
fi

echo
echo "Summary: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
[ "$FAIL" -eq 0 ]
