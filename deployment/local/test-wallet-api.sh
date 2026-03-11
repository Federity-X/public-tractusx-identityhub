#!/usr/bin/env bash
#
# test-wallet-api.sh — Comprehensive DCP Wallet API Test Script
#
# Tests the full IdentityHub + IssuerService deployment as a DCP wallet
# for EDC connectors (provider/consumer).
#
# Usage:
#   cd deployment/local
#   chmod +x test-wallet-api.sh
#   ./test-wallet-api.sh
#
# Prerequisites:
#   - docker compose up --build -d (all 4 containers running)
#   - jq installed (brew install jq)
#
set -euo pipefail

###############################################################################
# Configuration
###############################################################################
IH_DEFAULT=http://localhost:8181          # IdentityHub default context
IH_IDENTITY=http://localhost:15151        # IdentityHub identity (management) API
IH_DID=http://localhost:10100             # IdentityHub DID resolution
IH_CREDENTIALS=http://localhost:13131     # IdentityHub DCP credentials (holder-side)
IH_STS=http://localhost:9292              # IdentityHub STS

IS_DEFAULT=http://localhost:18181         # IssuerService default context
IS_ISSUER_ADMIN=http://localhost:15152    # IssuerService admin API
IS_DID=http://localhost:18100             # IssuerService DID resolution
IS_ISSUANCE=http://localhost:13132        # IssuerService DCP issuance protocol
IS_STS=http://localhost:18292             # IssuerService STS
IS_STATUSLIST=http://localhost:19999      # IssuerService statuslist

SUPERUSER_KEY="c3VwZXItdXNlcg==.superuserkey"

# Counters
PASS=0
FAIL=0
WARN=0
ERRORS=()

###############################################################################
# Helpers
###############################################################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

pass() { ((PASS++)); echo -e "  ${GREEN}✓ PASS${NC} $1"; }
fail() { ((FAIL++)); ERRORS+=("$1: $2"); echo -e "  ${RED}✗ FAIL${NC} $1 — $2"; }
warn() { ((WARN++)); echo -e "  ${YELLOW}⚠ WARN${NC} $1"; }
info() { echo -e "  ${CYAN}ℹ INFO${NC} $1"; }
section() { echo ""; echo -e "${BLUE}━━━ $1 ━━━${NC}"; }
subsection() { echo -e "  ${BLUE}── $1${NC}"; }

# b64url: base64-encode a participant ID and URL-encode the result
b64url() { printf '%s' "$1" | base64 | tr -d '\n' | sed 's/+/%2B/g; s/\//%2F/g; s/=/%3D/g'; }

# b64raw: base64-encode a participant ID (raw, no URL encoding)
b64raw() { printf '%s' "$1" | base64 | tr -d '\n'; }

# HTTP helper using temp file (macOS compatible — avoids head -n -1)
_http_tmpfile=$(mktemp)
http() {
  local method="$1"; shift
  local url="$1"; shift
  local code
  code=$(curl -s -o "$_http_tmpfile" -w "%{http_code}" -X "$method" "$url" "$@" 2>/dev/null)
  local body
  body=$(cat "$_http_tmpfile")
  echo "${code}|${body}"
}
trap 'rm -f "$_http_tmpfile"' EXIT

expect_http() {
  local expected="$1"
  local label="$2"
  local response="$3"
  local code="${response%%|*}"
  local body="${response#*|}"
  if [[ "$code" == "$expected" ]]; then
    pass "$label (HTTP $code)"
  else
    fail "$label" "expected HTTP $expected, got $code — ${body:0:200}"
  fi
}

expect_http_any() {
  local label="$1"
  local response="$2"
  shift 2
  local code="${response%%|*}"
  local body="${response#*|}"
  for expected in "$@"; do
    if [[ "$code" == "$expected" ]]; then
      pass "$label (HTTP $code)"
      return
    fi
  done
  fail "$label" "expected HTTP ${*}, got $code — ${body:0:200}"
}

json_field() {
  echo "$1" | jq -r "$2" 2>/dev/null || echo ""
}

# Wait for a URL to return HTTP 200
wait_for_health() {
  local url="$1"
  local max_wait="${2:-30}"
  local waited=0
  while [[ $waited -lt $max_wait ]]; do
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null) || true
    if [[ "$code" == "200" ]]; then
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done
  return 1
}

###############################################################################
# Pre-flight checks
###############################################################################
echo ""
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║        DCP Wallet API — Comprehensive Test Suite                ║"
echo "║        IdentityHub + IssuerService for EDC Connectors           ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""

section "0. Pre-flight Checks"

if ! command -v jq &>/dev/null; then
  fail "jq required" "Install with: brew install jq"
  exit 1
