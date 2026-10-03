# Conductor

Control your Mac with your hands. Conductor watches the camera, tracks your hand with Apple's
Vision framework, and turns gestures into real mouse and keyboard events. Everything runs
on-device. No video leaves the machine, and there is no Python, no model download, no server.

## Gestures

| Gesture | What it does |
| --- | --- |
| Open hand, held still for half a second | Takes control (the ready pose) |
| Move hand | Moves the cursor (it follows your index knuckle) |
| Pinch thumb + index, held briefly | Mouse down. Hold and move to drag, release to click |
| Two quick pinches | Double click |
| Pinch thumb + middle finger | Right click |
| Two fingers up, move hand up or down | Scroll, following your hand, with momentum after a flick |
| Closed fist, move up or down | Scroll, the same way |
| Both hands pinched, spread or squeeze | Zoom (cmd+scroll, or cmd +/- keys) |
| Index and middle up, flick sideways | Swipe: back (⌘[) or forward (⌘]) |
| ⌃⌥⌘H | Turn tracking on or off from anywhere |

Those are the defaults. Every trigger (four pinches, fist, both hands, two fingers, two swipes) can be rebound
in Settings > Gestures to click/drag, right click, middle click, scroll, zoom, a keyboard shortcut,
hold a key (push-to-talk), pause / resume, or nothing. Apps can have their own profile: add an app
in the Gestures tab and its bindings apply while it's in front.

The cursor follows your index knuckle. Pinching, raising two fingers, and making a fist all
move your fingertips but not the knuckle, so none of them drag the cursor and clicks land where you
aimed. At pinch start the cursor also freezes until your hand moves a little, which stops a click
turning into a tiny accidental drag.

Two-finger scrolling works like a trackpad: raise index and middle fingers with the others curled,
and the page follows your hand up or down. Let go mid-move and it coasts. The cursor holds still in
that pose, and a quick sideways flick in it swipes.

A few guards stop accidental clicks. A pinch has to hold for a few frames (about 0.06 s), so a
finger passing the thumb doesn't fire. When your index finger points straight at
the camera, its tip can cover your thumb in the picture without touching it, so pinches don't start
in that pose: angle your hand so the camera sees the finger from the side, or use dwell click. A
camera below eye level, or tilted down at your hands, sees fingers from above and avoids this.

If the hand leaves the frame while pinched, the button is released, and so is any held key.
Nothing gets stuck down.

## Control and accessibility

- Ready pose. On by default, so typing or reaching for a drink doesn't move the cursor. Control is
  handed back when your hand has been out of view for 1.5 seconds. Turn it off in Settings > Hands.
- Main hand. Right, left, or whichever comes first.
- Dwell click. Hold the cursor still to click; useful when pinching is hard. Off by default.
- Presets. Standard, Steadier (for tremor), and Bigger movements, in Settings > Hands.
- Pause / resume. Bind a gesture to it to stop input with the camera still on; the same gesture
  resumes.
- Cursor ring. Shows pinch, dwell, and ready-pose progress around the cursor.
- Sounds and VoiceOver. Optional sounds for clicks and control changes. With VoiceOver running,
  taking control, giving it back, pausing, and resuming are announced.
- Fine control. Slow, careful moves carry the cursor 35% of the usual distance so small targets
  are easier to hit. Quick moves go the full distance and bring the cursor back in line with your
  hand. Settings > Tracking > Slow-move speed; 100% turns it off.
- Trackpad mode. Settings > Tracking: the cursor moves by hand travel with acceleration instead of
  sitting where your hand is.
- Push-to-talk. "Hold a key" holds any key while a gesture is held. Settings > Gestures has a
  one-click setup that holds Right ⌘ for LocalFlow.

## Build and run

```sh
./build-app.sh
open /Applications/Conductor.app
```

The script installs to /Applications and keeps the previous build in the repo as
`Conductor.app.previous`. Set `APP_OUTPUT` to build somewhere else.

On first launch a setup assistant walks through camera access, Accessibility, where your camera
sits, and calibrating your reach and pointer speed. It's in the menu bar menu afterwards too.

Show Preview starts the camera and shows the skeleton Vision found, plus a dashed green box: that
box is the part of the frame that maps to your whole screen. Calibrate Reach replaces the
automatic box with the area you actually reach while tracing it for six seconds. The cursor follows
your index knuckle, so move your whole hand, not just your fingers. The green box grows as you trace.

