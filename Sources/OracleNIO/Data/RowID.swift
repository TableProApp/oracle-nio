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

public struct RowID: CustomStringConvertible, Sendable, Equatable, Hashable {
    public let description: String

    init(_ value: String) {
        self.description = value
    }

    init?(
        rba: UInt32,
        partitionID: UInt16,
        blockNumber: UInt32,
        slotNumber: UInt16
    ) {
        guard
            let value = Self.makeDescription(
                rba: rba,
                partitionID: partitionID,
                blockNumber: blockNumber,
                slotNumber: slotNumber
            )
        else { return nil }
        self.description = value
    }

    private static func makeDescription(
        rba: UInt32,
        partitionID: UInt16,
        blockNumber: UInt32,
        slotNumber: UInt16
    ) -> String? {
        if rba != 0 || partitionID != 0 || blockNumber != 0 || slotNumber != 0 {
            var bytes = [UInt8](
                repeating: 0, count: Constants.TNS_MAX_ROWID_LENGTH
            )
            var offset = 0
            offset = convertBase64(
                bytes: &bytes,
                value: Int(rba),
                size: 6,
                offset: offset
            )
            offset = convertBase64(
                bytes: &bytes,
                value: Int(partitionID),
                size: 3,
                offset: offset
            )
            offset = convertBase64(
                bytes: &bytes,
                value: Int(blockNumber),
                size: 6,
                offset: offset
            )
            offset = convertBase64(
                bytes: &bytes,
                value: Int(slotNumber),
                size: 3,
                offset: offset
            )
            return String(decoding: bytes, as: UTF8.self)
        }
        return nil
    }

    private static func convertBase64(
        bytes: inout [UInt8],
        value: Int,
        size: Int,
        offset: Int
    ) -> Int {
        var value = value
        for i in 0..<size {
            bytes[offset + size - i - 1] =
                Constants.TNS_BASE64_ALPHABET_ARRAY[value & 0x3f]
            value = value >> 6
        }
        return offset + size
    }
}

extension RowID {
    /// A universal rowid as Oracle spells it: a physical rowid in its 18-character form, and a
    /// logical one, such as an index-organized table's, as `*` and the base64 of its bytes.
    init(universal bytes: ByteBuffer) throws {
        let view = Array(bytes.readableBytesView)
        guard let kind = view.first else {
            throw OraclePartialDecodingError.fieldNotDecodable(type: RowID.self)
        }
        if kind == 1 {
            guard view.count >= 13 else {
                throw OraclePartialDecodingError.fieldNotDecodable(type: RowID.self)
            }
            func integer<T: FixedWidthInteger>(at offset: Int, as: T.Type) -> T {
                view[offset..<offset + MemoryLayout<T>.size].reduce(T.zero) { $0 << 8 | T($1) }
            }
            self.init(
                Self.makeDescription(
                    rba: integer(at: 1, as: UInt32.self),
                    partitionID: integer(at: 5, as: UInt16.self),
                    blockNumber: integer(at: 7, as: UInt32.self),
                    slotNumber: integer(at: 11, as: UInt16.self)
                ) ?? ""
            )
            return
        }
        self.init("*" + Self.unpaddedBase64(view.dropFirst()))
    }

    private static func unpaddedBase64(_ bytes: ArraySlice<UInt8>) -> String {
        let alphabet = Constants.TNS_BASE64_ALPHABET_ARRAY
        var output: [UInt8] = []
        output.reserveCapacity((bytes.count * 4 + 2) / 3)
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let remaining = bytes.endIndex - index
            let first = bytes[index]
            let second = remaining > 1 ? bytes[index + 1] : 0
            let third = remaining > 2 ? bytes[index + 2] : 0
            output.append(alphabet[Int(first >> 2)])
            output.append(alphabet[Int((first & 0x03) << 4 | second >> 4)])
            if remaining > 1 {
                output.append(alphabet[Int((second & 0x0f) << 2 | third >> 6)])
            }
            if remaining > 2 {
                output.append(alphabet[Int(third & 0x3f)])
            }
            index += min(3, remaining)
        }
        return String(decoding: output, as: UTF8.self)
    }
}

extension RowID: OracleDecodable {
    /// Since RowID is represented differently when received (either binary or b64 encoded string), we want to unify it here.
    init?(fromWire buffer: inout ByteBuffer) throws {
        let rba = try buffer.throwingReadUB4()
        let partitionID = try buffer.throwingReadUB2()
        try buffer.throwingMoveReaderIndex(forwardBy: 1)
        let blockNumber = try buffer.throwingReadUB4()
        let slotNumber = try buffer.throwingReadUB2()
        self.init(
            rba: rba,
            partitionID: partitionID,
            blockNumber: blockNumber,
            slotNumber: slotNumber
        )
    }

    @inlinable
    public init(
        from buffer: inout ByteBuffer,
        type: OracleDataType,
        context: OracleDecodingContext
    ) throws {
        switch type {
        case .rowID, .uRowID:
            guard let value = buffer.readString(length: buffer.readableBytes) else {
                throw OracleDecodingError.Code.missingData
            }
            self.description = value
        default:
            throw OracleDecodingError.Code.typeMismatch
        }
    }
}

extension RowID: OracleEncodable {
    @inlinable
    public static var defaultOracleType: OracleDataType { .rowID }

    @inlinable
    public func encode(
        into buffer: inout ByteBuffer,
        context: OracleEncodingContext
    ) {
        buffer.writeString(self.description)
    }
}
