import SwiftUI
import CoreImage.CIFilterBuiltins

struct QRCodeView: View {
    @ObservedObject var settingsModel: SettingsModel

    @State private var advertisedHost: String?
    @State private var openClawToken: String?
    @State private var openClawPort: Int = 18789
    @State private var connectionURL: String?
    @State private var errorMessage: String?
    @State private var copied = false
    @State private var isLoading = false

    private static let appStoreURL = URL(string: "https://apps.apple.com/jp/app/vibeterm/id6758266443")!

    var body: some View {
        VStack(spacing: 8) {
            Link(destination: Self.appStoreURL) {
                HStack(spacing: 6) {
                    Image(systemName: "iphone")
                        .font(.system(size: 14))
                        .foregroundStyle(PanelTheme.accentCyan)
                    Text("Connect VibeTerm")
                        .font(PanelTheme.titleFont)
                        .foregroundStyle(PanelTheme.textPrimary)
                }
            }
            if let url = connectionURL, let qrImage = generateQRCode(from: url) {
                Link(destination: Self.appStoreURL) {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                        .padding(8)
                        .background(Color.white)
                        .cornerRadius(PanelTheme.cornerRadius)
                }
                .onHover { inside in
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 80))
                        .foregroundStyle(PanelTheme.textTertiary)
                    if let error = errorMessage {
                        Text(error)
                            .foregroundStyle(PanelTheme.accentYellow)
                            .font(PanelTheme.smallFont)
                            .multilineTextAlignment(.center)
                    } else if isLoading {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Fetching from \(settingsModel.config.openclawHost)…")
                            .foregroundStyle(PanelTheme.textSecondary)
                            .font(PanelTheme.smallFont)
                    } else {
                        Text("Loading…")
                            .foregroundStyle(PanelTheme.textSecondary)
                            .font(PanelTheme.smallFont)
                    }
                }
                .frame(width: 200, height: 200)
                .padding(8)
            }

            PanelCard {
                ConnectionInfoRow(label: "Host", value: advertisedHost ?? settingsModel.config.openclawHost)
                ConnectionInfoRow(label: "Port", value: String(openClawPort))
            }

            ActionButton(title: copied ? "Copied!" : "Copy URL", tone: .primary, dense: true) {
                copyURL()
            }

            Link(destination: Self.appStoreURL) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.app")
                        .font(.system(size: 9))
                    Text("Get VibeTerm on App Store")
                        .font(PanelTheme.smallFont)
                }
                .foregroundStyle(PanelTheme.textTertiary)
            }
        }
        .padding(PanelTheme.padding)
        .onAppear {
            loadConnectionInfo()
        }
        .onChange(of: settingsModel.config.openclawHost) { _ in loadConnectionInfo() }
        .onChange(of: settingsModel.config.openclawPort) { _ in loadConnectionInfo() }
    }

    // MARK: - Private Methods

    private func loadConnectionInfo() {
        let host = settingsModel.config.openclawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = settingsModel.config.openclawPort
        guard !host.isEmpty else {
            errorMessage = "Set Host in Settings → Gateway."
            connectionURL = nil
            return
        }
        fetchOpenclawInfo(host: host, fallbackPort: port)
    }

    private func fetchOpenclawInfo(host: String, fallbackPort: Int) {
        // ClawGate API is assumed to live on the same host at port 8765.
        guard let url = URL(string: "http://\(host):8765/v1/openclaw-info") else {
            errorMessage = "Invalid host: \(host)"
            connectionURL = nil
            return
        }
        isLoading = true
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                isLoading = false
                if let error {
                    errorMessage = "Cannot reach \(host): \(error.localizedDescription)"
                    connectionURL = nil
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse else {
                    errorMessage = "Invalid response from \(host)"
                    connectionURL = nil
                    return
                }
                guard httpResponse.statusCode == 200 else {
                    if httpResponse.statusCode == 403 {
                        errorMessage = "Blocked by IP filter at \(host).\nOnly loopback and Tailscale (100.64.0.0/10) are allowed."
                    } else if httpResponse.statusCode == 404 {
                        errorMessage = "OpenClaw not configured on \(host)"
                    } else {
                        errorMessage = "ClawGate at \(host) returned HTTP \(httpResponse.statusCode)"
                    }
                    connectionURL = nil
                    return
                }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let ok = json["ok"] as? Bool, ok,
                      let respHost = json["host"] as? String,
                      let respToken = json["token"] as? String else {
                    errorMessage = "Invalid response from \(host)"
                    connectionURL = nil
                    return
                }
                advertisedHost = respHost
                openClawToken = respToken
                openClawPort = json["port"] as? Int ?? fallbackPort
                errorMessage = nil
                buildConnectionURL()
            }
        }.resume()
    }

    private func buildConnectionURL() {
        guard let host = advertisedHost, let token = openClawToken else {
            connectionURL = nil
            return
        }
        var components = URLComponents()
        components.scheme = "openclaw"
        components.host = "connect"
        components.queryItems = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "port", value: String(openClawPort)),
        ]
        connectionURL = components.string
    }

    private func copyURL() {
        guard let url = connectionURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)

        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
        }
    }

    private func generateQRCode(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()

        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else {
            return nil
        }

        let scale: CGFloat = 10
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: 200, height: 200))
    }
}

private struct ConnectionInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label + ":")
                .foregroundStyle(PanelTheme.textSecondary)
                .frame(width: 50, alignment: .trailing)
            Text(value)
                .foregroundStyle(PanelTheme.textPrimary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .font(PanelTheme.monoFont(size: 12))
    }
}
