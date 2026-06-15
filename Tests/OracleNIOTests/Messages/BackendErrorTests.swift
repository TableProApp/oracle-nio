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

@Suite(.timeLimit(.minutes(5))) struct BackendErrorTests {
    @Test func moreBatchOffsetsThanCodesDoesNotTrap() throws {
        // The server reports one batch error offset but zero batch error codes, so the
        // offsets loop indexes past the (empty) batch array. It must skip the out-of-range
        // write instead of trapping. Field versions use TNS_CCAP_FIELD_VERSION_MAX, so the
        // 12c+ and 20c branches are exercised.
        var buffer = ByteBuffer(bytes: [
            0,  // end of call status
            0,  // end to end seq#
            0,  // current row number
            0,  // error number
            0,  // array elem error
            0,  // array elem error
            0,  // cursor id
            0,  // error position
            0, 0, 0, 0, 0, 0,  // sql type, fatal, flags, cursor options, UDI, warning
            0, 0, 0, 0, 0,  // row id (rba, partition, separator, block, slot)
            0,  // OS error
            0,  // statement number
            0,  // call number
            0,  // padding
            0,  // success iterations
            0,  // oerrdd byte count
            0,  // number of batch error codes
            1, 1,  // number of batch error offsets = 1
            0,  // length indicator for offsets
            0,  // offset value
            0,  // number of batch error messages
            0,  // error number
            0,  // row count
            0,  // 20c sql type
            0,  // 20c server checksum
        ])
        let error = try BackendError.decode(
            from: &buffer, context: .init(capabilities: .desired())
        )
        #expect(error.batchErrors.isEmpty)
        #expect(error.number == 0)
    }
}
