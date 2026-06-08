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

import Atomics
import NIOCore
import NIOEmbedded
import Testing

@testable import OracleNIO

@Suite(.timeLimit(.minutes(5))) struct ConnectionStateMachineTests {
    @Test func queuedTasksAreExecuted() throws {
        var state = ConnectionStateMachine(.readyForStatement)
        let promise1 = EmbeddedEventLoop().makePromise(of: Void.self)
        promise1.fail(OracleSQLError.uncleanShutdown)  // we don't care about the error at all.
        let promise2 = EmbeddedEventLoop().makePromise(of: Void.self)
        promise2.fail(OracleSQLError.uncleanShutdown)  // we don't care about the error at all.
        let success = OracleBackendMessage.Status(callStatus: 1, endToEndSequenceNumber: 0)

        #expect(state.enqueue(task: .ping(promise1)) == .sendPing)
        #expect(state.enqueue(task: .ping(promise2)) == .wait)
        #expect(state.statusReceived(success) == .succeedPing(promise1))
        #expect(state.readyForStatementReceived() == .sendPing)
    }

    @Test func failedPingDoesNotLeak() {
        var state = ConnectionStateMachine(.readyForStatement)
        let atomic = ManagedAtomic(false)
        let pingPromise = EmbeddedEventLoop().makePromise(of: Void.self)
        pingPromise.futureResult.whenFailure { _ in
            atomic.store(true, ordering: .relaxed)
        }

        #expect(state.enqueue(task: .ping(pingPromise)) == .sendPing)
        #expect(
            state.errorHappened(.uncleanShutdown)
                == .closeConnectionAndCleanup(
                    .init(
                        action: .fireChannelInactive,
                        tasks: [],
                        error: .uncleanShutdown,
                        read: false,
                        closePromise: nil
                    )
                )
        )
        #expect(atomic.load(ordering: .relaxed) == true)
    }

    @Test func failedLOBDoesNotLeak() {
        var state = ConnectionStateMachine(.readyForStatement)
        let atomic = ManagedAtomic(false)
        let promise = EmbeddedEventLoop().makePromise(of: ByteBuffer?.self)
        promise.futureResult.whenFailure { _ in
            atomic.store(true, ordering: .relaxed)
        }
        let context = LOBOperationContext(
            sourceLOB: nil, sourceOffset: 0,
            destinationLOB: nil, destinationOffset: 0,
            operation: .read, sendAmount: false, amount: 0, promise: promise
        )

        #expect(state.enqueue(task: .lobOperation(context)) == .sendLOBOperation(context))
        #expect(
            state.errorHappened(.uncleanShutdown)
                == .closeConnectionAndCleanup(
                    .init(
                        action: .fireChannelInactive,
                        tasks: [],
                        error: .uncleanShutdown,
                        read: false,
                        closePromise: nil
                    )
                )
        )
        #expect(atomic.load(ordering: .relaxed) == true)
    }

    @Test func failLOBOperationOnError() {
        var state = ConnectionStateMachine(.readyForStatement)
        let promise = EmbeddedEventLoop().makePromise(of: ByteBuffer?.self)
        promise.fail(StatementContext.TestComplete())
        let context = LOBOperationContext(
            sourceLOB: nil, sourceOffset: 0,
            destinationLOB: nil, destinationOffset: 0,
            operation: .read, sendAmount: false, amount: 0, promise: promise
        )
        let error = BackendError(number: 1, rowCount: 0, isWarning: false, batchErrors: [])

        #expect(state.enqueue(task: .lobOperation(context)) == .sendLOBOperation(context))
        #expect(state.backendErrorReceived(error) == .failLOBOperation(promise, with: .server(error)))
    }

    @Test func failLOBOperationWhileClosing() {
        var state = ConnectionStateMachine(.closing)
        let promise = EmbeddedEventLoop().makePromise(of: ByteBuffer?.self)
        promise.fail(StatementContext.TestComplete())
        let context = LOBOperationContext(
            sourceLOB: nil, sourceOffset: 0,
            destinationLOB: nil, destinationOffset: 0,
            operation: .read, sendAmount: false, amount: 0, promise: promise
        )
        let error = BackendError(number: 1, rowCount: 0, isWarning: false, batchErrors: [])

        #expect(state.enqueue(task: .lobOperation(context)) == .failLOBOperation(promise, with: .server(error)))
    }

    @Test func resendLOBOperation() {
        var state = ConnectionStateMachine(.readyForStatement)
        let promise = EmbeddedEventLoop().makePromise(of: ByteBuffer?.self)
        promise.fail(StatementContext.TestComplete())
        let context = LOBOperationContext(
            sourceLOB: nil, sourceOffset: 0,
            destinationLOB: nil, destinationOffset: 0,
            operation: .read, sendAmount: false, amount: 0, promise: promise
        )

        #expect(state.enqueue(task: .lobOperation(context)) == .sendLOBOperation(context))
        #expect(state.resendReceived() == .sendLOBOperation(context))
    }

    @Test func resetMarkerRealignsNetworkSecurity() {
        var state = ConnectionStateMachine(.readyForStatement)
        let promise = EmbeddedEventLoop().makePromise(of: Void.self)
        promise.fail(OracleSQLError.uncleanShutdown)

        #expect(state.enqueue(task: .ping(promise)) == .sendPing)
        // The server signals an in-band break with two markers: we reply to the
        // first and realign the native-encryption keystream on the second (reset).
        #expect(state.markerReceived() == .sendMarker(read: false))
        #expect(state.markerReceived() == .resetNetworkSecurity)
    }

    @Test func errorDuringStatementSurfacesInsteadOfCrashing() {
        // A pipeline error mid-statement (a failed checksum after an in-band break)
        // must mark the statement complete so the follow-up readyForStatement does not
        // trip its precondition. Before the state write-back this readyForStatement
        // crashed the connection.
        let promise = EmbeddedEventLoop().makePromise(of: OracleRowStream.self)
        promise.fail(OracleSQLError.uncleanShutdown)  // we don't care about the error at all.
        let query: OracleStatement = "SELECT * FROM does_not_exist"
        let queryContext = StatementContext(statement: query, promise: promise)

        var state = ConnectionStateMachine.readyForStatement()
        #expect(
            state.enqueue(task: .statement(queryContext))
                == .sendExecute(queryContext, nil, cursorID: 0, requiresDefine: false, noPrefetch: false)
        )
        #expect(
            state.errorHappened(.uncleanShutdown)
                == .failStatement(promise, with: .uncleanShutdown, cleanupContext: nil)
        )
        #expect(state.readyForStatementReceived() == .fireEventReadyForStatement)
    }
}
