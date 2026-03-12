# Integrating Tractus-X IdentityHub as a DCP Wallet for EDC Connectors

**Version**: EDC 0.15.1 / IdentityHub 0.1.0-SNAPSHOT (locally built from branch `feature/198-upgrade-edc-0.15.1`, using upstream EDC 0.15.1)
**Date**: March 2026
**Audience**: EDC connector operators and developers

### Repository References

| Repository | Branch | URL |
|------------|--------|-----|
| **IdentityHub** (this repo) | `dcp-flow-local-deployment-with-upstream-0.15.1` | [Federity-X/public-tractusx-identityhub](https://github.com/Federity-X/public-tractusx-identityhub/tree/dcp-flow-local-deployment-with-upstream-0.15.1) |
| **Tractus-X EDC** | `dcp` | [Federity-X/public-tractusx-edc](https://github.com/Federity-X/public-tractusx-edc/tree/dcp) |

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Prerequisites](#3-prerequisites)
4. [Deployment](#4-deployment)
5. [Provisioning a Connector Identity](#5-provisioning-a-connector-identity)
6. [EDC Connector Configuration](#6-edc-connector-configuration)
7. [Authentication Model](#7-authentication-model)
8. [DCP Protocol Flow](#8-dcp-protocol-flow)
9. [API Reference](#9-api-reference)
10. [End-to-End Walkthrough](#10-end-to-end-walkthrough)
11. [Kubernetes / Helm Deployment](#11-kubernetes--helm-deployment)
12. [Troubleshooting](#12-troubleshooting)

---

## 1. Overview

The **Tractus-X IdentityHub** serves as a **Decentralized Claims Protocol (DCP) wallet** for Eclipse Dataspace Connector (EDC) instances. It provides:

- **Self-Issued (SI) Token generation** via an OAuth2-compatible Secure Token Service (STS)
- **DID document management** (`did:web` method) for connector identity
- **Verifiable Credential storage** and presentation
- **DCP protocol endpoints** for credential presentation queries, credential offers, and credential storage
- **Per-company architecture** — each company deploys its own IdentityHub instance with dedicated Vault and PostgreSQL

The companion **IssuerService** handles credential issuance, revocation, and status list management.

> **Important**: While IdentityHub supports multi-tenant operation (multiple participants in one instance),
> the recommended production architecture — and our validated local deployment — uses a **dedicated IdentityHub
> per company**. This avoids DID resolution conflicts and simplifies credential/key isolation.

### How EDC Connectors Use the IdentityHub

```
┌─────────────┐     STS Token        ┌───────────────┐
│ Provider CP │──(client_credentials)─│  Provider IH  │
│  Connector  │                       │  (DCP Wallet) │
└──────┬──────┘                       │  • STS        │
       │                              │  • DID        │
       │  SI Token (JWT)              │  • Credentials│
       │  iss=did:web:provider-ih:*   └───────────────┘
       │  aud=did:web:consumer-ih:*
       │  sub=did:web:provider-ih:*
       ▼
┌─────────────┐  Presentation Query   ┌───────────────┐
│ Consumer CP │──(Bearer SI Token)───▶│  Provider IH  │
│  Connector  │                       │  (resolves    │
└─────────────┘                       │   credentials)│
       │                              └───────────────┘
       │  Resolve consumer DID
       ▼
┌───────────────┐
│  Consumer IH  │
│  (verifies    │
│   JWT sig)    │
└───────────────┘
```

1. **Provider connector** calls **its own** IdentityHub STS (`provider-ih`) to get an SI token targeting the consumer
2. Provider sends the SI token as a `Bearer` token to the consumer connector
3. Consumer connector resolves the provider's DID document from **provider-ih**'s DID endpoint
4. Consumer verifies the JWT signature using the public key in the provider's DID document
5. For credential verification, the consumer calls **provider-ih**'s DCP presentation endpoint

---

## 2. Architecture

### Component Map

Each company deploys its own IdentityHub stack. A shared IssuerService handles credential issuance.

```mermaid
graph TB
    subgraph "Issuer Stack (from this repo)"
        issuer-vault["issuer-vault :8200"]
        issuer-postgres["issuer-postgres :5432"]
        issuerservice["issuerservice<br/>(Issuer IdentityHub)"]
        issuerservice --> issuer-vault
        issuerservice --> issuer-postgres
    end

    subgraph "Provider Company"
        provider-vault["provider-vault :8201"]
        provider-postgres["provider-postgres :6432"]
        provider-ih["provider-ih<br/>(Provider Wallet)"]
        provider-cp["provider-cp<br/>(Control Plane)"]
        provider-dp["provider-dp<br/>(Data Plane)"]
        provider-ih --> provider-vault
        provider-ih --> provider-postgres
        provider-cp --> provider-ih
        provider-cp --> provider-vault
        provider-dp --> provider-cp
    end

    subgraph "Consumer Company"
        consumer-vault["consumer-vault :8202"]
        consumer-postgres["consumer-postgres :6433"]
        consumer-ih["consumer-ih<br/>(Consumer Wallet)"]
        consumer-cp["consumer-cp<br/>(Control Plane)"]
        consumer-dp["consumer-dp<br/>(Data Plane)"]
        consumer-ih --> consumer-vault
        consumer-ih --> consumer-postgres
        consumer-cp --> consumer-ih
        consumer-cp --> consumer-vault
        consumer-dp --> consumer-cp
    end

    subgraph "Central"
        bdrs["bdrs-server :8580/:8581"]
    end

    issuerservice -- "Issues VCs" --> provider-ih
    issuerservice -- "Issues VCs" --> consumer-ih
    consumer-cp -- "DSP Protocol" --> provider-cp
    provider-cp -- "DID resolve" --> consumer-ih
    consumer-cp -- "DID resolve" --> provider-ih
    consumer-cp -- "BPN↔DID" --> bdrs
    provider-cp -- "BPN↔DID" --> bdrs
```

| Component | Provider Stack | Consumer Stack | Shared |
|-----------|---------------|----------------|--------|
| **IdentityHub** | `provider-ih` (7181, 7292, 7100, 7131, 7151) | `consumer-ih` (8182, 8293, 8100, 8132, 8152) | |
| **PostgreSQL** | `provider-postgres` (:6432) | `consumer-postgres` (:6433) | |
| **Vault** | `provider-vault` (:8201) | `consumer-vault` (:8202) | |
| **IssuerService** | | | `issuerservice` (18181, 18292, 13132, 15152, 19999) |
| **Issuer DB** | | | `issuer-postgres` (:5432) |
| **Issuer Vault** | | | `issuer-vault` (:8200) |
| **BDRS** | | | `bdrs-server` (:8580, :8581) |

### Port Reference (IdentityHub)

| Port | Context | Description | Auth |
|------|---------|-------------|------|
| **8181** | default | Health checks, observability, version API | None |
| **9292** | sts | STS token endpoint (OAuth2 client_credentials) | `client_id` + `client_secret` |
| **10100** | did | DID document resolution (`did:web`) | None (public) |
| **13131** | credentials | DCP protocol (presentations, offers, credential storage) | `Authorization: Bearer <SI Token>` |
| **15151** | identity | Management API (participant CRUD, keypairs, DIDs, credentials) | `x-api-key` header |

> **Port mapping note**: In the local Docker deployment, provider-ih maps internal ports to 7xxx
> and consumer-ih maps them to 8xxx on the host. The internal container ports remain at the
> defaults above. See the EDC `deployment/local/docker-compose.yaml` for exact mappings.

### Port Reference (IssuerService)

| Port | Context | Description | Auth |
|------|---------|-------------|------|
| **18181** | default | Health checks, observability | None |
| **18292** | sts | STS token endpoint | `client_id` + `client_secret` |
| **18100** | did | DID document resolution | None (public) |
| **13132** | issuance | DCP issuance protocol (credential requests, metadata) | `Authorization: Bearer <SI Token>` |
| **15152** | issueradmin | Admin API (holders, attestations, credential definitions) | `x-api-key` header |
| **19999** | statuslist | Credential status list resolution | None (public) |

---

## 3. Prerequisites

### Software

- Docker & Docker Compose
- `jq` (for testing / scripting)
- `curl`
- Java 21+ (if building from source)

### Networking

The IdentityHub and EDC connectors must be on the **same Docker network** so they can reach each other by container hostname.

```bash
# Create shared network (one-time)
docker network create edc-net
```

### Build Shadow JARs

```bash
cd tractusx-identityhub
./gradlew :runtimes:identityhub:shadowJar :runtimes:issuerservice:shadowJar
```

---

## 4. Deployment

### Local Docker Compose

The IdentityHub stack is deployed as part of the EDC local deployment. Each company
gets its own IdentityHub, Vault, and PostgreSQL:

```bash
# From the tractusx-identityhub repo — build shadow JARs first
cd tractusx-identityhub
./gradlew :runtimes:identityhub:shadowJar :runtimes:issuerservice:shadowJar

# From the tractusx-edc repo — start the full stack
cd tractusx-edc/deployment/local
docker compose up --build -d
```

This starts **14 containers** on the `edc-net` network:

| Container | Role | Host Ports |
|-----------|------|------------|
| `provider-ih` | Provider's DCP wallet | 7181, 7292, 7100, 7131, 7151 |
| `provider-vault` | Provider's secret store | 8201 |
| `provider-postgres` | Provider's database (IH + EDC) | 6432 |
| `provider-cp` | Provider control plane | 19191–19195 |
| `provider-dp` | Provider data plane | 19196–19198 |
| `consumer-ih` | Consumer's DCP wallet | 8182, 8293, 8100, 8132, 8152 |
| `consumer-vault` | Consumer's secret store | 8202 |
| `consumer-postgres` | Consumer's database (IH + EDC) | 6433 |
| `consumer-cp` | Consumer control plane | 29191–29195 |
| `consumer-dp` | Consumer data plane | 29196–29198 |
| `issuerservice` | Shared credential issuer | 18181, 18292, 13132, 15152, 19999 |
| `issuer-vault` | Issuer's secret store | 8200 |
| `issuer-postgres` | Issuer's database (+ BDRS) | 5432 |
| `bdrs-server` | BPN/DID resolution service | 8580, 8581 |

#### Verify health:

```bash
# Provider IdentityHub
curl -s http://localhost:7181/api/check/health | jq .

# Consumer IdentityHub
curl -s http://localhost:8182/api/check/health | jq .

# IssuerService
curl -s http://localhost:18181/api/check/health | jq .
```

### Configuration Files

| File | Purpose |
|------|---------|
| `deployment/local/config/provider-ih.properties` | Provider IdentityHub runtime config |
| `deployment/local/config/consumer-ih.properties` | Consumer IdentityHub runtime config |
| `deployment/local/config/provider-cp.properties` | Provider EDC control plane config |
| `deployment/local/config/consumer-cp.properties` | Consumer EDC control plane config |
| `deployment/local/config/provider-dp.properties` | Provider EDC data plane config |
| `deployment/local/config/consumer-dp.properties` | Consumer EDC data plane config |
| `deployment/local/docker-compose.yaml` | Full stack definition |

---

## 5. Provisioning a Connector Identity

Each EDC connector needs a **participant context** in **its own** IdentityHub instance. This gives the connector:
- A DID identity (`did:web:...`)
- A keypair for signing SI tokens
- STS credentials (`client_id` + `client_secret`)
- An API key for management operations

### Step 1: Create a Participant

Each participant is created in its **own** IdentityHub instance:

```bash
SUPERUSER_KEY="c3VwZXItdXNlcg==.superuserkey"

# Create provider participant in provider-ih (port 7151)
curl -s -X POST http://localhost:7151/api/identity/v1alpha/participants \
  -H "x-api-key: ${SUPERUSER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "participantContextId": "provider",
    "did": "did:web:provider-ih:provider",
    "active": true,
    "key": {
      "keyId": "provider-key",
      "privateKeyAlias": "provider-alias",
      "keyGeneratorParams": {
        "algorithm": "EdDSA",
        "curve": "Ed25519"
      }
    },
    "roles": []
  }' | jq .
```

**Response:**

```json
{
  "apiKey": "cHJvdmlkZXI=.uZM8DQ7x3nWb...",
  "clientId": "did:web:provider-ih:provider",
  "clientSecret": "3tgbpVrk58X894Lx"
}
```

**Save these three values — the EDC connector needs them:**

| Field | Purpose | Used By |
|-------|---------|---------|
| `apiKey` | Management API authentication | Admin tooling only |
| `clientId` | STS `client_id` parameter (= the DID) | EDC connector for STS auth |
| `clientSecret` | STS `client_secret` parameter | EDC connector for STS auth |

> **DID format**: The DID encodes the IdentityHub hostname. `did:web:provider-ih:provider`
> resolves to `http://provider-ih:10100/provider/did.json` inside Docker.

### Step 2: Verify the Participant

```bash
# Base64-encode the participant ID for path parameters
PROVIDER_B64=$(printf 'provider' | base64 | sed 's/+/%2B/g; s/\//%2F/g; s/=/%3D/g')

# Get participant details (note: port 7151 for provider-ih)
curl -s http://localhost:7151/api/identity/v1alpha/participants/${PROVIDER_B64} \
  -H "x-api-key: ${SUPERUSER_KEY}" | jq .
```

### Step 3: Verify DID and Keypair

```bash
# Query participant's DID (provider-ih management port)
curl -s -X POST http://localhost:7151/api/identity/v1alpha/participants/${PROVIDER_B64}/dids/query \
  -H "x-api-key: ${SUPERUSER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{}' | jq '.[0].id'
# → "did:web:provider-ih:provider"

# List keypairs
curl -s http://localhost:7151/api/identity/v1alpha/participants/${PROVIDER_B64}/keypairs \
  -H "x-api-key: ${SUPERUSER_KEY}" | jq '.[0]'
```

### Step 4: Test STS Token Acquisition

```bash
# Get an SI token from provider-ih STS (port 7292), targeting consumer
curl -s -X POST http://localhost:7292/api/sts/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=did:web:provider-ih:provider&client_secret=<SECRET>&audience=did:web:consumer-ih:consumer" | jq .
```

**Response:**

```json
{
  "access_token": "eyJhbGciOiJFZERTQS...",
  "token_type": "Bearer",
  "expires_in": 300
}
```

The `access_token` is a **Self-Issued (SI) JWT token** with:
- `iss` = provider's DID
- `sub` = provider's DID
- `aud` = consumer's DID (the target)
- `jti` = unique token ID
- `iat` / `exp` = issued at / expiration timestamps

---

## 6. EDC Connector Configuration

### Required Properties

Add these properties to your EDC connector's configuration to use the IdentityHub as its DCP wallet.

> **Critical**: Several of these properties have non-obvious requirements that were discovered
> through debugging. See the notes below each section.

#### Control Plane Properties (provider example)

```properties
###############################################################################
# DCP / IdentityHub Integration
###############################################################################

# --- Participant Identity ---
# CRITICAL: Must be the FULL DID on control planes, NOT a short name.
# Short names cause VP audience mismatch (aud claim won't match).
edc.participant.id=did:web:provider-ih:provider

# Short name for participant-context scoping (required when participant.id is a full DID)
edc.participant.context.id=provider

# The connector's DID (same as participant.id for control planes)
edc.iam.issuer.id=did:web:provider-ih:provider

# --- STS (Secure Token Service) ---
# The EDC connector calls its OWN IdentityHub's STS to obtain SI tokens.
edc.iam.sts.oauth.token.url=http://provider-ih:9292/api/sts/token
edc.iam.sts.oauth.client.id=did:web:provider-ih:provider
edc.iam.sts.oauth.client.secret.alias=provider-sts-secret

# --- DCP Credential Service ---
# The URL where the connector's credential presentation endpoint lives.
# Other connectors query this to verify credentials.
edc.iam.sts.dim.url=http://provider-ih:13131/api/credentials

# --- DID Configuration ---
edc.iam.did.web.use.https=false

# --- Trusted Issuer ---
# CRITICAL: Must include ALL credential types needed for policy evaluation.
# Missing DataExchangeGovernanceCredential here will cause negotiation failures.
edc.iam.trusted-issuer.issuer.id=did:web:issuerservice:issuer
edc.iam.trusted-issuer.issuer.supportedtypes=["MembershipCredential","BpnCredential","DataExchangeGovernanceCredential"]

# --- Transfer Proxy Key ---
# CRITICAL: Must be EC P-256 JWK JSON stored in Vault (NOT raw hex).
edc.transfer.proxy.token.signer.privatekey.alias=provider-transfer-proxy-key
edc.transfer.proxy.token.verifier.publickey.alias=provider-transfer-proxy-key
```

#### Data Plane Properties (provider example)

```properties
###############################################################################
# Data Plane — DCP / IdentityHub Integration
###############################################################################

# Data planes use short names (they don't participate in DCP VP validation)
edc.participant.id=provider

# CRITICAL: Must be the Docker container name so the DP self-registers
# with a hostname reachable from other containers on the network.
edc.hostname=provider-dp

# STS — same pattern, pointing to the provider's own IdentityHub
edc.iam.sts.oauth.token.url=http://provider-ih:9292/api/sts/token
edc.iam.sts.oauth.client.id=did:web:provider-ih:provider
edc.iam.sts.oauth.client.secret.alias=provider-sts-secret

# DCP credential endpoint
edc.iam.sts.dim.url=http://provider-ih:13131/api/credentials

# DID configuration
edc.iam.issuer.id=did:web:provider-ih:provider
edc.iam.did.web.use.https=false

# Transfer proxy key (same key as control plane)
edc.transfer.proxy.token.signer.privatekey.alias=provider-transfer-proxy-key
edc.transfer.proxy.token.verifier.publickey.alias=provider-transfer-proxy-key
```

### Configuration Pitfalls

| Property | Wrong | Right | Consequence |
|----------|-------|-------|-------------|
| `edc.participant.id` (CP) | `provider` | `did:web:provider-ih:provider` | VP audience mismatch — auth fails silently |
| `edc.hostname` (DP) | *(omitted)* | `provider-dp` | DP registers with wrong URL — transfers fail |
| `edc.iam.trusted-issuer...supportedtypes` | `["MembershipCredential","BpnCredential"]` | Include `DataExchangeGovernanceCredential` | Policy evaluation can't find required VC |
| Transfer proxy key | Raw hex string | EC P-256 JWK JSON | EDR tokens are invalid — data pull fails |

### Vault Configuration

Secrets are stored in each company's **own** Vault instance:

```bash
# Store the STS client_secret in the provider's vault
curl -sf -X PUT http://localhost:8201/v1/secret/data/provider-sts-secret \
  -H "X-Vault-Token: root-token" \
  -d '{"data": {"content": "<CLIENT_SECRET_FROM_STEP_1>"}}'

# Store the transfer proxy key (MUST be EC P-256 JWK JSON)
curl -sf -X PUT http://localhost:8201/v1/secret/data/provider-transfer-proxy-key \
  -H "X-Vault-Token: root-token" \
  -d '{"data": {"content": "{\"kty\":\"EC\",\"crv\":\"P-256\",\"x\":\"...\",\"y\":\"...\",\"d\":\"...\",\"kid\":\"provider-transfer-proxy-key\"}"}}'  
```

> **Important**: The transfer proxy key value must be a JSON string containing an EC P-256 JWK.
> Use `jq` to safely construct the payload to avoid JSON escaping issues:
> ```bash
> payload=$(jq -n --arg v "$JWK_JSON" '{"data": {"content": $v}}')
> curl -sf -X PUT "${VAULT_URL}/v1/secret/data/${KEY}" \
>   -H "X-Vault-Token: ${TOKEN}" -d "${payload}"
> ```

### Network Configuration

When using Docker Compose, the EDC connector must be on the same network as its IdentityHub:

```yaml
# In your EDC connector's docker-compose.yaml
services:
  edc-provider:
    # ... your connector config ...
    networks:
      - edc-net

networks:
  edc-net:
    external: true
```

Use **container hostnames** (not `localhost`) in the connector properties.
Each connector points to **its own** IdentityHub:

| Reference (Provider) | URL |
|-----------|-----|
| STS token | `http://provider-ih:9292/api/sts/token` |
| DCP credentials | `http://provider-ih:13131/api/credentials` |
| DID resolution | `http://provider-ih:10100/` |
| Health check | `http://provider-ih:8181/api/check/health` |

| Reference (Consumer) | URL |
|-----------|-----|
| STS token | `http://consumer-ih:9292/api/sts/token` |
| DCP credentials | `http://consumer-ih:13131/api/credentials` |
| DID resolution | `http://consumer-ih:10100/` |
| Health check | `http://consumer-ih:8181/api/check/health` |

---

## 7. Authentication Model

The IdentityHub uses three different authentication mechanisms depending on the API context:

### 7.1 Management API (`x-api-key`)

Used for: Participant CRUD, keypair management, DID management, credential management.

```bash
curl -H "x-api-key: cHJvdmlkZXI=.uZM8DQ7x3nWb..." \
  http://localhost:15151/api/identity/v1alpha/participants/{b64id}/keypairs
```

**API key format**: `base64(<participantContextId>).<randomToken>`

The base64 prefix identifies which participant context the request is scoped to. Participants with the `admin` role (like the super-user) can access cross-participant endpoints.

### 7.2 STS Token Endpoint (`client_id` + `client_secret`)

Used for: Obtaining SI tokens (JWT) for DCP protocol authentication.

```bash
curl -X POST http://localhost:7292/api/sts/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials\
&client_id=did:web:provider-ih:provider\
&client_secret=<SECRET>\
&audience=did:web:consumer-ih:consumer"
```

| Parameter | Value | Notes |
|-----------|-------|-------|
| `grant_type` | `client_credentials` | Only supported grant type |
| `client_id` | The participant's DID | From `createParticipant` response `.clientId` |
| `client_secret` | The participant's secret | From `createParticipant` response `.clientSecret` |
| `audience` | Target party's DID | **Mandatory** — the DID of the connector you want to communicate with |

> **Key point**: The `audience` must be the **target's full DID** (e.g., `did:web:consumer-ih:consumer`).
> The receiving connector validates that its own DID matches the JWT `aud` claim.

**Content-Type must be `application/x-www-form-urlencoded`** (not JSON). Returns HTTP 415 otherwise.

### 7.3 DCP Protocol Endpoints (`Authorization: Bearer <JWT>`)

Used for: Presentation queries, credential offers, credential storage (connector-to-connector).

```bash
curl -X POST http://localhost:13131/api/credentials/v1/participants/{b64id}/presentations/query \
  -H "Authorization: Bearer eyJhbGciOiJFZERTQS..." \
  -H "Content-Type: application/json" \
  -d '{
    "@context": ["https://w3id.org/tractusx-trust/v0.8"],
    "@type": "PresentationQueryMessage",
    "scope": ["org.eclipse.edc.vc.type:MembershipCredential:read"]
  }'
```

The JWT is an SI token obtained from the STS. The IdentityHub:
1. Extracts the `iss` (issuer DID) from the JWT
2. Resolves the issuer's DID document
3. Verifies the JWT signature against the DID document's verification method
4. Checks that the `aud` (audience) matches the target participant's DID

---

## 8. DCP Protocol Flow

### 8.1 Connector Authentication (DSP Protocol)

```mermaid
sequenceDiagram
    participant PC as Provider Connector
    participant PIH as Provider IH (Wallet)
    participant CC as Consumer Connector
    participant CIH as Consumer IH (Wallet)

    PC->>PIH: POST /api/sts/token<br/>(client_id=provider DID,<br/>client_secret, audience=consumer DID)
    PIH-->>PC: { access_token: SI JWT }

    PC->>CC: DSP Request<br/>Authorization: Bearer <SI JWT>
    CC->>PIH: Resolve Provider DID Document<br/>GET /.well-known/did.json
    PIH-->>CC: DID Document (with public key)
    Note over CC: Verify JWT signature<br/>with DID public key
    CC-->>PC: DSP Response
```

<details><summary>ASCII version</summary>

```
┌──────────┐                        ┌──────────────┐                       ┌──────────┐
│ Provider  │                        │  Provider    │                       │ Consumer │
│ Connector │                        │  IH (wallet) │                       │ Connector│
└─────┬─────┘                        └──────┬───────┘                       └────┬─────┘
      │                                     │                                    │
      │ 1. POST /api/sts/token              │                                    │
      │    client_id=<provider DID>         │                                    │
      │    client_secret=<secret>           │                                    │
      │    audience=<consumer DID>          │                                    │
      │────────────────────────────────────▶│                                    │
      │                                     │                                    │
      │ 2. { access_token: <SI JWT> }       │                                    │
      │◀────────────────────────────────────│                                    │
      │                                     │                                    │
      │ 3. DSP Request                      │                                    │
      │    Authorization: Bearer <SI JWT>   │                                    │
      │─────────────────────────────────────┼───────────────────────────────────▶│
      │                                     │                                    │
      │                                     │ 4. Resolve provider DID doc        │
      │                                     │    from provider-ih                │
      │                                     │◀───────────────────────────────────│
      │                                     │                                    │
      │                                     │ 5. DID Document (with public key)  │
      │                                     │───────────────────────────────────▶│
      │                                     │                                    │
      │                                     │              6. Verify JWT         │
      │                                     │              signature with         │
      │                                     │              DID public key         │
      │                                     │                                    │
      │ 7. DSP Response                     │                                    │
      │◀────────────────────────────────────┼────────────────────────────────────│
```
</details>

### 8.2 Credential Presentation (DCP Presentation Query)

When a consumer connector needs to verify the provider's credentials:

```
┌──────────┐                    ┌──────────────┐
│ Consumer  │                    │  Provider    │
│ Connector │                    │  IH (wallet) │
└─────┬─────┘                    └──────┬───────┘
      │                                 │
      │ POST /api/credentials/v1/       │
      │   participants/{b64id}/         │
      │   presentations/query           │
      │ Authorization: Bearer <JWT>     │
      │ Body: PresentationQueryMessage  │
      │────────────────────────────────▶│
      │                                 │
      │ Response: Verifiable            │
      │   Presentation with requested   │
      │   credentials                   │
      │◀────────────────────────────────│
```

### 8.3 Credential Issuance (DCP Credential Request)

When a connector requests a credential from an issuer:

```
┌──────────┐                    ┌───────────────┐
│ Holder    │                    │ IssuerService │
│ Connector │                    │               │
└─────┬─────┘                    └──────┬────────┘
      │                                 │
      │ 1. GET metadata                 │
      │    /api/issuance/v1alpha/       │
      │    participants/{b64}/metadata  │
      │────────────────────────────────▶│
      │                                 │
      │ 2. { issuer, credentialTypes }  │
      │◀────────────────────────────────│
      │                                 │
      │ 3. POST credential request      │
      │    /api/issuance/v1alpha/       │
      │    participants/{b64}/          │
      │    credentials/                 │
      │    Authorization: Bearer <JWT>  │
      │────────────────────────────────▶│
      │                                 │
      │ 4. Credential issued async      │
      │   (stored to holder wallet)     │
      │◀────────────────────────────────│
```

---

## 9. API Reference

### 9.1 Endpoints Used by EDC Connectors

#### STS Token (EDC calls this directly)

```
POST /api/sts/token
Host: provider-ih:9292
Content-Type: application/x-www-form-urlencoded

grant_type=client_credentials
&client_id=did:web:provider-ih:provider
&client_secret=<secret>
&audience=did:web:consumer-ih:consumer
```

**Response (200):**
```json
{
  "access_token": "eyJhbGciOiJFZERTQS...",
  "token_type": "Bearer",
  "expires_in": 300
}
```

#### DID Resolution (other connectors call this to verify JWTs)

```
GET /{participant-path}/did.json
Host: provider-ih:10100
```

Returns the DID document with verification methods (public keys).

**Note**: In local Docker, the DID `did:web:provider-ih:provider` resolves at
`http://provider-ih:10100/provider/did.json` (from inside Docker) or
`http://localhost:7100/provider/did.json` (from the host).
A reverse proxy is needed for production to map the `did:web` host to the IdentityHub DID endpoint.

#### DCP Presentation Query (connector-to-connector via IdentityHub)

```
POST /api/credentials/v1/participants/{base64-participantId}/presentations/query
Host: provider-ih:13131
Authorization: Bearer <SI-JWT>
Content-Type: application/json

{
  "@context": ["https://w3id.org/tractusx-trust/v0.8"],
  "@type": "PresentationQueryMessage",
  "scope": ["org.eclipse.edc.vc.type:MembershipCredential:read"]
}
```

#### DCP Credential Offer (issuer notifies holder)

```
POST /api/credentials/v1/participants/{base64-participantId}/offers
Host: provider-ih:13131
Authorization: Bearer <SI-JWT>
Content-Type: application/json

{
  "@context": ["https://w3id.org/dspace-dcp/v1.0/dcp.jsonld"],
  "type": "CredentialOfferMessage",
  "@id": "offer-123",
  "issuer": "did:web:issuerservice:issuer"
}
```

#### DCP Credential Storage (issuer writes credentials into holder wallet)

```
POST /api/credentials/v1/participants/{base64-participantId}/credentials
Host: provider-ih:13131
Authorization: Bearer <SI-JWT>
Content-Type: application/json

{
  "@context": ["https://w3id.org/dspace-dcp/v1.0/dcp.jsonld"],
  "type": "CredentialMessage",
  "credentials": [
    {
      "credentialType": "MembershipCredential",
      "payload": "<JWT or JSON-LD VC>",
      "format": "jwt"
    }
  ],
  "issuerPid": "did:web:issuerservice:issuer",
  "holderPid": "did:web:provider-ih:provider",
  "status": "ISSUED",
  "requestId": "req-123"
}
```

### 9.2 Management API (Admin/Provisioning)

All management endpoints use the `x-api-key` header. The `{b64id}` path parameter is the **base64 URL-encoded** participant context ID.

| Method | Path | Description |
|--------|------|-------------|
| POST | `/v1alpha/participants` | Create participant |
| GET | `/v1alpha/participants/{b64id}` | Get participant |
| GET | `/v1alpha/participants?offset=0&limit=10` | List all participants |
| DELETE | `/v1alpha/participants/{b64id}` | Delete participant |
| POST | `/v1alpha/participants/{b64id}/state?isActive=true` | Activate/deactivate |
| POST | `/v1alpha/participants/{b64id}/token` | Regenerate API token |
| PUT | `/v1alpha/participants/{b64id}/roles` | Update roles |
| GET | `/v1alpha/participants/{b64id}/keypairs` | List keypairs |
| POST | `/v1alpha/participants/{b64id}/keypairs/{id}/rotate` | Rotate keypair |
| POST | `/v1alpha/participants/{b64id}/dids/query` | Query DIDs |
| POST | `/v1alpha/participants/{b64id}/dids/publish` | Publish DID |
| POST | `/v1alpha/participants/{b64id}/dids/unpublish` | Unpublish DID |
| GET | `/v1alpha/participants/{b64id}/credentials` | List credentials |

### 9.3 Health / Observability

```
GET /api/check/health     → System health (vault + runtime)
GET /api/check/readiness  → Kubernetes readiness probe
GET /api/check/startup    → Kubernetes startup probe
GET /api/check/liveness   → Kubernetes liveness probe
GET /api/v1/version       → API version info
```

---

## 10. End-to-End Walkthrough

This walkthrough sets up two EDC connectors ("provider" and "consumer"), each with its
**own** IdentityHub instance, plus a shared IssuerService for credential issuance.

> **Recommended**: Use the automated `bootstrap.sh` script in `tractusx-edc/deployment/local/scripts/`
> instead of running these steps manually. The script handles all 16 steps including
> credential issuance, BDRS seeding, and E2E verification.

### Step 1: Build and Deploy

```bash
# Build IdentityHub JARs
cd tractusx-identityhub
./gradlew :runtimes:identityhub:shadowJar :runtimes:issuerservice:shadowJar

# Build EDC connector JARs
cd tractusx-edc
./gradlew shadowJar

# Start all 14 containers
cd deployment/local
docker compose up --build -d
```

### Step 2: Create Connector Identities (in separate IH instances)

```bash
SUPERUSER_KEY="c3VwZXItdXNlcg==.superuserkey"

# Create "provider" in provider-ih (port 7151)
PROVIDER_RESP=$(curl -s -X POST http://localhost:7151/api/identity/v1alpha/participants \
  -H "x-api-key: ${SUPERUSER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "participantContextId": "provider",
    "did": "did:web:provider-ih:provider",
    "active": true,
    "key": {
      "keyId": "provider-key",
      "privateKeyAlias": "provider-alias",
      "keyGeneratorParams": { "algorithm": "EdDSA", "curve": "Ed25519" }
    },
    "roles": []
  }')
echo "$PROVIDER_RESP" | jq .

PROVIDER_CLIENT_ID=$(echo "$PROVIDER_RESP" | jq -r '.clientId')
PROVIDER_CLIENT_SECRET=$(echo "$PROVIDER_RESP" | jq -r '.clientSecret')

# Create "consumer" in consumer-ih (port 8152)
CONSUMER_RESP=$(curl -s -X POST http://localhost:8152/api/identity/v1alpha/participants \
  -H "x-api-key: ${SUPERUSER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "participantContextId": "consumer",
    "did": "did:web:consumer-ih:consumer",
    "active": true,
    "key": {
      "keyId": "consumer-key",
      "privateKeyAlias": "consumer-alias",
      "keyGeneratorParams": { "algorithm": "EdDSA", "curve": "Ed25519" }
    },
    "roles": []
  }')
echo "$CONSUMER_RESP" | jq .

CONSUMER_CLIENT_ID=$(echo "$CONSUMER_RESP" | jq -r '.clientId')
CONSUMER_CLIENT_SECRET=$(echo "$CONSUMER_RESP" | jq -r '.clientSecret')
```

### Step 3: Store Secrets in Per-Company Vaults

```bash
# Provider vault (port 8201)
# STS secret
payload=$(jq -n --arg v "$PROVIDER_CLIENT_SECRET" '{"data": {"content": $v}}')
curl -sf -X PUT http://localhost:8201/v1/secret/data/provider-sts-secret \
  -H "X-Vault-Token: root-token" -d "${payload}"

# Transfer proxy key (EC P-256 JWK — MUST be JSON, not hex)
PROVIDER_JWK='{"kty":"EC","crv":"P-256","x":"Wpd-wxJHzg88SJI_6zE4S6EPwQiuosxvE_XI4n5dWWQ","y":"kd2DdngBbh3eBC2TYrTnz2mUF35UoXGl2Bg-85E_bPg","d":"9SZ3iNHpAWy6L_L6AuTqXEzkUI8rdT5Q9dDfHexMcZk","kid":"provider-transfer-proxy-key"}'
payload=$(jq -n --arg v "$PROVIDER_JWK" '{"data": {"content": $v}}')
curl -sf -X PUT http://localhost:8201/v1/secret/data/provider-transfer-proxy-key \
  -H "X-Vault-Token: root-token" -d "${payload}"

# Consumer vault (port 8202) — same pattern
payload=$(jq -n --arg v "$CONSUMER_CLIENT_SECRET" '{"data": {"content": $v}}')
curl -sf -X PUT http://localhost:8202/v1/secret/data/consumer-sts-secret \
  -H "X-Vault-Token: root-token" -d "${payload}"

CONSUMER_JWK='{"kty":"EC","crv":"P-256","x":"SUOwtseJYUQCjNeyKBqanO8xGSASjkg4CCH9XV4OTVs","y":"dow1nRS_daCoSL4sRYq6rDgwuzt4CuANHV3H6RQKdR4","d":"2gtOy54Scdo57JS1QtOzNr1B8phVPuDalaynKAb7Urs","kid":"consumer-transfer-proxy-key"}'
payload=$(jq -n --arg v "$CONSUMER_JWK" '{"data": {"content": $v}}')
curl -sf -X PUT http://localhost:8202/v1/secret/data/consumer-transfer-proxy-key \
  -H "X-Vault-Token: root-token" -d "${payload}"
```

### Step 4: Configure EDC Connectors

See [Section 6](#6-edc-connector-configuration) for the full property reference.

**Key points**:
- `edc.participant.id` on CPs **must** be the full DID (e.g., `did:web:provider-ih:provider`)
- `edc.hostname` on DPs **must** be the Docker container name (e.g., `provider-dp`)
- STS URLs point to the company's **own** IdentityHub
- `edc.iam.trusted-issuer.issuer.supportedtypes` must include `DataExchangeGovernanceCredential`

### Step 5: Issue Credentials and Run E2E Test

The remaining steps (credential issuance, BDRS seeding, catalog, negotiation, transfer)
are automated in the bootstrap script:

```bash
cd tractusx-edc/deployment/local/scripts
chmod +x bootstrap.sh test-transfer.sh

# Full bootstrap (Steps 0-16)
./bootstrap.sh

# Or run just the E2E transfer test (on an already-bootstrapped deployment)
./test-transfer.sh
```

### Step 6: Verify STS Token Contents

```bash
TOKEN=$(curl -s -X POST http://localhost:7292/api/sts/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials\
&client_id=${PROVIDER_CLIENT_ID}\
&client_secret=${PROVIDER_CLIENT_SECRET}\
&audience=did:web:consumer-ih:consumer" | jq -r '.access_token')

# Decode JWT payload
echo "$TOKEN" | cut -d'.' -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq .
```

Expected payload:
```json
{
  "iss": "did:web:provider-ih:provider",
  "sub": "did:web:provider-ih:provider",
  "aud": "did:web:consumer-ih:consumer",
  "jti": "unique-id",
  "iat": 1741300000,
  "exp": 1741300300
}
```

### Contract Negotiation — JSON-LD Pitfalls

When negotiating contracts via the management API, the JSON-LD format is critical:

```json
{
  "@context": {"odrl": "http://www.w3.org/ns/odrl/2/"},
  "@type": "NegotiationInitiateRequestDto",
  "counterPartyAddress": "http://provider-cp:8084/api/v1/dsp",
  "counterPartyId": "did:web:provider-ih:provider",
  "protocol": "dataspace-protocol-http",
  "policy": {
    "@type": "odrl:Offer",
    "@id": "<OFFER_ID_FROM_CATALOG>",
    "odrl:assigner": {"@id": "BPNL000000000001"},
    "odrl:permission": [{
      "odrl:action": {"@id": "odrl:use"},
      "odrl:constraint": {
        "odrl:and": [
          {
            "odrl:leftOperand": {"@id": "https://w3id.org/catenax/2025/9/policy/FrameworkAgreement"},
            "odrl:operator": {"@id": "odrl:eq"},
            "odrl:rightOperand": "DataExchangeGovernance:1.0"
          },
          {
            "odrl:leftOperand": {"@id": "https://w3id.org/catenax/2025/9/policy/UsagePurpose"},
            "odrl:operator": {"@id": "odrl:eq"},
            "odrl:rightOperand": "cx.core.industrycore:1"
          }
        ]
      }
    }]
  }
}
```

**Critical format rules**:
- `odrl:assigner`: Must be the provider's **BPN** (not DID)
- `odrl:action`: Must be `{"@id": "odrl:use"}` (not bare `"use"`) — ensures full IRI expansion for policy comparison
- `odrl:leftOperand`: Must use **full IRIs** wrapped in `{"@id": "..."}` — compact IRIs like `cx-policy:FrameworkAgreement` cause `IRI_CONFUSED_WITH_PREFIX` errors

---

## 11. Kubernetes / Helm Deployment

### Helm Charts

| Chart | Description |
|-------|-------------|
| `charts/tractusx-identityhub` | Production deployment (PostgreSQL + Vault) |
| `charts/tractusx-identityhub-memory` | Development deployment (in-memory) |
| `charts/tractusx-issuerservice` | IssuerService (PostgreSQL + Vault) |
| `charts/tractusx-issuerservice-memory` | IssuerService (in-memory) |

### Install IdentityHub

```bash
helm install identityhub charts/tractusx-identityhub \
  --set identityhub.image.repository=<your-registry>/identityhub \
  --set identityhub.image.tag=latest \
  --set postgresql.auth.password=<db-password> \
  --set vault.server.dev.devRootToken=<vault-token>
```

### Helm Values for EDC Integration

Key values to configure in the IdentityHub Helm chart:

```yaml
identityhub:
  endpoints:
    identity:
      port: 8082
      path: /api/identity
      authKeyAlias: "your-super-user-api-key"
    credentials:
      port: 8083
      path: /api/credentials
    did:
      port: 8084
      path: /
    sts:
      port: 8087
      path: /api/sts

  # Public-facing ingresses for DCP protocol
  ingresses:
    - enabled: true
      hostname: "identityhub.your-domain.com"
      endpoints:
        - credentials   # DCP presentation queries
        - did            # DID document resolution
        - sts            # STS token endpoint
      tls:
        enabled: true
```

### Ingress Configuration

For production, you need **two ingress resources**:

1. **Public ingress** (internet-facing) for DCP protocol:
   - DID resolution (`did:web` must be publicly resolvable)
   - DCP credentials (presentation queries from other connectors)
   - STS token endpoint

2. **Internal ingress** (not internet-facing) for management:
   - Identity management API (participant CRUD)

---

## 12. Troubleshooting

### Common Issues

#### 1. STS returns 415 Unsupported Media Type

**Cause**: Sending JSON instead of form-encoded data.

**Fix**: Use `Content-Type: application/x-www-form-urlencoded` and form-encode the body.

#### 2. STS returns 401 Unauthorized

**Cause**: Invalid `client_id` or `client_secret`.

**Fix**: Verify `client_id` matches the participant's DID (from `createParticipant` response `.clientId`) and `client_secret` matches `.clientSecret` (not the `apiKey`).

#### 3. "audience cannot be null"

**Cause**: Missing `audience` parameter in STS token request.

**Fix**: Always include `audience=<target-did>` in the STS request.

#### 4. VP Audience Mismatch ("Token audience claim did not contain expected audience")

**Cause**: `edc.participant.id` is set to a short name (e.g., `provider`) on a control plane. The JWT `aud` claim contains the full DID, but the CP tries to match it against the short name.

**Fix**: Set `edc.participant.id` to the **full DID** on control planes:
```properties
edc.participant.id=did:web:provider-ih:provider
```

#### 5. Policy Not Fulfilled / Contract Negotiation Rejected

Multiple possible causes:

**a) Assigner mismatch**: Using the provider's DID as `odrl:assigner` instead of its BPN.
- **Fix**: Use `"odrl:assigner": {"@id": "BPNL000000000001"}`

**b) Action type mismatch**: Using `"odrl:action": "use"` (short string) instead of the IRI form.
- **Fix**: Use `"odrl:action": {"@id": "odrl:use"}`

**c) Missing DataExchangeGovernanceCredential**: The trusted issuer types don't include it.
- **Fix**: Add it to `edc.iam.trusted-issuer.issuer.supportedtypes`

#### 6. IRI_CONFUSED_WITH_PREFIX Error

**Cause**: Using compact IRIs like `cx-policy:FrameworkAgreement` in policy `leftOperand`. The `cx-policy` prefix is mapped to different namespace URLs in different scopes.

**Fix**: Always use **full IRIs** for `leftOperand`:
```json
"odrl:leftOperand": {"@id": "https://w3id.org/catenax/2025/9/policy/FrameworkAgreement"}
```

#### 7. Transfer Fails / EDR Token Invalid

**Cause**: Transfer proxy key stored in Vault as raw hex string instead of EC P-256 JWK JSON.

**Fix**: Store the key as a proper JWK:
```json
{"kty":"EC","crv":"P-256","x":"...","y":"...","d":"...","kid":"provider-transfer-proxy-key"}
```

#### 8. Data Plane Registers with Wrong URL

**Cause**: `edc.hostname` not set on data planes. The DP self-registers with the container's internal hostname or `localhost`.

**Fix**: Set `edc.hostname` to the Docker container name:
```properties
edc.hostname=provider-dp
```

#### 9. HTTP 500 "No configuration found for participant context"

**Cause**: The in-memory `ParticipantContextConfigStore` lost its entries after a container restart.

**Fix**: This is handled automatically by the `SuperUserSeedExtension` which restores all participant configs on startup. If you see this error, check that the seed extension is loaded (look for `SuperUserSeedExtension` in startup logs).

#### 10. DID resolution returns 204 (empty) in local dev

**Cause**: The `did:web` parser includes the host and port in the DID identifier. The URL `http://localhost:7100/provider/did.json` resolves to `did:web:localhost%3A7100:provider`, but the stored DID is `did:web:provider-ih:provider`.

**Fix**: For local development, access the DID endpoint via the container hostname: `http://provider-ih:10100/provider/did.json`. For production, configure a reverse proxy so the DID URL domain matches the `did:web` identifier.

#### 11. Management API returns 401

**Cause**: Missing or malformed `x-api-key` header.

**Fix**: The API key format is `base64(<participantContextId>).<randomToken>`. The super-user key is `c3VwZXItdXNlcg==.superuserkey`. For other participants, use the key from the `createParticipant` response.

#### 7. Connector can't reach IdentityHub

**Cause**: Not on the same Docker network.

**Fix**: Ensure both the connector and IdentityHub are on the `edc-net` network:

```bash
docker network create edc-net  # if not already created
# Add to docker-compose.yaml: networks: edc-net: external: true
```

### Health Check Commands

```bash
# Provider IdentityHub health
curl http://localhost:7181/api/check/health | jq .

# Consumer IdentityHub health
curl http://localhost:8182/api/check/health | jq .

# IssuerService health
curl http://localhost:18181/api/check/health | jq .

# Database connectivity
docker exec provider-postgres pg_isready -U postgres
docker exec consumer-postgres pg_isready -U postgres

# Vault status
curl http://localhost:8201/v1/sys/health | jq .  # provider vault
curl http://localhost:8202/v1/sys/health | jq .  # consumer vault

# List all participants in provider-ih
curl -H "x-api-key: c3VwZXItdXNlcg==.superuserkey" \
  http://localhost:7151/api/identity/v1alpha/participants?offset=0&limit=50 | jq .
```

### Docker Logs

```bash
docker logs provider-ih 2>&1 | tail -100
docker logs consumer-ih 2>&1 | tail -100
docker logs provider-cp 2>&1 | tail -100
docker logs consumer-cp 2>&1 | tail -100
docker logs issuerservice 2>&1 | tail -100
```

---

## Quick Reference Card

```
┌─────────────────────────────────────────────────────────────────┐
│              EDC ↔ IdentityHub Quick Reference                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Architecture: Per-company IH (provider-ih, consumer-ih)        │
│                                                                 │
│  Create Participant (in company's own IH):                      │
│    POST provider-ih:15151/api/identity/v1alpha/participants      │
│    Auth: x-api-key: <super-user-key>                            │
│    Returns: { apiKey, clientId, clientSecret }                  │
│                                                                 │
│  Get SI Token (from company's own IH):                          │
│    POST provider-ih:9292/api/sts/token                          │
│    Content-Type: application/x-www-form-urlencoded              │
│    Body: grant_type=client_credentials                          │
│          &client_id=did:web:provider-ih:provider                │
│          &client_secret=<secret>                                │
│          &audience=did:web:consumer-ih:consumer                 │
│    Returns: { access_token, token_type, expires_in }            │
│                                                                 │
│  Resolve DID:                                                   │
│    GET provider-ih:10100/provider/did.json                       │
│                                                                 │
│  DCP Presentation Query:                                        │
│    POST provider-ih:13131/api/credentials/v1/                   │
│         participants/<b64id>/presentations/query                │
│    Auth: Authorization: Bearer <SI-token>                       │
│                                                                 │
│  EDC Control Plane Properties (CRITICAL):                       │
│    edc.participant.id=did:web:provider-ih:provider (FULL DID!)  │
│    edc.participant.context.id=provider                          │
│    edc.iam.sts.oauth.token.url=http://provider-ih:9292/...     │
│    edc.iam.sts.oauth.client.id=did:web:provider-ih:provider    │
│    edc.iam.sts.oauth.client.secret.alias=<vault-alias>         │
│    edc.iam.sts.dim.url=http://provider-ih:13131/...            │
│    edc.iam.trusted-issuer...supportedtypes=                    │
│      ["MembershipCredential","BpnCredential",                  │
│       "DataExchangeGovernanceCredential"]                       │
│                                                                 │
│  EDC Data Plane Properties (CRITICAL):                          │
│    edc.hostname=provider-dp  (Docker container name!)           │
│    Transfer proxy key = EC P-256 JWK JSON in Vault              │
│                                                                 │
│  Contract Negotiation (CRITICAL):                               │
│    odrl:assigner = Provider BPN (not DID!)                      │
│    odrl:action = {"@id": "odrl:use"} (not bare "use")          │
│    odrl:leftOperand = full IRI in {"@id": "https://..."}       │
│                                                                 │
│  Super-User Key: c3VwZXItdXNlcg==.superuserkey                 │
│  Provider IH Health: GET provider-ih:8181/api/check/health      │
│  Consumer IH Health: GET consumer-ih:8181/api/check/health      │
│                                                                 │
│  Bootstrap: tractusx-edc/deployment/local/scripts/bootstrap.sh  │
│  E2E Test:  tractusx-edc/deployment/local/scripts/test-transfer │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

# NOTICE

This work is licensed under the [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/legalcode).

* SPDX-License-Identifier: CC-BY-4.0
* SPDX-FileCopyrightText: 2025 Contributors to the Eclipse Foundation
* Source URL: https://github.com/eclipse-tractusx/tractusx-identityhub
