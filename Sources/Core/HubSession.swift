import Foundation
import CryptoKit
import Combine

/// A file or text queued for sending. `url` points at a local copy we own.
struct OutgoingItem: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let size: Int64
    let mime: String
    let isText: Bool
}

struct TransferRow: Identifiable {
    enum Direction { case outgoing, incoming }
    enum State { case waiting, active, done, failed }
    let id: String
    let direction: Direction
    var name: String
    var size: Int64
    var progress: Double = 0
    var state: State = .waiting
    var label: String
    var savedURL: URL?
    var text: String?
}

/// HUB transfer session, wire-compatible with gokhangeo/hub (protocol v2).
/// Not thread-safe by design: everything runs on the main queue.
final class HubSession: ObservableObject {
    enum Mode { case idle, sending, receiving }

    @Published private(set) var mode: Mode = .idle
    @Published private(set) var status = ""
    @Published private(set) var isError = false
    @Published private(set) var connected = false
    @Published private(set) var myCode = ""
    @Published private(set) var qrLink = ""
    @Published private(set) var rows: [TransferRow] = []
    /// True while waiting for files through a "Dosya iste" link.
    @Published private(set) var isRequest = false
    /// Set when a device typed our code (no QR key) and waits for "Kabul et".
    @Published var approvalRequest: String?

    private let signal = PeerSignal()
    private var sessionKey = ""
    private var links: [String: PeerLink] = [:]      // connectionId -> link
    private var active: PeerLink?
    private var helloPending: Set<String> = []
    private var awaitingApproval: PeerLink?
    private var queue: [OutgoingItem] = []
    private var sendingLoop = false
    private var waiters: [String: (PackValue?) -> Void] = [:]
    private var inbound: [String: Inbound] = [:]
    private var target: (code: String, key: String)?

    private final class Inbound {
        let id: String
        let name: String
        let size: Int64
        let totalChunks: Int64
        let isText: Bool
        var expected: Int64 = 0
        var received: Int64 = 0
        var hasher = SHA256()
        var buffer = Data()
        var handle: FileHandle?
        var fileURL: URL?
        init(id: String, name: String, size: Int64, totalChunks: Int64, isText: Bool) {
            self.id = id; self.name = name; self.size = size; self.totalChunks = totalChunks; self.isText = isText
        }
    }

    init() {
        signal.onMessage = { [weak self] message in self?.handleServer(message) }
        signal.onOpen = { [weak self] in self?.signalOpened() }
        signal.onClose = { [weak self] reason in
            guard let self = self, self.mode != .idle else { return }
            if self.active == nil { self.setStatus(reason, error: true) }
        }
    }

    // MARK: Public API

    /// Show a code + QR and wait for the receiver (QR key connects without approval).
    func startSending(_ items: [OutgoingItem]) {
        reset()
        mode = .sending
        queue = items
        sessionKey = Hub.generateSessionKey()
        let code = Hub.generateCode()
        myCode = code
        qrLink = Hub.receiveLink(code: code, key: sessionKey)
        for item in items {
            rows.append(TransferRow(id: item.id.uuidString, direction: .outgoing, name: item.isText ? "Metin" : item.name, size: item.size, label: "Alıcı bekleniyor"))
        }
        setStatus("Sinyal sunucusuna bağlanılıyor…")
        signal.start(id: code)
    }

    /// "Dosya iste": host a session whose link lets someone without the app send us files from a browser.
    func startRequest() {
        reset()
        mode = .sending
        isRequest = true
        sessionKey = Hub.generateSessionKey()
        let code = Hub.generateCode()
        myCode = code
        qrLink = Hub.requestLink(code: code, key: sessionKey)
        setStatus("Sinyal sunucusuna bağlanılıyor…")
        signal.start(id: code)
    }

    /// Connect to a sender by its 6-digit code (asks the sender to accept) or QR (with key).
    func connect(code: String, key: String) {
        reset()
        mode = .receiving
        target = (code, key)
        myCode = Hub.generateCode()
        setStatus("Bağlanılıyor…")
        signal.start(id: myCode)
    }

    func approve() {
        guard let link = awaitingApproval else { return }
        awaitingApproval = nil
        approvalRequest = nil
        accept(link)
    }

