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
keys and drags that were still going. Nothing gets stuck down.

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
  one-click setup that holds Right ⌘ for Walkie.

## Build and run

```sh
./build-app.sh
open /Applications/Conductor.app
```

The script installs to /Applications and keeps the previous build in the repo as
`Conductor.app.previous`. Set `APP_OUTPUT` to build somewhere else.

On first launch a setup assistant walks through six steps: camera access, Accessibility, your
screens and where the camera sits, look calibration, reach and pointer speed, and the gestures.
It's in the menu bar menu afterwards too.

Show Preview starts the camera and shows the skeleton Vision found, plus a dashed green box with
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

The .app wrapper matters. AVFoundation refuses camera access to a bare `swift run` binary because
it has no Info.plist with a camera usage string.

### Releasing

`scripts/release.sh` builds a universal Conductor.app signed with the Developer ID certificate in
your keychain, notarizes it when a notarytool keychain profile named `conductor-notary` exists,
staples the ticket, zips it to `dist/Conductor-<version>.zip` (and a copy named `Conductor.zip`,
which the site's download link fetches from the latest release), and writes the Sparkle appcast
for it to `dist/appcast.xml`. It leaves /Applications alone. All three go on the release:

```sh
VERSION=0.1.0 BUILD_NUMBER=1 scripts/release.sh
gh release create v0.1.0 dist/Conductor-0.1.0.zip dist/Conductor.zip dist/appcast.xml --title "Conductor 0.1.0" --notes-file notes.md
```

The signed release checks `releases/latest/download/appcast.xml` once a day and installs an update
on quit; Check for Updates… in the menu does it now. The appcast is signed with the Sparkle EdDSA
key in your keychain, whose public half is in `build-app.sh`, so a hijacked feed can't install
anything. Dev builds carry a different code signature than the release, which Sparkle would refuse,
so they don't update and the menu item says so.

Store the notarization profile once; it asks for an app-specific password from appleid.apple.com:

```sh
xcrun notarytool store-credentials conductor-notary --apple-id <apple id> --team-id <team id>
```

A release build carries a different signature from a dev build, so switching between them makes
macOS forget the Accessibility grant (see Permissions).

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

## Gesture log

Every tracking session writes every camera frame to a new file in `~/Library/Logs/Conductor/`
(Settings > Data > Show Logs opens the folder), split into a new file each hour. Each line is one JSON object: a
timestamp, every hand joint Vision found with its confidence, the measurements the recognizer
decides with (pinch distances, index lift and visible length, finger cross, fist and pointing checks), the mode,
any actions fired, where the cursor went, and frame timing (gap since the previous camera frame, time
in Vision, time for the whole frame). Camera stalls and settings refreshes get their own lines. It's numbers only, never camera images. A log
grows by a few megabytes a minute while a hand is in view; the folder keeps a week or 1 GB of logs
and reports, whichever comes first, oldest deleted first, and the file being written is never touched.

Conductor also runs Vision's face request and logs your face: its box (the height
is a distance gauge), head roll, yaw and pitch in degrees (pitch positive looking down), Vision's
landmark confidence, and for each eye the pupil, where it sits inside the eye opening, how open the
eye is, and a glare figure (the share of near-white pixels over the eye, which climbs when a screen
reflects in glasses). For the log alone the face is read on every sixth frame, since head angles and
distance change slowly and the face request costs more than the hands; in the "Display you're
looking at" mode it's every other frame, and during look calibration every frame. Frames in between
log no face. While the face is being read, the preview draws the face box, eye
outlines and pupils in cyan and shows the head angles next to the frame rate.

Look calibration frames are logged too, with the label "Calibrating look". A note marks when each
dot starts and stops being sampled, naming the display, and a last note holds the fitted pass and
its separation, or why it failed. Turn the log on before calibrating to keep a record of the run.

A logged run can be scored again from the log, which is how a calibration that misbehaved at
someone's desk gets diagnosed:

```sh
CONDUCTOR_LOOK_LOG=~/Library/Logs/Conductor/gestures-2026-10-06-120000.jsonl \
  swift test --filter LookReplayTests/testARealLogReplaysToTheScoreTheAppShowed
```

It prints the displays, sample count, the logged outcome, and the refitted averages, spreads and
separation, and fails if the refit disagrees with what the app showed (angles are logged to a tenth
of a degree, so the second decimal can differ).

Any log can also be run back through the recognizer with the current thresholds, which is how a
threshold change is checked against real hands before it ships. The ready pose is off for the
replay so every gesture counts, and crossed fingers are bound to scroll mode:

```sh
CONDUCTOR_GESTURE_LOG=~/Library/Logs/Conductor/gestures-2026-10-06-181843.jsonl \
  swift test --filter GestureLogReplayTests/testARealLogReplaysThroughTheRecognizer
```

It prints every click, swipe, key press/release, scroll-mode switch and display switch with the time
and what the app showed on that frame, then the totals. Set `CONDUCTOR_GESTURE_MAP` to a file containing
an encoded `GestureMap` to replay custom bindings too. In particular, the standard map leaves the
ring pinch unbound, so it cannot reproduce conflicts with ring-finger push-to-talk.

