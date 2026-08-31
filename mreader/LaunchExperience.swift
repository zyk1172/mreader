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
                Color(LaunchExperienceMetrics.backgroundColorName)
                    .ignoresSafeArea()

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

                VStack(spacing: LaunchExperienceMetrics.labelSpacing) {
                    Text(verbatim: LaunchExperienceCopy.brandLine)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Text(verbatim: LaunchExperienceCopy.capabilitiesLine)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.horizontal, 24)
                .padding(.bottom, proxy.safeAreaInsets.bottom + LaunchExperienceMetrics.brandBottomPadding)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(LaunchExperienceMetrics.overlayAccessibilityIdentifier)
    }
}
