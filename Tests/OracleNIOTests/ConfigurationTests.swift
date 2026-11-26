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

    private func redirect(
        _ address: String, connectData: String? = nil
    ) -> OracleBackendMessage.Redirect {
        OracleBackendMessage.Redirect(address: address, connectData: connectData)
    }

    @Test func followingRedirectRepointsToTarget() throws {
        let config = makeConfig()
        let redirected = try config.followingRedirect(
            redirect("(ADDRESS=(PROTOCOL=TCP)(HOST=node1.example.com)(PORT=1522))")
        )
        #expect(redirected.host == "node1.example.com")
        #expect(redirected.port == 1522)
        #expect(redirected.service == config.service)
        #expect(redirected.connectPacketFlags == Constants.TNS_PACKET_FLAG_REDIRECT)
        #expect(config.connectPacketFlags == 0)
    }

    // The listener adds INSTANCE_NAME and CONNECTION_ID, which pin the session to the
    // instance it chose, so the next hop sends its descriptor and not one of ours.
    @Test func followingRedirectSendsTheListenersConnectData() throws {
        let config = makeConfig()
        let handedBack =
            "(DESCRIPTION=(CONNECT_DATA=(SERVICE_NAME=orcl)(SERVER=dedicated)(INSTANCE_NAME=orcl1)))"
        let redirected = try config.followingRedirect(
            redirect("(ADDRESS=(PROTOCOL=TCP)(HOST=node1)(PORT=1521))", connectData: handedBack)
        )
        #expect(redirected.getConnectString() == handedBack)
        #expect(config.getConnectString() != handedBack)
    }

    @Test func followingRedirectWithoutConnectDataRebuildsOursForTheTarget() throws {
        let redirected = try makeConfig().followingRedirect(
            redirect("(ADDRESS=(PROTOCOL=tcp)(HOST=node2)(PORT=1525))")
        )
        #expect(redirected.getConnectString().contains("(HOST=node2)(PORT=1525)"))
    }

    // The CONNECT carries the redirect flag, so a listener that would redirect again
    // refuses instead; following the same address is how a listener hands back a
    // new descriptor.
    @Test func followingRedirectToTheSameAddressIsAllowed() throws {
        let config = makeConfig(host: "db.example.com", port: 1521)
        let redirected = try config.followingRedirect(
            redirect("(ADDRESS=(PROTOCOL=tcp)(HOST=db.example.com)(PORT=1521))")
        )
        #expect(redirected.host == "db.example.com")
    }

    @Test func followingRedirectWithoutTargetIsUnreadable() {
        #expect(reason(of: { try makeConfig().followingRedirect(redirect("")) }) == .unreadable)
        #expect(
            reason(of: { try makeConfig().followingRedirect(redirect("(DESCRIPTION=(garbage))")) })
                == .unreadable
        )
    }

    @Test func aDescriptorNoPacketCanCarryIsUnreadable() {
        let tooLong = "(DESCRIPTION=" + String(repeating: "x", count: 65_530) + ")"
        #expect(
            reason(of: {
                try makeConfig().followingRedirect(
                    redirect("(ADDRESS=(PROTOCOL=TCP)(HOST=node1)(PORT=1521))", connectData: tooLong)
                )
            }) == .unreadable
        )
    }

    @Test func followingRedirectIsOffWhenTheCallerSaysSo() {
        var config = makeConfig()
        config.followsListenerRedirects = false
        let error = catching {
            try config.followingRedirect(redirect("(ADDRESS=(PROTOCOL=tcp)(HOST=10.0.0.12)(PORT=1521))"))
        }
        #expect(error?.reason == .notFollowed)
        #expect(error?.host == "10.0.0.12")
        #expect(error?.port == 1521)
    }

    @Test func aWildcardAddressIsNotDialed() {
        for host in ["0.0.0.0", "::"] {
            let error = catching {
                try makeConfig().followingRedirect(redirect("(ADDRESS=(PROTOCOL=TCP)(HOST=\(host))(PORT=15213))"))
            }
            #expect(error?.reason == .targetUnreachable)
            #expect(error?.host == host)
        }
    }

    @Test func aSecondRedirectWithoutConnectDataKeepsTheFirstListenersDescriptor() throws {
        let handedBack = "(DESCRIPTION=(CONNECT_DATA=(SERVICE_NAME=orcl)(SERVER=shared)(INSTANCE_NAME=orcl1)))"
        let first = try makeConfig().followingRedirect(
            redirect("(ADDRESS=(PROTOCOL=TCP)(HOST=node1)(PORT=1521))", connectData: handedBack)
        )
        let second = try first.followingRedirect(redirect("(ADDRESS=(PROTOCOL=TCP)(HOST=node1)(PORT=15213))"))
        #expect(second.port == 15213)
        #expect(second.getConnectString() == handedBack)
    }

    @Test func plainTCPIsNotSentToATCPSAddress() {
        #expect(
            reason(of: {
                try makeConfig().followingRedirect(
                    redirect("(ADDRESS=(PROTOCOL=tcps)(HOST=node1)(PORT=2484))")
                )
            }) == .transportMismatch
        )
    }

    private func catching(
        _ body: () throws -> OracleConnection.Configuration
    ) -> OracleRedirectError? {
        do {
            _ = try body()
            return nil
        } catch {
            return error as? OracleRedirectError
        }
    }

    private func reason(
        of body: () throws -> OracleConnection.Configuration
    ) -> OracleRedirectError.Reason? {
        catching(body)?.reason
    }
}
