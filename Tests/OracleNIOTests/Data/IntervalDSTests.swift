//===----------------------------------------------------------------------===//
//
// This source file is part of the OracleNIO open source project
//
// Copyright (c) 2025 Timo Zacherl and the OracleNIO project authors
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

@Suite struct IntervalDSTests {
    /// Measured on Oracle 23ai: `INTERVAL '-1 02:03:04.5' DAY TO SECOND` sends every part below its
    /// bias, which unsigned subtraction trapped on.
    @Test func negativeIntervalDecodes() throws {
        var buffer: ByteBuffer? = ByteBuffer(bytes: [0x7f, 0xff, 0xff, 0xff, 58, 57, 56, 0x62, 0x32, 0x9b, 0x00])
        let interval = try IntervalDS._decodeRaw(from: &buffer, type: .intervalDS, context: .default)
        #expect(interval == IntervalDS(days: -1, hours: -2, minutes: -3, seconds: -4, fractionalSeconds: -500_000_000))
    }

    @Test func positiveIntervalDecodes() throws {
        var buffer: ByteBuffer? = ByteBuffer(bytes: [0x80, 0x00, 0x00, 0x01, 62, 63, 64, 0x9d, 0xcd, 0x65, 0x00])
        let interval = try IntervalDS._decodeRaw(from: &buffer, type: .intervalDS, context: .default)
        #expect(interval == IntervalDS(days: 1, hours: 2, minutes: 3, seconds: 4, fractionalSeconds: 500_000_000))
    }

    @Test func negativeIntervalEncodesBelowTheBias() {
        let interval = IntervalDS(days: -1, hours: -2, minutes: -3, seconds: -4, fractionalSeconds: -500_000_000)
        var buffer = ByteBuffer()
        interval.encode(into: &buffer, context: .default)
        #expect(buffer.getBytes(at: 0, length: 11) == [0x7f, 0xff, 0xff, 0xff, 58, 57, 56, 0x62, 0x32, 0x9b, 0x00])
    }
}
