//===----------------------------------------------------------------------===//
//
// This source file is part of the OracleNIO open source project
//
// Copyright (c) 2024 Timo Zacherl and the OracleNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE for license information
// See CONTRIBUTORS.md for the list of OracleNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import Testing

@testable import OracleNIO

@Suite(.timeLimit(.minutes(5))) struct RefuseRedirectTests {
    @Test func decodeRefuse() throws {
        let data = "(DESCRIPTION=(ERR=12514)(ERROR_STACK=(ERROR=(CODE=12514))))"
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt8(4))
        buffer.writeInteger(UInt8(0))
        buffer.writeInteger(UInt16(data.utf8.count))
        buffer.writeString(data)

        let result = try OracleBackendMessage.decode(
            from: &buffer,
            of: .refuse,
            context: .init(capabilities: .desired())
        )

        guard case .refuse(let refuse) = result.0.first else {
            Issue.record("expected a refuse message, got \(result.0)")
            return
        }
        #expect(refuse.code == 12514)
        #expect(refuse.data == data)
        #expect(buffer.readableBytes == 0)
    }

    @Test func refuseWithoutErrorCode() throws {
        let data = "(DESCRIPTION=(TMP=)(VSNNUM=0))"
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt8(0))
        buffer.writeInteger(UInt8(0))
        buffer.writeInteger(UInt16(data.utf8.count))
        buffer.writeString(data)

        let result = try OracleBackendMessage.decode(
            from: &buffer,
            of: .refuse,
            context: .init(capabilities: .desired())
        )

        guard case .refuse(let refuse) = result.0.first else {
            Issue.record("expected a refuse message, got \(result.0)")
            return
        }
        #expect(refuse.code == nil)
    }

    @Test func decodeRedirect() throws {
        let data = "(DESCRIPTION=(ADDRESS=(PROTOCOL=tcp)(HOST=node2.example.com)(PORT=1522)))"
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt16(data.utf8.count))
        buffer.writeString(data)

        let result = try OracleBackendMessage.decode(
            from: &buffer,
            of: .redirect,
            context: .init(capabilities: .desired())
        )

        guard case .redirect(let redirect) = result.0.first else {
            Issue.record("expected a redirect message, got \(result.0)")
            return
        }
        #expect(redirect.address == data)
        #expect(redirect.connectData == nil)
        let target = try #require(redirect.target)
        #expect(target.host == "node2.example.com")
        #expect(target.port == 1522)
        #expect(redirect.usesTCPS == false)
        #expect(buffer.readableBytes == 0)
    }

    @Test func decodeRedirectWithConnectData() throws {
        let address = "(DESCRIPTION=(ADDRESS=(PROTOCOL=tcps)(HOST=10.0.0.5)(PORT=2484)))"
        let connectData = "(CONNECT_DATA=(SERVICE_NAME=orcl))"
        let payload = "\(address)\0\(connectData)"
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt16(payload.utf8.count))
        buffer.writeString(payload)

        let result = try OracleBackendMessage.decode(
            from: &buffer,
            of: .redirect,
            context: .init(capabilities: .desired())
        )

        guard case .redirect(let redirect) = result.0.first else {
            Issue.record("expected a redirect message, got \(result.0)")
            return
        }
        #expect(redirect.address == address)
        #expect(redirect.connectData == connectData)
        let target = try #require(redirect.target)
        #expect(target.host == "10.0.0.5")
        #expect(target.port == 2484)
        #expect(redirect.usesTCPS == true)
    }

    @Test func redirectTargetMissingPort() {
        let redirect = OracleBackendMessage.Redirect(
            address: "(DESCRIPTION=(ADDRESS=(PROTOCOL=tcp)(HOST=node2)))",
            connectData: nil
        )
        #expect(redirect.target == nil)
    }
}
