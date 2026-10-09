# Development and recordings

[Overview and download](../README.md) · [User guide](user-guide.md) · [Domain glossary](../CONTEXT.md)

Build the app, work with gesture recordings, and run the test suites.

[Build](#build-and-run) · [Release](#releasing) · [Recordings](#gesture-log) · [Tests](#testing-and-architecture)

## Build and run

Run commands from the repository root unless a step says otherwise. Use the macOS SDK and a Swift toolchain that can build this package.

```sh
./build-app.sh
open /Applications/Conductor.app
```

The script installs to /Applications and keeps the previous build in the repo as
`Conductor.app.previous`. Set `APP_OUTPUT` to build somewhere else.

The .app wrapper matters. AVFoundation refuses camera access to a bare `swift run` binary because
it has no Info.plist with a camera usage string.

## Releasing

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
key in your keychain, whose public half is in `build-app.sh`, so Sparkle verifies the update before installing it. Dev builds carry a different code signature than the release, which Sparkle would refuse,
so they don't update and the menu item says so.

Store the notarization profile once; it asks for an app-specific password from appleid.apple.com:

```sh
xcrun notarytool store-credentials conductor-notary --apple-id <apple id> --team-id <team id>
```

A release build carries a different signature from a dev build, so switching between them makes
macOS forget the Accessibility grant (see Permissions).

## Permissions after rebuilding

Both grants are tied to the code signature. `build-app.sh` signs with a "Talix Dev Signing"
identity if your keychain has one, or `CODE_SIGN_IDENTITY` if set, so rebuilds keep the grants.
With no identity it falls back to ad-hoc signing, which changes every build and silently voids the
Accessibility grant: the switch in System Settings stays on but belongs to the old build. Fix that
with `tccutil reset Accessibility com.talix.conductor` and allow it again.

## Gesture log

Every tracking session queues camera frames for a new file in `~/Library/Logs/Conductor/`
(Settings > Data > Show Logs opens the folder), split into a new file each hour. Each line is one JSON object: a
timestamp, every hand joint Vision found with its confidence, the measurements the recognizer
decides with (pinch distances, index lift and visible length, finger cross, fist and pointing checks), the mode,
any actions fired, where the cursor went, and frame timing (gap since the previous camera frame, time
in Vision, time for the whole frame). Camera stalls and settings refreshes get their own lines. It's numbers only, never camera images. A log
grows by a few megabytes a minute while a hand is in view; the folder keeps a week or 1 GB of logs
and reports, whichever comes first, oldest deleted first, and the file being written is never touched.

The active file ends in `.jsonl.inprogress`. A utility worker encodes and writes records in order,
with at most 256 waiting records. If storage falls behind, it drops records and reports the count
instead of blocking camera processing. A settings setup line takes priority over a waiting frame.
On stop or hourly rotation the writer drains, closes, and renames the file to `.jsonl`; only then
can an upload sweep see it. Startup recovers abandoned `.inprogress` files by removing an incomplete
last line. File locks protect recordings still open in another app process. A write or finalization
failure keeps the interrupted file for recovery and reports the error.
On orderly quit, Conductor releases held input first, then waits for the current writer and any
writers still draining after tracking stopped or a log rotated.

Conductor also runs Vision's face request and logs your face: its box (the height
is a distance gauge), head roll, yaw and pitch in degrees (pitch positive looking down), Vision's
landmark confidence, and for each eye the pupil, where it sits inside the eye opening, how open the
eye is, and a glare figure (the share of near-white pixels over the eye, which climbs when a screen
reflects in glasses). For the log alone the face is read on every sixth frame, since head angles and
distance change slowly and the face request costs more than the hands; in the "Display you're
looking at" mode head pose is read every other frame, and during look calibration every frame.
Eye landmarks and glare are computed only on every sixth diagnostic frame during normal tracking.
Calibration uses head pose alone. Frames between face requests log no face. The preview keeps the
last diagnostic eye outline while updating head angles and the face box. YUV glare uses bright luma
and neutral chroma as an approximation of the BGRA near-white check.

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
or the Mac). Turning it off cancels the active request and discards queued upload sweeps. Turning
it back on allows subsequent sweeps; Upload Now requests one immediately. Bytes already accepted by the server remain there. A build with
no server keeps the logs local, and so does turning it off. What goes is the
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
moments, and the server keeps the first copy with an atomic conditional R2 write, including
concurrent uploads. A recording that gzips
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

## Testing and architecture

```sh
swift build --force-resolved-versions
swift test --force-resolved-versions
```

The checked-in `Package.resolved` pins Sparkle for reproducible builds. `.github/workflows/ci.yml`
runs the pinned Swift build and tests on macOS, plus `npm ci`, the Worker tests, TypeScript checking,
and the dependency audit in `ingest/` on Node 22. The workflow runs on pushes and pull requests.

Gesture recognition, smoothing, and screen mapping are plain Swift with no camera dependency, so
they are unit tested with synthesized hand poses in `Tests/ConductorTests`.

The gesture path is `Engine` → `FramePipeline` → `GestureRecognizer.update` → `InputScheduler`
→ `InputController`. The input scheduler owns a separate serial queue for commands, the 120 Hz
cursor glide, and the stall watchdog. A camera or Vision stall cannot prevent it from releasing
held input. Generation tokens reject commands from frames that finish after stop, restart, or
watchdog recovery. Restart admits frames only after its camera-queue reset, so callbacks queued
before stop cannot use the new generation against old recognizer state. Clicks and releases stop
the glide before posting.

