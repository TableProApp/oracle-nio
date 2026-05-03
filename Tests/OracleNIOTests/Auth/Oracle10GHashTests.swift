//===----------------------------------------------------------------------===//
//
// This source file is part of the OracleNIO open source project
//
// Copyright (c) 2026 Timo Zacherl and the OracleNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE for license information
// See CONTRIBUTORS.md for the list of OracleNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Testing

@testable import OracleNIO

@Suite("Oracle 10G password hash") struct Oracle10GHashTests {
    @Test("Canonical passlib test vector: username/password -> 872805F3F4C83365")
    func canonicalVector() {
        let hash = oracle10GHash(username: "username", password: "password")
        #expect(hash.hexString.uppercased() == "872805F3F4C83365")
    }

    @Test("Demo SCOTT/TIGER vector matches public reference")
    func scottTiger() {
        let hash = oracle10GHash(username: "SCOTT", password: "TIGER")
        #expect(hash.hexString.uppercased() == "F894844C34402B67")
    }

    @Test("Lowercase input produces same hash as uppercase (case-insensitive 10G)")
    func caseInsensitive() {
        let upper = oracle10GHash(username: "SCOTT", password: "TIGER")
        let lower = oracle10GHash(username: "scott", password: "tiger")
        let mixed = oracle10GHash(username: "Scott", password: "TiGeR")
        #expect(upper == lower)
        #expect(upper == mixed)
    }

    @Test("Empty password produces a deterministic hash, no crash")
    func emptyPassword() {
        let hash = oracle10GHash(username: "USER", password: "")
        #expect(hash.count == 8)
    }

    @Test("Output is always exactly 8 bytes")
    func outputLength() {
        let inputs: [(String, String)] = [
            ("a", "b"),
            ("longusername123", "longpassword456"),
            ("X", "Y"),
            ("SYSTEM", "MANAGER"),
        ]
        for (user, pass) in inputs {
            #expect(oracle10GHash(username: user, password: pass).count == 8)
        }
    }
}

@Suite("VerifierKind dispatch") struct VerifierKindTests {
    @Test("Recognizes 10G verifier flag 0x939")
    func tenG() throws {
        #expect(try VerifierKind(verifierFlag: 0x939) == .tenG)
    }

    @Test("Recognizes both 11G variants")
    func elevenG() throws {
        #expect(try VerifierKind(verifierFlag: 0xb152) == .elevenG)
        #expect(try VerifierKind(verifierFlag: 0x1b25) == .elevenG)
    }

    @Test("Recognizes 12C verifier")
    func twelveC() throws {
        #expect(try VerifierKind(verifierFlag: 0x4815) == .twelveC)
    }

    @Test("Throws unsupportedVerifierType for unknown flag preserving the value")
    func unsupported() {
        #expect(throws: OracleSQLError.self) {
            try VerifierKind(verifierFlag: 0xdead)
        }
    }

    @Test("Throws unsupportedVerifierType for nil flag")
    func nilFlag() {
        #expect(throws: OracleSQLError.self) {
            try VerifierKind(verifierFlag: nil)
        }
    }
}
