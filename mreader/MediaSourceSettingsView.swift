import SwiftUI

struct MediaSourceSettingsView: View {
    @ObservedObject var library: ComicLibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var sources: [MediaSource] = []
    @State private var sourceType = MediaSourceType.komga
    @State private var name = "Komga"
    @State private var baseURL = ""
    @State private var lanURL = ""
    @State private var username = ""
    @State private var apiKey = ""
    @State private var isTesting = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var hiddenComics: [HiddenKomgaComic] = []
    @State private var editingSource: MediaSource?
    @State private var editName = ""
    @State private var editBaseURL = ""
    @State private var editLanURL = ""
    @State private var editUsername = ""
    @State private var editApiKey = ""
    @State private var isEditing = false
    @State private var editStatusMessage: String?
    @State private var editStatusIsError = false
    @State private var sourcePendingRemoval: MediaSource?

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("mediaSources.added".localized)) {
                    if sources.filter({ $0.type == .komga || $0.type == .opds }).isEmpty {
                        Text("mediaSources.noServers".localized)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sources.filter { $0.type == .komga || $0.type == .opds }) { source in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(source.name)
                                                .font(.headline)
                                            Text(source.type == .opds ? "OPDS" : "Komga")
                                                .font(.caption2.weight(.bold))
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(source.baseURL)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                        if let lan = source.lanURL, !lan.isEmpty {
                                            Text("mediaSources.lanPrefix".localized + lan)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .textSelection(.enabled)
                                        }
                                    }
                                    Spacer()
                                    Toggle("", isOn: enabledBinding(for: source))
                                        .labelsHidden()
                                }
                                HStack {
                                    Button {
                                        refresh(source)
                                    } label: {
                                        Label("mediaSources.refresh".localized, systemImage: "arrow.clockwise")
                                    }
                                    .buttonStyle(.bordered)

                                    Button {
                                        startEditing(source)
                                    } label: {
                                        Label("mediaSources.edit".localized, systemImage: "pencil")
                                    }
                                    .buttonStyle(.bordered)

                                    Button(role: .destructive) {
                                        sourcePendingRemoval = source
                                    } label: {
                                        Label("mediaSources.remove".localized, systemImage: "trash")
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section(
                    header: Text("mediaSources.add".localized),
                    footer: Text(sourceType == .komga
                        ? "mediaSources.komgaDescription".localized
                        : "mediaSources.opdsDescription".localized)
                ) {
                    Picker("mediaSources.type".localized, selection: $sourceType) {
                        Text("Komga").tag(MediaSourceType.komga)
                        Text("OPDS").tag(MediaSourceType.opds)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: sourceType) { _, newValue in
                        name = newValue == .opds ? "OPDS" : "Komga"
                        username = ""
                        apiKey = ""
                        lanURL = ""
                        statusMessage = nil
                    }
                    TextField("mediaSources.name".localized, text: $name)
                        .textInputAutocapitalization(.never)
                    TextField(
                        sourceType == .komga
                            ? "mediaSources.serverUrl".localized
                            : "mediaSources.serverUrl".localized,
                        text: $baseURL
                    )
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(
                        "mediaSources.lanUrl".localized,
                        text: $lanURL
                    )
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if sourceType == .opds {
                        TextField("mediaSources.username".localized, text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    SecureField(sourceType == .komga ? "mediaSources.apiKey".localized : "mediaSources.password".localized, text: $apiKey)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button {
                        testAndSave()
                    } label: {
                        if isTesting {
                            ProgressView()
                        } else {
                            Label("mediaSources.testAndSave".localized, systemImage: "checkmark.shield")
                        }
                    }
                    .disabled(
                        isTesting
                            || baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || (sourceType == .komga && apiKey.isEmpty)
                    )

                    if let statusMessage {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(statusIsError ? .red : .secondary)
                    }
                }

                Section(header: Text("mediaSources.hiddenComics".localized)) {
                    if hiddenComics.isEmpty {
                        Text("mediaSources.noHidden".localized)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(hiddenComics) { item in
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title)
                                        .font(.body)
                                    Text(item.sourceName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("mediaSources.unhide".localized) {
                                    unhide(item)
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("mediaSources.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("nav.done".localized) {
                    dismiss()
                }
            }
            .onAppear {
                reloadSources()
                reloadHiddenComics()
            }
            .alert(item: $sourcePendingRemoval) { source in
                Alert(
                    title: Text("mediaSources.removeConfirmTitle".localized),
                    message: Text("mediaSources.removeConfirmMessage".localizedFormat(source.name)),
                    primaryButton: .destructive(Text("mediaSources.remove".localized)) {
                        remove(source)
                    },
                    secondaryButton: .cancel()
                )
            }
            .sheet(item: $editingSource) { source in
                NavigationStack {
                    Form {
                        Section(header: Text("mediaSources.edit".localized)) {
                            TextField("mediaSources.name".localized, text: $editName)
                                .textInputAutocapitalization(.never)
                            TextField(
                                source.type == .komga
                                    ? "mediaSources.serverUrl".localized
                                    : "mediaSources.serverUrl".localized,
                                text: $editBaseURL
                            )
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            TextField(
                                "mediaSources.lanUrl".localized,
                                text: $editLanURL
                            )
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            if source.type == .opds {
                                TextField("mediaSources.username".localized, text: $editUsername)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                            SecureField(source.type == .komga ? "mediaSources.apiKey".localized : "mediaSources.password".localized, text: $editApiKey)
                                .textContentType(.password)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()

                            Button {
                                testAndSaveEdit(source: source)
                            } label: {
                                if isEditing {
                                    ProgressView()
                                } else {
                                    Label("mediaSources.testAndSave".localized, systemImage: "checkmark.shield")
                                }
                            }
                            .disabled(
                                isEditing
                                    || editBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            )

                            if let editStatusMessage {
                                Text(editStatusMessage)
                                    .font(.footnote)
                                    .foregroundStyle(editStatusIsError ? .red : .secondary)
                            }
                        }
                    }
                    .navigationTitle("mediaSources.edit".localized)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("nav.cancel".localized) {
                                editingSource = nil
                            }
                        }
                    }
                }
            }
        }
    }

    private func enabledBinding(for source: MediaSource) -> Binding<Bool> {
        Binding {
            sources.first(where: { $0.id == source.id })?.isEnabled ?? source.isEnabled
        } set: { enabled in
            guard let index = sources.firstIndex(where: { $0.id == source.id }) else { return }
            sources[index].isEnabled = enabled
            let sourceID = sources[index].id
            Task {
                await library.setMediaSourceEnabled(id: sourceID, isEnabled: enabled)
                reloadSources()
            }
        }
    }

    private func testAndSave() {
        isTesting = true
        statusMessage = nil
        statusIsError = false
        let sourceName = name
        let server = baseURL
        let lan = lanURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = username
        let key = apiKey
        let selectedSourceType = sourceType
        Task {
            do {
                let source: MediaSource
                let resultDescription: String
                switch selectedSourceType {
                case .komga:
                    let libraries = try await KomgaProvider.testConnection(baseURL: server, apiKey: key)
                    source = try await KomgaProvider.addKomgaSource(name: sourceName, baseURL: server, apiKey: key, lanURL: lan.isEmpty ? nil : lan)
                    resultDescription = "mediaSources.discoveredKomga".localizedFormat(libraries.count)
                case .opds:
                    let publicationCount = try await OPDSProvider.testConnection(
                        baseURL: server,
                        username: account,
                        credential: key
                    )
                    source = try await OPDSProvider.addSource(
                        name: sourceName,
                        baseURL: server,
                        username: account,
                        credential: key,
                        lanURL: lan.isEmpty ? nil : lan
                    )
                    resultDescription = "mediaSources.discoveredOpds".localizedFormat(publicationCount)
                case .local:
                    throw MediaSourceError.invalidResponse
                }
                reloadSources()
                reloadHiddenComics()
                apiKey = ""
                lanURL = ""
                statusIsError = false
                statusMessage = "mediaSources.connectSuccess".localizedFormat(resultDescription, source.name)
                HapticManager.shared.play(.success)
                let syncedCount: Int
                if selectedSourceType == .opds {
                    syncedCount = await library.syncOPDSSources()
                } else {
                    syncedCount = await library.syncKomgaSources()
                }
                statusMessage = "mediaSources.syncComplete".localizedFormat(resultDescription, syncedCount)
            } catch {
                statusIsError = true
                statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                HapticManager.shared.play(.error)
            }
            isTesting = false
        }
    }

    private func refresh(_ source: MediaSource) {
        HapticManager.shared.play(.medium)
        Task {
            let syncedCount: Int
            if source.type == .opds {
                syncedCount = await library.syncOPDSSource(id: source.id)
            } else {
                syncedCount = await library.syncKomgaSource(id: source.id)
            }
            if let error = library.mediaSyncErrors[source.type] {
                statusIsError = true
                statusMessage = error
                HapticManager.shared.play(.error)
            } else {
                statusIsError = false
                statusMessage = "mediaSources.refreshComplete".localizedFormat(syncedCount, source.type == .opds ? "OPDS" : "Komga")
                HapticManager.shared.play(.success)
            }
            reloadSources()
            reloadHiddenComics()
        }
    }

    private func remove(_ source: MediaSource) {
        Task {
            do {
                try await KomgaProvider.removeSource(id: source.id)
                if source.type == .opds {
                    library.removeOPDSSource(id: source.id)
                } else {
                    library.removeKomgaSource(id: source.id)
                }
                reloadSources()
                reloadHiddenComics()
                HapticManager.shared.play(.heavy)
            } catch {
                statusIsError = true
                statusMessage = error.localizedDescription
            }
        }
    }

    private func reloadSources() {
        Task {
            sources = await RemoteSourceRuntimeService.shelfState().sources
        }
    }

    private func reloadHiddenComics() {
        Task {
            hiddenComics = await RemoteSourceRuntimeService.shelfState().hiddenComics
        }
    }

    private func unhide(_ item: HiddenKomgaComic) {
        HapticManager.shared.play(.medium)
        Task {
            await KomgaProvider.unhideComic(key: item.key)
            reloadHiddenComics()
            library.refreshVisibility()
        }
    }

    private func startEditing(_ source: MediaSource) {
        editName = source.name
        editBaseURL = source.baseURL
        editLanURL = source.lanURL ?? ""
        editUsername = source.username ?? ""
        editApiKey = ""
        editStatusMessage = nil
        editStatusIsError = false
        editingSource = source
    }

    private func testAndSaveEdit(source: MediaSource) {
        isEditing = true
        editStatusMessage = nil
        editStatusIsError = false
        let editedName = editName
        let editedBaseURL = editBaseURL
        let editedLanURL = editLanURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let editedUsername = editUsername
        let editedKey = editApiKey
        Task {
            do {
                var updatedSource = source
                updatedSource.name = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
                updatedSource.baseURL = editedBaseURL
                updatedSource.lanURL = editedLanURL.isEmpty ? nil : editedLanURL
                if source.type == .opds {
                    updatedSource.username = editedUsername.isEmpty ? nil : editedUsername
                }
                if !editedKey.isEmpty {
                    try KomgaProvider.saveAPIKey(editedKey, for: source.id)
                }
                switch source.type {
                case .komga:
                    let key = editedKey.isEmpty ? (KomgaProvider.apiKey(for: source.id) ?? "") : editedKey
                    let client = try KomgaAPIClient(baseURLString: editedBaseURL, apiKey: key)
                    _ = try await client.testConnection()
                case .opds:
                    let credential = editedKey.isEmpty ? (KomgaProvider.apiKey(for: source.id) ?? "") : editedKey
                    _ = try await OPDSProvider.testConnection(
                        baseURL: editedBaseURL,
                        username: editedUsername.isEmpty ? source.username : editedUsername,
                        credential: credential
                    )
                case .local:
                    break
                }
                try await KomgaProvider.updateSource(updatedSource)
                reloadSources()
                reloadHiddenComics()
                if source.type == .opds {
                    _ = await library.syncOPDSSources()
                } else if source.type == .komga {
                    _ = await library.syncKomgaSources()
                }
                editStatusIsError = false
                editStatusMessage = "mediaSources.saveSuccess".localized
                HapticManager.shared.play(.success)
                editingSource = nil
            } catch {
                editStatusIsError = true
                editStatusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                HapticManager.shared.play(.error)
            }
            isEditing = false
        }
    }
}
