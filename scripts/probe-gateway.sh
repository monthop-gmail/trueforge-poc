#!/usr/bin/env bash
# Topology-B probe: both MCP servers reached through the TrueFoundry AI Gateway.
#
# Inbound to the gateway is a TrueFoundry PAT; outbound to each server is the
# credential stored on that gateway connector. This script only reads — it does
# not create or change connectors.
#
# What it cannot prove, by design: gateway *authorization*. Every call here is
# made by one principal that is allowed everywhere, so a refusal for an
# unauthorized principal is untested. See docs/poc/dual-mcp-results.md.
set -uo pipefail

PASS=0
FAIL=0
SKIP=0
pass() { echo "PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL  $1${2:+ -- $2}"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP  $1${2:+ -- $2}"; SKIP=$((SKIP + 1)); }
note() { echo "NOTE  $1"; }

GATEWAY="${TFY_GATEWAY_BASE:-https://gateway.truefoundry.ai}"
TENANT="${TFY_TENANT:-}"
PAT="${TRUEFOUNDRY_API_KEY:-}"

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"trueforge-poc-gateway","version":"0.1.0"}}}'

server_url() { echo "${GATEWAY}/${TENANT}/mcp/$1/server"; }

mcp_post() {
  local url="$1" token="$2" body="$3" session="${4:-}"
  curl -sS --max-time 60 -X POST "$url" \
    ${token:+-H "Authorization: Bearer ${token}"} \
    -H 'content-type: application/json' \
    -H 'accept: application/json, text/event-stream' \
    ${session:+-H "mcp-session-id: ${session}"} \
    -d "$body" 2>/dev/null | sed -n 's/^data: //p' | head -1
}

http_code() {
  curl -sS --max-time 60 -o /dev/null -w '%{http_code}' -X POST "$1" \
    ${2:+-H "Authorization: Bearer ${2}"} \
    -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
    -d "$INIT" 2>/dev/null
}

session_id() {
  curl -sS --max-time 60 -o /dev/null -D - -X POST "$1" \
    -H "Authorization: Bearer ${PAT}" -H 'content-type: application/json' \
    -H 'accept: application/json, text/event-stream' -d "$INIT" 2>/dev/null \
    | tr -d '\r' | sed -n 's/^[Mm]cp-[Ss]ession-[Ii]d: //p' | head -1
}

# name, read tool, optional jq filter applied to the read result for a NOTE line
check_server() {
  local name="$1" read_tool="$2" note_filter="${3:-}"
  local url session tools count
  url="$(server_url "$name")"
  echo "-- ${name}"

  local code
  code="$(http_code "$url" "$PAT")"
  [ "$code" = "200" ] && pass "${name}: initialize through the gateway (200)" \
    || { fail "${name}: initialize -> HTTP $code" "expected 200"; return; }

  session="$(session_id "$url")"
  mcp_post "$url" "$PAT" '{"jsonrpc":"2.0","method":"notifications/initialized"}' "$session" >/dev/null
  tools="$(mcp_post "$url" "$PAT" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' "$session")"
  count="$(echo "$tools" | jq -r '.result.tools | length' 2>/dev/null)"
  if [ -n "$count" ] && [ "$count" -gt 0 ] 2>/dev/null; then
    pass "${name}: tools/list through the gateway (${count} tools)"
  else
    fail "${name}: tools/list through the gateway" "$(echo "$tools" | head -c 160)"
    return
  fi

  # A hub that hands an agent a shell is the one thing this PoC must never wave through.
  local privileged
  privileged="$(echo "$tools" | jq -r '[.result.tools[].name] | map(select(test("run_shell|exec|command"))) | join(",")' 2>/dev/null)"
  [ -z "$privileged" ] && pass "${name}: tool list exposes no privileged shell tool" \
    || fail "${name}: tool list exposes a privileged execution tool" "$privileged"

  local result
  result="$(mcp_post "$url" "$PAT" "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"${read_tool}\",\"arguments\":{}}}" "$session")"
  if echo "$result" | jq -e '.result' >/dev/null 2>&1; then
    pass "${name}: read tool call through the gateway (${read_tool})"
    [ -n "$note_filter" ] && note "${name}: $(echo "$result" | jq -r '.result.content[0].text' | jq -r "$note_filter" 2>/dev/null)"
  else
    fail "${name}: read tool call (${read_tool})" "$(echo "$result" | head -c 160)"
  fi

  # Inbound auth is the gateway's own boundary, separate from anything upstream does.
  code="$(http_code "$url" "")"
  [ "$code" = "401" ] && pass "${name}: gateway rejects a missing PAT (401)" \
    || fail "${name}: missing PAT -> HTTP $code" "expected 401"
  code="$(http_code "$url" "tfy_pat_not_a_real_token")"
  [ "$code" = "401" ] && pass "${name}: gateway rejects a wrong PAT (401)" \
    || fail "${name}: wrong PAT -> HTTP $code" "expected 401"
}

echo "== TRUEFOUNDRY GATEWAY PROBE =="
echo "run-at: $(date -Is)"
for cmd in curl jq; do
  command -v "$cmd" >/dev/null || { echo "missing required command: $cmd"; exit 1; }
done

if [ -z "$TENANT" ] || [ -z "$PAT" ]; then
  skip "gateway probe" "set TFY_TENANT and TRUEFOUNDRY_API_KEY"
else
  echo "gateway: ${GATEWAY}/${TENANT}"
  check_server "${TFY_COLLAB_SERVER:-ai-collaboration-mcp}" get_workspace_context '.you_are | "identity seen upstream: " + .'
  if [ -n "${TFY_ITOPS_SERVER:-}" ]; then
    check_server "$TFY_ITOPS_SERVER" rag_get_status '"rag backend=" + .backend + " sample=" + (.sample|tostring)'
  else
    skip "IT Ops connector" "set TFY_ITOPS_SERVER to the connector name in your tenant"
  fi
fi

echo
echo "Summary: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
[ "$FAIL" -eq 0 ]
