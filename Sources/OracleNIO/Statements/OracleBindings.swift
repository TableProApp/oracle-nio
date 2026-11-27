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

struct OracleBindingsCollection {
    /// Metadata is shared by all bind rows.
    var metadata: [OracleBindings.Metadata] = []
    var bindings: [Row] = []
    var hasData = false

    struct Row {
        var bytes = ByteBuffer()
        var longBytes = ByteBuffer()
        var smallChunkRow: OracleBindings.SmallChunkRow?
    }

    mutating func appendRow<each Bind: OracleThrowingDynamicTypeEncodable>(
        _ row: repeat (each Bind)?,
        context: OracleEncodingContext
    ) throws {
        var index = 0
        var bindings = Row()
        repeat try appendBind(each row, context: context, into: &bindings, index: &index)
        if !hasData { hasData = bindings.bytes.readableBytes > 0 || bindings.longBytes.readableBytes > 0 }
        self.bindings.append(bindings)
    }

    mutating func appendRow(_ row: OracleBindings) throws {
        for (index, column) in row.metadata.enumerated() {
            if metadata.count <= index {
                metadata.append(column)
            } else {
                let currentMetadata = metadata[index]
                if column.size > currentMetadata.size || column.bufferSize > currentMetadata.bufferSize {
                    metadata[index] = column
                }
            }
        }
        if !hasData { hasData = row.bytes.readableBytes > 0 || row.longBytes.readableBytes > 0 }
        self.bindings.append(Row(bytes: row.bytes, longBytes: row.longBytes, smallChunkRow: row.smallChunkRow))
    }

    private mutating func appendBind<T: OracleThrowingDynamicTypeEncodable>(
        _ bind: T?,
        context: OracleEncodingContext,
        into buffers: inout Row,
        index: inout Int
    ) throws {
        let newMetadata =
            if let bind {
                OracleBindings.Metadata(
                    value: bind,
                    protected: true,
                    bindName: "\(index)"
                )
            } else {
                OracleBindings.Metadata(
                    dataType: T.defaultOracleType,
                    protected: false,
                    size: 1,
                    isArray: false,
                    arrayCount: nil,
                    maxArraySize: nil,
                    bindName: "\(index)"
                )
            }
        if let bind {
            try OracleBindings.appendEncoded(
                to: &buffers.bytes, &buffers.longBytes, &buffers.smallChunkRow,
                long: newMetadata.bufferSize >= Constants.TNS_MIN_LONG_LENGTH, context: context
            ) { try bind._encodeRaw(into: &$0, context: $1) }
        } else {
            let start = buffers.bytes.writerIndex
            OracleBindings.writeNull(T.defaultOracleType, into: &buffers.bytes)
            OracleBindings.mirror(
                into: &buffers.smallChunkRow, bytes: buffers.bytes, longBytes: buffers.longBytes,
                long: false, start: start, small: nil
            )
        }
        if metadata.count <= index {
            metadata.append(newMetadata)
        } else {
            let currentMetadata = metadata[index]
            if newMetadata.size > currentMetadata.size || newMetadata.bufferSize > currentMetadata.bufferSize {
                metadata[index] = newMetadata
            }
        }
        index += 1
    }
}

public struct OracleBindings: Sendable, Hashable {
    @usableFromInline
    struct Metadata: Sendable, Hashable {
        @usableFromInline
        var dataType: OracleDataType
        @usableFromInline
        var protected: Bool
        @usableFromInline
        var size: UInt32
        @usableFromInline
        var bufferSize: UInt32

        @usableFromInline
        var isArray: Bool
        @usableFromInline
        var arrayCount: Int
        @usableFromInline
        var maxArraySize: Int

        @usableFromInline
        var bindName: String?
        @usableFromInline
        var outContainer: OracleRef?  // reference type for return binds

        @inlinable
        init(
            dataType: OracleDataType,
            protected: Bool,
            size: UInt32 = 0,
            isArray: Bool,
            arrayCount: Int?,
            maxArraySize: Int?,
            bindName: String?
        ) {
            self.dataType = dataType
            self.protected = protected
            let size =
                if size == 0 {
                    UInt32(self.dataType.defaultSize)
                } else {
                    size
                }
            self.size = size
            if dataType.defaultSize > 0 {
                self.bufferSize = size * UInt32(dataType.bufferSizeFactor)
            } else {
                self.bufferSize = UInt32(dataType.bufferSizeFactor)
            }
            self.isArray = isArray
            self.arrayCount = arrayCount ?? 0
            self.maxArraySize = maxArraySize ?? 0
            self.bindName = bindName
        }

