import SwiftUI
import AVFoundation

struct ReceiveView: View {
    @StateObject private var session = HubSession()
    @State private var digits = ""
    @State private var showScanner = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if session.mode == .idle {
                        Text("Gönderen cihazdaki QR'ı okut ya da 6 haneli kodu gir.")
                            .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                        Button { showScanner = true } label: {
                            Label("QR okut", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        TextField("000 000", text: $digits)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .font(.system(size: 36, weight: .bold, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .focused($focused)
                            .padding(10)
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(12)
                            .onChange(of: digits) { value in
                                let clean = Hub.digits(value)
                                if clean != value { digits = clean }
                                if clean.count == 6, let code = Hub.normalizeCode(clean) {
                                    focused = false
                                    session.connect(code: code, key: "")
                                }
                            }
                        Text("Kodla bağlanınca gönderen bir kez “Kabul et”e dokunur. QR ile onay gerekmez.")
                            .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                    } else {
                        StatusBanner(session: session)
                        TransferList(session: session)
                        Button(session.connected ? "Bağlantıyı kapat" : "Vazgeç") {
                            session.stop()
                            digits = ""
                        }
                        .buttonStyle(.bordered)
                        Text("Alınan dosyalar Dosyalar uygulamasında: Bulutsuz → Alınanlar. Aktarım sürerken uygulamayı açık tutun.")
                            .font(.caption2).foregroundColor(.secondary).multilineTextAlignment(.center)
                    }
                }
                .padding()
            }
            .navigationTitle("Dosya Al")
            .onChange(of: session.mode) { mode in
                UIApplication.shared.isIdleTimerDisabled = mode != .idle
            }
            .sheet(isPresented: $showScanner) {
                QRScannerSheet { text in
                    showScanner = false
                    if let parsed = Hub.parse(text) {
                        session.connect(code: parsed.code, key: parsed.key)
                    }
                }
            }
        }
    }
}

struct QRScannerSheet: View {
    var onFound: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var denied = false

    var body: some View {
        NavigationStack {
            ZStack {
                if denied {
                    Text("Kamera izni yok. Ayarlar → Bulutsuz → Kamera'yı açın.")
                        .multilineTextAlignment(.center).padding()
                } else {
                    QRScannerView(onFound: onFound).ignoresSafeArea()
                    RoundedRectangle(cornerRadius: 20).stroke(Color.white, lineWidth: 3).frame(width: 240, height: 240)
                }
            }
            .navigationTitle("QR okut")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Kapat") { dismiss() } } }
            .task {
                switch AVCaptureDevice.authorizationStatus(for: .video) {
                case .authorized: denied = false
                case .notDetermined: denied = !(await AVCaptureDevice.requestAccess(for: .video))
                default: denied = true
                }
            }
        }
    }
}

struct QRScannerView: UIViewControllerRepresentable {
    var onFound: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onFound = onFound
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onFound: ((String) -> Void)?
    private let captureSession = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var done = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input) else { return }
        captureSession.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(output) else { return }
        captureSession.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let session = captureSession
        DispatchQueue.global(qos: .userInitiated).async { if !session.isRunning { session.startRunning() } }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = captureSession
        DispatchQueue.global(qos: .userInitiated).async { if session.isRunning { session.stopRunning() } }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !done,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue,
              Hub.parse(value) != nil else { return }
        done = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onFound?(value)
    }
}
