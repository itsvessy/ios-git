import Foundation
import UIKit

@MainActor
final class KeyboardWarmupCoordinator: ObservableObject {
    private enum Constants {
        static let defaultsKey = "keyboard_warmup_v1_done"
        static let maxAttempts = 3
        static let retryDelayNs: UInt64 = 150_000_000
    }

    private let defaults: UserDefaults
    private let isDisabledForUIRuns: Bool
    private var isWarming = false

    init(defaults: UserDefaults = .standard, processInfo: ProcessInfo = .processInfo) {
        self.defaults = defaults
        self.isDisabledForUIRuns = processInfo.arguments.contains("UITEST_BYPASS_LOCK")
    }

    func warmupIfNeeded(isUnlocked: Bool) {
        guard isUnlocked else {
            return
        }
        guard !isDisabledForUIRuns else {
            return
        }
        guard !isWarming else {
            return
        }
        guard !defaults.bool(forKey: Constants.defaultsKey) else {
            return
        }

        isWarming = true
        Task { @MainActor in
            defer { isWarming = false }

            await Task.yield()

            for attempt in 1...Constants.maxAttempts {
                if runWarmupAttempt() {
                    defaults.set(true, forKey: Constants.defaultsKey)
                    return
                }

                if attempt < Constants.maxAttempts {
                    do {
                        try await Task.sleep(nanoseconds: Constants.retryDelayNs)
                    } catch {
                        return
                    }
                }
            }
        }
    }

    private func runWarmupAttempt() -> Bool {
        guard let keyWindow = resolveKeyWindow() else {
            return false
        }

        let textField = UITextField(frame: CGRect(x: -1024, y: -1024, width: 1, height: 1))
        textField.alpha = 0.001
        textField.tintColor = .clear
        textField.textColor = .clear
        textField.backgroundColor = .clear
        textField.isAccessibilityElement = false
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.textContentType = .none

        keyWindow.addSubview(textField)
        defer {
            textField.removeFromSuperview()
        }

        guard textField.becomeFirstResponder() else {
            return false
        }

        textField.resignFirstResponder()
        return true
    }

    private func resolveKeyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }
}
