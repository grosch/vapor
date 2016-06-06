public protocol InputBuffer {
    associatedtype Element
    mutating func next() throws -> Element?
}

extension IndexingIterator: InputBuffer {}
extension AnyIterator: InputBuffer {}
extension StreamBuffer: InputBuffer {}
extension Array: InputBuffer {
    public mutating func next() -> Element? {
        guard !isEmpty else { return nil }
        return removeFirst()
    }
}

public final class FrameDeserializer<Buffer: InputBuffer where Buffer.Element == Byte> {
    private var buffer: Buffer

    public init(buffer: Buffer) {
        self.buffer = buffer
    }

    public func acceptFrame() throws -> WebSock.Frame {
        let (fin, rsv1, rsv2, rsv3, opCode) = try extractByteZero()
        let (isMasked, payloadLengthInfo) = try extractByteOne()

        /**
         Returns UInt64 to encompass highest possible length. Length may be UInt16
         */
        let payloadLength: UInt64
        switch payloadLengthInfo {
        case Byte.twoBytePayloadLength:
            payloadLength = try extractTwoBytePayloadLengthExtension().toUIntMax()
        case Byte.eightBytePayloadLength:
            payloadLength = try extractEightBytePayloadLengthExtension()
        default:
            payloadLength = payloadLengthInfo.toUIntMax()
        }

        let maskingKey: MaskingKey
        if isMasked {
            maskingKey = try extractMaskingKey()
        } else {
            maskingKey = .none
        }

        let payload = try extractPayload(key: maskingKey, length: payloadLength)
        guard payload.count == Int(payloadLength) else {
            throw "598: WebSockets.Swift: FrameDeserializer"
        }

        let header = WebSock.Frame.Header(
            fin: fin,
            rsv1: rsv1,
            rsv2: rsv2,
            rsv3: rsv3,
            opCode: opCode,
            isMasked: isMasked,
            payloadLength: payloadLength,
            maskingKey: maskingKey
        )
        return WebSock.Frame(header: header, payload: Data(payload))
    }

    // MARK: Private
    
    private func extractByteZero() throws -> (fin: Bool, rsv1: Bool, rsv2: Bool, rsv3: Bool, opCode: WebSock.Frame.OpCode) {
        guard let byteZero = try buffer.next() else {
            throw "No next byte"
        }
        let fin = byteZero.containsMask(.finFlag)
        let rsv1 = byteZero.containsMask(.rsv1Flag)
        let rsv2 = byteZero.containsMask(.rsv2Flag)
        let rsv3 = byteZero.containsMask(.rsv3Flag)

        let opCode = try WebSock.Frame.OpCode(byteZero & .opCodeFlag)
        return (fin, rsv1, rsv2, rsv3, opCode)
    }

    private func extractByteOne() throws -> (maskKeyIncluded: Bool, payloadLength: Byte) {
        guard let byteOne = try buffer.next() else {
            throw "493: WebSockets.Swift: FrameDeserializer"
        }
        let maskKeyIncluded = byteOne.containsMask(.maskKeyIncludedFlag)
        let payloadLength = byteOne & .payloadLengthFlag
        return (maskKeyIncluded, payloadLength)
    }

    private func extractExtendedPayloadLength(_ length: PayloadLengthExtension) throws -> UInt16 {
        var bytes: [Byte] = []
        for _ in 1...length.rawValue {
            guard let next = try buffer.next() else {
                throw "522: WebSockets.Swift: FrameDeserializer"
            }
            bytes.append(next)
        }
        return try UInt16.init(bytes)
    }

    /**
     Returns UInt64 to encompass highest possible length. Length will be UInt16
     */
    private func extractTwoBytePayloadLengthExtension() throws -> UInt64 {
        let two = try buffer.chunk(length: 2)
        return try UInt64.init(two)
    }


    private func extractEightBytePayloadLengthExtension() throws -> UInt64 {
        let eight = try buffer.chunk(length: 8)
        return try UInt64.init(eight)
    }

    private func extractMaskingKey() throws -> MaskingKey {
        guard
            let zero = try buffer.next(),
            let one = try buffer.next(),
            let two = try buffer.next(),
            let three = try buffer.next()
            else {
                throw "536: WebSockets.Swift: FrameDeserializer"
        }

        return .key(zero: zero, one: one, two: two, three: three)
    }

    private func extractPayload(key: MaskingKey, length: UInt64) throws -> [Byte] {
        var count: UInt64 = 0
        var bytes: [UInt8] = []

        while count < length, let next = try buffer.next() {
            bytes.append(next)
            count += 1
        }

        return key.cypher(bytes)
    }
}

extension FrameDeserializer where Buffer: StreamBuffer {
    public convenience init(stream: Stream) {
        let buffer = Buffer.init(stream)
        self.init(buffer: buffer)
    }
}

extension InputBuffer {
   private mutating func chunk(length: Int) throws -> [Element] {
        var elements: [Element] = []
        for _ in 1...length {
            guard let next = try next() else {
                throw "6"
            }
            elements.append(next)
        }
        return elements
    }
}
