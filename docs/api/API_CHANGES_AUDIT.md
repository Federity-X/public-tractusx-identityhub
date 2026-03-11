# API Changes Audit: EDC 0.14.0 → 0.15.1

## Executive Summary

This document catalogs all API changes introduced by the EDC IdentityHub upgrade from version 0.14.0 to 0.15.1.
The audit covers: breaking changes from upstream, live endpoint verification, OpenAPI spec accuracy, and required adaptations.

> **Critical Finding**: The `ParticipantContextConfigStore` is in-memory only in EDC 0.15.1.
> On container restart, participant configs are lost while participant contexts persist in PostgreSQL.
> This causes 500 Internal Server Errors on all authenticated API calls until participants are recreated.

---

## 1. Breaking Changes from Upstream EDC

### 1.1 Rename `participantId` → `participantContextId` (#845)

**Impact**: HIGH — Affects all API request/response bodies and path parameters.

- All references to `participantId` in API payloads are now `participantContextId`
- The `ParticipantContext` model uses `participantContextId` as its identifier
- The `SuperUserSeedExtension` was already updated to use the new method name

**Status**: ✅ Adapted in our codebase.

### 1.2 Store Refactoring with New Lease Mechanism (#801)

**Impact**: HIGH — Requires new database schema with composite primary keys.

- The `edc_lease` table now uses composite PKs (`leased_by`, `leased_at`, `lease_duration`) instead of separate `lease_id` FK columns
- Tables like `edc_holder_credentialrequest` and `edc_issuance_process` no longer have a `lease_id` column
- Instead, lease columns are embedded directly in the entity tables

**Status**: ✅ Flyway V0_0_1 and V0_0_2 migration scripts created for both IdentityHub and IssuerService.

### 1.3 Improved VerifiableCredentialResource Handling (#834)

**Impact**: MEDIUM — Changes to credential storage and retrieval.

- Internal refactoring of how VCs are stored and managed
- The credential resource model may have different field names/structures

**Status**: ✅ Handled by upstream dependency upgrade.

### 1.4 Improved KeyPair Handling (#836)

**Impact**: MEDIUM — KeyPair response model changes.

- KeyPair resources now include:
  - `usage` array: `["sign_credentials", "sign_token", "sign_presentation"]`
  - `keyContext`: `"JsonWebKey2020"` (new field)
  - `serializedPublicKey`: JWK format string
  - `useDuration` / `rotationDuration`: timing parameters
- Previously, some of these fields were absent or named differently

**Status**: ✅ Verified in live testing — all new fields present in responses.

### 1.5 Ownership Check on Authorization Service (#847)

**Impact**: HIGH — Enforcement of participant-scoped access control.

- API calls are now scoped to the authenticated participant
- Admin role (`ServicePrincipal.ROLE_ADMIN`) can access cross-participant APIs (e.g., `/v1alpha/keypairs`, `/v1alpha/dids`, `/v1alpha/credentials`)
- Non-admin participants can only access their own resources

**Status**: ✅ Verified — super-user with admin role can access all endpoints.

### 1.6 Holder Attestation (#861)

**Impact**: MEDIUM — New attestation-related endpoints.

- New attestation definitions management API
- New database tables: `attestation_definitions`

**Status**: ✅ Database tables created via migration scripts. Endpoints available on IssuerService.

### 1.7 Multi-Tenant Vault (Participant Context Config)

**Impact**: CRITICAL — New per-participant vault configuration system.

- New `ParticipantContextConfig` SPI allows per-participant vault settings
- `ParticipantContextConfigStore` stores config entries per participant
- **Only in-memory implementation exists** in EDC 0.15.1 (no SQL store)
- Config entries are created during `ParticipantContextService.createParticipantContext()`
- On restart, configs are lost but participants persist in PostgreSQL → **500 errors**

**Status**: ⚠️ Workaround in place (re-creating participants). Needs proper fix (see Section 5).

### 1.8 API Key Format Change

**Impact**: HIGH — API authentication format changed.

- Old format: Simple random string
- New format: `base64(<participantContextId>).<random-string>`
- Example: `c3VwZXItdXNlcg==.superuserkey` (where `c3VwZXItdXNlcg==` = base64("super-user"))
- The base64 prefix is parsed by the auth filter to identify the participant context

**Status**: ✅ SuperUserSeedExtension generates correct format.

### 1.9 STS Token Endpoint Format

**Impact**: MEDIUM — STS token endpoint uses OAuth2-standard form encoding.

- Content-Type must be `application/x-www-form-urlencoded` (not JSON)
- Required fields: `grant_type`, `client_id`, `client_secret`, `audience`
- `audience` is now mandatory (returns error: "audience cannot be null")

