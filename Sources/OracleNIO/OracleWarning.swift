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

/// A condition the server reported on a call that still succeeded, such as
/// `ORA-28002: the password will expire within 7 days` at login.
public struct OracleWarning: Sendable, Hashable, CustomStringConvertible {
    /// The Oracle error number, `28002` for `ORA-28002`.
    public var number: Int
    /// The server's text for the warning, in the session's language.
    public var message: String

    public init(number: Int, message: String) {
        self.number = number
        self.message = message
    }

    /// The server sends the text only with a real warning, so a zero number or a missing text is none.
    init?(_ backend: BackendError) {
        guard backend.number != 0, let message = backend.message, !message.isEmpty else {
            return nil
        }
        self.init(number: Int(backend.number), message: message)
    }

    public var description: String {
        self.message
    }
}
