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

import Atomics
import Foundation
import Logging
import NIOCore
import NIOPosix

final class OracleTraceHandler: ChannelDuplexHandler, Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer

    private let logger: Logger
    private let shouldLog: Bool
    private let connectionID: OracleConnection.ID
    private let redactionBox: OracleTraceRedactionBox
    private let dumpsCredentials: Bool

    private let packetCount = ManagedAtomic(0)

    init(
        connectionID: OracleConnection.ID,
        logger: Logger,
        shouldLog: Bool? = nil,
        redactionBox: OracleTraceRedactionBox = OracleTraceRedactionBox(),
        dumpsCredentials: Bool = false
    ) {
        self.redactionBox = redactionBox
        self.dumpsCredentials = dumpsCredentials
        if let shouldLog {
            self.shouldLog = shouldLog
        } else {
            let envValue =
                getenv("ORANIO_TRACE_PACKETS")
                .flatMap { String(cString: $0) }
                .flatMap(Int.init) ?? 0
            self.shouldLog = envValue != 0
        }
        self.logger = logger
        self.connectionID = connectionID
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if self.shouldLog {
            let buffer = self.unwrapInboundIn(data)
            let count = self.packetCount.wrappingIncrementThenLoad(ordering: .relaxed)
            self.logger.info("\(self.describe(buffer, direction: "Receiving", op: count))")
        }
        context.fireChannelRead(data)
    }

    /// A full hex dump until the authentication exchange begins, then headers only. The
    /// header is what diagnoses a stalled handshake: the packet type, its length and the
    /// order the two ends sent them in. The body past that point is a credential.
    private func describe(_ buffer: ByteBuffer, direction: String, op: Int) -> String {
        let prefix = "\(direction) packet [op \(op)] on socket \(self.connectionID)"
        guard self.redactionBox.isRedacted, !self.dumpsCredentials else {
            return """
                \(prefix)
                \(buffer.oracleHexDump())
                """
        }
        let length = buffer.getInteger(at: buffer.readerIndex, as: UInt32.self) ?? 0
        let typeByte =
            buffer.getInteger(at: buffer.readerIndex + MemoryLayout<UInt32>.size, as: UInt8.self) ?? 0
        let flags =
            buffer.getInteger(
                at: buffer.readerIndex + MemoryLayout<UInt32>.size + MemoryLayout<UInt8>.size,
                as: UInt8.self
            ) ?? 0
        let type = PacketType(rawValue: typeByte).map(String.init(describing:)) ?? "unknown(\(typeByte))"
        let bodyBytes = max(0, buffer.readableBytes - Self.headerSize)
        return """
            \(prefix) redacted past authentication: \
            type \(type), flags \(flags), declared length \(length), body \(bodyBytes) bytes
            """
    }

    private static let headerSize = 8

    func write(
        context: ChannelHandlerContext,
        data: NIOAny,
        promise: EventLoopPromise<Void>?
    ) {
        if self.shouldLog {
            let buffer = self.unwrapOutboundIn(data)
            let count = self.packetCount.wrappingIncrementThenLoad(ordering: .relaxed)
            self.logger.info("\(self.describe(buffer, direction: "Sending", op: count))")
        }
        context.write(data, promise: promise)
    }
}
