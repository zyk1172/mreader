import SwiftUI

struct MediaSourceSettingsView: View {
    @ObservedObject var library: ComicLibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var sources: [MediaSource] = []
    @State private var name = "Komga"
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var isTesting = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("已添加媒体库")) {
                    if sources.filter({ $0.type == .komga }).isEmpty {
                        Text("还没有 Komga 服务器")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sources.filter { $0.type == .komga }) { source in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(source.name)
                                            .font(.headline)
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

                Section(header: Text("添加 Komga 服务器"), footer: Text("API Key 仅保存到 Keychain，不写入 UserDefaults 或 JSON。漫画文件保留在 Komga 服务器上。")) {
                    TextField("显示名称", text: $name)
                        .textInputAutocapitalization(.never)
                    TextField("服务器地址，例如 http://192.168.2.240:25600", text: $baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API Key", text: $apiKey)
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
                    .disabled(isTesting || baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || apiKey.isEmpty)

                    if let statusMessage {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(statusIsError ? .red : .secondary)
                    }
                }
            }
            .navigationTitle("漫画媒体库 / Komga")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("完成") {
                    dismiss()
                }
            }
            .onAppear {
                reloadSources()
            }
        }
    }

    private func enabledBinding(for source: MediaSource) -> Binding<Bool> {
        Binding {
            sources.first(where: { $0.id == source.id })?.isEnabled ?? source.isEnabled
        } set: { enabled in
            guard let index = sources.firstIndex(where: { $0.id == source.id }) else { return }
            sources[index].isEnabled = enabled
            try? KomgaProvider.updateSource(sources[index])
            Task { await library.syncKomgaSources() }
        }
    }

    private func testAndSave() {
        isTesting = true
        statusMessage = nil
        statusIsError = false
        let sourceName = name
        let server = baseURL
        let key = apiKey
        Task {
            do {
                let libraries = try await KomgaProvider.testConnection(baseURL: server, apiKey: key)
                let source = try await KomgaProvider.addKomgaSource(name: sourceName, baseURL: server, apiKey: key)
                reloadSources()
                apiKey = ""
                statusIsError = false
                statusMessage = "连接成功：发现 \(libraries.count) 个 Komga 书库，已保存 \(source.name)"
                HapticManager.shared.play(.success)
                let syncedCount = await library.syncKomgaSources()
                statusMessage = "连接成功：发现 \(libraries.count) 个书库，已同步 \(syncedCount) 本漫画"
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
            let syncedCount = await library.syncKomgaSources()
            statusIsError = false
            statusMessage = "刷新完成：已同步 \(syncedCount) 本 Komga 漫画"
            reloadSources()
        }
    }

    private func remove(_ source: MediaSource) {
        do {
            try KomgaProvider.removeSource(id: source.id)
            library.removeKomgaSource(id: source.id)
            reloadSources()
            HapticManager.shared.play(.heavy)
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }

    private func reloadSources() {
        sources = KomgaProvider.loadSources()
    }
}
