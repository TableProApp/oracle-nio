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

import BigInt
import Crypto
import Foundation
import Testing

@testable import OracleNIO

@Suite struct OracleNetworkSecurityTests {
    @Test func cbcCipherRoundTripsArbitraryLengths() throws {
        let key = [UInt8](repeating: 0x11, count: 32)
        let iv = [UInt8](repeating: 0x22, count: 16)
        let cipher = OracleNetworkCBCCipher(key: key, iv: iv)

        for length in [0, 1, 15, 16, 17, 31, 32, 100] {
            let plain = (0..<length).map { UInt8($0 & 0xFF) }
            let encrypted = try cipher.encrypt(plain)
            // Cipher text length is a 16-byte multiple plus the trailing pad-count byte.
            #expect((encrypted.count - 1) % 16 == 0)
            let decrypted = try cipher.decrypt(encrypted)
            #expect(decrypted == plain)
        }
    }

    @Test func cbcCipherAppendsPadCountTrailer() throws {
        let key = [UInt8](repeating: 0x33, count: 16)
        let iv = [UInt8](repeating: 0x44, count: 16)
        let cipher = OracleNetworkCBCCipher(key: key, iv: iv)

        // 10 bytes -> 6 bytes zero padding -> trailer is paddingCount + 1 == 7.
        let encrypted = try cipher.encrypt([UInt8](repeating: 1, count: 10))
        #expect(encrypted.last == 7)
        // 16 bytes -> 0 padding -> trailer == 1.
        let aligned = try cipher.encrypt([UInt8](repeating: 1, count: 16))
        #expect(aligned.last == 1)
    }

    @Test func cbcCipherRejectsBadPadding() throws {
        let cipher = OracleNetworkCBCCipher(
            key: [UInt8](repeating: 0, count: 16),
            iv: [UInt8](repeating: 0, count: 16)
        )
        #expect(throws: AdvancedNegotiation.DecodingError.self) {
            // Not (16n + 1) bytes.
            _ = try cipher.decrypt([UInt8](repeating: 0, count: 10))
        }
    }

    @Test func diffieHellmanProducesMatchingSharedSecret() throws {
        // Small but valid DH parameters: prime p, generator g.
        let prime = BigUInt(2_357)
        let generator = BigUInt(2)
        let primeBytes = leftPad(Array(prime.serialize()), to: 2)
        let genBytes = Array(generator.serialize())

        let clientPriv = leftPad(Array(BigUInt(17).serialize()), to: 2)
        let serverPriv = BigUInt(31)
        let serverPub = generator.power(serverPriv, modulus: prime)
        let serverPubBytes = leftPad(Array(serverPub.serialize()), to: 2)

        let client = try OracleNetworkSecurity.diffieHellmanSharedKey(
            generator: genBytes, prime: primeBytes, serverPublicKey: serverPubBytes,
            privateKey: clientPriv
        )

        // Server recomputes shared = clientPub^serverPriv mod p.
        let clientPub = BigUInt(Data(client.publicKey))
        let serverShared = clientPub.power(serverPriv, modulus: prime)
        let clientShared = BigUInt(Data(client.shared))
        #expect(clientShared == serverShared)
    }

    @Test func securityUnprotectRecoversPeerProtectedPayload() throws {
        // Oracle uses directional keystreams: the sender's checksum stream (key fold
        // 90) differs from the receiver's (fold 180), so a single endpoint cannot
        // verify its own `compute`. This models the real wire pairing: a peer endpoint
        // (identical key/iv) protects a packet that this endpoint unprotects. The peer's
        // checksum mirrors what our `validate` consumes via `peerCompute`.
        let response = AdvancedNegotiation.Response(
            encryptionAlgorithmID: Constants.TNS_ANO_ENC_AES256,
            dataIntegrityAlgorithmID: Constants.TNS_ANO_DI_SHA256
        )
        let sharedKey = (0..<48).map { UInt8($0 & 0xFF) }
        let iv = (0..<16).map { UInt8((0xF0 + $0) & 0xFF) }
        var local = try #require(
            try OracleNetworkSecurity.make(from: response, sharedKey: sharedKey, iv: iv)
        )
        var peer = try #require(
            try OracleNetworkSecurity.make(from: response, sharedKey: sharedKey, iv: iv)
        )

        let payload = (0..<200).map { UInt8($0 & 0xFF) }
        let protected = try peer.protectAsPeer(payload)
        // Protected payload grows by the checksum, AES padding and the folding byte.
        #expect(protected.count > payload.count)
        let recovered = try local.unprotect(protected)
        #expect(recovered == payload)
    }

    @Test func rc4HashVerifiesPeerChecksumForMD5() throws {
        let sharedKey = (0..<16).map { UInt8($0 & 0xFF) }
        let iv = (0..<16).map { UInt8((0x20 + $0) & 0xFF) }
        var peer = OracleNetworkRC4Hash<Insecure.MD5>(
            key: sharedKey, iv: iv, hashSize: 16
        )
        var local = OracleNetworkRC4Hash<Insecure.MD5>(
            key: sharedKey, iv: iv, hashSize: 16
        )
        let payload: [UInt8] = Array("hello native encryption".utf8)
        let withChecksum = peer.peerCompute(payload)
        #expect(withChecksum.count == payload.count + 16)
        let recovered = try local.validate(withChecksum)
        #expect(recovered == payload)
    }

    private func leftPad(_ bytes: [UInt8], to length: Int) -> [UInt8] {
        guard bytes.count < length else { return Array(bytes.suffix(length)) }
        return [UInt8](repeating: 0, count: length - bytes.count) + bytes
    }
}
