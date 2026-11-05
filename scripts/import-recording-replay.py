#!/usr/bin/env python3
"""Import finalized isolated replay outputs without running models or replacing rows."""
import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import sqlite3
import sys
import tempfile


EXCLUDED = {"screenshots", "chunks", "day_goals", "day_goal_categories",
            "grdb_migrations", "replay_imports"}


def independent(a, b):
    return a != Path("/") and a != b and a not in b.parents and b not in a.parents


def inside(root, path):
    path = path.resolve()
    if root not in path.parents or not path.is_file():
        raise ValueError(f"File missing or outside replay root: {path}")
    return path


def manifest(root):
    data = inside(root, root / "manifest.json").read_bytes()
    value = json.loads(data)
    windows = value.get("windows", [])
    if (value.get("version") != 1 or not windows
            or not isinstance(value.get("replayStartTs"), int)):
        raise ValueError("Replay requires a valid version 1 manifest")
    for w in windows:
        if (not isinstance(w.get("startTs"), int) or not isinstance(w.get("endTs"), int)
                or not 0 < w["startTs"] < w["endTs"]):
            raise ValueError("Invalid manifest window")
    windows = sorted(windows, key=lambda w: w["startTs"])
    if (not 0 < value["replayStartTs"] <= windows[0]["startTs"]
            or any(a["endTs"] > b["startTs"] for a, b in zip(windows, windows[1:]))):
        raise ValueError("Invalid or overlapping manifest windows")
    return value, hashlib.sha256(data).hexdigest()


def quote(name):
    return '"' + name.replace('"', '""') + '"'


def schema(db):
    return {name: (db.execute(f"PRAGMA table_xinfo({quote(name)})").fetchall(),
                   db.execute(f"PRAGMA foreign_key_list({quote(name)})").fetchall())
            for (name,) in db.execute("SELECT name FROM sqlite_master WHERE type='table'")
            if not name.startswith("sqlite_") and name != "replay_imports"}


def in_window(start, end, windows, tolerance=0):
    return (start is not None and end is not None and start <= end
            and any(w["startTs"] - tolerance <= start < w["endTs"]
                    and end <= w["endTs"] + tolerance for w in windows))


def validate_rows(src, dest, tables, windows, source_root, destination_root, report):
    if src.execute("PRAGMA foreign_key_check").fetchone():
        raise ValueError("Source has broken foreign key references")
    batches = {r[0]: r for r in src.execute(
        "SELECT id,batch_start_ts,batch_end_ts,status FROM analysis_batches")}
    recorded_failures = {item.get("batchID") for item in report.get("batches", [])
                         if item.get("status") == "failed" and item.get("error")}
    for batch_id, start, end, status in batches.values():
        terminal = status in {"analyzed", "completed"} or (status == "failed" and batch_id in recorded_failures)
        if not in_window(start, end, windows) or not terminal:
            raise ValueError(f"Source batch {batch_id} is unfinished or outside source windows")
        if not src.execute("SELECT 1 FROM batch_screenshots WHERE batch_id=?", (batch_id,)).fetchone():
            raise ValueError(f"Source batch {batch_id} has no screenshot evidence")
        if dest.execute("SELECT 1 FROM analysis_batches WHERE batch_start_ts < ? AND batch_end_ts > ?",
                        (end, start)).fetchone():
            raise ValueError("Source batch overlaps existing destination work")
    # Validate every source frame, including evidence referenced by pending cards.
    # File names differ across snapshots; compare actual segment bytes once per pair.
    media_pairs = set()
    for row in src.execute("SELECT id,captured_at,frame_index,is_privacy_redacted,is_deleted,file_path FROM screenshots"):
        frame_id, captured, index, private, deleted, path = row
        other = dest.execute("SELECT captured_at,frame_index,is_privacy_redacted,is_deleted,file_path "
                             "FROM screenshots WHERE id=?", (frame_id,)).fetchone()
        if (deleted != 0 or not in_window(captured, captured, windows)
                or other is None or tuple(other[:4]) != (captured, index, private, 0)):
            raise ValueError(f"Source frame {frame_id} does not match active destination frame")
        pair = (inside(source_root, Path(path)), inside(destination_root, Path(other[4])))
        if pair not in media_pairs:
            def digest(file):
                value = hashlib.sha256()
                with file.open("rb") as handle:
                    for block in iter(lambda: handle.read(1024 * 1024), b""):
                        value.update(block)
                return value.digest()
            if digest(pair[0]) != digest(pair[1]):
                raise ValueError(f"Media bytes differ for source frame {frame_id}")
            media_pairs.add(pair)
    for table in tables:
        columns = [r[1] for r in src.execute(f"PRAGMA table_info({quote(table)})")]
        for row in src.execute(f"SELECT * FROM {quote(table)}"):
            item = dict(zip(columns, row))
            if "batch_id" in item and item["batch_id"] is not None and item["batch_id"] not in batches:
                raise ValueError(f"Unrelated batch reference in {table}")
            if "start_ts" in item and "end_ts" in item:
                tolerance = 60 if table in {"timeline_cards", "pending_timeline_evidence"} else 0
                if not in_window(item["start_ts"], item["end_ts"], windows, tolerance):
                    raise ValueError(f"Output interval outside source windows in {table}")
            if item.get("video_summary_url") is not None:
                raise ValueError("Timelapse video_summary_url import is unsupported; use a worker without generated media")
    # These are raw media/configuration, never generated outputs.
    for table in {"chunks", "day_goals", "day_goal_categories"} & set(schema(src)):
        if src.execute(f"SELECT 1 FROM {quote(table)} LIMIT 1").fetchone():
            raise ValueError(f"Source {table} is not empty; prepare a pruned worker snapshot")


