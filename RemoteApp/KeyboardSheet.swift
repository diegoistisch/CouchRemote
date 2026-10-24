import RemoteKit
import SwiftUI

/// Tastatur fürs Fernsehen:
/// - „In App suchen“: Suchbegriff eingeben → die Suchseite der App öffnet sich am Fernseher.
/// - „Eintippen“: Text erscheint live dort, wo am Mac gerade der Cursor steht (z. B. im Suchfeld einer Seite).
struct KeyboardSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case search = "In App suchen"
        case type = "Eintippen"
        var id: String { rawValue }
    }

    let request: RemoteClient.KeyboardRequest

    @EnvironmentObject private var client: RemoteClient
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .search
    @State private var selectedAppID: UUID?
    @State private var query = ""
    @State private var typed = ""
    @FocusState private var isFocused: Bool

    private var searchableApps: [HomeApp] {
        client.apps.filter(KnownServices.supportsSearch)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if !searchableApps.isEmpty {
                    Picker("Modus", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                switch mode {
                case .search: searchMode
                case .type: typeMode
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Tastatur")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .onAppear(perform: setUp)
            .onChange(of: mode) { _, _ in isFocused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func setUp() {
        let searchable = searchableApps
        if let appID = request.appID, searchable.contains(where: { $0.id == appID }) {
            selectedAppID = appID
        } else {
            selectedAppID = searchable.first?.id
        }
        mode = (request.preferSearch && !searchable.isEmpty) ? .search : .type
        isFocused = true
    }

    // MARK: - In App suchen

    private var searchMode: some View {
        VStack(spacing: 16) {
            if searchableApps.count <= 3 {
                Picker("App", selection: $selectedAppID) {
                    ForEach(searchableApps) { Text($0.name).tag(Optional($0.id)) }
                }
                .pickerStyle(.segmented)
            } else {
                Picker("App", selection: $selectedAppID) {
                    ForEach(searchableApps) { Text($0.name).tag(Optional($0.id)) }
                }
                .pickerStyle(.menu)
            }

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Suchbegriff", text: $query)
                    .focused($isFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onSubmit(submitSearch)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary))

            Button(action: submitSearch) {
                Label("Am Fernseher suchen", systemImage: "play.tv")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || selectedAppID == nil)
        }
    }

    private func submitSearch() {
        guard let appID = selectedAppID else { return }
        Haptics.tap()
        client.search(appID: appID, query: query)
        dismiss()
    }

    // MARK: - Eintippen

    private var typeMode: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Text eingeben", text: $typed, axis: .vertical)
                .focused($isFocused)
                .submitLabel(.return)
                .lineLimit(1...4)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary))
                .onChange(of: typed) { old, new in
                    if skipNextSync {
                        skipNextSync = false // Änderung kam von uns selbst, nicht vom Tippen
                        return
                    }
                    // Zeilenumbruch = Return am Mac (Suche abschicken), Feld danach leeren.
                    if new.hasSuffix("\n") {
                        client.sendTextChange(from: old, to: String(new.dropLast()))
                        pressReturn()
                        return
                    }
                    client.sendTextChange(from: old, to: new)
                }

            HStack(spacing: 12) {
                RemoteButton(systemImage: "delete.left", label: "Löschen", repeats: true) {
                    // Löscht am Mac, auch Text, der schon vorher dort stand.
                    if typed.isEmpty {
                        client.send(.key(.deleteBackward))
                    } else {
                        typed.removeLast() // onChange schickt das Löschen
                    }
                }
                RemoteButton(systemImage: "return", label: "Return") {
                    pressReturn()
                }
                RemoteButton(systemImage: "xmark.circle", label: "Feld leeren (nur iPhone)") {
                    clearFieldWithoutSending()
                }
            }

            Text("Der Text erscheint live dort, wo am Mac der Cursor ist. Klicke vorher mit dem Trackpad ins Suchfeld der Seite.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @State private var skipNextSync = false

    /// Return am Mac (z. B. Suche abschicken). Das Feld am iPhone wird geleert, der Text am Mac bleibt.
    private func pressReturn() {
        client.send(.key(.select))
        clearFieldWithoutSending()
    }

    /// Leert das Feld am iPhone, ohne am Mac etwas zu löschen (neu anfangen).
    private func clearFieldWithoutSending() {
        guard !typed.isEmpty else { return }
        skipNextSync = true
        typed = ""
    }
}
