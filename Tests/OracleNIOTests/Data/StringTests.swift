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

@Suite struct StringTests {
    @Test func decodeUTF16() throws {
        var buffer: ByteBuffer? = ByteBuffer(
            bytes: [
                0, 72, 0, 101, 0, 108, 0, 108, 0, 111,
                0, 44, 0, 32, 0, 119, 0, 111, 0, 114,
                0, 108, 0, 100, 0, 33, 0, 32, 216, 60,
                223, 13, 216, 61, 220, 75,
            ]
        )
        let value = try String._decodeRaw(from: &buffer, type: .nVarchar, context: .default)
        #expect(value == "Hello, world! 🌍👋")
    }

    /// Measured on Oracle 23ai: a bind sized by character count fails with ORA-01460 or ORA-01461
    /// once one character takes more than four bytes.
    @Test func bindSizeIsTheUTF8ByteCount() {
        let cases: [(value: String, bytes: UInt32)] = [
            ("👍🏽", 8),
            ("🇻🇳", 8),
            ("x\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}y", 27),
            ("Tiếng Việt", 14),
            ("", 1),
        ]
        for testCase in cases {
            #expect(testCase.value.size == testCase.bytes, "\(testCase.value)")
        }
    }
}
