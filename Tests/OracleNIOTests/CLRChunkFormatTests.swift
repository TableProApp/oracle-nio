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

import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import Testing

@testable import OracleNIO

@Suite(.timeLimit(.minutes(5))) struct CLRChunkFormatTests {
    private static var smallChunks: Capabilities {
        var capabilities = Capabilities()
        capabilities.clrChunkFormat = .small
        return capabilities
    }

    private static func bytes(_ count: Int, startingAt first: UInt8 = 0) -> [UInt8] {
        (0..<count).map { first &+ UInt8(truncatingIfNeeded: $0) }
    }

    private static func contains(_ buffer: ByteBuffer, _ needle: ByteBuffer) -> Bool {
        let haystack = Array(buffer.readableBytesView)
        let needle = Array(needle.readableBytesView)
        guard needle.count <= haystack.count else { return false }
        return (0...(haystack.count - needle.count)).contains { Array(haystack[$0..<($0 + needle.count)]) == needle }
    }

    // Compile capability 37 measured as 0x00 on Oracle 11.2 and 0x20 on 23ai.
    @Test func serverCompileCapabilityPicksTheFormat() {
        var capabilities = Capabilities()
        var server = ByteBuffer(repeating: 0, count: Constants.TNS_CCAP_MAX)
        capabilities.adjustForServerCompileCapabilities(server)
        #expect(capabilities.clrChunkFormat == .small)

        server.setInteger(Constants.TNS_CCAP_BIG_CHUNK_CLR, at: Constants.TNS_CCAP_TTC3)
        capabilities.adjustForServerCompileCapabilities(server)
        #expect(capabilities.clrChunkFormat == .big)

        capabilities.adjustForServerCompileCapabilities(ByteBuffer(repeating: 0xff, count: Constants.TNS_CCAP_TTC3))
        #expect(capabilities.clrChunkFormat == .small)
    }

    @Test func cursorCellsKeepTheFormat() throws {
        var buffer = ByteBuffer()
        try Self.smallChunks.encode(into: &buffer)
        #expect(try Capabilities(from: &buffer).clrChunkFormat == .small)
    }

    @Test func smallChunksHaveOneByteLengths() {
        let value = Self.bytes(300)
        var buffer = ByteBuffer()
        buffer.writeOracleCLR(value, format: .small)

        var expected = ByteBuffer(integer: Constants.TNS_LONG_LENGTH_INDICATOR)
        var offset = 0
        for length in [64, 64, 64, 64, 44] {
            expected.writeInteger(UInt8(length))
            expected.writeBytes(value[offset..<(offset + length)])
            offset += length
        }
        expected.writeInteger(UInt8(0))
        #expect(buffer == expected)
    }

    @Test func bigChunksHaveUB4Lengths() {
        let value = Self.bytes(300)
        var buffer = ByteBuffer()
        buffer.writeOracleCLR(value, format: .big)

        var expected = ByteBuffer(bytes: [Constants.TNS_LONG_LENGTH_INDICATOR, 2, 0x01, 0x2c])
        expected.writeBytes(value)
        expected.writeInteger(UInt8(0))
        #expect(buffer == expected)
    }

    @Test(arguments: [CLRChunkFormat.small, .big])
    func shortValuesAreFramedTheSameEitherWay(format: CLRChunkFormat) {
        var buffer = ByteBuffer()
        buffer.writeOracleCLR(Self.bytes(Constants.TNS_MAX_SHORT_LENGTH), format: format)
        var expected = ByteBuffer(integer: UInt8(Constants.TNS_MAX_SHORT_LENGTH))
        expected.writeBytes(Self.bytes(Constants.TNS_MAX_SHORT_LENGTH))
        #expect(buffer == expected)
    }

    @Test(arguments: [CLRChunkFormat.small, .big])
    func readersTakeBackWhatTheWriterSent(format: CLRChunkFormat) throws {
        let value = Self.bytes(70_000)
        var written = ByteBuffer()
        written.writeOracleCLR(value, format: format)

        var sliced = written
        #expect(Array(try sliced.throwingReadOracleSpecificLengthPrefixedSlice(chunks: format).readableBytesView) == value)
        #expect(sliced.readableBytes == 0)

        var skipped = written
        try skipped.throwingSkipRawBytesChunked(chunks: format)
        #expect(skipped.readableBytes == 0)

        var row = written
        let read = row.readOracleSlice(chunks: format)
        let cell = try #require(read)
        #expect(row.readableBytes == 0)
        let column = DataRow(columnCount: 1, bytes: cell)[column: 0]
        #expect(column.map { Array($0.readableBytesView) } == value)
    }

    @Test func aPartialSmallChunkWaitsForTheRest() {
        var buffer = ByteBuffer(bytes: [Constants.TNS_LONG_LENGTH_INDICATOR, 64, 1, 2])
        #expect(buffer.readOracleSlice(chunks: .small) == nil)
        #expect(buffer.readerIndex == 0)
    }

    // The fetch response Oracle 11.2 sent for the sidebar's trigger read (#4629): TRIGGER_NAME, then the LONG
    // TRIGGER_BODY in one-byte chunks, then the LONG's null indicator and return code.
    @Test func longValueFrom11gDecodes() throws {
        let body = "BEGIN\n  :NEW.updated := SYSDATE;\nEND;"
        var buffer = ByteBuffer(bytes: [7])
        buffer.writeString("TP_T_BI")
        buffer.writeInteger(Constants.TNS_LONG_LENGTH_INDICATOR)
        buffer.writeInteger(UInt8(body.utf8.count))
        buffer.writeString(body)
        buffer.writeBytes([0, 0, 0])  // chunk end, null indicator, return code

        let context = OracleBackendMessageDecoder.Context(capabilities: Self.smallChunks, columns: .varchar, .long)
        let row = try OracleBackendMessage.RowData.decode(from: &buffer, context: context)
        #expect(buffer.readableBytes == 0)

        var expectedBody = ByteBuffer(integer: Constants.TNS_LONG_LENGTH_INDICATOR)
        expectedBody.writeInteger(UInt32(body.utf8.count))
        expectedBody.writeString(body)
        expectedBody.writeInteger(UInt32(0))
        var expectedName = ByteBuffer(bytes: [7])
        expectedName.writeString("TP_T_BI")
        #expect(row == .init(columns: [.data(expectedName), .data(expectedBody)]))
    }

    @Test func objectImageFromSmallChunksReadsLikeABigOne() throws {
        func image(_ format: CLRChunkFormat) -> ByteBuffer {
            var buffer = ByteBuffer()
            buffer.writeUB4(16)
            buffer.writeOracleCLR(Self.bytes(16), format: format)  // type oid
            buffer.writeUB4(0)  // oid
            buffer.writeUB4(0)  // snapshot
            buffer.writeUB2(1)  // version
            buffer.writeUB4(300)  // data length
            buffer.writeUB2(1)  // flags
            buffer.writeOracleCLR(Self.bytes(300, startingAt: 7), format: format)
            return buffer
        }
        var big = image(.big)
        var small = image(.small)
        let fromBig = try OracleBackendMessage.RowData.decode(from: &big, context: .init(columns: .object))
        let fromSmall = try OracleBackendMessage.RowData.decode(
            from: &small, context: .init(capabilities: Self.smallChunks, columns: .object)
        )
        #expect(small.readableBytes == 0)
        #expect(fromSmall == fromBig)
    }

    @Test func longErrorMessageFrom11gDecodes() throws {
        let message = "ORA-20001: " + String(repeating: "e", count: 400)
        var buffer = ByteBuffer(bytes: [
            0,  // end of call status
            0,  // end to end seq#
            0,  // current row number
            2, 0x4e, 0x21,  // error number 20001
            0, 0,  // array elem error
            0,  // cursor id
            0,  // error position
            0, 0, 0, 0, 0, 0,  // sql type, fatal, flags, cursor options, UDI, warning
            0, 0, 0, 0, 0,  // row id
            0,  // OS error
            0,  // statement number
            0,  // call number
            0,  // padding
            0,  // success iterations
            0,  // oerrdd byte count
            0, 0, 0,  // three empty batch chunks
        ])
        buffer.writeOracleCLR(Array(message.utf8), format: .small)

        var capabilities = Self.smallChunks
        capabilities.ttcFieldVersion = UInt8(Constants.TNS_CCAP_FIELD_VERSION_11_2)
        let error = try BackendError.decode(from: &buffer, context: .init(capabilities: capabilities))
        #expect(error.number == 20001)
        #expect(error.message == message)
        #expect(buffer.readableBytes == 0)
    }

    @Test(arguments: [CLRChunkFormat.small, .big])
    func statementTextGoesInTheServersFormat(format: CLRChunkFormat) {
        let sql = "SELECT 1 FROM dual /* \(String(repeating: "x", count: 400)) */"
        var capabilities = Capabilities()
        capabilities.clrChunkFormat = format
        var encoder = OracleFrontendMessageEncoder(buffer: .init(), capabilities: capabilities)
        let context = StatementContext(statement: OracleStatement(unsafeSQL: sql))
        defer { context.cleanup() }
        encoder.execute(
            statementContext: context, cleanupContext: .init(), describeInfo: nil, cursorID: 0,
            requiresDefine: false, noPrefetch: false
        )
        let message = encoder.flush()

        var expected = ByteBuffer()
        expected.writeOracleCLR(Array(sql.utf8), format: format)
        #expect(Self.contains(message, expected))
    }

    @Test func bindsKeepASmallChunkRowOnlyOnceAValueIsChunked() throws {
        var bindings = OracleBindings()
        bindings.append("short")
        try bindings.append(OracleNumber(7))
        #expect(bindings.smallChunkRow == nil)

        let long = String(repeating: "l", count: 300)
        bindings.append(long)
        bindings.appendNull(.varchar, bindName: "4")

        func row(_ format: CLRChunkFormat) throws -> ByteBuffer {
            let context = OracleEncodingContext(clrChunkFormat: format)
            var buffer = ByteBuffer()
            "short".encode(into: &buffer, context: context)
            try OracleNumber(7)._encodeRaw(into: &buffer, context: context)
            long.encode(into: &buffer, context: context)
            buffer.writeInteger(UInt8(0))
            return buffer
        }
        #expect(bindings.bytes == (try row(.big)))
        let smallRow = try #require(bindings.smallChunkRow)
        #expect(smallRow.bytes == (try row(.small)))
        #expect(smallRow.longBytes.readableBytes == 0)
    }

    @Test func aValueOnlyLongForTheLongSectionKeepsItsPlace() throws {
        var bindings = OracleBindings()
        let longest = String(repeating: "L", count: Int(Constants.TNS_MIN_LONG_LENGTH))
        bindings.append(longest)
        bindings.append("after")
        let smallRow = try #require(bindings.smallChunkRow)

        var expectedLong = ByteBuffer()
        longest.encode(into: &expectedLong, context: OracleEncodingContext(clrChunkFormat: .small))
        var expectedShort = ByteBuffer()
        "after".encode(into: &expectedShort, context: .default)
        #expect(smallRow.longBytes == expectedLong)
        #expect(smallRow.bytes == expectedShort)
        #expect(bindings.bytes == expectedShort)
    }

    @Test(arguments: [CLRChunkFormat.small, .big])
    func bindValuesGoInTheServersFormat(format: CLRChunkFormat) {
        let long = String(repeating: "b", count: 300)
        var capabilities = Capabilities()
        capabilities.clrChunkFormat = format
        var encoder = OracleFrontendMessageEncoder(buffer: .init(), capabilities: capabilities)
        let context = StatementContext(statement: "SELECT \(long) FROM dual")
        defer { context.cleanup() }
        encoder.execute(
            statementContext: context, cleanupContext: .init(), describeInfo: nil, cursorID: 0,
            requiresDefine: false, noPrefetch: false
        )
        let message = encoder.flush()

        var expected = ByteBuffer()
        expected.writeOracleCLR(Array(long.utf8), format: format)
        #expect(Self.contains(message, expected))
    }

    @Test func refWithALongValueDecodesAndBindsInEitherFormat() throws {
        let long = String(repeating: "r", count: 300)
        let ref = OracleRef(long)
        #expect(try ref.decode(as: String.self) == long)

        var bindings = OracleBindings()
        bindings.append(ref, isReturning: false)
        var big = ByteBuffer()
        big.writeOracleCLR(Array(long.utf8), format: .big)
        var small = ByteBuffer()
        small.writeOracleCLR(Array(long.utf8), format: .small)
        #expect(bindings.bytes == big)
        #expect(bindings.smallChunkRow?.bytes == small)
    }

    @Test func refWithAShortValueKeepsNoSmallRow() {
        var bindings = OracleBindings()
        bindings.append(OracleRef("short"), isReturning: false)
        bindings.append(OracleRef(OracleNumber(7)), isReturning: false)
        #expect(bindings.smallChunkRow == nil)
    }

    // A returned value arrives as a row frames it; bound again, it goes in the wire's framing.
    @Test func refThatReceivedALongValueBindsItAgainInEitherFormat() throws {
        let long = String(repeating: "o", count: 300)
        let ref = OracleRef(dataType: .varchar)
        var value = ByteBuffer(string: long)
        var row = ByteBuffer()
        row.writeOracleSlice(&value)
        ref.storage.withLockedValue { $0 = row }
        #expect(try ref.decode(as: String.self) == long)

        var bindings = OracleBindings()
        bindings.append(ref, isReturning: false)
        var big = ByteBuffer()
        big.writeOracleCLR(Array(long.utf8), format: .big)
        var small = ByteBuffer()
        small.writeOracleCLR(Array(long.utf8), format: .small)
        #expect(bindings.bytes == big)
        #expect(bindings.smallChunkRow?.bytes == small)
    }

    @Test func aValueThatDoesNotChunkIsEncodedOnce() {
        let counter = CountingValue(payload: [UInt8](repeating: 0xfe, count: 200))
        var bindings = OracleBindings()
        bindings.append(counter, context: .default, bindName: "1")
        #expect(counter.calls.withLockedValue { $0 } == 1)
        #expect(bindings.smallChunkRow == nil)
    }

    @Test func aThrowingSecondEncodeLeavesTheBindsAsTheyWere() {
        var bindings = OracleBindings()
        bindings.append("kept")
        let before = bindings.bytes
        let failing = FailsOnSecondEncode(payload: [UInt8](repeating: 1, count: 300))
        #expect(throws: FailsOnSecondEncode.Failure.self) {
            try bindings.append(failing, context: .default, bindName: "2")
        }
        #expect(bindings.bytes == before)
        #expect(bindings.count == 1)
        #expect(bindings.smallChunkRow == nil)
    }

    // Measured: Oracle 11.2 refuses a CLOB defined as LONG with ORA-00932, and its server process dies on an empty
    // one defined at the full LONG length.
    @Test(arguments: [OracleDataType.clob, .nCLOB])
    func clobReadAsTextIsDefinedAsLongVarchar(described: OracleDataType) throws {
        var column = DescribeInfo.Column(
            name: "C", dataType: described == .nCLOB ? .longNVarchar : .long, dataTypeSize: 0, precision: 0, scale: 0,
            bufferSize: UInt32.max >> 1, nullsAllowed: true, typeScheme: nil, typeName: nil, domainSchema: nil,
            domainName: nil, annotations: [:], vectorDimensions: nil, vectorFormat: nil
        )
        column.describedDataType = described
        var encoder = OracleFrontendMessageEncoder(buffer: .init(), capabilities: .init())
        let context = StatementContext(statement: "SELECT c FROM t")
        defer { context.cleanup() }
        encoder.execute(
            statementContext: context, cleanupContext: .init(), describeInfo: DescribeInfo(columns: [column]),
            cursorID: 1, requiresDefine: true, noPrefetch: true
        )
        let message = encoder.flush()

        let expected = ByteBuffer(bytes: [
            UInt8(_TNSDataType.lvc.rawValue), Constants.TNS_BIND_USE_INDICATORS, 0, 0, 4, 0x3f, 0xff, 0xff, 0xff,
        ])
        #expect(Self.contains(message, expected))
    }

    @Test func requestLongerThanATwoByteLengthIsSplitIntoPackets() throws {
        let channel = EmbeddedChannel(handler: OracleFrontendMessagePostProcessor())
        let processor = try channel.pipeline.syncOperations.handler(type: OracleFrontendMessagePostProcessor.self)
        processor.protocolVersion = 314
        processor.maxSize = 8_192

        var request = ByteBuffer(repeating: 0, count: OracleFrontendMessageEncoder.headerSize)
        request.writeInteger(UInt16(0))  // data flags
        request.writeBytes(Self.bytes(70_000))
        request.prepareSend(packetType: .data, protocolVersion: 314)
        // The channel handler writes without a promise, which the post processor does not complete.
        channel.writeAndFlush(request, promise: nil)

        var payload = [UInt8]()
        while let packet = try channel.readOutbound(as: ByteBuffer.self) {
            guard packet.readableBytes > 0 else { continue }
            #expect(packet.readableBytes <= 8_192)
            #expect(packet.getInteger(at: 0, as: UInt16.self).map(Int.init) == packet.readableBytes)
            payload += packet.getBytes(at: 10, length: packet.readableBytes - 10) ?? []
        }
        #expect(payload == Self.bytes(70_000))
        _ = try channel.finish()
    }
}

