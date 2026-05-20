import Foundation
import Combine
import Supabase

/// Online (Supabase-backed) data layer for the Global mode. Bluetooth keeps
/// running in parallel and is untouched. Everything here assumes Supa.shared
/// already has a session (anonymous or Apple). If the call fails for any
/// reason the UI just shows the previous local state.
@MainActor
final class Global: ObservableObject {
    static let shared = Global()

    // MARK: Models that match the database row shapes

    struct Profile: Identifiable, Hashable, Decodable {
        let id: UUID
        let username: String
        let display_name: String?
        let avatar_url: String?
    }

    enum ChatKind: String, Codable { case direct, group }

    struct Chat: Identifiable, Hashable, Decodable {
        let id: UUID
        let kind: ChatKind
        let name: String?
        let created_at: Date
    }

    /// One row in our local view of the chats list. Joins the chat itself
    /// with the other party (for direct chats) and the latest message.
    struct ChatRow: Identifiable, Hashable {
        let chat: Chat
        var members: [Profile]      // everyone, including me
        var lastMessage: Message?
        var unread: Int
        var id: UUID { chat.id }

        /// For direct chats: the other person. For group: returns nil.
        func otherParty(me: UUID) -> Profile? {
            guard chat.kind == .direct else { return nil }
            return members.first(where: { $0.id != me })
        }
    }

    struct Message: Identifiable, Hashable, Decodable {
        let id: UUID
        let chat_id: UUID
        let sender_id: UUID
        let body: String?
        let media_url: String?
        let created_at: Date
    }

    // MARK: Observable state

    @Published var chats: [ChatRow] = []
    @Published var me: Profile?
    /// Latest messages keyed by chat id. Updated by `openChat`.
    @Published var messages: [UUID: [Message]] = [:]

    private var pollTask: Task<Void, Never>?
    private var openChatID: UUID?

    private init() {}

    // MARK: Public API

    /// Hydrate `me` + chats list. Safe to call repeatedly.
    func refresh() async {
        do {
            try await ensureMyProfile()
            try await loadChats()
        } catch {
            print("Global.refresh failed: \(error)")
        }
    }

    enum RenameResult: Equatable {
        case ok
        case empty
        case tooShort
        case tooLong
        case taken
        case offline
    }

    /// Rename my own global username. The `profiles.username` column is
    /// UNIQUE, so we map a Postgres 23505 unique-violation to .taken so the
    /// UI can show a friendly "name already in use" message instead of a
    /// raw server error.
    func renameMe(_ newName: String) async -> RenameResult {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed.count < 3 { return .tooShort }
        if trimmed.count > 30 { return .tooLong }
        guard let myID = me?.id else { return .offline }
        struct Update: Encodable { let username: String }
        do {
            try await Supa.shared.client
                .from("profiles")
                .update(Update(username: trimmed))
                .eq("id", value: myID)
                .execute()
            await refresh()
            return .ok
        } catch {
            // PostgrestError surfaces the message; treat any error that
            // mentions duplicate / 23505 / unique as a uniqueness collision.
            let s = "\(error)".lowercased()
            if s.contains("duplicate") || s.contains("23505")
                || s.contains("unique") {
                return .taken
            }
            print("Global.renameMe failed: \(error)")
            return .offline
        }
    }

    /// Find profiles whose username starts with `prefix` (case-insensitive).
    /// Hides ourselves from the result so we cannot start a chat with self.
    func searchUsers(prefix: String) async -> [Profile] {
        let q = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        do {
            let rows: [Profile] = try await Supa.shared.client
                .from("profiles")
                .select("id,username,display_name,avatar_url")
                .ilike("username", pattern: "\(q)%")
                .limit(20)
                .execute()
                .value
            let myID = me?.id
            return rows.filter { $0.id != myID }
        } catch {
            print("Global.searchUsers failed: \(error)")
            return []
        }
    }

