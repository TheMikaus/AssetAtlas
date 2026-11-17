"""The visual tagging pass: render an asset, embed the render, store it.

What this costs, measured on this library rather than guessed. The render is
the whole job: 972 ms median walking one archive in order, 1,570 ms median
jumping between archives, against 9 ms to embed. Everything below follows
from that one number.

    32,296 distinct models x 972 ms = about 8.7 hours, once.

So this is an overnight job, not a progress bar to sit and watch, and three
things fall out of that:

  * It must be resumable, and is -- the queue is derived from the store, not
    kept anywhere. Whatever has no vector is what is left to do, so killing
    this at any moment and starting it again loses at most one batch.
  * It must be orderable, and is -- --folder and --pack take a slice, so the
    packs you are actually building with can be tagged in minutes instead of
    waiting behind 30,000 files you do not need yet.
  * It must leave the machine usable, and does -- the embedder gets two
    threads, this process drops its own priority, and --pace-ms puts a gap
    between renders. The default settings deliberately do not saturate.

Duplicates are collapsed before anything is rendered. Half this library is the
same file re-exported per engine version: 34,801 FBX rows are 18,948 distinct
files by name and size. Only one of each is rendered, which is also how
search_assets reports results, so nothing is lost and the pass is 45% shorter.

Atlas has to be running: the renderer being used is its own, over the loopback
bridge. That is deliberate -- a silhouette drawn by a second renderer would
not match what the app shows, and the whole point is that the picture being
embedded is the picture you looked at.

Run it with -P, for the reason in atlas_embed.py's docstring.
"""

import argparse
import base64
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))

# -P drops the script's own directory from sys.path along with the working
# directory, so the siblings below have to be found deliberately. Putting
# HERE back is not what -P was guarding against: HERE is this repository,
# whereas the thing worth excluding is whatever directory the renders and
# archives happen to live in.
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import atlas_mcp                                    # noqa: E402
import embedding_store                              # noqa: E402
from atlas_embed import DIMS, MODEL_ID              # noqa: E402

# Beside the catalog, like atlas_bridge.json: these are derived from it and a
# catalog rebuilt from scratch should leave them obviously stale rather than
# scattered somewhere unrelated.
VECTORS_NAME = "embeddings.f32"
INDEX_NAME = "embeddings_index.sqlite"

# What is worth looking at. Audio has nothing to see; .uasset is unreadable
# outside Unreal, so there is no geometry to draw.
RENDERABLE_EXTS = ("fbx", "obj")

# Renders are small -- 3.8 KB mean at 224 px -- so a batch costs nothing to
# hold. Eight matches the embedder's fastest measured rate.
DEFAULT_BATCH = 8

# 224 is the model's input size. Rendering larger would be thrown away by the
# resize, and rendering smaller would lose detail the model can use.
RENDER_SIZE = 224


def store_paths():
    catalog_dir = os.path.dirname(atlas_mcp.DB_PATH)
    return (os.path.join(catalog_dir, VECTORS_NAME),
            os.path.join(catalog_dir, INDEX_NAME))


def open_or_create_store():
    """The store, made on first use.

    Opening with expect_model_id is what stops a vector from one model being
    ranked against another's: the header carries the model and open() refuses
    a mismatch instead of returning numbers that mean nothing.
    """
    vectors_path, index_path = store_paths()
    if os.path.exists(vectors_path):
        return embedding_store.EmbeddingStore.open(
            vectors_path, index_path, expect_model_id=MODEL_ID)
    return embedding_store.EmbeddingStore.create(
        vectors_path, index_path, dims=DIMS, model_id=MODEL_ID)


def candidates(connection, folder=None, pack=None, ext=None):
    """One row per distinct renderable model, in archive order.

    Grouped by name and size because that is what makes two files the same
    file in this library, and ordered by path so consecutive renders hit the
    same archive -- worth 600 ms an asset over a random walk.
    """
    where = ["ignored = 0",
             "ext IN (%s)" % ", ".join(["?"] * len(RENDERABLE_EXTS))]
    params = list(RENDERABLE_EXTS)

    if ext:
        where.append("ext = ?")
        params.append(ext.lower().lstrip("."))
    if folder:
        where.append("lower(relative_path) LIKE ?")
        params.append("%" + folder.lower().replace("\\", "/") + "%")
    if pack:
        where.append("lower(path) LIKE ?")
        params.append("%" + pack.lower() + "%")

    rows = connection.execute(
        # referenced_by_model is selected although these are all models and
        # effective_type short-circuits before reading it: relying on the
        # order of those checks would make this break on a reordering
        # somewhere else entirely.
        "SELECT id, path, name, relative_path, model_kind, type, "
        "referenced_by_model, count(*) AS copies FROM catalog_assets WHERE %s "
        "GROUP BY lower(name), size ORDER BY path, relative_path"
        % " AND ".join(where), params).fetchall()

    # Animation clips hold curves and no geometry, and the renderer says so
    # rather than drawing anything: "has no geometry to draw: it is an
    # animation". Left in, all 801 of them would be rendered, fail, and be
    # retried on the next run for ever. The folder rule catches the ones
    # nothing has probed, which after a rescan is all of them.
    return [row for row in rows
            if atlas_mcp.effective_type(row) != "animation"]


