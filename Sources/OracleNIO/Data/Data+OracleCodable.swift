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

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

extension Data: OracleEncodable {
    @inlinable
    public static var defaultOracleType: OracleDataType { .raw }

    @inlinable
    public func encode(
        into buffer: inout ByteBuffer,
        context: OracleEncodingContext
    ) {
        buffer.reserveCapacity(minimumWritableBytes: MemoryLayout<UInt8>.size + self.count)
        buffer.writeOracleCLR(self, context: context)
    }

    @inlinable
    public func _encodeRaw(
        into buffer: inout ByteBuffer,
        context: OracleEncodingContext
    ) {
        self.encode(into: &buffer, context: context)
    }
}

extension Data: OracleDecodable {
    @inlinable
    public var size: UInt32 { UInt32(self.count) }

    @inlinable
    public init(
        from buffer: inout ByteBuffer,
        type: OracleDataType,
        context: OracleDecodingContext
    ) throws {
        switch type {
        case .raw, .longRAW:
            self = buffer.withUnsafeReadableBytesWithStorageManagement { ptr, storageRef in
                let storage = storageRef.takeUnretainedValue()
                return Data(
                    bytesNoCopy: UnsafeMutableRawPointer(mutating: ptr.baseAddress!),
                    count: buffer.readableBytes,
                    deallocator: .custom { _, _ in withExtendedLifetime(storage) {} }
                )
            }
        default:
            throw OracleDecodingError.Code.typeMismatch
        }
    }
}
