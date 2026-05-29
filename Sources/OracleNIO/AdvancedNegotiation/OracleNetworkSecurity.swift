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
import _CryptoExtras

/// AES-CBC cipher for native network encryption. Unlike standard PKCS#7, Oracle
/// zero-pads to the block boundary, CBC-encrypts, then appends a single trailing
/// byte equal to `paddingCount + 1`. The IV is the value negotiated during the
/// Diffie-Hellman exchange and stays fixed for the connection.
@usableFromInline
struct OracleNetworkCBCCipher {
    private let key: [UInt8]
    private let iv: [UInt8]

    @usableFromInline
    init(key: [UInt8], iv: [UInt8]) {
        self.key = key
        self.iv = iv
    }

    @usableFromInline
    func encrypt(_ input: [UInt8]) throws -> [UInt8] {
        let padding = input.count % 16 == 0 ? 0 : 16 - (input.count % 16)
        var padded = input
        padded.append(contentsOf: [UInt8](repeating: 0, count: padding))
        var output = try Array(
            AES._CBC.encrypt(
                padded,
                using: SymmetricKey(data: key),
                iv: AES._CBC.IV(ivBytes: iv),
                noPadding: true
            ))
        output.append(UInt8(padding + 1))
        return output
    }

    @usableFromInline
    func decrypt(_ input: [UInt8]) throws -> [UInt8] {
        guard input.count >= 1, (input.count - 1) % 16 == 0 else {
            throw AdvancedNegotiation.DecodingError(reason: "invalid native encryption padding")
        }
        let paddingTrailer = Int(input[input.count - 1])
        guard paddingTrailer >= 1, paddingTrailer <= 16 else {
            throw AdvancedNegotiation.DecodingError(reason: "invalid native encryption padding")
        }
        let padding = paddingTrailer - 1
        let cipherText = Array(input[0..<(input.count - 1)])
        let plain = try Array(
            AES._CBC.decrypt(
                cipherText,
                using: SymmetricKey(data: key),
                iv: AES._CBC.IV(ivBytes: iv),
                noPadding: true
            ))
        return Array(plain[0..<(plain.count - padding)])
    }
}

/// Oracle's non-standard keyed crypto-checksum. The hash is computed over the
/// payload concatenated with a per-call keystream block derived from the shared
/// key and IV, then appended to the payload. Validation recomputes the keystream,
/// hashes the payload, and compares the trailing bytes.
@usableFromInline
protocol OracleNetworkDataIntegrity {
    /// Returns `input` with the keyed checksum appended.
    mutating func compute(_ input: [UInt8]) -> [UInt8]
    /// Strips and verifies the trailing checksum, returning the original payload.
    mutating func validate(_ input: [UInt8]) throws -> [UInt8]

    #if DEBUG
        /// Produces the checksum a peer endpoint appends to a packet this side will
        /// `validate`. The send and receive keystreams are different by design (Oracle
        /// folds the key with 90 for the sender, 180 for the receiver), so a faithful
        /// round-trip test must mirror the peer's send stream rather than reuse
        /// ``compute``. Test-only.
        mutating func peerCompute(_ input: [UInt8]) -> [UInt8]
    #endif
}

/// MD5/SHA1 variant: the keystream comes from an RC4 cipher keyed with the last
/// five bytes of the shared key, `0xFF`, and the IV. Separate RC4 streams (suffix
/// 90 for compute, 180 for validate) feed the per-call block.
struct OracleNetworkRC4Hash<H: HashFunction>: OracleNetworkDataIntegrity {
    private var encryptor: RC4
    private var decryptor: RC4
    private let hashSize: Int

    init(key: [UInt8], iv: [UInt8], hashSize: Int) {
        self.hashSize = hashSize
        var keyGenKey = Array(key.suffix(5))
        keyGenKey.append(0xFF)
        keyGenKey.append(contentsOf: iv)
        var keyGen = RC4(key: keyGenKey)
        let derived = keyGen.process([UInt8](repeating: 0, count: 5))
        self.encryptor = RC4(key: derived + [90])
        self.decryptor = RC4(key: derived + [180])
    }

    mutating func compute(_ input: [UInt8]) -> [UInt8] {
        let block = self.encryptor.process([UInt8](repeating: 0, count: self.hashSize))
        return input + Self.hash(input + block)
    }

