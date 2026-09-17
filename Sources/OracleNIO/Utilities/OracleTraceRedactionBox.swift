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

import Atomics

/// Marks the point in a connection's life after which a packet trace must not carry
/// payload bytes.
///
/// The authentication exchange puts the password verifier, the session key and, for
/// token authentication, the token itself on the wire. A hex dump of those packets is a
/// credential, so the tracer stops dumping bodies once this is set and never resumes.
///
/// The flag is set at the one place the authentication messages are emitted, rather than
/// by asking the connection what state it is in. A state added later would not know to
/// exclude itself, and the failure mode of forgetting is a leak.
final class OracleTraceRedactionBox: Sendable {
    private let redacted = ManagedAtomic(false)

    init() {}

    var isRedacted: Bool {
        self.redacted.load(ordering: .relaxed)
    }

    /// Latches redaction on. There is deliberately no way to clear it: a connection that
    /// has sent credentials keeps carrying them in its session state.
    func redactFromNowOn() {
        self.redacted.store(true, ordering: .relaxed)
    }
}
