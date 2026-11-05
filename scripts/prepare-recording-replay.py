#!/usr/bin/env python3
"""Copy real saved frames and current non-secret settings into an isolated replay.

Run on the Mac owning the recordings. Uses SQLite's online backup API; never
updates the source database, preferences, media or installed production app.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import sqlite3
import sys

PREFERENCE_KEYS = {
    "aiConfiguration.v1", "colorCategories", "target.current", "target.migratedToEvents",
    "activityCardPromptOverrides.v1", "claudePromptOverrides",
    "llmOutputLanguageOverride", "AppleLanguages", "AppleLocale",
    "screenshotIntervalSeconds", "timelineAnalysisIntervalSeconds",
}


def independent(path, production):
    path, production = path.resolve(), production.resolve()
    return (path != Path("/") and path != production
            and production not in path.parents and path not in production.parents)


def parse_window(value):
    try:
        start, end = [dt.datetime.fromisoformat(part) for part in value.split(",")]
    except (ValueError, TypeError) as error:
        raise argparse.ArgumentTypeError("Use START,END with ISO dates and explicit timezone offsets") from error
    if start.tzinfo is None or end.tzinfo is None or end <= start:
        raise argparse.ArgumentTypeError("Window requires explicit timezones and END > START")
    return {"label": f"{start:%m-%d %H:%M}–{end:%H:%M}",
            "startTs": int(start.timestamp()), "endTs": int(end.timestamp())}


def prepare(source, output, preferences, windows, id_namespace=0):
    source, output = source.resolve(), output.resolve()
    if not independent(output, source):
        raise ValueError("Replay directory must be separate from production, its children and its ancestors")
    if output.exists():
        raise ValueError("Output already exists; choose a new directory (existing replays are never overwritten)")
    if not 0 <= id_namespace <= 1000:
        raise ValueError("id-namespace must be between 0 and 1000")
    windows = sorted(windows, key=lambda window: window["startTs"])
    if not windows or any(a["endTs"] > b["startTs"] for a, b in zip(windows, windows[1:])):
        raise ValueError("Choose non-overlapping recording windows")
    # Validate configuration before creating any output. Never copy login credentials.
    with preferences.open("rb") as handle:
        current = plistlib.load(handle)
    seed = {key: value for key, value in current.items() if key in PREFERENCE_KEYS}
    raw_configuration = seed.get("aiConfiguration.v1")
    if not isinstance(raw_configuration, bytes):
        raise ValueError("No saved AI configuration found")
    configuration = json.loads(raw_configuration)
    # Current goals are deliberately evaluated against historical activity. Their
    # original creation time must not suppress evaluation of the replay period.
    original_goal_start = None
    if isinstance(seed.get("target.current"), bytes):
        goal = json.loads(seed["target.current"])
        original_goal_start = goal.get("startedAt")
        goal["startedAt"] = windows[0]["startTs"] - 978307200  # Swift Date reference epoch
        seed["target.current"] = json.dumps(goal, ensure_ascii=False).encode()
    seed.update({"didOnboard": True, "isRecording": False, "showDockIcon": True,
                 "target.alertsEnabled": False})
    output.mkdir(parents=True, mode=0o700)
    database = output / "chunks.sqlite"
    uri = (source / "chunks.sqlite").as_uri() + "?mode=ro"
    with sqlite3.connect(uri, uri=True) as origin, sqlite3.connect(database) as destination:
        origin.backup(destination)
    source_hash = hashlib.sha256(database.read_bytes()).hexdigest()
    connection = sqlite3.connect(database)
    connection.row_factory = sqlite3.Row
    clauses = " OR ".join("(captured_at >= ? AND captured_at < ?)" for _ in windows)
    parameters = [value for window in windows for value in (window["startTs"], window["endTs"])]
    rows = connection.execute(
        f"SELECT * FROM screenshots WHERE is_deleted=0 AND ({clauses}) ORDER BY captured_at,id",
        parameters).fetchall()
    if not rows:
        raise ValueError("The chosen windows contain no active saved frames")
    # Copy all selected media before deleting anything from the snapshot. Refuse
    # media outside production, missing files, or a changing active segment.
    media = output / "recordings"
    media.mkdir(mode=0o700)
    copies = {}
    for row in rows:
        original = Path(row["file_path"]).resolve()
        if original in copies:
            continue
        if source not in original.parents or not original.is_file():
            raise ValueError(f"Selected recording is missing or outside source data: {original}")
        stamp = original.stat()
        relative = original.relative_to(source)
        target = media / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(original, target)
        after = original.stat()
        if (stamp.st_size, stamp.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
            raise ValueError(f"Recording is still changing; choose an earlier end time: {original}")
        copies[original] = (target, hashlib.sha256(target.read_bytes()).hexdigest())
    source_batches = []
    if connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='analysis_batches'").fetchone():
        source_batches = [dict(row) for row in connection.execute(
            "SELECT id,batch_start_ts,batch_end_ts,status FROM analysis_batches "
            "WHERE " + " OR ".join("(batch_start_ts < ? AND batch_end_ts >= ?)" for _ in windows),
            [value for window in windows for value in (window["endTs"], window["startTs"])])]
    connection.execute("PRAGMA foreign_keys=OFF")
    tables = [row[0] for row in connection.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")]
    for table in tables:
        if table not in {"screenshots", "grdb_migrations"}:
            escaped = table.replace('"', '""')
            connection.execute(f'DELETE FROM "{escaped}"')
    connection.execute("CREATE TEMP TABLE replay_selected_ids (id INTEGER PRIMARY KEY)")
    connection.executemany("INSERT INTO replay_selected_ids VALUES (?)", [(row["id"],) for row in rows])
    connection.execute("DELETE FROM screenshots WHERE id NOT IN (SELECT id FROM replay_selected_ids)")
    for original, (target, _) in copies.items():
        connection.execute("UPDATE screenshots SET file_path=? WHERE file_path=?", (str(target), str(original)))
        # Paths normally are already canonical, but symlink spellings must be rewritten too.
        for spelling in {row["file_path"] for row in rows if Path(row["file_path"]).resolve() == original}:
            connection.execute("UPDATE screenshots SET file_path=? WHERE file_path=?", (str(target), spelling))
    if id_namespace:
        generated_tables = [name for name, sql in connection.execute(
            "SELECT name,sql FROM sqlite_master WHERE type='table' AND name!='screenshots'")
            if sql and "AUTOINCREMENT" in sql.upper()]
        for table in generated_tables:
            # Empty tables may have no sqlite_sequence row yet. All generated
            # rows were pruned, so reserve an exact, independent ID range.
            connection.execute("DELETE FROM sqlite_sequence WHERE name=?", (table,))
            connection.execute("INSERT INTO sqlite_sequence(name,seq) VALUES (?,?)",
                               (table, id_namespace * 1_000_000))
    connection.commit()
    connection.execute("VACUUM")
    integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
    if integrity != "ok":
        raise ValueError(f"Snapshot integrity check failed: {integrity}")
    connection.close()
    os.chmod(database, 0o600)
    manifest = {
        "version": 1, "createdAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "sourceDatabaseSHA256": source_hash,
        "replayStartTs": windows[0]["startTs"], "windows": windows,
        "captureContinuityMode": "timestamp-and-frame-index",
        "captureContinuityLimitation": "Saved frames are fed as a virtual recording session; "
            "timestamp gaps, cadence and frame-index discontinuities are preserved. Historical "
            "sub-cadence recording stops were not persisted and cannot be reconstructed.",
        "goalPolicy": "Evaluate current configured goals against historical activity in the isolated replay only.",
        "originalGoalStartedAt": original_goal_start,
        "idNamespace": id_namespace,
        "frameCount": len(rows),
        "redactedFrameCount": sum(row["is_privacy_redacted"] for row in rows),
        "sourceBatches": source_batches,
        "media": [{"path": str(target.relative_to(output)), "sha256": digest, "bytes": target.stat().st_size}
                  for target, digest in copies.values()],
    }
    for window in windows:
        selected = [row for row in rows if window["startTs"] <= row["captured_at"] < window["endTs"]]
        window["frameCount"] = len(selected)
        window["redactedFrameCount"] = sum(row["is_privacy_redacted"] for row in selected)
    (output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    with (output / "replay-preferences.plist").open("wb") as handle:
        plistlib.dump(seed, handle)
    for path in (output / "manifest.json", output / "replay-preferences.plist"):
        path.chmod(0o600)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-data", type=Path,
                        default=Path.home() / "Library/Application Support/TargetFlow")
    parser.add_argument("--preferences", type=Path,
                        default=Path.home() / "Library/Preferences/local.targetflow.app.plist")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--window", type=parse_window, action="append", required=True)
    parser.add_argument("--id-namespace", type=int, default=0,
                        help="Reserve disjoint generated IDs for merging independent replay windows (0–1000)")
    args = parser.parse_args()
    try:
        manifest = prepare(args.source_data, args.output, args.preferences, args.window, args.id_namespace)
    except (ValueError, OSError, sqlite3.Error) as error:
        print(f"Replay snapshot failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"directory": str(args.output.resolve()), "frameCount": manifest["frameCount"],
                      "redactedFrameCount": manifest["redactedFrameCount"], "windows": manifest["windows"]},
                     ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
