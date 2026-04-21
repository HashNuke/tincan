#if os(iOS) || os(macOS)
import Foundation
import WebRTC

enum WebRTCProbe {
    static func makePeerConnectionFactory() -> RTCPeerConnectionFactory {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }
}
#endif
