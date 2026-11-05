"""Safety checks for the replay snapshot boundary; no macOS services required."""
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import sqlite3
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("snapshot", Path(__file__).with_name("prepare-recording-replay.py"))
snapshot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(snapshot)
relocation_spec = importlib.util.spec_from_file_location("relocation", Path(__file__).with_name("relocate-recording-replay.py"))
relocation = importlib.util.module_from_spec(relocation_spec)
relocation_spec.loader.exec_module(relocation)


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "production"
        self.source.mkdir()
        self.media = self.source / "segment.mp4"
        self.media.write_bytes(b"saved recording bytes")
        self.database = self.source / "chunks.sqlite"
        with sqlite3.connect(self.database) as connection:
            connection.executescript("""
                CREATE TABLE screenshots(id INTEGER PRIMARY KEY,file_path TEXT,frame_index INTEGER,
                    captured_at INTEGER,is_deleted INTEGER,is_privacy_redacted INTEGER);
                CREATE TABLE analysis_batches(id INTEGER PRIMARY KEY AUTOINCREMENT,batch_start_ts INTEGER,batch_end_ts INTEGER,status TEXT);
                CREATE TABLE timeline_cards(id INTEGER PRIMARY KEY AUTOINCREMENT,title TEXT,video_summary_url TEXT);
                CREATE TABLE generated_never_used(id INTEGER PRIMARY KEY AUTOINCREMENT,payload TEXT);
                INSERT INTO timeline_cards(id,title) VALUES(1,'private old output');
                INSERT INTO analysis_batches VALUES(1,1000,1300,'analyzed');
            """)
            connection.executemany("INSERT INTO screenshots VALUES(?,?,?,?,?,?)", [
                (1, str(self.media), 0, 1000, 0, 0),
                (2, str(self.media), 1, 1020, 0, 1),
                (3, str(self.media), 2, 2000, 0, 0)])
        self.preferences = self.root / "preferences.plist"
        self.preferences.write_bytes(plistlib.dumps({
            "aiConfiguration.v1": json.dumps({"version": 1}).encode(),
            "target.current": json.dumps({"startedAt": 1234, "text": "current goal"}).encode(),
            "screenshotIntervalSeconds": 20, "someAccountToken": "never copy this"}))
        self.window = {"label": "fixture", "startTs": 1000, "endTs": 1100}
        self.original_database = self.database.read_bytes()
        self.original_preferences = self.preferences.read_bytes()

    def test_copies_real_media_prunes_outputs_and_never_changes_source(self):
        output = self.root / "preview"
        manifest = snapshot.prepare(self.source, output, self.preferences, [self.window])
        self.assertEqual((manifest["frameCount"], manifest["redactedFrameCount"]), (2, 1))
        with sqlite3.connect(output / "chunks.sqlite") as connection:
            rows = connection.execute("SELECT id,file_path,frame_index,captured_at,is_privacy_redacted FROM screenshots ORDER BY id").fetchall()
            self.assertEqual([(r[0], r[2], r[3], r[4]) for r in rows], [(1, 0, 1000, 0), (2, 1, 1020, 1)])
            self.assertTrue(all(Path(r[1]).is_relative_to(output.resolve()) for r in rows))
            self.assertEqual(Path(rows[0][1]).read_bytes(), self.media.read_bytes())
            self.assertEqual(connection.execute("SELECT count(*) FROM timeline_cards").fetchone()[0], 0)
            self.assertEqual(connection.execute("SELECT count(*) FROM analysis_batches").fetchone()[0], 0)
        seed = plistlib.loads((output / "replay-preferences.plist").read_bytes())
        self.assertNotIn("someAccountToken", seed)
        self.assertEqual(json.loads(seed["target.current"])["startedAt"], 1000 - 978307200)
        self.assertFalse(seed["target.alertsEnabled"])
        self.assertEqual(self.database.read_bytes(), self.original_database)
        self.assertEqual(self.preferences.read_bytes(), self.original_preferences)

    def test_rejects_production_overlap_and_existing_preview(self):
        alias = self.root / "alias"
        alias.symlink_to(self.source, target_is_directory=True)
        for output in [self.source, self.source / "child", self.root, alias]:
            with self.assertRaises(ValueError):
                snapshot.prepare(self.source, output, self.preferences, [self.window])
        existing = self.root / "existing"
        existing.mkdir()
        sentinel = existing / "sentinel"
        sentinel.write_text("keep")
        with self.assertRaises(ValueError):
            snapshot.prepare(self.source, existing, self.preferences, [self.window])
        self.assertEqual(sentinel.read_text(), "keep")
        self.assertEqual(self.database.read_bytes(), self.original_database)

    def test_missing_media_fails_without_editing_source(self):
        self.media.unlink()
        with self.assertRaises(ValueError):
            snapshot.prepare(self.source, self.root / "missing", self.preferences, [self.window])
        self.assertEqual(self.database.read_bytes(), self.original_database)

    def test_generated_id_namespace_includes_previously_empty_tables(self):
        output = self.root / "namespaced"
        snapshot.prepare(self.source, output, self.preferences, [self.window], id_namespace=2)
        with sqlite3.connect(output / "chunks.sqlite") as connection:
            connection.execute("INSERT INTO timeline_cards(title) VALUES ('real result')")
            self.assertEqual(connection.execute("SELECT id FROM timeline_cards").fetchone()[0], 2_000_001)
            connection.execute("INSERT INTO generated_never_used(payload) VALUES ('new output')")
            self.assertEqual(connection.execute("SELECT id FROM generated_never_used").fetchone()[0], 2_000_001)
        self.assertEqual(self.database.read_bytes(), self.original_database)

    def test_saved_snapshot_reuses_recordings_with_current_preferences_and_fresh_outputs(self):
        baseline = self.root / "baseline"
        rerun = self.root / "rerun"
        snapshot.prepare(self.source, baseline, self.preferences, [self.window])
        with sqlite3.connect(baseline / "chunks.sqlite") as db:
            db.execute("INSERT INTO timeline_cards(title) VALUES ('previous generated output')")
        original_baseline = (baseline / "chunks.sqlite").read_bytes()
        preferences = plistlib.loads(self.preferences.read_bytes())
        preferences["aiConfiguration.v1"] = json.dumps({"version": 1, "model": "current choice"}).encode()
        self.preferences.write_bytes(plistlib.dumps(preferences))
        manifest = snapshot.prepare(baseline, rerun, self.preferences, [self.window])
        self.assertEqual((manifest["frameCount"], manifest["redactedFrameCount"]), (2, 1))
        with sqlite3.connect(rerun / "chunks.sqlite") as db:
            self.assertEqual(db.execute("SELECT count(*) FROM timeline_cards").fetchone()[0], 0)
            for path, in db.execute("SELECT file_path FROM screenshots"):
                self.assertTrue(Path(path).is_relative_to(rerun.resolve()))
                self.assertEqual(Path(path).read_bytes(), self.media.read_bytes())
        seed = plistlib.loads((rerun / "replay-preferences.plist").read_bytes())
        self.assertEqual(json.loads(seed["aiConfiguration.v1"])["model"], "current choice")
        self.assertEqual((baseline / "chunks.sqlite").read_bytes(), original_baseline)
        self.assertEqual(json.loads(plistlib.loads((baseline / "replay-preferences.plist").read_bytes())["aiConfiguration.v1"]), {"version": 1})

    def test_relocated_copy_preserves_outputs_and_verifies_media(self):
        original = self.root / "preview"
        copied = self.root / "copied"
        snapshot.prepare(self.source, original, self.preferences, [self.window])
        report_bytes = b'{"actualModelOutput":"retain byte for byte"}'
        (original / "report.json").write_bytes(report_bytes)
        shutil.copytree(original, copied)
        self.assertEqual(relocation.relocate(copied), 1)
        with sqlite3.connect(copied / "chunks.sqlite") as connection:
            paths = [Path(row[0]) for row in connection.execute("SELECT file_path FROM screenshots")]
            self.assertTrue(all(copied.resolve() in path.parents for path in paths))
        with sqlite3.connect(original / "chunks.sqlite") as connection:
            self.assertTrue(all(original.resolve() in Path(row[0]).parents
                                for row in connection.execute("SELECT file_path FROM screenshots")))
        self.assertEqual((copied / "report.json").read_bytes(), report_bytes)
        paths[0].write_bytes(b"changed copied media")
        before = (copied / "chunks.sqlite").read_bytes()
        with self.assertRaises(ValueError):
            relocation.relocate(copied)
        self.assertEqual((copied / "chunks.sqlite").read_bytes(), before)

    def test_window_requires_timezone_and_order(self):
        for text in ["2026-10-30T14:20,2026-10-30T15:20", "2026-10-30T15:20+08:00,2026-10-30T14:20+08:00"]:
            with self.assertRaises(Exception):
                snapshot.parse_window(text)
        window = snapshot.parse_window("2026-10-30T14:20+08:00,2026-10-30T15:20+08:00")
        self.assertEqual(window["endTs"] - window["startTs"], 3600)


if __name__ == "__main__":
    unittest.main()
