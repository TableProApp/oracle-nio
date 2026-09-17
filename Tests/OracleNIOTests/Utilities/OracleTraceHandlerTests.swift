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

import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import Testing

@testable import OracleNIO

@Suite(.timeLimit(.minutes(5))) final class OracleTraceHandlerTests {
    @Test func tracer() async throws {
        let lines: NIOLockedValueBox<[String]> = .init([])
        let logger = Logger(label: "Tracer") { _ in
            Handler(lines: lines)
        }
        let handler = OracleTraceHandler(connectionID: 1, logger: logger, shouldLog: true)
        let channel = await NIOAsyncTestingChannel(handler: handler)
        try await channel.connect(to: .makeAddressResolvingHost("127.0.0.1", port: 1521))
        let buffer = ByteBuffer(bytes: [
            0x0, 0x1, 0x2, 0x3, 0x4, 0x5, 0x6, 0x7,
            0x8, 0x9, 0xa, 0xb, 0xc, 0xd, 0xe, 0xf,
            UInt8(ascii: "a"),
        ])
        try await channel.writeInbound(buffer)
        do {
            let lines = lines.withLockedValue { $0 }
            #expect(lines.count == 1)
            #expect(
                lines.first == """
                    Receiving packet [op 1] on socket 1
                    0000 : 00 01 02 03 04 05 06 07 |........|
                    0008 : 08 09 0A 0B 0C 0D 0E 0F |........|
                    0016 : 61                      |a       |

                    """)
        }
        try await channel.writeOutbound(buffer)
        do {
            let lines = lines.withLockedValue { $0 }
            #expect(lines.count == 2)
            #expect(
                lines.last == """
                    Sending packet [op 2] on socket 1
                    0000 : 00 01 02 03 04 05 06 07 |........|
                    0008 : 08 09 0A 0B 0C 0D 0E 0F |........|
                    0016 : 61                      |a       |

                    """)
        }
    }

    /// Everything after the authentication exchange begins is a credential, so the
    /// trace keeps the header and drops the body. The password verifier, the session
    /// key and a bearer token all ride in those bodies.
    @Test func redactsBodiesOnceAuthenticationBegins() async throws {
        let lines: NIOLockedValueBox<[String]> = .init([])
        let logger = Logger(label: "Tracer") { _ in Handler(lines: lines) }
        let box = OracleTraceRedactionBox()
        let handler = OracleTraceHandler(
            connectionID: 1, logger: logger, shouldLog: true, redactionBox: box
        )
        let channel = await NIOAsyncTestingChannel(handler: handler)
        try await channel.connect(to: .makeAddressResolvingHost("127.0.0.1", port: 1521))

        let secret = Array("hunter2-password-verifier".utf8)
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt32(8 + secret.count))
        buffer.writeInteger(UInt8(6))
        buffer.writeInteger(UInt8(0))
        buffer.writeInteger(UInt16(0))
        buffer.writeBytes(secret)

        box.redactFromNowOn()
        try await channel.writeOutbound(buffer)

        let logged = try #require(lines.withLockedValue { $0 }.last)
        #expect(logged.contains("redacted past authentication"))
        #expect(logged.contains("body \(secret.count) bytes"))
        #expect(!logged.contains("hunter2"))
        #expect(!logged.contains("68 75 6E"))
    }

    @Test func dumpsEverythingBeforeAuthentication() async throws {
        let lines: NIOLockedValueBox<[String]> = .init([])
        let logger = Logger(label: "Tracer") { _ in Handler(lines: lines) }
        let handler = OracleTraceHandler(
            connectionID: 1, logger: logger, shouldLog: true,
            redactionBox: OracleTraceRedactionBox()
        )
        let channel = await NIOAsyncTestingChannel(handler: handler)
        try await channel.connect(to: .makeAddressResolvingHost("127.0.0.1", port: 1521))
        try await channel.writeOutbound(ByteBuffer(bytes: Array(repeating: UInt8(0xAB), count: 12)))

        let logged = try #require(lines.withLockedValue { $0 }.last)
        #expect(logged.contains("AB AB"))
        #expect(!logged.contains("redacted"))
    }

    /// The flag never clears, so one authentication packet redacts the rest of the
    /// connection rather than only the packet that set it.
    @Test func redactionIsPermanentForTheConnection() {
        let box = OracleTraceRedactionBox()
        #expect(box.isRedacted == false)
        box.redactFromNowOn()
        box.redactFromNowOn()
        #expect(box.isRedacted)
    }

    final class Handler: LogHandler, @unchecked Sendable {
        var metadata: Logger.Metadata = [:]
        var logLevel: Logger.Level = .trace

        let lines: NIOLockedValueBox<[String]>

        init(lines: NIOLockedValueBox<[String]>) {
            self.lines = lines
        }

        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get {
                metadata[key]
            }
            set(newValue) {
                metadata[key] = newValue
            }
        }

        func log(
            level: Logger.Level,
            message: Logger.Message,
            metadata: Logger.Metadata?,
            source: String,
            file: String,
            function: String,
            line: UInt
        ) {
            lines.withLockedValue {
                $0.append(message.description)
            }
        }
    }
}
