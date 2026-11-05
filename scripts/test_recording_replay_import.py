"""Focused replay-import safety tests using the native StorageManager schema."""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sqlite3
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("replay_import", Path(__file__).with_name("import-recording-replay.py"))
replay_import = importlib.util.module_from_spec(spec)
spec.loader.exec_module(replay_import)


class ImportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.destination = self.root / "main"
        self.source = self.root / "worker"
        swift = (Path(__file__).resolve().parents[1] /
                 "Dayflow/Dayflow/Core/Recording/StorageManager.swift").read_text()
        # Execute the actual three native CREATE TABLE blocks, including triggers.
        blocks = [s for s in re.findall(r'"""(.*?)"""', swift, re.S) if "CREATE TABLE" in s]
        self.assertEqual(len(blocks), 3)
        for root, windows in [(self.destination, [(1000, 1100), (2000, 2100)]),
                              (self.source, [(2000, 2100)])]:
            root.mkdir()
            media = root / "different-media-name.mp4"
            media.write_bytes(b"identical saved recording segment")
            value = {"version": 1, "replayStartTs": windows[0][0],
                     "windows": [{"startTs": a, "endTs": b} for a, b in windows]}
            (root / "manifest.json").write_text(json.dumps(value))
            with sqlite3.connect(root / "chunks.sqlite") as db:
                for block in blocks:
                    db.executescript(block)
                db.execute("ALTER TABLE llm_calls ADD COLUMN usage_receipt TEXT")
                db.execute("ALTER TABLE timeline_cards ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0")
                db.execute("INSERT INTO screenshots(id,captured_at,file_path,frame_index,is_privacy_redacted) "
                           "VALUES(20,2000,?,7,1)", (str(media),))
                if root == self.destination:
                    db.execute("INSERT INTO screenshots(id,captured_at,file_path,frame_index) VALUES(10,1000,?,0)", (str(media),))
                    db.execute("INSERT INTO analysis_batches(id,batch_start_ts,batch_end_ts,status) VALUES(1,1000,1080,'analyzed')")
                    db.execute("INSERT INTO day_goals VALUES('2026-10-30',60,30,0,1,1)")
        with sqlite3.connect(self.source / "chunks.sqlite") as db:
            db.executescript("""
                INSERT INTO analysis_batches(id,batch_start_ts,batch_end_ts,status,detailed_transcription)
                  VALUES(1000001,2000,2080,'analyzed','real generated text');
                INSERT INTO batch_screenshots VALUES(1000001,20);
                INSERT INTO timeline_cards(id,batch_id,start,end,start_ts,end_ts,day,title,summary,category)
                  VALUES(1000001,1000001,'00:33','00:35',1980,2100,'1970-01-01','真实标题','verbatim summary','Work');
                INSERT INTO target_assessments VALUES(1000001,'{"cardID":1000001,"reason":"真实评估"}');
                INSERT INTO observations(id,batch_id,start_ts,end_ts,observation)
                  VALUES(1000001,1000001,2000,2080,'real observation');
                INSERT INTO pending_timeline_evidence VALUES(1000001,1000001,2000,2080,'{"id":1000001}',20,20);
                INSERT INTO pending_timeline_sources VALUES(1000001,20);
                INSERT INTO llm_calls(id,batch_id,call_group_id,provider,operation,status,request_body,response_body,usage_receipt)
                  VALUES(1000001,1000001,'original-call-id','real','timeline','success','  {"raw":"请求"}  ',
                         ' original response\nwith whitespace ', '{"tokens":123,"cost":0.04}');
            """)
        self.digest = hashlib.sha256((self.source / "manifest.json").read_bytes()).hexdigest()
        self.report = json.dumps({"version": 1, "finishedAt": 1234, "manifestSHA256": self.digest,
                                  "batches": [{"batchID": 1000001}], "models": ["real model"]}, indent=2)
        (self.source / "report.json").write_text(self.report)
        (self.destination / "report.json").write_text('running coordinator report: do not touch')

    def run_import(self):
        return replay_import.import_replay(self.destination, self.source)

    def rows(self, root, table):
        with sqlite3.connect(root / "chunks.sqlite") as db:
            return db.execute(f'SELECT * FROM "{table}" ORDER BY 1').fetchall()

    def test_preserves_outputs_refs_raw_data_logs_and_source_and_is_idempotent(self):
        before = {p: p.read_bytes() for p in self.source.iterdir() if p.is_file()}
        raw = self.rows(self.destination, "screenshots")
        goals = self.rows(self.destination, "day_goals")
        selection_report = (self.destination / "report.json").read_bytes()
        result = self.run_import()
        self.assertTrue(result["imported"])
        for table in ["batch_screenshots", "timeline_cards", "target_assessments", "observations",
                      "pending_timeline_evidence", "pending_timeline_sources", "llm_calls"]:
            self.assertEqual(self.rows(self.source, table), self.rows(self.destination, table), table)
        self.assertEqual(self.rows(self.destination, "screenshots"), raw)
        self.assertEqual(self.rows(self.destination, "day_goals"), goals)
        self.assertEqual((self.destination / "report.json").read_bytes(), selection_report)
        self.assertEqual({p: p.read_bytes() for p in before}, before)
        receipt = self.rows(self.destination, "replay_imports")[0]
        self.assertEqual(receipt[1], self.report)
        audit = Path(result["auditPath"])
        self.assertEqual(json.loads(audit.read_text())["rowCounts"]["llm_calls"], 1)
        audit.unlink()  # Retry repairs sidecars after a crash following DB commit.
        self.assertFalse(self.run_import()["imported"])
        self.assertTrue(audit.exists())
        self.assertEqual(len(self.rows(self.destination, "llm_calls")), 1)
        with sqlite3.connect(self.destination / "chunks.sqlite") as db:
            self.assertFalse(db.execute("PRAGMA foreign_key_check").fetchall())
            self.assertEqual(db.execute("SELECT seq FROM sqlite_sequence WHERE name='timeline_cards'").fetchone()[0], 1000001)

    def assert_rejected_without_changes(self, pattern):
        before = (self.destination / "chunks.sqlite").read_bytes()
        with self.assertRaisesRegex((ValueError, sqlite3.Error), pattern):
            self.run_import()
        self.assertEqual((self.destination / "chunks.sqlite").read_bytes(), before)
        self.assertFalse(list(self.destination.glob("imported-replay-*.json")))

    def test_audited_failed_batch_remains_failed_in_aggregate(self):
        with sqlite3.connect(self.source / "chunks.sqlite") as db:
            db.execute("UPDATE analysis_batches SET status='failed',reason='real evidence gap'")
        self.assert_rejected_without_changes("unfinished")
        report = json.loads(self.report)
        report["batches"][0].update(status="failed", error="real evidence gap")
        (self.source / "report.json").write_text(json.dumps(report))
        self.assertTrue(self.run_import()["imported"])
        with sqlite3.connect(self.destination / "chunks.sqlite") as db:
            self.assertEqual(db.execute("SELECT status,reason FROM analysis_batches WHERE id=1000001").fetchone(),
                             ("failed", "real evidence gap"))
        self.assertEqual(self.rows(self.destination, "llm_calls"), self.rows(self.source, "llm_calls"))

    def test_collision_rolls_back_every_row_and_receipt(self):
        with sqlite3.connect(self.destination / "chunks.sqlite") as db:
            db.execute("INSERT INTO llm_calls(id,provider,operation,status) VALUES(1000001,'main','other','success')")
        self.assert_rejected_without_changes("UNIQUE")
        self.assertEqual(len(self.rows(self.destination, "analysis_batches")), 1)

    def test_frame_identity_and_active_status_must_match(self):
        for column, value in [("captured_at", 2001), ("frame_index", 8), ("is_privacy_redacted", 0), ("is_deleted", 1)]:
            with self.subTest(column=column):
                with sqlite3.connect(self.destination / "chunks.sqlite") as db:
                    original = db.execute(f"SELECT {column} FROM screenshots WHERE id=20").fetchone()[0]
                    db.execute(f"UPDATE screenshots SET {column}=? WHERE id=20", (value,))
                self.assert_rejected_without_changes("frame 20")
                with sqlite3.connect(self.destination / "chunks.sqlite") as db:
                    db.execute(f"UPDATE screenshots SET {column}=? WHERE id=20", (original,))

    def test_media_mismatch_rejected(self):
        (self.source / "different-media-name.mp4").write_bytes(b"unrelated bytes")
        self.assert_rejected_without_changes("Media bytes differ")

    def test_report_digest_and_completion_required(self):
        for report in [{"finishedAt": 1, "manifestSHA256": "wrong"}, {"manifestSHA256": self.digest}]:
            (self.source / "report.json").write_text(json.dumps(report))
            self.assert_rejected_without_changes("finalized")

    def test_out_of_window_and_generated_media_rejected(self):
        with sqlite3.connect(self.source / "chunks.sqlite") as db:
            db.execute("UPDATE observations SET end_ts=9999")
        self.assert_rejected_without_changes("outside source windows")
        with sqlite3.connect(self.source / "chunks.sqlite") as db:
            db.execute("UPDATE observations SET end_ts=2080")
            db.execute("UPDATE timeline_cards SET video_summary_url='/external/timelapse.mp4'")
        self.assert_rejected_without_changes("video_summary_url")

    def test_missing_destination_frame_rejected(self):
        with sqlite3.connect(self.destination / "chunks.sqlite") as db:
            db.execute("DELETE FROM screenshots WHERE id=20")
        self.assert_rejected_without_changes("frame 20")

    def test_existing_destination_batch_overlap_rejected(self):
        with sqlite3.connect(self.destination / "chunks.sqlite") as db:
            db.execute("INSERT INTO analysis_batches(id,batch_start_ts,batch_end_ts,status) VALUES(2,2000,2080,'processing')")
        self.assert_rejected_without_changes("overlaps")

    def test_destination_must_contain_source_windows(self):
        path = self.destination / "manifest.json"
        value = json.loads(path.read_text())
        value["windows"] = value["windows"][:1]
        path.write_text(json.dumps(value))
        self.assert_rejected_without_changes("contain all source windows")

    def test_output_trigger_rejected(self):
        with sqlite3.connect(self.destination / "chunks.sqlite") as db:
            db.executescript("CREATE TRIGGER mutate_log AFTER INSERT ON llm_calls BEGIN "
                             "UPDATE llm_calls SET response_body='changed' WHERE id=NEW.id; END;")
        self.assert_rejected_without_changes("output-table trigger")

    def test_schema_mismatch_rejected(self):
        with sqlite3.connect(self.source / "chunks.sqlite") as db:
            db.execute("ALTER TABLE llm_calls ADD COLUMN unexpected TEXT")
        self.assert_rejected_without_changes("schemas differ")

    def test_unsafe_production_and_overlapping_roots_rejected(self):
        fake_home = self.root / "home"
        production = fake_home / "Library/Application Support/TargetFlow"
        production.mkdir(parents=True)
        alias = self.root / "production-alias"
        alias.symlink_to(production, target_is_directory=True)
        with mock.patch.object(replay_import.Path, "home", return_value=fake_home):
            for unsafe in [production, production.parent, production / "child", alias, self.source, self.root]:
                with self.subTest(unsafe=unsafe), self.assertRaisesRegex(ValueError, "separate"):
                    replay_import.import_replay(unsafe, self.source)
                if unsafe != self.source:
                    with self.assertRaisesRegex(ValueError, "separate"):
                        replay_import.import_replay(self.destination, unsafe)
            with self.assertRaisesRegex(ValueError, "separate"):
                replay_import.import_replay(self.destination, self.destination)

    def test_online_backup_reads_committed_wal_without_changing_source(self):
        with sqlite3.connect(self.source / "chunks.sqlite") as writer:
            writer.execute("PRAGMA journal_mode=WAL")
            writer.execute("UPDATE llm_calls SET response_body='committed WAL response'")
            writer.commit()
            before = (self.source / "chunks.sqlite").read_bytes()
            wal = (self.source / "chunks.sqlite-wal").read_bytes()
            self.run_import()
            self.assertEqual((self.source / "chunks.sqlite").read_bytes(), before)
            self.assertEqual((self.source / "chunks.sqlite-wal").read_bytes(), wal)
            with sqlite3.connect(self.destination / "chunks.sqlite") as db:
                self.assertEqual(db.execute("SELECT response_body FROM llm_calls").fetchone()[0], 'committed WAL response')


if __name__ == "__main__":
    unittest.main()
