/*
 *   Copyright (c) 2026 Contributors to the Eclipse Foundation
 *
 *   See the NOTICE file(s) distributed with this work for additional
 *   information regarding copyright ownership.
 *
 *   This program and the accompanying materials are made available under the
 *   terms of the Apache License, Version 2.0 which is available at
 *   https://www.apache.org/licenses/LICENSE-2.0.
 *
 *   Unless required by applicable law or agreed to in writing, software
 *   distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 *   WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 *   License for the specific language governing permissions and limitations
 *   under the License.
 *
 *   SPDX-License-Identifier: Apache-2.0
 *
 */

package org.eclipse.tractusx.identityhub.portal;

import org.eclipse.edc.identityhub.spi.credential.request.model.HolderCredentialRequest;
import org.eclipse.edc.identityhub.spi.credential.request.store.HolderCredentialRequestStore;
import org.eclipse.edc.runtime.metamodel.annotation.Inject;
import org.eclipse.edc.runtime.metamodel.annotation.Setting;
import org.eclipse.edc.spi.monitor.Monitor;
import org.eclipse.edc.spi.query.QuerySpec;
import org.eclipse.edc.spi.system.ServiceExtension;
import org.eclipse.edc.spi.system.ServiceExtensionContext;

import java.util.Locale;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.regex.Pattern;

/**
 * Bridges the holder-pull IssuerService credential flow to the Portal's push-callback issuance
 * abstraction (see BE-293). It observes this runtime's {@link HolderCredentialRequestStore} for
 * holder requests reaching a terminal state (ISSUED / ERROR) and posts the Portal's EXISTING
 * BPN-keyed issuer callback ({@code /api/administration/registration/issuer/{bpn|membership}credential}),
 * which advances the AWAIT_*_CREDENTIAL_RESPONSE checklist step. The Portal is unchanged.
 *
 * <p>Topology-agnostic: it simply reacts to whatever holder requests live in its own runtime — the
 * single shared multi-tenant IdentityHub or a per-participant one. Correlation is by BPN, recovered
 * from the holder {@code participantContextId} (the Portal-managed onboarding wallet uses the
 * lowercased BPN as the participant context id — see IdentityHubService). Requests whose context id
 * is not a bare BPN (e.g. seeded {@code role-bpn} participants) are skipped — they have no Portal
 * onboarding application to advance.
 *
 * <p>Inert unless {@code tx.portal.callback.base.url} is set, so it is safe to always include in the
 * runtime and only activates where the Portal onboarding integration is configured.
 *
 * <p>Setting keys are dot-separated (EDC convention) so they are also settable via environment
 * variables: EDC maps {@code TX_PORTAL_CALLBACK_BASE_URL} -> {@code tx.portal.callback.base.url}
 * (uppercase, {@code _} -> {@code .}). Hyphenated keys are NOT reachable from an env var.
 *
 * <p>Deduplication is in-memory per (holderPid, terminal-state) for the runtime lifetime. After a
 * restart a completed request may be re-posted once; the Portal callback returns 404 (no SUBMITTED
 * application) / 409 (the AWAIT step already advanced) for such duplicates, which the client treats
 * as delivered, so this is bounded and harmless. A persistent notified-marker + a state-filtered
 * query are future hardening for large participant counts (see the BE-293 production-hardening notes).
 */
public class PortalCredentialCallbackExtension implements ServiceExtension {

    public static final String NAME = "Portal Credential Callback Extension";

    @Setting(description = "Portal administration base URL that receives the issuer credential callbacks. Empty disables the extension.")
    public static final String PORTAL_BASE_URL = "tx.portal.callback.base.url";
    @Setting(description = "OAuth2 token endpoint (centralidp) used for the Portal callback client-credentials flow.")
    public static final String PORTAL_TOKEN_URL = "tx.portal.callback.token.url";
    @Setting(description = "OAuth2 client id of the Portal technical user authorized to post issuer credential responses.")
    public static final String PORTAL_CLIENT_ID = "tx.portal.callback.client.id";
    @Setting(description = "OAuth2 client secret of the Portal technical user.")
    public static final String PORTAL_CLIENT_SECRET = "tx.portal.callback.client.secret";
    @Setting(description = "OAuth2 scope requested for the Portal callback token.", defaultValue = PortalCredentialCallbackClient.DEFAULT_SCOPE)
    public static final String PORTAL_SCOPE = "tx.portal.callback.scope";
    @Setting(description = "VC type of the BPN(L) onboarding credential.", defaultValue = "BpnCredential")
    public static final String BPN_CREDENTIAL_TYPE = "tx.portal.callback.bpn.credential.type";
    @Setting(description = "VC type of the Membership onboarding credential.", defaultValue = "MembershipCredential")
    public static final String MEMBERSHIP_CREDENTIAL_TYPE = "tx.portal.callback.membership.credential.type";
    @Setting(description = "How often (seconds) to scan for terminal holder credential requests.", defaultValue = "10")
    public static final String INTERVAL_SECONDS = "tx.portal.callback.interval.seconds";

