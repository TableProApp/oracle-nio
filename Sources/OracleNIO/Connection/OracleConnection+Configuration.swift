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
import NIOPosix
import NIOSSL

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

#if DistributedTracingSupport
    import Tracing
#endif

extension OracleConnection {
    /// A configuration object for a connection.
    public struct Configuration: Sendable {

        // MARK: - TLS

        /// The possible modes of operation for TLS encapsulation of a connection.
        public struct TLS: Sendable {

            /// Do not try to create a TLS connection to the server.
            @inlinable
            public static var disable: Self { .init(.disable) }

            /// Try to create a TLS connection to the server.
            ///
            /// If the server supports TLS, create a TLS connection. If the server does not support TLS,
            /// fail the connection creation.
            @inlinable
            public static func require(_ sslContext: NIOSSLContext) -> Self {
                self.init(.require(sslContext))
            }

            @inlinable
            public var sslContext: NIOSSLContext? {
                switch self.base {
                case .disable: return nil
                case .require(let context): return context
                }
            }

            @usableFromInline
            enum Base: Sendable {
                case disable
                case require(NIOSSLContext)
            }
            @usableFromInline
            let base: Base

            @usableFromInline
            init(_ base: Base) { self.base = base }
        }

        // MARK: - Underlying connection options

        /// Describes options affecting how the underlying connection is made.
        public struct Options: Sendable {
            /// A timeout for connection attempts. Defaults to ten seconds.
            ///
            /// - Note: This bounds the TCP connect alone. Everything after it, the TNS
            ///         accept, the advanced negotiation, protocol and datatype
            ///         negotiation and authentication, is bounded by ``loginTimeout``.
            public var connectTimeout: TimeAmount

            /// A timeout for the login handshake, measured from the moment the channel
            /// becomes active until authentication completes. Defaults to thirty seconds.
            ///
            /// Without it a server that accepts the connection and then answers nothing
            /// leaves the login waiting for as long as the server keeps the socket open,
            /// because the handshake is driven by replies rather than by polling. Set it
            /// to `nil` to wait indefinitely.
            public var loginTimeout: TimeAmount?

            /// The server name to use for certificate validation and SNI (Server Name Indication) when
            /// TLS is enabled.
            ///
            /// Defaults to none (but see below).
            ///
            /// > When set to `nil`:
            /// If the connection is made to a server over TCP using
            /// ``OracleConnection/Configuration/init(host:port:service:username:password:tls:)``,
            /// the given `host` is used, unless it was an IP address string. If it _was_ an IP, or the
            /// connection is made by any other method, SNI is disabled.
            public var tlsServerName: String?

            /// Create an options structure with default values.
            ///
            /// Most users should not need to adjust the defaults.
            public init() {
                self.connectTimeout = .seconds(10)
                self.loginTimeout = .seconds(30)
            }
        }

        // MARK: Oracle connection options

        enum OracleProtocol: CustomStringConvertible {
            /// Unencrypted network traffic.
            case tcp
            /// Encrypted network traffic via TLS.
            case tcps

            var description: String {
                switch self {
                case .tcp:
                    return "tcp"
                case .tcps:
                    return "tcps"
                }
            }
        }

        public var options: Options = .init()

        /// The name or IP address of the machine hosting the database or the database listener.
        public var host: String {
            get {
                switch self.endpointInfo {
                case .configureChannel(let channel):
                    channel.localAddress?.ipAddress ?? ""
                case .connectTCP(let host, _):
                    host
                }
            }
            set {
                switch self.endpointInfo {
                case .configureChannel:
                    break  // not part of public api
                case .connectTCP(_, let port):
                    self.endpointInfo = .connectTCP(host: newValue, port: port)
                }
            }
        }
        /// The port number on which the database listener is listening.
        public var port: Int {
            get {
                switch self.endpointInfo {
                case .configureChannel(let channel):
                    channel.localAddress?.port ?? 1521
                case .connectTCP(_, let port):
                    port
                }
            }
            set {
                switch self.endpointInfo {
                case .configureChannel:
                    break  // not part of public api
                case .connectTCP(let host, _):
                    self.endpointInfo = .connectTCP(host: host, port: newValue)
                }
            }
        }

