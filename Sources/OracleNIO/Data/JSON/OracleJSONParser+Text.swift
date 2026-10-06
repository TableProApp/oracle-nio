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

extension OracleJSONParser {
    /// Writes an OSON value as JSON text, keeping the order the tree stores each object's fields in
    /// and every digit of a NUMBER, which a decode through ``OracleJSONStorage`` loses.
    ///
    /// Scalars Oracle extends JSON with are spelled the way `JSON_SERIALIZE` spells them: dates and
    /// timestamps as ISO 8601 strings, intervals as ISO 8601 durations, binary as upper-case hex.
    @usableFromInline
    static func serialize(from buffer: inout ByteBuffer) throws -> String {
        var parser = OracleJSONParser()
        try parser.readHeader(from: &buffer)
        var text = ""
        try parser.writeValue(from: &buffer, into: &text)
        return text
    }

    private struct OpenContainer {
        var cursor: ChildCursor
        var hasWrittenAChild = false
    }

    /// Walks the tree with a stack of its own rather than recursion: nesting Oracle accepts overflows the stack
    /// a task runs on.
    private func writeValue(from buffer: inout ByteBuffer, into text: inout String) throws {
        let workLimit = Self.workLimit(forValueOfSize: buffer.writerIndex)
        let rootType = try buffer.throwingReadInteger(as: UInt8.self)
        guard Self.isContainer(rootType) else {
            try self.writeScalar(rootType, from: &buffer, into: &text)
            return
        }
        text += Self.isObject(rootType) ? "{" : "["
        var stack = [OpenContainer(cursor: try self.openContainer(ofType: rootType, in: &buffer))]
        while let top = stack.indices.last {
            guard let child = try self.nextChild(of: &stack[top].cursor, in: &buffer) else {
                text += stack.removeLast().cursor.isObject ? "}" : "]"
                continue
            }
            if stack[top].hasWrittenAChild {
                text += ","
            }
            stack[top].hasWrittenAChild = true
            if let name = child.name {
                Self.writeString(name, into: &text)
                text += ":"
            }
            let nodeType = try buffer.throwingReadInteger(as: UInt8.self)
            if Self.isContainer(nodeType) {
                try Self.checkDepth(stack.count + 1)
                let cursor = try self.openContainer(ofType: nodeType, in: &buffer)
                try Self.checkNotOpen(cursor, in: stack.map(\.cursor))
                text += Self.isObject(nodeType) ? "{" : "["
                stack.append(OpenContainer(cursor: cursor))
            } else {
                try self.writeScalar(nodeType, from: &buffer, into: &text)
            }
            guard text.utf8.count <= workLimit else {
                throw OracleError.ErrorType.unexpectedData
            }
        }
    }

