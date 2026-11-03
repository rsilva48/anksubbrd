import SwiftUI
import VisionKit

/// A profile's identity shown as a QR by a TV app ("Llevar al teléfono"):
/// `anksubbrd://identity?bridge=<url>&token=<64 hex>&label=<name>`.
struct IdentityTransferRequest: Identifiable {
    let bridge: String
    let token: String
    let label: String
    var id: String { token }

    init?(url: URL) {
        guard url.scheme?.lowercased() == "anksubbrd", url.host?.lowercased() == "identity",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let bridge = items.first(where: { $0.name == "bridge" })?.value.flatMap(BridgeEndpoint.canonicalURL),
              let token = items.first(where: { $0.name == "token" })?.value?.lowercased(),
              token.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { return nil }
        self.bridge = bridge
        self.token = token
        let label = items.first(where: { $0.name == "label" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.label = label.isEmpty ? "Perfil" : label
    }
}

/// What a scanned code or an opened link asks for: a profile to use here,
/// or a TV to pair with this device's identity.
enum ScannedCode: Identifiable {
    case identity(IdentityTransferRequest)
    case pairing(TVPairingRequest)

    var id: String {
        switch self {
        case .identity(let request): "identity:\(request.id)"
        case .pairing(let request): "pairing:\(request.id)"
        }
    }

    init?(_ text: String) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        if let identity = IdentityTransferRequest(url: url) {
            self = .identity(identity)
        } else if let pairing = TVPairingRequest(url: url) {
            self = .pairing(pairing)
        } else {
            return nil
        }
    }
}

/// Uses the profile from a TV's QR on this device: same Continue and
/// preferences. A different bridge is tested and adopted first.
struct IdentityImportSheet: View {
    let request: IdentityTransferRequest
    @Environment(ProfileStore.self) private var profile
    @Environment(\.dismiss) private var dismiss
    @State private var confirmedBackup = false
    @State private var working = false
    @State private var errorMessage: String?

    private var sameBridge: Bool { profile.isBridgeConfigured && profile.bridgeURL == request.bridge }
    private var alreadyInUse: Bool { sameBridge && SecureTokenStore.currentToken(for: request.bridge) == request.token }
    private var replacesIdentity: Bool { sameBridge && profile.hasToken && !alreadyInUse }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Usar el perfil «\(request.label)»", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.headline)
                    Text("Este dispositivo usará el mismo Continuar viendo y las mismas preferencias que ese perfil.")
                        .foregroundStyle(.secondary)
                }
                if alreadyInUse {
                    Section {
                        Label("Este dispositivo ya usa ese perfil.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                } else {
                    if !sameBridge {
                        Section {
                            Text(profile.isBridgeConfigured
                                 ? "El código es del bridge \(request.bridge) y este dispositivo usa \(profile.bridgeURL). Al continuar, la app se conectará a \(request.bridge)."
                                 : "Al continuar, la app se conectará al bridge \(request.bridge).")
                        } header: {
                            Text("Bridge")
                        }
                    }
                    if replacesIdentity {
                        Section {
                            Toggle("Ya guardé el token actual de forma segura", isOn: $confirmedBackup)
                        } header: {
                            Text("Reemplaza la identidad actual")
                        } footer: {
                            Text("Si no guardaste el token de la identidad actual, este dispositivo no podrá volver a abrir su historial. Puedes respaldarlo en Configuración › Identidad privada.")
                        }
                    }
                    Section {
                        Button(working ? "Conectando…" : "Usar este perfil") {
                            Task { await apply() }
                        }
                        .disabled(working || (replacesIdentity && !confirmedBackup))
                    }
                }
                if let errorMessage {
                    Section { ErrorNotice(message: errorMessage) }
                }
            }
            .navigationTitle("Perfil de la TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(alreadyInUse ? "Cerrar" : "Cancelar", role: .cancel) { dismiss() }
                        .disabled(working)
                }
            }
            .interactiveDismissDisabled(working)
        }
        .presentationDetents([.medium, .large])
    }

    private func apply() async {
        working = true
        errorMessage = nil
        defer { working = false }
        do {
            if !sameBridge {
                let health: HealthResponse = try await BridgeClient.get(base: request.bridge, path: "/health", timeoutInterval: 10)
                guard health.ok else { throw BridgeRequestError(message: "El bridge respondió de forma inesperada.") }
            }
            // The token goes to the bridge's Keychain item before the switch,
            // so the identity loads with it.
            try SecureTokenStore.save(request.token, for: request.bridge)
            if sameBridge {
                profile.reloadIdentity()
            } else {
                profile.useBridge(request.bridge)
            }
            Task { await profile.sync(force: true) }
            dismiss()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Scans a TV's QR in the app: a profile ("Llevar al teléfono") or a pairing
/// code. The system Camera app opens the same codes too.
struct CodeScannerSheet: View {
    let onScan: (ScannedCode) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var unrecognized = false

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    QRScannerView { text in
                        guard let code = ScannedCode(text) else {
                            unrecognized = true
                            return false
                        }
                        onScan(code)
                        dismiss()
                        return true
                    }
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    ContentUnavailableView(
                        "No se puede escanear",
                        systemImage: "camera",
                        description: Text("Permite el acceso a la cámara en Ajustes › AniBridge Player, o abre el código con la app Cámara.")
                    )
                }
            }
            .overlay(alignment: .bottom) {
                if unrecognized {
                    Text("Ese código no es de AniBridge Player.")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 32)
                }
            }
            .navigationTitle("Escanear código")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar", role: .cancel) { dismiss() }
                }
            }
        }
    }
}

/// VisionKit's live QR scanner. `onCode` returns true once a code was used.
private struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onCode: (String) -> Bool
        private var used = false

        init(onCode: @escaping (String) -> Bool) {
            self.onCode = onCode
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !used else { return }
            for item in addedItems {
                guard case .barcode(let barcode) = item, let text = barcode.payloadStringValue else { continue }
                if onCode(text) {
                    used = true
                    dataScanner.stopScanning()
                    return
                }
            }
        }
    }
}
