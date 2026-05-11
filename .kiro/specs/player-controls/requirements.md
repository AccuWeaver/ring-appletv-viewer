# Requirements Document

## Introduction

Netflix-style playback controls overlay for the RingAppleTV tvOS app. The overlay appears on Siri Remote interaction over the full-screen live video player, providing camera switching, event timeline scrubbing, playback controls, and audio muting. Controls auto-hide after a period of inactivity and integrate with the tvOS focus system for Siri Remote navigation.

## Glossary

- **Player_Overlay**: The semi-transparent controls layer rendered on top of the video content in PlayerView. Contains the Camera_Switcher, Timeline_Bar, Playback_Controls, and Mute_Toggle.
- **Camera_Switcher**: A pill-shaped button at the top of the Player_Overlay displaying the current camera name and a chevron indicator. Activates the Camera_Picker when selected.
- **Camera_Picker**: A modal list presented over the Player_Overlay allowing the user to select a different Ring camera from the available devices.
- **Timeline_Bar**: A horizontal bar showing event history markers and a playhead indicating the current position relative to the live edge.
- **Live_Indicator**: A label on the Timeline_Bar that shows "Live" when the stream is at the real-time edge.
- **Live_Button**: A focusable button that jumps playback back to the real-time live edge when the user has scrubbed into event history.
- **Playback_Controls**: A horizontal group of transport buttons: skip back, play/pause, and skip forward.
- **Mute_Toggle**: A button that toggles the incoming audio stream between muted and unmuted states.
- **Inactivity_Timer**: A countdown timer that starts when the Player_Overlay becomes visible. When it expires without user interaction, the Player_Overlay hides automatically.
- **Siri_Remote**: The Apple TV remote with a trackpad surface (swipe gestures, click), Play/Pause button, and Menu button.
- **DeviceService**: The application service that provides the list of available Ring cameras.
- **StreamSessionManager**: The application service that manages WebRTC live stream connections.
- **EventService**: The application service that fetches event history for Ring devices.

## Requirements

### Requirement 1: Overlay Visibility Toggle

**User Story:** As a viewer, I want to show and hide playback controls by tapping the Siri Remote, so that I can access controls without permanently obscuring the video.

#### Acceptance Criteria

1. WHEN the user presses the center button on the Siri_Remote while the Player_Overlay is hidden, THE Player_Overlay SHALL become visible with a fade-in animation.
2. WHEN the user presses the center button on the Siri_Remote while the Player_Overlay is visible, THE Player_Overlay SHALL become hidden with a fade-out animation.
3. WHEN the Player_Overlay becomes visible, THE Inactivity_Timer SHALL start with a duration of 5 seconds.
4. WHEN the user interacts with any control while the Player_Overlay is visible, THE Inactivity_Timer SHALL reset to 5 seconds.
5. WHEN the Inactivity_Timer expires, THE Player_Overlay SHALL become hidden with a fade-out animation.
6. WHILE the Player_Overlay is hidden, THE Player_Overlay SHALL NOT participate in the tvOS focus system.

### Requirement 2: Camera Switcher

**User Story:** As a viewer, I want to switch between my Ring cameras without leaving the player, so that I can quickly check different camera feeds.

#### Acceptance Criteria

1. THE Camera_Switcher SHALL display the name of the currently active camera and a chevron icon inside a pill-shaped container.
2. WHEN the user selects the Camera_Switcher, THE Camera_Picker SHALL appear displaying all online devices from the DeviceService.
3. WHEN the user selects a different device in the Camera_Picker, THE StreamSessionManager SHALL end the current stream session.
4. WHEN the user selects a different device in the Camera_Picker, THE StreamSessionManager SHALL start a new stream session for the selected device.
5. WHEN the user selects a different device in the Camera_Picker, THE Camera_Switcher SHALL update to display the newly selected camera name.
6. WHEN the user dismisses the Camera_Picker without selecting a device, THE Player_Overlay SHALL remain visible and the current stream SHALL continue unchanged.
7. WHILE only one device is available from the DeviceService, THE Camera_Switcher SHALL be hidden.

### Requirement 3: Event Timeline

**User Story:** As a viewer, I want to see a timeline of recent events and scrub through them, so that I can review what happened at my camera.

#### Acceptance Criteria