    /// Ensure there is a direct chat with `other`, return its id. If one
    /// already exists, reuse it. Two RPC-ish round trips, no server fn yet.
    func openDirectChat(with other: Profile) async -> UUID? {
        guard let myID = me?.id else { return nil }
        // 1. Try to find an existing direct chat that contains both ids.
        struct ChatMemberRow: Decodable { let chat_id: UUID }
        do {
            let mine: [ChatMemberRow] = try await Supa.shared.client
                .from("chat_members")
                .select("chat_id")
                .eq("user_id", value: myID)
                .execute()
                .value
            let myChatIDs = mine.map(\.chat_id)
            if !myChatIDs.isEmpty {
                let theirs: [ChatMemberRow] = try await Supa.shared.client
                    .from("chat_members")
                    .select("chat_id")
                    .eq("user_id", value: other.id)
                    .in("chat_id", values: myChatIDs)
                    .execute()
                    .value
                if let shared = theirs.first {
                    // Confirm it's a direct chat.
                    let chats: [Chat] = try await Supa.shared.client
                        .from("chats")
                        .select("id,kind,name,created_at")
                        .eq("id", value: shared.chat_id)
                        .eq("kind", value: "direct")
                        .limit(1)
                        .execute()
                        .value
                    if let c = chats.first { return c.id }
                }
            }
        } catch {
            print("Global.openDirectChat lookup failed: \(error)")
        }
        // 2. Create one. We generate the chat UUID on the client so we do
        //    not need `.insert().select()` to get it back. The SELECT
        //    policy on `chats` requires the caller to already be a member,
        //    which is false in the split-second BETWEEN inserting the chat
        //    and inserting our own chat_members row — so the returning
        //    select would come back empty and we would think it failed.
        do {
            let newID = UUID()
            struct NewChat: Encodable {
                let id: UUID
                let kind: String
                let created_by: UUID
            }
            try await Supa.shared.client
                .from("chats")
                .insert(NewChat(id: newID, kind: "direct",
                                created_by: myID))
                .execute()
            struct NewMember: Encodable {
                let chat_id: UUID
                let user_id: UUID
                let role: String
            }
            try await Supa.shared.client
                .from("chat_members")
                .insert(NewMember(chat_id: newID,
                                  user_id: myID, role: "owner"))
                .execute()
            try await Supa.shared.client
                .from("chat_members")
                .insert(NewMember(chat_id: newID,
                                  user_id: other.id, role: "member"))
                .execute()
            await refresh()
            return newID
        } catch {
            print("Global.openDirectChat insert failed: \(error)")
            return nil
        }
    }

