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

extension OracleBackendMessage {
    struct RowData: PayloadDecodable, Sendable, Hashable {
        var columns: [ColumnStorage]

        enum ColumnStorage: Sendable, Hashable {
            case data(ByteBuffer)
            case duplicate(Int)
        }

        static func decode(
            from buffer: inout ByteBuffer,
            context: OracleBackendMessageDecoder.Context
        ) throws -> RowData {
            guard let statementContext = context.statementContext else {
                throw OraclePartialDecodingError.fieldNotDecodable(type: StatementContext.self)
            }

            let describeInfo =
                switch context.statementContext?.type {
                case .cursor(let describeInfo, _, _):
                    describeInfo
                default:
                    context.describeInfo
                }

            let columns: [ColumnStorage]
            if let describeInfo {
                columns = try self.processRowData(
                    from: &buffer,
                    describeInfo: describeInfo,
                    context: context
                )
            } else {
                columns = try self.processBindRow(
                    from: &buffer,
                    statementContext: statementContext,
                    capabilities: context.capabilities
                )
            }

            return .init(columns: columns)
        }

        private static func isDuplicateData(
            columnNumber: UInt32, bitVector: [UInt8]?
        ) throws -> Bool {
            guard let bitVector else { return false }
            let byteNumber = Int(columnNumber / 8)
            let bitNumber = columnNumber % 8
            guard byteNumber < bitVector.count else {
                throw OraclePartialDecodingError.fieldNotDecodable(type: [UInt8].self)
            }
            return bitVector[byteNumber] & (1 << bitNumber) == 0
        }

        private static func processRowData(
            from buffer: inout ByteBuffer,
            describeInfo: DescribeInfo,
            context: OracleBackendMessageDecoder.Context
        ) throws -> [ColumnStorage] {
            var columns = [ColumnStorage]()
            columns.reserveCapacity(describeInfo.columns.count)
            for (index, column) in describeInfo.columns.enumerated() {
                if try self.isDuplicateData(
                    columnNumber: UInt32(index),
                    bitVector: context.bitVector
                ) {
                    columns.append(.duplicate(index))
                } else {
                    let data = try self.processColumnData(
                        from: &buffer,
                        oracleType: column.dataType._oracleType,
                        csfrm: column.dataType.csfrm,
                        bufferSize: column.bufferSize,
                        forBind: false,
                        capabilities: context.capabilities
                    )
                    columns.append(.data(data))
                }
            }

            // reset bit vector after usage
            context.bitVector = nil
            return columns
        }

