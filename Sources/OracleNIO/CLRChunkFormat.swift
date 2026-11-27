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

import NIOConcurrencyHelpers
import NIOCore

// How a value longer than one length byte gives the length of each chunk. The server picks it for both directions
// with its own TNS_CCAP_BIG_CHUNK_CLR compile capability, which Oracle 11.2 does not set (go-ora reads it the same way).
@usableFromInline
enum CLRChunkFormat: UInt8, Sendable, Hashable {
    // One-byte lengths.
    case small = 0
    // UB4 lengths.
    case big = 1

    @inlinable
    var maximumChunkLength: Int {
        switch self {
        case .small: Constants.TNS_SMALL_CHUNK_SIZE
        case .big: Constants.TNS_CHUNK_SIZE
        }
    }
}

extension ByteBuffer {
    @inlinable
    mutating func readCLRChunkLength(_ format: CLRChunkFormat) -> UInt32? {
        switch format {
        case .small: self.readInteger(as: UInt8.self).map(UInt32.init)
        case .big: self.readUB4()
        }
    }

    mutating func throwingSkipCLRChunkLength(
        _ format: CLRChunkFormat, file: String = #fileID, line: Int = #line
    ) throws {
        switch format {
        case .small: try self.throwingSkipUB1(file: file, line: line)
        case .big: try self.throwingSkipUB4(file: file, line: line)
        }
    }

    @inlinable
    mutating func writeCLRChunkLength(_ length: Int, format: CLRChunkFormat) {
        switch format {
        case .small: self.writeInteger(UInt8(length))
        case .big: self.writeUB4(UInt32(length))
        }
    }

    // A value's encoder writes in the context's format, and tells the context's witness when it chunked.
    @inlinable
    mutating func writeOracleCLR<Bytes: Collection<UInt8>>(_ bytes: Bytes, context: OracleEncodingContext) {
        if bytes.count > Constants.TNS_MAX_SHORT_LENGTH {
            context.chunkWitness?.withLockedValue { $0 = true }
        }
        self.writeOracleCLR(bytes, format: context.clrChunkFormat)
    }

    // A length byte and the bytes, or chunks once the value is longer than a length byte can say.
    @inlinable
    mutating func writeOracleCLR<Bytes: Collection<UInt8>>(_ bytes: Bytes, format: CLRChunkFormat) {
        var remaining = bytes.count
        guard remaining > Constants.TNS_MAX_SHORT_LENGTH else {
            self.writeInteger(UInt8(remaining))
            self.writeBytes(bytes)
            return
        }
        self.writeInteger(Constants.TNS_LONG_LENGTH_INDICATOR)
        var start = bytes.startIndex
        while remaining > 0 {
            let chunkLength = Swift.min(remaining, format.maximumChunkLength)
            let end = bytes.index(start, offsetBy: chunkLength)
            self.writeCLRChunkLength(chunkLength, format: format)
            self.writeBytes(bytes[start..<end])
            start = end
            remaining -= chunkLength
        }
        self.writeCLRChunkLength(0, format: format)
    }
}
