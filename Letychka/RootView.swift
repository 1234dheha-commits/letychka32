import SwiftUI
import UIKit
import PhotosUI

struct RootView: View {
    @StateObject private var ble = BLEMessenger()
    @AppStorage(AppTheme.key) private var themeMode = "dark"
    @Environment(\.colorScheme) private var scheme
    @State private var nickField = ""
    @State private var chatPeer: Peer?
    @State private var showSettings = false
    @State private var avatar: UIImage?
    @State private var avatarItem: PhotosPickerItem?
    @State private var bypassBT = false
    @State private var tab = 0
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg(scheme).ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    if ble.status == .on || bypassBT {
                        Picker("", selection: $tab) {
                            Text("Radar").tag(0)
                            Text("Chats").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 20)
                        .padding(.top, 10)

                        if tab == 0 {
                            statusLine
                            RadarView(ble: ble) { chatPeer = $0 }
                                .padding(20)
                            footer
                        } else {
                            ChatsListView(ble: ble) { chatPeer = $0 }
                        }
                    } else {
                        btRequiredView
                    }
                }
            }
            .navigationDestination(item: $chatPeer) { p in
                ChatView(ble: ble, peer: p)
            }
            .sheet(isPresented: $showSettings) { settingsSheet }
        }
        .tint(Theme.accent)
        .onAppear {
            nickField = ble.nick
            avatar = AvatarStore.load()
            ble.start()
        }
        .onChange(of: avatarItem) { _, item in
            guard let item else { return }
            Task { @MainActor in
                if let data = try? await item.loadTransferable(type: Data.self),
                   let ui = UIImage(data: data) {
                    AvatarStore.save(ui)
                    avatar = ui
                }
            }
        }
    }

    private var header: some View {
        HStack {
            if let a = avatar {
                Button { showSettings = true } label: {
                    Image(uiImage: a).resizable().scaledToFill()
                        .frame(width: 34, height: 34)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Theme.line(scheme), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
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

    private var btIcon: String {
        ble.status == .unsupported
            ? "antenna.radiowaves.left.and.right.slash"
            : "dot.radiowaves.left.and.right"
    }
    private var btTitle: String {
        switch ble.status {
        case .off:          return "Bluetooth is off"
        case .unauthorized: return "Bluetooth access needed"
        case .unsupported:  return "Bluetooth unavailable"
        default:            return "Starting Bluetooth"
        }
    }
    private var btMessage: String {
        switch ble.status {
        case .off:
            return "Letychka works only over Bluetooth. Turn Bluetooth on to find people near you. No internet is used."
        case .unauthorized:
            return "Letychka needs Bluetooth permission to find people near you. Enable it in Settings."
        case .unsupported:
            return "This device does not support Bluetooth LE, so Letychka cannot run here."
        default:
            return "Checking Bluetooth."
        }
    }

    private var btRequiredView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: btIcon)
                .font(.system(size: 58, weight: .light))
                .foregroundStyle(Theme.accent)
            Text(btTitle)
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(Theme.text(scheme))
            Text(btMessage)
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted(scheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            if ble.status == .off || ble.status == .unauthorized {
                Button("Open Settings") {
                    if let u = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(u)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 56).padding(.top, 6)
            }
            Button("Continue without Bluetooth") {
                bypassBT = true
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .padding(.top, 2)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("Your name") {
                    TextField("Anon", text: $nickField)
                        .onSubmit { ble.setNick(nickField) }
                }
                Section("Avatar") {
                    HStack(spacing: 14) {
                        if let a = avatar {
                            Image(uiImage: a).resizable().scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(Circle())
                        } else {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 52))
                                .foregroundStyle(Theme.muted(scheme))
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            PhotosPicker(selection: $avatarItem, matching: .images) {
                                Text(avatar == nil ? "Choose photo" : "Replace photo")
                            }
                            if avatar != nil {
                                Button(role: .destructive) {
                                    AvatarStore.clear()
                                    avatar = nil
                                    avatarItem = nil
                                } label: {
                                    Text("Remove photo")
                                }
                            }
                        }
                    }
                    Text("Your avatar is local only. It is not sent to people nearby; Bluetooth carries just short text.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted(scheme))
                }
                Section("Appearance") {
                    Picker("Theme", selection: $themeMode) {
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }
                Section("Privacy") {
                    Text("Letychka has no account and no sign in. There is nothing to log out of: nothing about you is stored or sent anywhere. Your name and avatar stay only on this phone, and chats disappear when you close the app.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted(scheme))
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Text("Clear everything on this phone")
                    }
                }
                Section {
                    Text("Letychka finds people near you over Bluetooth and lets you message them directly, with no internet and no servers. Everything is anonymous and disappears when you close the app.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted(scheme))
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Clear everything?", isPresented: $showClearConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Clear", role: .destructive) {
                    ble.clearAll()
                    AvatarStore.clear()
                    avatar = nil
                    avatarItem = nil
                    nickField = "Anon"
                }
            } message: {
                Text("Removes your name, avatar and all chats from this phone. This cannot be undone.")
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { ble.setNick(nickField); showSettings = false }
                }
            }
        }
        .tint(Theme.accent)
        // A sheet has its own presentation environment and does NOT inherit
        // the root's preferredColorScheme, so apply it here too. Reactive to
        // themeMode, so the picker switches the sheet live.
        .preferredColorScheme(AppTheme.scheme(for: themeMode))
    }
}
