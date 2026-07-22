/*
 *   Copyright (c) 2026 Technovative Solutions
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
import org.eclipse.edc.identityhub.spi.credential.request.model.HolderRequestState;
import org.eclipse.edc.identityhub.spi.credential.request.store.HolderCredentialRequestStore;
import org.eclipse.edc.spi.monitor.Monitor;
import org.junit.jupiter.api.Test;

import java.time.Clock;
import java.util.ArrayList;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class PortalCredentialCallbackExtensionTest {

    private static final String BPN_TYPE = "BpnCredential";
    private static final String MEMBERSHIP_TYPE = "MembershipCredential";
    private static final String ONBOARDED_ID = "bpnl00000003ayre";

    private final HolderCredentialRequestStore store = mock(HolderCredentialRequestStore.class);
    private final RecordingCallback callback = new RecordingCallback();
    private final Monitor monitor = mock(Monitor.class);

    // ---- static helpers -----------------------------------------------------------------------------

    @Test
    void onboardedBpnPattern_acceptsRealLowercasedBpnl() {
        // the Portal-managed onboarding wallet uses the lowercased BPN(L) as its participantContextId
        assertThat(PortalCredentialCallbackExtension.ONBOARDED_BPN.matcher("bpnl00000003ayre").matches()).isTrue();
    }

    @Test
    void onboardedBpnPattern_rejectsSeededAndMalformedIds() {
        // seeded/role participants (no Portal onboarding application) must not be reported
        assertThat(PortalCredentialCallbackExtension.ONBOARDED_BPN.matcher("provider-bpnl00000003ayre").matches()).isFalse();
        // upper-cased (not the stored lowercased form)
        assertThat(PortalCredentialCallbackExtension.ONBOARDED_BPN.matcher("BPNL00000003AYRE").matches()).isFalse();
        // wrong length
        assertThat(PortalCredentialCallbackExtension.ONBOARDED_BPN.matcher("bpnl123").matches()).isFalse();
        // not a legal-entity BPN(L)
        assertThat(PortalCredentialCallbackExtension.ONBOARDED_BPN.matcher("bpns00000003ayre").matches()).isFalse();
    }

    @Test
    void pathSuffixFor_mapsOnboardingTypesAndIgnoresOthers() {
        assertThat(PortalCredentialCallbackExtension.pathSuffixFor("BpnCredential", "BpnCredential", "MembershipCredential"))
                .isEqualTo("bpncredential");
        assertThat(PortalCredentialCallbackExtension.pathSuffixFor("MembershipCredential", "BpnCredential", "MembershipCredential"))
                .isEqualTo("membershipcredential");
        assertThat(PortalCredentialCallbackExtension.pathSuffixFor("DataExchangeGovernanceCredential", "BpnCredential", "MembershipCredential"))
                .isNull();
    }

    // ---- scan / process / deliver orchestration -----------------------------------------------------

    @Test
    void issued_onboardedBpn_deliversOneSuccessfulCallback() {
        stubStore(request("h1", HolderRequestState.ISSUED, ONBOARDED_ID, BPN_TYPE, null));

        newExtension().scanOnce();

        // BPN is upper-cased for the Portal lookup; status maps ISSUED -> SUCCESSFUL
        assertThat(callback.calls).singleElement().satisfies(c -> {
            assertThat(c.pathSuffix()).isEqualTo("bpncredential");
            assertThat(c.bpn()).isEqualTo("BPNL00000003AYRE");
            assertThat(c.status()).isEqualTo("SUCCESSFUL");
        });
    }

    @Test
    void error_onboardedBpn_deliversUnsuccessfulCallbackWithErrorDetail() {
        stubStore(request("h1", HolderRequestState.ERROR, ONBOARDED_ID, MEMBERSHIP_TYPE, "issuer said no"));

        newExtension().scanOnce();

        assertThat(callback.calls).singleElement().satisfies(c -> {
            assertThat(c.pathSuffix()).isEqualTo("membershipcredential");
            assertThat(c.status()).isEqualTo("UNSUCCESSFUL");
            assertThat(c.message()).contains("issuer said no");
        });
    }

    @Test
    void nonTerminalState_isIgnored() {
        stubStore(request("h1", HolderRequestState.REQUESTED, ONBOARDED_ID, BPN_TYPE, null));

        newExtension().scanOnce();

        assertThat(callback.calls).isEmpty();
    }

    @Test
    void seededParticipantContext_isIgnored() {
        // a seeded "role-bpn" participant has no Portal onboarding application to advance
        stubStore(request("h1", HolderRequestState.ISSUED, "provider-bpnl00000003ayre", BPN_TYPE, null));

        newExtension().scanOnce();

        assertThat(callback.calls).isEmpty();
    }

    @Test
    void unmappedCredentialType_isSkippedAndWarnedOncePerType() {
        stubStore(request("h1", HolderRequestState.ISSUED, ONBOARDED_ID, "DataExchangeGovernanceCredential", null));
        var extension = newExtension();

        extension.scanOnce();
        extension.scanOnce();

        // nothing delivered, and the config-drift warning fires exactly once despite two scans
        assertThat(callback.calls).isEmpty();
        verify(monitor, times(1)).warning(contains("no endpoint for credential type"));
    }

    @Test
    void duplicateScan_deliversOnlyOnce() {
        stubStore(request("h1", HolderRequestState.ISSUED, ONBOARDED_ID, BPN_TYPE, null));
        var extension = newExtension();

        extension.scanOnce();
        extension.scanOnce();

        assertThat(callback.calls).hasSize(1);
    }

    @Test
    void deliveryFailure_isRetriedOnNextScan() {
        stubStore(request("h1", HolderRequestState.ISSUED, ONBOARDED_ID, BPN_TYPE, null));
        callback.failNextCalls(1); // first POST throws, dedup key is cleared so the next scan retries
        var extension = newExtension();

        extension.scanOnce(); // throws internally, caught, dedup removed
        extension.scanOnce(); // retries and succeeds

        assertThat(callback.calls).hasSize(1); // one *successful* delivery recorded
        assertThat(callback.attempts).isEqualTo(2); // but two attempts were made
    }

    // ---- helpers ------------------------------------------------------------------------------------

    private PortalCredentialCallbackExtension newExtension() {
        return new PortalCredentialCallbackExtension(store, callback, BPN_TYPE, MEMBERSHIP_TYPE, monitor);
    }

    private void stubStore(HolderCredentialRequest... requests) {
        when(store.query(any())).thenReturn(List.of(requests));
    }

    private static HolderCredentialRequest request(String id, HolderRequestState state, String participantContextId,
                                                   String credentialType, String errorDetail) {
        var builder = HolderCredentialRequest.Builder.newInstance()
                .id(id)
                .state(state.code())
                .clock(Clock.systemUTC())
                .participantContextId(participantContextId)
                .issuerDid("did:web:issuer")
                .requestedCredential("obj-" + id, credentialType, "vc+jwt");
        if (errorDetail != null) {
            builder.errorDetail(errorDetail);
        }
        return builder.build();
    }

    private record Call(String pathSuffix, String bpn, String status, String message) {
    }

    private static final class RecordingCallback implements PortalCallback {
        private final List<Call> calls = new ArrayList<>();
        private int attempts;
        private int failCount;

        void failNextCalls(int n) {
            failCount = n;
        }

        @Override
        public void postCallback(String pathSuffix, String bpn, String status, String message) {
            attempts++;
            if (failCount > 0) {
                failCount--;
                throw new RuntimeException("simulated delivery failure");
            }
            calls.add(new Call(pathSuffix, bpn, status, message));
        }
    }
}
