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

/// A TNS redirect the connection did not end up following.
public struct OracleRedirectError: Error, Sendable, CustomStringConvertible {
    public enum Reason: Sendable, Hashable {
        /// ``OracleConnection/Configuration/followsListenerRedirects`` is off.
        case notFollowed
        /// The redirect named no host and port.
        case unreadable
        /// A plain TCP connection was redirected to a TCPS address.
        case transportMismatch
        /// The listeners kept redirecting past ``OracleConnection/maximumRedirects``.
        case tooManyRedirects
        /// The address the listener named could not be reached; ``underlying`` says why.
        case targetUnreachable
        /// The listener at the address the first one named refused the connection;
        /// ``underlying`` is its ``OracleListenerRefusedError``.
        case targetRefused
    }

    public var reason: Reason
    /// The host the listener redirected to, when the redirect named one.
    public var host: String?
    public var port: Int?
    public var underlying: (any Error)?

    var address: String
    var connectData: String?

    init(
        reason: Reason,
        redirect: OracleBackendMessage.Redirect,
        underlying: (any Error)? = nil
    ) {
        let target = redirect.target
        self.reason = reason
        self.host = target?.host
        self.port = target?.port
        self.underlying = underlying
        self.address = redirect.address
        self.connectData = redirect.connectData
    }

    public init(reason: Reason, host: String?, port: Int?, underlying: (any Error)? = nil) {
        self.reason = reason
        self.host = host
        self.port = port
        self.underlying = underlying
        self.address = ""
        self.connectData = nil
    }

    var redirect: OracleBackendMessage.Redirect {
        .init(address: self.address, connectData: self.connectData)
    }

    // The connect data echoes the client's host and OS user, so it stays out of this.
    public var description: String {
        let target = self.host.map { "\($0):\(self.port.map(String.init) ?? "?")" } ?? "unknown"
        return "OracleRedirectError(reason: \(self.reason), target: \(target))"
    }
}

extension OracleBackendMessage {
    // A 19c or later listener sends a REDIRECT holding only the data length, then the
    // data in the DATA packets after it. An older one sends it inline.
    struct Redirect: Hashable, Sendable {
        var address: String
        var connectData: String?

        init(address: String, connectData: String?) {
            self.address = address
            self.connectData = connectData
        }

        // `address\0connect-data`, or the address alone from an older listener. Invalid
        // UTF-8 is refused, not repaired: repair can triple the length, past what a
        // CONNECT can carry.
        init(data: ByteBuffer) {
            let bytes = data.getBytes(at: data.readerIndex, length: data.readableBytes) ?? []
            let payload = String(decoding: bytes, as: UTF8.self)
            guard Array(payload.utf8) == bytes else {
                self.init(address: "", connectData: nil)
                return
            }
            guard let separator = payload.firstIndex(of: "\0") else {
                self.init(address: payload, connectData: nil)
                return
            }
            let connectData = payload[payload.index(after: separator)...]
                .trimmingCharacters(in: "\0")
            self.init(
                address: String(payload[payload.startIndex..<separator]),
                connectData: connectData.isEmpty ? nil : connectData
            )
        }

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
            let pattern = Array("\(key)=").map { Character($0.uppercased()) }
            guard pattern.count <= characters.count else { return nil }

            for start in 0...(characters.count - pattern.count) {
                guard
                    characters[start..<start + pattern.count].map({ Character($0.uppercased()) })
                        == pattern
                else {
                    continue
                }
                // A value without its closing parenthesis is a cut-off descriptor, and
                // `(PORT=152` must not become port 152.
                let rest = characters[(start + pattern.count)...]
                guard let close = rest.firstIndex(of: ")") else { return nil }
                let trimmed = String(rest[..<close]).trimmingWhitespace()
                return trimmed.isEmpty ? nil : trimmed
            }
            return nil
        }
    }

    struct PendingRedirect {
        var length: Int
        var data: ByteBuffer

        var isComplete: Bool { self.data.readableBytes >= self.length }

        mutating func append(from buffer: inout ByteBuffer) {
            let wanted = min(self.length - self.data.readableBytes, buffer.readableBytes)
            if var chunk = buffer.readSlice(length: wanted) {
                self.data.writeBuffer(&chunk)
            }
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

    fileprivate func trimmingCharacters(in character: Character) -> String {
        let trimmedHead = self.drop { $0 == character }
        return String(trimmedHead.reversed().drop { $0 == character }.reversed())
    }
}
