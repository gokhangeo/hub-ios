import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

@main
struct BulutsuzApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(hubIndigo)
        }
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            SendHome()
                .tabItem { Label("Gönder", systemImage: "arrow.up.circle") }
            ReceiveView()
                .tabItem { Label("Al", systemImage: "arrow.down.circle") }
        }
    }
}

/// A photo or video picked from the library, copied to a file we own.
struct PickedFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { PickedFile(url: try TempFiles.copy($0.file)) }
        FileRepresentation(importedContentType: .image) { PickedFile(url: try TempFiles.copy($0.file)) }
        FileRepresentation(importedContentType: .data) { PickedFile(url: try TempFiles.copy($0.file)) }
    }
}

struct SendHome: View {
    @StateObject private var session = HubSession()
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showImporter = false
    @State private var text = ""
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if session.mode == .sending {
                    SendSessionView(session: session) {
                        session.stop()
                        TempFiles.cleanup()
                    }
                    .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
                    .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
                } else {
                    picker
                }
            }
            .navigationTitle("Bulutsuz Transfer")
        }
    }

    private var picker: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Android ve Windows'a bulutsuz gönder. Karşı tarafta HUB açık olsun: QR'ı okutsun ya da 6 haneli kodu girsin.")
                    .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                PhotosPicker(selection: $photoItems, maxSelectionCount: 30, matching: .any(of: [.images, .videos])) {
                    Label("Fotoğraf / Video seç", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                Button { showImporter = true } label: {
                    Label("Dosya seç", systemImage: "folder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.large)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Metin gönder").font(.headline)
                    TextEditor(text: $text)
                        .frame(minHeight: 100)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.3)))
                    HStack {
                        Button("Panodan yapıştır") { text = UIPasteboard.general.string ?? text }
                        Spacer()
                        Button("Metni gönder") { sendText() }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if loading { ProgressView("Hazırlanıyor…") }
                if let error = error { Text(error).foregroundColor(.red).font(.caption) }
                Text("İpucu: Fotoğraflar, Dosyalar ya da herhangi bir uygulamada Paylaş → Bulutsuz'u seçebilirsin.")
                    .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
            }
            .padding()
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                let items = urls.compactMap { try? TempFiles.copy($0) }.map { TempFiles.item(for: $0) }
                if items.isEmpty { error = "Dosya okunamadı." } else { session.startSending(items) }
            case .failure(let e):
                error = e.localizedDescription
            }
        }
        .onChange(of: photoItems) { newItems in
            guard !newItems.isEmpty else { return }
            loading = true
            error = nil
            Task {
                var items: [OutgoingItem] = []
                for item in newItems {
                    if let picked = try? await item.loadTransferable(type: PickedFile.self) {
                        items.append(TempFiles.item(for: picked.url))
                    }
                }
                await MainActor.run {
                    loading = false
                    photoItems = []
                    if items.isEmpty { error = "Seçilen öğeler okunamadı." } else { session.startSending(items) }
                }
            }
        }
    }

    private func sendText() {
        do {
            let url = try TempFiles.writeText(text)
            session.startSending([TempFiles.item(for: url, isText: true)])
            text = ""
        } catch {
            self.error = "Metin hazırlanamadı."
        }
    }
}
