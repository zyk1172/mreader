import SwiftUI

private enum AIModelVisionCapability: String, CaseIterable, Identifiable {
    case unknown
    case supported
    case unsupported

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unknown: return "未知"
        case .supported: return "支持"
        case .unsupported: return "不支持"
        }
    }

    init(supportsVision: Bool?) {
        switch supportsVision {
        case .some(true): self = .supported
        case .some(false): self = .unsupported
        case .none: self = .unknown
        }
    }

    var supportsVision: Bool? {
        switch self {
        case .unknown: return nil
        case .supported: return true
        case .unsupported: return false
        }
    }
}

nonisolated enum AIProviderModelSelectionPolicy {
    static func repairedVisionModel(
        selectedModel: String,
        changedModelID: String,
        changedDescriptor: AIModelDescriptor,
        models: [String],
        descriptors: [String: AIModelDescriptor]
    ) -> String {
        guard selectedModel == changedModelID,
              changedDescriptor.supportsVision == false else {
            return selectedModel
        }
        var updatedDescriptors = descriptors
        updatedDescriptors[changedModelID] = changedDescriptor
        return models.first { model in
            (updatedDescriptors[model] ?? AIModelProtocolCatalog.descriptor(for: model)).supportsVision != false
        } ?? ""
    }
}

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
    @State private var modelDescriptors: [String: AIModelDescriptor]
    @State private var selectedTextModel: String
    @State private var selectedVisionModel: String
    @State private var editingModel: ModelEditorItem?
    @State private var testingKind: ConnectionTestKind?
    @State private var testMessage: String?
    @State private var testFailed = false
    @State private var validationMessage: String?

    private enum ConnectionTestKind: String {
        case text
        case vision
    }

    private struct ModelEditorItem: Identifiable {
        let id: String
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
        _modelDescriptors = State(
            initialValue: Dictionary(
                uniqueKeysWithValues: (profile?.modelDescriptors ?? []).map { ($0.id, $0) }
            )
        )
        _selectedTextModel = State(initialValue: profile?.selectedTextModel ?? "gpt-4o-mini")
        _selectedVisionModel = State(initialValue: profile?.selectedVisionModel ?? profile?.selectedTextModel ?? "gpt-4o-mini")
    }

    private var normalizedModels: [String] {
        AIProviderProfile.normalizedModels(from: modelsText)
    }

    private var visionModels: [String] {
        normalizedModels.filter { descriptor(for: $0).supportsVision != false }
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
                        ForEach(visionModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    if visionModels.isEmpty {
                        Text("没有标记为支持视觉输入的模型")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    ForEach(normalizedModels, id: \.self) { model in
                        Button {
                            editingModel = ModelEditorItem(id: model)
                        } label: {
                            modelSummaryRow(for: model)
                        }
                        .buttonStyle(.plain)
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
                .disabled(testingKind != nil || apiKey.isEmpty || visionModels.isEmpty)

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
                selectedVisionModel = visionModels.first ?? ""
            } else if descriptor(for: selectedVisionModel).supportsVision == false {
                selectedVisionModel = visionModels.first ?? ""
            }
        }
        .sheet(item: $editingModel) { item in
            NavigationStack {
                AIModelDescriptorEditorView(
                    modelID: item.id,
                    descriptor: descriptor(for: item.id)
                ) { updatedDescriptor in
                    let repairedVisionModel = AIProviderModelSelectionPolicy.repairedVisionModel(
                        selectedModel: selectedVisionModel,
                        changedModelID: item.id,
                        changedDescriptor: updatedDescriptor,
                        models: normalizedModels,
                        descriptors: modelDescriptors
                    )
                    modelDescriptors[item.id] = updatedDescriptor
                    selectedVisionModel = repairedVisionModel
                    editingModel = nil
                }
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
            updatedAt: Date(),
            modelDescriptors: normalizedModels.map { descriptor(for: $0) }
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
        guard profile.descriptor(for: profile.selectedVisionModel).supportsVision != false else {
            validationMessage = "视觉模型明确不支持图片输入，请选择支持或未知的模型。"
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
            : (visionModels.contains(selectedVisionModel) ? selectedVisionModel : (visionModels.first ?? ""))
        guard !model.isEmpty else { return }
        let modelDescriptor = descriptor(for: model)
        guard kind != .vision || modelDescriptor.supportsVision != false else {
            testFailed = true
            testMessage = "当前模型明确不支持视觉输入。"
            return
        }
        testingKind = kind
        testMessage = nil
        testFailed = false
        Task {
            // 无论成功/失败/提前 return，都要清理测试状态，避免 spinner 卡住（项5）
            defer { testingKind = nil }
            do {
                let request: AITransportRequest
                let expectedItems = [
                    AIPageTranslationItem(id: "b0", sourceText: "Hello!", order: 0),
                    AIPageTranslationItem(id: "b1", sourceText: "Where are you going?", order: 1)
                ]
                if kind == .vision {
                    guard let imageURL = tinyPNGDataURL() else {
                        throw AITranslationRequestError.invalidConfiguration("settings.imageEncodingFailed".localized)
                    }
                    request = AITransportRequest(
                        model: modelDescriptor,
                        userPrompt: "Return OK.",
                        imageDataURL: imageURL,
                        maxTokens: 8,
                        timeout: AITranslationRequestPolicy.connectionTestTimeout,
                        kind: .connectionTest
                    )
                } else {
                    let prompt = try AIPageTranslationPromptBuilder.prompt(
                        items: expectedItems,
                        sourceLanguage: nil,
                        target: .simplifiedChinese,
                        styleInstructions: AITranslator.defaultTranslationStyleInstructions
                    )
                    request = AITransportRequest(
                        model: modelDescriptor,
                        systemPrompt: "你只做漫画整页翻译。必须保留输入 id，只输出严格 JSON。",
                        userPrompt: prompt,
                        responseFormat: .jsonObject,
                        temperature: 0.15,
                        maxTokens: 200,
                        timeout: AITranslationRequestPolicy.connectionTestTimeout,
                        kind: .connectionTest
                    )
                }
                let data = try await AITranslationClient(apiKey: apiKey, baseURL: baseURL).send(request)
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
                            expectedItems: expectedItems,
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

    private func descriptor(for model: String) -> AIModelDescriptor {
        modelDescriptors[model] ?? AIModelProtocolCatalog.descriptor(for: model)
    }

    @ViewBuilder
    private func modelSummaryRow(for model: String) -> some View {
        let modelDescriptor = descriptor(for: model)
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(modelDescriptor.apiProtocol.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    visionCapabilityLabel(for: modelDescriptor.supportsVision)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func visionCapabilityLabel(for supportsVision: Bool?) -> some View {
        switch supportsVision {
        case .some(true):
            Label("视觉", systemImage: "eye.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .some(false):
            Label("无视觉", systemImage: "eye.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .none:
            Label("视觉未知", systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

private struct AIModelDescriptorEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let modelID: String
    let onSave: (AIModelDescriptor) -> Void

    @State private var apiProtocol: AIAPIProtocol
    @State private var visionCapability: AIModelVisionCapability

    init(
        modelID: String,
        descriptor: AIModelDescriptor,
        onSave: @escaping (AIModelDescriptor) -> Void
    ) {
        self.modelID = modelID
        self.onSave = onSave
        _apiProtocol = State(initialValue: descriptor.apiProtocol)
        _visionCapability = State(initialValue: AIModelVisionCapability(
            supportsVision: descriptor.supportsVision
        ))
    }

    var body: some View {
        Form {
            Section {
                Picker("API 协议", selection: $apiProtocol) {
                    ForEach(AIAPIProtocol.allCases, id: \.self) { value in
                        Text(value.displayName).tag(value)
                    }
                }
            } header: {
                Text("API 协议")
            }

            Section {
                Picker("视觉输入", selection: $visionCapability) {
                    ForEach(AIModelVisionCapability.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                if visionCapability == .unknown {
                    Text("视觉能力未知：允许选择，但测试或正式请求失败时请改用明确支持视觉的模型。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("视觉输入")
            }
        }
        .navigationTitle(modelID)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("nav.cancel".localized) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("nav.save".localized) {
                    onSave(AIModelDescriptor(
                        id: modelID,
                        apiProtocol: apiProtocol,
                        supportsVision: visionCapability.supportsVision
                    ))
                    dismiss()
                }
            }
        }
    }
}
