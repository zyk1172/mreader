import SwiftUI
import UIKit

enum HapticLevel {
    case light
    case medium
    case heavy
    case selection
    case success
    case warning
    case error
}

enum HapticSettings {
    static let isEnabledKey = "haptic_feedback_enabled"
}

@MainActor
final class HapticManager {
    static let shared = HapticManager()

    private let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let heavyGenerator = UIImpactFeedbackGenerator(style: .heavy)
    private let selectionGenerator = UISelectionFeedbackGenerator()
    private let notificationGenerator = UINotificationFeedbackGenerator()

    private init() {
        prepare()
    }

    func play(_ level: HapticLevel) {
#if targetEnvironment(simulator)
        return
#else
        guard UserDefaults.standard.object(forKey: HapticSettings.isEnabledKey) as? Bool ?? true else { return }

        switch level {
        case .light:
            lightGenerator.impactOccurred(intensity: 0.55)
            lightGenerator.prepare()
        case .medium:
            mediumGenerator.impactOccurred(intensity: 0.7)
            mediumGenerator.prepare()
        case .heavy:
            heavyGenerator.impactOccurred(intensity: 0.9)
            heavyGenerator.prepare()
        case .selection:
            selectionGenerator.selectionChanged()
            selectionGenerator.prepare()
        case .success:
            notificationGenerator.notificationOccurred(.success)
            notificationGenerator.prepare()
        case .warning:
            notificationGenerator.notificationOccurred(.warning)
            notificationGenerator.prepare()
        case .error:
            notificationGenerator.notificationOccurred(.error)
            notificationGenerator.prepare()
        }
#endif
    }

    func prepare() {
#if !targetEnvironment(simulator)
        lightGenerator.prepare()
        mediumGenerator.prepare()
        heavyGenerator.prepare()
        selectionGenerator.prepare()
        notificationGenerator.prepare()
#endif
    }
}

extension View {
    func hapticTap(_ level: HapticLevel = .light) -> some View {
        simultaneousGesture(
            TapGesture().onEnded {
                HapticManager.shared.play(level)
            }
        )
    }
}