Replay runs the recognizer without posting input. Its ready-pose setting and map can differ from
the recording, and recovering an earlier mode switch changes how later frames are interpreted.
The logs contain joint positions but no labels for intended gestures, so action totals alone do
not measure accuracy.

The first line of every log is a setup line, written again whenever any of it changes: the install
ID (below), the app version and build, the macOS version, the Mac's model identifier and CPU
architecture, each display's name, position, size in points and Retina scale, the camera's name,
model and active format, where the camera sits, whether Accessibility is granted, and the settings
in force, with per-app profiles reduced to a count and camera and display UUIDs replaced by names.
Without the thresholds that fired an action the frames can't be read back; the display layout is
what the control box was mapped to. Frames also
carry the tracking warning showing at the time (too dark, unsure) and an `idle` flag on frames taken
at the power-saving rate.

## Uploading gesture logs

Conductor sends every finished gesture log and gesture check report in `~/Library/Logs/Conductor/`
to the upload server, so recordings from more than one Mac can be tuned against together. It's on
by default and Settings > Data > "Send logs to the developer" turns it off; the log itself isn't a
setting, since it's how tracking gets tuned. Settings > Data says exactly what it holds and what it
never does (no camera images or video, nothing typed, no app names, nothing that names the person
or the Mac). A build with no server keeps the logs local, and so does turning it off. What goes is the
file on disk and nothing more: the log gzipped (about a tenth the size), the report as it is. The
first time, the app makes itself a random install ID, kept in its preferences, and sends it with
every file and in every log's setup line, so one Mac's recordings sit together without naming
anyone. Nothing in a log names the person or the Mac: no username, hostname, serial number,
hardware, camera or display UUID, or the apps they use. A preferences reset makes a new install ID;
that's the trade for an ID that can't be matched to a machine. The app version and macOS version go
along as headers too.

Uploads happen when tracking stops, once an hour while it runs (the log is split there), when a
gesture check saves its report, from Settings > Data > Upload Now, and at launch for anything left
over (a quit mid-recording, a Mac that was offline). A file
counts as sent only once the server has it, so a failed upload is tried again at the next of those
moments, and the server keeps the first copy if the same file arrives twice. A recording that gzips
past 100 MB is skipped, which the hourly split should keep from ever happening. The gzip and the
upload run on their own queue, never the camera's, and the local files stay until the folder's week
or 1 GB runs out. Settings > Data also shows this Mac's install ID, to quote in a bug report.

The server is a Cloudflare Worker in `ingest/` that files each upload in an R2 bucket as
`recordings/<install id>/<file>.gz` or `reports/<install id>/<file>`. To stand one up:

```sh
cd ingest && npm install
npx wrangler login
npx wrangler r2 bucket create conductor-recordings
npx wrangler secret put UPLOAD_TOKEN    # any long random string; the app sends it as a bearer token
npm run deploy                          # prints the Worker's URL
```

Then build the app with the address and the token, which build-app.sh writes into Info.plist:

```sh
CONDUCTOR_UPLOAD_URL=https://conductor-logs.<your subdomain>.workers.dev \
CONDUCTOR_UPLOAD_TOKEN=<the token> ./build-app.sh
```

Keep those two in a file outside the repo (`~/.config/conductor/upload.env`, mode 600, `source` it
before building) rather than in a shell history or a commit.

`npm test` in `ingest/` runs the Worker's tests and `npm run typecheck` its types.

### What keeps the bucket safe

The token is one shared secret baked into every copy of the app, so anyone who opens the app
bundle has it. The Worker is written on the assumption that they do. It takes PUT only, over HTTPS,
of the two file names Conductor writes, under a UUID install ID, under 100 MB, with a SHA-256 the
app sends and R2 checks against the body. A name that's already there is never overwritten: the
same file again gets a 200, a different file a 409. Each install gets 20 uploads a minute and each
address 60, through Workers rate limiting, and the token compare is of digests, so neither the
token's bytes nor its length show in response times. Nothing can be read back: the Worker has no
GET, the bucket stays private (no r2.dev access), and reading goes through an R2 API token with
read access that lives only on the machine running DuckDB.

So a leaked token lets someone add junk logs at a bounded rate and nothing more. If that starts,
rotate: `npx wrangler secret put UPLOAD_TOKEN` with a new value, rebuild the app, and the old builds'
uploads fail quietly until people update. Treat installs as untrusted in analysis, since an install
ID is whatever the uploader says it is; the files under an ID you know are the ones to tune from.
The app side never follows a redirect, so a server that bounces the request can't send the token
elsewhere, and reads only the status code and the first 200 bytes of the reply.

What's left is the Cloudflare account itself: keep two-factor on, scope any API token to this
Worker and bucket, and set a billing alert on R2 storage so a flood shows up as a notification
rather than a bill.

## Querying the recordings

DuckDB reads the gzipped logs straight from the bucket; nothing is imported first. Install it
(`brew install duckdb`), make an R2 API token with read access in the Cloudflare dashboard, and tell
DuckDB about it once:

