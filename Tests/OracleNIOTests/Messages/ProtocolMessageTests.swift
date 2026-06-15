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

@Suite(.timeLimit(.minutes(5))) struct ProtocolMessageTests {
    private func context() -> OracleBackendMessageDecoder.Context {
        .init(capabilities: .desired())
    }

    @Test func wellFormedFDOComputesFullCharsetID() throws {
        var buffer = ByteBuffer(bytes: [
            0, 0,  // protocol array
            0,  // server banner terminator
            0, 0,  // charset id
            0,  // server flags
            0, 0,  // element count
            0, 11,  // fdo length
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0x07, 0xD0,  // fdo (ix = 6, nCharsetID = fdo[9..10])
            0,  // server compile capabilities (empty)
            0,  // server runtime capabilities (empty)
        ])
        let message = try OracleBackendMessage.`Protocol`.decode(
            from: &buffer, context: context()
        )
        #expect(message.newCapabilities.nCharsetID == 0x07D0)
    }

    @Test func shortFDOThrowsInsteadOfTrapping() {
        // fdo shorter than the indices the charset parser reads. Must throw, not trap on
        // an out-of-bounds subscript or a UInt8 overflow computing ix.
        var buffer = ByteBuffer(bytes: [
            0, 0,
            0,
            0, 0,
            0,
            0, 0,
            0, 3,  // fdo length 3
            1, 2, 3,  // fdo (too short for fdo[5]/fdo[6])
        ])
        #expect(throws: OraclePartialDecodingError.self) {
            _ = try OracleBackendMessage.`Protocol`.decode(
                from: &buffer, context: context()
            )
        }
    }
}