        public var tls: TLS
        public var serverNameForTLS: String? {
            // If a name was explicitly configured always use it.
            if let tlsServerName = options.tlsServerName {
                return tlsServerName
            }

            // Otherwise, if the hostname wasn't an IP use that.
            if !host.isIPAddress() { return host }

            // Otherwise disable SNI
            return nil
        }
        /// The protocol used to send network traffic.
        internal var _protocol: OracleProtocol {
            switch self.tls.base {
            case .disable: return .tcp
            case .require: return .tcps
            }
        }

        /// The name of the proxy user to connect to.
        public var proxyUser: String?

        /// The authentication variant used to connect to the database.
        ///
        /// It is defined as a closure to ensure we'll have an up-to-date token for establishing future
        /// connections if token based authentication is used.
        public var authenticationMethod: @Sendable () -> OracleAuthenticationMethod

        public var service: OracleServiceMethod

        /// Authorization mode to use.
        public var mode: AuthenticationMode = .default

        /// Boolean indicating whether out-of-band breaks should be disabled.
        ///
        /// - Note: Windows does not support this functionality at all.
        public var disableOOB: Bool = false

        /// The client's Oracle native network encryption and data-integrity level for
        /// the connect handshake.
        ///
        /// Defaults to ``NativeNetworkEncryptionLevel/accepted``, matching Oracle's own
        /// clients (JDBC thin, SQL Developer): the client offers encryption but does not
        /// insist on it, so a server that merely accepts encryption stays in clear text
        /// while a server that requires it negotiates AES. This is what lets the driver
        /// connect to `SQLNET.ENCRYPTION_SERVER = REQUIRED` servers without extra setup.
        public var nativeNetworkEncryption: NativeNetworkEncryptionLevel = .accepted

        /// Whether a TNS redirect from the listener, as a RAC SCAN listener, a shared
        /// server or Connection Manager sends, is followed to the address it names.
        /// Turn it off when ``host`` is a forward that only reaches the first listener:
        /// the redirect then fails with an ``OracleRedirectError`` naming the target.
        public var followsListenerRedirects: Bool = true

        /// A string with the format `host=<host>;port=<port>` that specifies the host and port of
        /// the PL/SQL debugger.
        public var debugJDWP: String?

        /// By default the timezone for the established session will be set to the client's (our) current
        /// timezone, provide a custom timezone if you want to set the timezone to something other than
        /// the one of the system.
        public var customTimezone: TimeZone?

        /// Prefix for the connection id sent to the database server.
        ///
        /// - Note: This has nothing to do with ``OracleConnection/id-property``. This
        ///         prefix can be used to identify the connection on the oracle server. It will be
        ///         sanitized.
        public var connectionIDPrefix: String {
            get { _connectionIDPrefix }
            set { _connectionIDPrefix = sanitize(value: newValue) }
        }
        private var _connectionIDPrefix: String = "" {
            didSet {
                self.connectionID = sanitize(
                    value: self._connectionIDPrefix
                        + Data([UInt8].random(count: 16)).base64EncodedString()
                )
            }
        }

        /// The number of tries that a connection attempt
        /// should be retried before the attempt is terminated.
        ///
        /// Defaults to `0`.
        public var retryCount: Int = 0

        /// The number of seconds to wait before making a new connection attempt.
        ///
        /// Defaults to `0`.
        public var retryDelay: Int = 0

        /// Connection ID on the oracle server.
        public private(set) var connectionID: String = ""

        /// The name of the process, sent to the oracle server upon connection.
        ///
        /// Defaults to the name of the current process.
        ///
        /// - Note: The value set here will be sanitized.
        public var programName: String {
            get { _programName }
            set { _programName = sanitize(value: newValue) }
        }
        private var _programName: String = sanitize(
            value: ProcessInfo.processInfo.processName
        )
        /// The name of the machine, sent to the oracle server upon connection.
        ///
        /// Defaults to the hostname of your system.
        ///
        /// - Note: The value set here will be sanitized.
        public var machineName: String {
            get { _machineName }
            set { _machineName = sanitize(value: newValue) }
        }
        private var _machineName: String = sanitize(
            value: ProcessInfo.processInfo.hostName
        )
        /// The process ID, sent to the oracle server upon connection.
        ///
        /// Defaults to the current process ID.
        var pid = ProcessInfo.processInfo.processIdentifier
        /// The name of the user running the process, sent to the oracle server upon connection.
        ///
        /// Defaults to the user running the current process.
        ///
        /// - Note: The value set here will be sanitized.
        public var processUsername: String {
            get { _processUsername }
            set { _processUsername = sanitize(value: newValue) }
        }
        private var _processUsername = sanitize(
            value: defaultUsername()
        )
        private static func defaultUsername() -> String {
            #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
                return "unknown"
            #else
                return ProcessInfo.processInfo.userName
            #endif
        }
        internal let _terminalName = "unknown"

