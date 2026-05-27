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
import NIOTestUtils
import Testing

@testable import OracleNIO

@Suite(.timeLimit(.minutes(5))) final class AcceptMessageTests {
    typealias Message = OracleBackendMessageDecoder.Container

    @Test func decodeAccept() {
        var expected = [Message]()
        var buffer = ByteBuffer()
        let encoder = OracleBackendMessageEncoder(protocolVersion: 0)

        // add before oob check
        var cap1 = Capabilities()
        cap1.protocolVersion = Constants.TNS_VERSION_MIN_ACCEPTED
        let message1 = Message(messages: [.accept(.init(newCapabilities: cap1))])
        encoder.encode(data: message1, out: &buffer)
        expected.append(message1)

        // add with oob check but without fast auth
        var cap2 = Capabilities()
        cap2.protocolVersion = Constants.TNS_VERSION_MIN_OOB_CHECK
        let message2 = Message(messages: [.accept(.init(newCapabilities: cap2))])
        encoder.encode(data: message2, out: &buffer)
        expected.append(message2)

        // add with oob check and fast auth
        var cap3 = Capabilities()
        cap3.protocolVersion = Constants.TNS_VERSION_MIN_OOB_CHECK
        cap3.supportsFastAuth = true
        let message3 = Message(messages: [.accept(.init(newCapabilities: cap3))])
        encoder.encode(data: message3, out: &buffer)
        expected.append(message3)

        #expect(
            throws: Never.self,
            performing: {
                try ByteToMessageDecoderVerifier.verifyDecoder(
                    inputOutputPairs: [(buffer, expected.map({ [$0] }))],
                    decoderFactory: {
                        OracleBackendMessageDecoder()
                    }
                )
            })
    }

    @Test func decodeUnsupportedVersion() throws {
        // protocol version 312 (Oracle 10g) is below the 11.1 floor and uses the
        // unsupported O3LOGON handshake, so it must be rejected
        let message = try ByteBuffer(
            bytes: Array(
                hexString:
                    "00 20 00 00 02 00 00 00 01 38 04 01 20 00 20 00 01 00 00 00 00 20 c5 00 00 00 00 00 00 00 00 00"
                    .replacing(" ", with: "")
            ))
        #expect(
            throws: OracleSQLError.serverVersionNotSupported,
            performing: {
                try ByteToMessageDecoderVerifier.verifyDecoder(inputOutputPairs: [(message, [])]) {
                    OracleBackendMessageDecoder()
                }
            })
    }

    @Test func decode11gAccept() throws {
        // a real Oracle 11.2 Accept packet: protocol version 314, 24-byte payload
        // with no SDU or OOB fields (added in 12.1 / 12.2)
        let message = try ByteBuffer(
            bytes: Array(
                hexString:
                    "00 20 00 00 02 00 00 00 01 3a 04 01 20 00 20 00 01 00 00 00 00 20 c5 00 00 00 00 00 00 00 00 00"
                    .replacing(" ", with: "")
            ))
        var capabilities = Capabilities()
        capabilities.adjustForProtocol(version: 314, options: 0x0401, flags: 0)
        let expected = Message(messages: [.accept(.init(newCapabilities: capabilities))])
        #expect(
            throws: Never.self,
            performing: {
                try ByteToMessageDecoderVerifier.verifyDecoder(
                    inputOutputPairs: [(message, [[expected]])]
                ) {
                    OracleBackendMessageDecoder()
                }
            })
    }
}
