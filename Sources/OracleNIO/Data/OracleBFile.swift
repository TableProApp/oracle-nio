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

/// The directory alias and file name a `BFILE` points at, read from its locator. Reading the file
/// itself takes LOB round trips; naming it does not.
public struct OracleBFile: Sendable, Hashable {
    public let directory: String
    public let fileName: String

    public init(directory: String, fileName: String) {
        self.directory = directory
        self.fileName = fileName
    }
}

extension OracleBFile: OracleDecodable {
    /// The names sit after the locator's fixed header, each behind a two-byte length, as
    /// python-oracledb's `get_file_name` reads them.
    public init(
        from buffer: inout ByteBuffer,
        type: OracleDataType,
        context: OracleDecodingContext
    ) throws {
        guard type == .bFile else {
            throw OracleDecodingError.Code.typeMismatch
        }
        guard buffer.readableBytes >= Constants.TNS_LOB_LOCATOR_FIXED_OFFSET else {
            throw OracleDecodingError.Code.missingData
        }
        buffer.moveReaderIndex(forwardBy: Constants.TNS_LOB_LOCATOR_FIXED_OFFSET)
        guard
            let directoryLength = buffer.readInteger(endianness: .big, as: UInt16.self),
            let directory = buffer.readString(length: Int(directoryLength)),
            let fileNameLength = buffer.readInteger(endianness: .big, as: UInt16.self),
            let fileName = buffer.readString(length: Int(fileNameLength))
        else {
            throw OracleDecodingError.Code.missingData
        }
        self.init(directory: directory, fileName: fileName)
    }
}
