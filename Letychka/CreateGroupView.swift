import SwiftUI

/// Pick a name and a couple of usernames, hit Create, get a fresh group
/// chat. Members can be added later from group settings.
struct CreateGroupView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    /// Called with the new chat id once the group is created.
    var onCreated: (UUID) -> Void

    @State private var name: String = ""
    @State private var query: String = ""
    @State private var results: [Global.Profile] = []
    @State private var selected: [Global.Profile] = []
    @State private var creating = false
    @State private var searching = false

    var body: some View {
        ZStack {
            Theme.bg(scheme).ignoresSafeArea()
            Form {
                Section(L("Group name")) {
                    TextField(L("e.g. Friday plans"), text: $name)
                }
                if !selected.isEmpty {
                    Section(L("Members")) {
                        ForEach(selected) { p in
                            HStack {
                                Text("@\(p.username)")
                                    .font(.system(size: 14))
                                Spacer()
                                Button {
                                    selected.removeAll { $0.id == p.id }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                }
                Section(L("Add by username")) {
                    TextField(L("Type to search"), text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: query) { _, v in
                            Task { await runSearch(v) }
                        }
                    if searching {
                        ProgressView()
                    }
                    ForEach(results) { p in
                        Button {
                            if !selected.contains(where: { $0.id == p.id }) {
                                selected.append(p)
                            }
                            query = ""
                            results = []
                        } label: {
                            HStack {
                                Text("@\(p.username)")
                                    .font(.system(size: 14))
                                Spacer()
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(L("New group"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(L("Cancel")) { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await create() }
                } label: {
                    if creating { ProgressView() }
                    else { Text(L("Create")).bold() }
                }
                .disabled(creating
                    || name.trimmingCharacters(in: .whitespaces).isEmpty
                    || selected.isEmpty)
            }
        }
    }

    private func runSearch(_ q: String) async {
        let snapshot = q
        searching = true
        defer { searching = false }
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard snapshot == query else { return }
        let found = await Global.shared.searchUsers(prefix: snapshot)
        let pickedIDs = Set(selected.map(\.id))
        results = found.filter { !pickedIDs.contains($0.id) }
    }

    private func create() async {
        creating = true
        defer { creating = false }
        if let id = await Global.shared.createGroup(name: name,
                                                    members: selected) {
            dismiss()
            onCreated(id)
        }
    }
}
