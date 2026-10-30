import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// Paylaş menüsü → Bulutsuz. Copies the shared items to our temp folder (streamed, never held
/// in memory) and shows the same code/QR screen as the app. The transfer runs here, so the
/// sheet has to stay open until it finishes.
final class ShareViewController: UIViewController {
    private let session = HubSession()
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let root = ShareRootView(session: session, model: model) { [weak self] in self?.finish() }
        let host = UIHostingController(rootView: root.tint(hubIndigo))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        loadItems()
    }

    private func finish() {
        session.stop()
        TempFiles.cleanup()
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    private func loadItems() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let group = DispatchGroup()
        var results: [Int: OutgoingItem] = [:]
        let lock = NSLock()

        for (index, provider) in providers.enumerated() {
            group.enter()
            ShareViewController.load(provider) { item in
                if let item = item { lock.lock(); results[index] = item; lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            let items = results.keys.sorted().compactMap { results[$0] }
            if items.isEmpty {
                self.model.error = "Paylaşılan öğe okunamadı."
            } else {
                self.model.ready = true
                self.session.startSending(items)
            }
        }
    }

    private static func load(_ provider: NSItemProvider, completion: @escaping (OutgoingItem?) -> Void) {
        let types = provider.registeredTypeIdentifiers
        let conforms: (UTType) -> String? = { target in
            types.first { UTType($0)?.conforms(to: target) == true }
        }

        // Web links and plain text travel as HUB text (shown in place on the other side).
        if conforms(.fileURL) == nil, let urlType = conforms(.url) {
            provider.loadItem(forTypeIdentifier: urlType, options: nil) { value, _ in
                if let url = value as? URL, !url.isFileURL { completion(textItem(url.absoluteString)) }
                else if let url = value as? URL { completion(try? TempFiles.item(for: TempFiles.copy(url))) }
                else if let s = value as? String { completion(textItem(s)) }
                else { completion(nil) }
            }
            return
        }
        if conforms(.fileURL) == nil, conforms(.data) == nil, let textType = conforms(.plainText) ?? conforms(.text) {
            provider.loadItem(forTypeIdentifier: textType, options: nil) { value, _ in
                if let s = value as? String { completion(textItem(s)) }
                else if let d = value as? Data, let s = String(data: d, encoding: .utf8) { completion(textItem(s)) }
                else { completion(nil) }
            }
            return
        }
        if conforms(.plainText) != nil, conforms(.fileURL) == nil, types.count == 1 {
            provider.loadItem(forTypeIdentifier: types[0], options: nil) { value, _ in
                completion((value as? String).flatMap(textItem))
            }
            return
        }

        // Everything else: ask for a file representation of the best data type.
        let preferred = conforms(.movie) ?? conforms(.image) ?? conforms(.data) ?? conforms(.item) ?? types.first
        guard let typeId = preferred else { return completion(nil) }
        provider.loadFileRepresentation(forTypeIdentifier: typeId) { url, _ in
            guard let url = url else { return completion(nil) }
            var name = provider.suggestedName.map(Hub.sanitizeFilename) ?? url.lastPathComponent
            if (name as NSString).pathExtension.isEmpty {
                let ext = url.pathExtension.isEmpty ? (UTType(typeId)?.preferredFilenameExtension ?? "") : url.pathExtension
                if !ext.isEmpty { name += "." + ext }
            }
            // The provided URL is deleted when this block returns, so copy it now.
            completion(try? TempFiles.item(for: TempFiles.copy(url, preferredName: name)))
        }
    }

    private static func textItem(_ text: String) -> OutgoingItem? {
        guard !text.isEmpty, let url = try? TempFiles.writeText(text) else { return nil }
        return TempFiles.item(for: url, isText: true)
    }
}

final class ShareModel: ObservableObject {
    @Published var ready = false
    @Published var error: String?
}

struct ShareRootView: View {
    @ObservedObject var session: HubSession
    @ObservedObject var model: ShareModel
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if let error = model.error {
                    VStack(spacing: 16) {
                        Text(error).foregroundColor(.red)
                        Button("Kapat", action: onClose).buttonStyle(.bordered)
                    }
                } else if !model.ready {
                    ProgressView("Hazırlanıyor…")
                } else {
                    SendSessionView(session: session, onClose: onClose)
                }
            }
            .navigationTitle("Bulutsuz Gönder")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
