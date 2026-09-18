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

extension OracleBackendMessage {
    struct ServerSidePiggyback: PayloadDecodable, Hashable {
        /// Indicates if the statement cache should be reset.
        ///
        /// Only applicable if we are currently establishing a DRCP session.
        let resetStatementCache: Bool

        /// Server side piggyback operation code.
        enum Code: UInt8 {
            case queryCacheInvalidation = 1
            case osPidMts = 2
            case traceEvent = 3
            case sessRet = 4
            case sync = 5
            case ltxID = 7
            case acReplayContext = 8
            case extSync = 9
            case sessionSignature = 10
        }

        /// Every count and length in a piggyback is a variable-length UB integer, a length byte followed by that
        /// many bytes, and every value is a length-prefixed byte string. Read as fixed-width integers instead, the
        /// `sync` piggyback Oracle 23ai sends after `ALTER SESSION` claimed 274 elements where it carried 18, so the
        /// decoder waited for bytes the server never sent and the connection hung.
        static func decode(
            from buffer: inout ByteBuffer,
            context: OracleBackendMessageDecoder.Context
        ) throws -> OracleBackendMessage.ServerSidePiggyback {
            let rawOpCode = try buffer.throwingReadInteger(as: UInt8.self)
            guard let opCode = Code(rawValue: rawOpCode) else {
                throw OraclePartialDecodingError.unknownServerSidePiggyback(opCode: rawOpCode)
            }
            switch opCode {
            case .ltxID:
                try buffer.throwingSkipBytesWithLength()
            case .queryCacheInvalidation, .traceEvent:
                break
            case .osPidMts:
                try buffer.throwingSkipUB2()
                try buffer.throwingSkipBytes()
            case .sync:
                try buffer.throwingSkipUB2()  // number of DTYs
                try buffer.throwingSkipUB1()  // length of DTYs
                let numberOfElements = try buffer.throwingReadUB2()
                try buffer.throwingSkipUB1()  // length
                for _ in 0..<numberOfElements {
                    try buffer.throwingSkipKeywordValuePair()
                }
                try buffer.throwingSkipUB4()  // overall flags
            case .extSync:
                try buffer.throwingSkipUB2()  // number of DTYs
                try buffer.throwingSkipUB1()  // length of DTYs
            case .acReplayContext:
                try buffer.throwingSkipUB2()  // number of DTYs
                try buffer.throwingSkipUB1()  // length of DTYs
                try buffer.throwingSkipUB4()  // flags
                try buffer.throwingSkipUB4()  // error code
                try buffer.throwingSkipUB1()  // queue
                try buffer.throwingSkipBytesWithLength()  // replay context
            case .sessRet:
                try buffer.throwingSkipUB2()  // number of DTYs
                try buffer.throwingSkipUB1()  // length of DTYs
                let numberOfElements = try buffer.throwingReadUB2()
                if numberOfElements > 0 {
                    try buffer.throwingSkipUB1()  // length
                    for _ in 0..<numberOfElements {
                        try buffer.throwingSkipKeywordValuePair()
                    }
                }
                let flags = try buffer.throwingReadUB4()  // session flags
                let resetStatementCache = flags & Constants.TNS_SESSGET_SESSION_CHANGED != 0
                try buffer.throwingSkipUB4()  // session id
                try buffer.throwingSkipUB2()  // serial number
                return .init(resetStatementCache: resetStatementCache)
            case .sessionSignature:
                try buffer.throwingSkipUB2()  // number of DTYs
                try buffer.throwingSkipUB1()  // length of DTYs
                try buffer.throwingSkipUB8()  // signature flags
                try buffer.throwingSkipUB8()  // client signature
                try buffer.throwingSkipUB8()  // server signature
            }

            return .init(resetStatementCache: false)
        }
    }
}

extension ByteBuffer {
    /// Skips one keyword/value pair of a piggyback: a text value, a binary value and a trailing number, each
    /// announced by a UB2 length, and each value length-prefixed.
    fileprivate mutating func throwingSkipKeywordValuePair() throws {
        if try self.throwingReadUB2() > 0 {
            try self.throwingSkipBytes()
        }
        if try self.throwingReadUB2() > 0 {
            try self.throwingSkipBytes()
        }
        try self.throwingSkipUB2()
    }

    /// Skips a length-prefixed byte string, chunked or not.
    fileprivate mutating func throwingSkipBytes() throws {
        _ = try self.throwingReadOracleSpecificLengthPrefixedSlice()
    }

    /// Skips a byte string preceded by a UB4 length, which is zero when the string is absent.
    fileprivate mutating func throwingSkipBytesWithLength() throws {
        if try self.throwingReadUB4() > 0 {
            try self.throwingSkipBytes()
        }
    }
}