        private static func processColumnData(
            from buffer: inout ByteBuffer,
            oracleType: _TNSDataType?,
            csfrm: UInt8,
            bufferSize: UInt32,
            forBind: Bool,
            capabilities: Capabilities
        ) throws -> ByteBuffer {
            var columnValue: ByteBuffer
            if bufferSize == 0 && ![.long, .longRAW, .uRowID].contains(oracleType) {
                columnValue = ByteBuffer(bytes: [0])  // NULL indicator
                return columnValue
            }

            switch oracleType {
            // Measured on Oracle 23ai: a REF arrives as one length-prefixed slice, like RAW.
            case .varchar, .char, .long, .raw, .longRAW, .number, .date, .timestamp,
                .timestampLTZ, .timestampTZ, .binaryDouble, .binaryFloat,
                .binaryInteger, .boolean, .intervalDS, .intervalYM, .intRef:
                switch buffer.readOracleSlice() {
                case .some(let slice):
                    columnValue = slice
                case .none:
                    throw MissingDataDecodingError.Trigger()
                }
            case .rowID:
                if forBind {
                    let value = try buffer.readString()
                    let rowID = RowID(value)
                    columnValue = ByteBuffer()
                    try columnValue.writeLengthPrefixed(as: UInt8.self) {
                        $0.writeString(rowID.description)
                    }
                } else {
                    // length is not the actual length of row ids
                    let length = try buffer.throwingReadInteger(as: UInt8.self)
                    if length == 0 || length == Constants.TNS_NULL_LENGTH_INDICATOR {
                        columnValue = ByteBuffer(bytes: [0])  // NULL indicator
                    } else {
                        columnValue = ByteBuffer()
                        if let rowID = try RowID(fromWire: &buffer) {
                            try columnValue.writeLengthPrefixed(as: UInt8.self) {
                                $0.writeString(rowID.description)
                            }
                        } else {
                            columnValue = ByteBuffer(bytes: [0])  // NULL indicator
                        }
                    }
                }
            case .cursor:
                try buffer.throwingMoveReaderIndex(forwardBy: 1)  // length (fixed value)

                let readerIndex = buffer.readerIndex
                _ = try DescribeInfo._decode(
                    from: &buffer, context: .init(capabilities: capabilities)
                )
                try buffer.throwingSkipUB2()  // cursor id
                let length = buffer.readerIndex - readerIndex
                buffer.moveReaderIndex(to: readerIndex)
                columnValue = ByteBuffer(integer: Constants.TNS_LONG_LENGTH_INDICATOR)
                try columnValue.writeLengthPrefixed(as: UInt32.self) { base in
                    let start = base.writerIndex
                    try capabilities.encode(into: &base)
                    guard let cursorSlice = buffer.readSlice(length: length) else {
                        throw OraclePartialDecodingError.expectedAtLeastNRemainingBytes(
                            length, actual: buffer.readableBytes
                        )
                    }
                    base.writeImmutableBuffer(cursorSlice)
                    return base.writerIndex - start
                }
                columnValue.writeInteger(0, as: UInt32.self)  // chunk length of zero
            case .bfile:
                // A BFILE carries only its locator, with no size or chunk size before it. Skipping
                // the locator and writing NULL made every BFILE read as NULL.
                let length = try buffer.throwingReadUB4()
                if length > 0 {
                    switch buffer.readOracleSlice() {
                    case .some(let locator):
                        columnValue = locator
                    case .none:
                        throw MissingDataDecodingError.Trigger()
                    }
                } else {
                    columnValue = .init(bytes: [0])  // NULL indicator
                }
            case .clob, .blob:

                // LOB has a UB4 length indicator instead of the usual UInt8
                let length = try buffer.throwingReadUB4()
                if length > 0 {
                    let size = try buffer.throwingReadUB8()
                    let chunkSize = try buffer.throwingReadUB4()
                    var locator: ByteBuffer
                    switch buffer.readOracleSlice() {
                    case .some(let slice):
                        locator = slice
                    case .none:
                        throw MissingDataDecodingError.Trigger()
                    }
                    columnValue = ByteBuffer()
                    try columnValue.writeLengthPrefixed(as: UInt8.self) {
                        $0.writeInteger(size) + $0.writeInteger(chunkSize)
                            + $0.writeBuffer(&locator)
                    }
                } else {
                    columnValue = .init(bytes: [0])  // empty buffer
                }
            case .json:
                switch try buffer.throwingReadOSON() {
                case .some(let slice):
                    columnValue = slice
                case .none:
                    throw MissingDataDecodingError.Trigger()
                }
            case .vector:
                let length = try buffer.throwingReadUB4()
                if length > 0 {
                    try buffer.throwingSkipUB8()  // size (unused)
                    try buffer.throwingSkipUB4()  // chunk size (unused)
                    switch buffer.readOracleSlice() {
                    case .some(let slice):
                        columnValue = slice
                    case .none:
                        throw MissingDataDecodingError.Trigger()
                    }
                    try buffer.throwingSkipRawBytesChunked()  // LOB locator (unused)
                } else {
                    columnValue = .init(bytes: [0])  // empty buffer
                }
            case .intNamed:
                let startIndex = buffer.readerIndex
                if try buffer.throwingReadUB4() > 0 {
                    try buffer.throwingSkipRawBytesChunked()  // type oid
                }
                if try buffer.throwingReadUB4() > 0 {
                    try buffer.throwingSkipRawBytesChunked()  // oid
                }
                if try buffer.throwingReadUB4() > 0 {
                    try buffer.throwingSkipRawBytesChunked()  // snapshot
                }
                try buffer.throwingSkipUB2()  // version
                let dataLength = try buffer.throwingReadUB4()
                try buffer.throwingSkipUB2()  // flags
                guard dataLength > 0 else {
                    // A NULL object still carries its type OID, version and flags.
                    columnValue = ByteBuffer(bytes: [0])  // NULL indicator
                    break
                }
                try buffer.throwingSkipRawBytesChunked()  // data
                let endIndex = buffer.readerIndex
                buffer.moveReaderIndex(to: startIndex)
                columnValue = ByteBuffer(integer: Constants.TNS_LONG_LENGTH_INDICATOR)
                let length = (endIndex - startIndex) + (MemoryLayout<UInt32>.size * 2)
                columnValue.reserveCapacity(minimumWritableBytes: length)
                try columnValue.writeLengthPrefixed(as: UInt32.self) {
                    guard let namedSlice = buffer.readSlice(length: endIndex - startIndex) else {
                        throw OraclePartialDecodingError.expectedAtLeastNRemainingBytes(
                            endIndex - startIndex, actual: buffer.readableBytes
                        )
                    }
                    return $0.writeImmutableBuffer(namedSlice)
                }
                columnValue.writeInteger(0, as: UInt32.self)  // chunk length of zero
            case .uRowID:
                if forBind {
                    columnValue = Self.columnValue(text: try buffer.readString())
                } else {
                    // Measured on Oracle 23ai: a one-byte slice holding the length of the slice that
                    // follows, which carries the rowid. A NULL is the first slice alone, empty.
                    let lengthSlice = try buffer.throwingReadOracleSpecificLengthPrefixedSlice()
                    if lengthSlice.readableBytes == 0 {
                        columnValue = ByteBuffer(bytes: [0])  // NULL indicator
                    } else {
                        let rowID = try RowID(universal: buffer.throwingReadOracleSpecificLengthPrefixedSlice())
                        columnValue = Self.columnValue(text: rowID.description)
                    }
                }
            default:
                throw OraclePartialDecodingError.unsupportedDataType(
                    type: oracleType ?? .undefined
                )
            }

            // Only a fetched LONG carries this trailer; an OUT bind is followed by its actual byte count.
            if !forBind, [.long, .longRAW].contains(oracleType) {
                try buffer.throwingSkipSB4()  // null indicator
                try buffer.throwingSkipUB4()  // return code
            }

            if csfrm == Constants.TNS_CS_NCHAR, [.varchar, .char, .long].contains(oracleType) {
                columnValue = try capabilities.nationalCharacterValue(columnValue)
            }

            return columnValue
        }