**Status**: ✅ Verified in live testing.

---

## 2. Registered API Endpoints (Live Verification)

### 2.1 Port/Context Mapping

| Context     | Port  | Base Path          | Status |
|-------------|-------|--------------------|--------|
| default     | 8181  | `/api`             | ✅ Active |
| did         | 10100 | `/`                | ✅ Active |
| credentials | 13131 | `/api/credentials` | ✅ Active |
| sts         | 9292  | `/api/sts`         | ✅ Active |
| identity    | 15151 | `/api/identity`    | ✅ Active |
| version     | 7171  | `/.well-known/api` | ❌ Not registered |

**Note**: The `version` context is configured in properties but its API extension is not loaded.
The `/v1/version` path is registered on the **default** context (port 8181), not on port 7171.

### 2.2 Registered Controller Paths

From Jersey IntrospectionModeler logs:

```
/                                                          → DID resolution (port 10100)
/check                                                     → Health/Observability (port 8181)
/v1/version                                                → Version info (port 8181)
/v1/participants/{participantContextId}/credentials        → DCP Credential Storage (port 13131)
/v1/participants/{participantContextId}/offers              → DCP Credential Offers (port 13131)
/v1/participants/{participantContextId}/presentations      → DCP Presentations (port 13131)
/v1alpha/credentials                                       → All credentials - admin (port 15151)
/v1alpha/dids                                              → All DIDs - admin (port 15151)
/v1alpha/keypairs                                          → All keypairs - admin (port 15151)
/v1alpha/participants                                      → Participant CRUD (port 15151)
/v1alpha/participants/{participantContextId}/credentials   → Credential management (port 15151)
/v1alpha/participants/{participantContextId}/dids          → DID management (port 15151)
/v1alpha/participants/{participantContextId}/keypairs      → KeyPair management (port 15151)
```

### 2.3 Live Test Results

#### Identity API (port 15151) — Authenticated with `x-api-key` header

| Method | Path | Status | Notes |
|--------|------|--------|-------|
| GET | `/v1alpha/participants?offset=0&limit=10` | ✅ 200 | Lists all participants |
| GET | `/v1alpha/participants/{b64id}` | ✅ 200 | Get participant by base64-encoded ID |
| POST | `/v1alpha/participants` | ✅ 200 | Create participant, returns `{apiKey, clientId, clientSecret}` |
| DELETE | `/v1alpha/participants/{b64id}` | ✅ 204 | Delete participant |
| POST | `/v1alpha/participants/{b64id}/state?isActive=true` | ✅ 204 | Activate/deactivate |
| POST | `/v1alpha/participants/{b64id}/token` | ✅ 200 | Regenerate API token |
| PUT | `/v1alpha/participants/{b64id}/roles` | ✅ 204 | Update roles (JSON array body) |
| GET | `/v1alpha/participants/{b64id}/keypairs` | ✅ 200 | List keypairs for participant |
| GET | `/v1alpha/participants/{b64id}/keypairs/{id}` | ✅ 200 | Get keypair by ID |
| POST | `/v1alpha/participants/{b64id}/keypairs/{id}/rotate` | ✅ 204 | Rotate keypair |
| GET | `/v1alpha/keypairs?participantId=...` | ✅ 200 | List all keypairs (admin) |
| GET | `/v1alpha/dids` | ✅ 200 | List all DID documents (admin) |
| GET | `/v1alpha/participants/{b64id}/credentials` | ✅ 200 | List credentials |
| POST | `/v1alpha/participants/{b64id}/dids/query` | ✅ 200 | Returns DID documents (requires `QuerySpec` body, e.g. `{}`) |
| POST | `/v1alpha/participants/{b64id}/dids/state` | ✅ 200 | Returns DID state string (e.g. `"PUBLISHED"`) |
| POST | `/v1alpha/participants/{b64id}/dids/publish` | ✅ 204 | Publishes DID to local DID publisher |

**Note on DID endpoints**: ALL path parameters for `participantContextId` require base64 URL encoding (same as participant CRUD endpoints). The earlier test errors were caused by passing raw (non-encoded) IDs. The `onEncoded()` helper in EDC 0.15.1 decodes base64 URL-encoded strings.

#### Credential Context (port 13131) — DCP Protocol endpoints

| Method | Path | Status | Notes |
|--------|------|--------|-------|
| POST | `/v1/participants/{id}/offers` | ✅ 401 | Requires `Authorization` header (DCP protocol) |
| POST | `/v1/participants/{id}/presentations/query` | ✅ 401 | Requires `Authorization` header |

#### DID Resolution (port 10100)

| Method | Path | Status | Notes |
|--------|------|--------|-------|
| GET | `/{participant}/did.json` | ⚠️ 204 | Returns empty — see explanation below |