        @inlinable
        init<Value: OracleThrowingDynamicTypeEncodable>(
            value: Value,
            protected: Bool,
            bindName: String?
        ) {
            self.init(
                dataType: value.oracleType,
                protected: protected,
                size: value.size,
                isArray: Value.isArray,
                arrayCount: value.arrayCount,
                maxArraySize: value.arraySize,
                bindName: bindName
            )
        }
    }

    @usableFromInline
    var metadata: [Metadata]
    @usableFromInline
    var bytes: ByteBuffer
    /// LONG binds need to be sent at last, so they require their own buffer.
    /// In the end ``bytes`` + ``longBytes`` will be written to the wire.
    @usableFromInline
    var longBytes: ByteBuffer
    // The same binds for a server that reads one-byte chunk lengths, kept once a value is framed differently there.
    @usableFromInline
    var smallChunkRow: SmallChunkRow?

    public var count: Int {
        self.metadata.count
    }

    public init() {
        self.metadata = []
        self.bytes = ByteBuffer()
        self.longBytes = ByteBuffer()
    }

    public init(capacity: Int) {
        self.metadata = []
        self.metadata.reserveCapacity(capacity)
        self.bytes = ByteBuffer()
        self.bytes.reserveCapacity(128 * capacity)
        self.longBytes = ByteBuffer()  // no capacity as it is rare
    }

    public mutating func appendNull(
        _ dataType: OracleDataType?, bindName: String
    ) {
        let dataType = dataType ?? .varchar
        let start = self.bytes.writerIndex
        Self.writeNull(dataType, into: &self.bytes)
        Self.mirror(
            into: &self.smallChunkRow, bytes: self.bytes, longBytes: self.longBytes,
            long: false, start: start, small: nil
        )
        self.metadata.append(
            .init(
                dataType: dataType,
                protected: false,
                size: 1,
                isArray: false,
                arrayCount: nil,
                maxArraySize: nil,
                bindName: bindName
            ))
    }

    public mutating func appendNull() {
        self.appendNull(.varchar, bindName: "\(count + 1)")
    }

    @inlinable
    public mutating func append<Value: OracleThrowingDynamicTypeEncodable>(
        _ value: Value, context: OracleEncodingContext, bindName: String
    ) throws {
        let metadata = Metadata(
            value: value,
            protected: true,
            bindName: bindName
        )
        try Self.appendEncoded(
            to: &self.bytes, &self.longBytes, &self.smallChunkRow,
            long: metadata.bufferSize >= Constants.TNS_MIN_LONG_LENGTH, context: context
        ) { try value._encodeRaw(into: &$0, context: $1) }
        self.metadata.append(metadata)
    }

    @inlinable
    public mutating func append(_ value: some OracleThrowingDynamicTypeEncodable) throws {
        try self.append(value, context: .default, bindName: "\(count + 1)")
    }

    @inlinable
    public mutating func append<Value: OracleDynamicTypeEncodable>(
        _ value: Value,
        context: OracleEncodingContext,
        bindName: String
    ) {
        let metadata = Metadata(
            value: value,
            protected: true,
            bindName: bindName
        )
        Self.appendEncoded(
            to: &self.bytes, &self.longBytes, &self.smallChunkRow,
            long: metadata.bufferSize >= Constants.TNS_MIN_LONG_LENGTH, context: context
        ) { value._encodeRaw(into: &$0, context: $1) }
        self.metadata.append(metadata)
    }

    @inlinable
    public mutating func append(_ value: some OracleDynamicTypeEncodable) {
        self.append(value, context: .default, bindName: "\(count + 1)")
    }

