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

extension OracleEncodable where Self: Collection, Self.Element == UInt8 {
    @inlinable
    public static var defaultOracleType: OracleDataType { .raw }

    @inlinable
    public var oracleType: OracleDataType { .raw }

    @inlinable
    public func encode(
        into buffer: inout ByteBuffer,
        context: OracleEncodingContext
    ) {
        buffer.writeOracleCLR(self, format: context.clrChunkFormat)
    }

    @inlinable
    public func _encodeRaw(
        into buffer: inout ByteBuffer,
        context: OracleEncodingContext
    ) {
        self.encode(into: &buffer, context: context)
    }
}