    func reject() {
        guard let link = awaitingApproval else { return }
        awaitingApproval = nil
        approvalRequest = nil
        link.send(.object([("type", .string("connection-rejected"))]))
        drop(link)
        setStatus("Bağlantı reddedildi. Alıcı bekleniyor…")
    }

    func stop() {
        reset()
        mode = .idle
        status = ""
    }

    var allDone: Bool { !rows.isEmpty && rows.allSatisfy { $0.state == .done || $0.state == .failed } }

    // MARK: Signalling

    private func signalOpened() {
        if mode == .sending && isRequest {
            setStatus("Linki gönder. Karşı taraf açıp dosyayı seçince buraya gelecek.")
        } else if mode == .sending {
            setStatus("Hazır. QR'ı okut ya da kodu gir: \(Hub.displayCode(myCode))")
        } else if mode == .receiving, let target = target {
            setStatus("\(Hub.displayCode(target.code)) koduna bağlanılıyor…")
            let link = PeerLink(remoteId: target.code, connectionId: "dc_" + Hub.randomToken(), originator: true, signal: signal)
            wire(link)
            link.startAsOriginator()
        }
    }

    private func handleServer(_ message: [String: Any]) {
        let type = message["type"] as? String ?? ""
        let payload = message["payload"] as? [String: Any] ?? [:]
        let src = message["src"] as? String ?? ""
        let connectionId = payload["connectionId"] as? String ?? ""
        switch type {
        case "ID-TAKEN":
            if isRequest { startRequest() }
            else if mode == .sending { startSending(queue) }
            else if let t = target { connect(code: t.code, key: t.key) }
        case "INVALID-KEY", "ERROR":
            setStatus("Sinyal sunucusu hata verdi. Biraz sonra yeniden deneyin.", error: true)
        case "EXPIRE":
            if mode == .receiving && active == nil {
                setStatus("Hedef cihaz bulunamadı. Kodun açık olduğunu kontrol edin.", error: true)
            }
        case "OFFER":
            guard mode == .sending, links[connectionId] == nil,
                  let sdp = (payload["sdp"] as? [String: Any])?["sdp"] as? String else { return }
            let link = PeerLink(remoteId: src, connectionId: connectionId, originator: false, signal: signal)
            wire(link)
            link.handleOffer(sdp: sdp)
        case "ANSWER":
            guard let sdp = (payload["sdp"] as? [String: Any])?["sdp"] as? String else { return }
            links[connectionId]?.handleAnswer(sdp: sdp)
        case "CANDIDATE":
            if let candidate = payload["candidate"] as? [String: Any] { links[connectionId]?.handleCandidate(candidate) }
        default:
            break
        }
    }

    private func wire(_ link: PeerLink) {
        links[link.connectionId] = link
        let id = link.connectionId
        link.onOpen = { [weak self, weak link] in
            guard let self = self, let link = link else { return }
            if link.originator {
                var hello: [(String, PackValue?)] = [("type", .string("hello")), ("version", .int(Hub.protocolVersion))]
                if let key = self.target?.key, !key.isEmpty { hello.append(("key", .string(key))) }
                link.send(.object(hello))
                self.setStatus(self.target?.key.isEmpty == false ? "Bağlanılıyor…" : "Gönderen cihazda “Kabul et”e dokunun.")
            } else {
                self.helloPending.insert(id)
            }
        }
        link.onMessage = { [weak self, weak link] message in
            guard let self = self, let link = link else { return }
            self.route(message, from: link)
        }
        link.onClose = { [weak self, weak link] reason in
            guard let self = self, let link = link else { return }
            self.linkClosed(link, reason: reason)
        }
    }

    private func drop(_ link: PeerLink) {
        link.onClose = nil
        link.close()
        links[link.connectionId] = nil
        helloPending.remove(link.connectionId)
    }

    private func linkClosed(_ link: PeerLink, reason: String) {
        links[link.connectionId] = nil
        if awaitingApproval === link { awaitingApproval = nil; approvalRequest = nil }
        guard active === link else { return }
        active = nil
        connected = false
        failPending(reason)
        setStatus(mode == .sending && !queue.isEmpty ? "\(reason) QR ile yeniden bağlanabilir." : reason, error: !allDone)
    }

    // MARK: Messages

