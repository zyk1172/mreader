import Combine
import SwiftUI

/// Shared geometry and timing constants used by both the system launch
/// storyboard and the first SwiftUI frame. Keeping the values here makes a
/// change to the launch composition explicit instead of letting the two
/// launch stages drift apart.
nonisolated enum LaunchExperienceMetrics {
    static let backgroundColorName = "LaunchBackground"
    static let glyphImageName = "LaunchGlyph"
    static let artworkVerticalRatio: CGFloat = 0.40
    static let artworkPointSize: CGFloat = 108
    static let brandBottomPadding: CGFloat = 28
    static let labelSpacing: CGFloat = 5
    static let minimumDisplayDurationNanoseconds: UInt64 = 2_000_000_000
    static let fadeDuration: Double = 0.20
    static let overlayAccessibilityIdentifier = "mreader.launch.overlay"
}

nonisolated enum LaunchPhase: Equatable {
    case launching
    case ready
}

/// 启动体验是品牌识别的一部分，固定使用中文，避免系统语言或 storyboard
/// 本地化选择让用户在启动过程中看到不同语言的两套文案。
nonisolated enum LaunchExperienceCopy {
    static let brandLine = "MReader · 读懂每一页"
    static let capabilitiesLine = "本地书架 · AI 翻译 · 沉浸阅读"
}

/// Coordinates the minimum brand exposure with the local state required for
/// the first usable shelf frame. Network maintenance and other background
/// work remain outside this gate.
@MainActor
final class AppLaunchState: ObservableObject {
    @Published private(set) var phase: LaunchPhase = .launching

    private let minimumDisplayDurationNanoseconds: UInt64
    private var hasStarted = false

    init(
        minimumDisplayDurationNanoseconds: UInt64 = LaunchExperienceMetrics.minimumDisplayDurationNanoseconds
    ) {
        self.minimumDisplayDurationNanoseconds = minimumDisplayDurationNanoseconds
    }

    var isVisible: Bool {
        phase == .launching
    }

    func start(prepare: @escaping @MainActor () async -> Void) async {
        guard !hasStarted else { return }
        hasStarted = true

        async let minimumDurationElapsed = Self.wait(
            nanoseconds: minimumDisplayDurationNanoseconds
        )
        async let startupReady = prepare()
        _ = await (minimumDurationElapsed, startupReady)

        guard !Task.isCancelled else { return }
        phase = .ready
    }

    nonisolated private static func wait(nanoseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}

struct LaunchOverlayView: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LaunchGradientBackground()

                Image(LaunchExperienceMetrics.glyphImageName)
                    .resizable()
                    .scaledToFit()
                    .frame(
                        width: LaunchExperienceMetrics.artworkPointSize,
                        height: LaunchExperienceMetrics.artworkPointSize
                    )
                    .position(
                        x: proxy.size.width * 0.5,
                        y: proxy.size.height * LaunchExperienceMetrics.artworkVerticalRatio
                    )

            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .overlay(alignment: .bottom) {
                VStack(spacing: LaunchExperienceMetrics.labelSpacing) {
                    Text(verbatim: LaunchExperienceCopy.brandLine)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(red: 0.118, green: 0.145, blue: 0.188))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Text(verbatim: LaunchExperienceCopy.capabilitiesLine)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 0.400, green: 0.447, blue: 0.518))
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                }
                .padding(.horizontal, 24)
                // Keep the copy at a fixed distance from the full-screen bottom
                // edge during the handoff from the system launch storyboard.
                .padding(.bottom, LaunchExperienceMetrics.brandBottomPadding)
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(LaunchExperienceMetrics.overlayAccessibilityIdentifier)
    }
}

struct LaunchGradientBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.984, green: 0.992, blue: 1.000),
                Color(red: 0.863, green: 0.890, blue: 0.925)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}