private final class CountingValue: OracleEncodable {
    let payload: [UInt8]
    let calls = NIOLockedValueBox(0)

    init(payload: [UInt8]) {
        self.payload = payload
    }

    static var defaultOracleType: OracleDataType { .raw }

    func encode(into buffer: inout ByteBuffer, context: OracleEncodingContext) {
        self.calls.withLockedValue { $0 += 1 }
        ByteBuffer(bytes: self.payload).encode(into: &buffer, context: context)
    }

    func _encodeRaw(into buffer: inout ByteBuffer, context: OracleEncodingContext) {
        self.encode(into: &buffer, context: context)
    }
}

private final class FailsOnSecondEncode: OracleThrowingEncodable {
    struct Failure: Error {}

    let payload: [UInt8]
    let calls = NIOLockedValueBox(0)

    init(payload: [UInt8]) {
        self.payload = payload
    }

    static var defaultOracleType: OracleDataType { .raw }

    func encode(into buffer: inout ByteBuffer, context: OracleEncodingContext) throws {
        let call = self.calls.withLockedValue { calls in
            calls += 1
            return calls
        }
        guard call == 1 else { throw Failure() }
        ByteBuffer(bytes: self.payload).encode(into: &buffer, context: context)
    }

    func _encodeRaw(into buffer: inout ByteBuffer, context: OracleEncodingContext) throws {
        try self.encode(into: &buffer, context: context)
    }
}