        /// A value in the row's own framing: a length byte, or chunks once it is too long for one.
        private static func columnValue(text: String) -> ByteBuffer {
            let bytes = Array(text.utf8)
            var value = ByteBuffer()
            if bytes.count <= Constants.TNS_MAX_SHORT_LENGTH {
                value.writeInteger(UInt8(bytes.count))
                value.writeBytes(bytes)
            } else {
                value.writeInteger(Constants.TNS_LONG_LENGTH_INDICATOR)
                value.writeInteger(UInt32(bytes.count))
                value.writeBytes(bytes)
                value.writeInteger(UInt32(0))  // chunk length of zero
            }
            return value
        }

        private static func processBindRow(
            from buffer: inout ByteBuffer,
            statementContext: StatementContext,
            capabilities: Capabilities
        ) throws -> [ColumnStorage] {
            let outBinds = statementContext.binds.metadata.compactMap(\.outContainer)
            guard !outBinds.isEmpty else {
                throw OraclePartialDecodingError.fieldNotDecodable(type: RowData.self)
            }
            var columns: [ColumnStorage] = []
            if statementContext.isReturning {
                for outBind in outBinds {
                    let rowCount = try buffer.throwingReadUB4()
                    if rowCount > 0 {
                        for _ in 0..<rowCount {
                            columns.append(
                                .data(
                                    try self.processBindData(
                                        from: &buffer,
                                        metadata: outBind.metadata.withLockedValue({ $0 }),
                                        capabilities: capabilities
                                    )))
                        }
                    } else {
                        // empty buffer
                        columns.append(.data(ByteBuffer(bytes: [0])))
                    }
                }
            } else {
                for outBind in outBinds {
                    columns.append(
                        .data(
                            try self.processBindData(
                                from: &buffer,
                                metadata: outBind.metadata.withLockedValue({ $0 }),
                                capabilities: capabilities
                            )))
                }
            }
            return columns
        }

        private static func processBindData(
            from buffer: inout ByteBuffer,
            metadata: OracleBindings.Metadata,
            capabilities: Capabilities
        ) throws -> ByteBuffer {
            let columnData = try self.processColumnData(
                from: &buffer,
                oracleType: metadata.dataType._oracleType,
                csfrm: metadata.dataType.csfrm,
                bufferSize: metadata.bufferSize,
                forBind: true,
                capabilities: capabilities
            )

            let actualBytesCount = try buffer.throwingReadSB4()
            if actualBytesCount < 0 && metadata.dataType._oracleType == .boolean {
                return ByteBuffer(bytes: [0])  // empty buffer
            } else if actualBytesCount != 0 && !columnData.oracleColumnIsEmpty {
                throw OraclePartialDecodingError.columnTruncated(
                    length: Int(actualBytesCount)
                )
            }

            return columnData
        }
    }
}