    private static final String STATE_ISSUED = "ISSUED";
    private static final String STATE_ERROR = "ERROR";
    private static final String STATUS_SUCCESSFUL = "SUCCESSFUL";
    private static final String STATUS_UNSUCCESSFUL = "UNSUCCESSFUL";
    // A Portal-onboarded holder wallet uses the lowercased BPN(L) as its participantContextId
    // (IdentityHubService.CreateHolderWalletAsync -> bpn.ToLowerInvariant()), i.e. "bpnl" + 12 chars.
    // Seeded participants use a "role-bpn" id (e.g. "provider-bpnl00000003ayre"), which must NOT be
    // reported to the Portal (there is no onboarding application for them). Gate on this pattern so
    // the BPN we recover is a real BPN and seeded contexts are skipped by construction.
    private static final Pattern ONBOARDED_BPN = Pattern.compile("^bpnl[a-z0-9]{12}$");

    @Inject
    private HolderCredentialRequestStore store;

    private Monitor monitor;
    private PortalCredentialCallbackClient client;
    private String bpnCredentialType;
    private String membershipCredentialType;
    private int intervalSeconds;
    private ScheduledExecutorService scheduler;

    // holderPid|state already delivered this runtime lifetime
    private final Set<String> notified = ConcurrentHashMap.newKeySet();

    @Override
    public String name() {
        return NAME;
    }

    @Override
    public void initialize(ServiceExtensionContext context) {
        monitor = context.getMonitor().withPrefix(PortalCredentialCallbackExtension.class.getSimpleName());
        bpnCredentialType = context.getSetting(BPN_CREDENTIAL_TYPE, "BpnCredential");
        membershipCredentialType = context.getSetting(MEMBERSHIP_CREDENTIAL_TYPE, "MembershipCredential");
        intervalSeconds = context.getSetting(INTERVAL_SECONDS, 10);

        var baseUrl = context.getSetting(PORTAL_BASE_URL, null);
        if (baseUrl == null || baseUrl.isBlank()) {
            monitor.info("%s disabled (no %s configured)".formatted(NAME, PORTAL_BASE_URL));
            return;
        }
        client = new PortalCredentialCallbackClient(
                baseUrl,
                context.getSetting(PORTAL_TOKEN_URL, null),
                context.getSetting(PORTAL_CLIENT_ID, null),
                context.getSetting(PORTAL_CLIENT_SECRET, null),
                context.getSetting(PORTAL_SCOPE, PortalCredentialCallbackClient.DEFAULT_SCOPE),
                monitor);
    }

    @Override
    public void start() {
        if (client == null) {
            return;
        }
        scheduler = Executors.newSingleThreadScheduledExecutor();
        scheduler.scheduleWithFixedDelay(this::scanSafely, intervalSeconds, intervalSeconds, TimeUnit.SECONDS);
        monitor.info("%s started (scanning every %ds)".formatted(NAME, intervalSeconds));
    }

    @Override
    public void shutdown() {
        if (scheduler != null) {
            scheduler.shutdownNow();
        }
    }

    private void scanSafely() {
        try {
            scan();
        } catch (Throwable t) {
            // Catch Throwable, not just Exception: an Error escaping this method would make
            // scheduleWithFixedDelay cancel the periodic task PERMANENTLY and silently (callbacks stop
            // with no further log). Log loudly and stay scheduled so the next tick retries.
            monitor.severe("Portal credential-callback scan failed (task stays scheduled): " + t.getMessage(), t);
        }
    }

    private void scan() {
        // NOTE (scale): QuerySpec.max() loads the whole store and terminal-filters client-side. Fine at
        // sandbox scale; for many participants, switch to a state-filtered query + a persisted notified
        // watermark (see the "Production hardening" notes in BE-293-cross-repo-changes-and-decisions.md).
        for (var request : store.query(QuerySpec.max())) {
            var state = request.stateAsString();
            if (!STATE_ISSUED.equals(state) && !STATE_ERROR.equals(state)) {
                continue;
            }
            if (!ONBOARDED_BPN.matcher(request.getParticipantContextId()).matches()) {
                continue; // seeded/role participant context — not a Portal-onboarded BPN wallet
            }
            var dedupKey = request.getHolderPid() + "|" + state;
            if (!notified.add(dedupKey)) {
                continue;
            }
            try {
                deliver(request, state);
            } catch (Exception e) {
                notified.remove(dedupKey); // allow a retry on the next scan
                monitor.warning("Failed to deliver Portal callback for holderPid %s: %s".formatted(request.getHolderPid(), e.getMessage()), e);
            }
        }
    }

    private void deliver(HolderCredentialRequest request, String state) {
        // participantContextId is the lowercased BPN (guarded by ONBOARDED_BPN in scan()); Locale.ROOT
        // so a JVM default locale (e.g. Turkish) cannot corrupt the upper-casing of an ASCII BPN.
        var bpn = request.getParticipantContextId().toUpperCase(Locale.ROOT);
        var status = STATE_ISSUED.equals(state) ? STATUS_SUCCESSFUL : STATUS_UNSUCCESSFUL;
        for (var requested : request.getIdsAndFormats()) {
            var type = requested.credentialType();
            String pathSuffix;
            if (type.equals(bpnCredentialType)) {
                pathSuffix = "bpncredential";
            } else if (type.equals(membershipCredentialType)) {
                pathSuffix = "membershipcredential";
            } else {
                monitor.debug("Ignoring credential type %s (not a Portal onboarding credential)".formatted(type));
                continue;
            }
            var message = STATE_ISSUED.equals(state)
                    ? "Credential %s issued via IdentityHub".formatted(type)
                    : "Credential %s failed to issue via IdentityHub".formatted(type);
            client.postCallback(pathSuffix, bpn, status, message);
            monitor.info("Delivered Portal callback: bpn=%s type=%s status=%s".formatted(bpn, type, status));
        }
    }
}
