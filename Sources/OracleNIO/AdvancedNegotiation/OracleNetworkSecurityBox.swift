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

/// Shared, mutable holder for the negotiated native network encryption state.
///
/// The cipher (fixed IV) and the keyed crypto-checksum (advancing keystream) are
/// installed once the ANO handshake completes and are then applied per data packet
/// by the outbound post-processor and the inbound decoder. All three handlers run
/// on the same channel event loop, so plain reference sharing without locking is
/// safe and avoids re-deriving keys per packet.
@usableFromInline
final class OracleNetworkSecurityBox {
    @usableFromInline
    var security: OracleNetworkSecurity?

    @usableFromInline
    var isActive: Bool {
        self.security?.isActive ?? false
    }

    @usableFromInline
    init() {}

    @usableFromInline
    func protect(_ payload: [UInt8]) throws -> [UInt8] {
        guard var security = self.security else { return payload }
        let result = try security.protect(payload)
        self.security = security
        return result
    }

    @usableFromInline
    func unprotect(_ payload: [UInt8]) throws -> [UInt8] {
        guard var security = self.security else { return payload }
        let result = try security.unprotect(payload)
        self.security = security
        return result
    }
}
