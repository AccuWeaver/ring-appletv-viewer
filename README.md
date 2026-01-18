# Ring Apple TV Viewer

An Apple TV application for viewing Ring camera live streams and recorded events directly on your television.

## Project Goals

This project aims to provide Ring camera owners with a native tvOS experience for monitoring their Ring devices without switching to another device. The app enables users to:

- **Authenticate securely** with Ring credentials (including 2FA support)
- **View all Ring devices** in an intuitive grid layout on the TV screen
- **Watch live video streams** from any Ring camera or doorbell
- **Review recent events** including motion detection and doorbell presses
- **Play recorded videos** from event history

## Key Features

- Native SwiftUI interface optimized for Apple TV remote navigation
- Secure token management with iOS Keychain integration
- HLS video streaming with adaptive quality
- Real-time device status and battery monitoring
- Background refresh for device list and events
- Comprehensive error handling and user feedback

## Technical Stack

- **Platform**: tvOS 15.0+
- **Language**: Swift 5.5+
- **UI Framework**: SwiftUI
- **Architecture**: MVVM with protocol-based dependency injection
- **Video Playback**: AVPlayer with HLS streaming

## Project Status

🚧 **In Development** - Currently in requirements and design phase

## Important Notes

- **Personal Use Only**: This app is for educational purposes and personal use
- **Unofficial API**: Uses Ring's private API (no official API available)
- **Not for Distribution**: Not intended for App Store or public distribution
- **Ring Account Required**: Active Ring account with Ring devices needed

## Documentation

- [Requirements Document](.kiro/specs/AppleTVRing/requirements.md)
- Design Document (coming soon)
- Implementation Tasks (coming soon)

## License

This project is for personal, non-commercial use only.

---

**Disclaimer**: This is an unofficial application and is not affiliated with, endorsed by, or connected to Ring LLC or Amazon.com, Inc.