**DID Resolution explanation**: The `DidWebParser` converts the request URL to a DID identifier including the host and port. For example, `http://localhost:10100/super-user/did.json` resolves to `did:web:localhost%3A10100:super-user`. However, the DID stored in the database is `did:web:super-user` (without host/port). This is expected behavior — in production, a reverse proxy would route requests so the DID URL matches the stored DID identifier.

#### STS (port 9292)

| Method | Path | Status | Notes |
|--------|------|--------|-------|
| POST | `/api/sts/token` | ✅ 400/401 | Accept `application/x-www-form-urlencoded` only |

#### Health (port 8181)

| Method | Path | Status | Notes |
|--------|------|--------|-------|
| GET | `/api/check/health` | ✅ 200 | Vault + BaseRuntime health |
| GET | `/api/check/readiness` | ✅ 200 | |
| GET | `/api/check/startup` | ✅ 200 | |
| GET | `/api/check/liveness` | ✅ 200 | |

---

## 3. OpenAPI Spec Discrepancies

The current OpenAPI spec at `docs/api/openAPI.yaml` has several discrepancies with the actual 0.15.1 implementation:

### 3.1 Path Parameter Naming

| Spec | Actual | Impact |
|------|--------|--------|
| `{PARTICIPANT_CONTEXT_ID}` (uppercase) | `{participantContextId}` (camelCase) | Documentation mismatch |
| `{KEY_PAIR_ID}` | `{keyPairId}` | Documentation mismatch |
| `{CREDENTIAL_ID}` | `{credentialId}` | Documentation mismatch |

### 3.2 Base64 Encoding Not Documented

The spec does not document that `PARTICIPANT_CONTEXT_ID` path parameters in participant CRUD endpoints require **base64 URL encoding** of the participant context ID.

Example: To get participant "super-user", the path is:
```
GET /v1alpha/participants/c3VwZXItdXNlcg==
```

However, DID management endpoints under `/v1alpha/participants/{participantContextId}/dids/...` use the **raw** participant context ID.

### 3.3 Spec Includes IssuerService Endpoints

The OpenAPI spec combines endpoints from both IdentityHub and IssuerService runtimes in a single file. Endpoints only available on IssuerService include:

- `/v1alpha/participants/{id}/attestations/**` — Attestation definitions CRUD
- `/v1alpha/participants/{id}/credentialdefinitions/**` — Credential definitions CRUD
- `/v1alpha/participants/{id}/credentials/offer` — Credential offer (issuer-side)
- `/v1alpha/participants/{id}/credentials/{id}/resume|revoke|suspend|status` — Credential lifecycle
- `/v1alpha/participants/{id}/holders/**` — Holder management
- `/v1alpha/participants/{id}/issuanceprocesses/**` — Issuance process management
- `/v1alpha/participants/{id}/metadata` — Issuer metadata
- `/v1alpha/participants/{id}/requests/**` — Credential request management

These are not available on the IdentityHub runtime.

### 3.4 Missing/Incorrect Spec Entries

| Issue | Details |
|-------|---------|
| DID state method | Actual is POST (not GET) with `DidRequestPayload` body: `{"did":"did:web:..."}`. Returns state string (e.g. `"PUBLISHED"`) |
| DID publish/unpublish | Both are POST with `DidRequestPayload` body: `{"did":"did:web:..."}`. Returns 204 on success |
| DID endpoint management | New endpoints: POST/PATCH/DELETE `/{b64did}/endpoints` for managing service endpoints in DID documents. Supports `?autoPublish=true` query param |
| Create participant response | Response now includes `clientSecret` field alongside `apiKey` and `clientId` |
| STS content type | Spec should specify `application/x-www-form-urlencoded` |
| STS `audience` required | `audience` parameter is now mandatory |
| Version API | Registered on default context (port 8181, path `/api/v1/version`), not on version context (7171). Returns JSON with API version info for all contexts (sts, credentials, identity, version, observability). |
| API key format | Not documented: `base64(<participantContextId>).<random-string>` |

### 3.5 `participantId` → `participantContextId` in Request Bodies

The create participant request body may still reference `participantId` but the actual field name is `participantContextId`.

---

## 4. New Response Fields

### ParticipantContext Response

```json
{
  "participantContextId": "super-user",    // was "participantId" in 0.14.0
  "properties": {},                         // new field
  "roles": ["admin"],
  "did": "did:web:super-user",
  "createdAt": 1772822172594,
  "lastModified": 1772822172594,
  "state": 1,
  "apiTokenAlias": "super-user-apikey"
}
```

### Create Participant Response

