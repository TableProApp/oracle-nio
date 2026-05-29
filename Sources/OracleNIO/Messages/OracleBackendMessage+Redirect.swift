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

/// Carries a TNS redirect target up the connection startup so the connect routine can
/// open a fresh connection to the address the listener handed back.
struct OracleRedirectError: Error, Equatable, Sendable {
    var address: String
    var connectData: String?
}

extension OracleBackendMessage {
    /// A TNS redirect packet, sent by a listener (RAC SCAN, shared server/MTS, or a
    /// load-balancing broker) to point the client at the address that actually serves
    /// the session. The client must open a fresh connection to ``address`` and resend
    /// the connect request, carrying ``connectData`` when present.
    struct Redirect: PayloadDecodable, Hashable, Sendable {
        var address: String
        var connectData: String?

        static func decode(
            from buffer: inout ByteBuffer,
            context: OracleBackendMessageDecoder.Context
        ) throws -> OracleBackendMessage.Redirect {
            let dataLength = try buffer.throwingReadInteger(as: UInt16.self)
            let length = min(Int(dataLength), buffer.readableBytes)
            let payload = buffer.readString(length: length) ?? ""

            if let separator = payload.firstIndex(of: "\0") {
                let address = String(payload[payload.startIndex..<separator])
                let connectData = String(payload[payload.index(after: separator)...])
                return .init(
                    address: address,
                    connectData: connectData.isEmpty ? nil : connectData
                )
            }

            return .init(address: payload, connectData: nil)
        }

        /// Extracts the host and port from the redirect descriptor's first ADDRESS clause,
        /// e.g. `(DESCRIPTION=(ADDRESS=(PROTOCOL=tcp)(HOST=node1)(PORT=1521))...)`.
        var target: (host: String, port: Int)? {
            guard
                let host = Self.value(of: "HOST", in: self.address),
                let portString = Self.value(of: "PORT", in: self.address),
                let port = Int(portString)
            else {
                return nil
            }
            return (host, port)
        }

        var usesTCPS: Bool {
            Self.value(of: "PROTOCOL", in: self.address)?.lowercased() == "tcps"
        }

        private static func value(of key: String, in descriptor: String) -> String? {
            let characters = Array(descriptor)
            let pattern = Array("\(key)=")
            guard pattern.count <= characters.count else { return nil }

            for start in 0...(characters.count - pattern.count) {
                guard
                    Array(characters[start..<start + pattern.count]).map({ Character($0.uppercased()) })
                        == pattern.map({ Character($0.uppercased()) })
                else {
                    continue
                }
                let value = characters[(start + pattern.count)...].prefix { $0 != ")" }
                let trimmed = String(value).trimmingWhitespace()
                return trimmed.isEmpty ? nil : trimmed
            }
            return nil
        }
    }
}

extension StringProtocol {
    fileprivate func trimmingWhitespace() -> String {
        let trimmedHead = self.drop { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
        let trimmedTail = trimmedHead.reversed().drop {
            $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r"
        }
        return String(trimmedTail.reversed())
    }
}
