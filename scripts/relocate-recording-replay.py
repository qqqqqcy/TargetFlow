#!/usr/bin/env python3
"""Retarget a copied, self-contained replay for viewing on another Mac. No AI calls."""
import argparse
import hashlib
import json
from pathlib import Path
import sqlite3


def relocate(directory):
    directory = directory.resolve()
    production = (Path.home() / "Library/Application Support/TargetFlow").resolve()
    if (directory == Path("/") or directory == production or production in directory.parents
            or directory in production.parents):
        raise ValueError("Only a separate copied replay directory may be relocated")
    manifest = json.loads((directory / "manifest.json").read_text())
    if manifest.get("version") != 1 or not manifest.get("media"):
        raise ValueError("A version 1 replay manifest with copied media is required")
    media = {}
    for entry in manifest["media"]:
        relative = Path(entry["path"])
        target = (directory / relative).resolve()
        if relative.is_absolute() or directory not in target.parents or not target.is_file():
            raise ValueError(f"Copied media is missing or escapes the replay directory: {relative}")
        if hashlib.sha256(target.read_bytes()).hexdigest() != entry["sha256"]:
            raise ValueError(f"Copied media checksum differs: {relative}")
        media[relative.as_posix()] = target
    database = directory / "chunks.sqlite"
    if directory not in database.resolve().parents:
        raise ValueError("Replay database points outside the copied directory")
    with sqlite3.connect(database.as_uri() + "?mode=rw", uri=True) as connection:
        mappings = {}
        for (old,) in connection.execute("SELECT DISTINCT file_path FROM screenshots"):
            matches = [target for relative, target in media.items() if old.endswith("/" + relative)]
            if len(matches) != 1:
                raise ValueError(f"Screenshot does not reference a manifest media file: {old}")
            mappings[old] = str(matches[0])
        # Replays currently use raw frame playback, with no generated summary movies.
        if connection.execute("SELECT count(*) FROM timeline_cards WHERE video_summary_url IS NOT NULL").fetchone()[0]:
            raise ValueError("Replay contains generated summary movies; copy and retarget those before viewing")
        for old, new in mappings.items():
            connection.execute("UPDATE screenshots SET file_path=? WHERE file_path=?", (new, old))
        if connection.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise ValueError("Copied replay database failed its integrity check")
    return len(mappings)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    count = relocate(args.directory)
    print(f"Retargeted {count} copied media paths. Model outputs and report are unchanged.")


if __name__ == "__main__":
    main()
