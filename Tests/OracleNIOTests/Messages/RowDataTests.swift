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
import NIOEmbedded
import Testing

@testable import OracleNIO

private typealias RowData = OracleBackendMessage.RowData

@Suite(.timeLimit(.minutes(5))) struct RowDataTests {

    @Test func processVectorColumnDataRequestsMissingData() {
        let type = OracleDataType.vector

        var buffer = ByteBuffer(bytes: [
            1, 1,  // length
            0,  // size
            0,  // chunk size
            1,  // value (partial)
        ])
        Self.expectNeedsMoreData(&buffer, type)

        buffer = ByteBuffer(bytes: [
            1, 1,  // length
            0,  // size
            0,  // chunk size
            1, 1,  // value
            1,  // locator (partial)
        ])
        Self.expectNeedsMoreData(&buffer, type)
    }

    @Test func processObjectColumnDataRequestsMissingData() throws {
        let type = OracleDataType.object

        var buffer = ByteBuffer(bytes: [1, 1])  // type oid
        Self.expectNeedsMoreData(&buffer, type)

        buffer = ByteBuffer(bytes: [
            1, 1, 0,  // type oid
            1, 1,  // oid
        ])
        Self.expectNeedsMoreData(&buffer, type)

        buffer = ByteBuffer(bytes: [
            1, 1, 0,  // type oid
            1, 1, 0,  // oid
            1, 1,  // snapshot
        ])
        Self.expectNeedsMoreData(&buffer, type)

        buffer = ByteBuffer(bytes: [
            1, 1, 0,  // type oid
            1, 1, 0,  // oid
            1, 1, 0,  // snapshot
            0,  // version
            0,  // data length
            0,  // flags
        ])
        #expect(
            throws: Never.self,
            performing: {
                try RowData.decode(from: &buffer, context: .init(columns: type))
            })
    }

    /// Measured on Oracle 23ai: a NULL object still ends with its UB2 flags, and a value read as
    /// LONG RAW ends with an SB4 null indicator and a UB4 return code. A packet that ends inside one
    /// of them used to leave the rest to be read as the next message, desynchronising the stream.
    @Test func fieldsSplitAtAPacketEndRequestMoreData() {
        var nullObjectFlagsSplit = ByteBuffer(bytes: [
            0,  // type oid
            0,  // oid
            0,  // snapshot
            0,  // version
            0,  // data length
            1,  // flags: length byte, value in the next packet
        ])
        Self.expectNeedsMoreData(&nullObjectFlagsSplit, .object)

        var longRawReturnCodeMissing = ByteBuffer(bytes: [
            2, 0xAB, 0xCD,  // value
            0,  // null indicator
        ])
        Self.expectNeedsMoreData(&longRawReturnCodeMissing, .longRAW)

        var nullLongRawIndicatorSplit = ByteBuffer(bytes: [
            0,  // value (NULL)
            0x81,  // null indicator: negative, one byte, value in the next packet
        ])
        Self.expectNeedsMoreData(&nullLongRawIndicatorSplit, .longRAW)
    }

    @Test func objectWithANullLengthIndicatorDecodes() throws {
        var buffer = ByteBuffer(bytes: [
            1, 16,  // type oid length
            Constants.TNS_NULL_LENGTH_INDICATOR,  // type oid
            0,  // oid
            0,  // snapshot
            0,  // version
            0,  // data length
            1, 1,  // flags
        ])
        _ = try RowData.decode(from: &buffer, context: .init(columns: .object))
        #expect(buffer.readableBytes == 0)
    }

    /// Measured on Oracle 23ai: a NULL object is sent with a data length of zero.
    @Test func objectWithoutDataIsNull() throws {
        var buffer = ByteBuffer(bytes: [
            1, 1, 1, 7,  // type oid
            0,  // oid
            0,  // snapshot
            0,  // version
            0,  // data length
            1, 1,  // flags
        ])
        let row = try RowData.decode(from: &buffer, context: .init(columns: .object))
        #expect(row == .init(columns: [.data(ByteBuffer(bytes: [0]))]))
        #expect(buffer.readableBytes == 0)
    }

    /// A chunked value shorter than 254 bytes used to wait for bytes that never came.
    @Test func shortChunkedObjectDecodes() throws {
        var buffer = ByteBuffer(bytes: [
            0,  // type oid
            0,  // oid
            0,  // snapshot
            0,  // version
            1, 10,  // data length
            1, 1,  // flags
            Constants.TNS_LONG_LENGTH_INDICATOR,
            1, 10,  // chunk length
        ])
        buffer.writeRepeatingByte(7, count: 10)
        buffer.writeInteger(UInt8(0))  // end of chunks
        _ = try RowData.decode(from: &buffer, context: .init(columns: .object))
        #expect(buffer.readableBytes == 0)
    }

    @Test func processLOBColumnDataRequestsMissingData() throws {
        let type = OracleDataType.blob

        var buffer = ByteBuffer(bytes: [
            1, 1,  // length
            1, 1,  // size
            1, 1,  // chunk size
            2, 0,  // locator (partial)
        ])
        Self.expectNeedsMoreData(&buffer, type)

        buffer = ByteBuffer(bytes: [
            1, 1,  // length
            1, 1,  // size
            1, 1,  // chunk size
            1, 0,  // locator
        ])
        #expect(
            throws: Never.self,
            performing: {
                try RowData.decode(from: &buffer, context: .init(columns: type))
            })

        buffer = ByteBuffer(bytes: [0])
        #expect(
            throws: Never.self,
            performing: {
                try RowData.decode(from: &buffer, context: .init(columns: type))
            })
    }

    @Test func processBufferSizeZero() throws {
        var buffer = ByteBuffer()
        let context = OracleBackendMessageDecoder.Context(capabilities: .init())
        context.statementContext = .init(statement: "")
        context.describeInfo = .init(columns: [
            .init(
                name: "",
                dataType: .varchar,
                dataTypeSize: 0,
                precision: 0,
                scale: 0,
                bufferSize: 0,
                nullsAllowed: true,
                typeScheme: nil,
                typeName: nil,
                domainSchema: nil,
                domainName: nil,
                annotations: [:],
                vectorDimensions: nil,
                vectorFormat: nil
            )
        ])
        let result = try RowData.decode(from: &buffer, context: context)
        #expect(result == .init(columns: [.data(ByteBuffer(bytes: [0]))]))
    }

    @Test func emptyRowID() throws {
        var buffer = ByteBuffer(bytes: [0])
        let context = OracleBackendMessageDecoder.Context(columns: .rowID)
        let result = try RowData.decode(from: &buffer, context: context)
        #expect(result == .init(columns: [.data(ByteBuffer(bytes: [0]))]))
    }

    @Test func emptyBufferZeroActualBytes() throws {
        var buffer = ByteBuffer(bytes: [0, 1, 255])
        let context = OracleBackendMessageDecoder.Context(capabilities: .init())
        let promise = EmbeddedEventLoop().makePromise(of: OracleRowStream.self)
        promise.fail(StatementContext.TestComplete())
        var statement: OracleStatement = ""
        statement.binds.append(.init(dataType: .boolean), bindName: "1", isReturning: false)
        context.statementContext = .init(statement: statement)
        let result = try RowData.decode(from: &buffer, context: context)
        #expect(result == .init(columns: [.data(ByteBuffer(bytes: [0]))]))
    }

    /// An OUT bind ends with its actual byte count. The LONG trailer belongs to fetched rows only.
    @Test(arguments: [OracleDataType.long, .longRAW])
    func longOutBindEndsWithItsByteCount(type: OracleDataType) throws {
        var buffer = ByteBuffer(bytes: [
            1, 65,  // value
            0,  // actual byte count
        ])
        let context = OracleBackendMessageDecoder.Context(capabilities: .init())
        var statement: OracleStatement = ""
        statement.binds.append(.init(dataType: type), bindName: "1", isReturning: false)
        context.statementContext = .init(statement: statement)
        let row = try RowData.decode(from: &buffer, context: context)
        #expect(row == .init(columns: [.data(ByteBuffer(bytes: [1, 65]))]))
        #expect(buffer.readableBytes == 0)
    }

    /// Measured on Oracle 23ai: a slice holding the rowid's length, then the rowid. A physical rowid
    /// reads in its 18-character form, a logical one (an index-organized table's) as `*` and base64.
    @Test func universalRowIDsDecode() throws {
        let cases: [(wire: [UInt8], text: String)] = [
            ([1, 13, 13, 1, 0, 1, 0x20, 0x1d, 0, 0x18, 0, 0, 1, 0xf4, 0, 0], "AAASAdAAYAAAAH0AAA"),
            ([1, 10, 10, 2, 4, 6, 0, 1, 0xeb, 2, 0xc1, 2, 0xfe], "*BAYAAesCwQL+"),
            ([1, 3, 3, 2, 4, 6], "*BAY"),
            ([1, 2, 2, 2, 0xff], "*/w"),
        ]
        for testCase in cases {
            var buffer = ByteBuffer(bytes: testCase.wire)
            let row = try RowData.decode(from: &buffer, context: .init(columns: .uRowID))
            var expected = ByteBuffer()
            expected.writeInteger(UInt8(testCase.text.utf8.count))
            expected.writeString(testCase.text)
            #expect(row == .init(columns: [.data(expected)]))
            #expect(buffer.readableBytes == 0)
        }
    }

    /// Measured on Oracle 23ai: a REF column is described with type 111 and its value is one
    /// length-prefixed slice. Both used to fail, the describe with `oracleTypeNotSupported`.
    @Test func refColumnIsReadPast() throws {
        #expect(try OracleDataType.fromORATypeAndCSFRM(typeNumber: 111, csfrm: 0) == .ref)
        let reference: [UInt8] = [0, 0x22, 2, 8] + [UInt8](repeating: 0x5d, count: 32)
        var buffer = ByteBuffer(bytes: [UInt8(reference.count)] + reference + [3, 0x6f, 0x6e, 0x65])
        let row = try RowData.decode(from: &buffer, context: .init(columns: .ref, .varchar))
        #expect(
            row
                == .init(columns: [
                    .data(ByteBuffer(bytes: [UInt8(reference.count)] + reference)),
                    .data(ByteBuffer(bytes: [3, 0x6f, 0x6e, 0x65])),
                ]))
        #expect(buffer.readableBytes == 0)

        var null = ByteBuffer(bytes: [0, 3, 0x74, 0x77, 0x6f])
        let nullRow = try RowData.decode(from: &null, context: .init(columns: .ref, .varchar))
        #expect(nullRow == .init(columns: [.data(ByteBuffer(bytes: [0])), .data(ByteBuffer(bytes: [3, 0x74, 0x77, 0x6f]))]))
    }

    @Test func nullUniversalRowIDIsOneByte() throws {
        var buffer = ByteBuffer(bytes: [0])
        let row = try RowData.decode(from: &buffer, context: .init(columns: .uRowID))
        #expect(row == .init(columns: [.data(ByteBuffer(bytes: [0]))]))
        #expect(buffer.readableBytes == 0)
    }

    /// A logical rowid of a long key is longer than one length byte can frame.
    @Test func longUniversalRowIDDecodes() throws {
        let data = [UInt8](repeating: 0x6b, count: 300)
        var buffer = ByteBuffer(bytes: [2, 0x01, 0x2d])  // the length slice: 301
        buffer.writeInteger(Constants.TNS_LONG_LENGTH_INDICATOR)
        buffer.writeUB4(301)
        buffer.writeInteger(UInt8(2))
        buffer.writeBytes(data)
        buffer.writeUB4(0)
        let row = try RowData.decode(from: &buffer, context: .init(columns: .uRowID))
        #expect(buffer.readableBytes == 0)
        let text = "*" + String(repeating: "a2tr", count: 100)
        let decoded = OracleRow(
            lookupTable: [:],
            data: DataRow(columnCount: 1, bytes: try Self.rowBytes(row)),
            columns: [Self.column(.uRowID)]
        )
        for cell in decoded {
            #expect(try cell.decode(String.self) == text)
        }
    }

    @Test func universalRowIDSplitAcrossPacketsRequestsMoreData() {
        var lengthOnly = ByteBuffer(bytes: [1, 13])
        Self.expectNeedsMoreData(&lengthOnly, .uRowID)
        var partialRowID = ByteBuffer(bytes: [1, 13, 13, 1, 0, 1])
        Self.expectNeedsMoreData(&partialRowID, .uRowID)
    }

    private static func rowBytes(_ row: RowData) throws -> ByteBuffer {
        var out = ByteBuffer()
        for column in row.columns {
            guard case .data(var bytes) = column else { throw TestError() }
            out.writeBuffer(&bytes)
        }
        return out
    }

    private static func column(_ type: OracleDataType) -> DescribeInfo.Column {
        .init(
            name: "", dataType: type, dataTypeSize: 0, precision: 0, scale: 0, bufferSize: 1,
            nullsAllowed: true, typeScheme: nil, typeName: nil, domainSchema: nil, domainName: nil,
            annotations: [:], vectorDimensions: nil, vectorFormat: nil
        )
    }

    private struct TestError: Error {}

    /// Either signal makes the decoder keep the message and retry it with the next packet.
    private static func expectNeedsMoreData(
        _ buffer: inout ByteBuffer,
        _ type: OracleDataType,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            _ = try RowData.decode(from: &buffer, context: .init(columns: type))
            Issue.record("Decoded a row whose last field is incomplete", sourceLocation: sourceLocation)
        } catch is MissingDataDecodingError.Trigger {
        } catch let error as OraclePartialDecodingError where error.category == .expectedAtLeastNRemainingBytes {
        } catch {
            Issue.record("Expected a request for more data, got \(error)", sourceLocation: sourceLocation)
        }
    }
}
