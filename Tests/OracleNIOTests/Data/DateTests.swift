//===----------------------------------------------------------------------===//
//
// This source file is part of the OracleNIO open source project
//
// Copyright (c) 2025 Timo Zacherl and the OracleNIO project authors
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

@Suite struct DateTests {
    /// 2024-01-02 03:04:05 UTC, the wall clock every case below starts from.
    private static let wholeSecond: [UInt8] = [120, 124, 1, 2, 4, 5, 6]

    /// Measured on Oracle 23ai: the four bytes after the seconds are nanoseconds, so `.05` arrives
    /// as 50,000,000 and `.000001` as 1,000.
    @Test func fractionIsReadAsNanoseconds() throws {
        let cases: [(nanoseconds: UInt32, expected: Int)] = [
            (50_000_000, 50_000_000),
            (1_000, 1_000),
            (999_999_999, 999_999_999),
            (123_456_000, 123_456_000),
        ]
        for testCase in cases {
            var bytes = ByteBuffer(bytes: Self.wholeSecond)
            bytes.writeInteger(testCase.nanoseconds, endianness: .big)
            var buffer: ByteBuffer? = bytes
            let date = try Date._decodeRaw(from: &buffer, type: .timestamp, context: .default)
            let base = Date(timeIntervalSince1970: 1_704_164_645)
            let nanoseconds = (date.timeIntervalSince(base) * 1_000_000_000).rounded()
            #expect(abs(nanoseconds - Double(testCase.expected)) < 1_000, "\(testCase.nanoseconds)")
        }
    }

    /// Measured on Oracle 23ai: `-05:30` arrives as hour byte 15 and minute byte 30, both below
    /// their bias, and the date and time bytes are already UTC.
    @Test func negativeOffsetDecodesWithoutTrapping() throws {
        var bytes = ByteBuffer(bytes: [120, 124, 1, 2, 9, 35, 6])
        bytes.writeInteger(UInt32(0), endianness: .big)
        bytes.writeBytes([15, 30])
        var buffer: ByteBuffer? = bytes
        let date = try Date._decodeRaw(from: &buffer, type: .timestampTZ, context: .default)
        #expect(date == Date(timeIntervalSince1970: 1_704_164_645 + 5 * 3_600 + 30 * 60))
    }

    @Test func encodedFractionIsNanoseconds() {
        let date = Date(timeIntervalSince1970: 1_704_164_645.25)
        var buffer = ByteBuffer()
        date.encode(into: &buffer, context: .default)
        #expect(buffer.getBytes(at: 0, length: 7) == Self.wholeSecond)
        #expect(buffer.getInteger(at: 7, endianness: .big, as: UInt32.self) == 250_000_000)
    }
}
