import Foundation
import Sentry

enum SentryRuntime {
    private(set) static var isEnabled = false

    static func configureIfPossible(serverEnabled: Bool = false) {
        guard serverEnabled else {
            isEnabled = false
            return
        }
        // NOTE: SDK symbol mismatch resolved olana kadar iOS Sentry init kapalı.
        // Backend Sentry açık olsa bile local init açılmadan breadcrumb/scope no-op kalır.
        isEnabled = false
    }

    static func addBreadcrumb(_ configure: (Breadcrumb) -> Void) {
        guard isEnabled else { return }
        let crumb = Breadcrumb()
        configure(crumb)
        SentrySDK.addBreadcrumb(crumb)
    }

    static func configureScope(_ configure: @escaping (Scope) -> Void) {
        guard isEnabled else { return }
        SentrySDK.configureScope(configure)
    }
}
