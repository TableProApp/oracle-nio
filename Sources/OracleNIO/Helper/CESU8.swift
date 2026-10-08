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

/// Oracle's `UTF8` character set is CESU-8: a character outside the Basic Multilingual Plane is stored
/// as its two UTF-16 surrogates, three bytes each, which a UTF-8 decoder rejects.
enum CESU8 {
    /// Converts CESU-8 to UTF-16BE, the form an AL16UTF16 database sends. A malformed sequence becomes
    /// U+FFFD, as it does when UTF-16 is decoded. A four-byte UTF-8 sequence is accepted too.
    static func utf16BigEndian(from bytes: ByteBuffer) -> ByteBuffer {
        var output = ByteBuffer()
        output.reserveCapacity(bytes.readableBytes * 2)
        bytes.withUnsafeReadableBytes { input in
            var index = 0
            while index < input.count {
                let (unit, length) = Self.decode(input, at: index)
                index += length
                if unit > 0xFFFF {
                    let offset = unit - 0x10000
                    output.writeInteger(UInt16(0xD800 + (offset >> 10)))
                    output.writeInteger(UInt16(0xDC00 + (offset & 0x3FF)))
                } else {
                    output.writeInteger(UInt16(unit))
                }
            }
        }
        return output
    }

    private static let replacement: UInt32 = 0xFFFD

    /// Returns the code point or surrogate at `index` and the number of bytes it takes.
    private static func decode(_ input: UnsafeRawBufferPointer, at index: Int) -> (UInt32, Int) {
        let lead = UInt32(input[index])
        let length: Int
        let minimum: UInt32
        var value: UInt32
        switch lead {
        case 0x00...0x7F:
            return (lead, 1)
        case 0xC2...0xDF:
            (length, minimum, value) = (2, 0x80, lead & 0x1F)
        case 0xE0...0xEF:
            (length, minimum, value) = (3, 0x800, lead & 0x0F)
        case 0xF0...0xF4:
            (length, minimum, value) = (4, 0x10000, lead & 0x07)
        default:
            return (Self.replacement, 1)
        }
        for offset in 1..<length {
            guard index + offset < input.count else { return (Self.replacement, offset) }
            let next = UInt32(input[index + offset])
            guard next & 0xC0 == 0x80 else { return (Self.replacement, offset) }
            value = (value << 6) | (next & 0x3F)
        }
        guard value >= minimum, value <= 0x10FFFF else { return (Self.replacement, length) }
        if length == 4, (0xD800...0xDFFF).contains(value) { return (Self.replacement, length) }
        return (value, length)
    }
}
