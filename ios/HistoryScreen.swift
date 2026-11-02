import SwiftUI

struct HistoryScreen: View {
    @Environment(ProfileStore.self) private var profile

    var body: some View {
        NavigationStack {
            HistoryList()
        }
        .task(id: profile.scope) {
            await profile.sync(force: true)
        }
    }
}

private struct HistoryList: View {
    @Environment(ProfileStore.self) private var profile
    @State private var editMode: EditMode = .inactive
    @State private var selectedEntryIDs = Set<WatchHistoryEntry.ID>()
    @State private var showBulkDeleteConfirmation = false

    private var isEditing: Bool { editMode.isEditing }
    private var entries: [WatchHistoryEntry] { profile.entries }

    var body: some View {
        List(selection: $selectedEntryIDs) {
            if entries.isEmpty {
                ContentUnavailableView("Nada para continuar", systemImage: "play.circle", description: Text("Las series que reproduzcas con esta identidad aparecerán aquí con el segundo en que las dejaste."))
            } else {
                Section("Reproducciones recientes") {
                    ForEach(entries) { entry in
                        NavigationLink {
                            EpisodesScreen(anime: entry.anime)
                        } label: {
                            HistoryRow(entry: entry, language: profile.preferences.titleLanguage)
                        }
                        .tag(entry.id)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                delete([entry])
                            } label: {
                                Label("Borrar", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .environment(\.editMode, $editMode)
        .listStyle(.insetGrouped)
        .navigationTitle("Continuar viendo")
        .modifier(AdaptableTabRootTitleStyle())
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isEditing ? "Listo" : "Editar") {
                    if isEditing {
                        selectedEntryIDs.removeAll()
                        editMode = .inactive
                    } else {
                        editMode = .active
                    }
                }
                .disabled(entries.isEmpty && !isEditing)
                .accessibilityIdentifier("history.edit")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isEditing {
                GlassEffectContainer(spacing: 12) {
                    HStack {
                        selectAllButton
                        Spacer(minLength: 12)
                        bulkDeleteButton
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .confirmationDialog(
            "¿Borrar \(selectedEntryIDs.count) series?",
            isPresented: $showBulkDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Borrar \(selectedEntryIDs.count) series", role: .destructive) {
                delete(entries.filter { selectedEntryIDs.contains($0.id) })
            }
        }
        .refreshable {
            await profile.sync(force: true)
        }
        .onChange(of: entries) { _, updatedEntries in
            selectedEntryIDs.formIntersection(Set(updatedEntries.map(\.id)))
        }
        .onChange(of: isEditing) { _, editing in
            if !editing {
                selectedEntryIDs.removeAll()
            }
        }
    }

    private var allEntriesSelected: Bool {
        !entries.isEmpty && selectedEntryIDs.count == entries.count
    }

    private var selectAllButton: some View {
        Button {
            if allEntriesSelected {
                selectedEntryIDs.removeAll()
            } else {
                selectedEntryIDs = Set(entries.map(\.id))
            }
        } label: {
            Label(allEntriesSelected ? "Deseleccionar todo" : "Seleccionar todo", systemImage: allEntriesSelected ? "xmark.circle" : "checkmark.circle")
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier("history.selectAll")
        .disabled(entries.isEmpty)
    }

    private var bulkDeleteButton: some View {
        Button(role: .destructive) {
            showBulkDeleteConfirmation = true
        } label: {
            Label("Borrar (\(selectedEntryIDs.count))", systemImage: "trash")
        }
        .buttonStyle(.glassProminent)
        .tint(.red)
        .accessibilityIdentifier("history.deleteSelected")
        .disabled(selectedEntryIDs.isEmpty)
    }

    private func delete(_ entriesToDelete: [WatchHistoryEntry]) {
        guard !entriesToDelete.isEmpty else { return }
        profile.remove(entriesToDelete)
        selectedEntryIDs.subtract(Set(entriesToDelete.map(\.id)))
        Task {
            await profile.sync(force: true)
        }
    }
}

private struct HistoryRow: View {
    let entry: WatchHistoryEntry
    let language: TitleLanguage

    private var serverLine: String {
        [entry.serverName.isEmpty ? nil : entry.serverName, entry.kind?.displayName].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PosterImage(imageURL: entry.imageUrl, cornerRadius: 8)
                .frame(width: 56)
            VStack(alignment: .leading, spacing: 4) {
                SeriesTitle(title: entry.seriesTitle, titleJp: entry.titleJp, language: language)
                Text("\(entry.episodeLabel) · \(formatTime(entry.positionSeconds))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !serverLine.isEmpty {
                    Text(serverLine)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
