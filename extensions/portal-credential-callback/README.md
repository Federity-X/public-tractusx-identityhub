# Portal Credential Callback extension

Holder-side EDC `ServiceExtension` (BE-293) that bridges the IdentityHub holder-pull credential flow
to the Catena-X Portal's **push-callback** issuance abstraction.

When a `HolderCredentialRequest` in this runtime reaches a terminal state (`ISSUED` / `ERROR`), the
extension POSTs the Portal's **existing** BPN-keyed issuer callback
(`/api/administration/registration/issuer/{bpn|membership}credential`, authenticated with an OAuth2
client-credentials token), which advances the Portal onboarding checklist's
`AWAIT_{BPN,MEMBERSHIP}_CREDENTIAL_RESPONSE` steps. No Portal change and no IdentityHub core change.

The extension is **inert unless `tx.portal.callback.base.url` is set**, so it is safe to always include
in the runtime; it only activates where the Portal onboarding integration is configured.

## How it works

```
scan (every N s) → HolderCredentialRequestStore
   request in ISSUED / ERROR ?
      recover BPN from the participant-context id (lowercased BPN)
      get centralidp client-credentials token
      POST Portal issuer callback { bpn, status: SUCCESSFUL | UNSUCCESSFUL, message }
   → Portal advances AWAIT_{BPN,MEMBERSHIP}_CREDENTIAL_RESPONSE
```

Correlation is by BPN, recovered from the holder `participantContextId` (the Portal-managed onboarding
wallet uses the lowercased BPN as the participant-context id). Requests whose context id is not a bare
BPN (e.g. seeded `role-bpn` participants) are skipped — they have no Portal onboarding application.

Deduplication is in-memory per `(holderPid, terminal-state, credentialType)` for the runtime lifetime.

## Configuration

All keys are dot-separated (EDC convention) so they are also settable via environment variables
(`TX_PORTAL_CALLBACK_BASE_URL` → `tx.portal.callback.base.url`; hyphenated keys are **not** env-reachable).

| Setting | Default | Purpose |
|---|---|---|
| `tx.portal.callback.base.url` | — (empty = disabled) | Portal administration base URL |
| `tx.portal.callback.token.url` | — | centralidp OAuth2 token endpoint |
| `tx.portal.callback.client.id` / `.client.secret` | — | technical user authorized for the issuer callback roles |
| `tx.portal.callback.scope` | `openid` | token scope |
| `tx.portal.callback.bpn.credential.type` / `.membership.credential.type` | `BpnCredential` / `MembershipCredential` | VC types mapped to the callback path |
| `tx.portal.callback.interval.seconds` | `10` | scan cadence (values `<= 0` fall back to the default) |

The callback client must hold the Portal roles `update_application_bpn_credential` +
`update_application_membership_credential`, or the callback is rejected `403`.

> **Cross-repo contract — keep the credential-type strings in sync.** `pathSuffixFor` matches the
> requested VC type against `tx.portal.callback.{bpn,membership}.credential.type` with an exact
> `.equals`; a type that matches neither is silently skipped and the Portal's `AWAIT_*_CREDENTIAL_RESPONSE`
> step never completes. These strings must equal, on all three sides:
> the VC `type` actually issued, the portal-backend `ApplicationChecklist:IdentityHub:{Bpn,Membership}CredentialType`,
> and these two settings. They share the defaults `BpnCredential` / `MembershipCredential`; if a deployment
> overrides one it must override all three (drive them from one umbrella value). Correlation also relies on
> the Portal-managed wallet using the lowercased BPN as its `participantContextId` (see `ONBOARDED_BPN`).

## Scope: local deployment vs. production

This extension was built and validated for **local / sandbox deployment** (Docker Compose, the umbrella
dev chart). The items below are **known production prerequisites that are intentionally deferred and
documented here** rather than implemented in this interim fork extension. They must be addressed before
this is used in a production dataspace.

### Security

- **Transport (http vs https).** The client does **not** enforce `https` on `base.url` / `token.url`.
  The local/in-cluster deployment reaches the token endpoint over cleartext `http://` (and the JDK
  client is pinned to HTTP/1.1 to make that h2c-free path work). In production the `client_secret` and
  the Portal bearer token must not traverse cleartext: use `https` endpoints (or service-mesh mTLS) and,
  ideally, reject non-`https` URLs unless an explicit insecure opt-in is set.
- **Secret sourcing.** `tx.portal.callback.client.secret` is read as a plain EDC setting. In production
  it must be injected from Vault / a Kubernetes secret, never committed to config or a values file.

### Reliability

- **Retry policy.** On a delivery failure the scan retries every interval with no backoff, no attempt
  cap, and no circuit breaker; a persistent misconfiguration (e.g. `403` wrong service account, or
  sustained `5xx`) re-fires — and logs — every tick indefinitely. Production needs exponential backoff
  with jitter, a per-target give-up/alert, treating config-class failures (`403`) as non-retryable, and
  rate-limited error logging.
- **Head-of-line blocking.** Delivery is blocking HTTP on the single scan thread, so one slow
  Portal/token endpoint stalls deliveries for all requests in the runtime. Production should decouple
  delivery from the scan (bounded async, per-target isolation) or shorten timeouts.

### Scale & restart

- **Full-store scan.** `scan()` loads the whole holder-request store (`QuerySpec.max()`) and filters
  terminal states client-side every interval — `O(store)` work forever. Production should use a
  state-filtered, paginated query.
- **In-memory dedup.** The `notified` set grows for the runtime lifetime and is wiped on restart, so
  every rolling upgrade replays the retained terminal-state store to the Portal (absorbed by the
  Portal's `404`/`409`, but wasteful). Production should persist a per-request `portal-notified` marker
  (a column / side table) so dedup survives restarts and stays bounded.
- **Horizontal scaling.** In-memory dedup + a per-replica scan loop means `replicaCount > 1` makes every
  replica scan and deliver independently. Production needs a single-writer / leader election or a
  persisted marker before scaling out.

### Semantics

- **`ERROR` → `UNSUCCESSFUL`.** A terminal `ERROR` is reported to the Portal as a permanent onboarding
  failure. Confirm this matches the desired onboarding semantics (vs. only reporting once
  IdentityHub-side retries are exhausted).

## Upstreaming

The extension **polls** the store because no terminal-state SPI event exists, and its payload/paths are
Catena-X-Portal-specific. See [`UPSTREAM-ISSUE.md`](./UPSTREAM-ISSUE.md), which proposes the missing SPI
event (a `HolderCredentialRequest` observable / `EventRouter` event); once that lands, this extension
would drop the scanner + in-memory dedup and become a thin event subscriber, and would be generalised
into a use-case-agnostic core plus a Portal adapter.
