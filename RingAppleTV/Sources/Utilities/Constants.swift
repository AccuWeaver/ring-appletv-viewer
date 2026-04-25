import Foundation
import CoreGraphics

/// App-wide constants grouped by domain.
enum Constants {

    // MARK: - API

    enum API {
        /// Ring OAuth base URL for authentication.
        static let oauthBaseURL = "https://oauth.ring.com"

        /// Ring REST API base URL for device/event operations.
        static let apiBaseURL = "https://api.ring.com"

        /// OAuth token endpoint.
        static let tokenEndpoint = "\(oauthBaseURL)/oauth/token"

        /// Devices endpoint.
        static let devicesEndpoint = "\(apiBaseURL)/clients_api/ring_devices"

        /// Event history endpoint template (replace `%d` with device ID).
        static let eventHistoryEndpoint = "\(apiBaseURL)/clients_api/doorbots/%d/history"
    }

    // MARK: - Config Defaults

    enum Config {
        /// Default stream timeout in seconds (10 minutes).
        static let streamTimeoutSeconds: TimeInterval = 600

        /// Maximum live stream duration in seconds.
        static let maxStreamDuration: TimeInterval = 600

        /// Interval between automatic device list refreshes (seconds).
        static let deviceRefreshInterval: TimeInterval = 60

        /// How far back to fetch event history (hours).
        static let eventHistoryHours: Int = 48

        /// Maximum number of events to fetch per request.
        static let maxEventCount: Int = 50

        /// Cache time-to-live in seconds (5 minutes).
        static let cacheExpirationSeconds: TimeInterval = 300

        /// Keychain service identifier for token storage.
        static let keychainServiceID = "com.ringappletv.auth"
    }

    // MARK: - UI (10-foot tvOS)

    enum UI {
        /// Number of columns in the device grid on the dashboard.
        static let gridColumns: Int = 3

        /// Standard spacing between grid items.
        static let gridSpacing: CGFloat = 48

        /// Padding inside card views.
        static let cardPadding: CGFloat = 24

        /// Corner radius for cards and containers.
        static let cornerRadius: CGFloat = 16

        /// Large title font size for 10-foot viewing.
        static let largeTitleSize: CGFloat = 48

        /// Title font size.
        static let titleSize: CGFloat = 38

        /// Body text font size.
        static let bodySize: CGFloat = 29

        /// Caption / secondary text font size.
        static let captionSize: CGFloat = 23

        /// Minimum touch/focus target size (Apple HIG for tvOS).
        static let minimumFocusSize: CGFloat = 66
    }
}
