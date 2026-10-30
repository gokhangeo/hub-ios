import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

let hubIndigo = Color(red: 0.19, green: 0.18, blue: 0.51)

enum TempFiles {
    static var directory: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("giden", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copies a file we only have temporary access to into our own temp folder.
    static func copy(_ source: URL, preferredName: String? = nil) throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = Hub.sanitizeFilename(preferredName ?? source.lastPathComponent)
        let dest = folder.appendingPathComponent(name)
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: source, to: dest)
        return dest
    }

    static func writeText(_ text: String) throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent("metin.txt")
        try Data(text.utf8).write(to: dest)
        return dest
    }

    static func item(for url: URL, isText: Bool = false) -> OutgoingItem {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let mime = isText ? "text/plain" : (UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream")
        return OutgoingItem(url: url, name: isText ? "metin.txt" : url.lastPathComponent, size: size, mime: mime, isText: isText)
    }

    static func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

struct QRCodeImage: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Color.gray.opacity(0.2)
        }
    }

    static func render(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let context = CIContext()
        guard let cg = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct StatusBanner: View {
    @ObservedObject var session: HubSession

    var body: some View {
        if !session.status.isEmpty {
            Text(session.status)
                .font(.subheadline)
                .foregroundColor(session.isError ? .red : .secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
        }
    }
}

struct TransferList: View {
    @ObservedObject var session: HubSession

    var body: some View {
        VStack(spacing: 10) {
            ForEach(session.rows) { row in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: row.direction == .outgoing ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                            .foregroundColor(row.state == .failed ? .red : hubIndigo)
                        Text(row.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Spacer()
                        Text(Hub.formatBytes(row.size)).font(.caption).foregroundColor(.secondary)
                    }
                    if row.state == .active || row.state == .waiting {
                        ProgressView(value: row.progress)
                    }
                    Text(row.label).font(.caption).foregroundColor(row.state == .failed ? .red : .secondary)
                    if let text = row.text {
                        Text(text).font(.body).textSelection(.enabled)
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.gray.opacity(0.12)).cornerRadius(8)
                        HStack {
                            Button { UIPasteboard.general.string = text } label: { Label("Kopyala", systemImage: "doc.on.doc") }
                            ShareLink(item: text) { Label("Paylaş", systemImage: "square.and.arrow.up") }
                        }.font(.caption)
                    }
                    if let url = row.savedURL {
                        ShareLink(item: url) { Label("Paylaş / Kaydet", systemImage: "square.and.arrow.up") }.font(.caption)
                    }
                }
                .padding(12)
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(12)
            }
        }
    }
}

/// Code + QR screen the sender shows; used by the app and the share extension.
struct SendSessionView: View {
    @ObservedObject var session: HubSession
    var onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if !session.connected && !session.qrLink.isEmpty {
                    Text("Alıcı bu QR'ı okutsun").font(.headline)
                    QRCodeImage(text: session.qrLink)
                        .frame(width: 240, height: 240)
                        .padding(12)
                        .background(Color.white)
                        .cornerRadius(16)
                    VStack(spacing: 4) {
                        Text("veya HUB'da bu kodu girsin").font(.caption).foregroundColor(.secondary)
                        Text(Hub.displayCode(session.myCode))
                            .font(.system(size: 40, weight: .bold, design: .monospaced))
                            .foregroundColor(hubIndigo)
                    }
                }
                StatusBanner(session: session)
                TransferList(session: session)
                Button(session.allDone ? "Bitti" : "İptal", action: onClose)
                    .buttonStyle(.borderedProminent)
                    .tint(hubIndigo)
                Text("Gönderim bitene kadar bu ekranı açık tutun.")
                    .font(.caption2).foregroundColor(.secondary)
            }
            .padding()
        }
        .alert("Bağlantı isteği", isPresented: Binding(
            get: { session.approvalRequest != nil },
            set: { _ in }
        )) {
            Button("Kabul et") { session.approve() }
            Button("Reddet", role: .cancel) { session.reject() }
        } message: {
            Text(session.approvalRequest ?? "")
        }
    }
}
