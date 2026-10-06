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

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

extension Date: OracleEncodable {
    @inlinable
    public static var defaultOracleType: OracleDataType { .timestampTZ }

    @inlinable
    public func encode(
        into buffer: inout ByteBuffer,
        context: OracleEncodingContext
    ) {
        var length = self.oracleType.bufferSizeFactor
        let currentCalendarTimeZone = Calendar.current
            .dateComponents([.timeZone], from: self).timeZone!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: self
        )
        let year = components.year!
        buffer.writeInteger(UInt8(year / 100 + 100))
        buffer.writeInteger(UInt8(year % 100 + 100))
        buffer.writeInteger(UInt8(components.month!))
        buffer.writeInteger(UInt8(components.day!))
        buffer.writeInteger(UInt8(components.hour! + 1))
        buffer.writeInteger(UInt8(components.minute! + 1))
        buffer.writeInteger(UInt8(components.second! + 1))
        if length > 7 {
            // The wire carries nanoseconds, not milliseconds.
            let fractionalSeconds = UInt32(components.nanosecond!)
            if fractionalSeconds == 0 && length <= 11 {
                length = 7
            } else {
                buffer.writeInteger(
                    fractionalSeconds, endianness: .big, as: UInt32.self
                )
            }
        }
        if length > 11 {
            let seconds = currentCalendarTimeZone.secondsFromGMT(for: self)
            let totalMinutes = seconds / 60
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            // Both parts carry the offset's sign, so a zone west of UTC writes bytes below the bias.
            buffer.writeInteger(UInt8(Int(Constants.TZ_HOUR_OFFSET) + hours))
            buffer.writeInteger(UInt8(Int(Constants.TZ_MINUTE_OFFSET) + minutes))
        }
    }
}

extension Date: OracleDecodable {
    @inlinable
    public init(
        from buffer: inout ByteBuffer,
        type: OracleDataType,
        context: OracleDecodingContext
    ) throws {
        switch type {
        case .date, .timestamp, .timestampLTZ, .timestampTZ:
            let length = buffer.readableBytes
            guard
                length >= 7,
                let firstSevenBytes = buffer.readBytes(length: 7)
            else {
                throw OracleDecodingError.Code.missingData
            }

            let year = (Int(firstSevenBytes[0]) - 100) * 100 + Int(firstSevenBytes[1]) - 100
            let month = Int(firstSevenBytes[2])
            let day = Int(firstSevenBytes[3])
            let hour = Int(firstSevenBytes[4]) - 1
            let minute = Int(firstSevenBytes[5]) - 1
            let second = Int(firstSevenBytes[6]) - 1
            var nanosecond = 0

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!

            if length >= 11,
                let value = buffer.readInteger(
                    endianness: .big, as: UInt32.self
                )
            {
                // The wire carries nanoseconds. Scaling by the digit count of the value read
                // `.05` as `.5` and `.000001` as `.1`.
                nanosecond = Int(value)
            }

            let (byte11, byte12) =
                buffer
                .readMultipleIntegers(as: (UInt8, UInt8).self) ?? (0, 0)

            if length > 11 && byte11 != 0 && byte12 != 0 {
                if byte11 & Constants.TNS_HAS_REGION_ID != 0 {
                    // Named time zones are not supported
                    throw OracleDecodingError.Code.failure
                }

                // A zone west of UTC sends bytes below the bias, which UInt8 arithmetic trapped on.
                let tzHour = Int(byte11) - Int(Constants.TZ_HOUR_OFFSET)
                let tzMinute = Int(byte12) - Int(Constants.TZ_MINUTE_OFFSET)
                if tzHour != 0 || tzMinute != 0 {
                    guard
                        let timeZone = TimeZone(
                            secondsFromGMT: tzHour * 3600 + tzMinute * 60
                        )
                    else {
                        throw OracleDecodingError.Code.failure
                    }
                    calendar.timeZone = timeZone
                }
            }

            let components = DateComponents(
                calendar: calendar,
                timeZone: TimeZone(secondsFromGMT: 0)!,  // dates are always UTC
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute,
                second: second,
                nanosecond: nanosecond
            )

            guard let value = calendar.date(from: components) else {
                throw OracleDecodingError.Code.failure
            }
            self = value
        default:
            throw OracleDecodingError.Code.typeMismatch
        }
    }
}
