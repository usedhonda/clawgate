import SwiftUI
import CoreImage.CIFilterBuiltins

struct QRCodeView: View {
    @State private var tailscaleHostname: String?
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
            .padding(.top, 4)

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
                        Text("Fetching from server...")
                            .foregroundStyle(PanelTheme.textSecondary)
                            .font(PanelTheme.smallFont)
                    } else {
                        Text("Loading...")
                            .foregroundStyle(PanelTheme.textSecondary)
                            .font(PanelTheme.smallFont)
                    }
                }
                .frame(width: 200, height: 200)
                .padding(8)
            }

            PanelCard {
                ConnectionInfoRow(label: "Host", value: tailscaleHostname ?? "Not available")
                ConnectionInfoRow(label: "Port", value: String(openClawPort))
            }

            PanelActionButton(title: copied ? "Copied!" : "Copy URL", tone: .primary) {
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
        .frame(width: 300, height: 420)
        .onAppear {
            loadConnectionInfo()
        }
    }

    // MARK: - Private Methods

    private func loadConnectionInfo() {
        let defaults = UserDefaults.standard
        let nodeRole = defaults.string(forKey: "clawgate.nodeRole") ?? "client"
        let federationURL = defaults.string(forKey: "clawgate.federationURL") ?? ""

        if nodeRole == "client" && !federationURL.isEmpty {
            loadFromServer(federationURL: federationURL)
        } else {
            loadFromLocal()
        }
    }

    private func loadFromServer(federationURL: String) {
        guard let wsURL = URL(string: federationURL),
              let host = wsURL.host else {
            errorMessage = "Invalid federation URL"
            return
        }
        let bridgePort = wsURL.port ?? 8765

        let defaults = UserDefaults.standard
        let token = defaults.string(forKey: "clawgate.federationToken")
            ?? defaults.string(forKey: "clawgate.remoteAccessToken") ?? ""

        guard let url = URL(string: "http://\(host):\(bridgePort)/v1/openclaw-info") else {
            errorMessage = "Could not build server URL"
            return
        }

        isLoading = true
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                isLoading = false
                if let error {
                    errorMessage = "Server error: \(error.localizedDescription)"
                    return
                }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let ok = json["ok"] as? Bool, ok,
                      let remoteHost = json["host"] as? String,
                      let remoteToken = json["token"] as? String else {
                    errorMessage = "Invalid response from server"
                    return
                }
                let remotePort = json["port"] as? Int ?? 18789

                tailscaleHostname = remoteHost
                openClawToken = remoteToken
                openClawPort = remotePort
                buildConnectionURL()
            }
        }.resume()
    }

    private func loadFromLocal() {
        tailscaleHostname = getTailscaleHostname()
        if let config = getOpenClawConfig() {
            openClawToken = config.token
            openClawPort = config.port
        }
        buildConnectionURL()
    }

    private func buildConnectionURL() {
        if let host = tailscaleHostname, let token = openClawToken {
            var components = URLComponents()
            components.scheme = "openclaw"
            components.host = "connect"
            components.queryItems = [
                URLQueryItem(name: "host", value: host),
                URLQueryItem(name: "token", value: token),
                URLQueryItem(name: "port", value: String(openClawPort)),
            ]
            connectionURL = components.string
        } else {
            var errors: [String] = []
            if tailscaleHostname == nil {
                errors.append("Tailscale not available")
            }
            if openClawToken == nil {
                errors.append("OpenClaw config not found")
            }
            errorMessage = errors.joined(separator: "\n")
        }
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

// MARK: - Data Fetching

private func getTailscaleHostname() -> String? {
    let paths = [
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]
    guard let cli = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
        return nil
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: cli)
    process.arguments = ["status", "--json"]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
    } catch {
        return nil
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationStatus == 0,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let backendState = json["BackendState"] as? String,
          backendState == "Running",
          let selfInfo = json["Self"] as? [String: Any],
          let dnsName = selfInfo["DNSName"] as? String else {
        return nil
    }

    return dnsName.hasSuffix(".") ? String(dnsName.dropLast()) : dnsName
}

private func getOpenClawConfig() -> (token: String, port: Int)? {
    let configPath = NSString("~/.openclaw/openclaw.json").expandingTildeInPath
    guard let data = FileManager.default.contents(atPath: configPath),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let gateway = json["gateway"] as? [String: Any],
          let auth = gateway["auth"] as? [String: Any],
          let token = auth["token"] as? String,
          !token.isEmpty else {
        return nil
    }

    let port = gateway["port"] as? Int ?? 18789
    return (token: token, port: port)
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
        .font(PanelTheme.bodyFont)
    }
}