class EmbedderProcess:
    """atlas_embed.py --serve, as a child process over two pipes.

    One child for the whole run: constructing the ONNX session costs about a
    second, so a process per batch would spend more time loading the model
    than using it.
    """

    def __init__(self, threads):
        self.process = subprocess.Popen(
            [sys.executable, "-P", os.path.join(HERE, "atlas_embed.py"),
             "--serve", "--threads", str(threads)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, cwd=HERE, text=True, bufsize=1)

    def ask(self, message):
        if self.process.poll() is not None:
            raise RuntimeError(
                "the embedder exited with code %d. Its stderr:\n%s"
                % (self.process.returncode, self.process.stderr.read()))
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError(
                "the embedder stopped answering. Its stderr:\n%s"
                % self.process.stderr.read())
        reply = json.loads(line)
        if not reply.get("ok"):
            raise RuntimeError("the embedder refused: %s"
                               % reply.get("error"))
        return reply

    def close(self):
        try:
            self.process.stdin.close()
        except (OSError, ValueError):
            pass
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()


def be_polite():
    """Drop this process below normal priority.

    The renders happen in Atlas and the matrix multiplies in the embedder, so
    this process is mostly waiting -- but it is the parent of the embedder,
    and on Windows a child inherits the parent's priority class.
    """
    try:
        if hasattr(os, "nice"):
            os.nice(10)
            return "nice +10"
        import ctypes
        from ctypes import wintypes
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        # Both signatures are declared, because they have to be: untyped,
        # GetCurrentProcess returns a C int and truncates the (HANDLE)-1
        # pseudo-handle, and SetPriorityClass then quietly refuses.
        kernel32.GetCurrentProcess.restype = wintypes.HANDLE
        kernel32.SetPriorityClass.argtypes = [wintypes.HANDLE,
                                              wintypes.DWORD]
        kernel32.SetPriorityClass.restype = wintypes.BOOL
        if kernel32.SetPriorityClass(
                kernel32.GetCurrentProcess(), 0x4000):  # BELOW_NORMAL
            return "below normal"
        return ("unchanged (SetPriorityClass failed, error %d)"
                % ctypes.get_last_error())
    except Exception as error:                      # noqa: BLE001
        return "unchanged (%s)" % error


def render(row):
    """One PNG from Atlas's own renderer, or None with the reason logged."""
    report = atlas_mcp.bridge_call("/render", {
        "path": row["path"], "size": RENDER_SIZE})
    encoded = report.get("png")
    if not encoded:
        raise RuntimeError("the bridge returned no image")
    return base64.b64decode(encoded)


def format_duration(seconds):
    if seconds < 90:
        return "%.0f s" % seconds
    if seconds < 5400:
        return "%.0f min" % (seconds / 60)
    return "%.1f h" % (seconds / 3600)


def run(arguments, out):
    # bridge_version probes the port rather than trusting atlas_bridge.json,
    # which outlives the process -- a descriptor three days stale was what
    # made that distinction worth having.
    version = atlas_mcp.bridge_version()
    if version is None:
        out.write("Atlas is not running, and its renderer is what draws "
                  "these. Start it, wait for the catalogue screen, and run "
                  "this again.\n")
        return 2
    out.write("Atlas          running, version %s\n" % version)

    priority = be_polite()
    store = open_or_create_store()
    try:
        with atlas_mcp.open_catalog() as connection:
            rows = candidates(connection, folder=arguments.folder,
                              pack=arguments.pack, ext=arguments.ext)
        by_id = {row["id"]: row for row in rows}
        todo_ids = store.missing([row["id"] for row in rows])
        todo = [by_id[asset_id] for asset_id in todo_ids]
        if arguments.limit:
            todo = todo[:arguments.limit]

        out.write(
            "%d distinct models selected, %d already embedded, %d to do\n"
            % (len(rows), len(rows) - len(todo_ids), len(todo)))
        out.write("store         %s (%d vectors)\n"
                  % (store.vectors_path, store.count))
        out.write("priority      %s, %d embedder threads, %d ms pace\n"
                  % (priority, arguments.threads, arguments.pace_ms))
        if not todo:
            out.write("Nothing to do.\n")
            return 0
        if arguments.dry_run:
            for row in todo[:20]:
                out.write("  would render %s\n" % row["relative_path"])
            if len(todo) > 20:
                out.write("  ... and %d more\n" % (len(todo) - 20))
            return 0

        embedder = EmbedderProcess(arguments.threads)
        done = 0
        failed = []
        started = time.perf_counter()
        batch = []
        try:
            for row in todo:
                try:
                    png = render(row)
                except Exception as error:          # noqa: BLE001
                    # A model Atlas cannot draw is not a reason to stop. It
                    # keeps no vector, so the next run tries it again -- which
                    # is right for a transient failure and merely wasteful for
                    # a permanently broken file.
                    failed.append((row["relative_path"], str(error)[:120]))
                    continue
                batch.append((row, png))
                if arguments.pace_ms:
                    time.sleep(arguments.pace_ms / 1000.0)

                if len(batch) >= arguments.batch:
                    done += flush(store, embedder, batch, out)
                    batch = []
                    report_progress(out, done, len(todo), started, failed)
            if batch:
                done += flush(store, embedder, batch, out)
                report_progress(out, done, len(todo), started, failed)
        except KeyboardInterrupt:
            # The store's append order survives this: vectors, then the count
            # that publishes them, then the index. Nothing half-written is
            # ever visible, so stopping here is safe and resuming is free.
            out.write("\nStopped. %d embedded this run; rerun to continue.\n"
                      % done)
        finally:
            embedder.close()

        elapsed = time.perf_counter() - started
        out.write("\n%d embedded in %s (%.0f ms each), %d failed, %d vectors "
                  "in the store\n"
                  % (done, format_duration(elapsed),
                     (elapsed * 1000 / done) if done else 0,
                     len(failed), store.count))
        for path, reason in failed[:10]:
            out.write("  failed  %s -- %s\n" % (path, reason))
        if len(failed) > 10:
            out.write("  ... and %d more failures\n" % (len(failed) - 10))
        return 0
    finally:
        store.close()


def flush(store, embedder, batch, out):
    """Embed a batch and append it. Returns how many were stored."""
    reply = embedder.ask({
        "op": "images",
        "entries": [{"asset_id": row["id"],
                     "png": base64.b64encode(png).decode("ascii")}
                    for row, png in batch]})
    vectors = reply["vectors"]
    if len(vectors) != len(batch):
        out.write("  the embedder returned %d vectors for %d images; batch "
                  "dropped\n" % (len(vectors), len(batch)))
        return 0
    now_ms = int(time.time() * 1000)
    store.append([(row["id"], vector, "render", now_ms)
                  for (row, _png), vector in zip(batch, vectors)])
    return len(batch)


def report_progress(out, done, total, started, failed):
    elapsed = time.perf_counter() - started
    rate = done / elapsed if elapsed else 0
    remaining = (total - done) / rate if rate else 0
    out.write("  %6d/%d  %.2f/s  %s left  %d failed\n"
              % (done, total, rate, format_duration(remaining), len(failed)))
    out.flush()


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Render and embed Atlas assets. Atlas must be running.")
    parser.add_argument("--folder", help="only paths containing this folder")
    parser.add_argument("--pack", help="only assets from archives matching this")
    parser.add_argument("--ext", help="only this extension (fbx or obj)")
    parser.add_argument("--limit", type=int,
                        help="stop after this many, for a first taste")
    parser.add_argument("--batch", type=int, default=DEFAULT_BATCH,
                        help="images per embedder call (default %d)"
                             % DEFAULT_BATCH)
    parser.add_argument("--threads", type=int, default=2,
                        help="embedder threads (default 2, kept low so the "
                             "machine stays usable)")
    parser.add_argument("--pace-ms", type=int, default=0,
                        help="pause between renders, to give Atlas and the "
                             "rest of the machine room")
    parser.add_argument("--dry-run", action="store_true",
                        help="say what would be rendered and stop")
    arguments = parser.parse_args(argv)
    return run(arguments, sys.stdout)


if __name__ == "__main__":
    sys.exit(main())
