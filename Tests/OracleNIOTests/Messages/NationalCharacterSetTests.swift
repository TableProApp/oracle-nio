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

@Suite struct NationalCharacterSetTests {
    private static let laoCESU8: [UInt8] = [
        0xE0, 0xBA, 0x94, 0xE0, 0xBB, 0x88, 0xE0, 0xBA, 0xB2, 0xE0, 0xBA, 0x99,  // ດ່ານ
        0x20, 0xED, 0xA0, 0xB4, 0xED, 0xB4, 0x9E,  // space, U+1D11E as two surrogates
    ]

    private static func capabilities(nationalCharacterSet: UInt16) -> Capabilities {
        var capabilities = Capabilities()
        capabilities.nCharsetID = nationalCharacterSet
        return capabilities
    }

    private static func decode(
        _ bytes: [UInt8], as type: OracleDataType, nationalCharacterSet: UInt16
    ) throws -> String? {
        var buffer = ByteBuffer(bytes: bytes)
        let context = OracleBackendMessageDecoder.Context(
            capabilities: Self.capabilities(nationalCharacterSet: nationalCharacterSet),
            columns: type
        )
        let row = try RowData.decode(from: &buffer, context: context)
        #expect(buffer.readableBytes == 0)
        guard case .data(let column) = row.columns.first else { return nil }
        var value = DataRow(columnCount: 1, bytes: column)[column: 0]
        guard value != nil else { return nil }
        return try String._decodeRaw(from: &value, type: type, context: .default)
    }

    /// Measured on Oracle 23ai with NLS_NCHAR_CHARACTERSET = UTF8: NVARCHAR2 arrives as CESU-8.
    @Test func nvarcharFromUTF8DatabaseDecodes() throws {
        let bytes = [UInt8(Self.laoCESU8.count)] + Self.laoCESU8
        #expect(try Self.decode(bytes, as: .nVarchar, nationalCharacterSet: 871) == "ດ່ານ 𝄞")
    }

    @Test func ncharFromUTF8DatabaseDecodes() throws {
        let bytes: [UInt8] = [5, 0xE0, 0xBA, 0xA5, 0x20, 0x20]
        #expect(try Self.decode(bytes, as: .nChar, nationalCharacterSet: 871) == "ລ  ")
    }

    /// An NCLOB is fetched as LONG NVARCHAR, which ends with a null indicator and a return code.
    @Test func longNVarcharFromUTF8DatabaseDecodes() throws {
        let bytes = [UInt8(Self.laoCESU8.count)] + Self.laoCESU8 + [0, 0]
        #expect(try Self.decode(bytes, as: .longNVarchar, nationalCharacterSet: 871) == "ດ່ານ 𝄞")
    }

    /// 200 ASCII bytes become 400 UTF-16 bytes, past the 252 a single length byte frames.
    @Test func valueThatGrowsPastShortLengthDecodes() throws {
        let text = String(repeating: "a", count: 200)
        let bytes = [UInt8(200)] + Array(text.utf8)
        #expect(try Self.decode(bytes, as: .nVarchar, nationalCharacterSet: 871) == text)
    }

    @Test func chunkedValueFromUTF8DatabaseDecodes() throws {
        let text = String(repeating: "ດ", count: 100)
        let utf8 = Array(text.utf8)
        let bytes =
            [Constants.TNS_LONG_LENGTH_INDICATOR]
            + [2, 0x01, 0x2C] + Array(utf8[0..<300])  // UB4 300
            + [0]  // end of chunks
            + [0, 0]  // null indicator, return code
        #expect(try Self.decode(bytes, as: .longNVarchar, nationalCharacterSet: 871) == text)
    }

    /// 20,000 ASCII bytes become 40,000 UTF-16 bytes, more than one 32,767-byte chunk.
    @Test func valueThatGrowsPastOneChunkDecodes() throws {
        let text = String(repeating: "a", count: 20_000)
        let bytes =
            [Constants.TNS_LONG_LENGTH_INDICATOR]
            + [2, 0x4E, 0x20] + Array(text.utf8)  // UB4 20,000
            + [0]  // end of chunks
            + [0, 0]  // null indicator, return code
        #expect(try Self.decode(bytes, as: .longNVarchar, nationalCharacterSet: 871) == text)
    }

    @Test func columnAfterAConvertedValueDecodes() throws {
        var buffer = ByteBuffer(bytes: [3, 0xE0, 0xBA, 0x94] + [3, 0xE0, 0xBA, 0x94])
        let context = OracleBackendMessageDecoder.Context(
            capabilities: Self.capabilities(nationalCharacterSet: 871),
            columns: .nVarchar, .varchar
        )
        let row = try RowData.decode(from: &buffer, context: context)
        #expect(buffer.readableBytes == 0)
        let values = try row.columns.enumerated().map { index, column -> String in
            guard case .data(let bytes) = column else { return "" }
            var value = DataRow(columnCount: 1, bytes: bytes)[column: 0]
            return try String._decodeRaw(from: &value, type: index == 0 ? .nVarchar : .varchar, context: .default)
        }
        #expect(values == ["ດ", "ດ"])
    }

    @Test func nullFromUTF8DatabaseStaysNull() throws {
        #expect(try Self.decode([0], as: .nVarchar, nationalCharacterSet: 871) == nil)
    }

    @Test func nvarcharFromAL16UTF16DatabaseIsUnchanged() throws {
        let bytes: [UInt8] = [6, 0x0E, 0x94, 0xD8, 0x34, 0xDD, 0x1E]
        #expect(try Self.decode(bytes, as: .nVarchar, nationalCharacterSet: 2000) == "ດ𝄞")
    }

    @Test func varcharIsNotConverted() throws {
        let bytes: [UInt8] = [3, 0xE0, 0xBA, 0x94]
        #expect(try Self.decode(bytes, as: .varchar, nationalCharacterSet: 871) == "ດ")
    }

    @Test func unknownNationalCharacterSetThrows() {
        #expect(throws: OracleSQLError.nationalCharsetNotSupported) {
            try Self.decode([1, 0x41], as: .nVarchar, nationalCharacterSet: 1)
        }
    }
}