    /// Create a group chat with `name` and `members` (besides me). Returns
    /// the new chat id, or nil on failure. I become the owner. Same trick
    /// as `openDirectChat`: client-generated UUID so we don't need to read
    /// the row back through a SELECT policy that we don't yet satisfy.
    func createGroup(name: String, members: [Profile]) async -> UUID? {
        guard let myID = me?.id else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let newID = UUID()
            struct NewChat: Encodable {
                let id: UUID
                let kind: String
                let name: String
                let created_by: UUID
            }
            try await Supa.shared.client
                .from("chats")
                .insert(NewChat(id: newID, kind: "group",
                                name: trimmed, created_by: myID))
                .execute()
            struct NewMember: Encodable {
                let chat_id: UUID
                let user_id: UUID
                let role: String
            }
            try await Supa.shared.client
                .from("chat_members")
                .insert(NewMember(chat_id: newID,
                                  user_id: myID, role: "owner"))
                .execute()
            for m in members where m.id != myID {
                try? await Supa.shared.client
                    .from("chat_members")
                    .insert(NewMember(chat_id: newID,
                                      user_id: m.id, role: "member"))
                    .execute()
            }
            await refresh()
            return newID
        } catch {
            print("Global.createGroup failed: \(error)")
            return nil
        }
    }

    /// Rename a group (owner/admin only on the server side; we just try).
    func renameGroup(_ chatID: UUID, name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        struct Update: Encodable { let name: String }
        do {
            try await Supa.shared.client
                .from("chats")
                .update(Update(name: trimmed))
                .eq("id", value: chatID)
                .execute()
            await refresh()
        } catch {
            print("Global.renameGroup failed: \(error)")
        }
    }

    /// Leave a chat (delete my membership). Server policy allows me to
    /// delete my own row.
    func leave(_ chatID: UUID) async {
        guard let myID = me?.id else { return }
        do {
            try await Supa.shared.client
                .from("chat_members")
                .delete()
                .eq("chat_id", value: chatID)
                .eq("user_id", value: myID)
                .execute()
            await refresh()
        } catch {
            print("Global.leave failed: \(error)")
        }
    }

    /// Add another user to a group I admin/own. The server enforces the
    /// rule, we just send the row.
    func addMember(_ chatID: UUID, user: Profile) async {
        struct NewMember: Encodable {
            let chat_id: UUID
            let user_id: UUID
            let role: String
        }
        do {
            try await Supa.shared.client
                .from("chat_members")
                .insert(NewMember(chat_id: chatID, user_id: user.id,
                                  role: "member"))
                .execute()
            await refresh()
        } catch {
            print("Global.addMember failed: \(error)")
        }
    }

    /// Load recent messages for a chat and start a light polling loop that
    /// pulls anything newer than the last id every ~2 seconds. Simpler and
    /// more portable than Realtime; good enough for v1 + low message rates.
    func openChat(_ chatID: UUID) async {
        openChatID = chatID
        await loadMessages(chatID, since: nil)
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                let last = await MainActor.run {
                    self.messages[chatID]?.last?.created_at
                }
                await self.loadMessages(chatID, since: last)
            }
        }
    }

    func closeChat() async {
        openChatID = nil
        pollTask?.cancel()
        pollTask = nil
    }

    private func loadMessages(_ chatID: UUID, since: Date?) async {
        do {
            var q = Supa.shared.client
                .from("messages")
                .select("id,chat_id,sender_id,body,media_url,created_at")
                .eq("chat_id", value: chatID)
            if let since {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                q = q.gt("created_at", value: iso.string(from: since))
            }
            let rows: [Message] = try await q
                .order("created_at", ascending: true)
                .limit(200)
                .execute()
                .value
            if rows.isEmpty { return }
            var list = messages[chatID] ?? []
            let known = Set(list.map(\.id))
            for r in rows where !known.contains(r.id) { list.append(r) }
            messages[chatID] = list
        } catch {
            print("Global.loadMessages failed: \(error)")
        }
    }

    /// Insert a text message. Use insert.select to get the server row back
    /// (with the canonical id + created_at) and drop it into the local list
    /// so our own bubble appears immediately instead of after the 2s poll.
    func sendText(_ text: String, to chatID: UUID) async {
        guard let myID = me?.id else { return }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        struct NewMsg: Encodable {
            let chat_id: UUID
            let sender_id: UUID
            let body: String
        }
        do {
            let rows: [Message] = try await Supa.shared.client
                .from("messages")
                .insert(NewMsg(chat_id: chatID, sender_id: myID, body: body))
                .select("id,chat_id,sender_id,body,media_url,created_at")
                .execute()
                .value
            if let m = rows.first {
                var list = messages[chatID] ?? []
                if !list.contains(where: { $0.id == m.id }) {
                    list.append(m)
                    messages[chatID] = list
                }
            }
        } catch {
            print("Global.sendText failed: \(error)")
        }
    }

    // MARK: Internals

    private func ensureMyProfile() async throws {
        guard let uid = Supa.shared.client.auth.currentUser?.id else { return }
        let rows: [Profile] = try await Supa.shared.client
            .from("profiles")
            .select("id,username,display_name,avatar_url")
            .eq("id", value: uid)
            .limit(1)
            .execute()
            .value
        me = rows.first
    }

    private func loadChats() async throws {
        guard let myID = me?.id else { return }
        // 1. all chat ids I am a member of
        struct MemberRow: Decodable { let chat_id: UUID }
        let myMemberships: [MemberRow] = try await Supa.shared.client
            .from("chat_members")
            .select("chat_id")
            .eq("user_id", value: myID)
            .execute()
            .value
        let chatIDs = myMemberships.map(\.chat_id)
        guard !chatIDs.isEmpty else {
            chats = []
            return
        }
        // 2. chat rows
        let chatRows: [Chat] = try await Supa.shared.client
            .from("chats")
            .select("id,kind,name,created_at")
            .in("id", values: chatIDs)
            .execute()
            .value
        // 3. every member of every chat (so we can show the other party)
        struct MemberFull: Decodable {
            let chat_id: UUID
            let user_id: UUID
        }
        let memberships: [MemberFull] = try await Supa.shared.client
            .from("chat_members")
            .select("chat_id,user_id")
            .in("chat_id", values: chatIDs)
            .execute()
            .value
        // 4. profiles of those users
        let userIDs = Array(Set(memberships.map(\.user_id)))
        let profiles: [Profile] = try await Supa.shared.client
            .from("profiles")
            .select("id,username,display_name,avatar_url")
            .in("id", values: userIDs)
            .execute()
            .value
        let byID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        // 5. last message per chat: pull recent batch, then collapse client-side
        let recent: [Message] = try await Supa.shared.client
            .from("messages")
            .select("id,chat_id,sender_id,body,media_url,created_at")
            .in("chat_id", values: chatIDs)
            .order("created_at", ascending: false)
            .limit(chatIDs.count * 3)
            .execute()
            .value
        var lastByChat: [UUID: Message] = [:]
        for m in recent where lastByChat[m.chat_id] == nil {
            lastByChat[m.chat_id] = m
        }
        // 6. assemble ChatRow list, sorted by last activity
        let out: [ChatRow] = chatRows.map { c in
            let mids = memberships.filter { $0.chat_id == c.id }.map(\.user_id)
            let ms = mids.compactMap { byID[$0] }
            return ChatRow(chat: c, members: ms,
                           lastMessage: lastByChat[c.id], unread: 0)
        }
        chats = out.sorted { (a, b) in
            let ad = a.lastMessage?.created_at ?? a.chat.created_at
            let bd = b.lastMessage?.created_at ?? b.chat.created_at
            return ad > bd
        }
    }

}
