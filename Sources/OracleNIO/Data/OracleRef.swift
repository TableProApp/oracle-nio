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

/// A reference type used to capture `OUT` and `IN/OUT` binds in `DML` returning statements or
/// `PL/SQL`.
///
/// - Note: `OracleRef`s used as `IN/OUT` binds without a value will be declared
///         as `NULL` in `PL/SQL`.
///
/// Here is an example showing how to use `OUT` binds in a `RETURNING` clause:
///
/// ```swift
/// let ref = OracleRef(dataType: .number, isReturnBind: true)
/// try await connection.execute(
///     "INSERT INTO table(id) VALUES (1) RETURNING id INTO \(ref)",
///     logger: logger
/// )
/// let id = try ref.decode(as: Int.self) // 1
/// ```
///
/// Here is an example showing how to use `OUT` binds in `PL/SQL`:
///
/// ```swift
/// let ref = OracleRef(dataType: .number)
/// try await conn.execute("""
///     begin
///         \(ref) := \(OracleNumber(8)) + \(OracleNumber(7));
///     end;
///     """, logger: logger)
/// let result = try ref.decode(as: Int.self) // 15
/// ```
///
/// Here is an example showing how to use `IN/OUT` binds in `PL/SQL`
///
/// ```swift
/// let ref = OracleRef(OracleNumber(25))
/// try await conn.execute("""
///     begin
///     \(ref) := \(ref) + \(OracleNumber(8)) + \(OracleNumber(7));
///     end;
///     """, logger: .oracleTest)
/// let result = try ref.decode(as: Int.self) // 40
/// ```
///
public final class OracleRef: Sendable, Hashable {
    @inlinable
    public static func == (lhs: OracleRef, rhs: OracleRef) -> Bool {
        lhs.storage.withLockedValue { lhs in
            rhs.storage.withLockedValue { rhs in
                lhs == rhs
            }
        }
    }

    @inlinable
    public func hash(into hasher: inout Hasher) {
        self.storage.withLockedValue { hasher.combine($0) }
    }

    @usableFromInline
    internal let storage: NIOLockedValueBox<ByteBuffer?>
    @usableFromInline
    internal let metadata: NIOLockedValueBox<OracleBindings.Metadata>

    /// Use this initializer to create an OUT bind.
    ///
    /// Please be aware that you still have to decode the database response into the Swift type you want
    /// after completing the statement (using ``decode(of:)``).
    ///
    /// - Parameter dataType: The desired datatype within the Oracle database.
    @inlinable
    public init(dataType: OracleDataType) {
        self.storage = NIOLockedValueBox(nil)
        self.metadata = NIOLockedValueBox(
            .init(
                dataType: dataType,
                protected: false,
                isArray: false,
                arrayCount: nil,
                maxArraySize: nil,
                bindName: nil
            ))
    }

    /// Use this initializer to create an IN/OUT bind.
    /// - Parameter value: The initial value of the bind.
    @inlinable
    public init<V: OracleThrowingDynamicTypeEncodable>(_ value: V) throws {
        var storage = ByteBuffer()
        try value._encodeRaw(into: &storage, context: .default)
        self.storage = NIOLockedValueBox(Self.rowFraming(of: storage, type: value.oracleType))
        self.metadata = NIOLockedValueBox(.init(value: value, protected: true, bindName: nil))
    }

    /// Use this initializer to create a IN/OUT bind.
    /// - Parameter value: The initial value of the bind.
    @inlinable
    public init<V: OracleEncodable>(_ value: V) {
        var storage = ByteBuffer()
        value._encodeRaw(into: &storage, context: .default)
        self.storage = NIOLockedValueBox(Self.rowFraming(of: storage, type: value.oracleType))
        self.metadata = NIOLockedValueBox(.init(value: value, protected: true, bindName: nil))
    }

    /// Decodes a value of the given type from the bind.
    ///
    /// This method uses the ``OracleDecodable/init(from:type:context:)`` to decode
    /// the value internally.
    ///
    /// - Parameter as: The type of the returned value.
    /// - Returns: A value of the specified type.
    @inlinable
    public func decode<V: OracleDecodable>(as: V.Type = V.self) throws -> V {
        var buffer: ByteBuffer?
        self.readStorage(&buffer)
        return try self.metadata.withLockedValue { metadata in
            try V._decodeRaw(
                from: &buffer, type: metadata.dataType, context: .default
            )
        }
    }

    /// Decodes a value of the given type from the bind.
    ///
    /// This method uses the ``OracleNonCopyableDecodable/init(from:type:context:)`` to decode
    /// the value internally.
    ///
    /// - Parameter as: The type of the returned value.
    /// - Returns: A value of the specified type.
    @inlinable
    public func decode<V: OracleNonCopyableDecodable & ~Copyable>(as: V.Type = V.self) throws -> V {
        var buffer: ByteBuffer?
        self.readStorage(&buffer)
        let dataType = self.metadata.withLockedValue { metadata in metadata.dataType }
        return try V._decodeRaw(from: &buffer, type: dataType, context: .default)
    }

    @inlinable
    func readStorage(_ buffer: inout ByteBuffer?) {
        self.storage.withLockedValue { storage in
            let length = Int(storage?.getInteger(at: 0, as: UInt8.self) ?? 0)

            if length == Constants.TNS_LONG_LENGTH_INDICATOR {
                buffer = ByteBuffer()
                var position = MemoryLayout<UInt8>.size
                while true {
                    let chunkLength =
                        Int(storage!.getInteger(at: position, as: UInt32.self)!)
                    position += MemoryLayout<UInt32>.size
                    if chunkLength == 0 { break }
                    var temp = storage!.getSlice(
                        at: position, length: chunkLength
                    )!
                    position += chunkLength
                    buffer?.writeBuffer(&temp)
                }
            } else if length != 0 && length != Constants.TNS_NULL_LENGTH_INDICATOR {
                buffer = storage!.getSlice(
                    at: MemoryLayout<UInt8>.size, length: length
                )!
            }
        }
    }
}

// `storage` holds a value as a row frames it, which is what a returned value arrives as and what `decode` reads. A
// chunked value is framed differently on the wire, so a bind derives the wire's framing from it.
extension OracleRef {
    @usableFromInline
    static let singleValueTypes: Set<_TNSDataType> = [.varchar, .char, .long, .raw, .longRAW]

    @usableFromInline
    static func rowFraming(of wire: ByteBuffer, type: OracleDataType) -> ByteBuffer {
        guard let oracleType = type._oracleType, Self.singleValueTypes.contains(oracleType),
            wire.getInteger(at: wire.readerIndex, as: UInt8.self) == Constants.TNS_LONG_LENGTH_INDICATOR
        else { return wire }
        var remaining = wire
        guard var value = try? remaining.throwingReadOracleSpecificLengthPrefixedSlice(chunks: .big),
            remaining.readableBytes == 0
        else { return wire }
        var row = ByteBuffer()
        row.writeOracleSlice(&value)
        return row
    }

    @usableFromInline
    static func wireFraming(of row: ByteBuffer, type: OracleDataType, format: CLRChunkFormat) -> ByteBuffer {
        guard let oracleType = type._oracleType, Self.singleValueTypes.contains(oracleType),
            row.getInteger(at: row.readerIndex, as: UInt8.self) == Constants.TNS_LONG_LENGTH_INDICATOR,
            let value = DataRow(columnCount: 1, bytes: row)[column: 0]
        else { return row }
        var wire = ByteBuffer()
        wire.writeOracleCLR(value.readableBytesView, format: format)
        return wire
    }
}