    mutating func validate(_ input: [UInt8]) throws -> [UInt8] {
        guard input.count > self.hashSize else {
            throw AdvancedNegotiation.DecodingError(reason: "data integrity check failed: short input")
        }
        let payload = Array(input[0..<(input.count - self.hashSize)])
        let received = Array(input[(input.count - self.hashSize)...])
        let block = self.decryptor.process([UInt8](repeating: 0, count: self.hashSize))
        let computed = Self.hash(payload + block)
        guard computed == received else {
            throw AdvancedNegotiation.DecodingError(reason: "data integrity check failed")
        }
        return payload
    }

    #if DEBUG
        mutating func peerCompute(_ input: [UInt8]) -> [UInt8] {
            let block = self.decryptor.process([UInt8](repeating: 0, count: self.hashSize))
            return input + Self.hash(input + block)
        }
    #endif

    private static func hash(_ input: [UInt8]) -> [UInt8] {
        var hasher = H()
        hasher.update(data: input)
        return Array(hasher.finalize())
    }
}

/// SHA256/384/512 variant. The keystream is produced by stateful AES-CBC ciphers:
/// each call CBC-encrypts the running buffer, and the chain continues from the
/// previous ciphertext (the CBC chaining IV advances across calls). A first folding
/// (`key[5] = 0xFF`) derives the base key and IV; folding `key[5] = 90`/`180`
/// yields the compute/validate ciphers. The hash is computed over the payload
/// concatenated with the current keystream buffer and appended.
struct OracleNetworkAESHash<H: HashFunction>: OracleNetworkDataIntegrity {
    private let hashSize: Int
    private var encryptor: ChainedCBC
    private var decryptor: ChainedCBC
    private var encryptorBuffer: [UInt8]
    private var decryptorBuffer: [UInt8]

    init(key: [UInt8], iv: [UInt8], hashSize: Int) {
        self.hashSize = hashSize

        var aesKey = [UInt8](repeating: 0, count: 16)
        for index in 0..<min(5, key.count) { aesKey[index] = key[index] }
        aesKey[5] = 0xFF

        // The key generator is itself a stateful CBC cipher seeded with the IV. Its
        // first 32-byte output yields the base key (first 16) and base IV (next 16).
        var keyGen = ChainedCBC(key: aesKey, iv: Array(iv.prefix(16)))
        let seed = keyGen.process([UInt8](repeating: 0, count: 32))
        var baseKey = Array(seed[0..<16])
        let baseIV = Array(seed[16..<32])

        baseKey[5] = 90
        self.encryptor = ChainedCBC(key: baseKey, iv: baseIV)
        baseKey[5] = 180
        self.decryptor = ChainedCBC(key: baseKey, iv: baseIV)

        self.encryptorBuffer = [UInt8](repeating: 0, count: hashSize)
        self.decryptorBuffer = [UInt8](repeating: 0, count: hashSize)
    }

    mutating func compute(_ input: [UInt8]) -> [UInt8] {
        self.encryptorBuffer = self.encryptor.process(self.encryptorBuffer)
        return input + Self.hash(input + self.encryptorBuffer)
    }

    mutating func validate(_ input: [UInt8]) throws -> [UInt8] {
        guard input.count > self.hashSize else {
            throw AdvancedNegotiation.DecodingError(reason: "data integrity check failed: short input")
        }
        let payload = Array(input[0..<(input.count - self.hashSize)])
        let received = Array(input[(input.count - self.hashSize)...])
        self.decryptorBuffer = self.decryptor.process(self.decryptorBuffer)
        let computed = Self.hash(payload + self.decryptorBuffer)
        guard computed == received else {
            throw AdvancedNegotiation.DecodingError(reason: "data integrity check failed")
        }
        return payload
    }

    #if DEBUG
        mutating func peerCompute(_ input: [UInt8]) -> [UInt8] {
            self.decryptorBuffer = self.decryptor.process(self.decryptorBuffer)
            return input + Self.hash(input + self.decryptorBuffer)
        }
    #endif

    private static func hash(_ input: [UInt8]) -> [UInt8] {
        var hasher = H()
        hasher.update(data: input)
        return Array(hasher.finalize())
    }
}

/// A stateful AES-CBC encrypter. Each `process` call CBC-encrypts the input and
/// carries the last ciphertext block forward as the chaining IV for the next call,
/// matching Go's `cipher.BlockMode.CryptBlocks`.
struct ChainedCBC {
    private let key: [UInt8]
    private var chainingIV: [UInt8]

    init(key: [UInt8], iv: [UInt8]) {
        self.key = key
        self.chainingIV = Array(iv.prefix(16))
    }

