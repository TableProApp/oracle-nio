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

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

extension OracleBackendMessage {
    struct Accept: PayloadDecodable, Hashable {
        /// The shortest accept packet any Oracle server sends: the 8-byte packet header
        /// plus the 24-byte body an 11.x server emits. `go-ora` rejects anything shorter
        /// outright, and so do we, because every offset below is a fixed position rather
        /// than a sequential read.
        static let minimumPacketSize = 32

        /// The connect flags, ACFL0 and ACFL1, as offsets into the WHOLE packet, header
        /// included. That is how `go-ora` (`packetData[22]`, `packetData[23]`) and
        /// python-oracledb (body offset 14 past an 8-byte header) address them, and the
        /// buffer handed to `decode` is the whole packet with the reader moved past the
        /// header. Addressing them relative to the reader is what put this read 8 bytes
        /// late and made the driver deaf to a server disabling native network encryption.
        static let connectFlags0Offset = 22
        static let connectFlags1Offset = 23

        var newCapabilities: Capabilities

        static func decode(
            from buffer: inout ByteBuffer,
            context: OracleBackendMessageDecoder.Context
        ) throws -> OracleBackendMessage.Accept {
            guard buffer.writerIndex >= Self.minimumPacketSize else {
                throw OraclePartialDecodingError.expectedAtLeastNRemainingBytes(
                    Self.minimumPacketSize, actual: buffer.writerIndex
                )
            }

            let protocolVersion =
                try buffer.throwingReadInteger(as: UInt16.self)

            if protocolVersion < Constants.TNS_VERSION_MIN_ACCEPTED {
                throw OracleSQLError.serverVersionNotSupported
            }

            let protocolOptions =
                try buffer.throwingReadInteger(as: UInt16.self)

            var caps = context.capabilities

            let acceptFlags0 =
                buffer.getInteger(at: Self.connectFlags0Offset, as: UInt8.self) ?? 0
            let acceptFlags1 =
                buffer.getInteger(at: Self.connectFlags1Offset, as: UInt8.self) ?? 0

            try buffer.throwingMoveReaderIndex(forwardBy: 20)
            let sdu: UInt32
            let flags: UInt32
            if protocolVersion >= Constants.TNS_VERSION_MIN_LARGE_SDU {
                sdu = try buffer.throwingReadInteger(as: UInt32.self)
                if protocolVersion >= Constants.TNS_VERSION_MIN_OOB_CHECK {
                    try buffer.throwingMoveReaderIndex(forwardBy: 5)
                    flags = try buffer.throwingReadInteger(as: UInt32.self)
                } else {
                    flags = 0
                }
            } else {
                sdu = caps.sdu
                flags = 0
            }

            caps.sdu = sdu
            caps.adjustForProtocol(
                version: protocolVersion, options: protocolOptions, flags: flags,
                acceptFlags0: acceptFlags0, acceptFlags1: acceptFlags1
            )

            return .init(newCapabilities: caps)
        }
    }
}
