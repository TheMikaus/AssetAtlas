"""Embed the library's images: atlases, textures, icon sprites.

The third driver, and the only one that needs nothing running. A model has to
be rendered before there is a picture to embed, which is why tag_assets.py
drives Atlas; an image *is* the picture, so this reads the file and hands the
bytes straight over. Atlas can be closed, and the vectors land in the same
store beside the model ones.

Everything that decides anything is still tagging.py, reached through
`atlas_embed.py --serve`, so this cannot disagree with the other two drivers
about what needs work or who writes the store.

Why it is worth having at all: a search for "scuffed dark metal floor" over
models alone answers with models whose *shape* is floor-like, because shape
is all a silhouette carries. The material being asked about lives in the
texture, and until the textures are in the store the question cannot be
answered. 35,522 PNGs, 1,841 GIFs, 1,608 PSDs, 143 JPEGs and 9 BMPs are
34,986 distinct files after duplicates collapse.

What it costs, measured rather than guessed: 33,671 of those 34,986 are under
1 MB and the 99th percentile is 2.5 MB, so this is nothing like the render
pass. The decode and the embed both happen in the worker, which is the
opposite of tag_assets.py -- there, the worker idled while Atlas drew -- so
the default thread count here is higher.

    python -I work/atlas_mcp/tag_images.py [--pack POLYGON_Town] [--limit 200]

Run it with -I or -P, for the reason in atlas_embed.py's docstring.
"""

import argparse
import base64
import os
import sys
import time
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import atlas_mcp                                    # noqa: E402
import tagging                                      # noqa: E402
# Reused rather than copied: a second Worker class would be a second protocol
# to keep in step, and the two drivers already share every decision.
from tag_assets import (Worker, be_polite, format_duration,  # noqa: E402
                        report_progress, GIVE_UP_AFTER_CONSECUTIVE)


class ArchiveReader:
    """Read entries out of archives, holding one handle at a time.

    Candidates come back ordered by path, so consecutive images are nearly
    always in the same archive; reopening it per file would re-parse a
    central directory of tens of thousands of entries each time.

    One handle, not a cache of many: the order makes a second one almost
    never useful, and an open zip handle keeps the file locked on Windows.
    """

    def __init__(self):
        self.container = None
        self.handle = None
        self.opened = 0

    def read(self, path):
        parsed = atlas_mcp.parse_zip_path(path)
        if parsed is None:
            with open(path, "rb") as handle:
                return handle.read()
        container, entry = parsed
        if container != self.container:
            self.close()
            self.handle = zipfile.ZipFile(container)
            self.container = container
            self.opened += 1
        return self.handle.read(entry)

    def close(self):
        if self.handle is not None:
            try:
                self.handle.close()
            except OSError:
                pass
        self.handle = None
        self.container = None


def load(reader, asset, max_bytes):
    """The bytes of one image, or a refusal that says why.

    The size is checked before reading rather than after: the point of the
    cap is not to hold a 177 MB PSD in memory, and reading it to find out how
    big it is would defeat that.
    """
    size = asset.get("size")
    if size is not None and max_bytes and size > max_bytes:
        raise RuntimeError(
            "%.1f MB, over the %.0f MB cap for one image"
            % (size / 1048576.0, max_bytes / 1048576.0))
    data = reader.read(asset["path"])
    if not data:
        raise RuntimeError("the file is empty")
    return data


def flush(worker, batch, out):
    """Hand a batch over. The worker embeds and keeps it; this counts."""
    reply = worker.ask(op="images", entries=[
        {"asset_id": asset["asset_id"],
         "image": base64.b64encode(data).decode("ascii"),
         "source": tagging.SOURCE_BY_KIND["image"]}
        for asset, data in batch])
    stored = reply.get("stored", 0)
    if stored != len(batch):
        out.write("  the worker kept %d of %d; the rest will be retried\n"
                  % (stored, len(batch)))
    return stored