    mutating func process(_ input: [UInt8]) -> [UInt8] {
        let output =
            (try? Array(
                AES._CBC.encrypt(
                    input,
                    using: SymmetricKey(data: self.key),
                    iv: AES._CBC.IV(ivBytes: self.chainingIV),
                    noPadding: true
                ))) ?? input
        if output.count >= 16 {
            self.chainingIV = Array(output.suffix(16))
        }
        return output
    }
}

/// Holds the negotiated cipher and checksum and applies them to each data packet
/// once the ANO handshake completes. Encrypt then append checksum is reversed on
/// receive: decrypt then validate checksum.
@usableFromInline
struct OracleNetworkSecurity {
    @usableFromInline
    var cipher: OracleNetworkCBCCipher?
    @usableFromInline
    var dataIntegrity: OracleNetworkDataIntegrity?

    @usableFromInline
    var isActive: Bool {
        self.cipher != nil || self.dataIntegrity != nil
    }

    @usableFromInline
    mutating func protect(_ payload: [UInt8]) throws -> [UInt8] {
        var data = payload
        if self.dataIntegrity != nil {
            data = self.dataIntegrity!.compute(data)
        }
        if let cipher = self.cipher {
            data = try cipher.encrypt(data)
        }
        // When encryption or checksum is active, Oracle appends a single trailing
        // folding byte to the protected payload.
        if self.isActive {
            data.append(0)
        }
        return data
    }

    #if DEBUG
        /// Protects a payload the way a peer endpoint would: the checksum uses the
        /// peer's send keystream (the one this side's ``unprotect`` verifies). Test-only.
        mutating func protectAsPeer(_ payload: [UInt8]) throws -> [UInt8] {
            var data = payload
            if self.dataIntegrity != nil {
                data = self.dataIntegrity!.peerCompute(data)
            }
            if let cipher = self.cipher {
                data = try cipher.encrypt(data)
            }
            if self.isActive {
                data.append(0)
            }
            return data
        }
    #endif

    @usableFromInline
    mutating func unprotect(_ payload: [UInt8]) throws -> [UInt8] {
        var data = payload
        // Strip the trailing folding byte before decrypting and validating.
        if self.isActive {
            guard !data.isEmpty else {
                throw AdvancedNegotiation.DecodingError(
                    reason: "native encryption: empty protected payload"
                )
            }
            data.removeLast()
        }
        if let cipher = self.cipher {
            data = try cipher.decrypt(data)
        }
        if self.dataIntegrity != nil {
            data = try self.dataIntegrity!.validate(data)
        }
        return data
    }

    /// Builds the cipher and checksum from the negotiated response. The session key
    /// is the Diffie-Hellman shared secret and the IV comes from the same exchange.
    static func make(
        from response: AdvancedNegotiation.Response,
        sharedKey: [UInt8],
        iv: [UInt8]
    ) throws -> OracleNetworkSecurity? {
        guard response.encryptionAlgorithmID != 0 || response.dataIntegrityAlgorithmID != 0
        else {
            return nil
        }
        var security = OracleNetworkSecurity()
        security.cipher = try makeCipher(
            algorithmID: response.encryptionAlgorithmID, sharedKey: sharedKey, iv: iv
        )
        security.dataIntegrity = try makeDataIntegrity(
            algorithmID: response.dataIntegrityAlgorithmID, sharedKey: sharedKey, iv: iv
        )
        return security
    }

    private static func makeCipher(
        algorithmID: Int, sharedKey: [UInt8], iv: [UInt8]
    ) throws -> OracleNetworkCBCCipher? {
        let keyLength: Int
        switch algorithmID {
        case 0:
            return nil
        case Constants.TNS_ANO_ENC_AES128:
            keyLength = 16
        case Constants.TNS_ANO_ENC_AES192:
            keyLength = 24
        case Constants.TNS_ANO_ENC_AES256:
            keyLength = 32
        default:
            throw AdvancedNegotiation.DecodingError(
                reason: "advanced negotiation: unsupported encryption algorithm \(algorithmID)"
            )
        }
        guard sharedKey.count >= keyLength else {
            throw AdvancedNegotiation.DecodingError(
                reason: "advanced negotiation: short Diffie-Hellman key"
            )
        }
        // The CBC cipher uses a fixed zero IV (the DH IV is only used by the
        // crypto-checksum). This matches the Oracle thin-driver wire behaviour.
        return OracleNetworkCBCCipher(
            key: Array(sharedKey.prefix(keyLength)),
            iv: [UInt8](repeating: 0, count: 16)
        )
    }

