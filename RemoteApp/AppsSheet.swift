import PhotosUI
import RemoteKit
import SwiftUI
import UIKit

/// Apps der Startseite: antippen öffnet am Fernseher, außerdem hinzufügen, bearbeiten, sortieren, löschen.
struct AppsSheet: View {
    @EnvironmentObject private var client: RemoteClient
    @Environment(\.dismiss) private var dismiss

    @State private var editing: HomeApp?
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            Group {
                if client.apps.isEmpty {
                    ContentUnavailableView {
                        Label("Keine Apps", systemImage: "square.grid.2x2")
                    } description: {
                        Text("Füge Seiten wie Crunchyroll oder Netflix hinzu. Sie erscheinen als Kacheln auf der Startseite am Fernseher.")
                    } actions: {
                        Button("App hinzufügen") { isAdding = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    list
                }
            }
            .navigationTitle("Apps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if !client.apps.isEmpty { EditButton() }
                    Button {
                        isAdding = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("App hinzufügen")
                    .disabled(client.apps.count >= HomeApp.maxCount)
                }
            }
            .sheet(isPresented: $isAdding) {
                AppEditor(app: nil) { newApp in
                    client.setApps(client.apps + [newApp])
                }
            }
            .sheet(item: $editing) { app in
                AppEditor(app: app) { updated in
                    client.setApps(client.apps.map { $0.id == updated.id ? updated : $0 })
                }
            }
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(client.apps) { app in
                    Button {
                        Haptics.tap()
                        client.openApp(app)
                        dismiss()
                    } label: {
                        HStack(spacing: 14) {
                            AppIcon(app: app, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name)
                                    .foregroundStyle(.primary)
                                Text(app.url.host ?? app.url.absoluteString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "play.tv")
                                .foregroundStyle(.tint)
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button("Bearbeiten") { editing = app }
                            .tint(.blue)
                    }
                }
                .onDelete { offsets in
                    var apps = client.apps
                    apps.remove(atOffsets: offsets)
                    client.setApps(apps)
                }
                .onMove { source, destination in
                    var apps = client.apps
                    apps.move(fromOffsets: source, toOffset: destination)
                    client.setApps(apps)
                }
            } footer: {
                Text("Antippen öffnet die App am Fernseher. Nach rechts wischen zum Bearbeiten, nach links zum Löschen. Reihenfolge über „Bearbeiten“ ändern.")
            }
        }
    }
}

/// Formular zum Anlegen oder Ändern einer App.
struct AppEditor: View {
    let app: HomeApp?
    let onSave: (HomeApp) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var colorHex = HomeApp.palette[0]
    @State private var logo: Data?
    @State private var photoItem: PhotosPickerItem?
    @State private var logoError: String?

    init(app: HomeApp?, onSave: @escaping (HomeApp) -> Void) {
        self.app = app
        self.onSave = onSave
        _name = State(initialValue: app?.name ?? "")
        _address = State(initialValue: app?.url.absoluteString ?? "")
        _colorHex = State(initialValue: app?.colorHex ?? HomeApp.palette.randomElement() ?? HomeApp.palette[0])
        _logo = State(initialValue: app?.logo)
    }

    /// „crunchyroll.com“ → „https://crunchyroll.com“
    private var normalizedURL: URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        return URL(string: withScheme)
    }

    private var draft: HomeApp? {
        guard let url = normalizedURL else { return nil }
        let candidate = HomeApp(id: app?.id ?? UUID(),
                                name: name.trimmingCharacters(in: .whitespaces),
                                url: url, colorHex: colorHex, logo: logo)
        return candidate.isValid ? candidate : nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        AppIcon(app: draft ?? HomeApp(name: name.isEmpty ? "?" : name,
                                                      url: URL(string: "https://example.invalid")!,
                                                      colorHex: colorHex, logo: logo),
                                size: 88)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                Section("Name") {
                    TextField("z. B. Crunchyroll", text: $name)
                        .textInputAutocapitalization(.words)
                }

                Section {
                    TextField("crunchyroll.com", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Adresse")
                } footer: {
                    Text("Wird am Mac im Standardbrowser geöffnet. Nur http(s)-Adressen.")
                }

                Section {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label(logo == nil ? "Logo aus Fotos wählen" : "Anderes Logo wählen", systemImage: "photo")
                    }
                    if logo != nil {
                        Button("Eigenes Logo entfernen", role: .destructive) { logo = nil }
                    }
                    if let logoError {
                        Text(logoError).foregroundStyle(.red)
                    }
                } header: {
                    Text("Logo")
                } footer: {
                    Text("Ohne eigenes Logo wird das offizielle Icon der Seite geladen. Breite Schriftzüge (PNG mit transparentem Hintergrund) füllen die Kachel wie bei Apple TV.")
                }
                .onChange(of: photoItem) { _, item in
                    guard let item else { return }
                    Task {
                        let data = try? await item.loadTransferable(type: Data.self)
                        if let prepared = data.flatMap(LogoProcessing.prepare) {
                            logo = prepared
                            logoError = nil
                        } else {
                            logoError = "Das Bild konnte nicht geladen werden."
                        }
                        photoItem = nil
                    }
                }

                Section("Farbe") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                        ForEach(HomeApp.palette, id: \.self) { hex in
                            let rgb = HexColor.rgb(hex)
                            Circle()
                                .fill(Color(red: rgb.red, green: rgb.green, blue: rgb.blue))
                                .frame(width: 36, height: 36)
                                .overlay(Circle().strokeBorder(.primary, lineWidth: colorHex == hex ? 3 : 0))
                                .onTapGesture { colorHex = hex }
                                .accessibilityLabel("Farbe \(hex)")
                                .accessibilityAddTraits(colorHex == hex ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle(app == nil ? "App hinzufügen" : "App bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        if let draft {
                            onSave(draft)
                            dismiss()
                        }
                    }
                    .disabled(draft == nil)
                }
            }
        }
    }
}

/// Kleines Kachel-Icon wie auf der Startseite.
struct AppIcon: View {
    let app: HomeApp
    let size: CGFloat

    var body: some View {
        let rgb = HexColor.rgb(app.colorHex)
        let color = Color(red: rgb.red, green: rgb.green, blue: rgb.blue)

        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(LinearGradient(colors: [color, color.opacity(0.7)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay {
                if let data = app.logo, let image = Image(logoData: data) {
                    image
                        .resizable()
                        .scaledToFit()
                        .padding(size * 0.12)
                } else {
                    WebsiteIcon(page: app.url, cornerRadius: size * 0.16) {
                        Text(String(app.name.prefix(1)).uppercased())
                            .font(.system(size: size * 0.5, weight: .heavy, design: .rounded))
                            .foregroundStyle(HexColor.isLight(app.colorHex) ? .black : .white)
                    }
                    .padding(size * 0.12)
                }
            }
            .accessibilityHidden(true)
    }
}
