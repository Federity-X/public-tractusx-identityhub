# Feature: emit an event / listener when a `HolderCredentialRequest` reaches a terminal state (ISSUED / ERROR)

## Is your feature request related to a problem?

The holder credential-request flow (`HolderCredentialRequestStore`, states `CREATED → REQUESTING → REQUESTED → ISSUED | ERROR`) has **no notification mechanism**. An external system that needs to react when a holder’s requested credential is finally issued (or fails) — e.g. an onboarding portal that must advance its own workflow, a monitoring component, an audit sink — has no way to be *told*. It can only **poll** `HolderCredentialRequestStore`/the credentials API and diff the state itself.

This is inconsistent with the rest of the EDC/IdentityHub programming model: `TransferProcess` and `ContractNegotiation` both expose an `Observable` + `Listener` (and fire `EventRouter` events) so extensions can subscribe to state transitions in-process. `HolderCredentialRequest` has neither an observable/listener nor an `EventRouter` event, so there is no supported extension point for “credential request completed”.

## Describe the solution you'd like

Add a state-transition notification for holder credential requests, ideally one (or both) of:

1. **SPI observable/listener** — a `HolderCredentialRequestListener` (`preRequested`, `issued`, `errored`, …) registered via a `HolderCredentialRequestObservable`, invoked by the holder credential-request state machine on transition, so an extension can subscribe in-process. (Mirrors `TransferProcessObservable`/`TransferProcessListener`.)
2. **EventRouter events** — publish `HolderCredentialRequestIssued` / `HolderCredentialRequestErrored` (extending `Event`) on the terminal transitions, so extensions can register an `EventSubscriber`.

Either lets downstream code react **push-style** (fire a webhook, kick off follow-up processing, emit metrics) with no polling and no duplicated state-diff logic.

## Describe alternatives you've considered

A polling extension that periodically queries `HolderCredentialRequestStore` for requests in `ISSUED`/`ERROR` and reacts (in our case, POSTing an outbound HTTP callback). This works and is the basis of the **reference implementation** below, but:

- it **polls** on a timer (no event hook exists), so it trades latency for load and needs its own de-duplication of already-handled requests;
- de-dup is in-memory (per runtime lifetime) because the store row stays in the terminal state, so there is nothing to transition it to a “notified” marker without a bespoke store.

With option 1 or 2 above, the same extension would simply subscribe and drop the scanner + the de-dup bookkeeping.

## Reference implementation

Branch `feat/holder-credential-request-status-callback` adds `extensions/portal-credential-callback` — a `ServiceExtension` that `@Inject`s `HolderCredentialRequestStore`, scans on a fixed interval for requests in `ISSUED`/`ERROR`, and emits a configurable outbound HTTP callback (OAuth2 client-credentials). It is inert unless a callback base-URL is configured, and is wired into the `identityhub` and `identityhub-memory` runtimes. It demonstrates the use case and would be simplified to a subscriber once the eventing hook exists.

> Note: the reference module + its `tx.portal.callback.*` settings are named for the specific downstream consumer (a Catena-X onboarding portal) that motivated it. If accepted upstream, the extension would be generalised (e.g. `credential-request-callback` with a use-case-agnostic payload/settings).

## Acceptance criteria

- A supported extension point (listener/observable and/or `EventRouter` event) fires when a `HolderCredentialRequest` transitions to `ISSUED` and to `ERROR`, carrying at least the `participantContextId`, `holderPid`, `issuerDid`, and the requested credential id(s)/type(s).
- Documented in the holder-credential-request SPI.
- Existing behaviour unchanged when no listener/subscriber is registered.
