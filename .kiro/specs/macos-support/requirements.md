# Requirements Document

## Introduction

This specification defines the requirements for adding macOS desktop support to the existing Ring Apple TV application. The macOS app will bring Ring doorbell and camera functionality — authentication, device dashboard, event history, and live video streaming — to the Mac desktop. This is the first of three cross-platform specs (macOS, iOS, watchOS).

The app targets macOS 26 (Tahoe) exclusively, leveraging the Liquid Glass design language, Swift 6.2 with approachable concurrency, and the `@Observable` macro for modern reactive state management. The existing RingAppleTV codebase uses SwiftUI with MVVM architecture, protocol-oriented services, and a well-structured separation of concerns. The macOS target will maximize code reuse of shared Models, Services, and Utilities while providing platform-native Views adapted for mouse, keyboard, and trackpad interaction.

## Glossary

- **RingMac_App**: The macOS desktop application target that provides Ring doorbell/camera functionality on Mac, targeting macOS 26 (Tahoe)
- **Shared_Module**: The cross-platform Swift package module containing Models, Services, and Utilities reused across tvOS and macOS targets
- **Auth_View**: The macOS login screen providing email/password authentication with two-factor support
- **Dashboard_View**: The macOS main view displaying Ring devices in a responsive grid layout
- **Events_View**: The macOS view displaying event history in a scrollable list
- **Player_View**: The macOS video player view for live streams and event playback
- **Navigation_Sidebar**: The macOS sidebar providing primary navigation between Dashboard and Events sections
- **Service_Container**: The dependency injection container that wires services and ViewModels for the macOS target
- **Menu_Bar**: The macOS application menu bar providing standard Mac menu items and app-specific actions
- **Toolbar**: The macOS window toolbar providing contextual actions such as refresh and filter controls
- **Liquid_Glass**: Apple's translucent design language introduced in macOS 26 that provides depth and dynamism through light refraction and reflection effects

## Requirements

### Requirement 1: Shared Cross-Platform Module

**User Story:** As a developer, I want shared Models, Services, and Utilities extracted into a cross-platform module, so that the macOS and tvOS targets reuse the same business logic without duplication.

#### Acceptance Criteria

1. THE Shared_Module SHALL contain all Model types (RingDevice, RingEvent, StreamSession, AuthToken, error types, DeviceFilter, AppConfiguration)
2. THE Shared_Module SHALL contain all Service Protocols and Implementations (AuthService, DeviceService, EventService, VideoService, CacheService, KeychainService, RingAPIClient)
3. THE Shared_Module SHALL contain all Utilities (Constants API/Config values, Date+Extensions, RateLimitManager, RetryStrategy)
4. THE Shared_Module SHALL declare platform support for both macOS 26+ and tvOS 15+ in its Package.swift manifest
5. WHEN the Shared_Module is compiled, THE Shared_Module SHALL produce zero compilation errors on both macOS and tvOS platforms
6. THE Shared_Module SHALL migrate ViewModels from ObservableObject to the @Observable macro for use by the macOS target

### Requirement 2: macOS Application Target and Entry Point

**User Story:** As a user, I want a native macOS application for Ring, so that I can monitor my Ring devices from my Mac desktop.

#### Acceptance Criteria

1. THE RingMac_App SHALL define a macOS application target with a minimum deployment target of macOS 26 (Tahoe)
2. THE RingMac_App SHALL use SwiftUI App lifecycle with a WindowGroup scene as the main window
3. WHEN the RingMac_App launches, THE Service_Container SHALL initialize all shared services and ViewModels
4. WHEN the RingMac_App launches, THE RingMac_App SHALL display the Auth_View if the user is not authenticated
5. WHEN the RingMac_App launches and a valid session exists in the KeychainService, THE RingMac_App SHALL display the Dashboard_View directly
6. THE RingMac_App SHALL set a default window size of 1000x700 points and a minimum window size of 700x500 points
7. THE RingMac_App SHALL enable the App Sandbox entitlement with outgoing network connections and Keychain access entitlements
8. THE RingMac_App SHALL use Swift 6.2 language mode with approachable concurrency enabled

### Requirement 3: macOS Authentication View

**User Story:** As a user, I want to log in to my Ring account on macOS, so that I can access my Ring devices from my Mac.

#### Acceptance Criteria

1. THE Auth_View SHALL display email and password text fields centered in the window
2. THE Auth_View SHALL display a "Sign In" button that initiates authentication using the shared AuthViewModel
3. WHEN the AuthService returns a two-factor-required response, THE Auth_View SHALL display a verification code input field and a "Verify" button replacing the "Sign In" button
4. WHILE authentication is in progress, THE Auth_View SHALL display a ProgressView and disable the sign-in button
5. IF authentication fails, THEN THE Auth_View SHALL display the error message returned by the AuthViewModel
6. WHEN authentication succeeds, THE Auth_View SHALL transition to the Navigation_Sidebar and Dashboard_View
7. WHEN the user presses Return/Enter in the password field, THE Auth_View SHALL initiate the login action

### Requirement 4: macOS Navigation Structure

**User Story:** As a user, I want sidebar navigation on macOS, so that I can switch between my device dashboard and event history using standard Mac navigation patterns.

#### Acceptance Criteria

1. THE RingMac_App SHALL use a NavigationSplitView with a Navigation_Sidebar and detail area
2. THE Navigation_Sidebar SHALL display "Dashboard" and "Events" navigation items with appropriate SF Symbol icons
3. WHEN the user selects a navigation item, THE RingMac_App SHALL display the corresponding view in the detail area
4. WHEN the RingMac_App first displays the authenticated view, THE Navigation_Sidebar SHALL select "Dashboard" by default
5. THE Navigation_Sidebar SHALL display a "Sign Out" button that invokes the AuthViewModel logout action and returns to the Auth_View

