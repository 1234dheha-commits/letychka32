import SwiftUI
import UIKit
import PhotosUI

struct RootView: View {
    @StateObject private var ble = BLEMessenger.shared
    @AppStorage(AppTheme.key) private var themeMode = "dark"
    @AppStorage("hideHints") private var hideHints = false
    @AppStorage("nearbyNotify") private var nearbyNotify = false
    @AppStorage("hideTabLabels") private var hideTabLabels = false
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
                .tabItem { tabLabel(L("Radar"),
                                    icon: "dot.radiowaves.left.and.right") }
                .tag(0)
            chatsTab
                .tabItem { tabLabel(L("Chats"),
                                    icon: "bubble.left.and.bubble.right.fill") }
                .badge(ble.unreadTotal + ble.roomUnread)
                .tag(1)
            settingsTab
                .tabItem { tabLabel(L("Settings"),
                                    icon: "gearshape.fill") }
                .tag(2)
            profileTab
                .tabItem { tabLabel(L("Profile"),
                                    icon: "person.crop.circle.fill") }
                .tag(3)
        }
    }

    /// One source of truth for tab item content. When `hideTabLabels` is on
    /// we render the icon only; SwiftUI auto-centres it in the tab slot.
    @ViewBuilder
    private func tabLabel(_ text: String, icon: String) -> some View {
        if hideTabLabels {
            Image(systemName: icon)
        } else {
            Label(text, systemImage: icon)
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
                    if ble.conversations().isEmpty {
                        chatsEmptyState
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ChatsListView(ble: ble) { chatsPeer = $0 }
                            }
                        }
                    }
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

    /// Centred "No chats yet" block; sits in the chats tab when the BLE
    /// conversations list is empty.
    private var chatsEmptyState: some View {
        VStack(spacing: 10) {
            Spacer().frame(height: 80)
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(Theme.accent)
            Text(L("No chats yet"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text(scheme))
            if !hideHints {
                Text(L("Find people on the radar and say hi. Chats are saved on this phone so they are still here next time."))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted(scheme))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 44)
            }
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    Toggle(L("Hide tab labels"), isOn: $hideTabLabels)
                    if !hideHints {
                        Text(L("Hides the small text under each tab icon so only the icons are shown."))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted(scheme))
                    }
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
                Section(L("Your name")) {
                    TextField(Ident.defaultNick, text: $nickField)
                        .onSubmit { ble.setNick(nickField) }
                    Text(joinedText)
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
