import SwiftUI
import UIKit
import PhotosUI
import AuthenticationServices

struct RootView: View {
    @StateObject private var ble = BLEMessenger.shared
    @ObservedObject private var global = Global.shared
    @AppStorage(AppTheme.key) private var themeMode = "dark"
    @AppStorage("hideHints") private var hideHints = false
    @AppStorage("nearbyNotify") private var nearbyNotify = false
    @AppStorage("netMode") private var netMode = "ble"   // ble | global | both
    @AppStorage(Lang.key) private var appLang = "system"
    @Environment(\.colorScheme) private var scheme
    @State private var nickField = ""
    @State private var avatar: UIImage?
    @State private var avatarItem: PhotosPickerItem?
    @State private var bypassBT = false
    @State private var tab = 0
    @State private var radarPeer: Peer?
    @State private var chatsPeer: Peer?
    @State private var showRoom = false
    @State private var showClearConfirm = false
    @AppStorage("appleUserID") private var appleUserID = ""
    @AppStorage("appleUserName") private var appleUserName = ""
    @State private var signInError: String?
    @State private var showDeleteAccountConfirm = false

    var body: some View {
        Group {
            if ble.status == .on || bypassBT {
                mainTabs
            } else {
                btRequiredView
                    .background(Theme.bg(scheme).ignoresSafeArea())
            }
        }
        .tint(Theme.accent)
        .onAppear {
            nickField = ble.nick
            avatar = AvatarStore.load()
            if UserDefaults.standard.object(forKey: "firstLaunch") == nil {
                UserDefaults.standard.set(Date(), forKey: "firstLaunch")
            }
            ble.start()
            ble.setMyAvatar(Self.tinyAvatar(avatar))
            openPending()
        }
        .onChange(of: tab) { old, _ in
            if old == 3 { ble.setNick(nickField) }
        }
        .onChange(of: avatarItem) { _, item in
            guard let item else { return }
            Task { @MainActor in
                if let data = try? await item.loadTransferable(type: Data.self),
                   let ui = UIImage(data: data) {
                    AvatarStore.save(ui)
                    avatar = ui
                    ble.setMyAvatar(Self.tinyAvatar(ui))
                }
            }
        }
        .onChange(of: ble.pendingOpenRoom) { _, v in
            if v { openPending() }
        }
        .onChange(of: ble.pendingOpenPeer) { _, v in
            if v != nil { openPending() }
        }
    }

    // MARK: Tabs

    private var mainTabs: some View {
        TabView(selection: $tab) {
            radarTab
                .tabItem {
                    Label(L("Radar"),
                          systemImage: "dot.radiowaves.left.and.right")
                }
                .tag(0)
            chatsTab
                .tabItem {
                    Label(L("Chats"),
                          systemImage: "bubble.left.and.bubble.right.fill")
                }
                .badge(ble.unreadTotal + ble.roomUnread)
                .tag(1)
            if netMode != "ble" {
                globalTab
                    .tabItem {
                        Label(L("Global"), systemImage: "globe")
                    }
                    .tag(4)
            }
            settingsTab
                .tabItem {
                    Label(L("Settings"), systemImage: "gearshape.fill")
                }
                .tag(2)
            profileTab
                .tabItem {
                    Label(L("Profile"),
                          systemImage: "person.crop.circle.fill")
                }
                .tag(3)
        }
    }

    private var radarTab: some View {
        NavigationStack {
            ZStack {
                Theme.bg(scheme).ignoresSafeArea()
                VStack(spacing: 0) {
                    if !ble.visible {
                        Text(L("You are hidden. Turn it back on in Settings."))
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.accent)
                            .padding(.top, 6)
                    }
                    RadarView(ble: ble) { radarPeer = $0 }
                        .padding(20)
                    if !hideHints { footer }
                }
            }
            .navigationTitle(L("Radar"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $radarPeer) { p in
                ChatView(ble: ble, peer: p)
            }
        }
    }