        #if DistributedTracingSupport
            /// The distributed tracing configuration to use for this connection.
            /// Defaults to using the globally bootstrapped tracer with OpenTelementry
            /// semantic conventions.
            public var tracing: OracleTracingConfiguration = .init()
        #endif


        // MARK: - Connection Pooling
        internal var purity: Purity = .default
        internal var serverType: String?
        internal var drcpEnabled = false
        internal var cclass: String?

        public init(
            host: String,
            port: Int = 1521,
            service: OracleServiceMethod,
            username: String,
            password: String,
            tls: TLS = .disable
        ) {
            self.endpointInfo = .connectTCP(
                host: host,
                port: port
            )
            self.service = service
            self.authenticationMethod = {
                .init(username: username, password: password)
            }
            self.tls = tls
        }

        public init(
            host: String,
            port: Int = 1521,
            service: OracleServiceMethod,
            authenticationMethod:
                @Sendable @autoclosure @escaping () -> OracleAuthenticationMethod,
            tls: TLS = .disable
        ) {
            self.endpointInfo = .connectTCP(
                host: host,
                port: port
            )
            self.service = service
            self.authenticationMethod = authenticationMethod
            self.tls = tls
        }

        init(
            establishedChannel channel: Channel,
            service: OracleServiceMethod,
            username: String,
            password: String
        ) {
            self.endpointInfo = .configureChannel(channel)
            self.service = service
            self.authenticationMethod = {
                .init(username: username, password: password)
            }
            self.tls = .disable
        }


        // MARK: - Implementation details

        enum EndpointInfo {
            case configureChannel(Channel)
            case connectTCP(host: String, port: Int)
        }

        var endpointInfo: EndpointInfo

        internal func getDescription() -> Description {
            let address = Address(
                protocol: self._protocol, host: self.host, port: self.port
            )
            let addressList = AddressList(addresses: [address])
            let desc = Description(
                connectionID: self.connectionID,
                addressLists: [addressList],
                sourceRoute: false,
                loadBalance: false,
                retryCount: self.retryCount,
                retryDelay: self.retryDelay,
                tcpConnectTimeout: self.options.connectTimeout,
                service: self.service,
                sslServerDnMatch: self.serverNameForTLS != nil,
                sslServerCertDn: nil,
                walletLocation: nil,
                purity: self.purity,
                serverType: self.serverType,
                cclass: self.cclass
            )
            return desc
        }

        // The descriptor a redirecting listener handed back. It names the instance and
        // the server type the listener chose, so it is sent as is, never rebuilt.
        internal var redirectConnectString: String?

        // Set on every hop after a redirect. The listener refuses a CONNECT carrying the
        // redirect flag rather than redirecting it again, which stops a loop.
        internal var isRedirected = false

        // When the whole connect has to be over, dial and login of every hop included.
        internal var loginDeadline: NIODeadline?

        internal var dialTimeout: TimeAmount {
            guard let loginDeadline else { return self.options.connectTimeout }
            return max(.milliseconds(1), min(self.options.connectTimeout, loginDeadline - .now()))
        }

        // Only a listener reached on this machine has a reason to send the client back to
        // it. The check runs on the address the hop actually connected to, so no spelling
        // of a loopback address and no name that resolves to one gets past it.
        internal var allowsLocalPeer = true

        internal var connectPacketFlags: UInt8 {
            self.isRedirected ? Constants.TNS_PACKET_FLAG_REDIRECT : 0
        }

