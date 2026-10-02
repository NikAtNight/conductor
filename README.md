# Conductor

Control your Mac with your hands. Conductor watches the camera, tracks your hand with Apple's
Vision framework, and turns gestures into real mouse and keyboard events. Everything runs
on-device. No video leaves the machine.

## Gestures

| Gesture | What it does |
| --- | --- |
| Move hand (thumb and index apart) | Moves the cursor |
| Pinch thumb + index | Mouse down. Hold and move to drag, release to click |
| Two quick pinches | Double click |
| Pinch thumb + middle finger | Right click |
| Closed fist, move up/down | Scroll |
| Both hands pinched, spread or squeeze | Zoom (cmd+scroll, or cmd +/- keys) |

The cursor follows the midpoint between your thumb and index tips. That point barely moves when
you pinch, so clicks land where you aimed.

## Build and run

```sh
./build-app.sh
open Conductor.app
```

The .app wrapper matters. AVFoundation refuses camera access to a bare `swift run` binary because
it has no Info.plist with a camera usage string.

On first launch macOS asks for two permissions:

- Camera, to see your hand.
- Accessibility (System Settings > Privacy & Security > Accessibility), to post mouse and
  keyboard events. Nothing moves until this is granted.

## Development

```sh
swift build
swift test
```

Gesture recognition, smoothing, and screen mapping are plain Swift with no camera dependency, so
they are unit tested with synthesized hand poses.

## Layout

```
Sources/Conductor/
  Camera/      AVCaptureSession wrapper
  Tracking/    Vision hand pose request and the HandPose model
  Gestures/    Gesture state machine, One Euro filter, screen mapping
  Control/     CGEvent posting and permission checks
  MenuBar/     Status item and menu
  Views/       Camera preview with landmark overlay, settings
  Model/       User settings
```