    private var chatsTab: some View {
        NavigationStack {
            ZStack {
                Theme.bg(scheme).ignoresSafeArea()
                VStack(spacing: 0) {
                    roomRow
                    ChatsListView(ble: ble) { chatsPeer = $0 }
                }
            }
            .navigationTitle(L("Chats"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $chatsPeer) { p in
                ChatView(ble: ble, peer: p)
            }
            .navigationDestination(isPresented: $showRoom) {
                RoomView(ble: ble)
            }
        }
    }

    private var globalTab: some View {
        NavigationStack { GlobalChatsView() }
    }

    private var roomRow: some View {
        Button { showRoom = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Theme.accent, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Room"))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.text(scheme))
                    Text(L("Everyone in Bluetooth range"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted(scheme))
                }
                Spacer()
                if ble.roomUnread > 0 {
                    Text("\(ble.roomUnread)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.accent, in: Capsule())
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.muted(scheme))
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .overlay(Divider(), alignment: .bottom)
    }

    // MARK: Settings tab

    private var settingsTab: some View {
        NavigationStack {
            Form {
                Section(L("Network mode")) {
                    Picker(L("Network mode"), selection: $netMode) {
                        Text(L("Bluetooth only")).tag("ble")
                        Text(L("Global only")).tag("global")
                        Text(L("Bluetooth and Global")).tag("both")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    if !hideHints {
                        Text(L("Global mode is in early beta. Direct chats, search by username and groups work. Messages travel through Supabase (EU) and are not yet end-to-end encrypted, so the server operator could read them. Bluetooth mode stays fully offline and end-to-end encrypted as before."))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted(scheme))
                    }
                }
                Section(L("Nearby")) {
                    Toggle(L("Show me on the radar"), isOn: Binding(
                        get: { ble.visible },
                        set: { ble.setVisible($0) }))
                    if !hideHints {
                        Text(L("Turn off to disconnect from the map. You become invisible to people nearby and your radar clears. Turn it back on to reconnect."))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted(scheme))
                    }
                    Toggle(L("Notify about people nearby"),
                           isOn: $nearbyNotify)
                    if !hideHints {
                        Text(L("A small notification when someone new appears in Bluetooth range. Off by default."))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted(scheme))
                    }
                }
                Section(L("Language")) {
                    Picker(L("Language"), selection: Binding(
                        get: { appLang },
                        set: { appLang = $0; Lang.set($0) })) {
                        Text(L("System default")).tag("system")
                        Text("English").tag("en")
                        Text("Українська").tag("uk")
                        Text("Русский").tag("ru")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                Section(L("Appearance")) {
                    Picker(L("Theme"), selection: $themeMode) {
                        Text(L("Light")).tag("light")
                        Text(L("Dark")).tag("dark")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Toggle(L("Hide hints"), isOn: $hideHints)
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
                    if !hideHints {
                        Text(L("Letychka has no account and no sign in. There is nothing to log out of: nothing about you is sent to any server. Your name, avatar and chats are stored only on this phone. Use the button below to wipe all of it."))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted(scheme))
                    }
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Text(L("Clear everything on this phone"))
                    }
                }
                if !hideHints {
                    Section {
                        Text(L("Letychka finds people near you over Bluetooth and lets you message them directly, with no internet and no servers. It stays anonymous and everything is kept only on your phone."))
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted(scheme))
                    }
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
                    nickField = Ident.defaultNick
                }
            } message: {
                Text(L("Removes your name, avatar and all chats from this phone. This cannot be undone."))
            }
        }
    }

    // MARK: Profile tab

    private var profileTab: some View {
        NavigationStack {
            Form {
                Section(L("Account")) {
                    if !appleUserID.isEmpty {
                        signedInBlock
                    } else {
                        signedOutBlock
                    }
                }
                Section(L("Your name")) {
                    TextField(Ident.defaultNick, text: $nickField)
                        .onSubmit { ble.setNick(nickField) }
                    Text(joinedText)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted(scheme))
                }
                if netMode != "ble" {
                    Section(L("Your global username")) {
                        HStack {
                            Text(global.me?.username
                                 ?? Ident.defaultNick)
                                .font(.system(size: 15,
                                              weight: .semibold))
                                .foregroundStyle(Theme.text(scheme))
                                .textSelection(.enabled)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                UIPasteboard.general.string =
                                    global.me?.username
                                    ?? Ident.defaultNick
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                        }
                        if !hideHints {
                            Text(L("Share this so others can find you in Global. It is created automatically when Global mode is enabled."))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.muted(scheme))
                        }
                    }
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
                                    ble.setMyAvatar(nil)
                                } label: {
                                    Text(L("Remove photo"))
                                }
                            }
                        }
                    }
                    if !hideHints {
                        Text(L("Your avatar is shared over Bluetooth with people near you so they see your photo. It is tiny and never goes to any server."))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted(scheme))
                    }
                }
            }
            .navigationTitle(L("Profile"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var signedInBlock: some View {
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
                if !hideHints {
                    Text(L("Optional. Nothing is stored on a server."))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted(scheme))
                }
            }
            Spacer()
        }
        Button(role: .destructive) {
            appleUserID = ""
            appleUserName = ""
        } label: {
            Label(L("Sign out"),
                  systemImage: "rectangle.portrait.and.arrow.right")
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
                nickField = Ident.defaultNick
            }
            Button(L("Cancel"), role: .cancel) {}
        }
    }

    @ViewBuilder
    private var signedOutBlock: some View {
        if !hideHints {
            Text(L("Sign in with Apple is optional. Letychka works fully without it and stays anonymous over Bluetooth. Signing in just lets you have an account you can delete."))
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted(scheme))
        }
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
                        // Phase E: also sign into Supabase using the Apple
                        // identity token, so the account is tied to Apple
                        // and survives reinstall on the same Apple ID.
                        if let tokenData = cred.identityToken,
                           let token = String(data: tokenData,
                                              encoding: .utf8) {
                            Task { await Supa.shared.signInWithApple(idToken: token) }
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

    // MARK: Helpers

    /// Consume a "tapped a notification" request: jump to that chat / Room.
    private func openPending() {
        if ble.pendingOpenRoom {
            ble.pendingOpenRoom = false
            tab = 1
            chatsPeer = nil
            showRoom = true
            return
        }
        if let pid = ble.pendingOpenPeer {
            ble.pendingOpenPeer = nil
            tab = 1
            chatsPeer = Peer(id: pid,
                             nick: ble.names[pid]
                                 ?? Ident.defaultNick(for: pid),
                             rssi: -65, lastSeen: Date())
        }
    }

    /// A very small avatar (~64px JPEG) to broadcast over Bluetooth.
    static func tinyAvatar(_ image: UIImage?) -> Data? {
        guard let image else { return nil }
        let dim: CGFloat = 64
        let s = min(1, dim / max(image.size.width, image.size.height))
        let sz = CGSize(width: image.size.width * s, height: image.size.height * s)
        let r = UIGraphicsImageRenderer(size: sz)
        let img = r.image { _ in image.draw(in: CGRect(origin: .zero, size: sz)) }
        return img.jpegData(compressionQuality: 0.4)
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
}
