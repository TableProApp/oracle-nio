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

    /// NCHAR arrives in the national character set, UTF-16BE, like NVARCHAR2.
    @Test func decodeNChar() throws {
        var buffer: ByteBuffer? = ByteBuffer(bytes: [0, 104, 0, 233, 0, 108, 0, 108, 0, 111, 0, 32])
        let value = try String._decodeRaw(from: &buffer, type: .nChar, context: .default)
        #expect(value == "héllo ")
    }

    /// OSON measured on Oracle 23ai. The text keeps the order the tree stores each object's fields
    /// in, every digit of a NUMBER, and spells Oracle's extended scalars as `JSON_SERIALIZE` does.
    @Test func decodeJSONAsText() throws {
        let cases: [(oson: String, text: String)] = [
            (
                "ff4a5a01612605000a0030000b2c5273ade500020004000800060000016201610163017a0164840305010200110014002606000031323021c102c0050011002000240010000e22c10333017884020403002e000f0179",
                #"{"b":1,"a":[1,2.5,"x",null,true],"c":{"z":"y","d":false}}"#
            ),
            (
                "ff4a5a01310607000e0000005e00001015317382adc400000002000400060008000a000c01750172016e01640173017a01698407010203040506070017001f00260038004000440052075469e1babf6e673a0004deadbeef3410cf0d23394f5b0d23394f5b0d23394f5b3c787c01020101010371225c7c787c01020923061dcd65000f1e3e7fffffff3a393862329b00",
                #"{"u":"Tiếng","r":"DEADBEEF","n":123456789012345678901234567890,"d":"2024-01-02T00:00:00","s":"q\"\\","z":"2024-01-02T03:04:05.500000-05:30","i":"-P1DT2H3M4.500000S"}"#
            ),
            ("ff4a5a01210601000200130000ea0000016bc0030008000b000d21c1020161840101001230", #"[1,"a",{"k":null}]"#),
            ("ff4a5a0100160007067363616c6172", #""scalar""#),
        ]
        for testCase in cases {
            var buffer: ByteBuffer? = ByteBuffer(bytes: Self.bytes(testCase.oson))
            let value = try String._decodeRaw(from: &buffer, type: .json, context: .default)
            #expect(value == testCase.text)
        }
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
