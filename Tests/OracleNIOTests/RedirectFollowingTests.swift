//===----------------------------------------------------------------------===//
//
// This source file is part of the OracleNIO open source project
//
// Copyright (c) 2026 Timo Zacherl and the OracleNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE for license information
// See CONTRIBUTORS.md for the list of OracleNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing

@testable import OracleNIO

// Listeners on loopback that answer a CONNECT the way a 23ai listener does: a REDIRECT
// holding only the data length, then a DATA packet with `address\0connect-data`.
@Suite(.timeLimit(.minutes(1)), .serialized) struct RedirectFollowingTests {
    struct ReceivedConnect: Sendable {
        var packetFlags: UInt8
        var connectData: String
    }

    final class Listener: Sendable {
        let channel: Channel
        let received: NIOLockedValueBox<[ReceivedConnect]>

        var port: Int { self.channel.localAddress!.port! }

        init(reply: @escaping @Sendable (_ port: Int) -> ByteBuffer?) async throws {
            let received = NIOLockedValueBox<[ReceivedConnect]>([])
            let portBox = NIOLockedValueBox(0)
            self.received = received
            self.channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .childChannelInitializer { child in
                    child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(
                            ConnectHandler(received: received) {
                                reply(portBox.withLockedValue { $0 })
                            }
                        )
                    }
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            portBox.withLockedValue { $0 = self.channel.localAddress!.port! }
        }

        func close() async throws {
            try await self.channel.close()
        }
    }

    final class ConnectHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        private var buffer = ByteBuffer()
        private var answered = false
        private let received: NIOLockedValueBox<[ReceivedConnect]>
        private let reply: () -> ByteBuffer?

        init(received: NIOLockedValueBox<[ReceivedConnect]>, reply: @escaping () -> ByteBuffer?) {
            self.received = received
            self.reply = reply
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var incoming = self.unwrapInboundIn(data)
            self.buffer.writeBuffer(&incoming)
            guard !self.answered, let connect = self.completeConnect() else { return }
            self.answered = true
            self.received.withLockedValue { $0.append(connect) }
            // No reply is a listener that accepted the TCP connection and went quiet.
            guard let reply = self.reply() else { return }
            context.writeAndFlush(self.wrapOutboundOut(reply)).whenComplete { _ in
                context.close(promise: nil)
            }
        }

        // The CONNECT carries its data inline up to 230 bytes and in one DATA packet
        // after that.
        private func completeConnect() -> ReceivedConnect? {
            guard
                let length = self.buffer.getInteger(at: 0, as: UInt16.self).map(Int.init),
                self.buffer.readableBytes >= length,
                let flags = self.buffer.getInteger(at: 5, as: UInt8.self),
                let dataLength = self.buffer.getInteger(at: 24, as: UInt16.self).map(Int.init)
            else { return nil }
            if length >= 74 + dataLength {
                let data = self.buffer.getString(at: 74, length: dataLength) ?? ""
                return .init(packetFlags: flags, connectData: data)
            }
            guard
                let next = self.buffer.getInteger(at: length, as: UInt16.self).map(Int.init),
                self.buffer.readableBytes >= length + next
            else { return nil }
            let data = self.buffer.getString(at: length + 10, length: next - 10) ?? ""
            return .init(packetFlags: flags, connectData: data)
        }
    }

    static func redirect(toPort port: Int, connectData: String?) -> ByteBuffer {
        let address = "(ADDRESS=(PROTOCOL=TCP)(HOST=127.0.0.1)(PORT=\(port)))"
        let payload = Array((connectData.map { "\(address)\0\($0)" } ?? address).utf8)
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt16(10))
        buffer.writeInteger(UInt16(0))
        buffer.writeInteger(PacketType.redirect.rawValue)
        buffer.writeInteger(UInt8(0x02))
        buffer.writeInteger(UInt16(0))
        buffer.writeInteger(UInt16(payload.count))
        buffer.writeInteger(UInt16(10 + payload.count))
        buffer.writeInteger(UInt16(0))
        buffer.writeInteger(PacketType.data.rawValue)
        buffer.writeInteger(UInt8(0))
        buffer.writeInteger(UInt16(0))
        buffer.writeInteger(Constants.TNS_DATA_FLAGS_EOF)
        buffer.writeBytes(payload)
        return buffer
    }

    static func refuse(code: Int) -> ByteBuffer {
        let data = "(DESCRIPTION=(TMP=)(VSNNUM=0)(ERR=\(code)))"
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt16(12 + data.utf8.count))
        buffer.writeInteger(UInt16(0))
        buffer.writeInteger(PacketType.refuse.rawValue)
        buffer.writeInteger(UInt8(0))
        buffer.writeInteger(UInt16(0))
        buffer.writeInteger(UInt8(0))
        buffer.writeInteger(UInt8(0))
        buffer.writeInteger(UInt16(data.utf8.count))
        buffer.writeString(data)
        return buffer
    }

    static func configuration(port: Int) -> OracleConnection.Configuration {
        var configuration = OracleConnection.Configuration(
            host: "127.0.0.1", port: port, service: .serviceName("orcl"),
            username: "scott", password: "tiger"
        )
        configuration.options.connectTimeout = .seconds(5)
        configuration.options.loginTimeout = .seconds(20)
        return configuration
    }

    static func connectError(_ configuration: OracleConnection.Configuration) async -> OracleSQLError? {
        do {
            let connection = try await OracleConnection.connect(
                configuration: configuration, id: 1, logger: Logger(label: "redirect-test")
            )
            try? await connection.close()
            return nil
        } catch {
            return error as? OracleSQLError
        }
    }

    @Test func followsARedirectWithTheListenersDescriptorAndTheRedirectFlag() async throws {
        let handedBack = "(DESCRIPTION=(CONNECT_DATA=(SERVICE_NAME=orcl)(SERVER=dedicated)(INSTANCE_NAME=orcl1)))"
        let target = try await Listener { _ in Self.refuse(code: 12514) }
        let scan = try await Listener { [targetPort = target.port] _ in
            Self.redirect(toPort: targetPort, connectData: handedBack)
        }

        let error = await Self.connectError(Self.configuration(port: scan.port))

        let redirect = try #require(error?.underlying as? OracleRedirectError)
        #expect(redirect.reason == .targetRefused)
        #expect(redirect.port == target.port)
        let refused = try #require(redirect.underlying as? OracleListenerRefusedError)
        #expect(refused.code == 12514)
        let first = try #require(scan.received.withLockedValue { $0 }.first)
        #expect(first.packetFlags == 0)
        let hop = try #require(target.received.withLockedValue { $0 }.first)
        #expect(hop.packetFlags == Constants.TNS_PACKET_FLAG_REDIRECT)
        #expect(hop.connectData == handedBack)
        try await scan.close()
        try await target.close()
    }

    @Test func stopsAfterTheMaximumNumberOfRedirects() async throws {
        let loop = try await Listener { ownPort in
            Self.redirect(toPort: ownPort, connectData: "(DESCRIPTION=(CONNECT_DATA=(SERVICE_NAME=orcl)))")
        }

        let error = await Self.connectError(Self.configuration(port: loop.port))

        let redirect = try #require(error?.underlying as? OracleRedirectError)
        #expect(redirect.reason == .tooManyRedirects)
        #expect(redirect.port == loop.port)
        #expect(loop.received.withLockedValue { $0.count } == OracleConnection.maximumRedirects + 1)
        try await loop.close()
    }

    @Test func refusedTargetIsTheRedirectsFailureAndFailsAtOnce() async throws {
        let closed = try await Listener { _ in ByteBuffer() }
        let closedPort = closed.port
        try await closed.close()
        let scan = try await Listener { _ in
            Self.redirect(toPort: closedPort, connectData: "(DESCRIPTION=(CONNECT_DATA=(SERVICE_NAME=orcl)))")
        }

        let started = ContinuousClock.now
        let error = await Self.connectError(Self.configuration(port: scan.port))

        #expect(ContinuousClock.now - started < .seconds(3))
        let redirect = try #require(error?.underlying as? OracleRedirectError)
        #expect(redirect.reason == .targetUnreachable)
        #expect(redirect.host == "127.0.0.1")
        #expect(redirect.port == closedPort)
        #expect(redirect.underlying != nil)
        try await scan.close()
    }

    @Test func aRefusedPortFailsAtOnce() async throws {
        let closed = try await Listener { _ in nil }
        let closedPort = closed.port
        try await closed.close()

        let started = ContinuousClock.now
        do {
            let connection = try await OracleConnection.connect(
                configuration: Self.configuration(port: closedPort), id: 1, logger: Logger(label: "redirect-test")
            )
            try? await connection.close()
            Issue.record("a closed port accepted the connection")
        } catch {
            #expect(ContinuousClock.now - started < .seconds(3))
            #if canImport(Network)
                #expect("\(error)".contains("ECONNREFUSED") || "\(error)".contains("refused"), "\(error)")
            #endif
        }
    }

    // The deadline covers every hop, so a target that never answers ends the connect when
    // one login would have.
    @Test func theLoginDeadlineCoversTheWholeChain() async throws {
        let silent = try await Listener { _ in nil }
        let scan = try await Listener { [silentPort = silent.port] _ in
            Self.redirect(toPort: silentPort, connectData: "(DESCRIPTION=(CONNECT_DATA=(SERVICE_NAME=orcl)))")
        }
        var configuration = Self.configuration(port: scan.port)
        configuration.options.loginTimeout = .seconds(1)

        let started = ContinuousClock.now
        let error = await Self.connectError(configuration)

        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(error?.code == .loginHandshakeTimedOut)
        try await scan.close()
        try await silent.close()
    }

    @Test func aCallerThatDoesNotFollowGetsTheTarget() async throws {
        let scan = try await Listener { _ in
            Self.redirect(toPort: 1599, connectData: "(DESCRIPTION=(CONNECT_DATA=(SERVICE_NAME=orcl)))")
        }
        var configuration = Self.configuration(port: scan.port)
        configuration.followsListenerRedirects = false

        let error = await Self.connectError(configuration)

        let redirect = try #require(error?.underlying as? OracleRedirectError)
        #expect(redirect.reason == .notFollowed)
        #expect(redirect.host == "127.0.0.1")
        #expect(redirect.port == 1599)
        #expect(scan.received.withLockedValue { $0.count } == 1)
        try await scan.close()
    }
}
