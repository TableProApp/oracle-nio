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
import NIOEmbedded
import Testing

@testable import OracleNIO

@Suite(.timeLimit(.minutes(5))) struct StatementStateMachineTests {
    @Test func queryWithoutDataRowsHappyPath() throws {
        let promise = EmbeddedEventLoop().makePromise(of: OracleRowStream.self)
        promise.fail(OracleSQLError.uncleanShutdown)  // we don't care about the error at all.
        let query: OracleStatement = "DELETE FROM table"
        let queryContext = StatementContext(statement: query, promise: promise)

        let result = StatementResult(value: .noRows(affectedRows: 0, lastRowID: nil))
        let backendError = BackendError(
            number: 0, cursorID: 6, position: 0, rowCount: 0, isWarning: false, message: nil,
            rowID: nil, batchErrors: [])

        var state = ConnectionStateMachine.readyForStatement()
        #expect(
            state.enqueue(task: .statement(queryContext))
                == .sendExecute(queryContext, nil, cursorID: 0, requiresDefine: false, noPrefetch: false)
        )
        #expect(state.backendErrorReceived(backendError) == .succeedStatement(promise, result))
        #expect(state.channelReadComplete() == .wait)
        #expect(state.readEventCaught() == .read)
    }

    @Test func queryWithDataRowsHappyPath() throws {
        let promise = EmbeddedEventLoop().makePromise(of: OracleRowStream.self)
        promise.fail(OracleSQLError.uncleanShutdown)  // we don't care about the error at all.
        let query: OracleStatement = "SELECT 1 AS id FROM dual"
        let queryContext = StatementContext(statement: query, promise: promise)

        let describeInfo = DescribeInfo(columns: [
            .init(
                name: "ID",
                dataType: .number,
                dataTypeSize: 0,
                precision: 11,
                scale: 127,
                bufferSize: 2,
                nullsAllowed: true,
                typeScheme: nil,
                typeName: nil,
                domainSchema: nil,
                domainName: nil,
                annotations: [:],
                vectorDimensions: nil,
                vectorFormat: nil
            )
        ])
        let rowHeader = OracleBackendMessage.RowHeader()
        let result = StatementResult(value: .describeInfo(describeInfo.columns))

        var state = ConnectionStateMachine.readyForStatement()
        #expect(
            state.enqueue(task: .statement(queryContext))
                == .sendExecute(queryContext, nil, cursorID: 0, requiresDefine: false, noPrefetch: false)
        )
        #expect(state.describeInfoReceived(describeInfo) == .wait)
        #expect(state.rowHeaderReceived(rowHeader) == .succeedStatement(promise, result))
        let row1: DataRow = .makeTestDataRow(1)
        #expect(state.rowDataReceived(.init(1), capabilities: .init()) == .wait)
        #expect(state.queryParameterReceived(.init()) == .wait)
        #expect(
            state.backendErrorReceived(.noData)
                == .forwardStreamComplete([row1], cursorID: 1, affectedRows: 1, lastRowID: nil))
    }

    @Test func queryWithLargeDuplicateWorks() throws {
        let promise = EmbeddedEventLoop().makePromise(of: OracleRowStream.self)
        promise.fail(OracleSQLError.uncleanShutdown)  // we don't care about the error at all.
        let query: OracleStatement = "SELECT 1 AS id FROM dual"
        let queryContext = StatementContext(statement: query, promise: promise)

        let describeInfo = DescribeInfo(columns: [
            .init(
                name: "ID",
                dataType: .number,
                dataTypeSize: 0,
                precision: 11,
                scale: 127,
                bufferSize: 2,
                nullsAllowed: true,
                typeScheme: nil,
                typeName: nil,
                domainSchema: nil,
                domainName: nil,
                annotations: [:],
                vectorDimensions: nil,
                vectorFormat: nil
            )
        ])
        let rowHeader = OracleBackendMessage.RowHeader()
        let result = StatementResult(value: .describeInfo(describeInfo.columns))

        var state = ConnectionStateMachine.readyForStatement()
        #expect(
            state.enqueue(task: .statement(queryContext))
                == .sendExecute(queryContext, nil, cursorID: 0, requiresDefine: false, noPrefetch: false)
        )
        #expect(state.describeInfoReceived(describeInfo) == .wait)
        #expect(state.rowHeaderReceived(rowHeader) == .succeedStatement(promise, result))
        var largeColumn = ByteBuffer(repeating: UInt8(1), count: Int(UInt8.max) + 25)
        var out = ByteBuffer()
        var length = largeColumn.readableBytes
        out.writeInteger(Constants.TNS_LONG_LENGTH_INDICATOR)
        while largeColumn.readableBytes > 0 {
            let chunkLength = min(length, Constants.TNS_CHUNK_SIZE)
            out.writeInteger(UInt32(chunkLength))
            length -= chunkLength
            var part = largeColumn.readSlice(length: chunkLength)!
            out.writeBuffer(&part)
        }
        out.writeInteger(UInt32(0))
        let row1 = DataRow(columnCount: 1, bytes: out)
        #expect(state.rowDataReceived(.init(columns: [.data(out)]), capabilities: .init()) == .wait)
        #expect(state.rowHeaderReceived(.init(bitVector: [])) == .wait)
        #expect(state.rowDataReceived(.init(columns: [.duplicate(0)]), capabilities: .init()) == .wait)
        #expect(state.queryParameterReceived(.init()) == .wait)
        #expect(
            state.backendErrorReceived(.noData)
                == .forwardStreamComplete([row1, row1], cursorID: 1, affectedRows: 1, lastRowID: nil))
    }

    @Test func cancellationCompletesQueryOnlyOnce() throws {
        let promise = EmbeddedEventLoop().makePromise(of: OracleRowStream.self)
        promise.fail(OracleSQLError.uncleanShutdown)  // we don't care about the error at all.
        let query: OracleStatement = "SELECT 1 AS id FROM dual"
        let queryContext = StatementContext(statement: query, promise: promise)

        let describeInfo = DescribeInfo(columns: [
            .init(
                name: "ID",
                dataType: .number,
                dataTypeSize: 0,
                precision: 11,
                scale: 0,
                bufferSize: 22,
                nullsAllowed: true,
                typeScheme: nil,
                typeName: nil,
                domainSchema: nil,
                domainName: nil,
                annotations: [:],
                vectorDimensions: nil,
                vectorFormat: nil
            )
        ])
        let rowHeader = OracleBackendMessage.RowHeader()
        let result = StatementResult(value: .describeInfo(describeInfo.columns))
        let backendError = BackendError(
            number: 1013, cursorID: 3, position: 0, rowCount: 2, isWarning: false,
            message: "ORA-01013: user requested cancel of current operation\n", rowID: nil,
            batchErrors: [])

        var state = ConnectionStateMachine.readyForStatement()
        #expect(
            state.enqueue(task: .statement(queryContext))
                == .sendExecute(queryContext, nil, cursorID: 0, requiresDefine: false, noPrefetch: false)
        )
        #expect(state.describeInfoReceived(describeInfo) == .wait)
        #expect(state.rowHeaderReceived(rowHeader) == .succeedStatement(promise, result))
        #expect(state.rowDataReceived(.init(1_024_834), capabilities: .init()) == .wait)
        #expect(state.rowDataReceived(.init(1_024_834), capabilities: .init()) == .wait)
        #expect(state.queryParameterReceived(.init()) == .wait)
        #expect(state.backendErrorReceived(.sendFetch) == .sendFetch(queryContext, cursorID: 3))
        #expect(
            state.cancelStatementStream()
                == .forwardStreamError(.statementCancelled, read: false, cursorID: nil, clientCancelled: true))
        #expect(state.markerReceived() == .sendMarker(read: false))
        #expect(state.backendErrorReceived(backendError) == .forwardCancelComplete(cursorID: 3))
        #expect(state.readyForStatementReceived() == .fireEventReadyForStatement)
    }

    @Test func cancellationFiresRead() throws {
        let promise = EmbeddedEventLoop().makePromise(of: OracleRowStream.self)
        promise.fail(OracleSQLError.uncleanShutdown)  // we don't care about the error at all.
        let query: OracleStatement = "SELECT 1 AS id FROM dual"
        let queryContext = StatementContext(statement: query, promise: promise)

        let describeInfo = DescribeInfo(columns: [
            .init(
                name: "ID",
                dataType: .number,
                dataTypeSize: 0,
                precision: 11,
                scale: 0,
                bufferSize: 22,
                nullsAllowed: true,
                typeScheme: nil,
                typeName: nil,
                domainSchema: nil,
                domainName: nil,
                annotations: [:],
                vectorDimensions: nil,
                vectorFormat: nil
            )
        ])
        let rowHeader = OracleBackendMessage.RowHeader()
        let result = StatementResult(value: .describeInfo(describeInfo.columns))

        var state = ConnectionStateMachine.readyForStatement()
        #expect(
            state.enqueue(task: .statement(queryContext))
                == .sendExecute(queryContext, nil, cursorID: 0, requiresDefine: false, noPrefetch: false)
        )
        #expect(state.describeInfoReceived(describeInfo) == .wait)
        #expect(state.rowHeaderReceived(rowHeader) == .succeedStatement(promise, result))
        #expect(state.rowDataReceived(.init(1_024_834), capabilities: .init()) == .wait)
        #expect(state.rowDataReceived(.init(1_024_834), capabilities: .init()) == .wait)
        #expect(state.queryParameterReceived(.init()) == .wait)
        #expect(state.backendErrorReceived(.sendFetch) == .sendFetch(queryContext, cursorID: 3))
        #expect(
            state.cancelStatementStream()
                == .forwardStreamError(
                    .statementCancelled, read: false, cursorID: nil, clientCancelled: true))
        #expect(state.statementStreamCancelled() == .sendMarker(read: true))
    }

    @Test func cancellationDoesNotCrashOnBitVector() throws {
        let promise = EmbeddedEventLoop().makePromise(of: OracleRowStream.self)
        promise.fail(OracleSQLError.uncleanShutdown)  // we don't care about the error at all.
        let query: OracleStatement = "SELECT 1 AS id FROM dual"
        let queryContext = StatementContext(statement: query, promise: promise)

        let describeInfo = DescribeInfo(columns: [
            .init(
                name: "ID",
                dataType: .number,
                dataTypeSize: 0,
                precision: 11,
                scale: 0,
                bufferSize: 22,
                nullsAllowed: true,
                typeScheme: nil,
                typeName: nil,
                domainSchema: nil,
                domainName: nil,
                annotations: [:],
                vectorDimensions: nil,
                vectorFormat: nil
            )
        ])
        let rowHeader = OracleBackendMessage.RowHeader()
        let result = StatementResult(value: .describeInfo(describeInfo.columns))

        var state = ConnectionStateMachine.readyForStatement()
        #expect(
            state.enqueue(task: .statement(queryContext))
                == .sendExecute(queryContext, nil, cursorID: 0, requiresDefine: false, noPrefetch: false)
        )
        #expect(state.describeInfoReceived(describeInfo) == .wait)
        #expect(state.rowHeaderReceived(rowHeader) == .succeedStatement(promise, result))
        #expect(state.rowDataReceived(.init(1), capabilities: .init()) == .wait)
        #expect(
            state.cancelStatementStream()
                == .forwardStreamError(
                    .statementCancelled, read: false, cursorID: nil, clientCancelled: true))
        #expect(state.bitVectorReceived(.init(columnsCountSent: 1, bitVector: nil)) == .wait)
        #expect(state.statementStreamCancelled() == .sendMarker(read: true))
    }

    // MARK: Server errors

    @Test func cursorFailingBeforeItsFirstRowFailsTheStatementAndClosesTheCursor() {
        let promise = Self.discardedPromise()
        let cursor = Cursor(id: 3, isQuery: true, describeInfo: Self.varcharDescribeInfo)
        let cursorContext = StatementContext(
            cursor: cursor, options: .init(), logger: OracleConnection.noopLogger, promise: promise
        )
        let backendError = Self.backendError(910, cursorID: 3)

        var state = ConnectionStateMachine.readyForStatement()
        #expect(
            state.enqueue(task: .statement(cursorContext))
                == .sendExecute(cursorContext, nil, cursorID: 3, requiresDefine: false, noPrefetch: false)
        )
        #expect(
            state.backendErrorReceived(backendError)
                == .failStatement(promise, with: .server(backendError), cleanupContext: nil, cursorID: 3)
        )
        #expect(state.readyForStatementReceived() == .fireEventReadyForStatement)
    }

    @Test func queryFailingAfterItsDescribeInfoFailsTheStatementAndClosesTheCursor() {
        let promise = Self.discardedPromise()
        let queryContext = StatementContext(statement: "SELECT 1/0 FROM dual", promise: promise)
        let backendError = Self.backendError(1476, cursorID: 1)

        var state = ConnectionStateMachine.readyForStatement()
        _ = state.enqueue(task: .statement(queryContext))
        #expect(state.describeInfoReceived(Self.varcharDescribeInfo) == .wait)
        #expect(
            state.backendErrorReceived(backendError)
                == .failStatement(promise, with: .server(backendError), cleanupContext: nil, cursorID: 1)
        )
        #expect(state.readyForStatementReceived() == .fireEventReadyForStatement)
    }

    @Test func failedStatementClosesTheCursorTheServerOpenedForIt() {
        let promise = Self.discardedPromise()
        let queryContext = StatementContext(statement: "SELECT 1/0 FROM dual", promise: promise)
        let backendError = Self.backendError(1476, cursorID: 1)

        var state = ConnectionStateMachine.readyForStatement()
        _ = state.enqueue(task: .statement(queryContext))
        #expect(
            state.backendErrorReceived(backendError)
                == .failStatement(promise, with: .server(backendError), cleanupContext: nil, cursorID: 1)
        )
    }

    /// Without a statement cache nothing executes the cursor again, so an integrity error leaves it
    /// open for the life of the session unless it is closed like any other.
    @Test func integrityErrorClosesTheCursorToo() {
        let promise = Self.discardedPromise()
        let insertContext = StatementContext(statement: "INSERT INTO t VALUES (1)", promise: promise)
        let backendError = Self.backendError(1, cursorID: 4)

        var state = ConnectionStateMachine.readyForStatement()
        _ = state.enqueue(task: .statement(insertContext))
        #expect(
            state.backendErrorReceived(backendError)
                == .failStatement(promise, with: .server(backendError), cleanupContext: nil, cursorID: 4)
        )
    }

    /// ORA-01000 arrives at cursor 0, because the server could not open one. It must fail the
    /// statement, not complete it as an empty result.
    @Test func errorWithoutACursorFailsTheStatement() throws {
        let promise = Self.discardedPromise()
        let queryContext = StatementContext(statement: "SELECT 42 FROM dual", promise: promise)
        let backendError = Self.backendError(1000, cursorID: 0)

        var state = ConnectionStateMachine.readyForStatement()
        _ = state.enqueue(task: .statement(queryContext))
        let action = state.backendErrorReceived(backendError)
        guard case .failStatement(_, let error, nil, nil) = action else {
            Issue.record("Expected the statement to fail, got \(action)")
            return
        }
        #expect(error.code == .server)
        #expect(error.serverInfo?.number == 1000)
        #expect(state.readyForStatementReceived() == .fireEventReadyForStatement)
    }

    @Test func errorWithoutACursorAfterRowCountsFailsTheStatement() {
        let promise = Self.discardedPromise()
        let insertContext = StatementContext(statement: "INSERT INTO t VALUES (1)", promise: promise)
        let backendError = Self.backendError(1000, cursorID: 0)

        var state = ConnectionStateMachine.readyForStatement()
        _ = state.enqueue(task: .statement(insertContext))
        #expect(state.queryParameterReceived(.init(schema: nil, edition: nil, rowCounts: [1])) == .wait)
        #expect(
            state.backendErrorReceived(backendError)
                == .failStatement(promise, with: .server(backendError), cleanupContext: nil, cursorID: nil)
        )
    }

    @Test func errorWhileStreamingClosesTheCursor() {
        let promise = Self.discardedPromise()
        var state = Self.streamingQuery(promise)
        let backendError = Self.backendError(1476, cursorID: 2)
        #expect(
            state.backendErrorReceived(backendError)
                == .forwardStreamError(.server(backendError), read: false, cursorID: 2, clientCancelled: false)
        )
        #expect(state.readyForStatementReceived() == .fireEventReadyForStatement)
    }

    // MARK: Cancellation

    /// Measured on Oracle 23ai: a fetch the client sent before it cancelled is still answered, here with
    /// its own error, and only then does ORA-01013, naming cursor 0, answer the cancellation.
    @Test func errorAfterCancellationWaitsForTheCancellationToComplete() {
        let promise = Self.discardedPromise()
        var state = Self.streamingQuery(promise)
        #expect(
            state.cancelStatementStream()
                == .forwardStreamError(.statementCancelled, read: false, cursorID: nil, clientCancelled: true)
        )
        #expect(state.statementStreamCancelled() == .sendMarker(read: true))
        #expect(state.backendErrorReceived(Self.backendError(1476, cursorID: 2)) == .wait)
        #expect(state.markerReceived() == .resetNetworkSecurity)
        #expect(state.backendErrorReceived(Self.backendError(1013, cursorID: 0)) == .forwardCancelComplete(cursorID: 2))
        #expect(state.readyForStatementReceived() == .fireEventReadyForStatement)
    }

    @Test func cancellationClosesTheCursorTheFetchInFlightNamed() {
        let promise = Self.discardedPromise()
        var state = Self.streamingQuery(promise)
        _ = state.cancelStatementStream()
        #expect(state.statementStreamCancelled() == .sendMarker(read: true))
        #expect(state.rowHeaderReceived(.init()) == .wait)
        #expect(state.rowDataReceived(.init(2), capabilities: .init()) == .wait)
        #expect(state.backendErrorReceived(.noData) == .wait)
        #expect(state.markerReceived() == .resetNetworkSecurity)
        #expect(state.backendErrorReceived(Self.backendError(1013, cursorID: 0)) == .forwardCancelComplete(cursorID: 1))
        #expect(state.readyForStatementReceived() == .fireEventReadyForStatement)
    }

    // MARK: Closing the connection

    /// The row stream held back a read while the consumer had not asked for rows. Closing must pass it
    /// on, or the reply to the logoff is never read and the close never completes.
    @Test func closingWhileStreamingFailsTheStreamAndClosesTheConnection() {
        let promise = Self.discardedPromise()
        var state = Self.streamingQuery(promise)
        let row: DataRow = .makeTestDataRow(1)
        #expect(state.rowDataReceived(.init(1), capabilities: .init()) == .wait)
        #expect(state.channelReadComplete() == .forwardRows([row]))
        #expect(state.readEventCaught() == .wait)

        let action = state.close(nil)
        guard case .forwardStreamError(let error, true, nil, false, let cleanup?) = action else {
            Issue.record("Expected the stream to fail and the connection to close, got \(action)")
            return
        }
        #expect(error.code == .clientClosedConnection)
        #expect(cleanup.action == .close)
    }

    @Test func describeInfoWhileStreamingClosesTheConnection() {
        let promise = Self.discardedPromise()
        var state = Self.streamingQuery(promise)
        Self.expectStreamClosedByUnexpectedMessage(state.describeInfoReceived(Self.varcharDescribeInfo))
    }

    @Test func duplicateColumnOnTheFirstRowClosesTheConnection() {
        let promise = Self.discardedPromise()
        var state = Self.streamingQuery(promise)
        Self.expectStreamClosedByUnexpectedMessage(
            state.rowDataReceived(.init(columns: [.duplicate(0)]), capabilities: .init())
        )
    }

    @Test func rowHeaderBeforeDescribeInfoClosesTheConnection() {
        let promise = Self.discardedPromise()
        var state = ConnectionStateMachine.readyForStatement()
        _ = state.enqueue(task: .statement(StatementContext(statement: "SELECT 1 FROM dual", promise: promise)))
        Self.expectStatementClosedByUnexpectedMessage(state.rowHeaderReceived(.init()))
    }

    @Test func rowDataWithMoreColumnsThanOutBindsClosesTheConnection() {
        let promise = Self.discardedPromise()
        var state = ConnectionStateMachine.readyForStatement()
        _ = state.enqueue(task: .statement(StatementContext(statement: "BEGIN NULL; END;", promise: promise)))
        Self.expectStatementClosedByUnexpectedMessage(state.rowDataReceived(.init(1), capabilities: .init()))
    }

    @Test func bindVectorWithTheWrongBindCountClosesTheConnection() {
        let promise = Self.discardedPromise()
        var state = ConnectionStateMachine.readyForStatement()
        _ = state.enqueue(task: .statement(StatementContext(statement: "BEGIN NULL; END;", promise: promise)))
        Self.expectStatementClosedByUnexpectedMessage(
            state.ioVectorReceived(.init(bindMetadata: [.init(index: 0, direction: 16)]))
        )
    }

    @Test func errorAfterTheStatementEndedClosesTheConnection() {
        let promise = Self.discardedPromise()
        let queryContext = StatementContext(statement: "SELECT 1/0 FROM dual", promise: promise)
        var state = ConnectionStateMachine.readyForStatement()
        _ = state.enqueue(task: .statement(queryContext))
        _ = state.backendErrorReceived(Self.backendError(1476, cursorID: 1))
        let action = state.backendErrorReceived(Self.backendError(1476, cursorID: 1))
        guard case .closeConnectionAndCleanup(let cleanup) = action else {
            Issue.record("Expected the connection to close, got \(action)")
            return
        }
        #expect(cleanup.error.code == .unexpectedBackendMessage)
    }

    // MARK: Helpers

    private static func discardedPromise() -> EventLoopPromise<OracleRowStream> {
        let promise = EmbeddedEventLoop().makePromise(of: OracleRowStream.self)
        promise.fail(OracleSQLError.uncleanShutdown)  // we don't care about the error at all.
        return promise
    }

    private static func backendError(_ number: UInt32, cursorID: UInt16?) -> BackendError {
        BackendError(
            number: number, cursorID: cursorID, position: 0, rowCount: 0, isWarning: false,
            message: number == 0 ? nil : "ORA-\(number)", rowID: nil, batchErrors: [])
    }

    /// A query whose first row header has arrived, so its consumer holds a row stream.
    private static func streamingQuery(_ promise: EventLoopPromise<OracleRowStream>) -> ConnectionStateMachine {
        let queryContext = StatementContext(statement: "SELECT 1 AS id FROM dual", promise: promise)
        var state = ConnectionStateMachine.readyForStatement()
        _ = state.enqueue(task: .statement(queryContext))
        _ = state.describeInfoReceived(Self.numberDescribeInfo)
        _ = state.rowHeaderReceived(.init())
        return state
    }

    private static func expectStreamClosedByUnexpectedMessage(
        _ action: ConnectionStateMachine.ConnectionAction,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard case .forwardStreamError(let error, _, nil, false, let cleanup?) = action else {
            Issue.record(
                "Expected the stream to fail and the connection to close, got \(action)",
                sourceLocation: sourceLocation
            )
            return
        }
        #expect(error.code == .unexpectedBackendMessage, sourceLocation: sourceLocation)
        #expect(cleanup.action == .close, sourceLocation: sourceLocation)
    }

    private static func expectStatementClosedByUnexpectedMessage(
        _ action: ConnectionStateMachine.ConnectionAction,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard case .failStatement(_, let error, let cleanup?, nil) = action else {
            Issue.record(
                "Expected the statement to fail and the connection to close, got \(action)",
                sourceLocation: sourceLocation
            )
            return
        }
        #expect(error.code == .unexpectedBackendMessage, sourceLocation: sourceLocation)
        #expect(cleanup.action == .close, sourceLocation: sourceLocation)
    }

    private static let numberDescribeInfo = DescribeInfo(columns: [
        .init(
            name: "ID",
            dataType: .number,
            dataTypeSize: 0,
            precision: 11,
            scale: 0,
            bufferSize: 22,
            nullsAllowed: true,
            typeScheme: nil,
            typeName: nil,
            domainSchema: nil,
            domainName: nil,
            annotations: [:],
            vectorDimensions: nil,
            vectorFormat: nil
        )
    ])

    private static let varcharDescribeInfo = DescribeInfo(columns: [
        .init(
            name: "COLUMN_VALUE",
            dataType: .varchar,
            dataTypeSize: 32767,
            precision: 0,
            scale: 0,
            bufferSize: 32767,
            nullsAllowed: true,
            typeScheme: nil,
            typeName: nil,
            domainSchema: nil,
            domainName: nil,
            annotations: [:],
            vectorDimensions: nil,
            vectorFormat: nil
        )
    ])
}
