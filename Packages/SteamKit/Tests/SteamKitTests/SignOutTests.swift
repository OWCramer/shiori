// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import SteamKit

struct SignOutTests {
    /// The revoke call sign-out sends, against a packet built by hand from the protos
    /// (Fixtures/revoke_token_request.bin): `Authentication.RevokeToken#1` as an authenticated
    /// service call, the refresh token in field 1, `k_EAuthTokenRevokePermanent` in field 2.
    @Test func revokeRequestMatchesFixture() throws {
        let request = SteamSession.revokeTokenRequest(refreshToken: "fixture.refresh.token")
        let packet = try CMConnection.servicePacket(SteamSession.revokeTokenMethod, request, authenticated: true)
        #expect(try packet.encoded() == fixture("revoke_token_request.bin"))
    }

    @Test func revokeRequestDecodes() throws {
        let packet = try #require(try Packet.decode(fixture("revoke_token_request.bin")))
        #expect(packet.knownEMsg == .kEmsgServiceMethodCallFromClient)
        #expect(packet.header.targetJobName == "Authentication.RevokeToken#1")
        let request = try packet.decode(CAuthentication_Token_Revoke_Request.self)
        #expect(request.token == "fixture.refresh.token")
        #expect(request.hasRevokeAction)
        #expect(request.revokeAction == .kEauthTokenRevokePermanent)
    }

    /// Offline (no connection, nothing to revoke with), signing out still forgets the token.
    @Test func signOutWithoutConnectionForgetsToken() async throws {
        let store = InMemorySessionStore()
        try store.save(StoredSession(accountName: "fixture", refreshToken: "fixture.refresh.token"))
        let session = SteamSession(configuration: SteamConfiguration(deviceName: "Test", deviceSeed: "seed"), store: store)
        await session.signOut()
        #expect(try store.load() == nil)
        #expect(await session.state == .signedOut)
    }
}
