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

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class PortalCredentialCallbackExtensionTest {

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
}