    private func route(_ message: PackValue, from link: PeerLink) {
        guard let type = message["type"]?.string else { return }
        switch type {
        case "hello":
            guard mode == .sending, helloPending.contains(link.connectionId) else { return }
            helloPending.remove(link.connectionId)
            guard message["version"]?.int == Hub.protocolVersion else {
                link.send(.object([("type", .string("connection-rejected"))]))
                return drop(link)
            }
            if active != nil { link.send(.object([("type", .string("connection-rejected"))])); return drop(link) }
            if let key = message["key"]?.string, key == sessionKey { return accept(link) }
            if let previous = awaitingApproval, previous !== link {
                previous.send(.object([("type", .string("connection-rejected"))]))
                drop(previous)
            }
            awaitingApproval = link
            approvalRequest = "Kodunuzu giren bir cihaz bağlanmak istiyor."
            setStatus("Bir cihaz bağlanmak istiyor. Kabul edin.")
        case "connection-accepted":
            guard mode == .receiving, link.originator else { return }
            guard message["version"]?.int == Hub.protocolVersion else { setStatus("Karşı cihazı güncelleyip yeniden deneyin.", error: true); return drop(link) }
            activate(link)
        case "connection-rejected":
            setStatus("Karşı cihaz bağlantıyı reddetti.", error: true)
            drop(link)
        default:
            guard link === active, let id = message["id"]?.string else { return }
            switch type {
            case "file-accepted", "file-rejected": resolve("\(id):accept", message)
            case "file-ack": resolve("\(id):ack", message)
            case "file-error":
                resolve("\(id):ack", message); resolve("\(id):accept", message)
                if let entry = inbound[id] { failInbound(entry, reason: message["reason"]?.string ?? "Aktarım başarısız.", notify: false) }
            case "file-cancel":
                resolve("\(id):accept", .object([("type", .string("file-error")), ("reason", .string("Karşı taraf iptal etti."))]))
                resolve("\(id):ack", .object([("type", .string("file-error")), ("reason", .string("Karşı taraf iptal etti."))]))
                if let entry = inbound[id] { failInbound(entry, reason: "Gönderici aktarımı iptal etti.", notify: false) }
            case "file-meta": incomingMeta(message, id: id)
            case "file-chunk": incomingChunk(message, id: id)
            case "file-end": incomingEnd(message, id: id)
            default: break
            }
        }
    }

    private func accept(_ link: PeerLink) {
        activate(link)
        link.send(.object([("type", .string("connection-accepted")), ("version", .int(Hub.protocolVersion))]))
        pumpQueue()
    }

    private func activate(_ link: PeerLink) {
        active = link
        connected = true
        setStatus(isRequest ? "✓ Karşı taraf bağlandı. Dosyayı seçmesi bekleniyor…" : mode == .sending ? "✓ Alıcı bağlandı" : "✓ Bağlandı. Dosyalar bekleniyor…")
        // Close any other half-open candidates.
        for (_, other) in links where other !== link { drop(other) }
    }

    // MARK: Sending

    private func pumpQueue() {
        guard !sendingLoop else { return }
        sendingLoop = true
        Task { @MainActor in
            while let link = self.active, !self.queue.isEmpty {
                let item = self.queue.removeFirst()
                await self.send(item, over: link)
            }
            self.sendingLoop = false
            if self.mode == .sending && self.allDone && self.active != nil {
                let failed = self.rows.contains { $0.state == .failed }
                self.setStatus(failed ? "Bazı aktarımlar başarısız oldu." : "✓ Hepsi gönderildi ve doğrulandı.", error: failed)
            }
        }
    }

