import Combine
import SwiftUI

struct OfflineTranslationStartView: View {
    let comic: ComicBook
    let currentPageIndex: Int
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var coordinator = OfflineTranslationCoordinator.shared
    @AppStorage("translation_target_language") private var targetLanguageRaw = TranslationTargetLanguage.simplifiedChinese.rawValue
    @AppStorage("translation_style_instructions") private var styleInstructions = AITranslator.defaultTranslationStyleInstructions
    @State private var scope: Scope = .entire
    @State private var sourceLanguageRaw: String
    @State private var rangeStart: Int
    @State private var rangeEnd: Int
    @State private var activateWhenComplete = true
    @State private var showingProgress = false

    private enum Scope: String, CaseIterable, Identifiable {
        case entire
        case fromCurrent
        case range
        case missing
        case failed

        var id: String { rawValue }
        var titleKey: String {
            switch self {
            case .entire: return "offlineTranslation.scope.entire"
            case .fromCurrent: return "offlineTranslation.scope.fromCurrent"
            case .range: return "offlineTranslation.scope.range"
            case .missing: return "offlineTranslation.scope.missing"
            case .failed: return "offlineTranslation.scope.failed"
            }
        }
    }

    init(comic: ComicBook, currentPageIndex: Int, initialScopeRaw: String? = nil) {
        self.comic = comic
        self.currentPageIndex = currentPageIndex
        _sourceLanguageRaw = State(initialValue: comic.translationSourceLanguageRaw)
        _scope = State(initialValue: Scope(rawValue: initialScopeRaw ?? "") ?? .entire)
        let last = max(comic.totalPages, 1)
        _rangeStart = State(initialValue: min(max(currentPageIndex + 1, 1), last))
        _rangeEnd = State(initialValue: last)
    }

    private var totalPages: Int { max(comic.totalPages, 1) }

    private var selection: OfflineTranslationSelection {
        switch scope {
        case .entire:
            return .entireComic
        case .fromCurrent:
            return .fromPage(min(max(currentPageIndex, 0), totalPages - 1))
        case .range:
            return .range(start: rangeStart - 1, end: rangeEnd - 1)
        case .missing:
            return .missingPages
        case .failed:
            return .failedPages
        }
    }

