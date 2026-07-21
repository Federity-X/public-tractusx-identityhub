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

import com.sun.net.httpserver.HttpServer;
import org.eclipse.edc.spi.EdcException;
import org.eclipse.edc.spi.monitor.Monitor;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;

class PortalCredentialCallbackClientTest {

    private final AtomicInteger callbackStatus = new AtomicInteger(200);
    private final AtomicInteger tokenRequests = new AtomicInteger();
    private HttpServer server;
    private String baseUrl;

    @BeforeEach
    void setUp() throws IOException {
        callbackStatus.set(200);
        tokenRequests.set(0);
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/", exchange -> {
            exchange.getRequestBody().readAllBytes();
            int code;
            String body;
            if (exchange.getRequestURI().getPath().endsWith("/token")) {
                tokenRequests.incrementAndGet();
                code = 200;
                body = "{\"access_token\":\"tok-" + tokenRequests.get() + "\",\"expires_in\":300}";
            } else {
                code = callbackStatus.get();
                body = "response-body";
            }
            var bytes = body.getBytes(StandardCharsets.UTF_8);
            exchange.sendResponseHeaders(code, bytes.length);
            try (var os = exchange.getResponseBody()) {
                os.write(bytes);
            }
        });
        server.start();
        baseUrl = "http://127.0.0.1:" + server.getAddress().getPort();
    }

    @AfterEach
    void tearDown() {
        server.stop(0);
    }

    private PortalCredentialCallbackClient newClient() {
        return new PortalCredentialCallbackClient(baseUrl, baseUrl + "/token", "client-id", "client-secret", "openid", mock(Monitor.class));
    }

    @Test
    void success2xx_isDeliveredWithoutThrowing() {
        callbackStatus.set(200);
        newClient().postCallback("bpncredential", "BPNL00000003AYRE", "SUCCESSFUL", "ok");
        assertThat(tokenRequests.get()).isEqualTo(1);
    }

    @Test
    void notFound404_isTreatedAsDelivered() {
        callbackStatus.set(404);
        // 404 = no SUBMITTED application for this BPN — nothing to advance, must not throw/retry
        newClient().postCallback("bpncredential", "BPNL00000003AYRE", "SUCCESSFUL", "ok");
    }

    @Test
    void conflict409_isTreatedAsDelivered() {
        callbackStatus.set(409);
        // 409 = the AWAIT step already advanced (duplicate) — must not throw/retry
        newClient().postCallback("membershipcredential", "BPNL00000003AYRE", "SUCCESSFUL", "ok");
    }

    @Test
    void serverError500_isRaised() {
        callbackStatus.set(500);
        assertThatThrownBy(() -> newClient().postCallback("bpncredential", "BPNL00000003AYRE", "SUCCESSFUL", "ok"))
                .isInstanceOf(EdcException.class);
    }

    @Test
    void forbidden403_isRaised() {
        callbackStatus.set(403);
        // 403 = callback client lacks the update_application_*_credential roles — must surface, never swallow
        assertThatThrownBy(() -> newClient().postCallback("bpncredential", "BPNL00000003AYRE", "SUCCESSFUL", "ok"))
                .isInstanceOf(EdcException.class);
    }

    @Test
    void token_isCachedAcrossCalls() {
        callbackStatus.set(200);
        var client = newClient();
        client.postCallback("bpncredential", "BPNL00000003AYRE", "SUCCESSFUL", "ok");
        client.postCallback("membershipcredential", "BPNL00000003AYRE", "SUCCESSFUL", "ok");
        assertThat(tokenRequests.get()).isEqualTo(1);
    }

    @Test
    void unauthorized401_dropsCachedTokenSoNextCallReMints() {
        var client = newClient();
        callbackStatus.set(401);
        assertThatThrownBy(() -> client.postCallback("bpncredential", "BPNL00000003AYRE", "SUCCESSFUL", "ok"))
                .isInstanceOf(EdcException.class);
        assertThat(tokenRequests.get()).isEqualTo(1);

        callbackStatus.set(200);
        client.postCallback("bpncredential", "BPNL00000003AYRE", "SUCCESSFUL", "ok");
        // the 401 invalidated the cached token, so the second call minted a fresh one
        assertThat(tokenRequests.get()).isEqualTo(2);
    }
}
