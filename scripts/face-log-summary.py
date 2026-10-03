#!/usr/bin/env python3
"""Per-second summary of the face in a gesture log, for judging whether head pose separates the
displays. Usage: scripts/face-log-summary.py [log.jsonl ...]; with no argument, the newest log."""
import glob, json, os, statistics as st, sys

paths = sys.argv[1:] or [max(glob.glob(os.path.expanduser("~/Library/Logs/Conductor/gestures-*.jsonl")), key=os.path.getmtime)]
for path in paths:
    frames = [json.loads(line) for line in open(path) if '"fps"' in line]
    faces = [f for f in frames if f.get("face")]
    span = frames[-1]["time"] - frames[0]["time"] if frames else 0
    print(f"\n== {os.path.basename(path)}: {len(frames)} frames, {len(faces)} with a face, {span:.1f} s")
    if not faces:
        continue
    face_ms = [f["faceMs"] for f in frames if f.get("faceMs") is not None]
    print(f"faceMs median {st.median(face_ms):.1f} max {max(face_ms):.1f}; "
          f"hand detectMs median {st.median(f['detectMs'] for f in frames):.1f}")
    print(f"face height median {st.median(f['face']['box'][3] for f in faces):.3f}; "
          f"landmark confidence median {st.median(f['face'].get('landmarkConfidence') or 0 for f in faces):.2f}")

    t0 = frames[0]["time"]
    seconds = {}
    for f in faces:
        seconds.setdefault(int(f["time"] - t0), []).append(f["face"])

    def eye(fs, side, key):
        vals = [f[side][key] for f in fs if f.get(side) and f[side].get(key) is not None]
        if not vals:
            return "-"
        if isinstance(vals[0], list):
            return f"{st.mean(v[0] for v in vals):+.2f},{st.mean(v[1] for v in vals):+.2f}"
        return f"{st.mean(vals):.2f}"

    print(" sec  n  pitch mean±sd   yaw   faceH   gazeL dx,dy   gazeR dx,dy  openL openR glareL glareR")
    for s in sorted(seconds):
        fs = seconds[s]
        pitch = [f["pitch"] for f in fs if f.get("pitch") is not None]
        yaw = [f["yaw"] for f in fs if f.get("yaw") is not None]
        height = st.mean(f["box"][3] for f in fs)
        pitch_s = f"{st.mean(pitch):6.1f}±{st.pstdev(pitch):4.1f}" if pitch else "     -     "
        yaw_s = f"{st.mean(yaw):5.1f}" if yaw else "  -  "
        print(f"{s:4d} {len(fs):2d}  {pitch_s}  {yaw_s}  {height:.3f}  {eye(fs, 'leftEye', 'gaze'):>12}  "
              f"{eye(fs, 'rightEye', 'gaze'):>12}  {eye(fs, 'leftEye', 'openness'):>5} {eye(fs, 'rightEye', 'openness'):>5} "
              f"{eye(fs, 'leftEye', 'glare'):>5}  {eye(fs, 'rightEye', 'glare'):>5}")
