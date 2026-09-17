//===----------------------------------------------------------------------===//
//
// This source file is part of the OracleNIO open source project
//
// Copyright (c) 2025 Timo Zacherl and the OracleNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE for license information
// See CONTRIBUTORS.md for the list of OracleNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Testing

@testable import OracleNIO

@Suite struct ConfigurationTests {
    @Test func sanitization() {
        var config = OracleConnection.Configuration(
            host: "127.0.0.1",
            service: .serviceName("sn"),
            username: "us",
            password: "pw"
        )
        config.connectionIDPrefix = "a()bce="
        config.programName = "x=0y"
        config.machineName = "192.168.1.1(mypc)"
        config.processUsername = "sha=(full)"
        #expect(config.connectionIDPrefix == "a??bce?")
        #expect(config.programName == "x?0y")
        #expect(config.machineName == "192.168.1.1?mypc?")
        #expect(config.processUsername == "sha??full?")
    }

    private func makeConfig(host: String = "scan.example.com", port: Int = 1521)
        -> OracleConnection.Configuration
    {
        OracleConnection.Configuration(
            host: host, port: port, service: .serviceName("orcl"),
            username: "us", password: "pw"
        )
    }

    @Test func followingRedirectRepointsToTarget() throws {
        let config = makeConfig()
        let redirect = OracleRedirectError(
            address: "(DESCRIPTION=(ADDRESS=(PROTOCOL=tcp)(HOST=node1.example.com)(PORT=1522)))",
            connectData: nil
        )
        let redirected = try #require(config.followingRedirect(redirect))
        #expect(redirected.host == "node1.example.com")
        #expect(redirected.port == 1522)
        // Service and credentials carry across the redirect.
        #expect(redirected.service == config.service)
    }

    /// A listener may legally redirect to its own address to hand back a replacement
    /// connect descriptor, so the same address is followed. Refusing it was never a loop
    /// bound either: two servers pointing at each other never repeat consecutively. The
    /// hop limit in `connectFollowingRedirects` is what bounds the chain.
    @Test func followingRedirectToSameAddressIsAllowed() throws {
        let config = makeConfig(host: "db.example.com", port: 1521)
        let redirect = OracleRedirectError(
            address: "(DESCRIPTION=(ADDRESS=(PROTOCOL=tcp)(HOST=db.example.com)(PORT=1521)))",
            connectData: "(DESCRIPTION=(CONNECT_DATA=(SERVICE_NAME=handed_back)))"
        )
        let redirected = try #require(config.followingRedirect(redirect))
        #expect(redirected.host == "db.example.com")
        #expect(redirected.port == 1521)
    }

    /// The listener replaces the whole descriptor, so the follow-up connect sends what
    /// it handed back rather than one rebuilt from this configuration. Rebuilding it is
    /// what makes shared server and MTS a coin flip.
    @Test func followingRedirectSendsTheServersConnectString() throws {
        let config = makeConfig()
        let handedBack = "(DESCRIPTION=(CONNECT_DATA=(SERVICE_NAME=shared)(SERVER=dedicated)))"
        let redirect = OracleRedirectError(
            address: "(DESCRIPTION=(ADDRESS=(PROTOCOL=tcp)(HOST=node1.example.com)(PORT=1522)))",
            connectData: handedBack
        )
        let redirected = try #require(config.followingRedirect(redirect))
        #expect(redirected.getConnectString() == handedBack)
        #expect(config.getConnectString() != handedBack)
    }

    /// Following a `PROTOCOL=tcps` redirect from a plain-TCP configuration would connect
    /// in clear text to an endpoint that asked for TLS.
    @Test func followingRedirectRefusesATransportMismatch() {
        let config = makeConfig()
        let redirect = OracleRedirectError(
            address: "(DESCRIPTION=(ADDRESS=(PROTOCOL=tcps)(HOST=node1.example.com)(PORT=2484)))",
            connectData: nil
        )
        #expect(config.followingRedirect(redirect) == nil)
    }

    @Test func followingRedirectWithoutParseableTargetReturnsNil() {
        let config = makeConfig()
        let redirect = OracleRedirectError(address: "(DESCRIPTION=(garbage))", connectData: nil)
        #expect(config.followingRedirect(redirect) == nil)
    }
}