    private var providerProfile: AIProviderProfile? {
        let store = AIProviderStore.shared
        let id = store.activeProfileID() ?? store.profiles().first?.id
        return id.flatMap { profileID in store.profiles().first(where: { $0.id == profileID }) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("offlineTranslation.scope.title".localized, selection: $scope) {
                        ForEach(Scope.allCases) { value in
                            Text(value.titleKey.localized).tag(value)
                        }
                    }
                    .pickerStyle(.menu)

                    if scope == .range {
                        Stepper(value: $rangeStart, in: 1...totalPages) {
                            LabeledContent("offlineTranslation.range.start".localized, value: "\(rangeStart)")
                        }
                        Stepper(value: $rangeEnd, in: 1...totalPages) {
                            LabeledContent("offlineTranslation.range.end".localized, value: "\(rangeEnd)")
                        }
                    }
                } header: {
                    Text("offlineTranslation.scope.header".localized)
                } footer: {
                    Text("offlineTranslation.scope.footer".localized)
                }

                Section("offlineTranslation.language.header".localized) {
                    Picker("ocr.sourceLanguage".localized, selection: $sourceLanguageRaw) {
                        ForEach(TranslationSourceLanguage.allCases) { language in
                            Text(language.localizedTitle).tag(language.rawValue)
                        }
                    }
                    Picker("ocr.targetLanguage".localized, selection: $targetLanguageRaw) {
                        ForEach(TranslationTargetLanguage.allCases) { language in
                            Text(language.localizedTitle).tag(language.rawValue)
                        }
                    }
                }

                Section("offlineTranslation.provider.header".localized) {
                    if let profile = providerProfile {
                        LabeledContent("offlineTranslation.provider.name".localized, value: profile.name)
                        LabeledContent(
                            "offlineTranslation.provider.model".localized,
                            value: profile.selectedVisionModel.isEmpty ? "—" : profile.selectedVisionModel
                        )
                        Text(profile.baseURL)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        Label("offlineTranslation.provider.missing".localized, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    Text("offlineTranslation.provider.freezeNotice".localized)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Toggle(
                    "offlineTranslation.activateWhenComplete".localized,
                    isOn: $activateWhenComplete
                )

                Section {
                    Button {
                        coordinator.start(
                            comic: comic,
                            selection: selection,
                            sourceLanguage: TranslationSourceLanguage(rawValue: sourceLanguageRaw) ?? .automatic,
                            targetLanguage: TranslationTargetLanguage.migrateLegacyValue(targetLanguageRaw),
                            styleInstructions: styleInstructions,
                            readingDirectionRaw: comic.readingDirectionRaw,
                            activateWhenComplete: activateWhenComplete
                        )
                    } label: {
                        Label("offlineTranslation.start".localized, systemImage: "play.circle.fill")
                    }
                    .disabled(!coordinator.canStart || (scope == .range && rangeStart > rangeEnd))
                }

                if let error = coordinator.lastError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("offlineTranslation.startTitle".localized)
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: coordinator.job?.id) { _, _ in
                if coordinator.job?.comicID == comic.id {
                    showingProgress = true
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("nav.cancel".localized) { dismiss() }
                }
            }
            .sheet(isPresented: $showingProgress) {
                OfflineTranslationProgressView(comic: comic)
            }
        }
    }
}

struct OfflineTranslationProgressView: View {
    let comic: ComicBook
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var coordinator = OfflineTranslationCoordinator.shared
    @State private var showingCancelConfirmation = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let job = coordinator.job, job.comicID == comic.id {
                    Image(systemName: icon(for: job.state))
                        .font(.system(size: 42))
                        .foregroundStyle(job.state == .needsConfiguration ? .orange : .blue)
                    Text(title(for: job.state))
                        .font(.headline)
                    ProgressView(value: coordinator.progress)
                        .padding(.horizontal)
                    Text("\(Int(coordinator.progress * 100))%")
                        .font(.system(.title2, design: .rounded).monospacedDigit())
                    if let page = job.currentPageIndex {
                        Text("offlineTranslation.currentPage".localizedFormat(page + 1, job.totalPages))
                            .foregroundStyle(.secondary)
                    }
                    Text("offlineTranslation.taskProgress".localizedFormat(
                        min(job.nextPageOffset, job.pageIndexes.count),
                        job.pageIndexes.count
                    ))
                    .foregroundStyle(.secondary)
                    if let manifest = coordinator.manifest, manifest.comicID == comic.id {
                        VStack(spacing: 6) {
                            Text("offlineTranslation.completedCount".localizedFormat(manifest.completedPageCount))
                            Text("offlineTranslation.noTextCount".localizedFormat(manifest.noTextPageCount))
                            Text("offlineTranslation.failedCount".localizedFormat(manifest.failedPageCount))
                            Text("offlineTranslation.coverageDetail".localizedFormat(
                                manifest.coveredPageCount,
                                manifest.totalPages,
                                manifest.failedPageCount
                            ))
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    if let error = job.lastError, !error.isEmpty {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    HStack {
                        if coordinator.isRunning {
                            Button("offlineTranslation.pause".localized) { coordinator.pause() }
                            Button("offlineTranslation.cancel".localized, role: .destructive) {
                                showingCancelConfirmation = true
                            }
                        } else if job.state == .paused
                                    || job.state == .interrupted
                                    || job.state == .cancelled
                                    || job.state == .needsConfiguration {
                            Button("offlineTranslation.resume".localized) {
                                coordinator.resume(job, comic: comic)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    ProgressView()
                }
                Spacer()
            }
            .padding(.top, 30)
            .navigationTitle("offlineTranslation.progressTitle".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("nav.done".localized) { dismiss() }
                }
            }
            .alert("offlineTranslation.stopTitle".localized, isPresented: $showingCancelConfirmation) {
                Button("offlineTranslation.stopAndKeep".localized, role: .destructive) {
                    coordinator.cancel()
                }
                Button("offlineTranslation.keepGoing".localized, role: .cancel) {}
            } message: {
                Text("offlineTranslation.stopMessage".localized)
            }
        }
    }

    private func icon(for state: OfflineTranslationJobState) -> String {
        switch state {
        case .queued, .running: return "arrow.triangle.2.circlepath"
        case .paused, .interrupted: return "pause.circle"
        case .needsConfiguration: return "key.fill"
        case .completed: return "checkmark.circle.fill"
        case .completedWithFailures: return "exclamationmark.circle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    private func title(for state: OfflineTranslationJobState) -> String {
        "offlineTranslation.state.\(state.rawValue)".localized
    }
}

struct OfflineTranslationManagerView: View {
    let comic: ComicBook
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var coordinator = OfflineTranslationCoordinator.shared
    @State private var summaries: [OfflineTranslationSetSummary] = []
    @State private var showingStart = false
    @State private var showingProgress = false
    @State private var startScopeRaw: String?
    @State private var setToDelete: OfflineTranslationSetSummary?

    var body: some View {
        NavigationStack {
            List {
                if summaries.isEmpty {
                    ContentUnavailableView("offlineTranslation.empty".localized, systemImage: "text.badge.xmark")
                } else {
                    ForEach(summaries) { summary in
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(summary.manifest.targetLanguage.localizedTitle)
                                        .font(.headline)
                                    if summary.isActive {
                                        Text("offlineTranslation.active".localized)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.tint)
                                    }
                                    Spacer()
                                    Text("\(Int(summary.manifest.coverage * 100))%")
                                        .monospacedDigit()
                                }
                                Text("offlineTranslation.coverageDetail".localizedFormat(
                                    summary.manifest.coveredPageCount,
                                    summary.manifest.totalPages,
                                    summary.manifest.failedPageCount
                                ))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                Text("\(summary.manifest.providerName) · \(summary.manifest.visionModel)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                HStack {
                                    if !summary.isActive {
                                        Button("offlineTranslation.setActive".localized) {
                                            Task {
                                                try? await OfflineTranslationStorageManager.shared.setActive(
                                                    comicID: comic.id,
                                                    setID: summary.manifest.id
                                                )
                                                await reload()
                                            }
                                        }
                                    }
                                    if let job = summary.jobs.first(where: {
                                        !$0.state.isTerminal || $0.state == .cancelled
                                    }) {
                                        Button("offlineTranslation.resume".localized) {
                                            coordinator.resume(job, comic: comic)
                                            showingProgress = true
                                        }
                                    }
                                    if summary.manifest.failedPageCount > 0 {
                                        Button("offlineTranslation.retryFailed".localized) {
                                            startScopeRaw = "failed"
                                            showingStart = true
                                        }
                                    }
                                    Spacer()
                                    Button("offlineTranslation.deleteSet".localized, role: .destructive) {
                                        setToDelete = summary
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(coordinator.isRunning && coordinator.job?.setID == summary.manifest.id)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("offlineTranslation.manageTitle".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("nav.done".localized) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        startScopeRaw = nil
                        showingStart = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("offlineTranslation.start".localized)
                }
            }
            .task { await reload() }
            .sheet(isPresented: $showingStart) {
                OfflineTranslationStartView(
                    comic: comic,
                    currentPageIndex: comic.currentPageIndex,
                    initialScopeRaw: startScopeRaw
                )
            }
            .sheet(isPresented: $showingProgress) {
                OfflineTranslationProgressView(comic: comic)
            }
            .alert(item: $setToDelete) { summary in
                Alert(
                    title: Text("offlineTranslation.deleteTitle".localized),
                    message: Text("offlineTranslation.deleteMessage".localized),
                    primaryButton: .destructive(Text("offlineTranslation.deleteSet".localized)) {
                        for job in summary.jobs {
                            OfflineTranslationBackgroundScheduler.shared.clearPending(jobID: job.id)
                        }
                        Task {
                            try? await OfflineTranslationStorageManager.shared.deleteSet(
                                comicID: comic.id,
                                setID: summary.manifest.id
                            )
                            await reload()
                        }
                    },
                    secondaryButton: .cancel(Text("nav.cancel".localized))
                )
            }
        }
    }

    private func reload() async {
        summaries = await OfflineTranslationStorageManager.shared.summaries(for: comic.id)
    }
}
