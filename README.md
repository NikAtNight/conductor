# Conductor

Control your Mac with your hands. Conductor watches the camera, tracks your hand with Apple's
Vision framework, and turns gestures into real mouse and keyboard events. Everything runs
on-device. No video leaves the machine, and there is no Python, no model download, no server.

## Gestures

| Gesture | What it does |
| --- | --- |
| Move hand, thumb and index apart | Moves the cursor |
| Pinch thumb + index | Mouse down. Hold and move to drag, release to click |
| Two quick pinches | Double click |
| Pinch thumb + middle finger | Right click |
| Closed fist, move up or down | Scroll |
| Both hands pinched, spread or squeeze | Zoom (cmd+scroll, or cmd +/- keys) |
| ⌃⌥⌘H | Pause or resume tracking from anywhere |

The cursor follows the midpoint between your thumb and index tips. That point barely moves when
you pinch, so clicks land where you aimed. At pinch start the cursor also freezes until your hand
moves about a centimeter, which stops a click turning into a tiny accidental drag.

If the hand leaves the frame while pinched, the button is released. Nothing gets stuck down.

## Build and run

```sh
./build-app.sh
open Conductor.app
```

Then click the hand icon in the menu bar and choose Show Preview. The preview starts the camera
and shows the skeleton Vision found, plus a dashed green box: that box is the part of the frame
that maps to your whole screen.

The .app wrapper matters. AVFoundation refuses camera access to a bare `swift run` binary because
it has no Info.plist with a camera usage string.

### Permissions

On first start macOS asks for two things:

- Camera, to see your hand.
- Accessibility, to post mouse and keyboard events. macOS opens the dialog, but you still have
  to flip the switch in System Settings > Privacy & Security > Accessibility. The cursor won't
  move until then, and the preview says so.

Both grants are tied to the code signature. `build-app.sh` signs ad hoc, so a rebuild usually
keeps them. If macOS re-prompts after a rebuild, remove and re-add Conductor in the Accessibility
list.

## Tuning

Menu bar > Settings. Start with the control box: make it as small as you can while still aiming
comfortably, since a smaller box means less arm travel. If the cursor shivers, lower the smoothing
cutoff. If clicks fire when you don't mean them to, lower pinch engage. If they chatter, raise
pinch release.

Lighting matters more than anything else. Vision needs to see your fingers clearly against the
background. A lamp in front of you beats a bright window behind you.

## Development

```sh
swift build
swift test
```

Gesture recognition, smoothing, and screen mapping are plain Swift with no camera dependency, so
they are unit tested with synthesized hand poses in `Tests/ConductorTests`.

```
Sources/Conductor/
  Engine.swift   Camera -> tracker -> recognizer -> input, on the camera queue
  Camera/        AVCaptureSession wrapper
  Tracking/      Vision hand pose request and the HandPose model
  Gestures/      GestureRecognizer state machine, One Euro filter, ScreenMapper
  Control/       CGEvent posting, Accessibility check, global hotkey
  MenuBar/       Status item and menu
  Views/         Camera preview with overlay, settings form
  Model/         Preferences (UserDefaults) and TrackingState (UI)
```

## Not in the MVP

Things that came up while scoping and were left out on purpose:

- Keyboard input or an on-screen keyboard.
- Custom gesture mapping. The gesture set is fixed in code.
- Multi-display support. Coordinates map to the main display only.
- Gesture-based pause (an open palm hold, say). The hotkey does that job for now.
- Head or gaze tracking.