    @inlinable
    public mutating func append<Value: OracleRef>(
        _ value: Value, bindName: String, isReturning: Bool
    ) {
        value.metadata.withLockedValue { valueMetadata in
            valueMetadata.bindName = bindName
            var metadata = valueMetadata
            metadata.bindName = bindName
            metadata.outContainer = value
            value.storage.withLockedValue { valueStorage in
                let long = valueStorage != nil && metadata.bufferSize >= Constants.TNS_MIN_LONG_LENGTH
                let start = long ? self.longBytes.writerIndex : self.bytes.writerIndex
                if var bytes = valueStorage {
                    if long {
                        self.longBytes.writeBuffer(&bytes)
                    } else {
                        self.bytes.writeBuffer(&bytes)
                    }
                } else if !isReturning {  // return binds do not send null
                    self.bytes.writeInteger(UInt8(0))  // null
                }
                Self.mirror(
                    into: &self.smallChunkRow, bytes: self.bytes, longBytes: self.longBytes,
                    long: long, start: start, small: value.smallChunkStorage.withLockedValue { $0 }
                )
            }
            self.metadata.append(metadata)
        }
    }

    @inlinable
    public mutating func append(_ value: some OracleRef, isReturning: Bool) {
        if let name = contains(ref: value) {
            self.append(value, bindName: name, isReturning: isReturning)
        } else {
            self.append(value, bindName: "\(count + 1)", isReturning: isReturning)
        }
    }

    @inlinable
    mutating func appendUnprotected<Value: OracleThrowingDynamicTypeEncodable>(
        _ value: Value,
        context: OracleEncodingContext,
        bindName: String
    ) throws {
        let metadata = Metadata(
            value: value,
            protected: false,
            bindName: bindName
        )
        try Self.appendEncoded(
            to: &self.bytes, &self.longBytes, &self.smallChunkRow,
            long: metadata.bufferSize >= Constants.TNS_MIN_LONG_LENGTH, context: context
        ) { try value._encodeRaw(into: &$0, context: $1) }
        self.metadata.append(metadata)
    }

    @inlinable
    mutating func appendUnprotected<Value: OracleDynamicTypeEncodable>(
        _ value: Value,
        context: OracleEncodingContext,
        bindName: String
    ) {
        let metadata = Metadata(
            value: value,
            protected: false,
            bindName: bindName
        )
        Self.appendEncoded(
            to: &self.bytes, &self.longBytes, &self.smallChunkRow,
            long: metadata.bufferSize >= Constants.TNS_MIN_LONG_LENGTH, context: context
        ) { value._encodeRaw(into: &$0, context: $1) }
        self.metadata.append(metadata)
    }

    /// Checks if a INOUT bind is already present and returns its bind name to be reused.
    ///
    /// This ensures that we don't shadow those binds on the db side and potentially returning incorrect
    /// results in the out bind.
    ///
    /// You might wonder why we don't use the metadata on `OracleRef` itself.
    /// This is because we cannot know if the metadata is from a previous statement or not.
    @usableFromInline
    func contains(ref: OracleRef) -> String? {
        self.metadata.first(where: { $0.outContainer === ref })?.bindName
    }
}

extension OracleBindings {
    @usableFromInline
    struct SmallChunkRow: Sendable, Hashable {
        @usableFromInline
        var bytes: ByteBuffer
        @usableFromInline
        var longBytes: ByteBuffer

        @inlinable
        init(bytes: ByteBuffer, longBytes: ByteBuffer) {
            self.bytes = bytes
            self.longBytes = longBytes
        }
    }

    @inlinable
    static func appendEncoded(
        to bytes: inout ByteBuffer,
        _ longBytes: inout ByteBuffer,
        _ smallChunkRow: inout SmallChunkRow?,
        long: Bool,
        context: OracleEncodingContext,
        _ encode: (inout ByteBuffer, OracleEncodingContext) throws -> Void
    ) rethrows {
        let start = long ? longBytes.writerIndex : bytes.writerIndex
        if long {
            try encode(&longBytes, context)
        } else {
            try encode(&bytes, context)
        }
        let written = long ? longBytes : bytes
        let small = try Self.smallChunkEncoding(
            of: written.getSlice(at: start, length: written.writerIndex - start)!, context: context, encode
        )
        Self.mirror(into: &smallChunkRow, bytes: bytes, longBytes: longBytes, long: long, start: start, small: small)
    }

    // Only a chunked value differs between the formats, and it always holds TNS_LONG_LENGTH_INDICATOR.
    @inlinable
    static func smallChunkEncoding(
        of encoded: ByteBuffer,
        context: OracleEncodingContext,
        _ encode: (inout ByteBuffer, OracleEncodingContext) throws -> Void
    ) rethrows -> ByteBuffer? {
        guard encoded.readableBytesView.contains(Constants.TNS_LONG_LENGTH_INDICATOR) else { return nil }
        var smallContext = context
        smallContext.clrChunkFormat = .small
        var small = ByteBuffer()
        try encode(&small, smallContext)
        return small == encoded ? nil : small
    }

