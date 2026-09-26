import Observation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct MangaVisionFeedbackShortcutButton: View {
    let onTap: () -> Void
    let onQuickMark: () -> Void

    var body: some View {
        Image(systemName: "exclamationmark.bubble")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.thinMaterial, in: Circle())
            .overlay {
                Circle()
                    .strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
            }
            .contentShape(Circle())
            .gesture(
                LongPressGesture(minimumDuration: 0.5)
                    .exclusively(before: TapGesture())
                    .onEnded { value in
                        switch value {
                        case .first(true):
                            onQuickMark()
                        case .second:
                            onTap()
                        default:
                            break
                        }
                    }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("MangaVision 模型反馈")
            .accessibilityHint("轻点打开反馈，长按快速加入训练候选")
            .accessibilityIdentifier("mreader.reader.mangaVisionFeedback")
    }
}

struct MangaVisionHardCaseFeedbackSheet: View {
    let onSave: (MangaVisionHardCaseFeedback) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var affectedAreas: Set<MangaVisionHardCaseAffectedArea> = []
    @State private var issueTypes: Set<MangaVisionHardCaseIssueType> = []
    @State private var productImpacts: Set<MangaVisionHardCaseProductImpact> = []
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("问题涉及") {
                    ForEach(MangaVisionHardCaseAffectedArea.allCases, id: \.self) { item in
                        selectionRow(
                            item.displayName,
                            identifier: "mreader.hardCase.feedback.area.\(item.rawValue)",
                            selected: affectedAreas.contains(item)
                        ) {
                            toggle(item, in: &affectedAreas)
                        }
                    }
                }

                Section("问题类型") {
                    ForEach(MangaVisionHardCaseIssueType.allCases.filter { $0 != .unspecifiedVisualError }, id: \.self) { item in
                        selectionRow(
                            item.displayName,
                            identifier: "mreader.hardCase.feedback.issue.\(item.rawValue)",
                            selected: issueTypes.contains(item)
                        ) {
                            toggle(item, in: &issueTypes)
                        }
                    }
                }

                Section("产品影响") {
                    ForEach(MangaVisionHardCaseProductImpact.allCases, id: \.self) { item in
                        selectionRow(
                            item.displayName,
                            identifier: "mreader.hardCase.feedback.impact.\(item.rawValue)",
                            selected: productImpacts.contains(item)
                        ) {
                            toggle(item, in: &productImpacts)
                        }
                    }
                }

                Section("备注（可选）") {
                    TextField("补充说明", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .navigationTitle("MangaVision 模型反馈")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(
                            MangaVisionHardCaseFeedback(
                                affectedAreas: affectedAreas,
                                issueTypes: issueTypes,
                                productImpacts: productImpacts,
                                note: note
                            )
                        )
                        dismiss()
                    }
                    .disabled(affectedAreas.isEmpty && issueTypes.isEmpty && productImpacts.isEmpty)
                    .accessibilityIdentifier("mreader.hardCase.feedback.save")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("mreader.hardCase.feedback.sheet")
    }

    @ViewBuilder
    private func selectionRow(
        _ title: String,
        identifier: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .accessibilityIdentifier(identifier)
    }

    private func toggle<T: Hashable>(_ value: T, in set: inout Set<T>) {
        if set.contains(value) {
            set.remove(value)
        } else {
            set.insert(value)
        }
    }
}

struct MangaVisionDeveloperSettingsSection: View {
    @AppStorage(MangaVisionHardCaseFeature.shortcutDefaultsKey)
    private var showFeedbackShortcut = false

    @AppStorage(MangaVisionHardCaseImageRetentionPolicy.defaultsKey)
    private var retentionPolicyRaw = MangaVisionHardCaseImageRetentionPolicy.developmentDefault.rawValue

    var body: some View {
        Section(
            header: Text("MangaVision / 模型反馈"),
            footer: Text("默认关闭。开启后，阅读器底部会显示模型反馈按钮。Hard Case 数据仅保存在本机，导出必须手动触发。")
        ) {
            Toggle("显示模型反馈按钮", isOn: $showFeedbackShortcut)
                .accessibilityIdentifier("mreader.settings.mangaVisionFeedbackShortcut")

            Picker("Hard Case 图片保留方式", selection: $retentionPolicyRaw) {
                Text("Reference only")
                    .tag(MangaVisionHardCaseImageRetentionPolicy.referenceOnly.rawValue)
                Text("Copy on capture")
                    .tag(MangaVisionHardCaseImageRetentionPolicy.copyOnCapture.rawValue)
                Text("Copy on export")
                    .tag(MangaVisionHardCaseImageRetentionPolicy.copyOnExport.rawValue)
            }

            NavigationLink {
                MangaVisionHardCaseManagerView()
            } label: {
                Label("Hard Case 管理", systemImage: "exclamationmark.bubble")
            }
            .accessibilityIdentifier("mreader.settings.mangaVisionHardCases")
        }
    }
}

