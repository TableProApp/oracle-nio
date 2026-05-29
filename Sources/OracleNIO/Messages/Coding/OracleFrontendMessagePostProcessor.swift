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

final class OracleFrontendMessagePostProcessor: ChannelOutboundHandler {
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let headerSize = OracleFrontendMessageEncoder.headerSize
    private let dataFlagsSize = MemoryLayout<UInt16>.size

    var protocolVersion: UInt16 = 0
    var maxSize = Int(Constants.TNS_SDU)
    private let securityBox: OracleNetworkSecurityBox

    init(securityBox: OracleNetworkSecurityBox = OracleNetworkSecurityBox()) {
        self.securityBox = securityBox
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        var buffer = self.unwrapOutboundIn(data)

        // Once native network encryption is active, encrypt and checksum the
        // data-packet body (after the 8-byte header and 2-byte data flags) before
        // framing, so the segmentation below sees the protected payload.
        if self.securityBox.isActive,
            buffer.readableBytes > self.headerSize,
            let packetTypeByte = buffer.getInteger(
                at: MemoryLayout<UInt32>.size, as: UInt8.self
            ),
            packetTypeByte == PacketType.data.rawValue
        {
            do {
                buffer = try self.encryptDataPacket(buffer, allocator: context.channel.allocator)
            } catch {
                promise?.fail(error)
                context.fireErrorCaught(error)
                return
            }
        }

        if buffer.readableBytes > maxSize {
            var temporaryBuffer = context.channel.allocator
                .buffer(capacity: maxSize)
            temporaryBuffer.moveWriterIndex(forwardBy: self.headerSize)

            let packetType =
                buffer
                .getInteger(at: MemoryLayout<UInt32>.size, as: UInt8.self)!
            let packetFlags =
                buffer
                .getInteger(
                    at: MemoryLayout<UInt32>.size + MemoryLayout<UInt8>.size,
                    as: UInt8.self
                ) ?? 0

            // ignore the header, because we need to create a new one for each
            // slice with the size of the slice.
            buffer.moveReaderIndex(to: self.headerSize)


            let maxContentSize =
                self.maxSize - self.headerSize - self.dataFlagsSize
            var first = true
            while buffer.readableBytes > 0 {
                var slice: ByteBuffer
                let final: Bool
                if buffer.readableBytes > maxContentSize {
                    slice = buffer.readSlice(
                        length: first ? maxContentSize + dataFlagsSize : maxContentSize
                    )!
                    final = false
                } else {
                    slice = buffer.readSlice(length: buffer.readableBytes)!
                    final = true
                }
                first = false
                temporaryBuffer.writeBuffer(&slice)
                temporaryBuffer.prepareSend(
                    packetTypeByte: packetType,
                    packetFlags: packetFlags,
                    protocolVersion: self.protocolVersion
                )
                context.writeAndFlush(
                    self.wrapOutboundOut(temporaryBuffer), promise: nil
                )
                if !final {
                    temporaryBuffer.clear(minimumCapacity: maxSize)
                    temporaryBuffer.moveWriterIndex(forwardBy: headerSize)
                    // add data flags for continuation packet
                    temporaryBuffer.writeInteger(UInt16(0))
                }
            }
        }

        context.writeAndFlush(self.wrapOutboundOut(buffer), promise: nil)
    }

    /// Encrypts the body of an already-framed data packet. The header and the
    /// 2-byte data flags stay in clear; the rest is protected and the length is
    /// rewritten to account for the cipher padding and checksum growth.
    private func encryptDataPacket(
        _ buffer: ByteBuffer, allocator: ByteBufferAllocator
    ) throws -> ByteBuffer {
        var source = buffer
        source.moveReaderIndex(to: self.headerSize)
        guard let dataFlags = source.readInteger(as: UInt16.self) else {
            return buffer
        }
        let body = source.readBytes(length: source.readableBytes) ?? []
        let protected = try self.securityBox.protect(body)

        var output = allocator.buffer(
            capacity: self.headerSize + self.dataFlagsSize + protected.count
        )
        output.moveWriterIndex(forwardBy: self.headerSize)
        output.writeInteger(dataFlags)
        output.writeBytes(protected)
        output.prepareSend(packetType: .data, protocolVersion: self.protocolVersion)
        return output
    }

}