    @MainActor private func send(_ item: OutgoingItem, over link: PeerLink) async {
        let rowId = item.id.uuidString
        let id = Hub.transferId()
        let total = (item.size + Int64(Hub.chunkSize) - 1) / Int64(Hub.chunkSize)
        update(rowId) { $0.state = .waiting; $0.label = "Alıcı onayı bekleniyor" }
        var meta: [(String, PackValue?)] = [
            ("type", .string("file-meta")), ("id", .string(id)), ("name", .string(item.name)),
            ("size", .int(item.size)), ("mime", .string(item.mime)), ("totalChunks", .int(total)),
            ("version", .int(Hub.protocolVersion))
        ]
        if item.isText { meta.append(("kind", .string("text"))) }
        link.send(.object(meta))
        let accepted = await wait(for: "\(id):accept", timeout: Hub.acceptTimeout)
        guard accepted?["type"]?.string == "file-accepted" else {
            return update(rowId) { $0.state = .failed; $0.label = accepted?["reason"]?.string ?? "Alıcı dosyayı reddetti." }
        }
        guard let handle = try? FileHandle(forReadingFrom: item.url) else {
            return update(rowId) { $0.state = .failed; $0.label = "Dosya okunamadı." }
        }
        defer { try? handle.close() }
        let resumeFrom = max(0, min(total, accepted?["resumeFrom"]?.int ?? 0))
        var hasher = SHA256()
        var index: Int64 = 0
        var sent: Int64 = 0
        update(rowId) { $0.state = .active; $0.label = "Gönderiliyor" }
        while true {
            guard active === link, link.isOpen else {
                return update(rowId) { $0.state = .failed; $0.label = "Bağlantı kesildi." }
            }
            let data: Data
            if #available(iOS 13.4, *) { data = (try? handle.read(upToCount: Hub.chunkSize)) ?? Data() }
            else { data = handle.readData(ofLength: Hub.chunkSize) }
            if data.isEmpty { break }
            hasher.update(data: data)
            if index >= resumeFrom {
                while link.bufferedAmount > Hub.maxBufferedAmount && link.isOpen {
                    try? await Task.sleep(nanoseconds: 15_000_000)
                }
                link.send(.object([("type", .string("file-chunk")), ("id", .string(id)), ("index", .int(index)), ("data", .binary(data))]))
            }
            sent += Int64(data.count)
            index += 1
            if index % 8 == 0 || sent == item.size {
                let p = item.size == 0 ? 1 : Double(sent) / Double(item.size)
                update(rowId) { $0.progress = p }
                await Task.yield()
            }
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        link.send(.object([("type", .string("file-end")), ("id", .string(id)), ("hash", .string(hash)), ("bytes", .int(item.size)), ("totalChunks", .int(total))]))
        update(rowId) { $0.label = "Alıcı doğruluyor"; $0.progress = 1 }
        let ack = await wait(for: "\(id):ack", timeout: Hub.acceptTimeout)
        if ack?["type"]?.string == "file-ack", ack?["hash"]?.string == hash {
            update(rowId) { $0.state = .done; $0.label = item.isText ? "✓ Metin gönderildi · doğrulandı" : "✓ Gönderildi · doğrulandı" }
        } else {
            update(rowId) { $0.state = .failed; $0.label = ack?["reason"]?.string ?? "Alıcı doğrulaması başarısız." }
        }
    }

    @MainActor private func wait(for key: String, timeout: TimeInterval) async -> PackValue? {
        await withCheckedContinuation { (continuation: CheckedContinuation<PackValue?, Never>) in
            DispatchQueue.main.async {
                self.waiters[key] = { continuation.resume(returning: $0) }
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.resolve(key, nil) }
            }
        }
    }

    private func resolve(_ key: String, _ value: PackValue?) {
        guard let waiter = waiters.removeValue(forKey: key) else { return }
        waiter(value)
    }

    private func failPending(_ reason: String) {
        let pending = waiters
        waiters.removeAll()
        for (_, waiter) in pending { waiter(.object([("type", .string("file-error")), ("reason", .string(reason))])) }
        for (_, entry) in inbound { failInbound(entry, reason: reason, notify: false) }
    }

    // MARK: Receiving

    static var inboxDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Alınanlar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func incomingMeta(_ message: PackValue, id: String) {
        guard let link = active else { return }
        func reject(_ reason: String) {
            link.send(.object([("type", .string("file-rejected")), ("id", .string(id)), ("reason", .string(reason))]))
        }
        guard id.range(of: "^[a-f0-9]{24}$", options: .regularExpression) != nil, inbound[id] == nil else { return reject("Geçersiz aktarım kimliği.") }
        guard let size = message["size"]?.int, size >= 0, size <= Hub.maxFileBytes else { return reject("Dosya boyutu izin verilen sınırın dışında.") }
        let expectedChunks = (size + Int64(Hub.chunkSize) - 1) / Int64(Hub.chunkSize)
        guard message["totalChunks"]?.int == expectedChunks else { return reject("Parça bilgisi geçersiz.") }
        guard let rawName = message["name"]?.string, !rawName.trimmingCharacters(in: .whitespaces).isEmpty else { return reject("Dosya adı geçersiz.") }
        let isText = message["kind"]?.string == "text" && size <= Int64(Hub.textMaxBytes)
        let name = Hub.sanitizeFilename(rawName)
        let entry = Inbound(id: id, name: name, size: size, totalChunks: expectedChunks, isText: isText)
        if !isText {
            let url = uniqueURL(for: name)
            guard FileManager.default.createFile(atPath: url.path, contents: nil), let handle = try? FileHandle(forWritingTo: url) else {
                return reject("Dosya kaydedilemedi.")
            }
            entry.fileURL = url
            entry.handle = handle
        }
        inbound[id] = entry
        rows.append(TransferRow(id: id, direction: .incoming, name: isText ? "Metin" : name, size: size, state: .active, label: "Alınıyor"))
        link.send(.object([("type", .string("file-accepted")), ("id", .string(id))]))
        setStatus(isText ? "Metin geliyor…" : "\(name) geliyor…")
    }

