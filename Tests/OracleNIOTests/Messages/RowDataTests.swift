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