Show Hand Map, in the menu bar menu, puts a small always-on-top map in the bottom-right corner while
tracking runs. It shows the box and a dot for your hand, red when the hand is outside the box, so
you can find the box without the preview. Clicks pass through it.

The .app wrapper matters. AVFoundation refuses camera access to a bare `swift run` binary because
it has no Info.plist with a camera usage string.

### Permissions

On first start macOS asks for two things:

- Camera, to see your hand.
- Accessibility, to post mouse and keyboard events. macOS opens the dialog, but you still have
  to flip the switch in System Settings > Privacy & Security > Accessibility. The cursor won't
  move until then, and the preview says so.

Both grants are tied to the code signature. `build-app.sh` signs with a "Talix Dev Signing"
identity if your keychain has one, or `CODE_SIGN_IDENTITY` if set, so rebuilds keep the grants.
With no identity it falls back to ad-hoc signing, which changes every build and silently voids the
Accessibility grant: the switch in System Settings stays on but belongs to the old build. Fix that
with `tccutil reset Accessibility com.talix.conductor` and allow it again.

## Multiple displays

Settings > Tracking > Displays has three modes:

- All displays. The control box covers every monitor at once.
- Display under the cursor. Each time your hand comes back into view, Conductor locks onto the
  display the cursor is on. Park the mouse on a monitor, raise your hand, and that monitor is yours
  until the hand drops out of frame.
- Main display only.

Side-by-side and stacked layouts both work. A few things keep them predictable:

- Camera position. Click where your webcam sits on the display map in Settings. The control box is
  laid out the way your screens sit around the camera, so reaching toward a screen moves the cursor
  onto it. Without a choice, Conductor assumes a built-in camera sits on the built-in display and
  any other camera sits on top of the main display.
- Match the shape of your screens. On by default. The box takes the shape of the area it maps to,
  so a tall stacked layout gets a tall box and up-down moves at the same speed as left-right.
- Gaps. Screens of different sizes leave corners that belong to no display. A point that lands in
  one moves to the nearest edge of the nearest screen.

## Camera and power

Settings > Camera picks the camera, or leaves it on Automatic. After a minute with no hand in view,
Conductor checks for one only a few times a second until a hand shows up again. If the picture is
too dark or tracking keeps guessing, the preview and the menu say so.

## Gesture log

Menu bar > Record Gesture Log writes every camera frame to a new file in
`~/Library/Logs/Conductor/` (Show Gesture Logs opens the folder). Each line is one JSON object: a
timestamp, every hand joint Vision found with its confidence, the measurements the recognizer
decides with (pinch distances, index lift and visible length, fist and pointing checks), the mode,
any actions fired, where the cursor went, and frame timing (gap since the previous camera frame, time
in Vision, time for the whole frame). Camera stalls and settings refreshes get their own lines. It's numbers only, never camera images, and it stays
on your Mac. Turn it off when you're done; it grows by a few megabytes a minute.

## Tuning

Menu bar > Settings. Start with the control box: make it as small as you can while still aiming
comfortably, since a smaller box means less arm travel. If aiming still feels too fast, lower the
slow-move speed. If the cursor shivers, lower the smoothing cutoff. If clicks fire when you don't
mean them to, lower pinch engage. If they chatter, raise pinch release.

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
  Engine.swift   Camera queue, Vision, clock, stall watchdog, calibration, gesture log, posting
                 input, publishing to the UI
  FramePipeline.swift  One frame after detection: recognizer, filter, pointers, scroll and zoom,
                 the input gate. Hands and a time in, cursor and input commands out
  Camera/        AVCaptureSession wrapper, camera choice, brightness/confidence checks
  Tracking/      Vision hand pose request, the HandPose model (open hand, fist, two fingers),
                 the gesture log
  Gestures/      GestureMap, GestureRecognizer (control, pause, dwell, swipes), ControlBox,
                 ScreenMapper, calibration, One Euro filter, pointer helpers, ScrollPolicy
  Control/       CGEvent posting (incl. held modifier keys), Accessibility check, global hotkey
  Feedback/      Cursor ring overlay, hand map, sounds and VoiceOver announcements
  MenuBar/       Status item and menu
  Views/         Preview, toolbar-tab settings window, setup assistant
  Model/         Preferences (UserDefaults), presets and app profiles, TrackingState (UI)
```

## Not in the MVP

Things that came up while scoping and were left out on purpose:

- Keyboard input or an on-screen keyboard.
- Head or gaze tracking.