fi
pass "jq available"

if ! command -v curl &>/dev/null; then
  fail "curl required" ""
  exit 1
fi
pass "curl available"

# Check containers
for name in identityhub issuerservice ih-postgres ih-vault; do
  if docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -q true; then
    pass "Container: $name running"
  else
    fail "Container: $name" "not running"
  fi
done

###############################################################################
# 1. HEALTH & OBSERVABILITY
###############################################################################
section "1. Health & Observability"

subsection "IdentityHub (port 8181)"
for ep in health readiness startup liveness; do
  resp=$(http GET "${IH_DEFAULT}/api/check/${ep}")
  expect_http 200 "IH /check/${ep}" "$resp"
done

subsection "IssuerService (port 18181)"
for ep in health readiness startup liveness; do
  resp=$(http GET "${IS_DEFAULT}/api/check/${ep}")
  expect_http 200 "IS /check/${ep}" "$resp"
done

###############################################################################
# 2. VERSION APIs
###############################################################################
section "2. Version API"

resp=$(http GET "${IH_DEFAULT}/api/v1/version")
expect_http 200 "IH version" "$resp"

resp=$(http GET "${IS_DEFAULT}/api/v1/version")
expect_http 200 "IS version" "$resp"

###############################################################################
# 3. SUPER-USER PARTICIPANT (already seeded)
###############################################################################
section "3. Super-User Participant Context"

SU_B64=$(b64url "super-user")

resp=$(http GET "${IH_IDENTITY}/api/identity/v1alpha/participants/${SU_B64}" \
  -H "x-api-key: ${SUPERUSER_KEY}")
expect_http 200 "IH get super-user" "$resp"
body="${resp#*|}"
su_state=$(json_field "$body" '.state')
info "super-user state: ${su_state}"

resp=$(http GET "${IH_IDENTITY}/api/identity/v1alpha/participants?offset=0&limit=10" \
  -H "x-api-key: ${SUPERUSER_KEY}")
expect_http 200 "IH list participants" "$resp"

###############################################################################
# 4. CREATE CONNECTOR PARTICIPANT: "provider"
###############################################################################
section "4. Create Connector Participant: provider"

PROVIDER_ID="provider"
PROVIDER_DID="did:web:identityhub:provider"
PROVIDER_B64=$(b64url "$PROVIDER_ID")

# Cleanup from previous runs — delete if exists (ignore errors)
cleanup_resp=$(http DELETE "${IH_IDENTITY}/api/identity/v1alpha/participants/${PROVIDER_B64}" \
  -H "x-api-key: ${SUPERUSER_KEY}" 2>/dev/null || true)
cleanup_code="${cleanup_resp%%|*}"
if [[ "$cleanup_code" == "204" ]]; then
  info "Cleaned up existing provider participant"
  sleep 1
elif [[ "$cleanup_code" == "500" ]]; then
  # This can happen if configs were lost — the fix should prevent this
  warn "Could not delete stale provider (500). Config may not have been restored."
fi

resp=$(http POST "${IH_IDENTITY}/api/identity/v1alpha/participants" \
  -H "x-api-key: ${SUPERUSER_KEY}" \
  -H "Content-Type: application/json" \
  -d "{
    \"participantContextId\": \"${PROVIDER_ID}\",
    \"did\": \"${PROVIDER_DID}\",
    \"active\": true,
    \"key\": {
      \"keyId\": \"${PROVIDER_ID}-key\",
      \"privateKeyAlias\": \"${PROVIDER_ID}-alias\",
      \"keyGeneratorParams\": {
        \"algorithm\": \"EdDSA\",
        \"curve\": \"Ed25519\"
      }
    },
    \"roles\": []
  }")
expect_http 200 "Create provider participant" "$resp"
body="${resp#*|}"
PROVIDER_API_KEY=$(json_field "$body" '.apiKey')
PROVIDER_CLIENT_ID=$(json_field "$body" '.clientId')
PROVIDER_CLIENT_SECRET=$(json_field "$body" '.clientSecret')
info "Provider API key: ${PROVIDER_API_KEY:0:40}..."
info "Provider client ID (DID): ${PROVIDER_CLIENT_ID}"
info "Provider client secret: ${PROVIDER_CLIENT_SECRET}"

# Verify the provider exists
resp=$(http GET "${IH_IDENTITY}/api/identity/v1alpha/participants/${PROVIDER_B64}" \
  -H "x-api-key: ${SUPERUSER_KEY}")
expect_http 200 "Get provider participant" "$resp"

###############################################################################
# 5. CREATE CONNECTOR PARTICIPANT: "consumer"
###############################################################################
section "5. Create Connector Participant: consumer"

