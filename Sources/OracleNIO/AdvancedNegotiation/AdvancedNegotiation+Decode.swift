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

extension AdvancedNegotiation {
    /// Parses the server's ANO response into the negotiated algorithm IDs and any
    /// Diffie-Hellman material. Mirrors go-ora's `AdvNego.Read`.
    static func decodeResponse(from buffer: inout ByteBuffer) throws -> Response {
        let magic = try readUInt32(&buffer)
        guard magic == Constants.TNS_ANO_MAGIC else {
            throw DecodingError(reason: "advanced negotiation: bad response header")
        }
        _ = try readUInt16(&buffer)  // payload length
        _ = try readUInt32(&buffer)  // version
        let serviceCount = try readUInt16(&buffer)
        _ = try readUInt8(&buffer)  // error flags

        var response = Response()
        for _ in 0..<serviceCount {
            let serviceType = try readUInt16(&buffer)
            let subPacketCount = try readUInt16(&buffer)
            let errorCode = try readUInt32(&buffer)
            guard errorCode == 0 else {
                throw DecodingError(
                    reason: "advanced negotiation: service error ora-\(errorCode)"
                )
            }
            switch Int(serviceType) {
            case Constants.TNS_ANO_SERVICE_SUPERVISOR:
                try decodeSupervisor(from: &buffer)
            case Constants.TNS_ANO_SERVICE_AUTH:
                try decodeAuth(from: &buffer, subPacketCount: Int(subPacketCount))
            case Constants.TNS_ANO_SERVICE_ENCRYPTION:
                response.encryptionAlgorithmID = try decodeEncryption(from: &buffer)
            case Constants.TNS_ANO_SERVICE_DATA_INTEGRITY:
                try decodeDataIntegrity(
                    from: &buffer, subPacketCount: Int(subPacketCount), into: &response
                )
            default:
                throw DecodingError(
                    reason: "advanced negotiation: unknown service \(serviceType)"
                )
            }
        }
        return response
    }

    private static func decodeSupervisor(from buffer: inout ByteBuffer) throws {
        _ = try readVersion(&buffer)
        let status = try readStatus(&buffer)
        guard status == Constants.TNS_ANO_STATUS_SUPERVISOR else {
            throw DecodingError(reason: "advanced negotiation: reading supervisor service")
        }
        _ = try readUB2Array(&buffer)
    }

    private static func decodeAuth(from buffer: inout ByteBuffer, subPacketCount: Int) throws {
        _ = try readVersion(&buffer)
        let status = try readStatus(&buffer)
        if status == 0xFAFF && subPacketCount > 2 {
            _ = try readUB1(&buffer)
            _ = try readString(&buffer)
            if subPacketCount > 4 {
                _ = try readVersion(&buffer)
                _ = try readUB4(&buffer)
                _ = try readUB4(&buffer)
            }
        } else if status != 0xFBFF {
            throw DecodingError(reason: "advanced negotiation: reading authentication service")
        }
    }

    private static func decodeEncryption(from buffer: inout ByteBuffer) throws -> Int {
        _ = try readVersion(&buffer)
        let algorithmID = try readUB1(&buffer)
        return Int(algorithmID)
    }

    private static func decodeDataIntegrity(
        from buffer: inout ByteBuffer, subPacketCount: Int, into response: inout Response
    ) throws {
        _ = try readVersion(&buffer)
        response.dataIntegrityAlgorithmID = Int(try readUB1(&buffer))
        guard subPacketCount == 8 else { return }

        let generatorBitLength = try readUB2(&buffer)
        let primeBitLength = try readUB2(&buffer)
        let generator = try readBytes(&buffer)
        let prime = try readBytes(&buffer)
        let serverPublicKey = try readBytes(&buffer)
        let iv = try readBytes(&buffer)
        guard generatorBitLength > 0, primeBitLength > 0 else {
            throw DecodingError(reason: "advanced negotiation: bad Diffie-Hellman parameter")
        }
        let byteLength = (generatorBitLength + 7) / 8
        guard serverPublicKey.count == byteLength, prime.count == byteLength else {
            throw DecodingError(reason: "advanced negotiation: Diffie-Hellman out of sync")
        }
        response.dhGenerator = generator
        response.dhPrime = prime
        response.dhServerPublicKey = serverPublicKey
        response.dhIV = iv
    }

