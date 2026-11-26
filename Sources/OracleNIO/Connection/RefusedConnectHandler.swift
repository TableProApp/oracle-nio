//===----------------------------------------------------------------------===//
//
// This source file is part of the OracleNIO open source project
//
// Copyright (c) 2026 Timo Zacherl and the OracleNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE for license information
// See CONTRIBUTORS.md for the list of OracleNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if canImport(Network)
    import Network
    import NIOConcurrencyHelpers
    import NIOCore
    import NIOTransportServices

    // Network.framework keeps a connect it cannot complete waiting until the connect
    // timeout. That is right while a route may still appear, the Local Network prompt
    // among them, and wrong for a port nothing listens on, which a socket reports at once.
    final class RefusedConnectHandler: ChannelInboundHandler, RemovableChannelHandler, Sendable {
        typealias InboundIn = ByteBuffer

        private let refused: NIOLockedValueBox<Bool>

        init(refused: NIOLockedValueBox<Bool>) {
            self.refused = refused
        }

        func channelActive(context: ChannelHandlerContext) {
            context.fireChannelActive()
            context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
        }

        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if let waiting = event as? NIOTSNetworkEvents.WaitingForConnectivity,
                case .posix(let code) = waiting.transientError, code == .ECONNREFUSED
            {
                self.refused.withLockedValue { $0 = true }
                context.close(promise: nil)
                return
            }
            context.fireUserInboundEventTriggered(event)
        }
    }
#endif
