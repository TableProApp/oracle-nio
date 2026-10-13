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

@Suite(.timeLimit(.minutes(5))) struct WarningMessageTests {
    private func context() -> OracleBackendMessageDecoder.Context {
        .init(capabilities: .desired())
    }

    private static let text =
        "ORA-28098: Profile limits PASSWORD_LIFE_TIME and PASSWORD_GRACE_TIME are not unlimited, password will expire within 7 days."

    /// The warning Oracle AI Database 23.26 sent twice ahead of the authentication reply, for a login whose password
    /// was in its grace period, captured off the wire after the message ID: the number, the text's length and the
    /// flags as UB2, then the text with its own length prefix and a trailing newline.
    private static let passwordGraceWarning: [UInt8] = [
        0x02, 0x6D, 0xC2, 0x01, 0x7C, 0x01, 0x04, 0x7C, 0x4F, 0x52, 0x41, 0x2D,
        0x32, 0x38, 0x30, 0x39, 0x38, 0x3A, 0x20, 0x50, 0x72, 0x6F, 0x66, 0x69,
        0x6C, 0x65, 0x20, 0x6C, 0x69, 0x6D, 0x69, 0x74, 0x73, 0x20, 0x50, 0x41,
        0x53, 0x53, 0x57, 0x4F, 0x52, 0x44, 0x5F, 0x4C, 0x49, 0x46, 0x45, 0x5F,
        0x54, 0x49, 0x4D, 0x45, 0x20, 0x61, 0x6E, 0x64, 0x20, 0x50, 0x41, 0x53,
        0x53, 0x57, 0x4F, 0x52, 0x44, 0x5F, 0x47, 0x52, 0x41, 0x43, 0x45, 0x5F,
        0x54, 0x49, 0x4D, 0x45, 0x20, 0x61, 0x72, 0x65, 0x20, 0x6E, 0x6F, 0x74,
        0x20, 0x75, 0x6E, 0x6C, 0x69, 0x6D, 0x69, 0x74, 0x65, 0x64, 0x2C, 0x20,
        0x70, 0x61, 0x73, 0x73, 0x77, 0x6F, 0x72, 0x64, 0x20, 0x77, 0x69, 0x6C,
        0x6C, 0x20, 0x65, 0x78, 0x70, 0x69, 0x72, 0x65, 0x20, 0x77, 0x69, 0x74,
        0x68, 0x69, 0x6E, 0x20, 0x37, 0x20, 0x64, 0x61, 0x79, 0x73, 0x2E, 0x0A,
    ]

    @Test func passwordGraceWarningDecodesToItsLastByte() throws {
        let nextMessage = OracleBackendMessage.MessageID.parameter.rawValue
        var buffer = ByteBuffer(bytes: Self.passwordGraceWarning + [nextMessage])
        let warning = try BackendError.decodeWarning(from: &buffer, context: context())
        #expect(warning.number == 28098)
        #expect(warning.message == Self.text)
        #expect(warning.isWarning)
        #expect(buffer.readableBytes == 1)
        #expect(buffer.readInteger(as: UInt8.self) == nextMessage)
    }

    /// Read as fixed-width integers, the number and length came out as nonsense and the text read ran past the
    /// packet, so the decoder waited for bytes the server would never send and the login hung until its deadline.
    @Test func warningsInsideADataPacketDecodeCompletely() throws {
        let dataFlags: [UInt8] = [0x20, 0x00]
        let warning = [OracleBackendMessage.MessageID.warning.rawValue] + Self.passwordGraceWarning
        let endOfRequest = OracleBackendMessage.MessageID.endOfRequest.rawValue
        var buffer = ByteBuffer(bytes: dataFlags + warning + warning + [endOfRequest])
        let (messages, _) = try OracleBackendMessage.decode(from: &buffer, of: .data, context: context())
        #expect(messages.count == 2)
        for message in messages {
            guard case .warning(let warning) = message else {
                Issue.record("Expected a warning, got \(message)")
                continue
            }
            #expect(warning.number == 28098)
            #expect(warning.message == Self.text)
        }
        #expect(buffer.readableBytes == 0)
    }

    @Test func warningWithoutTextHasNoMessage() throws {
        var buffer = ByteBuffer(bytes: [0x00, 0x00, 0x00])
        let warning = try BackendError.decodeWarning(from: &buffer, context: context())
        #expect(warning.number == 0)
        #expect(warning.message == nil)
        #expect(OracleWarning(warning) == nil)
        #expect(buffer.readableBytes == 0)
    }

    @Test func truncatedWarningAsksForMoreData() {
        var buffer = ByteBuffer(bytes: Array(Self.passwordGraceWarning.dropLast(10)))
        #expect(throws: OraclePartialDecodingError.self) {
            try BackendError.decodeWarning(from: &buffer, context: context())
        }
    }
}