def write_audit(root, digest, text):
    path = root / f"imported-replay-{digest}.json"
    if path.exists() or path.is_symlink():
        if path.is_symlink() or path.read_text() != text:
            raise ValueError(f"Import committed but audit sidecar conflicts: {path}")
        return
    with path.open("x", encoding="utf-8") as handle:
        handle.write(text)
    path.chmod(0o600)


def import_replay(destination, source):
    destination, source = Path(destination).resolve(), Path(source).resolve()
    production = (Path.home() / "Library/Application Support/TargetFlow").resolve()
    if not all(independent(root, production) for root in (destination, source)) or not independent(destination, source):
        raise ValueError("Replay roots must be separate from production and each other, including ancestors")
    destination_manifest, _ = manifest(destination)
    source_manifest, digest = manifest(source)
    windows = source_manifest["windows"]
    if not all(any(d["startTs"] <= w["startTs"] and w["endTs"] <= d["endTs"]
                   for d in destination_manifest["windows"]) for w in windows):
        raise ValueError("Destination windows do not contain all source windows")
    report_text = inside(source, source / "report.json").read_text()
    report = json.loads(report_text)
    if not report.get("finishedAt") or report.get("manifestSHA256") != digest:
        raise ValueError("Source report must be finalized and match the actual manifest SHA256")
    source_db = inside(source, source / "chunks.sqlite")
    destination_db = inside(destination, destination / "chunks.sqlite")
    if source_db.samefile(destination_db):
        raise ValueError("Source and destination databases must be separate files")
    # SQLite backup includes committed WAL pages without copying a live database file.
    with tempfile.TemporaryDirectory(prefix="targetflow-import-") as temporary:
        with sqlite3.connect(source_db.as_uri() + "?mode=ro", uri=True) as origin, \
                sqlite3.connect(Path(temporary) / "snapshot.sqlite") as src:
            origin.backup(src)
            with sqlite3.connect(destination_db.as_uri() + "?mode=rw", uri=True, timeout=30) as dest:
                dest.execute("PRAGMA busy_timeout=30000")
                dest.execute("PRAGMA foreign_keys=ON")
                dest.execute("BEGIN IMMEDIATE")
                if schema(src) != schema(dest):
                    raise ValueError("Source/destination table or column schemas differ")
                # The native schema only has screenshot update/delete triggers. Any
                # output trigger could silently change preserved logs or existing rows.
                for db in (src, dest):
                    if db.execute("SELECT 1 FROM sqlite_master WHERE type='trigger' AND tbl_name != 'screenshots'").fetchone():
                        raise ValueError("Unsupported output-table trigger")
                dest.execute("CREATE TABLE IF NOT EXISTS replay_imports (source_manifest_sha TEXT PRIMARY KEY, "
                             "report_json TEXT NOT NULL, imported_at TEXT NOT NULL, audit_json TEXT NOT NULL)")
                receipt = dest.execute("SELECT audit_json FROM replay_imports WHERE source_manifest_sha=?", (digest,)).fetchone()
                if receipt:
                    audit_text = receipt[0]
                    imported = False
                else:
                    tables = sorted(set(schema(src)) - EXCLUDED)
                    validate_rows(src, dest, tables, windows, source, destination, report)
                    dest.execute("PRAGMA defer_foreign_keys=ON")
                    counts = {}
                    for table in tables:
                        columns = [r[1] for r in src.execute(f"PRAGMA table_info({quote(table)})")]
                        rows = src.execute(f"SELECT * FROM {quote(table)}").fetchall()
                        if not rows:
                            continue
                        sql = (f"INSERT INTO {quote(table)} ({','.join(map(quote, columns))}) "
                               f"VALUES ({','.join('?' for _ in columns)})")
                        dest.executemany(sql, rows)
                        counts[table] = len(rows)
                    audit_text = json.dumps({"sourceManifestSHA256": digest, "source": str(source),
                                             "importedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
                                             "rowCounts": counts, "sourceReport": report},
                                            ensure_ascii=False, indent=2) + "\n"
                    dest.execute("INSERT INTO replay_imports VALUES (?,?,?,?)",
                                 (digest, report_text, json.loads(audit_text)["importedAt"], audit_text))
                    imported = True
                dest.commit()
        # A retry repairs a missing sidecar using the committed receipt.
        write_audit(destination, digest, audit_text)
    return {"imported": imported, "sourceManifestSHA256": digest,
            "auditPath": str(destination / f"imported-replay-{digest}.json")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(import_replay(args.destination, args.source), indent=2))
    except (ValueError, OSError, sqlite3.Error, KeyError, TypeError) as error:
        print(f"Replay import failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
