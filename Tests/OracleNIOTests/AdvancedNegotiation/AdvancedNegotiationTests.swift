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

@Suite struct AdvancedNegotiationTests {
    @Test func encodesRequestWithFourServicesAndMagicHeader() throws {
        var buffer = ByteBuffer()
        AdvancedNegotiation.encodeRequest(into: &buffer)

        #expect(buffer.getInteger(at: 0, as: UInt32.self) == Constants.TNS_ANO_MAGIC)
        // version follows the 2-byte payload length
        #expect(buffer.getInteger(at: 6, as: UInt32.self) == Constants.TNS_ANO_VERSION)
        // service count
        #expect(buffer.getInteger(at: 10, as: UInt16.self) == 4)
    }

    @Test func roundTripsServerStyleResponse() throws {
        var response = ByteBuffer()
        response.writeInteger(Constants.TNS_ANO_MAGIC)
        response.writeInteger(UInt16(0))  // payload length, unchecked on read
        response.writeInteger(Constants.TNS_ANO_VERSION)
        response.writeInteger(UInt16(4))  // four services
        response.writeInteger(UInt8(0))  // error flags

        writeSupervisorResponse(into: &response)
        writeAuthResponse(into: &response)
        writeEncryptionResponse(into: &response, algorithmID: 17)
        writeDataIntegrityResponse(into: &response, algorithmID: 4)

        let decoded = try AdvancedNegotiation.decodeResponse(from: &response)
        #expect(decoded.encryptionAlgorithmID == 17)
        #expect(decoded.dataIntegrityAlgorithmID == 4)
        #expect(decoded.dhPrime?.count == 32)
        #expect(decoded.dhServerPublicKey?.count == 32)
        #expect(decoded.dhIV?.count == 16)
    }

    @Test func rejectsResponseWithBadMagic() throws {
        var response = ByteBuffer()
        response.writeInteger(UInt32(0x1234_5678))
        #expect(throws: AdvancedNegotiation.DecodingError.self) {
            var copy = response
            _ = try AdvancedNegotiation.decodeResponse(from: &copy)
        }
    }

    // MARK: - Response builders

    private func writeServiceHeader(
        into buffer: inout ByteBuffer, type: Int, subPackets: Int
    ) {
        buffer.writeInteger(UInt16(type))
        buffer.writeInteger(UInt16(subPackets))
        buffer.writeInteger(UInt32(0))
    }

    private func writeVersionSubPacket(into buffer: inout ByteBuffer) {
        buffer.writeInteger(UInt16(4))
        buffer.writeInteger(UInt16(Constants.TNS_ANO_TYPE_VERSION))
        buffer.writeInteger(Constants.TNS_ANO_VERSION)
    }

    private func writeStatusSubPacket(into buffer: inout ByteBuffer, status: UInt16) {
        buffer.writeInteger(UInt16(2))
        buffer.writeInteger(UInt16(Constants.TNS_ANO_TYPE_STATUS))
        buffer.writeInteger(status)
    }

    private func writeUB1SubPacket(into buffer: inout ByteBuffer, value: UInt8) {
        buffer.writeInteger(UInt16(1))
        buffer.writeInteger(UInt16(Constants.TNS_ANO_TYPE_UB1))
        buffer.writeInteger(value)
    }

    private func writeUB2SubPacket(into buffer: inout ByteBuffer, value: UInt16) {
        buffer.writeInteger(UInt16(2))
        buffer.writeInteger(UInt16(Constants.TNS_ANO_TYPE_UB2))
        buffer.writeInteger(value)
    }

    private func writeBytesSubPacket(into buffer: inout ByteBuffer, bytes: [UInt8]) {
        buffer.writeInteger(UInt16(bytes.count))
        buffer.writeInteger(UInt16(Constants.TNS_ANO_TYPE_BYTES))
        buffer.writeBytes(bytes)
    }

    private func writeSupervisorResponse(into buffer: inout ByteBuffer) {
        writeServiceHeader(into: &buffer, type: 4, subPackets: 3)
        writeVersionSubPacket(into: &buffer)
        writeStatusSubPacket(into: &buffer, status: 31)
        let entries: [UInt16] = [4, 1, 2, 3]
        buffer.writeInteger(UInt16(10 + entries.count * 2))
        buffer.writeInteger(UInt16(Constants.TNS_ANO_TYPE_BYTES))
        buffer.writeInteger(Constants.TNS_ANO_MAGIC)
        buffer.writeInteger(UInt16(3))
        buffer.writeInteger(UInt32(entries.count))
        for entry in entries { buffer.writeInteger(entry) }
    }

    private func writeAuthResponse(into buffer: inout ByteBuffer) {
        writeServiceHeader(into: &buffer, type: 1, subPackets: 2)
        writeVersionSubPacket(into: &buffer)
        writeStatusSubPacket(into: &buffer, status: 0xFBFF)
    }

    private func writeEncryptionResponse(into buffer: inout ByteBuffer, algorithmID: UInt8) {
        writeServiceHeader(into: &buffer, type: 2, subPackets: 2)
        writeVersionSubPacket(into: &buffer)
        writeUB1SubPacket(into: &buffer, value: algorithmID)
    }

    private func writeDataIntegrityResponse(into buffer: inout ByteBuffer, algorithmID: UInt8) {
        writeServiceHeader(into: &buffer, type: 3, subPackets: 8)
        writeVersionSubPacket(into: &buffer)
        writeUB1SubPacket(into: &buffer, value: algorithmID)
        writeUB2SubPacket(into: &buffer, value: 256)  // generator bit length
        writeUB2SubPacket(into: &buffer, value: 256)  // prime bit length
        writeBytesSubPacket(into: &buffer, bytes: [2] + [UInt8](repeating: 0, count: 31))
        writeBytesSubPacket(into: &buffer, bytes: [UInt8](repeating: 0xAB, count: 32))
        writeBytesSubPacket(into: &buffer, bytes: [UInt8](repeating: 0xCD, count: 32))
        writeBytesSubPacket(into: &buffer, bytes: [UInt8](repeating: 0xEF, count: 16))
    }
}