        internal func getConnectString() -> String {
            if let redirectConnectString { return redirectConnectString }
            let description = self.getDescription()
            let cid = """
                (PROGRAM=\(self.programName))\
                (HOST=\(self.machineName))\
                (USER=\(self.processUsername))
                """
            return description.buildConnectString(cid)
        }

        /// This configuration pointed at the address a TNS redirect names. Throws an
        /// ``OracleRedirectError`` when the redirect cannot be followed.
        internal func followingRedirect(
            _ redirect: OracleBackendMessage.Redirect
        ) throws -> OracleConnection.Configuration {
            guard self.followsListenerRedirects, case .connectTCP = self.endpointInfo else {
                throw OracleRedirectError(reason: .notFollowed, redirect: redirect)
            }
            // Before the ACCEPT a packet's length is 16 bits, so a descriptor that does not
            // fit one DATA packet cannot be sent.
            let longestConnectData =
                Int(UInt16.max) - OracleFrontendMessageEncoder.headerSize - MemoryLayout<UInt16>.size
            // The descriptor goes out as the next CONNECT's payload, so a listener must not
            // be able to put line breaks or other control bytes in front of whatever
            // answers at the address it names.
            let descriptor = redirect.address + (redirect.connectData ?? "")
            guard let target = redirect.target,
                (redirect.connectData?.utf8.count ?? 0) <= longestConnectData,
                !descriptor.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
            else {
                throw OracleRedirectError(reason: .unreadable, redirect: redirect)
            }
            // A dispatcher configured on HOST=0.0.0.0 hands that back as is, and dialing it
            // reaches this machine, not the server.
            if ["0.0.0.0", "::", "[::]"].contains(target.host) {
                throw OracleRedirectError(reason: .targetUnreachable, redirect: redirect)
            }
            // A TCPS hop keeps its TLS whatever the redirect says, so only plain TCP told
            // to go to a TCPS address is refused; it would never get past the handshake.
            if redirect.usesTCPS, self._protocol == .tcp {
                throw OracleRedirectError(reason: .transportMismatch, redirect: redirect)
            }

            var copy = self
            copy.endpointInfo = .connectTCP(host: target.host, port: target.port)
            // A second listener can name an address and nothing else; the descriptor the
            // first one handed back still names the instance it chose.
            copy.redirectConnectString = redirect.connectData ?? self.redirectConnectString
            copy.isRedirected = true
            // Decided once, from the address the user entered, and kept for every hop.
            copy.allowsLocalPeer = self.isRedirected ? self.allowsLocalPeer : self.host.isLocalHost
            return copy
        }
    }
}

// originally taken from NIOSSL
extension String {
    fileprivate var isLocalHost: Bool {
        if self.lowercased() == "localhost" { return true }
        return (try? SocketAddress(ipAddress: self, port: 0))?.isOnThisMachine ?? false
    }

    fileprivate func isIPAddress() -> Bool {
        // We need some scratch space to let inet_pton write into.
        var ipv4Addr = in_addr()
        var ipv6Addr = in6_addr()
        // inet_pton() assumes the provided address buffer is non-NULL

        /// N.B.: ``String/withCString(_:)`` is much more efficient than directly passing
        /// `self`, especially twice.
        return self.withCString { ptr in
            inet_pton(AF_INET, ptr, &ipv4Addr) == 1 || inet_pton(AF_INET6, ptr, &ipv6Addr) == 1
        }
    }
}

private func sanitize(value: String) -> String {
    return value.replacing(/\(|\)|\=/, with: "?")
}

public struct OracleAccessToken: Sendable, Equatable {
    let base: Base

    enum Base: Sendable, Equatable {
        case oAuth2(String)
        case tokenAndPrivateKey(token: String, key: String)
    }

    /// Allows to use OAuth 2.0 tokens managed in a Microsoft Entry ID service.
    public static func oAuth2(with token: String) -> OracleAccessToken {
        self.init(base: .oAuth2(token))
    }
    /// Specifies the token and private key strings used for Oracle Cloud Infrastructure (OCI)
    /// Identity and Access Management (IAM) token based authentication.
    public static func tokenAndPrivateKey(token: String, key: String) -> OracleAccessToken {
        self.init(base: .tokenAndPrivateKey(token: token, key: key))
    }
}

