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

/// Sizes and offsets inside a value come from the server, or from anyone on a plain TCP path to it. A value that
/// breaks them has to fail its own decode, never trap or exhaust the process.
@Suite struct MalformedValueTests {
    /// `JSON('[1, "a", {"k":null}]')` measured on Oracle 23ai. The tree segment starts at byte 17: an array of
    /// three children at tree offsets 8, 11 and 13, the last an object whose one child sits at offset 18.
    private static let validOSON: [UInt8] = [
        0xff, 0x4a, 0x5a, 0x01, 0x21, 0x06, 0x01, 0x00, 0x02, 0x00, 0x13, 0x00, 0x00, 0xea, 0x00, 0x00, 0x01, 0x6b,
        0xc0, 0x03, 0x00, 0x08, 0x00, 0x0b, 0x00, 0x0d, 0x21, 0xc1, 0x02, 0x01, 0x61, 0x84, 0x01, 0x01, 0x00, 0x12,
        0x30,
    ]
    private static let firstChildOffset = 20
    private static let objectChildOffset = 34

    private static func decodeJSON(_ bytes: [UInt8]) throws -> String {
        var buffer: ByteBuffer? = ByteBuffer(bytes: bytes)
        return try String._decodeRaw(from: &buffer, type: .json, context: .default)
    }

    private static func decodeStorage(_ bytes: [UInt8]) throws -> OracleJSONStorage {
        var buffer = ByteBuffer(bytes: bytes)
        return try OracleJSONParser.parse(from: &buffer)
    }

    @Test func validOSONStillDecodes() throws {
        #expect(try Self.decodeJSON(Self.validOSON) == #"[1,"a",{"k":null}]"#)
        #expect(try Self.decodeStorage(Self.validOSON) == .array([.double(1), .string("a"), .container(["k": .none])]))
    }

    @Test func childOffsetOutsideTheValueThrows() {
        var bytes = Self.validOSON
        bytes[Self.firstChildOffset] = 0xff
        bytes[Self.firstChildOffset + 1] = 0xff
        #expect(throws: OracleError.ErrorType.self) { try Self.decodeJSON(bytes) }
        #expect(throws: OracleError.ErrorType.self) { try Self.decodeStorage(bytes) }
    }

    /// The object's child points back at the object, which recursed until the stack overflowed.
    @Test func childPointingAtItsContainerThrows() {
        var bytes = Self.validOSON
        bytes[Self.objectChildOffset + 1] = 0x0d
        #expect(throws: OracleError.ErrorType.self) { try Self.decodeJSON(bytes) }
        #expect(throws: OracleError.ErrorType.self) { try Self.decodeStorage(bytes) }
    }

    /// Measured on Oracle 23ai: identical values, empty containers included, are one node that several children
    /// point at, so a node reached twice is valid.
    @Test func sharedNodesStillDecode() throws {
        let oson = Self.bytes(
            "ff4a5a0161260200040066001a2c870000000201610178c00c002400290022002200200020002e003700400045004a005807"
                + "000121c1028400c000860101001d9c0024001dc002001d003421c103c002001d003d21c1030473616d650473616d65840102"
                + "004fc002001d005521c103840102005dc002001d006321c103"
        )
        #expect(
            try Self.decodeJSON(oson)
                == #"[{"a":1},{"a":1},[],[],{},{},[1,2],[1,2],"same","same",{"x":[1,2]},{"x":[1,2]}]"#
        )
        #expect(throws: Never.self) { try Self.decodeStorage(oson) }
    }

    /// Sharing lets a few kilobytes stand for gigabytes: each of eleven nested arrays holds the next one twice,
    /// so the 60 KB string at the bottom is reached 2,048 times.
    @Test func sharingThatMultipliesTheValueThrows() {
        let levels = 11
        var tree: [UInt8] = []
        for level in 0..<levels {
            let next = UInt16((level + 1) * 6)
            tree += [0xc0, 0x02, UInt8(next >> 8), UInt8(next & 0xff), UInt8(next >> 8), UInt8(next & 0xff)]
        }
        let stringLength = 60_000
        tree += [Constants.TNS_JSON_TYPE_STRING_LENGTH_UINT32]
        tree += withUnsafeBytes(of: UInt32(stringLength).bigEndian, Array.init)
        tree += [UInt8](repeating: 0x78, count: stringLength)
        let size = UInt32(tree.count)
        let header: [UInt8] =
            [0xff, 0x4a, 0x5a, 0x01, 0x10, 0x00, 0x00, 0x00, 0x00]
            + withUnsafeBytes(of: size.bigEndian, Array.init) + [0x00, 0x00]
        #expect(throws: OracleError.ErrorType.self) { try Self.decodeJSON(header + tree) }
        #expect(throws: OracleError.ErrorType.self) { try Self.decodeStorage(header + tree) }
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

    /// Oracle stores JSON up to 1,024 levels deep, which recursion on a task's 512 KB stack did not survive.
    @Test func nestingPastTheLimitThrows() throws {
        #expect(try Self.decodeJSON(Self.nestedArrays(OracleJSONParser.maxDepth)).hasPrefix("[[["))
        #expect(try Self.decodeStorage(Self.nestedArrays(OracleJSONParser.maxDepth)) != .none)
        #expect(throws: OracleError.ErrorType.self) { try Self.decodeJSON(Self.nestedArrays(OracleJSONParser.maxDepth + 1)) }
        #expect(throws: OracleError.ErrorType.self) { try Self.decodeStorage(Self.nestedArrays(OracleJSONParser.maxDepth + 1)) }
    }

    /// `count` arrays, each holding the next, around a null.
    private static func nestedArrays(_ count: Int) -> [UInt8] {
        var tree: [UInt8] = []
        for level in 0..<count {
            let next = UInt16((level + 1) * 4)
            tree += [0xc0, 0x01, UInt8(next >> 8), UInt8(next & 0xff)]
        }
        tree.append(0x30)
        let size = UInt16(tree.count)
        return [0xff, 0x4a, 0x5a, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, UInt8(size >> 8), UInt8(size & 0xff), 0x00, 0x00]
            + tree
    }

    @Test func truncatedHeaderThrows() {
        #expect(throws: (any Error).self) { try Self.decodeJSON(Array(Self.validOSON.prefix(12))) }
    }

    /// Mantissa bytes outside 1...100 (101 minus a digit for a negative number) are not digits, and unsigned
    /// arithmetic trapped on them; a value longer than a NUMBER's 22 bytes is not one.
    @Test func malformedNumbersThrow() {
        let malformed: [[UInt8]] = [
            [0xc1, 0x00],
            [0x3e, 0xff],
            [0xc1] + [UInt8](repeating: 0x01, count: 30),
        ]
        for bytes in malformed {
            var buffer = ByteBuffer(bytes: bytes)
            #expect(throws: (any Error).self) {
                try OracleNumber(from: &buffer, type: .number, context: .default)
            }
            var text = ByteBuffer(bytes: bytes)
            #expect(throws: (any Error).self) { try OracleNumeric.parseDecimalString(from: &text) }
        }
    }

    /// The element count sizes an allocation before any element is read.
    @Test func vectorClaimingMoreElementsThanItsBytesThrows() {
        var buffer = ByteBuffer(bytes: [Constants.TNS_VECTOR_MAGIC_BYTE, 0, 0, 0, 2, 0xff, 0xff, 0xff, 0xff])
        #expect(throws: (any Error).self) { try _decodeOracleVectorMetadata(from: &buffer) }
    }
}
