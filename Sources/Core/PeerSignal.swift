import Foundation

/// Minimal PeerJS 1.5.x signalling client (lib/socket.ts): one WebSocket to the public
/// PeerServer, JSON messages, HEARTBEAT every 5 s. All callbacks arrive on the main queue.
final class PeerSignal: NSObject, URLSessionWebSocketDelegate {
    var onOpen: (() -> Void)?
    var onMessage: (([String: Any]) -> Void)?
    var onClose: ((String) -> Void)?

    private(set) var id = ""
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var heartbeat: Timer?
    private var closed = true

    func start(id: String, host: String = "0.peerjs.com", key: String = "peerjs") {
        stop()
        self.id = id
        closed = false
        let urlString = "wss://\(host):443/peerjs?key=\(key)&id=\(id)&token=\(Hub.randomToken())&version=1.5.5"
        guard let url = URL(string: urlString) else { return }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receive()
    }

    func stop() {
        closed = true
        heartbeat?.invalidate()
        heartbeat = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    func send(_ object: [String: Any]) {
        guard let task = task,
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    private func receive() {
        task?.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, !self.closed else { return }
                switch result {
                case .failure(let error):
                    self.finish("Sinyal bağlantısı koptu: \(error.localizedDescription)")
                case .success(let message):
                    var data: Data?
                    switch message {
                    case .string(let s): data = s.data(using: .utf8)
                    case .data(let d): data = d
                    @unknown default: data = nil
                    }
                    if let data = data, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                        if (obj["type"] as? String) == "OPEN" { self.onOpen?() }
                        self.onMessage?(obj)
                    }
                    self.receive()
                }
            }
        }
    }

    private func finish(_ reason: String) {
        guard !closed else { return }
        stop()
        onClose?(reason)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.send(["type": "HEARTBEAT"])
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish("Sinyal sunucusu bağlantıyı kapattı.")
    }
}