`LatestSnapshot` keeps one pending preview update, published on the main actor at up to 30 Hz.
Unchanged scalar values are not published again. Gesture events and calibration samples use their
own ordered delivery so dropping an old preview cannot drop an action or sample.
`SamplingOwnership` gives reach calibration, look calibration, and gesture check one exclusive
owner. Stale completion tokens cannot end a newer run, and stopping tracking cancels the owner.
Ending sampling keeps input muted until the camera queue resets the recognizer. A newer sampling
owner keeps input muted when an older cleanup finishes. Cursor glides retain the measured frame
interval after reaching a target; explicit input cancellation clears that timing history.

A fist leaving scroll mode activates its configured binding. Look-based display selection stays
locked while scroll mode is active. Input timing notes record tick intervals and frame-to-input
queue delay. Camera drop notes include the capture reason. Periodic writer notes record enqueue,
encoding and write times, queue backlog, and drop/failure counts. These measurements locate delays
but do not by themselves establish a speedup.

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

Input and sampling changes are exercised with fake input sinks; no synthetic
input is posted by these regression tests. `InputSchedulerTests` covers timer/watchdog independence
while the camera queue is blocked, stale generations, ordered command completions, and timing.
`RuntimeOwnershipTests` covers competing owners and bounded preview publication.
`EngineLifecycleTests` drives the real Engine with a blocked camera queue and fake input. It checks
early cancellation with held keys/drags, protection of a replacement owner, queued callbacks during
restart, and sampling claimed before initialization finishes.
It also checks frames queued before sampling cleanup, including clicks and held input.
`EngineLogLifecycleTests` checks that shutdown releases input before waiting for blocked writers
and drains recordings that were already closing when tracking stopped.
`GestureLogTests`, `LogUploaderTests`, and `LogUploadHTTPTests` cover writer pressure, close/rename
visibility, crash recovery, opt-out, response bounds, and cancellation through URLSession.
`CameraCaptureTests` and `PixelAnalysisTests` check format selection, row strides and pixel ranges.
The Worker tests include simultaneous conflicting and identical uploads, with one stored copy.

```
Sources/Conductor/
  Engine.swift   Camera queue, Vision, calibration, log lifecycle, input submission, UI snapshots
  SamplingOwnership.swift  Exclusive reach, look, and gesture-check ownership
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
  Control/       InputScheduler owns command order, glide ticks, and the stall watchdog;
                 InputController posts CGEvents, Accessibility check, global hotkey
  Feedback/      Cursor ring overlay, hand map, sounds and VoiceOver announcements
  MenuBar/       Status item and menu
  Views/         Preview, toolbar-tab settings window, setup assistant, look calibration overlay,
                 gesture check window
  Model/         Settings (every knob and its default), Preferences (stores Settings in UserDefaults),
                 presets and app profiles, TrackingState (UI), LatestSnapshot (bounded preview updates)
ingest/          The upload server: a Cloudflare Worker that files logs and reports in R2
scripts/recordings.sql  DuckDB views over the bucket (frames, notes, reports)
```

## Verification history

These notes describe earlier implementation reviews. The temporary paths belong to the original review machine. Check [GitHub CI](https://github.com/dev-talix/conductor/actions/workflows/ci.yml) for current results.

<details>
<summary>October 2026 review notes</summary>

Local verification on October 8, 2026, macOS arm64, Swift 6.4 and Node 22.23.2, base commit
`d1ea7e1` plus `/tmp/conductor-performance-updates.patch`:

- PASS: `swift test --force-resolved-versions`, 380 executed, two optional real-log tests skipped,
  zero failures. Evidence: `/tmp/conductor-performance-tests.log`.
- PASS: `swift build -c release --force-resolved-versions`. Evidence:
  `/tmp/conductor-performance-release-build.log`.
- PASS in `ingest/`: `npm ci`, `npm test`, seven tests, `npm run typecheck`, and
  `npm audit --audit-level=high`, zero vulnerabilities.
- PASS: actual bundled Worker with local workerd/R2, conflicting uploads return 201/409, identical
  uploads return 201/200, and stored bytes match the winner. Local harness:
  `cd ingest && node /tmp/conductor-r2-race-check.cjs`; evidence: `/tmp/conductor-r2-race-check.log`.
- PASS: `git diff --check` and CI YAML parsing. The lockfile is included in the patch.
- RESOLVED: fresh review found early sampling cancellation and queued callbacks during restart.
  Reverting those fixes produced the expected forbidden input and missing held-key/drag behavior.
  Evidence: `/tmp/conductor-engine-lifecycle-red.log`; restored focused checks passed in
  `/tmp/conductor-runtime-lifecycle-green.log`. A separate reviewer rechecked both fixes and found
  no further actionable issue.

The evidence files are local temporary artifacts. The test commands and regression suites remain
in the repository.

Follow-up verification on the same environment, base `fb02dda` plus
`/tmp/conductor-review-fixes.patch`, passed `swift test --force-resolved-versions` with 387 tests,
two optional skips and zero failures, and `swift build -c release --force-resolved-versions`.
Evidence is in `/tmp/conductor-review-fixes-tests.log` and
`/tmp/conductor-review-fixes-release-build.log`. The sampling, cursor cadence and log shutdown
regressions each failed before their fix and passed afterward. The seven Worker tests, TypeScript
check and dependency audit also passed, with zero vulnerabilities.

Live camera accuracy, YUV/BGRA end-to-end timing, Accessibility input, and cursor feel remain
unverified. The merged commit's [GitHub CI run](https://github.com/dev-talix/conductor/actions/runs/37877316665)
passed the application build and Worker checks, but Swift tests failed to compile the nested
expression in `LookReplayTests.pitches`. The follow-up splits that expression into smaller parts;
GitHub CI still needs to run against those changes. No app installation or server deployment is
part of this update.

</details>
