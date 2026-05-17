import SwiftUI

struct ChatView: View {
    @ObservedObject var ble: BLEMessenger
    let peer: Peer
    @Environment(\.colorScheme) private var scheme
    @State private var draft = ""

    private var msgs: [ChatMessage] { ble.messages(with: peer.id) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(msgs) { m in
                            HStack {
                                if m.mine { Spacer(minLength: 40) }
                                Text(m.text)
                                    .font(.system(size: 15))
                                    .foregroundStyle(m.mine ? .white : Theme.text(scheme))
                                    .padding(.vertical, 9).padding(.horizontal, 13)
                                    .background(m.mine ? Theme.accent : Theme.surface(scheme))
                                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                                if !m.mine { Spacer(minLength: 40) }
                            }
                            .id(m.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: msgs.count) { _, _ in
                    if let last = msgs.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }

            HStack(spacing: 10) {
                TextField("Message", text: $draft)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 11).padding(.horizontal, 14)
                    .background(Theme.surface(scheme))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button {
                    ble.send(draft, to: peer.id)
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
        .background(Theme.bg(scheme).ignoresSafeArea())
        .navigationTitle(peer.nick)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { ble.connect(peer.id) }
    }
}