    // Copies the value written at `start` into the small row, or its `small` framing, and starts the row from what
    // came before once a value differs.
    @inlinable
    static func mirror(
        into smallChunkRow: inout SmallChunkRow?,
        bytes: ByteBuffer,
        longBytes: ByteBuffer,
        long: Bool,
        start: Int,
        small: ByteBuffer?
    ) {
        let written = long ? longBytes : bytes
        if smallChunkRow == nil {
            guard small != nil else { return }
            smallChunkRow = SmallChunkRow(
                bytes: long ? bytes : bytes.getSlice(at: bytes.readerIndex, length: start - bytes.readerIndex)!,
                longBytes: long
                    ? longBytes.getSlice(at: longBytes.readerIndex, length: start - longBytes.readerIndex)!
                    : longBytes
            )
        }
        var value = small ?? written.getSlice(at: start, length: written.writerIndex - start)!
        if long {
            smallChunkRow!.longBytes.writeBuffer(&value)
        } else {
            smallChunkRow!.bytes.writeBuffer(&value)
        }
    }

    static func writeNull(_ dataType: OracleDataType, into bytes: inout ByteBuffer) {
        if dataType == .boolean {
            bytes.writeInteger(Constants.TNS_ESCAPE_CHAR)
            bytes.writeInteger(UInt8(1))
        } else if dataType._oracleType == .intNamed {
            bytes.writeUB4(0)  // TOID
            bytes.writeUB4(0)  // OID
            bytes.writeUB4(0)  // snapshot
            bytes.writeUB4(0)  // version
            bytes.writeUB4(0)  // packed data length
            bytes.writeUB4(Constants.TNS_OBJ_TOP_LEVEL)  // flags
        } else {
            bytes.writeInteger(UInt8(0))
        }
    }
}

extension OracleBindings:
    CustomStringConvertible, CustomDebugStringConvertible
{
    public var description: String {
        """
        [
        \(zip(self.metadata, BindingsReader(buffer: self.bytes))
            .lazy
            .map({
                Self.makeBindingPrintable(
                    protected: $0.protected,
                    type: $0.dataType,
                    buffer: $1
                )
            })
            .joined(separator: ", "))
        ]
        """
    }

    public var debugDescription: String {
        """
        [
        \(zip(self.metadata, BindingsReader(buffer: self.bytes))
                .lazy
                .map({
                    Self.makeDebugDescription(
                        protected: $0.protected,
                        type: $0.dataType,
                        buffer: $1
                    )
                })
                .joined(separator: ", "))
        ]
        """
    }

    private static func makeDebugDescription(
        protected: Bool, type: OracleDataType, buffer: ByteBuffer?
    ) -> String {
        "(\(Self.makeBindingPrintable(protected: protected, type: type, buffer: buffer)); \(type))"
    }

    private static func makeBindingPrintable(
        protected: Bool, type: OracleDataType, buffer: ByteBuffer?
    ) -> String {
        if protected {
            return "****"
        }

        guard var buffer else {
            return "null"
        }

        do {
            switch type {
            case .binaryInteger, .number:
                let number = try Int64(
                    from: &buffer, type: type, context: .default
                )
                return String(describing: number)
            case .boolean:
                let bool = try Bool(
                    from: &buffer, type: type, context: .default
                )
                return String(describing: bool)
            case .varchar, .char, .long, .rowID:
                let value = try String(
                    from: &buffer, type: type, context: .default
                )
                return String(reflecting: value)  // adds quotes
            default:
                return "\(buffer.readableBytes) bytes"
            }
        } catch {
            return "\(buffer.readableBytes) bytes"
        }
    }
}

/// A small helper to inspect encoded bindings
private struct BindingsReader: Sequence {
    typealias Element = ByteBuffer?

    var buffer: ByteBuffer

    struct Iterator: IteratorProtocol {
        typealias Element = ByteBuffer?
        private var buffer: ByteBuffer

        init(buffer: ByteBuffer) {
            self.buffer = buffer
        }

        mutating func next() -> ByteBuffer?? {
            return self.buffer.readOracleSpecificLengthPrefixedSlice(chunks: .big)
        }
    }

    func makeIterator() -> Iterator {
        Iterator(buffer: self.buffer)
    }
}