def run(arguments, out):
    priority = be_polite()
    vectors_path, index_path = tagging.store_paths()
    worker = Worker(arguments.threads, vectors_path, index_path)
    reader = ArchiveReader()
    try:
        if arguments.retry_failed:
            forgotten = worker.ask(op="retry")["forgotten"]
            out.write("retry         %d previous failures forgotten\n"
                      % forgotten)

        selection = {"folder": arguments.folder, "pack": arguments.pack,
                     "ext": arguments.ext,
                     "max_attempts": arguments.max_attempts,
                     "kind": "image"}
        work = worker.ask(op="next", limit=arguments.limit, **selection)

        out.write("%d distinct images selected, %d already embedded, "
                  "%d to do\n"
                  % (work["selected"], work["done"], work["remaining"]))
        out.write("store         %s\n" % vectors_path)
        out.write("priority      %s, %d worker threads\n"
                  % (priority, arguments.threads))
        if work["given_up"]:
            out.write("given up      %d after %d failed attempts each "
                      "(--retry-failed to try them again)\n"
                      % (work["given_up"], arguments.max_attempts))
        if not work["assets"]:
            out.write("Nothing to do.\n")
            return 0
        if arguments.dry_run:
            for asset in work["assets"][:20]:
                out.write("  would embed %s\n" % asset["relative_path"])
            if len(work["assets"]) > 20:
                out.write("  ... and %d more\n" % (len(work["assets"]) - 20))
            return 0

        total = work["remaining"]
        done = 0
        failed = []
        interrupted = None
        consecutive_failures = 0
        started = time.perf_counter()
        batch = []
        pending = list(work["assets"])
        # The worker answers `next` from the store, and an image that has not
        # been handed over yet is not in the store -- so without this, topping
        # up re-queues whatever is still in the batch and embeds it twice.
        taken = {asset["asset_id"] for asset in pending}

        try:
            while pending:
                asset = pending.pop(0)
                try:
                    data = load(reader, asset, arguments.max_bytes)
                except Exception as error:          # noqa: BLE001
                    reason = "%s: %s" % (type(error).__name__, error)
                    consecutive_failures += 1
                    if consecutive_failures >= GIVE_UP_AFTER_CONSECUTIVE:
                        # A run of failures this long is not about the files.
                        # A missing drive looks exactly like 35,000 broken
                        # images otherwise, and would retire all of them.
                        interrupted = (
                            "%d reads failed in a row, so something systemic "
                            "is wrong and the rest were left alone"
                            % consecutive_failures)
                        break
                    failed.append((asset["relative_path"], reason[:120]))
                    worker.ask(op="failed", entries=[
                        {"asset_id": asset["asset_id"], "reason": reason}])
                    continue
                consecutive_failures = 0
                batch.append((asset, data))
                if arguments.pace_ms:
                    time.sleep(arguments.pace_ms / 1000.0)

                if len(batch) >= arguments.batch:
                    done += flush(worker, batch, out)
                    batch = []
                    report_progress(out, done, total, started, failed)

                if not pending and arguments.limit is None:
                    more = worker.ask(op="next", limit=arguments.batch * 8,
                                      **selection)
                    pending = [item for item in more["assets"]
                               if item["asset_id"] not in taken]
                    taken.update(item["asset_id"] for item in pending)
                    total = done + len(batch) + len(pending)
        except KeyboardInterrupt:
            interrupted = "Stopped"
        except RuntimeError as error:
            interrupted = "The worker stopped: %s" % error

        # Whatever is in hand gets written on every path out: the store's
        # append order makes a partial batch exactly as safe as a full one.
        if batch:
            try:
                done += flush(worker, batch, out)
            except (RuntimeError, OSError, ValueError) as error:
                out.write("  the last %d could not be embedded: %s\n"
                          % (len(batch), error))
            report_progress(out, done, total, started, failed)

        if interrupted:
            out.write("\n%s. %d embedded this run and kept; rerun to "
                      "continue where it left off.\n" % (interrupted, done))

        elapsed = time.perf_counter() - started
        out.write("\n%d embedded in %s (%.0f ms each), %d failed, "
                  "%d archives opened\n"
                  % (done, format_duration(elapsed),
                     (elapsed * 1000 / done) if done else 0, len(failed),
                     reader.opened))
        for path, reason in failed[:10]:
            out.write("  failed  %s -- %s\n" % (path, reason))
        if len(failed) > 10:
            out.write("  ... and %d more failures\n" % (len(failed) - 10))
        return 0
    finally:
        reader.close()
        worker.close()


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Embed the catalog's images. Atlas need not be running.")
    parser.add_argument("--folder", help="only paths containing this folder")
    parser.add_argument("--pack",
                        help="only images from archives matching this")
    parser.add_argument("--ext",
                        help="only this extension (png, psd, gif, jpg, bmp)")
    parser.add_argument("--limit", type=int,
                        help="stop after this many, for a first taste")
    parser.add_argument("--batch", type=int, default=tagging.DEFAULT_BATCH,
                        help="images per worker call (default %d)"
                             % tagging.DEFAULT_BATCH)
    # Higher than tag_assets.py's two on purpose: there the worker waited on
    # Atlas to draw, and here the decode and the embed are both its work.
    parser.add_argument("--threads", type=int, default=4,
                        help="worker threads (default 4; the decode and the "
                             "embed both happen there)")
    parser.add_argument("--pace-ms", type=int, default=0,
                        help="pause between images, to leave the machine room")
    parser.add_argument("--max-bytes", type=int,
                        default=tagging.MAX_IMAGE_BYTES,
                        help="refuse an image larger than this (default "
                             "%d; 0 means no cap)" % tagging.MAX_IMAGE_BYTES)
    parser.add_argument("--max-attempts", type=int,
                        default=tagging.DEFAULT_MAX_ATTEMPTS,
                        help="give up on an image after this many failures "
                             "(default %d; 0 means never give up)"
                             % tagging.DEFAULT_MAX_ATTEMPTS)
    parser.add_argument("--retry-failed", action="store_true",
                        help="forget every recorded failure and try them "
                             "all again")
    parser.add_argument("--dry-run", action="store_true",
                        help="say what would be embedded and stop")
    arguments = parser.parse_args(argv)
    return run(arguments, sys.stdout)


if __name__ == "__main__":
    sys.exit(main())