    private func writeScalar(_ nodeType: UInt8, from buffer: inout ByteBuffer, into text: inout String) throws {
        switch nodeType {
        case Constants.TNS_JSON_TYPE_NULL:
            text += "null"
        case Constants.TNS_JSON_TYPE_TRUE:
            text += "true"
        case Constants.TNS_JSON_TYPE_FALSE:
            text += "false"
        case Constants.TNS_JSON_TYPE_DATE, Constants.TNS_JSON_TYPE_TIMESTAMP7:
            let bytes = try buffer.throwingReadSlice(length: 7)
            Self.writeString(try Self.isoDateTime(bytes, alwaysWriteFraction: false), into: &text)
        case Constants.TNS_JSON_TYPE_TIMESTAMP:
            let bytes = try buffer.throwingReadSlice(length: 11)
            Self.writeString(try Self.isoDateTime(bytes, alwaysWriteFraction: false), into: &text)
        case Constants.TNS_JSON_TYPE_TIMESTAMP_TZ:
            let bytes = try buffer.throwingReadSlice(length: 13)
            Self.writeString(try Self.isoDateTime(bytes, alwaysWriteFraction: true), into: &text)
        case Constants.TNS_JSON_TYPE_BINARY_FLOAT:
            var bytes = try buffer.throwingReadSlice(length: 4)
            text += Self.jsonNumber(Double(try OracleNumeric.parseBinaryFloat(from: &bytes)))
        case Constants.TNS_JSON_TYPE_BINARY_DOUBLE:
            var bytes = try buffer.throwingReadSlice(length: 8)
            text += Self.jsonNumber(try OracleNumeric.parseBinaryDouble(from: &bytes))
        case Constants.TNS_JSON_TYPE_INTERVAL_DS:
            var bytes = try buffer.throwingReadSlice(length: 11)
            let interval = try IntervalDS(from: &bytes, type: .intervalDS, context: .default)
            Self.writeString(Self.isoDuration(interval), into: &text)
        case Constants.TNS_JSON_TYPE_INTERVAL_YM:
            var bytes = try buffer.throwingReadSlice(length: 5)
            let interval = try IntervalYM(from: &bytes, type: .intervalYM, context: .default)
            let sign = interval.years < 0 || interval.months < 0 ? "-" : ""
            Self.writeString("\(sign)P\(abs(interval.years))Y\(abs(interval.months))M", into: &text)
        case Constants.TNS_JSON_TYPE_STRING_LENGTH_UINT8:
            let length = try buffer.throwingReadInteger(as: UInt8.self)
            Self.writeString(try buffer.throwingReadString(length: Int(length)), into: &text)
        case Constants.TNS_JSON_TYPE_STRING_LENGTH_UINT16:
            let length = try buffer.throwingReadInteger(as: UInt16.self)
            Self.writeString(try buffer.throwingReadString(length: Int(length)), into: &text)
        case Constants.TNS_JSON_TYPE_STRING_LENGTH_UINT32:
            let length = try buffer.throwingReadInteger(as: UInt32.self)
            Self.writeString(try buffer.throwingReadString(length: Int(length)), into: &text)
        case Constants.TNS_JSON_TYPE_NUMBER_LENGTH_UINT8:
            let length = try buffer.throwingReadInteger(as: UInt8.self)
            var bytes = try buffer.throwingReadSlice(length: Int(length))
            text += try OracleNumeric.parseDecimalString(from: &bytes)
        case Constants.TNS_JSON_TYPE_BINARY_LENGTH_UINT16:
            let length = try buffer.throwingReadInteger(as: UInt16.self)
            Self.writeString(Self.hex(try buffer.throwingReadSlice(length: Int(length))), into: &text)
        case Constants.TNS_JSON_TYPE_BINARY_LENGTH_UINT32:
            let length = try buffer.throwingReadInteger(as: UInt32.self)
            Self.writeString(Self.hex(try buffer.throwingReadSlice(length: Int(length))), into: &text)
        case Constants.TNS_JSON_TYPE_EXTENDED:
            try self.writeExtended(from: &buffer, into: &text)
        default:
            try self.writeInlineScalar(nodeType, from: &buffer, into: &text)
        }
    }

    /// Numbers and strings short enough to carry their length in the node type itself.
    private func writeInlineScalar(_ nodeType: UInt8, from buffer: inout ByteBuffer, into text: inout String) throws {
        if [0x20, 0x60].contains(nodeType & 0xf0) {
            var bytes = try buffer.throwingReadSlice(length: Int(nodeType & 0x0f) + 1)
            text += try OracleNumeric.parseDecimalString(from: &bytes)
            return
        }
        if [0x40, 0x50].contains(nodeType & 0xf0) {
            var bytes = try buffer.throwingReadSlice(length: Int(nodeType & 0x0f))
            text += try OracleNumeric.parseDecimalString(from: &bytes)
            return
        }
        if nodeType & 0xe0 == 0 {
            Self.writeString(try buffer.throwingReadString(length: Int(nodeType)), into: &text)
            return
        }
        throw OracleError.ErrorType.osonNodeTypeNotSupported
    }

    private func writeExtended(from buffer: inout ByteBuffer, into text: inout String) throws {
        let extendedType = try buffer.throwingReadInteger(as: UInt8.self)
        guard extendedType == Constants.TNS_JSON_TYPE_VECTOR else {
            throw OracleError.ErrorType.osonNodeTypeNotSupported
        }
        let length = try buffer.throwingReadInteger(as: UInt32.self)
        var slice = try buffer.throwingReadSlice(length: Int(length))
        let (format, elements) = try _decodeOracleVectorMetadata(from: &slice)
        let values: [String]
        switch format {
        case .int8:
            values = try OracleVectorInt8._decodeActual(from: &slice, elements: elements).map { String($0) }
        case .float32:
            values = try OracleVectorFloat32._decodeActual(from: &slice, elements: elements)
                .map { Self.jsonNumber(Double($0)) }
        case .float64:
            values = try OracleVectorFloat64._decodeActual(from: &slice, elements: elements)
                .map { Self.jsonNumber($0) }
        case .binary:
            values = try OracleVectorBinary._decodeActual(from: &slice, elements: elements).map { String($0) }
        }
        text += "[" + values.joined(separator: ",") + "]"
    }

