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

import struct NIOCore.ByteBuffer

extension ByteBuffer {
    mutating func throwingSkipUB1(file: String = #fileID, line: Int = #line) throws {
        try self.throwingMoveReaderIndex(forwardBy: 1, file: file, line: line)
    }

    @inlinable
    mutating func throwingSkipUB2(file: String = #fileID, line: Int = #line) throws {
        try throwingSkipUB(2, file: file, line: line)
    }

    @inlinable
    mutating func readUB2() -> UInt16? {
        guard let length = readUBLength() else { return nil }
        switch length {
        case 0:
            return 0
        case 1:
            return self.readInteger(as: UInt8.self).map(UInt16.init(_:))
        case 2:
            return self.readInteger(as: UInt16.self)
        default:
            return nil
        }
    }

    @inlinable
    mutating func throwingReadUB2(
        file: String = #fileID, line: Int = #line
    ) throws -> UInt16 {
        try self.readUB2().value(
            or: OraclePartialDecodingError.expectedAtLeastNRemainingBytes(
                MemoryLayout<UInt16>.size, actual: self.readableBytes,
                file: file, line: line
            )
        )
    }

    @inlinable
    mutating func readUB4() -> UInt32? {
        guard let length = readUBLength() else { return nil }
        switch length {
        case 0:
            return 0
        case 1:
            return self.readInteger(as: UInt8.self).map(UInt32.init(_:))
        case 2:
            return self.readInteger(as: UInt16.self).map(UInt32.init(_:))
        case 3:
            guard self.readableBytes >= 3,
                let high = self.readInteger(as: UInt8.self),
                let middle = self.readInteger(as: UInt8.self),
                let low = self.readInteger(as: UInt8.self)
            else { return nil }
            return UInt32(high) << 16 | UInt32(middle) << 8 | UInt32(low)
        case 4:
            return self.readInteger(as: UInt32.self)
        default:
            return nil
        }
    }

    @inlinable
    mutating func throwingReadUB4(
        file: String = #fileID, line: Int = #line
    ) throws -> UInt32 {
        try self.readUB4().value(
            or: OraclePartialDecodingError.expectedAtLeastNRemainingBytes(
                MemoryLayout<Int8>.size, actual: self.readableBytes,
                file: file, line: line
            )
        )
    }

    mutating func throwingSkipUB4(file: String = #fileID, line: Int = #line) throws {
        try throwingSkipUB(4, file: file, line: line)
    }

    mutating func readUB8() -> UInt64? {
        guard let length = readUBLength() else { return nil }
        switch length {
        case 0:
            return 0
        case 1:
            return self.readInteger(as: UInt8.self).map(UInt64.init)
        case 2:
            return self.readInteger(as: UInt16.self).map(UInt64.init)
        case 3:
            guard self.readableBytes >= 3,
                let high = self.readInteger(as: UInt8.self),
                let middle = self.readInteger(as: UInt8.self),
                let low = self.readInteger(as: UInt8.self)
            else { return nil }
            return UInt64(high) << 16 | UInt64(middle) << 8 | UInt64(low)
        case 4:
            return self.readInteger(as: UInt32.self).map(UInt64.init)
        case 8:
            return self.readInteger(as: UInt64.self)
        default:
            return nil
        }
    }

    mutating func throwingReadUB8(
        file: String = #fileID, line: Int = #line
    ) throws -> UInt64 {
        try self.readUB8().value(
            or: OraclePartialDecodingError.expectedAtLeastNRemainingBytes(
                MemoryLayout<UInt8>.size, actual: self.readableBytes,
                file: file, line: line
            )
        )
    }

    mutating func throwingSkipUB8(file: String = #fileID, line: Int = #line) throws {
        try throwingSkipUB(8, file: file, line: line)
    }

    @inlinable
    mutating func readUBLength() -> UInt8? {
        guard var length = self.readInteger(as: UInt8.self) else { return nil }
        if length & 0x80 != 0 {
            length = length & 0x7f
        }
        return length
    }

    mutating func writeUB2(_ integer: UInt16) {
        switch integer {
        case 0:
            self.writeInteger(UInt8(0))
        case 1...UInt16(UInt8.max):
            self.writeInteger(UInt8(1))
            self.writeInteger(UInt8(integer))
        default:
            self.writeInteger(UInt8(2))
            self.writeInteger(integer)
        }
    }

    @inlinable
    mutating func writeUB4(_ integer: UInt32) {
        switch integer {
        case 0:
            self.writeInteger(UInt8(0))
        case 1...UInt32(UInt8.max):
            self.writeInteger(UInt8(1))
            self.writeInteger(UInt8(integer))
        case (UInt32(UInt8.max) + 1)...UInt32(UInt16.max):
            self.writeInteger(UInt8(2))
            self.writeInteger(UInt16(integer))
        default:
            self.writeInteger(UInt8(4))
            self.writeInteger(integer)
        }
    }

    mutating func writeUB8(_ integer: UInt64) {
        switch integer {
        case 0:
            self.writeInteger(UInt8(0))
        case 1...UInt64(UInt8.max):
            self.writeInteger(UInt8(1))
            self.writeInteger(UInt8(integer))
        case (UInt64(UInt8.max) + 1)...UInt64(UInt16.max):
            self.writeInteger(UInt8(2))
            self.writeInteger(UInt16(integer))
        case (UInt64(UInt16.max) + 1)...UInt64(UInt32.max):
            self.writeInteger(UInt8(4))
            self.writeInteger(UInt32(integer))
        default:
            self.writeInteger(UInt8(8))
            self.writeInteger(integer)
        }
    }

    /// A packet can end inside an integer. Skipping only the part that arrived leaves the rest to be
    /// read as the next message, so a short field throws and the decoder retries with the next packet.
    @inlinable
    @inline(__always)
    mutating func throwingSkipUB(_ maxLength: Int, file: String = #fileID, line: Int = #line) throws {
        guard let length = readUBLength().flatMap(Int.init) else {
            throw OraclePartialDecodingError.expectedAtLeastNRemainingBytes(
                MemoryLayout<UInt8>.size,
                actual: self.readableBytes,
                file: file, line: line
            )
        }
        guard length <= maxLength else {
            throw OraclePartialDecodingError.fieldNotDecodable(
                type: UInt.self, file: file, line: line
            )
        }
        try self.throwingMoveReaderIndex(forwardBy: length, file: file, line: line)
    }
}

extension ByteBuffer {
    /// Skips a value that may be chunked: a length byte, where 0 and `TNS_NULL_LENGTH_INDICATOR` mean
    /// NULL and `TNS_LONG_LENGTH_INDICATOR` starts UB4-prefixed chunks ending in a zero-length one.
    /// Throws when the value continues in the next packet, so the decoder retries with it.
    mutating func throwingSkipRawBytesChunked(file: String = #fileID, line: Int = #line) throws {
        let length = try self.throwingReadInteger(as: UInt8.self, file: file, line: line)
        switch length {
        case 0, Constants.TNS_NULL_LENGTH_INDICATOR:
            return
        case Constants.TNS_LONG_LENGTH_INDICATOR:
            while true {
                let chunkLength = try self.throwingReadUB4(file: file, line: line)
                if chunkLength == 0 { return }
                try self.throwingMoveReaderIndex(forwardBy: Int(chunkLength), file: file, line: line)
            }
        default:
            try self.throwingMoveReaderIndex(forwardBy: Int(length), file: file, line: line)
        }
    }
}
