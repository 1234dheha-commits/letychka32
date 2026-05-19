import SwiftUI

/// The shared "nearby room": one common chat for everyone in Bluetooth
/// range. Text only, no servers, broadcast to every reachable phone.
struct RoomView: View {
    @ObservedObject var ble: BLEMessenger
    @AppStorage("hideHints") private var hideHints = false
    @Environment(\.colorScheme) private var scheme
    @State private var draft = ""

    private func nickOf(_ m: ChatMessage) -> String {
        ble.names[m.peerID] ?? L("Anon")
    }

    var body: some View {
        VStack(spacing: 0) {
            if ble.roomMessages.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "person.3")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(Theme.accent)
                    Text(L("Nobody has spoken yet"))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.text(scheme))
                    if !hideHints {
                        Text(L("This is a shared room: everyone near you over Bluetooth sees it. Say something."))
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted(scheme))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 44)
                    }
                    Spacer()
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(ble.roomMessages) { m in
                                HStack {
                                    if m.mine { Spacer(minLength: 40) }
                                    VStack(alignment: m.mine ? .trailing : .leading,
                                           spacing: 2) {
                                        if !m.mine {
                                            Text(nickOf(m))
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundStyle(Theme.accent)
                                        }
                                        Text(ChatView.linkified(m.text))
                                            .font(.system(size: 15))
                                            .foregroundStyle(m.mine ? .white
                                                             : Theme.text(scheme))
                                            .tint(m.mine ? .white : Theme.accent)
                                            .padding(.vertical, 9)
                                            .padding(.horizontal, 13)
                                            .background(m.mine ? Theme.accent
                                                        : Theme.surface(scheme))
                                            .clipShape(RoundedRectangle(
                                                cornerRadius: 15, style: .continuous))
                                    }
                                    if !m.mine { Spacer(minLength: 40) }
                                }
                                .id(m.id)
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: ble.roomMessages.count) { _, _ in
                        if let last = ble.roomMessages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                TextField(L("Message everyone nearby"), text: $draft)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 11).padding(.horizontal, 14)
                    .background(Theme.surface(scheme))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button {
                    ble.sendRoom(draft)
                    draft = ""
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Theme.accent)
                        .clipShape(Circle())
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
