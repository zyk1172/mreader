import SwiftUI

struct AIProviderSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profiles: [AIProviderProfile] = []
    @State private var activeProfileID: UUID?
    @State private var editingProfile: AIProviderProfile?
    @State private var isAddingProfile = false
    @State private var pendingDelete: AIProviderProfile?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                if profiles.isEmpty {
                    ContentUnavailableView(
                        "aiProvider.empty".localized,
                        systemImage: "cpu",
                        description: Text("aiProvider.emptyDescription".localized)
                    )
                } else {
                    ForEach(profiles) { profile in
                        HStack(spacing: 12) {
                            Button {
                                editingProfile = profile
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: activeProfileID == profile.id
                                          ? "checkmark.circle.fill"
                                          : "circle")
                                        .foregroundStyle(activeProfileID == profile.id ? .green : .secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(profile.name)
                                            .foregroundStyle(.primary)
                                        Text(profile.selectedTextModel)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                        Text(profile.baseURL)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Menu {
                                ForEach(profile.models, id: \.self) { model in
                                    Button {
                                        select(model: model, for: profile)
                                    } label: {
                                        Label(
                                            model,
                                            systemImage: profile.selectedTextModel == model
                                                ? "checkmark"
                                                : "circle"
                                        )
                                    }
                                }
                            } label: {
                                Image(systemName: "switch.2")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 36, height: 36)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                        }
                        .contentShape(Rectangle())
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if activeProfileID != profile.id {
                                Button("aiProvider.makeActive".localized) {
                                    AIProviderStore.shared.setActiveProfile(id: profile.id)
                                    reload()
                                    HapticManager.shared.play(.success)
                                }
                                .tint(.green)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("comic.delete".localized, role: .destructive) {
                                pendingDelete = profile
                            }
                        }
                    }
                }
            } header: {
                Text("aiProvider.saved".localized)
            } footer: {
                Text("aiProvider.sharedModelDescription".localized)
            }

            Section {
                Button {
                    isAddingProfile = true
                } label: {
                    Label("aiProvider.add".localized, systemImage: "plus")
                }
            }
        }
        .navigationTitle("aiProvider.title".localized)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("nav.done".localized) { dismiss() }
            }
        }
        .onAppear(perform: reload)
        .sheet(item: $editingProfile) { profile in
            NavigationStack {
                AIProviderEditorView(profile: profile) {
                    reload()
                    editingProfile = nil
                }
            }
        }
        .sheet(isPresented: $isAddingProfile) {
            NavigationStack {
                AIProviderEditorView(profile: nil) {
                    reload()
                    isAddingProfile = false
                }
            }
        }
        .confirmationDialog(
            "aiProvider.deleteTitle".localized,
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("comic.delete".localized, role: .destructive) {
                guard let profile = pendingDelete else { return }
                do {
                    try AIProviderStore.shared.deleteProfile(id: profile.id)
                    reload()
                    HapticManager.shared.play(.heavy)
                } catch {
                    errorMessage = error.localizedDescription
                    HapticManager.shared.play(.error)
                }
                pendingDelete = nil
            }
            Button("nav.cancel".localized, role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text("aiProvider.deleteMessage".localized)
        }
        .alert(
            "common.error".localized,
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("nav.done".localized, role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func reload() {
        profiles = AIProviderStore.shared.profiles()
        activeProfileID = AIProviderStore.shared.activeProfileID()
    }

    private func select(model: String, for profile: AIProviderProfile) {
        do {
            // 快捷切换只改“文本翻译模型”，不要覆盖用户单独配置的视觉模型（审查 #8）
            try AIProviderStore.shared.setSelectedTextModel(model, for: profile.id, activate: true)
            reload()
            HapticManager.shared.play(.light)
        } catch {
            errorMessage = error.localizedDescription
            HapticManager.shared.play(.error)
        }
    }
}

private struct AIProviderEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let onSaved: () -> Void

    @State private var profileID: UUID
    @State private var createdAt: Date
    @State private var name: String
    @State private var baseURL: String
    @State private var apiKey: String
    @State private var modelsText: String
    @State private var selectedTextModel: String
    @State private var selectedVisionModel: String
    @State private var testingKind: ConnectionTestKind?
    @State private var testMessage: String?
    @State private var testFailed = false
    @State private var validationMessage: String?

    private enum ConnectionTestKind: String {
        case text
        case vision
    }

    init(profile: AIProviderProfile?, onSaved: @escaping () -> Void) {
        let id = profile?.id ?? UUID()
        self.onSaved = onSaved
        _profileID = State(initialValue: id)
        _createdAt = State(initialValue: profile?.createdAt ?? Date())
        _name = State(initialValue: profile?.name ?? "")
        _baseURL = State(initialValue: profile?.baseURL ?? "https://api.openai.com/v1")
        _apiKey = State(initialValue: profile.map { AIProviderStore.shared.apiKey(for: $0.id) } ?? "")
        _modelsText = State(initialValue: profile?.models.joined(separator: "\n") ?? "gpt-4o-mini")
        _selectedTextModel = State(initialValue: profile?.selectedTextModel ?? "gpt-4o-mini")
        _selectedVisionModel = State(initialValue: profile?.selectedVisionModel ?? profile?.selectedTextModel ?? "gpt-4o-mini")
    }

    private var normalizedModels: [String] {
        AIProviderProfile.normalizedModels(from: modelsText)
    }

    private var isTesting: Bool { testingKind != nil }

    var body: some View {
        Form {
            Section("aiProvider.connection".localized) {
                TextField("aiProvider.name".localized, text: $name)
                TextField("settings.baseUrl".localized, text: $baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("settings.apiKey".localized, text: $apiKey)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section {
                TextEditor(text: $modelsText)
                    .font(.footnote.monospaced())
                    .frame(minHeight: 120)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if normalizedModels.isEmpty {
                    Text("aiProvider.modelRequired".localized)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Picker("aiProvider.textModel".localized, selection: $selectedTextModel) {
                        ForEach(normalizedModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    Picker("aiProvider.visionModel".localized, selection: $selectedVisionModel) {
                        ForEach(normalizedModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                }
            } header: {
                Text("aiProvider.childModels".localized)
            } footer: {
                Text("aiProvider.textVisionFooter".localized)
            }

            Section {
                Button {
                    testConnection(kind: .text)
                } label: {
                    if testingKind == .text {
                        ProgressView()
                    } else {
                        Label("settings.testTextConnection".localized, systemImage: "text.bubble")
                    }
                }
                .disabled(testingKind != nil || apiKey.isEmpty || normalizedModels.isEmpty)

                Button {
                    testConnection(kind: .vision)
                } label: {
                    if testingKind == .vision {
                        ProgressView()
                    } else {
                        Label("settings.testVisionConnection".localized, systemImage: "photo")
                    }
                }
                .disabled(testingKind != nil || apiKey.isEmpty || normalizedModels.isEmpty)

                if let testMessage {
                    Text(testMessage)
                        .font(.footnote)
                        .foregroundStyle(testFailed ? .red : .green)
                }
            }
        }
        .navigationTitle(name.isEmpty ? "aiProvider.add".localized : name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("nav.cancel".localized) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("nav.save".localized) { save() }
            }
        }
        .onChange(of: modelsText) { _, _ in
            if !normalizedModels.contains(selectedTextModel) {
                selectedTextModel = normalizedModels.first ?? ""
            }
            if !normalizedModels.contains(selectedVisionModel) {
                selectedVisionModel = normalizedModels.first ?? ""
            }
        }
        .alert(
            "common.error".localized,
            isPresented: Binding(
                get: { validationMessage != nil },
                set: { if !$0 { validationMessage = nil } }
            )
        ) {
            Button("nav.done".localized, role: .cancel) {}
        } message: {
            Text(validationMessage ?? "")
        }
    }

    private func save() {
        let profile = AIProviderProfile.normalized(
            id: profileID,
            name: name,
            baseURL: baseURL,
            modelsText: modelsText,
            selectedTextModel: selectedTextModel,
            selectedVisionModel: selectedVisionModel,
            createdAt: createdAt,
            updatedAt: Date()
        )
        guard !profile.baseURL.isEmpty else {
            validationMessage = "settings.invalidUrl".localized
            return
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            validationMessage = "aiProvider.apiKeyRequired".localized
            return
        }
        guard !profile.selectedTextModel.isEmpty || !profile.selectedVisionModel.isEmpty else {
            validationMessage = "aiProvider.modelRequired".localized
            return
        }
        do {
            // 编辑已有配置时保持其原来的 active 状态，不要因为编辑就自动激活（审查 #22）。
            let wasActive = AIProviderStore.shared.activeProfileID() == profileID
            try AIProviderStore.shared.save(profile: profile, apiKey: apiKey, activate: wasActive)
            HapticManager.shared.play(.success)
            onSaved()
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
            HapticManager.shared.play(.error)
        }
    }

    private func testConnection(kind: ConnectionTestKind) {
        let model = kind == .text
            ? (normalizedModels.contains(selectedTextModel) ? selectedTextModel : (normalizedModels.first ?? ""))
            : (normalizedModels.contains(selectedVisionModel) ? selectedVisionModel : (normalizedModels.first ?? ""))
        guard !model.isEmpty else { return }
        testingKind = kind
        testMessage = nil
        Task {
            do {
                var value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                while value.hasSuffix("/") { value.removeLast() }
                guard let url = URL(string: value + "/chat/completions") else {
                    throw AITranslationRequestError.invalidConfiguration("settings.invalidUrl".localized)
                }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = 25
                let body: [String: Any]
                if kind == .vision {
                    // 与 AITranslator.recognizeVisionImage 相同的内容格式：小图验证多模态输入
                    guard let imageURL = tinyPNGDataURL() else {
                        throw AITranslationRequestError.invalidConfiguration("settings.imageEncodingFailed".localized)
                    }
                    body = [
                        "model": model,
                        "messages": [
                            [
                                "role": "user",
                                "content": [
                                    ["type": "text", "text": "Return OK."],
                                    ["type": "image_url", "image_url": ["url": imageURL]]
                                ]
                            ]
                        ],
                        "max_tokens": 8
                    ]
                } else {
                    // 文本模型测试直接走真实整页翻译协议（审查 #2）：
                    // 只有 parser 能通过才显示“兼容”，避免“连接成功但读漫画报错”。
                    let testItems = [
                        AIPageTranslationItem(id: "b0", sourceText: "Hello!", order: 0),
                        AIPageTranslationItem(id: "b1", sourceText: "Where are you going?", order: 1)
                    ]
                    let prompt = try AIPageTranslationPromptBuilder.prompt(
                        items: testItems,
                        sourceLanguage: nil,
                        target: .simplifiedChinese,
                        styleInstructions: AITranslator.defaultTranslationStyleInstructions
                    )
                    body = [
                        "model": model,
                        "messages": [
                            ["role": "system", "content": "你只做漫画整页翻译。必须保留输入 id，只输出严格 JSON。"],
                            ["role": "user", "content": prompt]
                        ],
                        "temperature": 0.15,
                        "max_tokens": 200
                    ]
                }
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let response = response as? HTTPURLResponse else {
                    throw AITranslationRequestError.invalidConfiguration("settings.invalidResponse".localized)
                }
                guard (200..<300).contains(response.statusCode) else {
                    let details = String(data: data.prefix(300), encoding: .utf8) ?? ""
                    throw AITranslationRequestError.server(
                        model: model,
                        statusCode: response.statusCode,
                        message: details
                    )
                }
                if kind == .text {
                    let decoded = AIChatResponseDecoder.decode(data)
                    guard let content = decoded.content else {
                        testFailed = true
                        testMessage = "settings.textProtocolNoContent".localized
                        HapticManager.shared.play(.error)
                        return
                    }
                    do {
                        let result = try AIPageTranslationParser.parse(
                            content,
                            expectedItems: [
                                AIPageTranslationItem(id: "b0", sourceText: "Hello!", order: 0),
                                AIPageTranslationItem(id: "b1", sourceText: "Where are you going?", order: 1)
                            ],
                            target: .simplifiedChinese
                        )
                        guard !result.items.isEmpty else {
                            throw AIPageTranslationParserError.emptyResult
                        }
                    } catch {
                        testFailed = true
                        let excerpt = String(content.prefix(300))
                        testMessage = "settings.textProtocolIncompatible".localizedFormat(model, excerpt)
                        HapticManager.shared.play(.error)
                        return
                    }
                }
                testFailed = false
                let kindLabel = kind == .text
                    ? "settings.testTextConnection".localized
                    : "settings.testVisionConnection".localized
                testMessage = "settings.connectionSuccess".localizedFormat("\(kindLabel) · \(model)")
                HapticManager.shared.play(.success)
            } catch {
                testFailed = true
                testMessage = error.localizedDescription
                HapticManager.shared.play(.error)
            }
            testingKind = nil
        }
    }

    private func tinyPNGDataURL() -> String? {
        let size = 32
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let image = renderer.image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }
        guard let data = image.pngData() else { return nil }
        return "data:image/png;base64,\(data.base64EncodedString())"
    }
}
