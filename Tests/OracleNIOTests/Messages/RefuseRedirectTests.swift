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
import NIOEmbedded
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

    // An Oracle 23.26 listener's answer to a CONNECT it redirects, captured verbatim: a
    // REDIRECT holding only the data length (297), then a DATA packet with the data.
    static let redirectHeader = "000a0000050200000129"
    static let redirectData =
        "0133000006000000004028414444524553533d2850524f544f434f4c3d5443502928484f53543d3132372e302e302e312928504f52543d3135323132292900284445534352495054494f4e3d28414444524553533d2850524f544f434f4c3d7463702928484f53543d3132372e302e302e312928504f52543d3135323131292928434f4e4e4543545f444154413d28534552564943455f4e414d453d667265657064623129284349443d2850524f4752414d3d5461626c6550726f2928484f53543d70726f62652d6d61632e6c6f63616c2928555345523d70726f6265757365722929285345525645523d6465646963617465642928494e5354414e43455f4e414d453d465245452928434f4e4e454354494f4e5f49443d59536f5a4377685441434467597749414561784c71513d3d292929"
    static let capturedAddress = "(ADDRESS=(PROTOCOL=TCP)(HOST=127.0.0.1)(PORT=15212))"
    static let capturedConnectData =
        "(DESCRIPTION=(ADDRESS=(PROTOCOL=tcp)(HOST=127.0.0.1)(PORT=15211))(CONNECT_DATA=(SERVICE_NAME=freepdb1)(CID=(PROGRAM=TablePro)(HOST=probe-mac.local)(USER=probeuser))(SERVER=dedicated)(INSTANCE_NAME=FREE)(CONNECTION_ID=YSoZCwhTACDgYwIAEaxLqQ==)))"

    private func decoderChannel() -> EmbeddedChannel {
        EmbeddedChannel(
            handler: ByteToMessageHandler(
                OracleBackendMessageDecoder(context: .init(capabilities: .init()))
            )
        )
    }

    private func messages(_ channel: EmbeddedChannel) throws -> [OracleBackendMessage] {
        var messages: [OracleBackendMessage] = []
        while let out = try channel.readInbound(as: OracleBackendMessageDecoder.InboundOut.self) {
            for container in out {
                messages.append(contentsOf: container.messages)
            }
        }
        return messages
    }

    private func bytes(_ hex: String) throws -> ByteBuffer {
        ByteBuffer(bytes: try Array(hexString: hex))
    }

    private func expectCapturedRedirect(_ messages: [OracleBackendMessage]) throws {
        #expect(messages.count == 1)
        guard case .redirect(let redirect) = try #require(messages.first) else {
            Issue.record("expected a redirect message, got \(messages)")
            return
        }
        #expect(redirect.address == Self.capturedAddress)
        #expect(redirect.connectData == Self.capturedConnectData)
        let target = try #require(redirect.target)
        #expect(target.host == "127.0.0.1")
        #expect(target.port == 15212)
    }

    // Loopback and a fast LAN deliver both packets in one read. The DATA packet used to
    // fail TTC decoding and take the redirect with it.
    @Test func redirectAndItsDataInOneRead() throws {
        let channel = decoderChannel()
        try channel.writeInbound(try bytes(Self.redirectHeader + Self.redirectData))
        try expectCapturedRedirect(try messages(channel))
    }

    // Read on its own, the REDIRECT used to decode as an empty address.
    @Test func redirectAndItsDataInTwoReads() throws {
        let channel = decoderChannel()
        try channel.writeInbound(try bytes(Self.redirectHeader))
        #expect(try messages(channel).isEmpty)
        try channel.writeInbound(try bytes(Self.redirectData))
        try expectCapturedRedirect(try messages(channel))
    }

    // A small SDU spreads the data over more than one DATA packet.
    @Test func redirectDataOverTwoDataPackets() throws {
        let payload = Array("\(Self.capturedAddress)\0\(Self.capturedConnectData)".utf8)
        let cut = 40
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt16(10))
        buffer.writeInteger(UInt16(0))
        buffer.writeInteger(UInt8(5))
        buffer.writeInteger(UInt8(2))
        buffer.writeInteger(UInt16(0))
        buffer.writeInteger(UInt16(payload.count))
        for chunk in [payload[..<cut], payload[cut...]] {
            buffer.writeInteger(UInt16(10 + chunk.count))
            buffer.writeInteger(UInt16(0))
            buffer.writeInteger(UInt8(6))
            buffer.writeInteger(UInt8(0))
            buffer.writeInteger(UInt16(0))
            buffer.writeInteger(Constants.TNS_DATA_FLAGS_EOF)
            buffer.writeBytes(chunk)
        }
        let channel = decoderChannel()
        try channel.writeInbound(buffer)
        try expectCapturedRedirect(try messages(channel))
    }

    @Test func aListenerThatClosesEarlyIsAnUnreadableRedirect() throws {
        let channel = decoderChannel()
        let address = "(ADDRESS=(PROTOCOL=TCP)(HOST=node1)(PORT=152"
        var buffer = try bytes(Self.redirectHeader)
        buffer.writeInteger(UInt16(10 + address.utf8.count))
        buffer.writeInteger(UInt16(0))
        buffer.writeInteger(UInt8(6))
        buffer.writeInteger(UInt8(0))
        buffer.writeInteger(UInt16(0))
        buffer.writeInteger(Constants.TNS_DATA_FLAGS_EOF)
        buffer.writeString(address)
        try channel.writeInbound(buffer)
        #expect(try messages(channel).isEmpty)

        _ = try channel.finish(acceptAlreadyClosed: true)
        let decoded = try messages(channel)
        guard case .redirect(let redirect) = try #require(decoded.first) else {
            Issue.record("expected a redirect message, got \(decoded)")
            return
        }
        #expect(redirect.address.isEmpty)
        #expect(redirect.target == nil)
    }

    @Test func aCutOffPortIsNotAPort() {
        let redirect = OracleBackendMessage.Redirect(
            address: "(ADDRESS=(PROTOCOL=TCP)(HOST=node1)(PORT=152", connectData: nil
        )
        #expect(redirect.target == nil)
    }

    // Repairing 0xFF to U+FFFD triples it, and connect data past 65535 bytes trapped the
    // CONNECT encoder's length.
    @Test func invalidUTF8IsUnreadableNotRepaired() {
        var data = ByteBuffer()
        data.writeString("(ADDRESS=(PROTOCOL=TCP)(HOST=node1)(PORT=1521))\0")
        data.writeBytes(Array(repeating: UInt8(0xFF), count: 22_000))
        let redirect = OracleBackendMessage.Redirect(data: data)
        #expect(redirect.address.isEmpty)
        #expect(redirect.connectData == nil)
        #expect(redirect.target == nil)
    }

    @Test func aRedirectAfterTheAcceptIsNotWaitedOn() throws {
        var capabilities = Capabilities()
        capabilities.protocolVersion = 319
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt16(297))
        let result = try OracleBackendMessage.decode(
            from: &buffer, of: .redirect, context: .init(capabilities: capabilities)
        )
        #expect(result.lastPacket)
        guard case .redirect = result.0.first else {
            Issue.record("expected a redirect message, got \(result.0)")
            return
        }
    }

    @Test func anotherPacketDropsAnUnfinishedRedirect() throws {
        let refuse = "(DESCRIPTION=(ERR=12516))"
        var buffer = try bytes(Self.redirectHeader)
        buffer.writeInteger(UInt16(12 + refuse.utf8.count))
        buffer.writeInteger(UInt16(0))
        buffer.writeInteger(UInt8(4))
        buffer.writeInteger(UInt8(0))
        buffer.writeInteger(UInt16(0))
        buffer.writeInteger(UInt8(0))
        buffer.writeInteger(UInt8(0))
        buffer.writeInteger(UInt16(refuse.utf8.count))
        buffer.writeString(refuse)

        let channel = decoderChannel()
        try channel.writeInbound(buffer)
        let decoded = try messages(channel)
        #expect(decoded.count == 1)
        guard case .refuse(let refused) = try #require(decoded.first) else {
            Issue.record("expected a refuse message, got \(decoded)")
            return
        }
        #expect(refused.code == 12516)
    }

    @Test func redirectTargetMissingPort() {
        let redirect = OracleBackendMessage.Redirect(
            address: "(DESCRIPTION=(ADDRESS=(PROTOCOL=tcp)(HOST=node2)))",
            connectData: nil
        )
        #expect(redirect.target == nil)
    }
}