```json
{
  "apiKey": "dGVzdC1wMg==.uZM8DQ...",     // new base64 format
  "clientId": "did:web:test-p2",           // STS client ID (new)
  "clientSecret": "3tgbpVrk58X894Lx"      // STS client secret (new)
}
```

### KeyPair Response

```json
{
  "participantContextId": "super-user",
  "id": "a954081c-...",
  "timestamp": 1772822172663,
  "keyId": "super-user-key",
  "groupName": null,
  "keyContext": "JsonWebKey2020",          // new field
  "defaultPair": true,
  "useDuration": 15552000000,             // new field
  "rotationDuration": 0,                  // new field
  "serializedPublicKey": "{...JWK...}",
  "privateKeyAlias": "super-user-alias",
  "state": 200,
  "usage": ["sign_credentials", "sign_token", "sign_presentation"]  // new field
}
```

---

## 5. Known Issues & Required Fixes

### 5.1 CRITICAL: ParticipantContextConfig Persistence (FIXED)

**Problem**: The `ParticipantContextConfigStore` is in-memory only. On container restart, config entries are lost while participants persist in PostgreSQL. This causes `EdcException: No configuration found for participant context <id>` → HTTP 500 on all authenticated API calls.

Additionally, when using HashiCorp Vault in dev mode, the API key is lost on container restart, causing `NullPointerException` in `ServicePrincipal.getCredential()` during authentication.

**Root Cause**: The `HashicorpVault.getVaultClient()` calls `forParticipant()` which calls `ParticipantContextConfig.getSensitiveString()`. This throws if no config entry exists for the participant.

**Fix Applied**: Modified `SuperUserSeedExtension` to:
1. Create a `ParticipantContextConfiguration` entry in the in-memory config store when the participant already exists in DB (`ensureConfigExists()`)
2. Store the API key in vault when the participant already exists but the vault entry is missing (`ensureApiKeyInVault()`)
3. Added `participant-context-config-spi` dependency to the seed extension module

**Verified**: Tested across all restart scenarios (restart, down/up, full recreate). API returns 200 consistently.

### 5.2 Version API Context Not Registered

**Problem**: Port 7171 (`/.well-known/api`) is configured but the version API context is not actually initialized in runtime. The `/v1/version` endpoint is instead registered on the default context (port 8181, accessible at `/api/v1/version`).

**Impact**: Low — version info is accessible at `http://localhost:8181/api/v1/version`. Returns JSON with API maturity/version info for all contexts.

**Response example**:
```json
{
  "sts": [{"version": "1.0.0", "urlPath": "/v1", "maturity": "stable"}],
  "credentials": [{"version": "1.0.0", "urlPath": "/v1", "maturity": "stable"}],
  "identity": [{"version": "1.0.0-alpha", "urlPath": "/v1alpha", "maturity": null}],
  "version": [{"version": "1.0.1", "urlPath": "/v1"}],
  "observability": [{"version": "1.0.0", "urlPath": "/v1", "maturity": "stable"}]
}
```

### 5.3 DID Resolution Returns Empty in Local Development

**Problem**: `GET /{participant}/did.json` on port 10100 returns 204 (no content) in local Docker development.

**Root Cause**: The `DidWebParser` converts the HTTP request URL to a `did:web` identifier including host and port. The URL `http://localhost:10100/super-user/did.json` resolves to `did:web:localhost%3A10100:super-user`, but the DID stored in the database is `did:web:super-user` (without host/port).

**Fix**: In production, configure a reverse proxy so DID resolution URLs match the stored DID identifiers. For local dev, either:
1. Create DIDs with the full identifier: `did:web:localhost%3A10100:super-user`
2. Or use a reverse proxy that maps the DID domain to the local hub

### 5.4 Missing Logging Configuration

**Problem**: The Dockerfiles reference `-Djava.util.logging.config.file=/app/logging.properties` but the file is not included in the Docker image.

**Fix**: ✅ Created `deployment/local/config/logging.properties` and mounted via docker-compose volume.

---

## 6. Migration Checklist

- [x] Update `participantId` → `participantContextId` in all API calls and documentation
- [x] Update API key format to `base64(<participantContextId>).<random-string>`
- [x] Create Flyway migration scripts for new database schema (composite PKs, new tables)
- [x] Add `logging.properties` to Docker deployment
- [x] Update STS token calls to use `application/x-www-form-urlencoded` with mandatory `audience`
- [ ] Update OpenAPI spec to match actual 0.15.1 endpoints
- [x] Fix or document the ParticipantContextConfig persistence issue
- [ ] Separate IdentityHub and IssuerService endpoints in OpenAPI spec (or clearly label them)
- [ ] Document base64 encoding requirement for participant ID path parameters
- [ ] Investigate and fix DID management query endpoint