```sql
CREATE PERSISTENT SECRET r2 (TYPE r2, KEY_ID '<access key id>', SECRET '<secret>', ACCOUNT_ID '<account id>');
```

DuckDB reads an R2 secret only for `r2://` paths, which is what the views use; `s3://` would go to
Amazon and fail.

`scripts/recordings.sql` defines views over the bucket, each row tagged with the install ID and the
recording or report it came from: `frames` (one row per camera frame; `hands`, `measures`, `face` and
`cursor` are nested columns, and `measures` is the log's `primary`, a reserved word in SQL), `notes`
(the lines between frames), `setups` (one row per setup line: the Mac, displays, camera and
settings), and `reports` (one row per gesture per hand in each gesture check).

```sh
duckdb -init scripts/recordings.sql
```

DuckDB checks each view against the files when it's made, so until the bucket holds a recording
and a report this stops with "No files found".

```sql
select recording, count(*) as frames, avg(measures.pinch.indexTip) as index_pinch
from frames where measures is not null group by 1 order by 1;
select hands[1].joints.indexTip, mode from frames where len(hands) > 0 limit 5;
select hand, title, verdict, count(*) from reports group by all order by 1, 2;
select install, len(displays) as monitors, displays[1].width, model, settings.pinchEngage from setups;
```

The views read wherever the `root` variable points. To work on a downloaded copy of the bucket with
the same folder layout, `set variable root = '/path/to/copy';` and the next query uses it. A
recording's file is the same JSONL the replay tests take, so `gunzip` it and run it back through the
recognizer as above.

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

The gesture path is `Engine` → `FramePipeline` → `GestureRecognizer.update` → input commands.
`HandPose` supplies the geometry. Regression tests for the October 6 recordings are in
`PinchRobustnessTests`, `SwipeTests`, and `ScrollModeTests`: a folded thumb must not start push-to-talk
while two fingers are forming, short horizontal flicks must swipe without vertical drift doing so,
and last-joint evidence may sustain a cross without starting one from uncrossed visible tips.
`TriggerReading` answers whether a trigger could start on one frame. The recognizer starts triggers
from it and the gesture check scores it, so the check can't drift from what the recognizer does.
The check also shares the swipe direction calculation and the main hand choice with the recognizer.

Run those cases with:

```sh
swift test --filter 'PinchRobustnessTests|SwipeTests|ScrollModeTests|GestureCheckTests'
```

These tests and the log replay check recognition and emitted actions. Comfort, intended swipe
direction, and camera tracking after a rebuild still need a live trial.

Local verification on October 6, 2026, macOS arm64: `swift test` passed 286 tests with two optional
log tests skipped. All 12 recordings with frame data replayed using the push-to-talk map; one empty
recording was skipped. The signed release build passed signature verification. This was tested on
base commit `37d1ac7` plus uncommitted changes. Local evidence is in `/tmp/conductor-tests-final.txt`,
`/tmp/conductor-replay-final/`, and `/tmp/conductor-release-final.txt`; this turn's patch is
`/tmp/conductor-2012-fixes.patch`. Replay outcomes still need interpretation against intended gestures.


```
Sources/Conductor/
  Engine.swift   Camera queue, Vision, clock, stall watchdog, calibration, gesture log, posting
                 input, publishing to the UI
  FramePipeline.swift  One frame after detection: recognizer, filter, pointers, scroll and zoom,
                 the input gate. Hands and a time in, cursor and input commands out
  Camera/        AVCaptureSession wrapper, camera choice, brightness/confidence checks
  Tracking/      Vision hand pose and face requests, the HandPose model (open hand, fist, two
                 fingers, the pointing sign), the FacePose model (head angles, eyes), the gesture
                 log and the replays of it (look calibration, hands), gzip and the upload of
                 finished logs
  Gestures/      GestureMap, GestureRecognizer (control, pause, scroll lever and scroll mode, dwell,
                 swipes, pointing), TriggerReading (one frame's start condition per trigger),
                 ControlBox, ScreenMapper, calibration, One Euro filter, pointer helpers,
                 ScrollPolicy, LookPicker, GestureCheck (per-hand gesture report)
  Control/       CGEvent posting (incl. held modifier keys), Accessibility check, global hotkey
  Feedback/      Cursor ring overlay, hand map, sounds and VoiceOver announcements
  MenuBar/       Status item and menu
  Views/         Preview, toolbar-tab settings window, setup assistant, look calibration overlay,
                 gesture check window
  Model/         Settings (every knob and its default), Preferences (stores Settings in UserDefaults),
                 presets and app profiles, TrackingState (UI)
ingest/          The upload server: a Cloudflare Worker that files logs and reports in R2
scripts/recordings.sql  DuckDB views over the bucket (frames, notes, reports)
```

## Not in the MVP

Things that came up while scoping and were left out on purpose:

- Keyboard input or an on-screen keyboard.
- Gaze tracking. Head pose picks a display; nothing follows the eyes.
