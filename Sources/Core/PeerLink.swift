import Foundation
import WebRTC

/// One PeerJS DataConnection (serialization 'binary', reliable) over a native RTCPeerConnection.
/// Mirrors lib/negotiator.ts + BinaryPack.ts: label = connectionId, ordered channel,
/// messages over 16300 bytes split into {__peerData, n, data, total} chunks.
/// Every callback is delivered on the main queue.
final class PeerLink: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()
    static let chunkedMTU = 16300

    let remoteId: String
    let connectionId: String
    let originator: Bool
    private let signal: PeerSignal
    private var pc: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var pendingCandidates: [RTCIceCandidate] = []
    private var remoteDescriptionSet = false
    private var chunkCounter: Int64 = 1
    private var chunkStore: [Int64: (parts: [Int: Data], total: Int)] = [:]
    private var didOpen = false
    private var didClose = false

    var onOpen: (() -> Void)?
    var onMessage: ((PackValue) -> Void)?
    var onClose: ((String) -> Void)?

    var isOpen: Bool { channel?.readyState == .open }
    var bufferedAmount: UInt64 { channel?.bufferedAmount ?? 0 }

    private static let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: ["DtlsSrtpKeyAgreement": "true"])

    init(remoteId: String, connectionId: String, originator: Bool, signal: PeerSignal) {
        self.remoteId = remoteId
        self.connectionId = connectionId
        self.originator = originator
        self.signal = signal
        super.init()
        let config = RTCConfiguration()
        config.iceServers = [RTCIceServer(urlStrings: Hub.iceServers)]
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        pc = PeerLink.factory.peerConnection(with: config, constraints: PeerLink.constraints, delegate: self)
    }

    // MARK: Negotiation

    /// Caller side: create the channel and send an OFFER through the PeerServer.
    func startAsOriginator() {
        guard let pc = pc else { return fail("WebRTC başlatılamadı.") }
        let dcConfig = RTCDataChannelConfiguration()
        dcConfig.isOrdered = true
        guard let dc = pc.dataChannel(forLabel: connectionId, configuration: dcConfig) else { return fail("Veri kanalı açılamadı.") }
        attach(dc)
        pc.offer(for: PeerLink.constraints) { [weak self] sdp, error in
            DispatchQueue.main.async {
                guard let self = self, let pc = self.pc else { return }
                guard let sdp = sdp, error == nil else { return self.fail("Teklif oluşturulamadı.") }
                pc.setLocalDescription(sdp) { error in
                    DispatchQueue.main.async {
                        if error != nil { return self.fail("Yerel SDP ayarlanamadı.") }
                        self.signal.send([
                            "type": "OFFER",
                            "dst": self.remoteId,
                            "payload": [
                                "sdp": ["type": "offer", "sdp": sdp.sdp],
                                "type": "data",
                                "connectionId": self.connectionId,
                                "label": self.connectionId,
                                "reliable": true,
                                "serialization": "binary"
                            ] as [String: Any]
                        ])
                    }
                }
            }
        }
    }

    /// Callee side: answer an incoming OFFER.
    func handleOffer(sdp: String) {
        guard let pc = pc else { return fail("WebRTC başlatılamadı.") }
        pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self, let pc = self.pc else { return }
                if error != nil { return self.fail("Uzak SDP geçersiz.") }
                self.remoteDescriptionSet = true
                self.flushCandidates()
                pc.answer(for: PeerLink.constraints) { answer, error in
                    DispatchQueue.main.async {
                        guard let answer = answer, error == nil else { return self.fail("Yanıt oluşturulamadı.") }
                        pc.setLocalDescription(answer) { error in
                            DispatchQueue.main.async {
                                if error != nil { return self.fail("Yerel SDP ayarlanamadı.") }
                                self.signal.send([
                                    "type": "ANSWER",
                                    "dst": self.remoteId,
                                    "payload": [
                                        "sdp": ["type": "answer", "sdp": answer.sdp],
                                        "type": "data",
                                        "connectionId": self.connectionId
                                    ] as [String: Any]
                                ])
                            }
                        }
                    }
                }
            }
        }
    }

    func handleAnswer(sdp: String) {
        pc?.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if error != nil { return self.fail("Uzak SDP geçersiz.") }
                self.remoteDescriptionSet = true
                self.flushCandidates()
            }
        }
    }

    func handleCandidate(_ dict: [String: Any]) {
        guard let sdp = dict["candidate"] as? String, !sdp.isEmpty else { return }
        let index = (dict["sdpMLineIndex"] as? NSNumber)?.int32Value ?? 0
        let mid = dict["sdpMid"] as? String
        let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: index, sdpMid: mid)
        if remoteDescriptionSet { pc?.add(candidate) { _ in } }
        else { pendingCandidates.append(candidate) }
    }

    private func flushCandidates() {
        for candidate in pendingCandidates { pc?.add(candidate) { _ in } }
        pendingCandidates.removeAll()
    }

    // MARK: Sending

    func send(_ value: PackValue) {
        let blob = BinaryPack.pack(value)
        if blob.count <= PeerLink.chunkedMTU {
            sendRaw(blob)
            return
        }
        let total = (blob.count + PeerLink.chunkedMTU - 1) / PeerLink.chunkedMTU
        let id = chunkCounter
        chunkCounter += 1
        var start = 0
        var n = 0
        while start < blob.count {
            let end = min(blob.count, start + PeerLink.chunkedMTU)
            let piece = PackValue.map([
                ("__peerData", .int(id)),
                ("n", .int(Int64(n))),
                ("data", .binary(blob.subdata(in: start..<end))),
                ("total", .int(Int64(total)))
            ])
            sendRaw(BinaryPack.pack(piece))
            start = end
            n += 1
        }
    }

    private func sendRaw(_ data: Data) {
        _ = channel?.sendData(RTCDataBuffer(data: data, isBinary: true))
    }

    func close() {
        guard !didClose else { return }
        didClose = true
        channel?.delegate = nil
        channel?.close()
        pc?.close()
        pc = nil
    }

    private func fail(_ reason: String) {
        guard !didClose else { return }
        close()
        onClose?(reason)
    }

    // MARK: Receiving

    private func attach(_ dc: RTCDataChannel) {
        channel = dc
        dc.delegate = self
        if dc.readyState == .open { markOpen() }
    }

    private func markOpen() {
        guard !didOpen else { return }
        didOpen = true
        onOpen?()
    }

    private func handleIncoming(_ data: Data) {
        guard let value = try? BinaryPack.unpack(data) else { return }
        if let peerData = value["__peerData"] {
            if peerData.isMap {
                if peerData["type"]?.string == "close" { fail("Karşı cihaz bağlantıyı kapattı.") }
                return
            }
            guard let id = peerData.int, let n = value["n"]?.int, let total = value["total"]?.int,
                  let piece = value["data"]?.data, total > 0, total < 100_000, n >= 0, n < total else { return }
            var entry = chunkStore[id] ?? (parts: [:], total: Int(total))
            entry.parts[Int(n)] = piece
            if entry.parts.count == entry.total {
                chunkStore[id] = nil
                var whole = Data()
                for i in 0..<entry.total { if let p = entry.parts[i] { whole.append(p) } }
                handleIncoming(whole)
            } else {
                chunkStore[id] = entry
            }
            return
        }
        onMessage?(value)
    }

    // MARK: RTCDataChannelDelegate

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        let state = dataChannel.readyState
        DispatchQueue.main.async {
            switch state {
            case .open: self.markOpen()
            case .closed: self.fail("Veri kanalı kapandı.")
            default: break
            }
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let data = buffer.data
        DispatchQueue.main.async { self.handleIncoming(data) }
    }

    // MARK: RTCPeerConnectionDelegate

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        DispatchQueue.main.async {
            if newState == .failed { self.fail("Cihazlar bağlanamadı (ICE). Farklı ağlardaysanız TURN gerekebilir.") }
            if newState == .closed { self.fail("Bağlantı kapandı.") }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let payload: [String: Any] = [
            "candidate": [
                "candidate": candidate.sdp,
                "sdpMid": candidate.sdpMid ?? "0",
                "sdpMLineIndex": candidate.sdpMLineIndex
            ] as [String: Any],
            "type": "data",
            "connectionId": connectionId
        ]
        DispatchQueue.main.async {
            self.signal.send(["type": "CANDIDATE", "dst": self.remoteId, "payload": payload])
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        DispatchQueue.main.async { self.attach(dataChannel) }
    }
}
