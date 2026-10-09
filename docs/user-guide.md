# User guide

[Overview and download](../README.md) · [Development and recordings](development.md)

Set up your camera, learn the gestures, and adjust Conductor to your hands and displays.

[First launch](#first-launch) · [Gestures](#gestures) · [Displays](#multiple-displays) · [Tuning](#tuning)

## First launch

On first launch a setup assistant walks through six steps: camera access, Accessibility, your
screens and where the camera sits, look calibration, reach and pointer speed, and the gestures.
It's in the menu bar menu afterwards too.

Show Preview starts the camera and shows the hand landmarks Vision found, plus a dashed green box with
corner handles: that box is the part of the frame that maps to your whole screen. Drag the box to
move it, or drag a corner to resize it; the result is saved as your box, the same as a calibration,
and Settings > Tracking > Use automatic goes back to the automatic layout. Beside the camera, a
panel lists every bound gesture with its picture and action. The one your hand is making lights
up, and each pinch has a bar showing how close that fingertip is to the thumb, so you can watch a
pinch about to fire and see which finger Conductor thinks is closest. Calibrate Reach measures the box
instead, from the area you actually reach while tracing it for six seconds. The cursor follows your
index knuckle, so move your whole hand, not just your fingers. The green box grows as you trace.

Show Hand Map, in the menu bar menu, puts a small always-on-top map in the bottom-right corner while
tracking runs. It shows the box and a dot for your hand, red when the hand is outside the box, so
you can find the box without the preview. Clicks pass through it.

## Permissions

On first start macOS asks for two things:

- Camera, to see your hand.
- Accessibility, to post mouse and keyboard events. macOS opens the dialog, but you still have
  to flip the switch in System Settings > Privacy & Security > Accessibility. The cursor won't
  move until then, and the preview says so.

## Gestures

| Gesture | What it does |
| --- | --- |
| Open hand, held still for half a second | Takes control (the ready pose) |
| Move hand | Moves the cursor (it follows your index knuckle) |
| Pinch thumb + index, held briefly | Mouse down. Hold and move to drag, release to click |
| Two quick pinches | Double click |
| Pinch thumb + middle finger | Right click |
| Two fingers up, hold hand above or below where it was | Scroll, faster the farther you hold it (see below) |
| Closed fist, hold above or below | Scroll, the same way |
| Both hands pinched, spread or squeeze | Zoom (cmd+scroll, or cmd +/- keys) |
| Index and middle up, flick sideways | Swipe: back (⌘[) or forward (⌘]) |
| Index and middle crossed, held briefly | Scroll mode on or off (off by default, see below); a fist held a moment also turns it off |
| Point with your index finger, thumb out, held briefly | Switch display: the screen you point at |
| ⌃⌥⌘H | Turn tracking on or off from anywhere |

Those are the defaults. Every trigger (four pinches, fist, both hands, two fingers, two swipes, crossed
fingers, the pointing sign) can be rebound in Settings > Gestures to click/drag, right click, middle click,
scroll, zoom, a keyboard shortcut, hold a key (push-to-talk), switch display, scroll mode on / off,
pause / resume, or nothing. Each row shows a picture of the sign as you'd see your own hand in the
preview, drawn for your main hand (Settings > Hands, or the picker at the top of the Gestures tab;
either hand can make any gesture). Apps can have their own profile: add an app in the Gestures tab
and its bindings apply while it's in front.

The cursor follows your index knuckle. Pinching, raising two fingers, and making a fist all
move your fingertips but not the knuckle, so none of them drag the cursor and clicks land where you
aimed. At pinch start the cursor also holds still until your hand moves about 3.5% of the frame
(Settings > Tracking > Click dead zone), which stops a click turning into an accidental drag. A
firm pinch held for a second or more drifted up to 3.3% in recorded logs, and at the old 1.2% those
clicks dragged. The cursor holds where it was when the button went down, not where the smoothing
was still heading, which used to creep it on by 10 to 12 px after the press. Past the dead zone
the drag starts from the held spot.

A click also lets go once your thumb and finger have opened past the pinch threshold for 0.15 s,
even short of the release distance, as long as you haven't started dragging. Fingers often come to
rest just short of the release after a click, and the button stayed down while the hand drifted.
A drag keeps the full release, so loosening the pinch mid-drag doesn't drop what it carries.

The camera delivers about 30 frames a second, and a cursor that jumped to each one read as 30
hops a second. Instead the cursor glides from where it is to each new position over the frame that
follows, 120 updates a second, the rate a trackpad reports at. It arrives on each position just as
the next one comes in, so the cost is about a frame of lag at the end of a move. The smoothing loosens
quickly once the hand moves, so it trails a moving hand by about 30 ms; a still hand is smoothed as
hard as before.

### Scrolling

A fist or two raised fingers (others curled) scrolls. Where your knuckles are when the fingers close
is neutral. Hold your hand above neutral to scroll down the page, below it to scroll up; the farther
from neutral, the faster. Near neutral nothing moves. Open your hand and the page stops at once, and
bringing your hand back to where it started scrolls nothing, so there's no return stroke to fight.
The cursor ring turns purple with an arrow for the direction while you scroll. The cursor holds still
in the two-finger pose, and a quick sideways flick in it swipes. Rest the hand briefly before the
next flick; you can keep the two fingers raised. Vertical movement with a little sideways drift
still scrolls.

Your thumb can rest on the curled ring finger. Once the two-finger shape appears, it takes priority
over starting a pinch, including while the pose is being confirmed. To make a separate ring pinch,
leave the little finger extended so the shapes differ. A pinch already held keeps its binding until
you release it.

Settings > Tracking > Scroll by switches to the older style, Move your hand, where the page follows
your hand like a trackpad and a flick coasts. It's less steady: the camera's frame-to-frame noise
in your palm position goes straight into the wheel.

Scrolling and the hand signs work anywhere the camera sees your hand. The control box (below) only
decides where the cursor goes.

A few guards stop accidental clicks. A pinch has to hold for a few frames (about 0.06 s), so a
finger passing the thumb doesn't fire. After any gesture ends, a finger has to open clear of the
thumb before it can pinch, because opening a fist or letting go of one pinch swings fingertips past
the thumb on the way. When your index finger points straight at the camera, its tip can cover your
thumb in the picture without touching it, so pinches don't start in that pose: angle your hand so
the camera sees the finger from the side, or use dwell click. A camera below eye level, or tilted
down at your hands, sees fingers from above and avoids this.

Pinching the ring or little finger drags the thumb past the middle finger, so two fingertips often
sit at the thumb at once. On a near tie the finger further along the hand wins, and the index never
loses a tie. A held middle, ring or little pinch also survives Vision briefly swapping its tip with
a neighbouring finger, which otherwise dropped a push-to-talk key mid-sentence.

If the hand leaves the frame while pinched, the button is released after about 0.4 s, and so is any
held key. Vision loses a pinched hand for a few frames at a time, so a shorter wait cancelled held
keys and drags that were still going. This releases held input when the hand leaves view.

### Scroll mode

Scrolling with a fist or two fingers means holding fingers curled. Scroll mode scrolls the same way
with a relaxed, open hand instead. Turn it on in Settings > Gestures > Scroll mode > Set up, which
binds crossed index and middle fingers to it.

1. Cross your index and middle fingers for about a third of a second. The cursor ring turns purple.
2. Uncross them and rest your hand wherever it's comfortable. After a moment, that spot is neutral.
3. Knuckles above neutral scroll down the page, below it scroll up. Farther from neutral is faster.
   Near neutral nothing scrolls. The ring shows an arrow for the direction, or a bar at rest.
4. Cross your fingers again to go back to pointing. Leaving takes a shorter hold than entering
   (0.15 s against 0.3 s): the finger underneath hides its tip and Vision finds it on about half the
   frames of a real cross, which at the full hold left scroll mode stuck after crosses of over half a
   second. Switching out by mistake only brings the pointer back.
5. If the cross won't read, close your hand into a fist and hold it for a fifth of a second. That
   leaves scroll mode too, and the fist carries on as a fist from there, scrolling by default.

While scroll mode is on, the cursor holds still and pinches, swipes, pause, and a brief fist do
nothing, so fingers curling as you rock your hand can't click. Like pause, scroll mode is shared by every app
profile. Crossing straight out of the two-finger pose can scroll a few pixels before the cross counts,
and uncrossing back into it scrolls as usual. Losing the hand for a moment keeps scroll mode and sets a new
neutral when it comes back. Gone for 1.5 seconds, you're back to pointing.

The camera sees the hand in 2D. Tipping your fingers toward the screen lowers your knuckles in the
picture, and so does tipping them back, so rocking from an upright hand only scrolls up. To scroll both
ways by rocking at the wrist, rest with the hand tipped forward a little when neutral is set. Pushing
the hand toward the screen isn't measured.

Either finger can be on top. Crossed fingers only count with the palm roughly facing the camera.
Turned edge-on, the fingertips line up behind each other and look crossed when they aren't. The
finger underneath often loses its tip to Vision while it's covered; then the last joints of the two
fingers stand in. Those joints also help maintain an existing cross when visible fingertips jitter
apart. A held cross rides out up to three bad frames, though those frames don't count toward the
hold. Fingers that look curled or a palm turned edge-on still cannot start a cross.

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
  one-click setup that holds Right ⌘ for Flo.

## Multiple displays

Settings > Displays has four modes:

- All displays. The control box covers every monitor at once.
- Display under the cursor. Each time your hand comes back into view, Conductor locks onto the
  display the cursor is on. Park the mouse on a monitor, raise your hand, and that monitor is yours
  until the hand drops out of frame.
- Main display only.
- Display you're looking at. The box maps onto whichever screen your head is turned toward. Needs
  look calibration first. Switch display (point at the screen) overrides it by hand.

### Look calibration

Calibrate Look, in the menu bar menu or Settings > Displays, covers every screen and walks a dot
around each one: the four corners, then the centre, about eight seconds per screen. Follow the dot
with your eyes and let your head move the way it normally does. For each screen Conductor saves the
average head pitch and yaw while the dot was on it, and how far your head strayed from that
average. It reads the head, not the eyes: pupils are too small and too easily hidden by glasses
glare to be reliable from a webcam.

When you're looking, the screen whose average is nearest your current head angle gets the box.
Distances are measured in how far your head typically strays, so the line between two screens sits
midway between their averages, with a small dead band around it where the pick stays put.
Switching takes a quarter of a second of looking at the other screen and never happens mid-drag or
mid-scroll. An earlier version saved a range of angles per screen instead; the ranges of stacked
screens overlapped near the edge they share, and inside the overlap the pick never changed.

Run it once from each place you sit. Measurements showed that further back the head moves only a
few degrees between stacked screens while the eyes do the rest, so one close pass can't be scaled
to cover it. Conductor keeps one pass per sitting distance, gauged by how tall your face is in the
picture. A new pass within about 15% of an existing pass's distance replaces it. Between passes it
interpolates; beyond the nearest or furthest pass it extrapolates by geometry alone, which is only
a rough guide. Recalibrate if you move the camera or rearrange the screens. Forget, in Settings >
Displays, drops every pass.

After each run Conductor says how well your head separated the screens from where you sat. It
compares the gap between two screens' averages with how much your head wanders on each. A clear
result needs little else. A weak one is saved but can pick the wrong screen near the edge between
them; that's typical when leaning back. The run fails if the screens are too close to tell apart,
or if it didn't see your face while the dot was on a screen.

Switch display moves the box by hand. The default trigger is the pointing sign: index finger out,
thumb out, the other fingers curled, held for about a third of a second. The cursor ring fills in
indigo while you hold it and the preview label says so. Point up for the screen
above, down for the one below, left or right for a screen beside. With nothing that way, or on any
other trigger bound to Switch display, the box goes to the next screen: top to bottom, then left to
right, and around again, which with two screens is simply the other one. The thumb has to be out: a
relaxed pointing hand rests the thumb on the curled fingers, and that doesn't count, so hovering
with one finger out can't switch. A finger aimed straight at the camera has no readable direction
and doesn't count either.

In "Display you're looking at" a switch sticks until your head has turned toward a different screen
for as long as a normal look switch takes, so neither the head nor a flicker at the edge between
screens undoes it. It also works in "Display under the cursor". It's the dependable option when you
sit far back. Rebind it in Settings > Gestures if the sign is awkward; it used to be thumb + ring
pinch, which pulls on the little finger.

Side-by-side and stacked layouts both work. A few things keep them predictable:

- Camera position. Click where your webcam sits on the display map in Settings. The control box is
  laid out the way your screens sit around the camera, so reaching toward a screen moves the cursor
  onto it. Without a choice, Conductor assumes a built-in camera sits on the built-in display and
  any other camera sits on top of the main display.
- Match the shape of your screens. On by default. The box takes the shape of the area it maps to,
  so a tall stacked layout gets a tall box and up-down moves at the same speed as left-right.
- Distance. Sit further back and your hand looks smaller, so a box that stayed the same part of
  the frame would need a longer reach. The automatic box shrinks and grows with your open hand
  instead, from half to one and a half times the Width setting, so the same hand movement crosses
  the screen wherever you sit. It's measured when you take control, so it never changes size under
  a hand that's using it. A box you calibrated or dragged stays as you set it; Use automatic gets
  the sizing back.
- Gaps. Screens of different sizes leave corners that belong to no display. A point that lands in
  one moves to the nearest edge of the nearest screen.

## Camera and power

Settings > Camera picks the camera, or leaves it on Automatic. After a minute with no hand in view,
Conductor checks for one only a few times a second until a hand shows up again. If the picture is
too dark or tracking keeps guessing, the preview and the menu say so.

Capture prefers the camera's supported 420 YUV format, full range first, then video range, with
BGRA as the fallback. Brightness and eye glare use the same pixel reader and normalize video-range
luma before applying thresholds. Set `CONDUCTOR_CAMERA_BGRA=1` when launching a development build
to compare capture formats on the same camera; each log notes its output format. Vision tracking
quality and conversion cost still
need a live comparison.

## Gesture check

Check Gestures, in the menu bar menu, walks every gesture one hand at a time: the open hand, the
four pinches, the fist, two fingers, crossed fingers, a two-finger flick, the pointing sign, then
both hands pinched. For each it shows the sign, asks you to make it for a couple of seconds, then
to rest, and reads the number the recognizer decides on (thumb to fingertip for a pinch, thumb out
for the open hand and the pointing sign, how far the index sits past the middle for a cross, sideways knuckle
travel in a quarter of a second for a flick) in both phases. The live line under the picture shows the
reading and whether it counts right now, so you can see what the camera makes of your hand before
the clock runs out. Skip this one moves on; closing the window cancels.

At the end each gesture gets a verdict. Clear: read on nearly every frame made and never at rest.
Weak: read most of the time, or rest comes within a few frames of firing. Refused: missed more than
hit, or fired at rest, so the current threshold doesn't fit this hand. Where the made and rest
readings don't overlap the line also gives their midpoint, which is where a threshold for this hand
would sit. Nothing is applied: the report is saved as `gesture-check-<date>.json` beside the
gesture logs, and each line is written to the gesture log if it's recording.

Left and right are checked separately because Vision reports which hand it sees and the two differ.
Each step watches the hand the recognizer would: the one being checked, or the first hand in view
when Vision doesn't report that one.
Readings are in hand scales, so sitting distance cancels out, but the camera angle and the light
don't: run it again if you move the camera.

## Tuning

Menu bar > Settings. Start with the control box: make it as small as you can while still aiming
comfortably, since a smaller box means less arm travel. If aiming still feels too fast, lower the
slow-move speed. If the cursor shivers, lower the smoothing cutoff. If clicks fire when you don't
mean them to, lower pinch engage. If they chatter, raise pinch release.

Lighting matters more than anything else. Vision needs to see your fingers clearly against the
background. A lamp in front of you beats a bright window behind you.

## Limits

Conductor can send keyboard shortcuts and hold keys, but it does not provide text entry or an on-screen keyboard. Display selection uses head angles, not gaze tracking.