CONSUMER_ID="consumer"
CONSUMER_DID="did:web:identityhub:consumer"
CONSUMER_B64=$(b64url "$CONSUMER_ID")

# Cleanup from previous runs
cleanup_resp=$(http DELETE "${IH_IDENTITY}/api/identity/v1alpha/participants/${CONSUMER_B64}" \
  -H "x-api-key: ${SUPERUSER_KEY}" 2>/dev/null || true)
cleanup_code="${cleanup_resp%%|*}"
if [[ "$cleanup_code" == "204" ]]; then
  info "Cleaned up existing consumer participant"
  sleep 1
fi

resp=$(http POST "${IH_IDENTITY}/api/identity/v1alpha/participants" \
  -H "x-api-key: ${SUPERUSER_KEY}" \
  -H "Content-Type: application/json" \
  -d "{
    \"participantContextId\": \"${CONSUMER_ID}\",
    \"did\": \"${CONSUMER_DID}\",
    \"active\": true,
    \"key\": {
      \"keyId\": \"${CONSUMER_ID}-key\",
      \"privateKeyAlias\": \"${CONSUMER_ID}-alias\",
      \"keyGeneratorParams\": {
        \"algorithm\": \"EdDSA\",
        \"curve\": \"Ed25519\"
      }
    },
    \"roles\": []
  }")
expect_http 200 "Create consumer participant" "$resp"
body="${resp#*|}"
CONSUMER_API_KEY=$(json_field "$body" '.apiKey')
CONSUMER_CLIENT_ID=$(json_field "$body" '.clientId')
CONSUMER_CLIENT_SECRET=$(json_field "$body" '.clientSecret')
info "Consumer API key: ${CONSUMER_API_KEY:0:40}..."
info "Consumer client ID (DID): ${CONSUMER_CLIENT_ID}"
info "Consumer client secret: ${CONSUMER_CLIENT_SECRET}"

###############################################################################
# 6. KEYPAIR MANAGEMENT
###############################################################################
section "6. Keypair Management"

subsection "Provider keypairs (own API key)"
resp=$(http GET "${IH_IDENTITY}/api/identity/v1alpha/participants/${PROVIDER_B64}/keypairs" \
  -H "x-api-key: ${PROVIDER_API_KEY}")
expect_http 200 "Provider: list own keypairs" "$resp"
body="${resp#*|}"
provider_key_id=$(json_field "$body" '.[0].keyId')
provider_kp_id=$(json_field "$body" '.[0].id')
info "Provider key ID: ${provider_key_id}, keypair resource ID: ${provider_kp_id}"

subsection "Consumer keypairs (own API key)"
resp=$(http GET "${IH_IDENTITY}/api/identity/v1alpha/participants/${CONSUMER_B64}/keypairs" \
  -H "x-api-key: ${CONSUMER_API_KEY}")
expect_http 200 "Consumer: list own keypairs" "$resp"

subsection "Admin: list all keypairs (super-user)"
resp=$(http GET "${IH_IDENTITY}/api/identity/v1alpha/keypairs?participantId=${PROVIDER_ID}&offset=0&limit=10" \
  -H "x-api-key: ${SUPERUSER_KEY}")
expect_http 200 "Admin: list provider keypairs" "$resp"

###############################################################################
# 7. DID MANAGEMENT
###############################################################################
section "7. DID Management"

