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

import com.fasterxml.jackson.databind.ObjectMapper;
import org.eclipse.edc.spi.EdcException;
import org.eclipse.edc.spi.monitor.Monitor;

import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.Instant;
import java.util.Map;
import java.util.Objects;

/**
 * Posts the Portal's BPN-keyed issuer credential callback, authenticating with an OAuth2
 * client-credentials token (cached until shortly before expiry). Responses that mean the Portal has
 * nothing to advance — 404 (no SUBMITTED application for this BPN), 409 (the AWAIT step already
 * advanced), 410 (gone) — are treated as delivered and NOT retried. Auth failures (401 — the cached
 * token is dropped and re-minted next attempt — and 403), any other 4xx, and 5xx are RAISED so the
 * periodic scan retries and the failure stays visible in the log; they are never silently swallowed
 * (a swallowed auth failure would hang the Portal's AWAIT_*_CREDENTIAL_RESPONSE step forever).
 */
public class PortalCredentialCallbackClient {

    public static final String DEFAULT_SCOPE = "openid";
    private static final String CALLBACK_PATH = "/api/administration/registration/issuer/";
    private static final long EXPIRY_SKEW_SECONDS = 30;

    private final String baseUrl;
    private final String tokenUrl;
    private final String clientId;
    private final String clientSecret;
    private final String scope;
    private final ObjectMapper mapper = new ObjectMapper();
    private final Monitor monitor;
    // Pin HTTP/1.1: the JDK HttpClient defaults to HTTP/2, which over cleartext (http://)
    // attempts an h2c upgrade that the ingress-nginx / Keycloak token endpoint does not
    // complete, so the request hangs until the 30s timeout. curl (HTTP/1.1) reaches the
    // same endpoint in ~6ms; forcing HTTP/1.1 here makes the callback work in-cluster.
    private final HttpClient httpClient = HttpClient.newBuilder()
            .version(HttpClient.Version.HTTP_1_1)
            .connectTimeout(Duration.ofSeconds(10))
            .build();

    private String cachedToken;
    private Instant tokenExpiry = Instant.MIN;

    public PortalCredentialCallbackClient(String baseUrl, String tokenUrl, String clientId, String clientSecret,
                                          String scope, Monitor monitor) {
        this.baseUrl = Objects.requireNonNull(baseUrl, "Portal callback base-url is required").replaceAll("/+$", "");
        this.tokenUrl = Objects.requireNonNull(tokenUrl, "Portal callback token-url is required");
        this.clientId = Objects.requireNonNull(clientId, "Portal callback client-id is required");
        this.clientSecret = Objects.requireNonNull(clientSecret, "Portal callback client-secret is required");
        this.scope = scope == null || scope.isBlank() ? DEFAULT_SCOPE : scope;
        this.monitor = monitor;
    }

    public void postCallback(String pathSuffix, String bpn, String status, String message) {
        var url = baseUrl + CALLBACK_PATH + pathSuffix;
        var body = serialize(Map.of("bpn", bpn, "status", status, "message", message == null ? "" : message));
        var request = HttpRequest.newBuilder(URI.create(url))
                .timeout(Duration.ofSeconds(30))
                .header("Content-Type", "application/json")
                .header("Authorization", "Bearer " + getToken())
                .POST(HttpRequest.BodyPublishers.ofString(body))
                .build();

        var response = send(request, "Portal callback " + pathSuffix);
        var code = response.statusCode();
        if (code >= 200 && code < 300) {
            return;
        }
        // The Portal has nothing to advance for this BPN — safe to treat as delivered, do not retry:
        //   404 = no SUBMITTED application for this BPN (a seeded participant, or one already fully processed)
        //   409 = the AWAIT step already advanced (duplicate delivery, e.g. after an IdentityHub restart)
        //   410 = gone
        if (code == 404 || code == 409 || code == 410) {
            monitor.info("Portal callback %s for bpn=%s returned %d (nothing to advance — treating as delivered): %s"
                    .formatted(pathSuffix, bpn, code, response.body()));
            return;
        }
        // Everything else must NOT be swallowed — that would silently hang AWAIT_*_CREDENTIAL_RESPONSE.
        //   401 = the cached token is stale/rejected (e.g. centralidp re-seeded within the token TTL) → drop it
        //         so the next attempt re-mints; the scan retries.
        //   403 = the callback client lacks update_application_{bpn,membership}_credential (wrong service account).
        //   other 4xx / 5xx = raise + log so the failure is visible; the scan retries.
        if (code == 401) {
            invalidateToken();
        }
        monitor.warning("Portal callback %s for bpn=%s returned %d — will retry on the next scan: %s"
                .formatted(pathSuffix, bpn, code, response.body()));
        throw new EdcException("Portal callback %s failed with status %d: %s".formatted(pathSuffix, code, response.body()));
    }

    private synchronized void invalidateToken() {
        cachedToken = null;
        tokenExpiry = Instant.MIN;
    }

    private synchronized String getToken() {
        if (cachedToken != null && Instant.now().isBefore(tokenExpiry)) {
            return cachedToken;
        }
        var form = "grant_type=client_credentials"
                + "&client_id=" + enc(clientId)
                + "&client_secret=" + enc(clientSecret)
                + "&scope=" + enc(scope);
        var request = HttpRequest.newBuilder(URI.create(tokenUrl))
                .timeout(Duration.ofSeconds(30))
                .header("Content-Type", "application/x-www-form-urlencoded")
                .POST(HttpRequest.BodyPublishers.ofString(form))
                .build();

        var response = send(request, "Portal callback token request");
        if (response.statusCode() < 200 || response.statusCode() >= 300) {
            throw new EdcException("Portal callback token request failed with status %d: %s".formatted(response.statusCode(), response.body()));
        }
        try {
            var json = mapper.readTree(response.body());
            cachedToken = json.get("access_token").asText();
            var expiresIn = json.has("expires_in") ? json.get("expires_in").asLong() : 60L;
            tokenExpiry = Instant.now().plusSeconds(Math.max(0, expiresIn - EXPIRY_SKEW_SECONDS));
            return cachedToken;
        } catch (Exception e) {
            throw new EdcException("Failed to parse Portal callback token response: " + e.getMessage(), e);
        }
    }

    private HttpResponse<String> send(HttpRequest request, String action) {
        try {
            return httpClient.send(request, HttpResponse.BodyHandlers.ofString());
        } catch (Exception e) {
            throw new EdcException(action + " failed: " + e.getMessage(), e);
        }
    }

    private String serialize(Map<String, String> value) {
        try {
            return mapper.writeValueAsString(value);
        } catch (Exception e) {
            throw new EdcException("Failed to serialize Portal callback body: " + e.getMessage(), e);
        }
    }

    private static String enc(String value) {
        return URLEncoder.encode(value, StandardCharsets.UTF_8);
    }
}
