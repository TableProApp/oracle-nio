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

@Suite(.timeLimit(.minutes(5))) struct ServerSidePiggybackTests {
    private func context() -> OracleBackendMessageDecoder.Context {
        .init(capabilities: .desired())
    }

    @Test func wellFormedSyncDecodes() throws {
        // sync (5): skip 2 + 1, one element (key len 0, value len 0, flags), overall flags.
        var buffer = ByteBuffer(bytes: [
            5,
            0, 0,  // number of DTYs
            0,  // length of DTYs
            0, 1,  // number of elements
            0,  // length
            0, 0,  // element key length
            0, 0,  // element value length
            0, 0,  // element flags
            0, 0, 0, 0,  // overall flags
        ])
        let piggyback = try OracleBackendMessage.ServerSidePiggyback.decode(
            from: &buffer, context: context()
        )
        #expect(piggyback.resetStatementCache == false)
    }

    @Test func truncatedSyncThrowsInsteadOfTrapping() {
        // Claims one element but ends before the element flags can be skipped. Must throw,
        // not trap on moveReaderIndex past the buffer end (#1683).
        var buffer = ByteBuffer(bytes: [
            5,
            0, 0,
            0,
            0, 1,
            0,
            0, 0,
            0, 0,
        ])
        #expect(throws: OraclePartialDecodingError.self) {
            _ = try OracleBackendMessage.ServerSidePiggyback.decode(
                from: &buffer, context: context()
            )
        }
    }

    @Test func truncatedSessRetThrowsInsteadOfTrapping() {
        // sessRet (4) with a header that runs out before the trailing flags.
        var buffer = ByteBuffer(bytes: [
            4,
            0, 0,
            0,
            0, 0,  // zero elements
        ])
        #expect(throws: OraclePartialDecodingError.self) {
            _ = try OracleBackendMessage.ServerSidePiggyback.decode(
                from: &buffer, context: context()
            )
        }
    }

    @Test func syncInsideDataPacketSurfacesErrorInsteadOfTrapping() {
        // The full data-packet path turns a short piggyback into a recoverable decoding
        // error rather than crashing the channel thread.
        var buffer = ByteBuffer(bytes: [
            0, 0,  // data flags
            23,  // message id: server side piggyback
            5,  // sync
            0, 0,
            0,
            0, 1,
            0,
            0, 0,
            0, 0,
        ])
        #expect(throws: (any Error).self) {
            _ = try OracleBackendMessage.decode(
                from: &buffer, of: .data, context: context()
            )
        }
    }
}