    // MARK: - Typed sub-packet readers

    private static func readPacketHeader(_ buffer: inout ByteBuffer, expectedType: Int) throws -> Int {
        let length = Int(try readUInt16(&buffer))
        let type = Int(try readUInt16(&buffer))
        guard type == expectedType else {
            throw DecodingError(reason: "advanced negotiation: unexpected sub-packet type")
        }
        return length
    }

    private static func readVersion(_ buffer: inout ByteBuffer) throws -> UInt32 {
        _ = try readPacketHeader(&buffer, expectedType: Constants.TNS_ANO_TYPE_VERSION)
        return try readUInt32(&buffer)
    }

    private static func readStatus(_ buffer: inout ByteBuffer) throws -> Int {
        _ = try readPacketHeader(&buffer, expectedType: Constants.TNS_ANO_TYPE_STATUS)
        return Int(try readUInt16(&buffer))
    }

    private static func readUB1(_ buffer: inout ByteBuffer) throws -> UInt8 {
        _ = try readPacketHeader(&buffer, expectedType: Constants.TNS_ANO_TYPE_UB1)
        return try readUInt8(&buffer)
    }

    private static func readUB2(_ buffer: inout ByteBuffer) throws -> Int {
        _ = try readPacketHeader(&buffer, expectedType: Constants.TNS_ANO_TYPE_UB2)
        return Int(try readUInt16(&buffer))
    }

    private static func readUB4(_ buffer: inout ByteBuffer) throws -> Int {
        _ = try readPacketHeader(&buffer, expectedType: Constants.TNS_ANO_TYPE_UB4)
        return Int(try readUInt32(&buffer))
    }

    private static func readString(_ buffer: inout ByteBuffer) throws -> String {
        let length = try readPacketHeader(&buffer, expectedType: Constants.TNS_ANO_TYPE_STRING)
        guard let value = buffer.readString(length: length) else {
            throw DecodingError(reason: "advanced negotiation: short string sub-packet")
        }
        return value
    }

    private static func readBytes(_ buffer: inout ByteBuffer) throws -> [UInt8] {
        let length = try readPacketHeader(&buffer, expectedType: Constants.TNS_ANO_TYPE_BYTES)
        guard let value = buffer.readBytes(length: length) else {
            throw DecodingError(reason: "advanced negotiation: short bytes sub-packet")
        }
        return value
    }

    private static func readUB2Array(_ buffer: inout ByteBuffer) throws -> [Int] {
        _ = try readPacketHeader(&buffer, expectedType: Constants.TNS_ANO_TYPE_BYTES)
        let magic = try readUInt32(&buffer)
        let marker = try readUInt16(&buffer)
        let count = Int(try readUInt32(&buffer))
        guard magic == Constants.TNS_ANO_MAGIC, marker == 3 else {
            throw DecodingError(reason: "advanced negotiation: reading supervisor service")
        }
        var values = [Int]()
        values.reserveCapacity(count)
        for _ in 0..<count {
            values.append(Int(try readUInt16(&buffer)))
        }
        return values
    }

    // MARK: - Primitive readers

    private static func readUInt8(_ buffer: inout ByteBuffer) throws -> UInt8 {
        guard let value = buffer.readInteger(as: UInt8.self) else {
            throw DecodingError(reason: "advanced negotiation: short response")
        }
        return value
    }

    private static func readUInt16(_ buffer: inout ByteBuffer) throws -> UInt16 {
        guard let value = buffer.readInteger(as: UInt16.self) else {
            throw DecodingError(reason: "advanced negotiation: short response")
        }
        return value
    }

    private static func readUInt32(_ buffer: inout ByteBuffer) throws -> UInt32 {
        guard let value = buffer.readInteger(as: UInt32.self) else {
            throw DecodingError(reason: "advanced negotiation: short response")
        }
        return value
    }
}
