# Conductor

A macOS menu bar app that turns a webcam view of your hands into mouse and keyboard input. This glossary names the concepts the code and the docs share.

## Language

**Hand pose**:
The 21 landmarks Vision reports for one hand in one camera frame, with a confidence per landmark.
_Avoid_: skeleton, observation

**Face pose**:
The face box, head angles (roll, yaw, pitch), and eye landmarks Vision reports for the user's face in one camera frame.
_Avoid_: eye tracking (we measure the head and estimate the eyes), gaze (that is the estimate, not the data)

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

**Look calibration**:
Following a dot around each display's corners so Conductor learns the head angles for each screen.
_Avoid_: gaze calibration, eye calibration

**Look model**:
The average head angle and its spread for each display, one pass per sitting distance, that look calibration saves.
_Avoid_: gaze model

**Separation**:
How far apart two displays' average head angles are, measured in how much the head wanders on each. Decides whether a look calibration is clear, weak, or refused.
_Avoid_: accuracy, confidence

**Switch display**:
The action that moves the control box to another display by hand: the one pointed at on the pointing sign, the next one otherwise. Overrides the look pick until the head has turned elsewhere for a dwell.
_Avoid_: next screen, display override

**Pointing sign**:
Index finger straight, thumb out, the other three curled, held briefly. The thumb out separates it from a relaxed pointing hand. The index finger's direction, up, down, left or right as the user sees it, goes with the trigger.
_Avoid_: finger gun, L shape, point (on its own; a relaxed pointing hand is not the sign)

**Frame pipeline**:
Everything that happens to one camera frame after hand detection, ending in the cursor position and the input commands to post.
_Avoid_: engine (that is the camera, clock, and publishing adapter around it), processing loop

**Input command**:
One thing to post to macOS: a cursor move, a button, a key, a scroll, or a release of everything held.
_Avoid_: event, CGEvent

**Scroll policy**:
The rules that turn what a scroll trigger measured (palm travel, or the lever's offset from neutral) into wheel pixels. They set the lever's rate, keep a flick coasting, and decide what ends a coast.
_Avoid_: momentum scroller, inertia

**Scroll lever**:
Scrolling at a rate set by how far the knuckles sit above or below neutral, with a small dead zone around it. Held scroll triggers use it by default (the scroll style "lever"), and scroll mode always does. The other scroll style, "travel", moves the page by the hand's movement instead and can coast.
_Avoid_: rate control, joystick scrolling

**Scroll mode**:
A state, switched on and off by a trigger bound to it, in which the relaxed hand works the scroll lever and no other trigger fires.
_Avoid_: command mode, scroll lock

**Neutral**:
Where the knuckles were when a scroll trigger engaged, or where they settle just after scroll mode starts. The scroll lever measures from it.
_Avoid_: center, origin

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

**Gesture check**:
Walking every trigger for each hand, made then rested, and scoring how cleanly the current threshold reads it: clear, weak, or refused. A report, not a calibration; it changes nothing.
_Avoid_: gesture calibration (nothing is saved to settings), training
