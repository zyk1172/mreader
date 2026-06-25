import SwiftUI

struct MediaSourceSettingsView: View {
    @ObservedObject var library: ComicLibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var sources: [MediaSource] = []
    @State private var sourceType = MediaSourceType.komga
    @State private var name = "Komga"
    @State private var baseURL = ""
    @State private var username = ""
    @State private var apiKey = ""
    @State private var isTesting = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var hiddenComics: [HiddenKomgaComic] = []

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("已添加媒体库")) {
                    if sources.filter({ $0.type == .komga || $0.type == .opds }).isEmpty {
                        Text("还没有远程漫画服务器")
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
                                    }
                                    Spacer()
                                    Toggle("", isOn: enabledBinding(for: source))
                                        .labelsHidden()
                                }
                                HStack {
                                    Button {
                                        refresh(source)
                                    } label: {
                                        Label("刷新", systemImage: "arrow.clockwise")
                                    }
                                    .buttonStyle(.bordered)

                                    Button(role: .destructive) {
                                        remove(source)
                                    } label: {
                                        Label("移除", systemImage: "trash")
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section(
                    header: Text("添加远程服务器"),
                    footer: Text(sourceType == .komga
                        ? "Komga API Key 仅保存到 Keychain。"
                        : "OPDS 支持 Atom/JSON 目录。填写用户名时使用 Basic 认证；用户名留空时凭据作为 Bearer Token。")
                ) {
                    Picker("类型", selection: $sourceType) {
                        Text("Komga").tag(MediaSourceType.komga)
                        Text("OPDS").tag(MediaSourceType.opds)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: sourceType) { _, newValue in
                        name = newValue == .opds ? "OPDS" : "Komga"
                        username = ""
                        apiKey = ""
                        statusMessage = nil
                    }
                    TextField("显示名称", text: $name)
                        .textInputAutocapitalization(.never)
                    TextField(
                        sourceType == .komga
                            ? "服务器地址，例如 http://192.168.2.240:25600"
                            : "OPDS 地址，例如 https://example.com/opds",
                        text: $baseURL
                    )
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if sourceType == .opds {
                        TextField("用户名（Bearer Token 模式可留空）", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    SecureField(sourceType == .komga ? "API Key" : "密码或 Token", text: $apiKey)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button {
                        testAndSave()
                    } label: {
                        if isTesting {
                            ProgressView()
                        } else {
                            Label("测试连接并保存", systemImage: "checkmark.shield")
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

                Section(header: Text("已隐藏的 Komga 漫画")) {
                    if hiddenComics.isEmpty {
                        Text("暂无隐藏的 Komga 漫画")
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
                                Button("取消隐藏") {
                                    unhide(item)
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("远程漫画媒体库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("完成") {
                    dismiss()
                }
            }
            .onAppear {
                reloadSources()
                reloadHiddenComics()
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
                    source = try await KomgaProvider.addKomgaSource(name: sourceName, baseURL: server, apiKey: key)
                    resultDescription = "发现 \(libraries.count) 个 Komga 书库"
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
                        credential: key
                    )
                    resultDescription = "发现 \(publicationCount) 本 OPDS 出版物"
                case .local:
                    throw MediaSourceError.invalidResponse
                }
                reloadSources()
                reloadHiddenComics()
                apiKey = ""
                statusIsError = false
                statusMessage = "连接成功：\(resultDescription)，已保存 \(source.name)"
                HapticManager.shared.play(.success)
                let syncedCount: Int
                if selectedSourceType == .opds {
                    syncedCount = await library.syncOPDSSources()
                } else {
                    syncedCount = await library.syncKomgaSources()
                }
                statusMessage = "\(resultDescription)，已同步 \(syncedCount) 本漫画"
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
                syncedCount = await library.syncOPDSSources()
            } else {
                syncedCount = await library.syncKomgaSources()
            }
            statusIsError = false
            statusMessage = "刷新完成：已同步 \(syncedCount) 本 \(source.type == .opds ? "OPDS" : "Komga") 漫画"
            reloadSources()
            reloadHiddenComics()
        }
    }

    private func remove(_ source: MediaSource) {
        do {
            try KomgaProvider.removeSource(id: source.id)
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

    private func reloadSources() {
        sources = KomgaProvider.loadSources()
    }

    private func reloadHiddenComics() {
        hiddenComics = KomgaProvider.hiddenKomgaComics()
    }

    private func unhide(_ item: HiddenKomgaComic) {
        HapticManager.shared.play(.medium)
        KomgaProvider.unhideComic(key: item.key)
        reloadHiddenComics()
        library.refreshVisibility()
    }
}
