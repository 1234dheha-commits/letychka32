import SwiftUI

struct RootView: View {
    @StateObject private var ble = BLEMessenger()
    @AppStorage(AppTheme.key) private var themeMode = "system"
    @Environment(\.colorScheme) private var scheme
    @State private var nickField = ""
    @State private var chatPeer: Peer?
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg(scheme).ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    statusLine
                    RadarView(ble: ble) { chatPeer = $0 }
                        .padding(20)
                    footer
                }
            }
            .navigationDestination(item: $chatPeer) { p in
                ChatView(ble: ble, peer: p)
            }
            .sheet(isPresented: $showSettings) { settingsSheet }
        }
        .tint(Theme.accent)
        .preferredColorScheme(AppTheme.scheme(for: themeMode))
        .onAppear {
            nickField = ble.nick
            ble.start()
        }
    }

    private var header: some View {
        HStack {
            Text("Letychka")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.text(scheme))
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(Theme.text(scheme))
            }
        }
        .padding(.horizontal, 20).padding(.top, 8)
    }

    private var statusLine: some View {
        Text(ble.poweredOn
             ? (ble.peers.isEmpty ? "Looking for people nearby"
                                  : "\(ble.peers.count) nearby, tap to chat")
             : "Turn on Bluetooth to find people nearby")
            .font(.system(size: 13))
            .foregroundStyle(Theme.muted(scheme))
            .padding(.top, 6)
    }

    private var footer: some View {
        Text("Anonymous. No internet, no servers, no accounts. Works only with people near you.")
            .font(.system(size: 12))
            .foregroundStyle(Theme.muted(scheme))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32).padding(.bottom, 16)
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("Your name") {
                    TextField("Anon", text: $nickField)
                        .onSubmit { ble.setNick(nickField) }
                }
                Section("Appearance") {
                    Picker("Theme", selection: $themeMode) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Text("Letychka finds people near you over Bluetooth and lets you message them directly, with no internet and no servers. Everything is anonymous and disappears when you close the app.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted(scheme))
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { ble.setNick(nickField); showSettings = false }
                }
            }
        }
        .tint(Theme.accent)
    }
}
