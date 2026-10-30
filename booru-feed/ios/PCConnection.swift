import Foundation

enum PCConnection {
    static let defaultAddress = "https://desktop-s26voof.tail6da04d.ts.net:8443/"
    static func url(_ address: String) -> URL? {
        guard let parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port == nil || (1...65535).contains(parts.port!),
              let url = parts.url else { return nil }
        return url
    }
}

#if canImport(UIKit)
import SwiftUI
import SafariServices

struct PCConnectionView: View {
    @AppStorage("pcFeedAddress") private var address = PCConnection.defaultAddress
    @State private var connection: Destination?
    private struct Destination: Identifiable { let id = UUID(); let url: URL }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Sheet-style pink card holding the address and the connect button.
                VStack(alignment: .leading, spacing: 12) {
                    Label("PC address", systemImage: "desktopcomputer").font(.headline)
                    TextField("https://your-pc.ts.net:8443/", text: $address)
                        .textContentType(.URL).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("PC Booru Feed address")
                        .padding(14).foregroundStyle(.white)
                        .background(Color.ink, in: Capsule())
                    Button { if let url = PCConnection.url(address) { connection = Destination(url: url) } } label: {
                        Label("Connect to Booru Feed", systemImage: "network").font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .overlay(Capsule().stroke(Color.ink, lineWidth: 2))
                    }.buttonStyle(.plain).disabled(PCConnection.url(address) == nil).opacity(PCConnection.url(address) == nil ? 0.4 : 1)
                    if PCConnection.url(address) == nil {
                        Text("Enter an HTTPS address without passwords or pairing codes in the URL.").font(.footnote)
                    }
                }
                .foregroundStyle(Color.ink)
                .padding(18)
                .background(Color.brand, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                VStack(alignment: .leading, spacing: 12) {
                    Text("Before connecting").font(.headline).foregroundStyle(Color.brand)
                    Text("Keep Booru Feed running on your PC with mobile access enabled. Connect Tailscale on both devices using the same account.")
                    Text("If asked to pair, enter the code shown in the PC app’s mobile access settings. Your phone uses the existing scrolling web feed, including its boards, saved media and manga.")
                    Text("If the PC is offline, close the browser and try again when it is online. Local folders and drives still work offline.")
                }
                .font(.footnote).foregroundStyle(.white.opacity(0.8))
                .padding(18)
                .background(Color.panel, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }.padding(16)
        }
        .background(Color.ink)
        .navigationTitle("Connect to PC")
        .fullScreenCover(item: $connection) { PCFeedBrowser(url: $0.url).ignoresSafeArea() }
    }
}

private struct PCFeedBrowser: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let browser = SFSafariViewController(url: url)
        browser.dismissButtonStyle = .close
        browser.preferredBarTintColor = UIColor(Color.ink)
        browser.preferredControlTintColor = UIColor(Color.brand)
        return browser
    }
    func updateUIViewController(_ browser: SFSafariViewController, context: Context) {}
}
#endif
