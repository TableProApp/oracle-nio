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

    /// The `sync` piggyback Oracle AI Database 23.26 sent after `ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY'`,
    /// captured off the wire from the operation code to the overall flags: 18 NLS keyword/value pairs.
    private static let alterSessionSync: [UInt8] = [
        0x05, 0x01, 0x01, 0x10, 0x01, 0x12, 0x16, 0x00, 0x01, 0x08, 0x08, 0x41,
        0x4D, 0x45, 0x52, 0x49, 0x43, 0x41, 0x4E, 0x01, 0x10, 0x00, 0x01, 0x07,
        0x07, 0x41, 0x4D, 0x45, 0x52, 0x49, 0x43, 0x41, 0x01, 0x09, 0x00, 0x01,
        0x01, 0x01, 0x24, 0x00, 0x00, 0x01, 0x07, 0x07, 0x41, 0x4D, 0x45, 0x52,
        0x49, 0x43, 0x41, 0x01, 0x01, 0x00, 0x01, 0x02, 0x02, 0x2E, 0x2C, 0x01,
        0x02, 0x00, 0x01, 0x08, 0x08, 0x41, 0x4C, 0x33, 0x32, 0x55, 0x54, 0x46,
        0x38, 0x01, 0x0A, 0x00, 0x01, 0x09, 0x09, 0x47, 0x52, 0x45, 0x47, 0x4F,
        0x52, 0x49, 0x41, 0x4E, 0x01, 0x0C, 0x00, 0x01, 0x04, 0x04, 0x59, 0x59,
        0x59, 0x59, 0x01, 0x07, 0x00, 0x01, 0x08, 0x08, 0x41, 0x4D, 0x45, 0x52,
        0x49, 0x43, 0x41, 0x4E, 0x01, 0x08, 0x00, 0x01, 0x06, 0x06, 0x42, 0x49,
        0x4E, 0x41, 0x52, 0x59, 0x01, 0x0B, 0x00, 0x01, 0x0E, 0x0E, 0x48, 0x48,
        0x2E, 0x4D, 0x49, 0x2E, 0x53, 0x53, 0x58, 0x46, 0x46, 0x20, 0x41, 0x4D,
        0x01, 0x39, 0x00, 0x01, 0x18, 0x18, 0x44, 0x44, 0x2D, 0x4D, 0x4F, 0x4E,
        0x2D, 0x52, 0x52, 0x20, 0x48, 0x48, 0x2E, 0x4D, 0x49, 0x2E, 0x53, 0x53,
        0x58, 0x46, 0x46, 0x20, 0x41, 0x4D, 0x01, 0x3A, 0x00, 0x01, 0x12, 0x12,
        0x48, 0x48, 0x2E, 0x4D, 0x49, 0x2E, 0x53, 0x53, 0x58, 0x46, 0x46, 0x20,
        0x41, 0x4D, 0x20, 0x54, 0x5A, 0x52, 0x01, 0x3B, 0x00, 0x01, 0x1C, 0x1C,
        0x44, 0x44, 0x2D, 0x4D, 0x4F, 0x4E, 0x2D, 0x52, 0x52, 0x20, 0x48, 0x48,
        0x2E, 0x4D, 0x49, 0x2E, 0x53, 0x53, 0x58, 0x46, 0x46, 0x20, 0x41, 0x4D,
        0x20, 0x54, 0x5A, 0x52, 0x01, 0x3C, 0x00, 0x01, 0x01, 0x01, 0x24, 0x01,
        0x34, 0x00, 0x01, 0x06, 0x06, 0x42, 0x49, 0x4E, 0x41, 0x52, 0x59, 0x01,
        0x32, 0x00, 0x01, 0x04, 0x04, 0x42, 0x59, 0x54, 0x45, 0x01, 0x3D, 0x00,
        0x01, 0x05, 0x05, 0x46, 0x41, 0x4C, 0x53, 0x45, 0x01, 0x3E, 0x00,
    ]

    @Test func syncFromAlterSessionDecodesToItsLastByte() throws {
        let nextMessage = OracleBackendMessage.MessageID.error.rawValue
        var buffer = ByteBuffer(bytes: Self.alterSessionSync + [nextMessage])
        let piggyback = try OracleBackendMessage.ServerSidePiggyback.decode(
            from: &buffer, context: context()
        )
        #expect(piggyback.resetStatementCache == false)
        #expect(buffer.readableBytes == 1)
        #expect(buffer.readInteger(as: UInt8.self) == nextMessage)
    }

    @Test func syncFromAlterSessionInsideADataPacketDecodesCompletely() throws {
        let dataFlags: [UInt8] = [0x20, 0x00]
        let piggybackID = OracleBackendMessage.MessageID.serverSidePiggyback.rawValue
        let endOfRequest = OracleBackendMessage.MessageID.endOfRequest.rawValue
        var buffer = ByteBuffer(bytes: dataFlags + [piggybackID] + Self.alterSessionSync + [endOfRequest])
        let (messages, _) = try OracleBackendMessage.decode(
            from: &buffer, of: .data, context: context()
        )
        #expect(Array(messages) == [.serverSidePiggyback(.init(resetStatementCache: false))])
        #expect(buffer.readableBytes == 0)
    }

    @Test func truncatedSyncThrowsInsteadOfTrapping() {
        // Claims one element but ends inside it.
        var buffer = ByteBuffer(bytes: [
            5,
            0,  // number of DTYs
            0,  // length of DTYs
            1, 1,  // number of elements
            0,  // length
            0,  // text value length
            1, 3,  // binary value length, then the value is missing
        ])
        #expect(throws: OraclePartialDecodingError.self) {
            _ = try OracleBackendMessage.ServerSidePiggyback.decode(
                from: &buffer, context: context()
            )
        }
    }

    @Test func sessRetReportsAChangedSession() throws {
        var buffer = ByteBuffer(bytes: [
            4,
            0,  // number of DTYs
            0,  // length of DTYs
            1, 1,  // number of elements
            0,  // length
            1, 1, 1, 0x61,  // key "a"
            1, 1, 1, 0x62,  // value "b"
            0,  // flags
            1, UInt8(Constants.TNS_SESSGET_SESSION_CHANGED),  // session flags
            1, 0x2A,  // session id
            2, 0x12, 0x34,  // serial number
        ])
        let piggyback = try OracleBackendMessage.ServerSidePiggyback.decode(
            from: &buffer, context: context()
        )
        #expect(piggyback.resetStatementCache)
        #expect(buffer.readableBytes == 0)
    }

    @Test func truncatedSessRetThrowsInsteadOfTrapping() {
        // Runs out before the session flags.
        var buffer = ByteBuffer(bytes: [
            4,
            0,
            0,
            0,  // zero elements
        ])
        #expect(throws: OraclePartialDecodingError.self) {
            _ = try OracleBackendMessage.ServerSidePiggyback.decode(
                from: &buffer, context: context()
            )
        }
    }

    @Test func ltxIDSkipsItsLengthPrefixedValue() throws {
        var buffer = ByteBuffer(bytes: [7, 1, 3, 3, 0x0A, 0x0B, 0x0C, 29])
        _ = try OracleBackendMessage.ServerSidePiggyback.decode(from: &buffer, context: context())
        #expect(buffer.readInteger(as: UInt8.self) == 29)
    }

    @Test func sessionSignatureIsSkipped() throws {
        var buffer = ByteBuffer(bytes: [10, 1, 1, 0, 8, 1, 2, 3, 4, 5, 6, 7, 8, 0, 1, 9, 29])
        _ = try OracleBackendMessage.ServerSidePiggyback.decode(from: &buffer, context: context())
        #expect(buffer.readInteger(as: UInt8.self) == 29)
    }

    @Test func unknownOperationCodeThrowsInsteadOfMisreadingTheRest() {
        var buffer = ByteBuffer(bytes: [0x42, 1, 2, 3])
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
            0,
            0,
            1, 1,
            0,
        ])
        #expect(throws: (any Error).self) {
            _ = try OracleBackendMessage.decode(
                from: &buffer, of: .data, context: context()
            )
        }
    }
}