### Requirement 5: macOS Dashboard View

**User Story:** As a user, I want to see all my Ring devices in a responsive grid on macOS, so that I can monitor my cameras and doorbells from my Mac.

#### Acceptance Criteria

1. THE Dashboard_View SHALL display Ring devices in a responsive LazyVGrid that adapts column count to the window width
2. THE Dashboard_View SHALL display each device as a card showing the device name, device type display name, and online/offline status
3. WHEN the Dashboard_View loads, THE Dashboard_View SHALL invoke the shared DashboardViewModel to fetch devices
4. WHILE devices are loading, THE Dashboard_View SHALL display a loading indicator
5. IF device loading fails, THEN THE Dashboard_View SHALL display an error message with a "Retry" button
6. WHEN no devices are found, THE Dashboard_View SHALL display an empty state message
7. THE Toolbar SHALL display a refresh button and a device type filter picker
8. WHEN the user clicks a device card, THE Dashboard_View SHALL navigate to the Player_View for that device

### Requirement 6: macOS Events View

**User Story:** As a user, I want to view my Ring event history on macOS, so that I can review motion alerts and doorbell presses from my Mac.

#### Acceptance Criteria

1. THE Events_View SHALL display events in a scrollable List with each row showing event type icon, device name, event type display name, and timestamp
2. WHEN the Events_View loads, THE Events_View SHALL invoke the shared EventsViewModel to fetch events
3. WHILE events are loading, THE Events_View SHALL display a loading indicator
4. IF event loading fails, THEN THE Events_View SHALL display an error message with a "Retry" button
5. WHEN no events are found, THE Events_View SHALL display an empty state message with Ring Protect guidance when applicable
6. WHEN the user clicks an event row with video available, THE Events_View SHALL navigate to the Player_View for event playback
7. WHEN the EventsViewModel indicates no Ring Protect subscription, THE Events_View SHALL display a subscription banner

### Requirement 7: macOS Video Player View

**User Story:** As a user, I want to watch live streams and recorded events on macOS, so that I can see what my Ring cameras are capturing in real time or review past recordings.

#### Acceptance Criteria

1. THE Player_View SHALL display an AVPlayer-based video player using the HLS stream URL from the shared PlayerViewModel
2. WHEN the Player_View appears, THE Player_View SHALL invoke the PlayerViewModel to request a live stream for the selected device
3. WHILE the stream is connecting, THE Player_View SHALL display a loading overlay with the device name
4. IF the stream request fails, THEN THE Player_View SHALL display an error message with "Retry" and "Back" buttons
5. THE Player_View SHALL display the device name as an overlay on the video content
6. THE Player_View SHALL display standard AVPlayer playback controls (play, pause, volume, fullscreen)
7. WHEN the user presses the Escape key in the Player_View, THE Player_View SHALL navigate back to the previous view

### Requirement 8: macOS Menu Bar Integration

**User Story:** As a user, I want standard Mac menu bar items, so that the Ring app follows macOS conventions and provides keyboard shortcuts for common actions.

#### Acceptance Criteria

1. THE Menu_Bar SHALL include a "View" menu with a "Refresh" item mapped to Cmd+R that triggers the current view's refresh action
2. THE Menu_Bar SHALL include a "View" menu with "Dashboard" (Cmd+1) and "Events" (Cmd+2) items for sidebar navigation
3. THE Menu_Bar SHALL include an application menu with a "Sign Out" item
4. WHEN the user is not authenticated, THE Menu_Bar SHALL disable navigation and refresh menu items

### Requirement 9: macOS Keyboard and Accessibility Support

**User Story:** As a user, I want full keyboard navigation and accessibility support, so that I can use the Ring macOS app efficiently with keyboard, trackpad, or assistive technologies.

#### Acceptance Criteria

1. THE RingMac_App SHALL support full keyboard Tab navigation across all interactive elements
2. THE RingMac_App SHALL provide accessibility labels for all interactive controls and status indicators
3. THE RingMac_App SHALL support VoiceOver navigation for all views
4. WHEN a device card receives keyboard focus, THE Dashboard_View SHALL display a visible focus ring indicator
5. WHEN an error state is displayed, THE RingMac_App SHALL announce the error message to VoiceOver

### Requirement 10: Platform-Specific UI Adaptation

**User Story:** As a developer, I want macOS-specific UI constants and styling separated from tvOS, so that each platform uses appropriate sizing, spacing, and visual treatment.

#### Acceptance Criteria

1. THE RingMac_App SHALL define macOS-specific UI constants for grid spacing, card padding, corner radius, and font sizes appropriate for desktop viewing distances
2. THE Shared_Module SHALL use conditional compilation or platform-specific constant files to provide correct UI values per platform
3. THE RingMac_App SHALL adopt the Liquid_Glass design language for toolbar, sidebar, and overlay surfaces using the system-provided glass material APIs

### Requirement 11: macOS Window and Lifecycle Management

**User Story:** As a user, I want the Ring macOS app to behave like a proper Mac citizen with correct window and lifecycle behavior.

#### Acceptance Criteria

1. WHEN the user closes the last window, THE RingMac_App SHALL remain running in the Dock
2. WHEN the user re-opens the RingMac_App from the Dock after closing the window, THE RingMac_App SHALL restore a new main window
3. WHEN the RingMac_App moves to the background, THE DashboardViewModel SHALL stop background device refresh to conserve resources
4. WHEN the RingMac_App returns to the foreground, THE DashboardViewModel SHALL resume background device refresh
