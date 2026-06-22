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

@Suite(.timeLimit(.minutes(5))) struct ByteBufferExtensionTests {

    let empty = ByteBuffer()
    let zeroLength = ByteBuffer(bytes: [0])
    let normalLengthMissingBytes = ByteBuffer(bytes: [5, 0, 0])
    let normalLength = ByteBuffer(bytes: [3, 0, 0, 0])
    let longLengthWithoutData = ByteBuffer(integer: Constants.TNS_LONG_LENGTH_INDICATOR)
    let longLengthWithoutEnoughData: ByteBuffer = {
        var buffer = ByteBuffer(integer: Constants.TNS_LONG_LENGTH_INDICATOR)
        buffer.writeUB4(300)
        buffer.writeRepeatingByte(0, count: 260)
        return buffer
    }()
    let longLengthWithoutEnoughDataOnSecondLength: ByteBuffer = {
        var buffer = ByteBuffer(integer: Constants.TNS_LONG_LENGTH_INDICATOR)
        buffer.writeUB4(300)
        buffer.writeRepeatingByte(0, count: 300)
        buffer.writeInteger(UInt8(1))
        return buffer
    }()
    let longLengthWithoutEnoughDataAfterSecondLength: ByteBuffer = {
        var buffer = ByteBuffer(integer: Constants.TNS_LONG_LENGTH_INDICATOR)
        buffer.writeUB4(300)
        buffer.writeRepeatingByte(0, count: 300)
        buffer.writeUB4(2)
        return buffer
    }()
    let longLengthData: ByteBuffer = {
        var buffer = ByteBuffer(integer: Constants.TNS_LONG_LENGTH_INDICATOR)
        buffer.writeUB4(300)
        buffer.writeRepeatingByte(0, count: 300)
        buffer.writeUB4(0)
        return buffer
    }()

    @Test func skipRawBytesChunked() {
        var buffer = empty
        #expect(buffer.skipRawBytesChunked() == false)
        buffer = normalLengthMissingBytes
        #expect(buffer.skipRawBytesChunked() == false)
        buffer = zeroLength
        #expect(buffer.skipRawBytesChunked() == true)
        buffer = normalLength
        #expect(buffer.skipRawBytesChunked() == true)

        buffer = longLengthWithoutData
        #expect(buffer.skipRawBytesChunked() == false)
        buffer = longLengthWithoutEnoughData
        #expect(buffer.skipRawBytesChunked() == false)
        buffer = longLengthWithoutEnoughDataOnSecondLength
        #expect(buffer.skipRawBytesChunked() == false)
        buffer = longLengthWithoutEnoughDataAfterSecondLength
        #expect(buffer.skipRawBytesChunked() == false)
        buffer = longLengthData
        #expect(buffer.skipRawBytesChunked() == true)
    }

    @Test func oracleSpecificLengthPrefixedSlice() {
        var buffer = empty
        #expect(buffer.readOracleSpecificLengthPrefixedSlice() == nil)
        buffer = normalLengthMissingBytes
        #expect(buffer.readOracleSpecificLengthPrefixedSlice() == nil)
        buffer = zeroLength
        #expect(buffer.readOracleSpecificLengthPrefixedSlice() != nil)
        buffer = normalLength
        #expect(buffer.readOracleSpecificLengthPrefixedSlice() != nil)

        buffer = longLengthWithoutData
        #expect(buffer.readOracleSpecificLengthPrefixedSlice() == nil)
        buffer = longLengthWithoutEnoughData
        #expect(buffer.readOracleSpecificLengthPrefixedSlice() == nil)
        buffer = longLengthWithoutEnoughDataOnSecondLength
        #expect(buffer.readOracleSpecificLengthPrefixedSlice() == nil)
        buffer = longLengthWithoutEnoughDataAfterSecondLength
        #expect(buffer.readOracleSpecificLengthPrefixedSlice() == nil)
        buffer = longLengthData
        #expect(buffer.readOracleSpecificLengthPrefixedSlice() != nil)
    }

    @Test func throwingOracleSpecificLengthPrefixedSlice() {
        var buffer = empty
        #expect(
            throws: OraclePartialDecodingError.expectedAtLeastNRemainingBytes(MemoryLayout<UInt8>.size, actual: 0),
            performing: { try buffer.throwingReadOracleSpecificLengthPrefixedSlice() }
        )
        buffer = normalLengthMissingBytes
        #expect(
            throws: OraclePartialDecodingError.expectedAtLeastNRemainingBytes(5, actual: 2),
            performing: { try buffer.throwingReadOracleSpecificLengthPrefixedSlice() }
        )
        buffer = zeroLength
        #expect(throws: Never.self, performing: { try buffer.throwingReadOracleSpecificLengthPrefixedSlice() })
        buffer = normalLength
        #expect(throws: Never.self, performing: { try buffer.throwingReadOracleSpecificLengthPrefixedSlice() })

        buffer = longLengthWithoutData
        #expect(
            throws: OraclePartialDecodingError.expectedAtLeastNRemainingBytes(MemoryLayout<UInt8>.size, actual: 0),
            performing: { try buffer.throwingReadOracleSpecificLengthPrefixedSlice() }
        )
        buffer = longLengthWithoutEnoughData
        #expect(
            throws: OraclePartialDecodingError.expectedAtLeastNRemainingBytes(300, actual: 260),
            performing: { try buffer.throwingReadOracleSpecificLengthPrefixedSlice() }
        )
        buffer = longLengthWithoutEnoughDataOnSecondLength
        #expect(
            throws: OraclePartialDecodingError.expectedAtLeastNRemainingBytes(MemoryLayout<UInt8>.size, actual: 0),
            performing: { try buffer.throwingReadOracleSpecificLengthPrefixedSlice() }
        )
        buffer = longLengthWithoutEnoughDataAfterSecondLength
        #expect(
            throws: OraclePartialDecodingError.expectedAtLeastNRemainingBytes(2, actual: 0),
            performing: { try buffer.throwingReadOracleSpecificLengthPrefixedSlice() }

        )
        buffer = longLengthData
        #expect(throws: Never.self, performing: { try buffer.throwingReadOracleSpecificLengthPrefixedSlice() })
    }

    @Test func readOracleSliceReturnsNilOnEmptyBuffer() {
        var buffer = ByteBuffer()
        #expect(buffer.readOracleSlice() == nil)
    }

    @Test func throwingSkipUBShouldThrowOnMissingBytes() {
        var buffer = ByteBuffer(bytes: [1])
        #expect(
            throws: OraclePartialDecodingError.expectedAtLeastNRemainingBytes(1, actual: 0),
            performing: { try buffer.throwingSkipUB4() }
        )
    }

    @Test func readOSONFailsAppropriately() {
        var sliceMissingBuffer = ByteBuffer(bytes: [1, 40, 0, 0])
        #expect((try? sliceMissingBuffer.throwingReadOSON()) == nil)  // TODO: refactor to throw
        var locatorMissingBuffer = ByteBuffer(bytes: [1, 40, 0, 0, 0])
        #expect((try? locatorMissingBuffer.throwingReadOSON()) == nil)  // TODO: refactor to throw
    }

    @Test func throwingSkipUBThrowsOnMissingLength() {
        var buffer = ByteBuffer()
        #expect(
            throws: OraclePartialDecodingError.expectedAtLeastNRemainingBytes(1, actual: 0),
            performing: { try buffer.throwingSkipUB4() }
        )
    }

    @Test func readUBReturnsNilOnOutOfRangeOrShortLength() {
        // Length prefixes the field type cannot represent must yield nil, not trap.
        var ub2OutOfRange = ByteBuffer(bytes: [3, 0, 0, 0])
        #expect(ub2OutOfRange.readUB2() == nil)
        var ub4OutOfRange = ByteBuffer(bytes: [5, 0, 0, 0, 0, 0])
        #expect(ub4OutOfRange.readUB4() == nil)
        var ub8OutOfRange = ByteBuffer(bytes: [5, 0, 0, 0, 0, 0])
        #expect(ub8OutOfRange.readUB8() == nil)
        // A three-byte length with fewer than three bytes available must yield nil.
        var ub4Short = ByteBuffer(bytes: [3, 0])
        #expect(ub4Short.readUB4() == nil)
    }

    @Test func readUBDecodesThreeByteValue() {
        // A three-byte length prefix carries a big-endian 24-bit value.
        var ub4 = ByteBuffer(bytes: [3, 0x01, 0x02, 0x03])
        #expect(ub4.readUB4() == 0x01_02_03)
        var ub8 = ByteBuffer(bytes: [3, 0x0a, 0x0b, 0x0c])
        #expect(ub8.readUB8() == 0x0a_0b_0c)
    }

    @Test func readStringThrowsOnUnsupportedCharset() {
        var buffer = ByteBuffer(bytes: [1, 0x41])
        #expect(throws: OraclePartialDecodingError.self) {
            _ = try buffer.readString(with: Constants.TNS_CS_IMPLICIT + 1)
        }
    }

    @Test func readSBReturnsNilOnOutOfRangeLength() {
        var sb2OutOfRange = ByteBuffer(bytes: [3, 0, 0, 0])
        #expect(sb2OutOfRange.readSB2() == nil)
        var sb4OutOfRange = ByteBuffer(bytes: [5, 0, 0, 0, 0, 0])
        #expect(sb4OutOfRange.readSB4() == nil)
        var sb8OutOfRange = ByteBuffer(bytes: [5, 0, 0, 0, 0, 0])
        #expect(sb8OutOfRange.readSB8() == nil)
    }

    @Test func throwingSkipUBThrowsOnOutOfRangeLength() {
        var buffer = ByteBuffer(bytes: [5, 0, 0, 0, 0])
        #expect(throws: OraclePartialDecodingError.self) {
            try buffer.throwingSkipUB4()
        }
    }
}
