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

/// Builds and parses the Advanced Networking Option (native network encryption)
/// handshake. The wire format mirrors the Oracle JDBC thin driver and go-ora: an
/// outer `0xDEADBEEF` header followed by typed service blocks for supervisor,
/// authentication, encryption and data integrity.
///
/// Sub-packets are typed length/value pairs. Each is `[length: UInt16][type: UInt16]`
/// followed by the payload. Multi-byte integers are big-endian.
struct AdvancedNegotiation {
    struct DecodingError: Error, Equatable {
        var reason: String
    }

    /// Encryption algorithm IDs the client offers, most preferred last (the server
    /// scans for the highest match). Matches go-ora's default list.
    static let offeredEncryptionAlgorithms: [UInt8] = [
        UInt8(Constants.TNS_ANO_ENC_AES128),
        UInt8(Constants.TNS_ANO_ENC_AES192),
        UInt8(Constants.TNS_ANO_ENC_AES256),
    ]
    /// Data-integrity algorithm IDs the client offers.
    static let offeredDataIntegrityAlgorithms: [UInt8] = [
        UInt8(Constants.TNS_ANO_DI_MD5),
        UInt8(Constants.TNS_ANO_DI_SHA1),
        UInt8(Constants.TNS_ANO_DI_SHA512),
        UInt8(Constants.TNS_ANO_DI_SHA256),
        UInt8(Constants.TNS_ANO_DI_SHA384),
    ]
    static let supervisorCID: [UInt8] = [0, 0, 16, 28, 102, 236, 40, 234]
    static let supervisorServiceArray: [Int] = [
        Constants.TNS_ANO_SERVICE_SUPERVISOR,
        Constants.TNS_ANO_SERVICE_AUTH,
        Constants.TNS_ANO_SERVICE_ENCRYPTION,
        Constants.TNS_ANO_SERVICE_DATA_INTEGRITY,
    ]

    /// Result of parsing the server's ANO response.
    struct Response: Equatable, Hashable {
        var encryptionAlgorithmID: Int = 0
        var dataIntegrityAlgorithmID: Int = 0
        /// Diffie-Hellman material, present when the server requested key exchange
        /// (sub-packet count of 8 in the data-integrity block).
        var dhGenerator: [UInt8]?
        var dhPrime: [UInt8]?
        var dhServerPublicKey: [UInt8]?
        var dhIV: [UInt8]?
    }

    // MARK: - Encoding

    /// Encodes the full ANO request payload (header + four service blocks) into a
    /// fresh buffer. The caller wraps it in a TTC data packet.
    static func encodeRequest(into buffer: inout ByteBuffer) {
        var supervisor = ByteBuffer()
        encodeSupervisorService(into: &supervisor)
        var auth = ByteBuffer()
        encodeAuthService(into: &auth)
        var encryption = ByteBuffer()
        encodeEncryptionService(into: &encryption)
        var dataIntegrity = ByteBuffer()
        encodeDataIntegrityService(into: &dataIntegrity)

        let serviceLength =
            supervisor.readableBytes + auth.readableBytes
            + encryption.readableBytes + dataIntegrity.readableBytes
        encodeHeader(into: &buffer, payloadLength: 13 + serviceLength, serviceCount: 4)
        buffer.writeImmutableBuffer(supervisor)
        buffer.writeImmutableBuffer(auth)
        buffer.writeImmutableBuffer(encryption)
        buffer.writeImmutableBuffer(dataIntegrity)
    }

    /// Encodes the follow-up packet that carries the client's Diffie-Hellman public
    /// key when the server requested key exchange.
    static func encodeClientPublicKey(_ publicKey: [UInt8], into buffer: inout ByteBuffer) {
        let size = 12 + publicKey.count
        encodeHeader(into: &buffer, payloadLength: size + 13, serviceCount: 1)
        encodeServiceHeader(
            into: &buffer,
            serviceType: Constants.TNS_ANO_SERVICE_DATA_INTEGRITY,
            subPacketCount: 1
        )
        encodeBytes(publicKey, into: &buffer)
    }

    private static func encodeHeader(
        into buffer: inout ByteBuffer, payloadLength: Int, serviceCount: Int
    ) {
        buffer.writeInteger(Constants.TNS_ANO_MAGIC)
        buffer.writeInteger(UInt16(payloadLength))
        buffer.writeInteger(Constants.TNS_ANO_VERSION)
        buffer.writeInteger(UInt16(serviceCount))
        buffer.writeInteger(UInt8(0))  // error flags
    }

