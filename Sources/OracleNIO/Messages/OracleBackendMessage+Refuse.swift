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

/// The error a listener sends in a TNS refuse packet when it declines a connection
/// before the protocol handshake, for example for an unknown service name or SID.
public struct OracleListenerRefusedError: Error, Equatable, Sendable {
    public var code: Int?
    public var message: String
}

extension OracleBackendMessage {
    struct Refuse: PayloadDecodable, Hashable, Sendable {
        var userReason: UInt8
        var systemReason: UInt8
        var data: String

        var code: Int? {
            for key in ["(ERR=", "(CODE="] {
                guard let value = Self.number(after: key, in: self.data), value != 0 else {
                    continue
                }
                return value
            }
            return nil
        }

        private static func number(after marker: String, in text: String) -> Int? {
            let characters = Array(text)
            let pattern = Array(marker)
            guard pattern.count <= characters.count else { return nil }

            for start in 0...(characters.count - pattern.count) {
                guard Array(characters[start..<start + pattern.count]) == pattern else {
                    continue
                }
                let digits = characters[(start + pattern.count)...].prefix { $0.isNumber }
                return Int(String(digits))
            }
            return nil
        }

        var refusedError: OracleListenerRefusedError {
            OracleListenerRefusedError(code: self.code, message: self.data)
        }

        static func decode(
            from buffer: inout ByteBuffer,
            context: OracleBackendMessageDecoder.Context
        ) throws -> OracleBackendMessage.Refuse {
            let userReason = try buffer.throwingReadInteger(as: UInt8.self)
            let systemReason = try buffer.throwingReadInteger(as: UInt8.self)
            let dataLength = try buffer.throwingReadInteger(as: UInt16.self)
            let data =
                buffer.readString(length: min(Int(dataLength), buffer.readableBytes)) ?? ""
            return .init(
                userReason: userReason,
                systemReason: systemReason,
                data: data
            )
        }
    }
}
