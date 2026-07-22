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

/**
 * Seam over the Portal issuer credential callback POST. Extracting the single delivery operation behind
 * an interface lets the scan/deliver logic in {@link PortalCredentialCallbackExtension} be unit-tested
 * with a fake sink — no HTTP endpoint and no OAuth2 token exchange — while production wires in the real
 * {@link PortalCredentialCallbackClient}.
 */
interface PortalCallback {

    /**
     * Delivers one Portal issuer callback. Returns normally when the Portal accepted it (or had nothing to
     * advance, e.g. 404/409/410); throws when delivery failed and should be retried on the next scan.
     *
     * @param pathSuffix Portal callback path suffix ({@code bpncredential} / {@code membershipcredential}).
     * @param bpn        the upper-cased BPN the Portal keys the onboarding application on.
     * @param status     {@code SUCCESSFUL} / {@code UNSUCCESSFUL}.
     * @param message    human-readable detail attached to the callback.
     */
    void postCallback(String pathSuffix, String bpn, String status, String message);
}
