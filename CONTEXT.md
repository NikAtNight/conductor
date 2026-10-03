# Conductor

A macOS menu bar app that turns a webcam view of your hands into mouse and keyboard input. This glossary names the concepts the code and the docs share.

## Language

**Hand pose**:
The 21 landmarks Vision reports for one hand in one camera frame, with a confidence per landmark.
_Avoid_: skeleton, observation

**Pointer**:
The landmark the cursor follows (the index knuckle). A pointer sample is where it is in one frame.
_Avoid_: fingertip, hand position

**Trigger**:
Something a hand can do that Conductor detects: a pinch, a fist, the two-finger pose, both hands pinched, a swipe.
_Avoid_: gesture (when a specific detectable thing is meant), event

**Action**:
What a trigger does when bound: click or drag, right click, scroll, zoom, a shortcut, hold a key, pause or resume, or nothing.
_Avoid_: binding (that is the trigger-to-action pair), command

**Gesture map**:
Which action each trigger does. Everywhere bindings plus per-app profiles.
_Avoid_: key map, mapping

**Control**:
Whether hand movement is allowed to move the cursor at all. Taken with the ready pose, handed back after the hand is gone for a while, independent of pause.
_Avoid_: tracking (that is the camera being on), engaged

**Ready pose**:
A flat open hand held still, the trigger that takes control.
_Avoid_: activation gesture

**Pause**:
A state in which input is suppressed while the camera keeps running, entered and left by a trigger bound to pause or resume.
_Avoid_: stop (that is the camera turning off), tracking off

**Control box**:
The part of the camera frame that maps onto the screen. Automatic from screen layout and camera position, or measured by calibration.
_Avoid_: active area, region of interest

**Calibration**:
Measuring the control box from the area the hand actually reaches while tracing it for a few seconds.
_Avoid_: setup, training

**Frame pipeline**:
Everything that happens to one camera frame after hand detection, ending in the cursor position and the input commands to post.
_Avoid_: engine (that is the camera, clock, and publishing adapter around it), processing loop

**Input command**:
One thing to post to macOS: a cursor move, a button, a key, a scroll, or a release of everything held.
_Avoid_: event, CGEvent

**Scroll policy**:
The rules that turn scroll triggers into wheel pixels, keep a flick coasting, and decide what ends a coast.
_Avoid_: momentum scroller, inertia

**Momentum**:
Scrolling that continues after the hand lets go mid-flick and slows to a stop.
_Avoid_: inertia, kinetic scrolling

**Stall**:
The camera not delivering frames for a second while tracking is on. Releases held input without giving up control.
_Avoid_: freeze, lag (that is what the user feels)

**Hand map**:
The small always-on-top picture of the control box and the pointer, for finding the box without the preview.
_Avoid_: overlay, HUD

**Gesture log**:
The opt-in per-frame record of hand poses, measurements, and what the pipeline did, for tuning.
_Avoid_: telemetry, analytics