    private static func makeDataIntegrity(
        algorithmID: Int, sharedKey: [UInt8], iv: [UInt8]
    ) throws -> OracleNetworkDataIntegrity? {
        switch algorithmID {
        case 0:
            return nil
        case Constants.TNS_ANO_DI_MD5:
            return OracleNetworkRC4Hash<Insecure.MD5>(key: sharedKey, iv: iv, hashSize: 16)
        case Constants.TNS_ANO_DI_SHA1:
            return OracleNetworkRC4Hash<Insecure.SHA1>(key: sharedKey, iv: iv, hashSize: 20)
        case Constants.TNS_ANO_DI_SHA256:
            return OracleNetworkAESHash<SHA256>(key: sharedKey, iv: iv, hashSize: 32)
        case Constants.TNS_ANO_DI_SHA384:
            return OracleNetworkAESHash<SHA384>(key: sharedKey, iv: iv, hashSize: 48)
        case Constants.TNS_ANO_DI_SHA512:
            return OracleNetworkAESHash<SHA512>(key: sharedKey, iv: iv, hashSize: 64)
        default:
            throw AdvancedNegotiation.DecodingError(
                reason: "advanced negotiation: unsupported data integrity algorithm \(algorithmID)"
            )
        }
    }

    static func randomPrivateKey(byteLength: Int) -> [UInt8] {
        Self.randomBytes(count: byteLength)
    }

    /// Computes the client public key `g^priv mod p` and the shared key
    /// `serverPub^priv mod p`. Both outputs are left-padded to the prime's byte
    /// length, matching `big.Int.FillBytes` in go-ora.
    static func diffieHellmanSharedKey(
        generator: [UInt8], prime: [UInt8], serverPublicKey: [UInt8],
        privateKey: [UInt8]? = nil
    ) throws -> (publicKey: [UInt8], shared: [UInt8]) {
        let byteLength = prime.count
        let privateBytes = privateKey ?? Self.randomBytes(count: byteLength)
        let g = BigUInt(Data(generator))
        let p = BigUInt(Data(prime))
        let priv = BigUInt(Data(privateBytes))
        let serverPub = BigUInt(Data(serverPublicKey))
        guard p > 0 else {
            throw AdvancedNegotiation.DecodingError(reason: "advanced negotiation: zero prime")
        }
        let publicKey = g.power(priv, modulus: p)
        let shared = serverPub.power(priv, modulus: p)
        return (
            publicKey: leftPad(Array(publicKey.serialize()), to: byteLength),
            shared: leftPad(Array(shared.serialize()), to: byteLength)
        )
    }

    private static func leftPad(_ bytes: [UInt8], to length: Int) -> [UInt8] {
        guard bytes.count < length else {
            return Array(bytes.suffix(length))
        }
        return [UInt8](repeating: 0, count: length - bytes.count) + bytes
    }

    private static func randomBytes(count: Int) -> [UInt8] {
        // The Diffie-Hellman private key must come from a cryptographically secure
        // source. `SystemRandomNumberGenerator` is backed by the platform CSPRNG
        // (getentropy / arc4random), unlike a seeded generator.
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: count)
        var index = 0
        while index < count {
            var word = generator.next()
            for _ in 0..<MemoryLayout<UInt64>.size where index < count {
                bytes[index] = UInt8(truncatingIfNeeded: word)
                word >>= 8
                index += 1
            }
        }
        return bytes
    }
}

/// Minimal RC4 keystream generator. Swift has no stdlib RC4; native network
/// encryption needs it only to derive the MD5/SHA1 crypto-checksum keystream.
struct RC4 {
    private var state: [UInt8]
    private var i: Int = 0
    private var j: Int = 0

    init(key: [UInt8]) {
        self.state = Array(0...255)
        var j = 0
        for i in 0..<256 {
            j = (j + Int(self.state[i]) + Int(key[i % key.count])) & 0xFF
            self.state.swapAt(i, j)
        }
    }

    mutating func process(_ input: [UInt8]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: input.count)
        for index in input.indices {
            self.i = (self.i + 1) & 0xFF
            self.j = (self.j + Int(self.state[self.i])) & 0xFF
            self.state.swapAt(self.i, self.j)
            let k = self.state[(Int(self.state[self.i]) + Int(self.state[self.j])) & 0xFF]
            output[index] = input[index] ^ k
        }
        return output
    }
}