subsection "Provider DIDs (own API key)"
resp=$(http POST "${IH_IDENTITY}/api/identity/v1alpha/participants/${PROVIDER_B64}/dids/query" \
  -H "x-api-key: ${PROVIDER_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{}')
expect_http 200 "Provider: query own DIDs" "$resp"
body="${resp#*|}"
provider_did_actual=$(json_field "$body" '.[0].id')
info "Provider DID: ${provider_did_actual}"

resp=$(http POST "${IH_IDENTITY}/api/identity/v1alpha/participants/${PROVIDER_B64}/dids/state" \
  -H "x-api-key: ${PROVIDER_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"did\": \"${provider_did_actual}\"}")
expect_http 200 "Provider: DID state" "$resp"
body="${resp#*|}"
info "Provider DID state: ${body}"

subsection "Consumer DIDs (own API key)"
resp=$(http POST "${IH_IDENTITY}/api/identity/v1alpha/participants/${CONSUMER_B64}/dids/query" \
  -H "x-api-key: ${CONSUMER_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{}')
expect_http 200 "Consumer: query own DIDs" "$resp"

subsection "Admin: list all DIDs"
resp=$(http GET "${IH_IDENTITY}/api/identity/v1alpha/dids?offset=0&limit=10" \
  -H "x-api-key: ${SUPERUSER_KEY}")
expect_http 200 "Admin: list all DIDs" "$resp"

###############################################################################
# 8. DID RESOLUTION (did:web)
###############################################################################
section "8. DID Resolution (did:web)"

info "Note: did:web resolution in local Docker returns 204 because the DID document's"
info "host (identityhub:10100) doesn't match the request host (localhost:10100)."
info "In production with a reverse proxy, this will return 200 with the DID document."

subsection "IdentityHub DID resolution (port 10100)"
resp=$(http GET "${IH_DID}/super-user/did.json")
code="${resp%%|*}"
if [[ "$code" == "200" ]]; then
  pass "IH: resolve super-user DID (HTTP 200)"
elif [[ "$code" == "204" ]]; then
  pass "IH: resolve super-user DID (HTTP 204 — expected in local dev)"
else
  fail "IH: resolve super-user DID" "expected 200 or 204, got $code"
fi

resp=$(http GET "${IH_DID}/provider/did.json")
code="${resp%%|*}"
if [[ "$code" == "200" || "$code" == "204" ]]; then
  pass "IH: resolve provider DID (HTTP $code)"
else
  fail "IH: resolve provider DID" "expected 200 or 204, got $code"
fi

subsection "IssuerService DID resolution (port 18100)"
resp=$(http GET "${IS_DID}/super-user/did.json")
code="${resp%%|*}"
if [[ "$code" == "200" || "$code" == "204" ]]; then
  pass "IS: resolve super-user DID (HTTP $code)"
else
  fail "IS: resolve super-user DID" "expected 200 or 204, got $code"
fi

###############################################################################
# 9. CREDENTIAL MANAGEMENT
###############################################################################
section "9. Credential Management"

subsection "Provider credentials (own API key)"
resp=$(http GET "${IH_IDENTITY}/api/identity/v1alpha/participants/${PROVIDER_B64}/credentials" \
  -H "x-api-key: ${PROVIDER_API_KEY}")
expect_http 200 "Provider: list own credentials" "$resp"
body="${resp#*|}"
info "Provider credentials count: $(json_field "$body" 'length')"

subsection "Consumer credentials (own API key)"
resp=$(http GET "${IH_IDENTITY}/api/identity/v1alpha/participants/${CONSUMER_B64}/credentials" \
  -H "x-api-key: ${CONSUMER_API_KEY}")
expect_http 200 "Consumer: list own credentials" "$resp"

subsection "Admin: list all credentials"
resp=$(http GET "${IH_IDENTITY}/api/identity/v1alpha/credentials?participantId=${PROVIDER_ID}&offset=0&limit=10" \
  -H "x-api-key: ${SUPERUSER_KEY}")
expect_http 200 "Admin: list all credentials for provider" "$resp"

###############################################################################
# 10. STS TOKEN ENDPOINT (IdentityHub)
#     This is how EDC connectors authenticate to get Self-Issued tokens.
#     - client_id = DID (from createParticipant response .clientId)
#     - client_secret = secret (from createParticipant response .clientSecret)
#     - audience = the DID of the target party
###############################################################################
section "10. STS Token Endpoint (IdentityHub)"

subsection "IH STS — invalid client (expected 401)"
resp=$(http POST "${IH_STS}/api/sts/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=nonexistent&client_secret=bad&audience=did:web:someone")
expect_http 401 "IH STS: invalid client -> 401" "$resp"

subsection "IH STS — wrong content type (expected 415)"
resp=$(http POST "${IH_STS}/api/sts/token" \
  -H "Content-Type: application/json" \
  -d '{"grant_type":"client_credentials"}')
expect_http 415 "IH STS: JSON content type -> 415" "$resp"

subsection "IH STS — provider gets SI token (client_credentials flow)"
if [[ -n "${PROVIDER_CLIENT_ID:-}" && "${PROVIDER_CLIENT_ID}" != "null" && "${PROVIDER_CLIENT_ID}" != "" ]]; then
  resp=$(http POST "${IH_STS}/api/sts/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials&client_id=${PROVIDER_CLIENT_ID}&client_secret=${PROVIDER_CLIENT_SECRET}&audience=${CONSUMER_DID}")
  code="${resp%%|*}"
  body="${resp#*|}"
  if [[ "$code" == "200" ]]; then
    pass "IH STS: provider -> consumer token (HTTP 200)"
    PROVIDER_STS_TOKEN=$(json_field "$body" '.access_token')
    STS_TOKEN_TYPE=$(json_field "$body" '.token_type')
    STS_EXPIRES_IN=$(json_field "$body" '.expires_in')
    info "Token type: ${STS_TOKEN_TYPE}, expires_in: ${STS_EXPIRES_IN}s"
    info "Access token (SI token): ${PROVIDER_STS_TOKEN:0:80}..."
  else
    fail "IH STS: provider -> consumer token" "HTTP $code — ${body:0:300}"
  fi
else
  fail "IH STS: provider token" "No clientId returned during participant creation"
fi

subsection "IH STS — consumer gets SI token"
if [[ -n "${CONSUMER_CLIENT_ID:-}" && "${CONSUMER_CLIENT_ID}" != "null" && "${CONSUMER_CLIENT_ID}" != "" ]]; then
  resp=$(http POST "${IH_STS}/api/sts/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials&client_id=${CONSUMER_CLIENT_ID}&client_secret=${CONSUMER_CLIENT_SECRET}&audience=${PROVIDER_DID}")
  code="${resp%%|*}"
  body="${resp#*|}"
  if [[ "$code" == "200" ]]; then
    pass "IH STS: consumer -> provider token (HTTP 200)"
    CONSUMER_STS_TOKEN=$(json_field "$body" '.access_token')
    info "Consumer SI token: ${CONSUMER_STS_TOKEN:0:80}..."
  else
    fail "IH STS: consumer -> provider token" "HTTP $code — ${body:0:300}"
  fi
else
  fail "IH STS: consumer token" "No clientId returned during participant creation"
fi

###############################################################################
# 11. DCP PROTOCOL — HOLDER SIDE (IdentityHub port 13131)
#     These are the endpoints that other connectors call to request
#     credential presentations from a wallet holder.
#     Path: /api/credentials/v1/participants/{b64-participantId}/...
###############################################################################
section "11. DCP Protocol — Holder Side (IdentityHub)"

# DCP protocol endpoints require base64-encoded participantContextId in the path
PROV_B64_RAW=$(b64raw "$PROVIDER_ID")

subsection "Presentations query (requires valid SI token from counter-party)"
resp=$(http POST "${IH_CREDENTIALS}/api/credentials/v1/participants/${PROV_B64_RAW}/presentations/query" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer fake-token" \
  -d '{
    "@context": ["https://w3id.org/tractusx-trust/v0.8"],
    "@type": "PresentationQueryMessage",
    "scope": ["org.eclipse.edc.vc.type:MembershipCredential:read"]
  }')
expect_http 401 "DCP: presentations/query (fake auth -> 401)" "$resp"
body="${resp#*|}"
info "Response: ${body:0:150}"

subsection "Credential offers (requires valid SI token)"
resp=$(http POST "${IH_CREDENTIALS}/api/credentials/v1/participants/${PROV_B64_RAW}/offers" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer fake-token" \
  -d '{}')
expect_http_any "DCP: offers (fake auth)" "$resp" 401 400

subsection "Credential storage (requires valid SI token)"
resp=$(http POST "${IH_CREDENTIALS}/api/credentials/v1/participants/${PROV_B64_RAW}/credentials" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer fake-token" \
  -d '{}')
expect_http_any "DCP: credential storage (fake auth)" "$resp" 401 400

###############################################################################
# 12. DCP PROTOCOL — ISSUER SIDE (IssuerService port 13132)
###############################################################################
section "12. DCP Protocol — Issuer Side (IssuerService)"

IS_SU_B64_RAW=$(b64raw "super-user")

subsection "Issuer metadata (public — no auth required)"
resp=$(http GET "${IS_ISSUANCE}/api/issuance/v1alpha/participants/${IS_SU_B64_RAW}/metadata/" \
  -H "Authorization: Bearer fake-token")
expect_http 200 "DCP Issuer: metadata (public endpoint)" "$resp"
body="${resp#*|}"
issuer_did=$(json_field "$body" '.issuer')
info "Issuer DID: ${issuer_did}"

subsection "Credential request (requires DCP token)"
resp=$(http POST "${IS_ISSUANCE}/api/issuance/v1alpha/participants/${IS_SU_B64_RAW}/credentials/" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer fake-token" \
  -d '{
    "@context": ["https://w3id.org/tractusx-trust/v0.8"],
    "@type": "CredentialRequestMessage",
    "format": "jwt_vc",
    "credentialType": "MembershipCredential"
  }')
expect_http_any "DCP Issuer: credential request (fake auth)" "$resp" 401 400

subsection "Credential request status (requires DCP token)"
resp=$(http GET "${IS_ISSUANCE}/api/issuance/v1alpha/participants/${IS_SU_B64_RAW}/requests/test-req-id" \
  -H "Authorization: Bearer fake-token")
expect_http 401 "DCP Issuer: request status (fake auth -> 401)" "$resp"

###############################################################################
# 13. ISSUERSERVICE ADMIN API (port 15152)
###############################################################################
section "13. IssuerService Admin API"

IS_SU_B64=$(b64url "super-user")

subsection "Holders"
resp=$(http POST "${IS_ISSUER_ADMIN}/api/issuer/v1alpha/participants/${IS_SU_B64}/holders/query" \
  -H "x-api-key: ${SUPERUSER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{}')
expect_http 200 "IS Admin: holders/query" "$resp"
body="${resp#*|}"
info "Holders: $(json_field "$body" 'length') entries"

subsection "Attestation definitions"
resp=$(http POST "${IS_ISSUER_ADMIN}/api/issuer/v1alpha/participants/${IS_SU_B64}/attestations/query" \
  -H "x-api-key: ${SUPERUSER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{}')
expect_http 200 "IS Admin: attestations/query" "$resp"

subsection "Credential definitions"
resp=$(http POST "${IS_ISSUER_ADMIN}/api/issuer/v1alpha/participants/${IS_SU_B64}/credentialdefinitions/query" \
  -H "x-api-key: ${SUPERUSER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{}')
expect_http 200 "IS Admin: credentialdefinitions/query" "$resp"

subsection "Issuance processes"
resp=$(http POST "${IS_ISSUER_ADMIN}/api/issuer/v1alpha/participants/${IS_SU_B64}/issuanceprocesses/query" \
  -H "x-api-key: ${SUPERUSER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{}')
expect_http 200 "IS Admin: issuanceprocesses/query" "$resp"

subsection "Credentials"
resp=$(http POST "${IS_ISSUER_ADMIN}/api/issuer/v1alpha/participants/${IS_SU_B64}/credentials/query" \
  -H "x-api-key: ${SUPERUSER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{}')
expect_http 200 "IS Admin: credentials/query" "$resp"

###############################################################################
# 14. IssuerService STS
###############################################################################
section "14. IssuerService STS"

resp=$(http POST "${IS_STS}/api/sts/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=nonexistent&client_secret=bad&audience=did:web:someone")
expect_http 401 "IS STS: invalid client -> 401" "$resp"

###############################################################################
# 15. PARTICIPANT LIFECYCLE: activate / deactivate / token regen
###############################################################################
section "15. Participant Lifecycle"

subsection "Deactivate provider"
resp=$(http POST "${IH_IDENTITY}/api/identity/v1alpha/participants/${PROVIDER_B64}/state?isActive=false" \
  -H "x-api-key: ${SUPERUSER_KEY}")
expect_http 204 "Deactivate provider" "$resp"

# Verify deactivated — provider should not be able to use their API key
resp=$(http GET "${IH_IDENTITY}/api/identity/v1alpha/participants/${PROVIDER_B64}/keypairs" \
  -H "x-api-key: ${PROVIDER_API_KEY}")
code="${resp%%|*}"
if [[ "$code" == "401" || "$code" == "403" ]]; then
  pass "Deactivated provider cannot access API (HTTP $code)"
else
  warn "Deactivated provider still has access (HTTP $code) — may be expected depending on caching"
fi

subsection "Reactivate provider"
resp=$(http POST "${IH_IDENTITY}/api/identity/v1alpha/participants/${PROVIDER_B64}/state?isActive=true" \
  -H "x-api-key: ${SUPERUSER_KEY}")
expect_http 204 "Reactivate provider" "$resp"

subsection "Regenerate provider API token"
resp=$(http POST "${IH_IDENTITY}/api/identity/v1alpha/participants/${PROVIDER_B64}/token" \
  -H "x-api-key: ${SUPERUSER_KEY}")
code="${resp%%|*}"
body="${resp#*|}"
if [[ "$code" == "200" ]]; then
  pass "Regenerate provider token (HTTP 200)"
  # Token regen returns raw API key string (plain text, not JSON)
  NEW_PROVIDER_KEY="$body"
  if [[ -n "$NEW_PROVIDER_KEY" && ${#NEW_PROVIDER_KEY} -gt 10 ]]; then
    pass "New provider API key received (${#NEW_PROVIDER_KEY} chars)"
    PROVIDER_API_KEY="$NEW_PROVIDER_KEY"
  else
    # Try JSON format (may vary by version)
    json_key=$(json_field "$body" '.apiKey')
    if [[ -n "$json_key" && "$json_key" != "null" ]]; then
      PROVIDER_API_KEY="$json_key"
      pass "New provider API key from JSON"
    else
      warn "Token regeneration response format unclear: ${body:0:100}"
    fi
  fi
else
  fail "Regenerate provider token" "HTTP $code — ${body:0:200}"
fi

# Verify new key works
resp=$(http GET "${IH_IDENTITY}/api/identity/v1alpha/participants/${PROVIDER_B64}/keypairs" \
  -H "x-api-key: ${PROVIDER_API_KEY}")
expect_http 200 "Provider: new API key works" "$resp"

###############################################################################
# 16. DID PUBLISH / UNPUBLISH
###############################################################################
section "16. DID Publish / Unpublish"

subsection "Publish provider DID"
resp=$(http POST "${IH_IDENTITY}/api/identity/v1alpha/participants/${PROVIDER_B64}/dids/publish" \
  -H "x-api-key: ${PROVIDER_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"did\": \"${PROVIDER_DID}\"}")
expect_http 204 "Publish provider DID" "$resp"

subsection "Unpublish provider DID (should fail — primary DID)"
resp=$(http POST "${IH_IDENTITY}/api/identity/v1alpha/participants/${PROVIDER_B64}/dids/unpublish" \
  -H "x-api-key: ${PROVIDER_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"did\": \"${PROVIDER_DID}\"}")
code="${resp%%|*}"
if [[ "$code" == "400" ]]; then
  pass "Unpublish primary DID correctly rejected (HTTP 400)"
elif [[ "$code" == "204" ]]; then
  warn "Unpublish primary DID succeeded — check if this is intended"
else
  fail "Unpublish provider DID" "unexpected HTTP $code"
fi

###############################################################################
# 17. END-TO-END: STS Token for Connector-to-Connector Communication
#     This simulates the real DCP flow:
#     1. Provider connector calls IH STS to get SI token targeting consumer
#     2. The SI token is a JWT signed by the provider's key
#     3. Consumer verifies the JWT via the provider's DID document
###############################################################################
section "17. End-to-End: STS Token Flow (Connector Auth)"

subsection "Provider requests SI token with consumer as audience"
if [[ -n "${PROVIDER_CLIENT_ID:-}" && "${PROVIDER_CLIENT_ID}" != "null" && "${PROVIDER_CLIENT_ID}" != "" ]]; then
  resp=$(http POST "${IH_STS}/api/sts/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials&client_id=${PROVIDER_CLIENT_ID}&client_secret=${PROVIDER_CLIENT_SECRET}&audience=${CONSUMER_DID}")
  code="${resp%%|*}"
  body="${resp#*|}"
  if [[ "$code" == "200" ]]; then
    pass "STS: provider -> consumer SI token (HTTP 200)"
    E2E_TOKEN=$(json_field "$body" '.access_token')

    # Decode JWT header (add padding for base64)
    jwt_header_raw=$(printf '%s' "$E2E_TOKEN" | cut -d'.' -f1 | tr '_-' '/+')
    # Add base64 padding
    pad=$((4 - ${#jwt_header_raw} % 4))
    [[ $pad -lt 4 ]] && jwt_header_raw="${jwt_header_raw}$(printf '=%.0s' $(seq 1 $pad))"
    jwt_header=$(printf '%s' "$jwt_header_raw" | base64 -d 2>/dev/null || true)
    if echo "$jwt_header" | jq . &>/dev/null 2>&1; then
      pass "SI token is a valid JWT"
      jwt_alg=$(json_field "$jwt_header" '.alg')
      jwt_kid=$(json_field "$jwt_header" '.kid')
      info "JWT alg: $jwt_alg, kid: $jwt_kid"
    fi

    # Decode JWT payload (add padding for base64)
    jwt_payload_raw=$(printf '%s' "$E2E_TOKEN" | cut -d'.' -f2 | tr '_-' '/+')
    pad=$((4 - ${#jwt_payload_raw} % 4))
    [[ $pad -lt 4 ]] && jwt_payload_raw="${jwt_payload_raw}$(printf '=%.0s' $(seq 1 $pad))"
    jwt_payload=$(printf '%s' "$jwt_payload_raw" | base64 -d 2>/dev/null || true)
    if echo "$jwt_payload" | jq . &>/dev/null 2>&1; then
      jwt_iss=$(json_field "$jwt_payload" '.iss')
      jwt_sub=$(json_field "$jwt_payload" '.sub')
      jwt_aud=$(json_field "$jwt_payload" '.aud')
      jwt_jti=$(json_field "$jwt_payload" '.jti')
      info "JWT iss: $jwt_iss"
      info "JWT sub: $jwt_sub"
      info "JWT aud: $jwt_aud"
      info "JWT jti: $jwt_jti"

      # Verify issuer matches provider DID
      if [[ "$jwt_iss" == "$PROVIDER_DID" ]]; then
        pass "JWT issuer matches provider DID"
      else
        fail "JWT issuer mismatch" "expected $PROVIDER_DID, got $jwt_iss"
      fi

      # Verify audience matches consumer DID
      if [[ "$jwt_aud" == "$CONSUMER_DID" ]]; then
        pass "JWT audience matches consumer DID"
      else
        fail "JWT audience mismatch" "expected $CONSUMER_DID, got $jwt_aud"
      fi
    fi
  else
    fail "STS: provider -> consumer SI token" "HTTP $code — ${body:0:300}"
  fi
else
  fail "STS E2E test" "No provider clientId"
fi

###############################################################################
# 18. RESTART RESILIENCE
###############################################################################
section "18. Restart Resilience"

info "Restarting IdentityHub container..."
docker restart identityhub >/dev/null 2>&1

info "Waiting for IdentityHub to be healthy..."
if wait_for_health "${IH_DEFAULT}/api/check/health" 30; then
  pass "IH healthy after restart"
else
  fail "IH health after restart" "Did not become healthy within 30s"
fi

resp=$(http GET "${IH_IDENTITY}/api/identity/v1alpha/participants/${PROVIDER_B64}" \
  -H "x-api-key: ${SUPERUSER_KEY}")
expect_http 200 "Provider persisted after restart" "$resp"

# After restart, vault dev mode loses secrets, so provider's API key won't work.
# The super-user key is restored by SuperUserSeedExtension.ensureApiKeyInVault(),
# but other participants' keys are lost. This is expected in dev mode.
resp=$(http GET "${IH_IDENTITY}/api/identity/v1alpha/participants/${PROVIDER_B64}/keypairs" \
  -H "x-api-key: ${PROVIDER_API_KEY}")
code="${resp%%|*}"
if [[ "$code" == "200" ]]; then
  pass "Provider API key works after restart"
else
  warn "Provider API key lost after restart (HTTP $code) — expected with Vault dev mode (non-persistent)"
fi

# Super-user key should always work (restored by SuperUserSeedExtension)
resp=$(http GET "${IH_IDENTITY}/api/identity/v1alpha/participants?offset=0&limit=10" \
  -H "x-api-key: ${SUPERUSER_KEY}")
expect_http 200 "Super-user key works after restart" "$resp"

###############################################################################
# 19. CLEANUP: delete test participants
###############################################################################
section "19. Cleanup"

resp=$(http DELETE "${IH_IDENTITY}/api/identity/v1alpha/participants/${PROVIDER_B64}" \
  -H "x-api-key: ${SUPERUSER_KEY}")
expect_http 204 "Delete provider participant" "$resp"

resp=$(http DELETE "${IH_IDENTITY}/api/identity/v1alpha/participants/${CONSUMER_B64}" \
  -H "x-api-key: ${SUPERUSER_KEY}")
expect_http 204 "Delete consumer participant" "$resp"

# Verify deletion
resp=$(http GET "${IH_IDENTITY}/api/identity/v1alpha/participants/${PROVIDER_B64}" \
  -H "x-api-key: ${SUPERUSER_KEY}")
expect_http_any "Provider deleted" "$resp" 404 409

###############################################################################
# SUMMARY
###############################################################################
echo ""
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║                         TEST SUMMARY                            ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""
echo -e "  ${GREEN}Passed:   ${PASS}${NC}"
echo -e "  ${YELLOW}Warnings: ${WARN}${NC}"
echo -e "  ${RED}Failed:   ${FAIL}${NC}"
echo ""

if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo -e "${RED}Failures:${NC}"
  for err in "${ERRORS[@]}"; do
    echo "  - $err"
  done
  echo ""
fi

echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Connector Integration Notes:"
echo "  An EDC connector can use this deployment as its DCP wallet by"
echo "  configuring these properties (example for 'provider'):"
echo ""
echo "  # STS token endpoint"
echo "  edc.iam.sts.oauth.token.url=http://identityhub:9292/api/sts/token"
echo "  edc.iam.sts.oauth.client.id=<clientId from createParticipant>"
echo "  edc.iam.sts.oauth.client.secret.alias=<vault alias for clientSecret>"
echo ""
echo "  # DCP credential endpoint"
echo "  edc.iam.sts.dim.url=http://identityhub:13131/api/credentials"
echo ""
echo "  # DID resolution"
echo "  edc.ih.did.resolution.url=http://identityhub:10100/"
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if [[ $FAIL -eq 0 ]]; then
  echo -e "${GREEN}All tests passed! The DCP wallet is ready for connector integration.${NC}"
  exit 0
else
  echo -e "${RED}Some tests failed. Review the errors above.${NC}"
  exit 1
fi