nonisolated enum MangaVisionHardCaseManagerFilter: String, CaseIterable, Sendable {
    case all
    case frame
    case text
    case balloon
    case onomatopoeia
    case guidedPanel
    case ocr
    case translation
    case unreviewed
    case reviewed
    case annotated
    case exported

    var displayName: String {
        switch self {
        case .all: "全部"
        case .frame: "Frame"
        case .text: "Text"
        case .balloon: "Balloon"
        case .onomatopoeia: "Onomatopoeia"
        case .guidedPanel: "Guided Panel 影响"
        case .ocr: "OCR 影响"
        case .translation: "翻译影响"
        case .unreviewed: "未审核"
        case .reviewed: "已审核"
        case .annotated: "已标注"
        case .exported: "已导出"
        }
    }

    func matches(_ record: MangaVisionHardCaseRecord) -> Bool {
        switch self {
        case .all:
            true
        case .frame:
            record.feedback.affectedAreas.contains(.frame)
        case .text:
            record.feedback.affectedAreas.contains(.text)
        case .balloon:
            record.feedback.affectedAreas.contains(.balloon)
        case .onomatopoeia:
            record.feedback.affectedAreas.contains(.onomatopoeia)
        case .guidedPanel:
            record.feedback.productImpacts.contains(.guidedPanel)
        case .ocr:
            record.feedback.productImpacts.contains(.ocr)
        case .translation:
            record.feedback.productImpacts.contains(.translation)
        case .unreviewed:
            record.reviewState == .unreviewed
        case .reviewed:
            record.reviewState == .reviewed
        case .annotated:
            record.reviewState == .annotated
        case .exported:
            record.reviewState == .exported
        }
    }
}

@MainActor
@Observable
final class MangaVisionHardCaseManagerModel {
    var records: [MangaVisionHardCaseRecord] = []
    var statistics = MangaVisionHardCaseStatistics(
        total: 0,
        unreviewed: 0,
        reviewed: 0,
        annotated: 0,
        exported: 0,
        storageBytes: 0
    )
    var filter: MangaVisionHardCaseManagerFilter = .all
    var errorMessage: String?
    var exportDocument: MangaVisionHardCaseZIPDocument?
    var exportFilename = "mangavision-hardcases.zip"
    var isExportingFile = false

    private let store: MangaVisionHardCaseStore

    init(store: MangaVisionHardCaseStore = .shared) {
        self.store = store
    }

    var filteredRecords: [MangaVisionHardCaseRecord] {
        records.filter(filter.matches)
    }

    func reload() async {
        records = await store.allRecords()
        statistics = await store.statistics()
    }

