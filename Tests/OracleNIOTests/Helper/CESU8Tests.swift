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
import Testing

@testable import OracleNIO

@Suite struct CESU8Tests {
    private func converted(_ bytes: [UInt8]) -> [UInt8] {
        let buffer = CESU8.utf16BigEndian(from: ByteBuffer(bytes: bytes))
        return buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
    }

    @Test func asciiAndLaoConvert() {
        // "Aດ່" as measured in an NVARCHAR2 column of a UTF8 national character set database
        #expect(converted([0x41, 0xE0, 0xBA, 0x94, 0xE0, 0xBB, 0x88]) == [0x00, 0x41, 0x0E, 0x94, 0x0E, 0xC8])
    }

    @Test func twoByteSequenceConverts() {
        #expect(converted([0xC3, 0xA9]) == [0x00, 0xE9])
    }

    /// Measured on Oracle 23ai: U+1D11E is stored as ED A0 B4 ED B4 9E, its two surrogates.
    @Test func surrogatePairConverts() {
        #expect(converted([0xED, 0xA0, 0xB4, 0xED, 0xB4, 0x9E]) == [0xD8, 0x34, 0xDD, 0x1E])
    }

    @Test func fourByteUTF8Converts() {
        #expect(converted([0xF0, 0x9D, 0x84, 0x9E]) == [0xD8, 0x34, 0xDD, 0x1E])
    }

    @Test func malformedBytesBecomeReplacementCharacters() {
        #expect(converted([0x80]) == [0xFF, 0xFD])
        #expect(converted([0xC0, 0xAF]) == [0xFF, 0xFD, 0xFF, 0xFD])
        #expect(converted([0xE0, 0x80, 0x80]) == [0xFF, 0xFD])
        #expect(converted([0xE0, 0xBA]) == [0xFF, 0xFD])
        #expect(converted([0xE0, 0xBA, 0x41]) == [0xFF, 0xFD, 0x00, 0x41])
        #expect(converted([0xF0, 0xED, 0xA0, 0x80]) == [0xFF, 0xFD, 0xD8, 0x00])
        #expect(converted([0xF4, 0x90, 0x80, 0x80]) == [0xFF, 0xFD])
    }

    @Test func emptyInputConvertsToEmptyOutput() {
        #expect(converted([]) == [])
    }
}