1. THE Timeline_Bar SHALL display event markers corresponding to recent events from the EventService for the active device.
2. THE Timeline_Bar SHALL display the Live_Indicator when the stream is at the real-time edge.
3. WHEN the user swipes left on the Siri_Remote trackpad, THE Timeline_Bar SHALL scrub backward through the event history.
4. WHEN the user swipes right on the Siri_Remote trackpad, THE Timeline_Bar SHALL scrub forward through the event history.
5. WHEN the user scrubs to an event marker on the Timeline_Bar, THE Player_Overlay SHALL begin playback of the recorded event video from the EventService.
6. WHEN the stream is not at the real-time edge, THE Live_Button SHALL become visible and focusable.
7. WHEN the user selects the Live_Button, THE StreamSessionManager SHALL resume the live stream for the active device.
8. WHILE the user is scrubbing the Timeline_Bar, THE Inactivity_Timer SHALL be paused.

### Requirement 4: Playback Controls

**User Story:** As a viewer, I want play/pause and skip controls, so that I can control video playback during live and recorded viewing.

#### Acceptance Criteria

1. THE Playback_Controls SHALL display a skip-back button, a play/pause button, and a skip-forward button in a horizontal arrangement.
2. WHEN the user selects the play/pause button, THE PlayerViewModel SHALL toggle between playing and paused states.
3. WHEN the user presses the Play/Pause hardware button on the Siri_Remote, THE PlayerViewModel SHALL toggle between playing and paused states regardless of Player_Overlay visibility.
4. WHEN the user selects the skip-back button, THE Timeline_Bar SHALL move the playhead backward by one event.
5. WHEN the user selects the skip-forward button, THE Timeline_Bar SHALL move the playhead forward by one event.
6. WHILE the stream is at the real-time live edge, THE skip-forward button SHALL appear visually disabled and SHALL NOT respond to selection.

### Requirement 5: Mute Toggle

**User Story:** As a viewer, I want to mute and unmute the incoming audio, so that I can control whether I hear sound from the camera.

#### Acceptance Criteria

1. THE Mute_Toggle SHALL display a speaker icon reflecting the current audio state: unmuted or muted.
2. WHEN the user selects the Mute_Toggle while audio is unmuted, THE Player_Overlay SHALL mute the incoming audio stream.
3. WHEN the user selects the Mute_Toggle while audio is muted, THE Player_Overlay SHALL unmute the incoming audio stream.
4. THE Mute_Toggle SHALL persist its state across camera switches within the same player session.

### Requirement 6: Siri Remote Navigation

**User Story:** As a viewer, I want to navigate controls using the Siri Remote directional inputs, so that I can use the player without a touch screen.

#### Acceptance Criteria

1. WHILE the Player_Overlay is visible, THE Player_Overlay SHALL set initial focus on the play/pause button in the Playback_Controls.
2. WHEN the user swipes up on the Siri_Remote trackpad while the Playback_Controls are focused, THE focus SHALL move to the Camera_Switcher.
3. WHEN the user swipes down on the Siri_Remote trackpad while the Camera_Switcher is focused, THE focus SHALL move to the Playback_Controls.
4. THE Mute_Toggle SHALL be reachable via horizontal navigation from the Playback_Controls.
5. WHEN the user presses the Menu button on the Siri_Remote, THE PlayerView SHALL dismiss and return to the previous screen regardless of Player_Overlay visibility.
6. WHILE the Player_Overlay is hidden, THE PlayerView SHALL NOT contain any focusable elements that intercept Siri_Remote directional input.

### Requirement 7: Overlay Layout and Appearance

**User Story:** As a viewer, I want the controls to look polished and not obstruct the video unnecessarily, so that I have a premium viewing experience.

#### Acceptance Criteria

1. THE Player_Overlay SHALL render a semi-transparent gradient background that darkens the top and bottom edges of the video while leaving the center unobscured.
2. THE Camera_Switcher SHALL be positioned at the top-center of the Player_Overlay.
3. THE Playback_Controls SHALL be positioned at the center of the Player_Overlay.
4. THE Timeline_Bar SHALL be positioned at the bottom of the Player_Overlay, spanning the full width with horizontal padding.
5. THE Mute_Toggle SHALL be positioned at the bottom-right of the Player_Overlay.
6. THE Player_Overlay SHALL use fade animations with a duration of 0.3 seconds for show and hide transitions.