public struct OracleAuthenticationMethod: Sendable, Equatable, CustomDebugStringConvertible {
    let base: Base

    enum Base: Sendable, Equatable {
        case usernamePassword(String, String, String?)
        case token(OracleAccessToken)
    }

    /// Authenticate with username and password.
    /// - Parameters:
    ///   - username: The name of the user to connect to.
    ///   - password: The password for the user.
    ///   - newPassword: If set, the new password will take effect immediately upon a
    ///                  successful connection to the database.
    public init(
        username: String, password: String, newPassword: String? = nil
    ) {
        self.base = .usernamePassword(username, password, newPassword)
    }

    /// Authenticate with access token.
    /// - Parameter token: The access token can be one of ``OracleAccessToken``.
    public init(token: OracleAccessToken) {
        self.base = .token(token)
    }

    public var debugDescription: String {
        switch self.base {
        case .usernamePassword(let username, _, let newPassword):
            return """
                OracleAuthenticationMethod(username: \(String(reflecting: username)), \
                password: ********, \
                newPassword: \(newPassword != nil ? "********" : "nil"))
                """
        case .token:
            return "OracleAuthenticationMethod(token: ********)"
        }
    }

}

public struct OracleServiceMethod: Sendable, Equatable {
    let base: Base

    enum Base: Sendable, Equatable {
        case serviceName(String)
        case sid(String)
    }

    /// The service name of the database.
    public static func serviceName(_ value: String) -> OracleServiceMethod {
        self.init(base: .serviceName(value))
    }

    /// The system identifier (SID) of the database.
    ///
    /// - Note: Using a ``serviceName(_:)`` instead is recommended by Oracle.
    public static func sid(_ value: String) -> OracleServiceMethod {
        self.init(base: .sid(value))
    }
}

#if DistributedTracingSupport
    /// A configuration object that defines distributed tracing behavior of an Oracle connection.
    public struct OracleTracingConfiguration: Sendable {
        /// The tracer to use, or `nil` to disable tracing.
        /// Defaults to the globally bootstrapped tracer.
        public var tracer: (any Tracer)? = InstrumentationSystem.tracer

        /// The attribute names used in spans created by OracleNIO. Defaults to OpenTelemetry semantics.
        public var attributeNames: AttributeNames = .init()

        /// The static attribute values used in spans created by OracleNIO.
        public var attributeValues: AttributeValues = .init()

        /// Attribute names used in spans created by OracleNIO.
        public struct AttributeNames: Sendable {
            public var databaseNamespace: String = "db.namespace"
            public var databaseResponseStatusCode: String = "db.response.status_code"
            public var errorType: String = "error.type"
            public var serverPort: String = "server.port"
            public var databaseCollectionName: String = "db.collection.name"
            public var databaseOperationBatchSize: String = "db.operation.batch.size"
            public var databaseOperationName: String = "db.operation.name"
            public var databaseQuerySummary: String = "db.query.summary"
            public var databaseQueryText: String = "db.query.text"
            public var databaseStoredProcedureName: String = "db.stored_procedure.name"
            public var serverAddress: String = "server.address"
            public var databaseQueryParameterPrefix: String = "db.query.parameter."
            public var databaseResponseReturnedRows: String = "db.response.returned_rows"
        }

        /// Static attribute values used in spans created by OracleNIO.
        public struct AttributeValues: Sendable {
            public var databaseSystem: String = "oracle.db"
        }
    }
#endif

extension SocketAddress {
    // Loopback in any spelling, IPv4-mapped included, and the 0.0.0.0/8 a connect to the
    // unspecified address lands on.
    var isOnThisMachine: Bool {
        switch self {
        case .v4(let address):
            let first = UInt32(bigEndian: address.address.sin_addr.s_addr) >> 24
            return first == 127 || first == 0
        case .v6(let address):
            var raw = address.address.sin6_addr
            let bytes = withUnsafeBytes(of: &raw) { Array($0) }
            if bytes[0..<15].allSatisfy({ $0 == 0 }) && (bytes[15] == 1 || bytes[15] == 0) {
                return true
            }
            let mapped = bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF
            return mapped && (bytes[12] == 127 || bytes[12] == 0)
        case .unixDomainSocket:
            return true
        }
    }
}
