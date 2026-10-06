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

public struct IntervalDS: Sendable, Equatable, Hashable {
    public var days: Int
    public var hours: Int
    public var minutes: Int
    public var seconds: Int
    public var fractionalSeconds: Int

    @inlinable
    public init(days: Int, hours: Int, minutes: Int, seconds: Int, fractionalSeconds: Int) {
        self.days = days
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.fractionalSeconds = fractionalSeconds
    }
}

extension IntervalDS: ExpressibleByFloatLiteral {
    @inlinable
    public init(floatLiteral value: Double) {
        var remaining = value
        let days = (remaining / (24 * 60 * 60)).rounded(.down)
        remaining -= Double(days) * 24 * 60 * 60
        let hours = (remaining / (60 * 60)).rounded(.down)
        remaining -= Double(hours) * 60 * 60
        let minutes = (remaining / 60).rounded(.down)
        remaining -= Double(minutes) * 60
        let seconds = remaining.rounded(.down)
        let fractionalSeconds = ((remaining - seconds) * 1000).rounded(.down)
        self = .init(
            days: Int(days),
            hours: Int(hours),
            minutes: Int(minutes),
            seconds: Int(seconds),
            fractionalSeconds: Int(fractionalSeconds)
        )
    }

    @inlinable
    public var double: Double {
        return (Double(days) * 24 * 60 * 60) + (Double(hours) * 60 * 60) + (Double(minutes) * 60)
            + Double(seconds) + (Double(fractionalSeconds) / 1000)
    }
}

extension IntervalDS: Encodable {
    @inlinable
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if encoder is _OracleJSONEncoder {
            try container.encode(self)
        } else {
            try container.encode(double)
        }
    }
}

extension IntervalDS: Decodable {
    @inlinable
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(Double.self)
        self = .init(floatLiteral: value)
    }
}

extension IntervalDS: OracleEncodable {
    @inlinable
    public static var defaultOracleType: OracleDataType { .intervalDS }

    @inlinable
    public func encode(
        into buffer: inout ByteBuffer,
        context: OracleEncodingContext
    ) {
        // Every part of a negative interval is negative, so each one is written below its bias.
        buffer.writeInteger(
            UInt32(bitPattern: Int32(self.days)) &+ Constants.TNS_DURATION_MID, endianness: .big
        )
        buffer.writeInteger(UInt8(Int(Constants.TNS_DURATION_OFFSET) + self.hours))
        buffer.writeInteger(UInt8(Int(Constants.TNS_DURATION_OFFSET) + self.minutes))
        buffer.writeInteger(UInt8(Int(Constants.TNS_DURATION_OFFSET) + self.seconds))
        buffer.writeInteger(
            UInt32(bitPattern: Int32(self.fractionalSeconds)) &+ Constants.TNS_DURATION_MID,
            endianness: .big
        )
        buffer.writeInteger(UInt8(buffer.readableBytes))
    }
}

extension IntervalDS: OracleDecodable {
    @inlinable
    public init(
        from buffer: inout ByteBuffer,
        type: OracleDataType,
        context: OracleDecodingContext
    ) throws {
        switch type {
        case .intervalDS:
            // A negative interval sends every part below its bias; unsigned subtraction trapped.
            let durationMid = Constants.TNS_DURATION_MID
            let durationOffset = Int(Constants.TNS_DURATION_OFFSET)
            let days = try buffer.throwingReadInteger(endianness: .big, as: UInt32.self)
            let hours = try buffer.throwingReadInteger(as: UInt8.self)
            let minutes = try buffer.throwingReadInteger(as: UInt8.self)
            let seconds = try buffer.throwingReadInteger(as: UInt8.self)
            let fractionalSeconds = try buffer.throwingReadInteger(endianness: .big, as: UInt32.self)
            self = .init(
                days: Int(Int32(bitPattern: days &- durationMid)),
                hours: Int(hours) - durationOffset,
                minutes: Int(minutes) - durationOffset,
                seconds: Int(seconds) - durationOffset,
                fractionalSeconds: Int(Int32(bitPattern: fractionalSeconds &- durationMid))
            )
        default:
            throw OracleDecodingError.Code.typeMismatch
        }
    }
}
