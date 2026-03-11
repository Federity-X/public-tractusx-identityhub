# EDC 0.14.0 → 0.15.1 Upgrade: Complete List of Fixes

**Issue**: [#198](https://github.com/eclipse-tractusx/tractusx-identityhub/issues/198)
**Branch**: `edc-integration`
**Date**: March 2026

---

## Summary

Upgrading tractusx-identityhub from EDC 0.14.0 to 0.15.1 required **14 distinct fixes** across build configuration, database migrations, Java code, Docker deployment, and runtime behavior. This document catalogs every fix applied, its root cause, and the affected files.

| Category | Fixes | Severity |
|----------|-------|----------|
| Build System | 4 | HIGH |
| Database Migrations | 6 | HIGH |
| Java Code (Runtime Bugs) | 3 | CRITICAL |
| Docker/Deployment | 1 | MEDIUM |

---

## Fix 1: Shadow Plugin Migration

**Severity**: HIGH — Build fails entirely without this fix
**Root Cause**: The old Shadow plugin (`com.github.johnrengelman.shadow:8.1.1`) is incompatible with Gradle 9.x, which is required by edc-build 1.1.6.

**Change**: Migrated to the maintained fork `com.gradleup.shadow:9.3.1`.

**Files Changed**:
- `gradle/libs.versions.toml` — Plugin ID and version
  ```diff
  - shadow = { id = "com.github.johnrengelman.shadow", version = "8.1.1" }
  + shadow = { id = "com.gradleup.shadow", version = "9.3.1" }
  ```
- `build.gradle.kts` — Plugin reference and task naming
  ```diff
  - import com.github.jengelman.gradle.plugins.shadow.ShadowJavaPlugin
  - hasPlugin("com.github.johnrengelman.shadow")
  - tasks.named(ShadowJavaPlugin.SHADOW_JAR_TASK_NAME)
  + hasPlugin(libs.plugins.shadow.get().pluginId)
  + tasks.named("shadowJar")
  ```

---

## Fix 2: Shadow JAR `mergeServiceFiles()` Configuration

**Severity**: HIGH — Runtime crashes with missing EDC extensions
**Root Cause**: Without `mergeServiceFiles()`, the Shadow plugin overwrites `META-INF/services/` files instead of merging them. This causes the EDC runtime to silently miss service extensions (e.g., Flyway migrators, Vault extensions, SQL stores), leading to empty databases, missing tables, and 500 errors.

**Change**: Added `mergeServiceFiles()` to all four runtime `shadowJar` tasks.

**Files Changed**:
- `runtimes/identityhub/build.gradle.kts`
- `runtimes/identityhub-memory/build.gradle.kts`
- `runtimes/issuerservice/build.gradle.kts`
- `runtimes/issuerservice-memory/build.gradle.kts`

```kotlin
tasks.shadowJar {
    mergeServiceFiles()
    // ...
}
```

---

## Fix 3: Gradle 9.x API Compatibility

**Severity**: HIGH — Build fails without these changes
**Root Cause**: Gradle 9.x removed/deprecated several APIs used in `build.gradle.kts`.

**Changes**:
- `tasks.create(...)` → `tasks.register(...)` (lazy task configuration)
- Plugin reference updated (see Fix 1)
- Gradle wrapper upgraded from 8.12 to 9.3.1 via `./gradlew wrapper --gradle-version=9.3.1`

**Files Changed**:
- `build.gradle.kts`
- `gradle/wrapper/gradle-wrapper.properties`

---

## Fix 4: EDC Version and Build Plugin Updates

**Severity**: HIGH — Required for all other fixes
**Root Cause**: Direct dependency version bumps.

**Files Changed**:
- `gradle/libs.versions.toml`
  ```diff
  - edc = "0.14.0"
  + edc = "0.15.1"
  - edc-build = "1.0.0"
  + edc-build = "1.1.6"
  ```

---

## Fix 5: `participantId` → `participantContextId` API Rename

**Severity**: HIGH — Compilation fails without this fix
**Root Cause**: EDC 0.15.1 renamed the `participantId` field to `participantContextId` across all participant-related SPIs and APIs (upstream PR #845).

**Change**: Updated the `ParticipantManifest.Builder` call in the SuperUser seed extension.

**Files Changed**:
- `extensions/seed/super-user/src/main/java/.../SuperUserSeedExtension.java`
  ```diff
  - .participantId(superUserParticipantId)
  + .participantContextId(superUserParticipantId)
  ```

---

## Fix 6: Flyway V0_0_2 Database Migrations (6 scripts)

**Severity**: HIGH — Runtime crashes with schema mismatches
**Root Cause**: EDC 0.15.1 changed multiple database schemas. Without migration scripts, the runtime fails at startup when Flyway detects mismatches or when queries reference nonexistent columns.

### 6a. `credential_resource` — New `usage` Column

```sql
ALTER TABLE credential_resource
    ADD COLUMN IF NOT EXISTS usage VARCHAR NOT NULL DEFAULT 'holder';
```

**File**: `extensions/store/sql/migrations/.../credentials/V0_0_2__Add_Usage_Column.sql`

### 6b. `keypair_resource` — New `usage` Column

```sql
ALTER TABLE keypair_resource
    ADD COLUMN IF NOT EXISTS usage VARCHAR NOT NULL DEFAULT '';
```

**File**: `extensions/store/sql/migrations/.../keypair/V0_0_2__Add_Usage_Column.sql`

### 6c. `edc_sts_client` — Schema Restructuring

EDC 0.15.1 added `participant_context_id` and removed `private_key_alias` / `public_key_reference`.

```sql
ALTER TABLE edc_sts_client ADD COLUMN IF NOT EXISTS participant_context_id VARCHAR;
ALTER TABLE edc_sts_client DROP COLUMN IF EXISTS private_key_alias;
ALTER TABLE edc_sts_client DROP COLUMN IF EXISTS public_key_reference;
```

**File**: `extensions/store/sql/migrations/.../stsclient/V0_0_2__Update_Schema_For_EDC_0_15_1.sql`

> **Warning**: The dropped columns (`private_key_alias`, `public_key_reference`) are permanently removed.

### 6d. `holders` — New `anonymous` and `properties` Columns

```sql
ALTER TABLE holders ADD COLUMN IF NOT EXISTS anonymous BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE holders ADD COLUMN IF NOT EXISTS properties JSON DEFAULT '{}';
```

**File**: `extensions/store/sql/migrations/.../holder/V0_0_2__Add_Anonymous_And_Properties.sql`

### 6e. `edc_lease` (credentialrequest) — Primary Key Redesign

The lease table was redesigned from a single `lease_id` FK to a composite PK `(resource_id, resource_kind)`. This required dropping FK constraints from dependent tables and recreating the lease table.

```sql
ALTER TABLE edc_credential_offers DROP CONSTRAINT IF EXISTS edc_credential_offers_lease_id_fkey;
ALTER TABLE edc_credential_offers DROP COLUMN IF EXISTS lease_id;
ALTER TABLE edc_holder_credentialrequest DROP CONSTRAINT IF EXISTS edc_holder_credentialrequest_lease_id_fkey;
ALTER TABLE edc_holder_credentialrequest DROP COLUMN IF EXISTS lease_id;

DROP TABLE IF EXISTS edc_lease CASCADE;
CREATE TABLE IF NOT EXISTS edc_lease (
    resource_id    VARCHAR NOT NULL,
    resource_kind  VARCHAR NOT NULL,
    leased_by      VARCHAR NOT NULL,
    leased_at      BIGINT,
    lease_duration INTEGER NOT NULL DEFAULT 60000,
    PRIMARY KEY (resource_id, resource_kind)
);
```

**File**: `extensions/store/sql/migrations/.../credentialrequest/V0_0_2__Update_Lease_Schema.sql`

> **Warning**: Destructive migration — all existing lease data is dropped.

### 6f. `edc_lease` (issuanceprocess) — Primary Key Redesign

Same redesign as 6e, applied to the issuance process subsystem.

```sql
ALTER TABLE edc_issuance_process DROP CONSTRAINT IF EXISTS edc_issuance_process_lease_id_fkey;
ALTER TABLE edc_issuance_process DROP COLUMN IF EXISTS lease_id;

DROP TABLE IF EXISTS edc_lease CASCADE;
CREATE TABLE IF NOT EXISTS edc_lease (
    resource_id    VARCHAR NOT NULL,
    resource_kind  VARCHAR NOT NULL,
    leased_by      VARCHAR NOT NULL,
    leased_at      BIGINT,
    lease_duration INTEGER NOT NULL DEFAULT 60000,
    PRIMARY KEY (resource_id, resource_kind)
);
```

**File**: `extensions/store/sql/migrations/.../issuanceprocess/V0_0_2__Update_Lease_Schema.sql`

> **Note**: Both 6e and 6f use separate Flyway subsystems, so they run independently and both create the same `edc_lease` table. The second `CREATE TABLE IF NOT EXISTS` is a no-op.

---

## Fix 7: V0_0_1 Migration — Foreign Key Conflict with `edc_lease`

**Severity**: HIGH — Fresh database creation fails
**Root Cause**: The V0_0_1 migration scripts for `credentialrequest` and `issuanceprocess` both try to `CREATE TABLE edc_lease` with incompatible schemas. Since they share the same `edc_lease` table name but run in separate Flyway subsystems, the second one fails if the first already created the table with different FK dependencies.

**Change**: Added `DROP TABLE IF EXISTS edc_lease CASCADE;` before the `CREATE TABLE` in the V0_0_1 init scripts, and updated FK constraints to use `IF NOT EXISTS` patterns.

**Files Changed**:
- `extensions/store/sql/migrations/.../credentialrequest/V0_0_1__Init_CredentialRequest_and_Offers.sql`
- `extensions/store/sql/migrations/.../issuanceprocess/V0_0_1__Init_IssuanceProcess.sql`

---

## Fix 8: `ParticipantContextConfig` Persistence — Super-User (Critical)

**Severity**: CRITICAL — All authenticated API calls return HTTP 500 after container restart
**Root Cause**: EDC 0.15.1 introduced a new `ParticipantContextConfigStore` for per-participant vault configuration. However, only an **in-memory implementation** exists (no SQL store). On container restart, all config entries are lost while participant contexts persist in PostgreSQL. This causes:

```
org.eclipse.edc.spi.EdcException: No configuration found for participant context <id>
```

Any API call that touches the vault (authentication, token regeneration, deletion, credential operations) fails with HTTP 500.

**Change**: Added `ensureConfigExists()` method to `SuperUserSeedExtension` that re-creates the in-memory `ParticipantContextConfiguration` entry for the super-user when the participant already exists in the database but has no config entry.

**Files Changed**:
- `extensions/seed/super-user/src/main/java/.../SuperUserSeedExtension.java` — New `ensureConfigExists()` method
- `extensions/seed/super-user/build.gradle.kts` — Added `edc-ih-participant-context-config-spi` dependency

---

## Fix 9: `ParticipantContextConfig` Persistence — All Participants (Critical)

**Severity**: CRITICAL — Same as Fix 8, but for ALL non-super-user participants
**Root Cause**: Fix 8 only restored the config for the super-user. All other participants (e.g., "provider", "consumer" created via the API) still lost their config entries on restart, causing:

- `DELETE /participants/{id}` → HTTP 500
- `POST /participants/{id}/token` (regen) → HTTP 500
- Any vault-dependent operation → HTTP 500

**Change**: Added `restoreAllParticipantConfigs()` method that queries ALL participant contexts from PostgreSQL on startup and re-creates missing in-memory config entries.

```java
private void restoreAllParticipantConfigs() {
    participantContextService.query(QuerySpec.max())
        .onSuccess(participants -> {
            for (var pc : participants) {
                var id = pc.getParticipantContextId();
                if (participantContextConfigService.get(id).failed()) {
                    var cfg = ParticipantContextConfiguration.Builder.newInstance()
                            .participantContextId(id).build();
                    participantContextConfigService.save(cfg);
                }
            }
        });
}
```

**Files Changed**:
- `extensions/seed/super-user/src/main/java/.../SuperUserSeedExtension.java` — New `restoreAllParticipantConfigs()` method, added `QuerySpec` import

---

## Fix 10: Super-User API Key Vault Persistence

**Severity**: HIGH — Super-user authentication fails after restart with non-persistent vault
**Root Cause**: When using HashiCorp Vault in dev mode (or any non-persistent vault backend), the API key secret is lost on container restart. The super-user participant context persists in PostgreSQL, so `ensureConfigExists()` (Fix 8) restores the config, but the API key in the vault is gone. This causes a `NullPointerException` in `ServicePrincipal.getCredential()` during authentication.

**Change**: Added `ensureApiKeyInVault()` method that stores the configured super-user API key override (`edc.ih.api.superuser.key`) back into the vault on startup if it's missing or stale.

**Files Changed**:
- `extensions/seed/super-user/src/main/java/.../SuperUserSeedExtension.java` — New `ensureApiKeyInVault()` method

---

## Fix 11: Missing Datasource Configurations

**Severity**: HIGH — Flyway migrations fail, tables not created
**Root Cause**: EDC 0.15.1 requires datasource configuration for several new stores that didn't exist in 0.14.0. Without these, Flyway migrations for the corresponding subsystems silently fail, and the tables are never created.

**Change**: Added datasource entries for all required subsystems in both IdentityHub and IssuerService properties files.

**New datasource entries added**:
| Datasource | Used By |
|------------|---------|
| `edc.datasource.attestationdefinitions.*` | Attestation definitions store |
| `edc.datasource.credentialdefinitions.*` | Credential definitions store |
| `edc.datasource.credentialrequest.*` | Credential request store |
| `edc.datasource.holder.*` | Holder store |
| `edc.datasource.issuanceprocess.*` | Issuance process store |
| `edc.datasource.jti.*` | JTI validation store |

Each requires `url`, `user`, and `password` properties pointing to the PostgreSQL instance.

**Files Changed**:
- `deployment/local/config/identityhub.properties`
- `deployment/local/config/issuerservice.properties`

---

## Fix 12: Local Docker Deployment (docker-compose)

**Severity**: MEDIUM — No local development environment without this
**Root Cause**: No Docker Compose configuration existed for running the full stack locally.

**Change**: Created a complete local deployment setup with 4 containers on a shared Docker network (`edc-net`) for future EDC connector integration.

**Files Created**:
| File | Purpose |
|------|---------|
| `deployment/local/docker-compose.yaml` | 4-container stack (IdentityHub, IssuerService, PostgreSQL, Vault) |
| `deployment/local/config/identityhub.properties` | Full runtime configuration (154 lines) |
| `deployment/local/config/issuerservice.properties` | Full runtime configuration (172 lines) |
| `deployment/local/config/logging.properties` | JDK logger configuration |
| `deployment/local/test-wallet-api.sh` | Comprehensive 68-test validation script |

**Container Configuration**:
| Container | Ports | Purpose |
|-----------|-------|---------|
| `identityhub` | 8181, 15151, 10100, 13131, 9292 | DCP Wallet (holder-side) |
| `issuerservice` | 18181, 15152, 18100, 13132, 18292, 19999 | DCP Issuer |
| `ih-postgres` | 5432 | PostgreSQL 16-alpine |
| `ih-vault` | 8200 | HashiCorp Vault 1.15 (dev mode) |

---

## Fix 13: Checkstyle Import Ordering

**Severity**: LOW — Build fails on checkstyle validation
**Root Cause**: edc-build 1.1.6 enforces a stricter `CustomImportOrder` rule. The required order is:

1. `THIRD_PARTY_PACKAGE` (all non-JDK imports)
2. `STANDARD_JAVA_PACKAGE` (`java.*`, `javax.*`)
3. `STATIC` (static imports)

Each group separated by a blank line.

**Files Changed**: All `.java` files with imports that violated the new order — primarily `SuperUserSeedExtension.java`.

---

## Fix 14: `participant-context-config-spi` Dependency

**Severity**: HIGH — Compilation fails
**Root Cause**: The `ParticipantContextConfigService` and `ParticipantContextConfiguration` classes used in Fixes 8/9/10 are in a new SPI module that didn't exist in EDC 0.14.0 and was not yet referenced by the seed extension.

**Change**: Added the dependency to the super-user seed extension build file.

**Files Changed**:
- `extensions/seed/super-user/build.gradle.kts`
  ```kotlin
  dependencies {
      implementation(libs.edc.ih.spi)
      implementation(libs.edc.ih.participant.context.config.spi) // NEW
  }
  ```
- `gradle/libs.versions.toml`
  ```toml
  edc-ih-participant-context-config-spi = { module = "org.eclipse.edc:participant-context-config-spi", version.ref = "edc" }
  ```

---

## Verification

All fixes were validated with the comprehensive test script (`deployment/local/test-wallet-api.sh`):

```
Passed:   68
Warnings: 1
Failed:   0
```

The test covers:
- Health/observability (8 endpoints)
- Version APIs (2 endpoints)
- Super-user context management
- Participant CRUD (create, get, delete, activate/deactivate)
- Keypair management (own + admin)
- DID management (query, state, publish/unpublish)
- DID resolution (did:web)
- Credential management
- STS token endpoint (OAuth2 client_credentials flow)
- DCP holder-side protocol (presentations, offers, credentials)
- DCP issuer-side protocol (metadata, credential request, status)
- IssuerService admin API (holders, attestations, credential definitions, issuance processes)
- Token regeneration
- **JWT SI token validation** (iss, sub, aud claims verified)
- **Restart resilience** (configs + API keys survive container restart)
- Cleanup (full teardown)

---

## Files Changed (Complete List)

| File | Type of Change |
|------|---------------|
| `gradle/libs.versions.toml` | Version bumps, new dependency entries, shadow plugin migration |
| `gradle/wrapper/gradle-wrapper.properties` | Gradle 8.12 → 9.3.1 |
| `build.gradle.kts` | Shadow plugin references, Gradle 9.x API compatibility |
| `runtimes/identityhub/build.gradle.kts` | `mergeServiceFiles()` |
| `runtimes/identityhub-memory/build.gradle.kts` | `mergeServiceFiles()` |
| `runtimes/issuerservice/build.gradle.kts` | `mergeServiceFiles()` |
| `runtimes/issuerservice-memory/build.gradle.kts` | `mergeServiceFiles()` |
| `extensions/seed/super-user/build.gradle.kts` | New config SPI dependency |
| `extensions/seed/super-user/.../SuperUserSeedExtension.java` | `participantContextId()`, `ensureConfigExists()`, `ensureApiKeyInVault()`, `restoreAllParticipantConfigs()` |
| `extensions/store/sql/migrations/.../credentials/V0_0_2__Add_Usage_Column.sql` | New migration |
| `extensions/store/sql/migrations/.../keypair/V0_0_2__Add_Usage_Column.sql` | New migration |
| `extensions/store/sql/migrations/.../stsclient/V0_0_2__Update_Schema_For_EDC_0_15_1.sql` | New migration |
| `extensions/store/sql/migrations/.../holder/V0_0_2__Add_Anonymous_And_Properties.sql` | New migration |
| `extensions/store/sql/migrations/.../credentialrequest/V0_0_1__Init_CredentialRequest_and_Offers.sql` | FK conflict fix |
| `extensions/store/sql/migrations/.../credentialrequest/V0_0_2__Update_Lease_Schema.sql` | New migration |
| `extensions/store/sql/migrations/.../issuanceprocess/V0_0_1__Init_IssuanceProcess.sql` | FK conflict fix |
| `extensions/store/sql/migrations/.../issuanceprocess/V0_0_2__Update_Lease_Schema.sql` | New migration |
| `deployment/local/docker-compose.yaml` | New file |
| `deployment/local/config/identityhub.properties` | New file |
| `deployment/local/config/issuerservice.properties` | New file |
| `deployment/local/config/logging.properties` | New file |
| `deployment/local/test-wallet-api.sh` | New file (68-test validation script) |

# NOTICE

This work is licensed under the [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/legalcode).

* SPDX-License-Identifier: CC-BY-4.0
* SPDX-FileCopyrightText: 2025 Contributors to the Eclipse Foundation
* Source URL: https://github.com/eclipse-tractusx/tractusx-identityhub
