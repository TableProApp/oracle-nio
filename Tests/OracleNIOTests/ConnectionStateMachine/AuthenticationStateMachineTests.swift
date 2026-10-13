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

import Testing

@testable import OracleNIO

@Suite(.timeLimit(.minutes(5))) struct AuthenticationStateMachineTests {
    @Test func fastAuthHappyPath() {
        var capabilities = Capabilities()
        capabilities.supportsFastAuth = true
        capabilities.protocolVersion = Constants.TNS_VERSION_DESIRED
        let accept = OracleBackendMessage.Accept(newCapabilities: capabilities)
        let description = Description(
            connectionID: "1",
            addressLists: [],
            service: .serviceName("service_name"),
            sslServerDnMatch: false,
            purity: .default
        )
        let authContext = AuthContext(
            method: .init(username: "test", password: "pasword123"),
            service: .serviceName("service_name"),
            terminalName: "",
            programName: "",
            machineName: "",
            pid: 1,
            processUsername: "",
            mode: .default,
            description: description
        )

        var state = ConnectionStateMachine()

        #expect(state.connected() == .sendConnect)
        #expect(state.acceptReceived(accept, description: description) == .provideAuthenticationContext(.allowed))
        #expect(state.provideAuthenticationContext(authContext, fastAuth: .allowed) == .sendFastAuth(authContext))
        #expect(state.protocolReceived(.init(newCapabilities: capabilities)) == .wait)
        #expect(state.dataTypesReceived(.init()) == .wait)
        #expect(
            state.parameterReceived(parameters: .init([:])) == .sendAuthenticationPhaseTwo(authContext, .init([:])))
        #expect(state.parameterReceived(parameters: [:]) == .authenticated([:]))
    }

    @Test func authHappyPath() {
        var capabilities = Capabilities()
        capabilities.protocolVersion = Constants.TNS_VERSION_DESIRED
        let accept = OracleBackendMessage.Accept(newCapabilities: capabilities)
        let description = Description(
            connectionID: "1",
            addressLists: [],
            service: .serviceName("service_name"),
            sslServerDnMatch: false,
            purity: .default
        )
        let authContext = AuthContext(
            method: .init(username: "test", password: "pasword123"),
            service: .serviceName("service_name"),
            terminalName: "",
            programName: "",
            machineName: "",
            pid: 1,
            processUsername: "",
            mode: .default,
            description: description
        )

        var state = ConnectionStateMachine()

        #expect(state.connected() == .sendConnect)
        #expect(state.acceptReceived(accept, description: description) == .sendProtocol)
        #expect(state.protocolReceived(.init(newCapabilities: capabilities)) == .sendDataTypes)
        #expect(state.dataTypesReceived(.init()) == .provideAuthenticationContext(.denied))
        #expect(
            state.provideAuthenticationContext(authContext, fastAuth: .denied)
                == .sendAuthenticationPhaseOne(authContext)
        )
        #expect(
            state.parameterReceived(parameters: .init([:])) == .sendAuthenticationPhaseTwo(authContext, .init([:])))
        #expect(state.parameterReceived(parameters: [:]) == .authenticated([:]))
    }

    /// ORA-28002 (ORA-28098 on 26ai) leaves the login successful, so the warning rides along with it.
    @Test func warningDuringLoginReachesTheAuthenticatedConnection() {
        var capabilities = Capabilities()
        capabilities.protocolVersion = Constants.TNS_VERSION_DESIRED
        let accept = OracleBackendMessage.Accept(newCapabilities: capabilities)
        let description = Description(
            connectionID: "1",
            addressLists: [],
            service: .serviceName("service_name"),
            sslServerDnMatch: false,
            purity: .default
        )
        let authContext = AuthContext(
            method: .init(username: "test", password: "pasword123"),
            service: .serviceName("service_name"),
            terminalName: "",
            programName: "",
            machineName: "",
            pid: 1,
            processUsername: "",
            mode: .default,
            description: description
        )
        let warning = BackendError(
            number: 28002,
            rowCount: 0,
            isWarning: true,
            message: "ORA-28002: the password will expire within 7 days",
            batchErrors: []
        )

        var state = ConnectionStateMachine()

        #expect(state.connected() == .sendConnect)
        #expect(state.acceptReceived(accept, description: description) == .sendProtocol)
        #expect(state.protocolReceived(.init(newCapabilities: capabilities)) == .sendDataTypes)
        #expect(state.dataTypesReceived(.init()) == .provideAuthenticationContext(.denied))
        #expect(
            state.provideAuthenticationContext(authContext, fastAuth: .denied)
                == .sendAuthenticationPhaseOne(authContext)
        )
        #expect(
            state.parameterReceived(parameters: .init([:])) == .sendAuthenticationPhaseTwo(authContext, .init([:])))
        #expect(state.warningReceived(warning) == .wait)
        let empty = BackendError(number: 0, rowCount: 0, isWarning: true, message: nil, batchErrors: [])
        #expect(state.warningReceived(empty) == .wait)
        #expect(state.parameterReceived(parameters: [:]) == .authenticated([:], warning: warning))

        // A warning on an open connection is not a login warning and changes nothing.
        #expect(state.warningReceived(warning) == .wait)
    }

    /// Only fast authentication expects protocol and data types replies during the login. Anywhere else
    /// they used to be a precondition failure, so a server out of step ended the host process.
    @Test func negotiationReplyOutsideFastAuthClosesTheConnection() {
        var capabilities = Capabilities()
        capabilities.protocolVersion = Constants.TNS_VERSION_DESIRED
        let accept = OracleBackendMessage.Accept(newCapabilities: capabilities)
        let description = Description(
            connectionID: "1",
            addressLists: [],
            service: .serviceName("service_name"),
            sslServerDnMatch: false,
            purity: .default
        )
        let authContext = AuthContext(
            method: .init(username: "test", password: "pasword123"),
            service: .serviceName("service_name"),
            terminalName: "",
            programName: "",
            machineName: "",
            pid: 1,
            processUsername: "",
            mode: .default,
            description: description
        )

        for reply: (inout ConnectionStateMachine) -> ConnectionStateMachine.ConnectionAction in [
            { $0.protocolReceived(.init(newCapabilities: capabilities)) },
            { $0.dataTypesReceived(.init()) },
        ] {
            var state = ConnectionStateMachine()
            #expect(state.connected() == .sendConnect)
            #expect(state.acceptReceived(accept, description: description) == .sendProtocol)
            #expect(state.protocolReceived(.init(newCapabilities: capabilities)) == .sendDataTypes)
            #expect(state.dataTypesReceived(.init()) == .provideAuthenticationContext(.denied))
            #expect(
                state.provideAuthenticationContext(authContext, fastAuth: .denied)
                    == .sendAuthenticationPhaseOne(authContext)
            )
            guard case .closeConnectionAndCleanup(let cleanup) = reply(&state) else {
                Issue.record("Expected the connection to be closed")
                continue
            }
            #expect(cleanup.error.code == .unexpectedBackendMessage)
            #expect(cleanup.action == .closeImmediately)
        }
    }
}
