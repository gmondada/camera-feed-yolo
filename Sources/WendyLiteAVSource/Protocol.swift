import NIOCore

// ───────────────────────────────────────────────────────────────────────────
// Wire format
//
// Mirrors the device side, xiao-esp32s3-camera-stream/main/server.h. Every
// message is a 4 byte header followed by a payload, all multi-byte fields in
// network order:
//
//   offset 0: magic (kMagic)
//   offset 1: message type
//   offset 2: payload size (16 bits)
//
// Type 1, request, us to the device, 12 byte payload:
//
//   offset  0: channel
//   offset  1: number of frames (ignored by the device for now)
//   offset  2: reserved
//   offset  4: delay in microseconds since the last frame (ignored for now)
//   offset  8: request id, echoed back in every chunk of the frame
//
// Type 2, data, the device to us, 20 byte payload plus image data:
//
//   offset  0: channel
//   offset  1: last_chunk flag (1 bit) then chunk number (23 bits)
//   offset  4: frame number
//   offset  8: frame timestamp in microseconds
//   offset 12: host timestamp in microseconds
//   offset 16: request id
//   offset 20: image data
// ───────────────────────────────────────────────────────────────────────────

let kMagic: UInt8 = 0xAF
let kHeaderLength = 4
let kMaxMessageLength = 1_280

let kMessageTypeRequest: UInt8 = 1
let kMessageTypeData: UInt8 = 2

let kChannelVideo: UInt8 = 1

let kRequestPayloadLength = 12
let kDataHeaderLength = 20

// The top bit of the 24 bit word at offset 1 of a data payload.
let kLastChunkFlag: UInt32 = 0x80_0000
let kChunkNumberMask: UInt32 = 0x7F_FFFF

/// One framed message off the wire. The payload excludes the header.
struct AVMessage: Sendable {
    let type: UInt8
    var payload: ByteBuffer
}

// ───────────────────────────────────────────────────────────────────────────
// Decoder
// ───────────────────────────────────────────────────────────────────────────

// A ByteToMessageDecoder rather than hand-rolled buffering in the read loop:
// NIO already handles the partial-read bookkeeping, and a frame arrives as
// dozens of small messages so getting that wrong would be expensive.
struct AVMessageDecoder: ByteToMessageDecoder {
    typealias InboundOut = AVMessage

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let header = buffer.getBytes(at: buffer.readerIndex, length: kHeaderLength) else {
            return .needMoreData
        }
        guard header[0] == kMagic else {
            throw AVSourceError.invalidMagic(header[0])
        }

        let payloadLength = Int(header[2]) << 8 | Int(header[3])
        guard payloadLength <= kMaxMessageLength - kHeaderLength else {
            // Nothing we can resynchronize on, the stream is lost.
            throw AVSourceError.payloadTooLarge(payloadLength)
        }
        guard buffer.readableBytes >= kHeaderLength + payloadLength else {
            return .needMoreData
        }

        buffer.moveReaderIndex(forwardBy: kHeaderLength)
        let payload = buffer.readSlice(length: payloadLength)!
        context.fireChannelRead(wrapInboundOut(AVMessage(type: header[1], payload: payload)))
        return .continue
    }
}

// ───────────────────────────────────────────────────────────────────────────
// Encoder
// ───────────────────────────────────────────────────────────────────────────

// Builds a type 1 message asking for a single video frame. The device ignores
// the frame count and the delay today, so they are pinned at 1 and 0.
func makeVideoRequest(requestID: UInt32, allocator: ByteBufferAllocator) -> ByteBuffer {
    var buffer = allocator.buffer(capacity: kHeaderLength + kRequestPayloadLength)
    buffer.writeInteger(kMagic)
    buffer.writeInteger(kMessageTypeRequest)
    buffer.writeInteger(UInt16(kRequestPayloadLength))
    buffer.writeInteger(kChannelVideo)
    buffer.writeInteger(UInt8(1))
    buffer.writeInteger(UInt16(0))
    buffer.writeInteger(UInt32(0))
    buffer.writeInteger(requestID)
    return buffer
}
