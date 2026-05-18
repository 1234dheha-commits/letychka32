import SwiftUI
import UIKit
import PhotosUI
import AuthenticationServices

struct RootView: View {
    @StateObject private var ble = BLEMessenger.shared
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
    @AppStorage("appleUserID") private var appleUserID = ""
    @AppStorage("appleUserName") private var appleUserName = ""
    @State private var signInError: String?
    @State private var showDeleteAccountConfirm = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg(scheme).ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    if ble.status == .on || bypassBT {
                        Picker("", selection: $tab) {
                            Text(L("Radar")).tag(0)
                            Text(ble.unreadTotal > 0
                                 ? L("Chats (%d)", ble.unreadTotal)
                                 : L("Chats")).tag(1)
                            Text(L("Room")).tag(2)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 20)
                        .padding(.top, 10)

                        if tab == 0 {
                            statusLine
                            RadarView(ble: ble) { chatPeer = $0 }
                                .padding(20)
                            footer
                        } else if tab == 1 {
                            ChatsListView(ble: ble) { chatPeer = $0 }
                        } else {
                            RoomView(ble: ble)
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
            if UserDefaults.standard.object(forKey: "firstLaunch") == nil {
                UserDefaults.standard.set(Date(), forKey: "firstLaunch")
            }
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

    private var statusText: String {
        if !ble.visible { return L("You are hidden. Turn it back on in Settings.") }
        if !ble.poweredOn { return L("Turn on Bluetooth to find people nearby") }
        return ble.peers.isEmpty
            ? L("Looking for people nearby")
            : L("%d nearby, tap to chat", ble.peers.count)
    }

    private var statusLine: some View {
        Text(statusText)
            .font(.system(size: 13))
            .foregroundStyle(Theme.muted(scheme))
            .padding(.top, 6)
    }

    private var footer: some View {
        Text(L("Anonymous. No internet, no servers, no accounts. Works only with people near you."))
            .font(.system(size: 12))
            .foregroundStyle(Theme.muted(scheme))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32).padding(.bottom, 16)
    }

    private var joinedText: String {
        let d = (UserDefaults.standard.object(forKey: "firstLaunch") as? Date) ?? Date()
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return L("On Letychka since %@", f.string(from: d))
    }

    private var btIcon: String {
        ble.status == .unsupported
            ? "antenna.radiowaves.left.and.right.slash"
            : "dot.radiowaves.left.and.right"
    }
    private var btTitle: String {
        switch ble.status {
        case .off:          return L("Bluetooth is off")
        case .unauthorized: return L("Bluetooth access needed")
        case .unsupported:  return L("Bluetooth unavailable")
        default:            return L("Starting Bluetooth")
        }
    }
    private var btMessage: String {
        switch ble.status {
        case .off:
            return L("Letychka works only over Bluetooth. Turn Bluetooth on to find people near you. No internet is used.")
        case .unauthorized:
            return L("Letychka needs Bluetooth permission to find people near you. Enable it in Settings.")
        case .unsupported:
            return L("This device does not support Bluetooth LE, so Letychka cannot run here.")
        default:
            return L("Checking Bluetooth.")
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
                Button(L("Open Settings")) {
                    if let u = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(u)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 56).padding(.top, 6)
            }
            Button(L("Continue without Bluetooth")) {
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
                Section(L("Account")) {
                    if !appleUserID.isEmpty {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(Theme.accent)
                                .font(.system(size: 20))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(appleUserName.isEmpty
                                     ? L("Signed in with Apple")
                                     : L("Signed in as %@", appleUserName))
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Theme.text(scheme))
                                Text(L("Optional. Nothing is stored on a server."))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.muted(scheme))
                            }
                            Spacer()
                        }
                        Button(role: .destructive) {
                            appleUserID = ""
                            appleUserName = ""
                        } label: {
                            Label(L("Sign out"), systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        Button(role: .destructive) {
                            showDeleteAccountConfirm = true
                        } label: {
                            Label(L("Delete account"), systemImage: "trash.fill")
                        }
                        .confirmationDialog(
                            L("Delete account and all local data? This removes your Apple sign-in, your name, avatar and chats from this phone. It cannot be undone."),
                            isPresented: $showDeleteAccountConfirm,
                            titleVisibility: .visible
                        ) {
                            Button(L("Delete"), role: .destructive) {
                                appleUserID = ""
                                appleUserName = ""
                                ble.clearAll()
                                AvatarStore.clear()
                                avatar = nil
                                avatarItem = nil
                                nickField = "Anon"
                            }
                            Button(L("Cancel"), role: .cancel) {}
                        }
                    } else {
                        Text(L("Sign in with Apple is optional. Letychka works fully without it and stays anonymous over Bluetooth. Signing in just lets you have an account you can delete."))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted(scheme))
                        SignInWithAppleButton(.signIn,
                            onRequest: { req in req.requestedScopes = [.fullName] },
                            onCompletion: { result in
                                switch result {
                                case .success(let auth):
                                    if let cred = auth.credential as? ASAuthorizationAppleIDCredential {
                                        appleUserID = cred.user
                                        if let fn = cred.fullName?.givenName, !fn.isEmpty {
                                            appleUserName = fn
                                        }
                                    }
                                    signInError = nil
                                case .failure(let err):
                                    signInError = err.localizedDescription
                                }
                            })
                        .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
                        .frame(height: 44)
                        if let msg = signInError {
                            Text(msg).font(.system(size: 12)).foregroundStyle(.red)
                        }
                    }
                }
                Section(L("Your name")) {
                    TextField(L("Anon"), text: $nickField)
                        .onSubmit { ble.setNick(nickField) }
                    Text(joinedText)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted(scheme))
                }
                Section(L("Nearby")) {
                    Toggle(L("Show me on the radar"), isOn: Binding(
                        get: { ble.visible },
                        set: { ble.setVisible($0) }))
                    Text(L("Turn off to disconnect from the map. You become invisible to people nearby and your radar clears. Turn it back on to reconnect."))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted(scheme))
                }
                Section(L("Avatar")) {
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
                                Text(avatar == nil ? L("Choose photo") : L("Replace photo"))
                            }
                            if avatar != nil {
                                Button(role: .destructive) {
                                    AvatarStore.clear()
                                    avatar = nil
                                    avatarItem = nil
                                } label: {
                                    Text(L("Remove photo"))
                                }
                            }
                        }
                    }
                    Text(L("Your avatar is local only. It is not sent to people nearby; Bluetooth carries just short text."))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted(scheme))
                }
                Section(L("Appearance")) {
                    Picker(L("Theme"), selection: $themeMode) {
                        Text(L("Light")).tag("light")
                        Text(L("Dark")).tag("dark")
                    }
                    .pickerStyle(.segmented)
                }
                if !ble.blocked.isEmpty {
                    Section(L("Blocked")) {
                        ForEach(Array(ble.blocked), id: \.self) { bid in
                            HStack {
                                Text(ble.names[bid] ?? L("Unknown"))
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.text(scheme))
                                Spacer()
                                Button(L("Unblock")) { ble.unblock(bid) }
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }
                Section(L("Privacy")) {
                    Text(L("Letychka has no account and no sign in. There is nothing to log out of: nothing about you is sent to any server. Your name, avatar and chats are stored only on this phone. Use the button below to wipe all of it."))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted(scheme))
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Text(L("Clear everything on this phone"))
                    }
                }
                Section {
                    Text(L("Letychka finds people near you over Bluetooth and lets you message them directly, with no internet and no servers. It stays anonymous and everything is kept only on your phone."))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted(scheme))
                }
            }
            .navigationTitle(L("Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .alert(L("Clear everything?"), isPresented: $showClearConfirm) {
                Button(L("Cancel"), role: .cancel) {}
                Button(L("Clear"), role: .destructive) {
                    ble.clearAll()
                    AvatarStore.clear()
                    avatar = nil
                    avatarItem = nil
                    nickField = "Anon"
                }
            } message: {
                Text(L("Removes your name, avatar and all chats from this phone. This cannot be undone."))
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { ble.setNick(nickField); showSettings = false }
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
