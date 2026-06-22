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

import struct NIOCore.ByteBuffer

extension ByteBuffer {
    mutating func readString(
        with charset: Int = Constants.TNS_CS_IMPLICIT,
        file: String = #fileID, line: Int = #line
    ) throws -> String {
        guard charset == Constants.TNS_CS_IMPLICIT else {
            throw OraclePartialDecodingError.fieldNotDecodable(
                type: String.self, file: file, line: line
            )
        }
        var stringSlice = try self.throwingReadOracleSpecificLengthPrefixedSlice()
        guard let string = stringSlice.readString(length: stringSlice.readableBytes) else {
            throw OraclePartialDecodingError.fieldNotDecodable(
                type: String.self, file: file, line: line
            )
        }
        return string
    }
}
