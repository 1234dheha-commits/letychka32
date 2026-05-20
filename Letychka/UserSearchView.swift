import SwiftUI

/// Type a username, see matching people, tap one to start a direct chat.
/// The search is server-side and only against the `profiles` table.
struct UserSearchView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    var onPick: (Global.Profile) -> Void

    @State private var query: String = ""
    @State private var results: [Global.Profile] = []
    @State private var searching = false

    var body: some View {
        ZStack {
            Theme.bg(scheme).ignoresSafeArea()
            VStack(spacing: 0) {
                searchBar
                if searching {
                    ProgressView().padding(.top, 32)
                } else if results.isEmpty {
                    hintBlock
                } else {
                    list
                }
                Spacer()
            }
        }
        .navigationTitle(L("Find people"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(L("Cancel")) { dismiss() }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.muted(scheme))
            TextField(L("Username (e.g. letychkauser…)"),
                      text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: query) { _, v in
                    Task { await run(v) }
                }
            if !query.isEmpty {
                Button { query = ""; results = [] } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.muted(scheme))
                }
            }
        }
        .padding(10)
        .background(Theme.surface(scheme), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    @ViewBuilder
    private var hintBlock: some View {
        VStack(spacing: 8) {
            Spacer().frame(height: 28)
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Theme.muted(scheme))
            Text(query.isEmpty
                 ? L("Type at least one letter to search.")
                 : L("No one found."))
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted(scheme))
        }
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(results) { p in
                    Button { onPick(p) } label: { row(p) }
                        .buttonStyle(.plain)
                    Divider().overlay(Theme.line(scheme))
                        .padding(.leading, 64)
                }
            }
            .padding(.top, 8)
        }
    }

    private func row(_ p: Global.Profile) -> some View {
        HStack(spacing: 12) {
            Circle().fill(Theme.accent.opacity(0.18))
                .frame(width: 40, height: 40)
                .overlay(
                    Text(String(p.username.prefix(1)).uppercased())
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.accent)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(p.display_name?.isEmpty == false
                     ? (p.display_name ?? "")
                     : p.username)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text(scheme))
                Text("@\(p.username)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted(scheme))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.muted(scheme))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    /// Debounce: each keystroke kicks the task, the first one to finish for
    /// the current query wins. Simple guard, no fancy throttling needed.
    private func run(_ q: String) async {
        let snapshot = q
        searching = true
        defer { searching = false }
        // Tiny delay so we don't hit the server on every keystroke.
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard snapshot == query else { return }
        results = await Global.shared.searchUsers(prefix: snapshot)
    }
}