    private static func encodeServiceHeader(
        into buffer: inout ByteBuffer, serviceType: Int, subPacketCount: Int
    ) {
        buffer.writeInteger(UInt16(serviceType))
        buffer.writeInteger(UInt16(subPacketCount))
        buffer.writeInteger(UInt32(0))  // error code
    }

    private static func encodeSupervisorService(into buffer: inout ByteBuffer) {
        encodeServiceHeader(
            into: &buffer,
            serviceType: Constants.TNS_ANO_SERVICE_SUPERVISOR,
            subPacketCount: 3
        )
        encodeVersion(into: &buffer)
        encodeBytes(supervisorCID, into: &buffer)
        encodeUB2Array(supervisorServiceArray, into: &buffer)
    }

    private static func encodeAuthService(into buffer: inout ByteBuffer) {
        // Plain username/password authentication advertises no extra ANO auth
        // service, mirroring go-ora's default (status 0xFCFF, no service entries).
        encodeServiceHeader(
            into: &buffer,
            serviceType: Constants.TNS_ANO_SERVICE_AUTH,
            subPacketCount: 3
        )
        encodeVersion(into: &buffer)
        encodeUB2(0xE0E1, into: &buffer)
        encodeStatus(0xFCFF, into: &buffer)
    }

    private static func encodeEncryptionService(into buffer: inout ByteBuffer) {
        encodeServiceHeader(
            into: &buffer,
            serviceType: Constants.TNS_ANO_SERVICE_ENCRYPTION,
            subPacketCount: 3
        )
        encodeVersion(into: &buffer)
        encodeBytes(offeredEncryptionAlgorithms, into: &buffer)
        encodeUB1(1, into: &buffer)  // selected driver
    }

    private static func encodeDataIntegrityService(into buffer: inout ByteBuffer) {
        encodeServiceHeader(
            into: &buffer,
            serviceType: Constants.TNS_ANO_SERVICE_DATA_INTEGRITY,
            subPacketCount: 2
        )
        encodeVersion(into: &buffer)
        encodeBytes(offeredDataIntegrityAlgorithms, into: &buffer)
    }

    // MARK: - Typed sub-packet encoders

    private static func encodePacketHeader(
        length: Int, type: Int, into buffer: inout ByteBuffer
    ) {
        buffer.writeInteger(UInt16(length))
        buffer.writeInteger(UInt16(type))
    }

    private static func encodeVersion(into buffer: inout ByteBuffer) {
        encodePacketHeader(length: 4, type: Constants.TNS_ANO_TYPE_VERSION, into: &buffer)
        buffer.writeInteger(Constants.TNS_ANO_VERSION)
    }

    private static func encodeUB1(_ value: UInt8, into buffer: inout ByteBuffer) {
        encodePacketHeader(length: 1, type: Constants.TNS_ANO_TYPE_UB1, into: &buffer)
        buffer.writeInteger(value)
    }

    private static func encodeUB2(_ value: Int, into buffer: inout ByteBuffer) {
        encodePacketHeader(length: 2, type: Constants.TNS_ANO_TYPE_UB2, into: &buffer)
        buffer.writeInteger(UInt16(value))
    }

    private static func encodeStatus(_ value: Int, into buffer: inout ByteBuffer) {
        encodePacketHeader(length: 2, type: Constants.TNS_ANO_TYPE_STATUS, into: &buffer)
        buffer.writeInteger(UInt16(value))
    }

    private static func encodeBytes(_ value: [UInt8], into buffer: inout ByteBuffer) {
        encodePacketHeader(length: value.count, type: Constants.TNS_ANO_TYPE_BYTES, into: &buffer)
        buffer.writeBytes(value)
    }

    private static func encodeUB2Array(_ values: [Int], into buffer: inout ByteBuffer) {
        encodePacketHeader(
            length: 10 + values.count * 2, type: Constants.TNS_ANO_TYPE_BYTES, into: &buffer
        )
        buffer.writeInteger(Constants.TNS_ANO_MAGIC)
        buffer.writeInteger(UInt16(3))
        buffer.writeInteger(UInt32(values.count))
        for value in values {
            buffer.writeInteger(UInt16(value))
        }
    }
}
