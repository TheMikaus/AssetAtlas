"""Fill in the catalog's rig_family column in one pass.

Atlas works this out lazily: it reads a file when a filter needs the answer,
and writes what it found. That is right for an app -- reading 27,652 FBX files
to open a window would not be -- but it leaves the column mostly empty, and
anything that asks "which characters are on the Polygon rig?" across the whole
library gets a thin answer. Both the rig filter in Atlas and the MCP server's
type=character depend on this column.

This fills it in, reading every FBX with the Atlas importer's --probe and
writing what it finds. Twelve workers, one archive handle per zip, batched
writes. It took about a minute over 27,652 files here.

  Close Atlas first. This writes to the database Atlas owns, and SQLite will
  not let two processes write at once.

  python -I work/atlas_mcp/backfill_rigs.py [--limit N] [--dry-run]
"""

import argparse
import json
import os
import sqlite3
import subprocess
import sys
import threading
import zipfile
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import atlas_mcp  # noqa: E402  - path set above so this runs from anywhere

WORKERS = 12
BATCH = 500


def probe(path, data):
    completed = subprocess.run(
        [atlas_mcp.IMPORTER_PATH, "--stdin", "--probe", os.path.basename(path)],
        input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=300)
    if completed.returncode != 0:
        return None
    try:
        return json.loads(completed.stdout.decode("utf-8", "replace"))
    except ValueError:
        return None


class Archives:
    """One open handle and one lock per archive.

    A single lock shared across archives deadlocks the moment a worker holding
    it asks for a handle that another worker is opening -- which is how the
    first version of this stopped dead after four hundred files.
    """

    def __init__(self):
        self._handles = {}
        self._locks = {}
        self._guard = threading.Lock()

    def read(self, container, entry):
        with self._guard:
            lock = self._locks.setdefault(container, threading.Lock())
        with lock:
            handle = self._handles.get(container)
            if handle is None:
                handle = zipfile.ZipFile(container)
                self._handles[container] = handle
            return handle.read(entry)

    def close(self):
        for handle in self._handles.values():
            try:
                handle.close()
            except OSError:
                pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--limit", type=int, default=0,
                        help="Stop after this many files; 0 means all of them.")
    parser.add_argument("--dry-run", action="store_true",
                        help="Read everything, write nothing.")
    parser.add_argument("--all", action="store_true",
                        help="Re-read files that already have a rig recorded.")
    options = parser.parse_args()

    if not atlas_mcp.IMPORTER_PATH or not os.path.exists(atlas_mcp.IMPORTER_PATH):
        print("The Atlas FBX reader was not found. Set ATLAS_MCP_IMPORTER.",
              file=sys.stderr)
        return 2
    if not atlas_mcp.DB_PATH or not os.path.exists(atlas_mcp.DB_PATH):
        print("No catalog at %s." % atlas_mcp.DB_PATH, file=sys.stderr)
        return 2

    connection = sqlite3.connect(atlas_mcp.DB_PATH)
    where = "ext = 'fbx'" if options.all else "ext = 'fbx' AND rig_family IS NULL"
    sql = "SELECT id, path FROM catalog_assets WHERE %s" % where
    if options.limit:
        sql += " LIMIT %d" % options.limit
    todo = connection.execute(sql).fetchall()
    print("%d files to read." % len(todo))
    if not todo:
        connection.close()
        return 0

    archives = Archives()
    done = [0]
    progress_lock = threading.Lock()

    def classify(item):
        asset_id, path = item
        try:
            parsed = atlas_mcp.parse_zip_path(path)
            if parsed is None:
                with open(path, "rb") as handle:
                    data = handle.read()
            else:
                data = archives.read(*parsed)
            result = probe(path, data)
        except Exception:  # noqa: BLE001 - one bad file must not stop the sweep
            result = None
        with progress_lock:
            done[0] += 1
            if done[0] % 500 == 0:
                print("  %d / %d" % (done[0], len(todo)), flush=True)
        if result is None:
            return asset_id, None, None
        kind = "animation" if result.get("kind") == "animation" else "mesh"
        rig = atlas_mcp.rig_family_from_markers(result.get("rigMarkers"))
        return asset_id, kind, rig

    rows = []
    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        for asset_id, kind, rig in pool.map(classify, todo):
            if rig is None:
                continue
            rows.append((kind, rig, asset_id))
    archives.close()

    counts = {}
    for _, rig, _ in rows:
        counts[rig] = counts.get(rig, 0) + 1
    print("read %d of %d: %s"
          % (len(rows), len(todo),
             ", ".join("%s %d" % pair for pair in sorted(counts.items()))))

    if options.dry_run:
        print("--dry-run: nothing written.")
        connection.close()
        return 0

    for start in range(0, len(rows), BATCH):
        connection.executemany(
            "UPDATE catalog_assets SET model_kind = ?, rig_family = ? WHERE id = ?",
            rows[start:start + BATCH])
        connection.commit()
    connection.close()
    print("written.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
