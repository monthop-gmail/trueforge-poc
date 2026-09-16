#!/usr/bin/env bash
# OAuth compatibility probe for the Dual MCP PoC.
#
# Part 1 runs against any MCP base URL and only reads discovery documents.
# Part 2 runs the full authorization-code + PKCE + refresh flow, and is opt-in
# (ITOPS_RUN_FLOW=1) because it registers a client on the target deployment —
# only point it at a sandbox you own.
#
# Prints no token values. Tokens are compared by SHA-256 prefix so the report can
# say "same secret" without carrying the secret.
set -uo pipefail

PASS=0
FAIL=0
SKIP=0
pass() { echo "PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL  $1${2:+ -- $2}"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP  $1${2:+ -- $2}"; SKIP=$((SKIP + 1)); }
note() { echo "NOTE  $1"; }

fingerprint() { printf '%s' "$1" | sha256sum | cut -c1-12; }

# RFC 7636 S256: base64url(SHA256(verifier)), unpadded.
pkce_challenge() { printf '%s' "$1" | openssl dgst -binary -sha256 | openssl base64 -A | tr '+/' '-_' | tr -d '='; }

discovery() {
  local label="$1" origin="$2" resource_path="$3" mcp_path="$4"
  echo "-- ${label}: ${origin}"

  local as_body code
  as_body="$(curl -sS --max-time 15 "${origin}/.well-known/oauth-authorization-server" 2>/dev/null)"
  if echo "$as_body" | jq -e '.authorization_endpoint and .token_endpoint' >/dev/null 2>&1; then
    pass "${label} authorization-server metadata"
    note "${label} $(echo "$as_body" | jq -c '{registration_endpoint,grant_types_supported,code_challenge_methods_supported,token_endpoint_auth_methods_supported}')"
  else
    fail "${label} authorization-server metadata" "$(echo "$as_body" | head -c 160)"
  fi

  code="$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' "${origin}${resource_path}" 2>/dev/null)"
  [ "$code" = "200" ] && pass "${label} protected-resource metadata (200)" \
    || fail "${label} protected-resource metadata -> HTTP $code" "expected 200"

  local challenge
  challenge="$(curl -sS --max-time 15 -o /dev/null -D - -X POST "${origin}${mcp_path}" \
    -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' -d '{}' 2>/dev/null \
    | tr -d '\r' | sed -n 's/^[Ww][Ww][Ww]-[Aa]uthenticate: //p' | head -1)"
  if [ -n "$challenge" ]; then
    pass "${label} unauthenticated MCP call returns a WWW-Authenticate challenge"
    note "${label} challenge: ${challenge}"
  else
    fail "${label} unauthenticated MCP call carries no WWW-Authenticate header"
  fi
}

echo "== DUAL MCP OAUTH PROBE =="
echo "run-at: $(date -Is)"
for cmd in curl jq openssl sha256sum; do
  command -v "$cmd" >/dev/null || { echo "missing required command: $cmd"; exit 1; }
done

# ------------------------------------------------------------ part 1: discovery
if [ -n "${COLLAB_ORIGIN:-}" ]; then
  discovery "collab" "$COLLAB_ORIGIN" "/.well-known/oauth-protected-resource/mcp" "/mcp"
else
  skip "collab discovery: COLLAB_ORIGIN not set"
fi

if [ -n "${ITOPS_BASE_URL:-}" ]; then
  discovery "itops" "$ITOPS_BASE_URL" "/.well-known/oauth-protected-resource/mcp/it/mcp" "/mcp/it/mcp"
else
  skip "itops discovery: ITOPS_BASE_URL not set"
fi

# ------------------------------------------------------ part 2: full code flow
if [ "${ITOPS_RUN_FLOW:-0}" != "1" ] || [ -z "${ITOPS_BASE_URL:-}" ] || [ -z "${ITOPS_IT_TOKEN:-}" ]; then
  skip "itops authorization-code flow" "set ITOPS_RUN_FLOW=1 with a sandbox ITOPS_BASE_URL/ITOPS_IT_TOKEN"
else
  echo "-- itops authorization-code + PKCE flow"
  B="$ITOPS_BASE_URL"
  REDIRECT="${ITOPS_REDIRECT_URI:-http://127.0.0.1:45999/callback}"
  RESOURCE="${B}/mcp/it/mcp"

  reg="$(curl -sS --max-time 15 -X POST "${B}/register" -H 'content-type: application/json' \
    -d "{\"client_name\":\"trueforge-poc-probe\",\"redirect_uris\":[\"${REDIRECT}\"],\"grant_types\":[\"authorization_code\",\"refresh_token\"],\"response_types\":[\"code\"],\"token_endpoint_auth_method\":\"none\"}" 2>/dev/null)"
  CLIENT_ID="$(echo "$reg" | jq -r '.client_id // empty')"
  if [ -n "$CLIENT_ID" ]; then
    pass "itops dynamic client registration (DCR)"
    note "itops registered client_name=$(echo "$reg" | jq -r '.client_name // "-"') auth_method=$(echo "$reg" | jq -r '.token_endpoint_auth_method // "-"')"
  else
    fail "itops dynamic client registration" "$(echo "$reg" | head -c 200)"
  fi

  VERIFIER="$(openssl rand -hex 48)"
  CHALLENGE="$(pkce_challenge "$VERIFIER")"

  # The consent step is a form where an operator pastes the role token. Posting it
  # here is the scripted equivalent of that human step, against our own sandbox.
  location="$(curl -sS --max-time 15 -o /dev/null -D - -X POST "${B}/authorize" \
    --data-urlencode "client_id=${CLIENT_ID}" \
    --data-urlencode "redirect_uri=${REDIRECT}" \
    --data-urlencode "state=poc-state" \
    --data-urlencode "code_challenge=${CHALLENGE}" \
    --data-urlencode "code_challenge_method=S256" \
    --data-urlencode "resource=${RESOURCE}" \
    --data-urlencode "scope=mcp:it" \
    --data-urlencode "token=${ITOPS_IT_TOKEN}" 2>/dev/null | tr -d '\r' | sed -n 's/^[Ll]ocation: //p' | head -1)"
  CODE="$(printf '%s' "$location" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')"
  [ -n "$CODE" ] && pass "itops /authorize granted a code" || fail "itops /authorize granted no code" "location: ${location:-none}"

  tok="$(curl -sS --max-time 15 -X POST "${B}/token" \
    --data-urlencode "grant_type=authorization_code" \
    --data-urlencode "code=${CODE}" \
    --data-urlencode "redirect_uri=${REDIRECT}" \
    --data-urlencode "client_id=${CLIENT_ID}" \
    --data-urlencode "code_verifier=${VERIFIER}" 2>/dev/null)"
  ACCESS="$(echo "$tok" | jq -r '.access_token // empty')"
  REFRESH="$(echo "$tok" | jq -r '.refresh_token // empty')"
  if [ -n "$ACCESS" ]; then
    pass "itops token exchange returned an access_token"
    note "itops token response: $(echo "$tok" | jq -c '{token_type,expires_in,scope,has_refresh:(.refresh_token!=null)}')"
  else
    fail "itops token exchange" "$(echo "$tok" | head -c 200)"
  fi

  # Wrong verifier must not buy a second token for the same code.
  bad="$(curl -sS --max-time 15 -X POST "${B}/token" \
    --data-urlencode "grant_type=authorization_code" \
    --data-urlencode "code=${CODE}" \
    --data-urlencode "redirect_uri=${REDIRECT}" \
    --data-urlencode "client_id=${CLIENT_ID}" \
    --data-urlencode "code_verifier=$(openssl rand -hex 48)" 2>/dev/null)"
  echo "$bad" | jq -e '.access_token' >/dev/null 2>&1 \
    && fail "itops replayed code with a wrong verifier still returned a token" \
    || pass "itops rejects a replayed code / wrong PKCE verifier"

  if [ -n "$ACCESS" ]; then
    if [ "$(fingerprint "$ACCESS")" = "$(fingerprint "$ITOPS_IT_TOKEN")" ]; then
      note "itops OAuth access_token IS the shared IT role token (same sha256 prefix $(fingerprint "$ACCESS")) — per-client revocation is not possible"
    else
      note "itops OAuth access_token differs from the static IT token"
    fi

    code="$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' -X POST "$RESOURCE" \
      -H "Authorization: Bearer ${ACCESS}" -H 'content-type: application/json' \
      -H 'accept: application/json, text/event-stream' \
      -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"trueforge-poc-probe","version":"0.1.0"}}}' 2>/dev/null)"
    [ "$code" = "200" ] && pass "itops OAuth access_token works on the IT MCP endpoint (200)" \
      || fail "itops OAuth access_token on IT endpoint -> HTTP $code" "expected 200"

    code="$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' -X POST "${B}/mcp/admin/mcp" \
      -H "Authorization: Bearer ${ACCESS}" -H 'content-type: application/json' \
      -H 'accept: application/json, text/event-stream' -d '{}' 2>/dev/null)"
    [ "$code" = "403" ] && pass "itops OAuth IT access_token denied at /mcp/admin (403)" \
      || fail "itops OAuth IT access_token at /mcp/admin -> HTTP $code" "expected 403"
  fi

  if [ -n "$REFRESH" ]; then
    ref="$(curl -sS --max-time 15 -X POST "${B}/token" \
      --data-urlencode "grant_type=refresh_token" \
      --data-urlencode "refresh_token=${REFRESH}" \
      --data-urlencode "client_id=${CLIENT_ID}" 2>/dev/null)"
    echo "$ref" | jq -e '.access_token' >/dev/null 2>&1 \
      && pass "itops refresh_token grant returned a new access_token" \
      || fail "itops refresh_token grant" "$(echo "$ref" | head -c 200)"
  else
    skip "itops refresh_token grant" "no refresh_token issued"
  fi
fi

echo
echo "Summary: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
[ "$FAIL" -eq 0 ]