    private func incomingChunk(_ message: PackValue, id: String) {
        guard let entry = inbound[id] else { return }
        let remaining = entry.size - entry.received
        guard let data = message["data"]?.data, message["index"]?.int == entry.expected,
              Int64(data.count) == min(Int64(Hub.chunkSize), remaining), !data.isEmpty else {
            return failInbound(entry, reason: "Geçersiz veya sırası bozuk dosya parçası.", notify: true)
        }
        entry.hasher.update(data: data)
        if entry.isText { entry.buffer.append(data) }
        else {
            do {
                if #available(iOS 13.4, *) { try entry.handle?.write(contentsOf: data) } else { entry.handle?.write(data) }
            } catch {
                return failInbound(entry, reason: "Dosya yazılamadı (depolama dolu olabilir).", notify: true)
            }
        }
        entry.expected += 1
        entry.received += Int64(data.count)
        if entry.expected % 8 == 0 || entry.received == entry.size {
            let p = entry.size == 0 ? 1 : Double(entry.received) / Double(entry.size)
            update(id) { $0.progress = p }
        }
    }

    private func incomingEnd(_ message: PackValue, id: String) {
        guard let entry = inbound[id], let link = active else { return }
        let hash = entry.hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard entry.received == entry.size, entry.expected == entry.totalChunks,
              message["bytes"]?.int == entry.size, message["totalChunks"]?.int == entry.totalChunks else {
            return failInbound(entry, reason: "Dosya eksik alındı.", notify: true)
        }
        guard message["hash"]?.string == hash else {
            return failInbound(entry, reason: "Bütünlük doğrulaması başarısız.", notify: true)
        }
        try? entry.handle?.close()
        inbound[id] = nil
        let text = entry.isText ? String(decoding: entry.buffer, as: UTF8.self) : nil
        update(id) {
            $0.state = .done
            $0.progress = 1
            $0.label = entry.isText ? "✓ Metin alındı · doğrulandı" : "✓ Kaydedildi · doğrulandı"
            $0.savedURL = entry.fileURL
            $0.text = text
        }
        link.send(.object([("type", .string("file-ack")), ("id", .string(id)), ("hash", .string(hash))]))
        setStatus(entry.isText ? "✓ Metin alındı" : "✓ \(entry.name) alındı ve doğrulandı")
    }

    private func failInbound(_ entry: Inbound, reason: String, notify: Bool) {
        inbound[entry.id] = nil
        try? entry.handle?.close()
        if let url = entry.fileURL { try? FileManager.default.removeItem(at: url) }
        if notify { active?.send(.object([("type", .string("file-error")), ("id", .string(entry.id)), ("reason", .string(reason))])) }
        update(entry.id) { $0.state = .failed; $0.label = reason }
    }

    private func uniqueURL(for name: String) -> URL {
        let dir = HubSession.inboxDirectory
        var url = dir.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
        }
        return url
    }

    // MARK: Helpers

    private func update(_ id: String, _ change: (inout TransferRow) -> Void) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        change(&rows[i])
    }

    private func setStatus(_ text: String, error: Bool = false) {
        status = text
        isError = error
    }

    private func reset() {
        failPending("Oturum kapatıldı.")
        for (_, link) in links { link.onClose = nil; link.close() }
        links.removeAll()
        active = nil
        connected = false
        awaitingApproval = nil
        approvalRequest = nil
        helloPending.removeAll()
        inbound.removeAll()
        queue.removeAll()
        target = nil
        rows.removeAll()
        isRequest = false
        qrLink = ""
        myCode = ""
        signal.stop()
    }
}
