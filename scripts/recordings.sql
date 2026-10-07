-- Views over the recordings bucket for DuckDB: one row per camera frame, per note, and per
-- gesture in a gesture check. See "Querying the recordings" in the README.
--
--   duckdb -init scripts/recordings.sql
--
-- The views read from the root below. Point them somewhere else, like a downloaded copy of the
-- bucket, with   set variable root = '/path/to/copy';   the views pick it up on the next query.
-- Each view is checked against the files when it's made, so this fails with "No files found"
-- until the bucket holds at least one recording and one report.
install httpfs;
load httpfs;
set variable root = coalesce(getvariable('root'), 'r2://conductor-recordings');

-- Every line of every log. Setup lines, frames and notes share the file; the views below split them.
create or replace view log_lines as
  select regexp_extract(filename, 'recordings/([^/]+)/', 1) as install,
         regexp_extract(filename, '([^/]+)\.jsonl\.gz$', 1) as recording,
         * exclude (filename)
  from read_json_auto(getvariable('root') || '/recordings/*/*.jsonl.gz',
                      filename = true, union_by_name = true, maximum_object_size = 16777216);

-- One camera frame. `hands` is a list of {chirality, joints, confidence}; `measures` is what the
-- recognizer read off the hand driving the cursor ("primary" in the file, a reserved word here).
create or replace view frames as
  select * exclude (event, setup, "primary"), "primary" as measures
  from log_lines where fps is not null;

-- What each recording was made on and with: the Mac, its displays, the camera and where it sits,
-- and the settings in force. One row at the start of a recording and another whenever any of it
-- changed, so join frames to the latest setup row at or before their time.
create or replace view setups as
  select install, recording, time, unnest(setup)
  from log_lines where setup is not null;

-- What happened between frames: refreshes, camera stalls, calibration marks.
create or replace view notes as
  select install, recording, time, event from log_lines where event is not null;

-- One gesture per hand per gesture check, with its verdict and the made and rest readings.
create or replace view reports as
  select regexp_extract(filename, 'reports/([^/]+)/', 1) as install,
         regexp_extract(filename, '([^/]+)\.json$', 1) as report,
         date, unnest(results, max_depth := 2)
  from read_json_auto(getvariable('root') || '/reports/*/*.json', filename = true, union_by_name = true);
