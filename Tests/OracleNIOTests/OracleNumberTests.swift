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

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif


@Suite struct OracleNumberTests {
    @Test func description() {
        #expect(OracleNumber(1.001).description == "1.001")
    }

    @Test func initializers() {
        #expect(OracleNumber("1.001") == 1.001)
        #expect(OracleNumber("hello") == nil)
        #expect(OracleNumber(Int(1)) == 1)
        #expect(OracleNumber(Float(1.0)) == 1.0)
        #expect(OracleNumber(Double(1.1)) == 1.1)

        let integerLiteral: OracleNumber = 1
        #expect(integerLiteral == 1)
        let floatLiteral: OracleNumber = 1.0
        #expect(floatLiteral == 1.0)
    }

    /// Wire bytes measured on Oracle 23ai.
    private static let measured: [(hex: String, text: String)] = [
        ("cc0d23394f5b0d23394f5b0d23", "123456789012345678901234"),
        ("4559432d170b59432d1766", "-0.000000000000123456789012345678"),
        ("c00b", "0.1"),
        ("3e6066", "-5"),
        ("c202", "100"),
        ("c902182e445a02182e441a", "12345678901234567.25"),
        ("355c4f441d62212f182b5d66", "-9223372036854775808"),
        ("ca0a1722490445374e3b09", "9223372036854775808"),
        ("80", "0"),
    ]

    @Test func descriptionKeepsEveryDigit() throws {
        for testCase in Self.measured {
            var buffer = ByteBuffer(bytes: Self.bytes(testCase.hex))
            let number = try OracleNumber(from: &buffer, type: .number, context: .default)
            #expect(number.description == testCase.text)
        }
    }

    /// A NUMBER holds more digits than any integer type, and the decode used to trap on them.
    @Test func integerTooLargeForTheTypeThrows() throws {
        var tooLarge: ByteBuffer? = ByteBuffer(bytes: Self.bytes("cc0d23394f5b0d23394f5b0d23"))
        #expect(throws: OracleDecodingError.Code.self) {
            try Int._decodeRaw(from: &tooLarge, type: .number, context: .default)
        }
        var justAboveMax: ByteBuffer? = ByteBuffer(bytes: Self.bytes("ca0a1722490445374e3b09"))
        #expect(throws: OracleDecodingError.Code.self) {
            try Int._decodeRaw(from: &justAboveMax, type: .number, context: .default)
        }
        var minimum: ByteBuffer? = ByteBuffer(bytes: Self.bytes("355c4f441d62212f182b5d66"))
        #expect(try Int._decodeRaw(from: &minimum, type: .number, context: .default) == Int.min)
    }

    private static func bytes(_ hex: String) -> [UInt8] {
        var result: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            result.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return result
    }
}
