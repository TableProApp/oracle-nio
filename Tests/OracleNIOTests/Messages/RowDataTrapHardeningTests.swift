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

private typealias RowData = OracleBackendMessage.RowData
private typealias BitVector = OracleBackendMessage.BitVector

@Suite(.timeLimit(.minutes(5))) struct RowDataTrapHardeningTests {

    @Test func rowDataWithoutStatementContextThrows() {
        var buffer = ByteBuffer(bytes: [1, 65])
        let context = OracleBackendMessageDecoder.Context(capabilities: .init())
        #expect(throws: OraclePartialDecodingError.self) {
            try RowData.decode(from: &buffer, context: context)
        }
    }

    @Test func shortBitVectorThrowsInsteadOfTrapping() {
        var buffer = ByteBuffer(bytes: [1, 65])
        let context = OracleBackendMessageDecoder.Context(columns: .varchar, .varchar)
        context.bitVector = []
        #expect(throws: OraclePartialDecodingError.self) {
            try RowData.decode(from: &buffer, context: context)
        }
    }

    @Test func bitVectorWithoutDescribeInfoThrows() {
        var buffer = ByteBuffer(bytes: [1, 2])
        let context = OracleBackendMessageDecoder.Context(capabilities: .init())
        context.statementContext = .init(statement: "")
        #expect(throws: OraclePartialDecodingError.self) {
            try BitVector.decode(from: &buffer, context: context)
        }
    }
}