    func update(
        id: UUID,
        feedback: MangaVisionHardCaseFeedback? = nil,
        reviewState: MangaVisionHardCaseReviewState? = nil
    ) async {
        do {
            _ = try await store.update(id: id, feedback: feedback, reviewState: reviewState)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(id: UUID) async {
        do {
            try await store.delete(id: id)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteAll() async {
        do {
            try await store.deleteAll()
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteExportedImages() async {
        do {
            try await store.deleteExportedImages()
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func prepareExport(recordIDs: Set<UUID>? = nil) async {
        do {
            let url = try await store.export(recordIDs: recordIDs)
            let data = try Data(contentsOf: url)
            exportFilename = url.lastPathComponent
            exportDocument = MangaVisionHardCaseZIPDocument(data: data)
            isExportingFile = true
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func imageURL(for record: MangaVisionHardCaseRecord) async -> URL? {
        await store.imageURL(for: record)
    }
}

struct MangaVisionHardCaseManagerView: View {
    @State private var model = MangaVisionHardCaseManagerModel()
    @State private var showDeleteAllConfirmation = false

    var body: some View {
        List {
            Section("统计") {
                HStack {
                    stat("Total", model.statistics.total)
                    stat("Unreviewed", model.statistics.unreviewed)
                    stat("Reviewed", model.statistics.reviewed)
                }
                HStack {
                    stat("Annotated", model.statistics.annotated)
                    stat("Exported", model.statistics.exported)
                    stat("Storage", formattedBytes(model.statistics.storageBytes))
                }
            }

            Section("筛选") {
                Picker("显示", selection: $model.filter) {
                    ForEach(MangaVisionHardCaseManagerFilter.allCases, id: \.self) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
            }

            Section("Hard Cases") {
                if model.filteredRecords.isEmpty {
                    ContentUnavailableView(
                        "暂无 Hard Case",
                        systemImage: "tray",
                        description: Text("阅读时使用 MangaVision 模型反馈入口收集。")
                    )
                } else {
                    ForEach(model.filteredRecords) { record in
                        NavigationLink {
                            MangaVisionHardCaseDetailView(record: record, model: model)
                        } label: {
                            MangaVisionHardCaseRow(record: record)
                        }
                    }
                    .onDelete { offsets in
                        let visible = model.filteredRecords
                        for offset in offsets where visible.indices.contains(offset) {
                            Task { await model.delete(id: visible[offset].id) }
                        }
                    }
                }
            }

            Section("存储与导出") {
                Button {
                    Task { await model.prepareExport() }
                } label: {
                    Label("Export Hard Cases", systemImage: "square.and.arrow.up")
                }
                .disabled(model.records.isEmpty)

                Button {
                    Task { await model.deleteExportedImages() }
                } label: {
                    Label("Delete exported images", systemImage: "photo.badge.minus")
                }
                .disabled(model.statistics.exported == 0)

                Button(role: .destructive) {
                    showDeleteAllConfirmation = true
                } label: {
                    Label("Delete all", systemImage: "trash")
                }
                .disabled(model.records.isEmpty)
            }

            Section {
                Text("Hard Cases are not ground truth until reviewed and annotated.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("LOCAL ONLY。不会自动上传服务器、GitHub 或遥测服务。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("MangaVision Hard Cases")
        .task { await model.reload() }
        .refreshable { await model.reload() }
        .confirmationDialog(
            "删除全部 Hard Cases？",
            isPresented: $showDeleteAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除全部", role: .destructive) {
                Task { await model.deleteAll() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("记录和已保存的页面副本都会被删除，此操作不可撤销。")
        }
        .alert("Hard Case 操作失败", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .fileExporter(
            isPresented: $model.isExportingFile,
            document: model.exportDocument,
            contentType: .zip,
            defaultFilename: model.exportFilename
        ) { result in
            if case let .failure(error) = result {
                model.errorMessage = error.localizedDescription
            }
            model.exportDocument = nil
        }
        .accessibilityIdentifier("mreader.hardCase.manager")
    }

    @ViewBuilder
    private func stat(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text("\(value)").font(.headline).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct MangaVisionHardCaseRow: View {
    let record: MangaVisionHardCaseRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(record.comicTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text("#\(record.pageIndex + 1)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(record.feedback.issueTypes.map(\.displayName).sorted().joined(separator: " · ").nonEmpty ?? "未分类视觉错误")
                .font(.subheadline)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(record.reviewState.rawValue)
                Text("×\(record.feedbackCount)")
                Text(record.analysisState.rawValue)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct MangaVisionHardCaseDetailView: View {
    let record: MangaVisionHardCaseRecord
    let model: MangaVisionHardCaseManagerModel
    @Environment(\.dismiss) private var dismiss

    @State private var feedback: MangaVisionHardCaseFeedback
    @State private var reviewState: MangaVisionHardCaseReviewState
    @State private var enabledClasses: Set<String> = ["frame", "text", "balloon", "onomatopoeia"]
    @State private var previewImage: UIImage?
    @State private var showDeleteConfirmation = false

    init(record: MangaVisionHardCaseRecord, model: MangaVisionHardCaseManagerModel) {
        self.record = record
        self.model = model
        _feedback = State(initialValue: record.feedback)
        _reviewState = State(initialValue: record.reviewState)
    }

    var body: some View {
        Form {
            Section("页面") {
                MangaVisionHardCasePreview(
                    image: previewImage,
                    record: record,
                    enabledClasses: enabledClasses
                )
                .frame(height: 340)
                .listRowInsets(EdgeInsets())
            }

            Section("Detection overlay") {
                ForEach(["frame", "text", "balloon", "onomatopoeia"], id: \.self) { name in
                    Toggle(name, isOn: Binding(
                        get: { enabledClasses.contains(name) },
                        set: { enabled in
                            if enabled { enabledClasses.insert(name) }
                            else { enabledClasses.remove(name) }
                        }
                    ))
                }
            }

            Section("问题涉及") {
                ForEach(MangaVisionHardCaseAffectedArea.allCases, id: \.self) { item in
                    Toggle(item.displayName, isOn: binding(for: item))
                }
            }

            Section("问题类型") {
                ForEach(MangaVisionHardCaseIssueType.allCases, id: \.self) { item in
                    Toggle(item.displayName, isOn: issueBinding(for: item))
                }
            }

            Section("产品影响") {
                ForEach(MangaVisionHardCaseProductImpact.allCases, id: \.self) { item in
                    Toggle(item.displayName, isOn: impactBinding(for: item))
                }
            }

            Section("备注") {
                TextField("备注", text: $feedback.note, axis: .vertical)
                    .lineLimit(2...6)
            }

            Section("审核") {
                Picker("状态", selection: $reviewState) {
                    ForEach(MangaVisionHardCaseReviewState.allCases, id: \.self) { state in
                        Text(state.rawValue).tag(state)
                    }
                }

                Button("Mark reviewed") {
                    reviewState = .reviewed
                    save()
                }

                Button("Reject", role: .destructive) {
                    reviewState = .rejected
                    save()
                }
            }

            Section("导出") {
                Button {
                    Task { await model.prepareExport(recordIDs: Set([record.id])) }
                } label: {
                    Label("Export candidate", systemImage: "square.and.arrow.up")
                }
            }

            Section("元数据") {
                LabeledContent("Model", value: record.modelName)
                LabeledContent("Model SHA", value: record.modelSHA256)
                LabeledContent("Calibration", value: record.calibrationRevision)
                LabeledContent("Page SHA", value: record.pageSHA256)
                LabeledContent("Inference", value: record.inferenceMode.rawValue)
                LabeledContent("Analysis", value: record.analysisState.rawValue)
                LabeledContent("Detections", value: "\(record.detections.count)")
            }

            Section {
                Button("Delete", role: .destructive) {
                    showDeleteConfirmation = true
                }
            }
        }
        .navigationTitle("Hard Case #\(record.pageIndex + 1)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("保存") { save() }
        }
        .task {
            guard let url = await model.imageURL(for: record) else { return }
            previewImage = await Task.detached(priority: .utility) {
                UIImage(contentsOfFile: url.path)
            }.value
        }
        .confirmationDialog(
            "删除这条 Hard Case？",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                Task {
                    await model.delete(id: record.id)
                    dismiss()
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func save() {
        Task {
            await model.update(id: record.id, feedback: feedback, reviewState: reviewState)
        }
    }

    private func binding(for item: MangaVisionHardCaseAffectedArea) -> Binding<Bool> {
        Binding(
            get: { feedback.affectedAreas.contains(item) },
            set: { selected in
                if selected { feedback.affectedAreas.insert(item) }
                else { feedback.affectedAreas.remove(item) }
            }
        )
    }

    private func issueBinding(for item: MangaVisionHardCaseIssueType) -> Binding<Bool> {
        Binding(
            get: { feedback.issueTypes.contains(item) },
            set: { selected in
                if selected { feedback.issueTypes.insert(item) }
                else { feedback.issueTypes.remove(item) }
            }
        )
    }

    private func impactBinding(for item: MangaVisionHardCaseProductImpact) -> Binding<Bool> {
        Binding(
            get: { feedback.productImpacts.contains(item) },
            set: { selected in
                if selected { feedback.productImpacts.insert(item) }
                else { feedback.productImpacts.remove(item) }
            }
        )
    }
}

private struct MangaVisionHardCasePreview: View {
    let image: UIImage?
    let record: MangaVisionHardCaseRecord
    let enabledClasses: Set<String>

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.88)
                if let image {
                    let sourceSize = CGSize(
                        width: max(CGFloat(record.pixelWidth), 1),
                        height: max(CGFloat(record.pixelHeight), 1)
                    )
                    let fit = aspectFitRect(sourceSize: sourceSize, container: proxy.size)

                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: fit.width, height: fit.height)
                        .position(x: fit.midX, y: fit.midY)

                    ForEach(record.detections.filter { enabledClasses.contains($0.detectionClass) }) { detection in
                        let box = detection.normalizedBBox
                        let x = fit.minX + CGFloat(box.xMin) * fit.width
                        let y = fit.minY + CGFloat(box.yMin) * fit.height
                        let width = CGFloat(box.xMax - box.xMin) * fit.width
                        let height = CGFloat(box.yMax - box.yMin) * fit.height
                        Rectangle()
                            .stroke(.white, lineWidth: 1.2)
                            .frame(width: max(width, 1), height: max(height, 1))
                            .position(x: x + width / 2, y: y + height / 2)
                            .overlay(alignment: .topLeading) {
                                Text(detection.detectionClass)
                                    .font(.caption2.monospaced())
                                    .padding(.horizontal, 3)
                                    .padding(.vertical, 1)
                                    .background(.black.opacity(0.68))
                                    .foregroundStyle(.white)
                                    .offset(x: x, y: y)
                            }
                    }
                } else {
                    ContentUnavailableView(
                        "页面预览不可用",
                        systemImage: "photo.badge.exclamationmark",
                        description: Text("记录仍保留 prediction snapshot 和元数据。")
                    )
                    .foregroundStyle(.white)
                }
            }
            .clipped()
        }
    }

    private func aspectFitRect(sourceSize: CGSize, container: CGSize) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0,
              container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / sourceSize.width, container.height / sourceSize.height)
        let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}

struct MangaVisionHardCaseZIPDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