    static func writeString(_ value: String, into text: inout String) {
        text += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": text += "\\\""
            case "\\": text += "\\\\"
            case "\n": text += "\\n"
            case "\r": text += "\\r"
            case "\t": text += "\\t"
            case "\u{08}": text += "\\b"
            case "\u{0C}": text += "\\f"
            case _ where scalar.value < 0x20:
                text += "\\u" + String(repeating: "0", count: 4 - String(scalar.value, radix: 16).count)
                    + String(scalar.value, radix: 16)
            default:
                text.unicodeScalars.append(scalar)
            }
        }
        text += "\""
    }

    /// JSON has no infinity or NaN, so those become strings rather than invalid text.
    private static func jsonNumber(_ value: Double) -> String {
        guard value.isFinite else {
            return "\"\(value)\""
        }
        return "\(value)"
    }

    private static func hex(_ bytes: ByteBuffer) -> String {
        bytes.readableBytesView.map { byte in
            let digits = String(byte, radix: 16, uppercase: true)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
    }

    private static func isoDuration(_ interval: IntervalDS) -> String {
        let isNegative =
            interval.days < 0 || interval.hours < 0 || interval.minutes < 0
            || interval.seconds < 0 || interval.fractionalSeconds < 0
        var text = isNegative ? "-P" : "P"
        text += "\(abs(interval.days))DT\(abs(interval.hours))H\(abs(interval.minutes))M\(abs(interval.seconds))"
        let nanoseconds = abs(interval.fractionalSeconds)
        if nanoseconds != 0 {
            text += "." + Self.fraction(nanoseconds)
        }
        return text + "S"
    }

    /// Six digits when the value is whole microseconds, nine otherwise, as `JSON_SERIALIZE` writes.
    private static func fraction(_ nanoseconds: Int) -> String {
        let digits = nanoseconds % 1_000 == 0 ? 6 : 9
        let value = digits == 6 ? nanoseconds / 1_000 : nanoseconds
        let text = String(value)
        return String(repeating: "0", count: max(0, digits - text.count)) + text
    }

    /// The date and time bytes of a value with a zone are UTC, and the text shows the wall clock at
    /// the value's own offset, as `JSON_SERIALIZE` does.
    private static func isoDateTime(_ bytes: ByteBuffer, alwaysWriteFraction: Bool) throws -> String {
        let view = Array(bytes.readableBytesView)
        guard view.count >= 7 else {
            throw OracleDecodingError.Code.missingData
        }
        var year = (Int(view[0]) - 100) * 100 + Int(view[1]) - 100
        var month = Int(view[2])
        var day = Int(view[3])
        var hour = Int(view[4]) - 1
        var minute = Int(view[5]) - 1
        let second = Int(view[6]) - 1
        var nanoseconds = 0
        if view.count >= 11 {
            nanoseconds = view[7..<11].reduce(0) { $0 << 8 | Int($1) }
        }

        var suffix = ""
        if view.count >= 13, view[11] != 0, view[12] != 0 {
            if view[11] & Constants.TNS_HAS_REGION_ID != 0 {
                suffix = "Z"
            } else {
                let offsetMinutes =
                    (Int(view[11]) - Int(Constants.TZ_HOUR_OFFSET)) * 60
                    + Int(view[12]) - Int(Constants.TZ_MINUTE_OFFSET)
                (year, month, day, hour, minute) = Self.shift(
                    year: year, month: month, day: day, hour: hour, minute: minute, by: offsetMinutes
                )
                let magnitude = abs(offsetMinutes)
                suffix = (offsetMinutes < 0 ? "-" : "+") + Self.pad(magnitude / 60, 2) + ":" + Self.pad(magnitude % 60, 2)
            }
        }

        let yearText = (year < 0 ? "-" : "") + Self.pad(abs(year), 4)
        var text = "\(yearText)-\(Self.pad(month, 2))-\(Self.pad(day, 2))"
        text += "T\(Self.pad(hour, 2)):\(Self.pad(minute, 2)):\(Self.pad(second, 2))"
        if nanoseconds != 0 || alwaysWriteFraction {
            text += "." + Self.fraction(nanoseconds)
        }
        return text + suffix
    }

    /// Moves a wall clock by whole minutes in proleptic Gregorian days. Oracle numbers the year
    /// before 1 as -1, so the arithmetic runs on astronomical years and converts back.
    private static func shift(
        year: Int, month: Int, day: Int, hour: Int, minute: Int, by offsetMinutes: Int
    ) -> (Int, Int, Int, Int, Int) {
        let astronomicalYear = year < 0 ? year + 1 : year
        var days = Self.daysFromCivil(year: astronomicalYear, month: month, day: day)
        var minutes = hour * 60 + minute + offsetMinutes
        let minutesPerDay = 1_440
        let dayCarry = minutes >= 0 ? minutes / minutesPerDay : (minutes - minutesPerDay + 1) / minutesPerDay
        days += dayCarry
        minutes -= dayCarry * minutesPerDay
        let civil = Self.civilFromDays(days)
        let oracleYear = civil.year <= 0 ? civil.year - 1 : civil.year
        return (oracleYear, civil.month, civil.day, minutes / 60, minutes % 60)
    }

    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let year = month <= 2 ? year - 1 : year
        let era = (year >= 0 ? year : year - 399) / 400
        let yearOfEra = year - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }
}
