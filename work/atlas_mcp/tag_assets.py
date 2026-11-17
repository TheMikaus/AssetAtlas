"""The visual tagging pass from a terminal: render, hand over, repeat.

This is one of two drivers. The other is Atlas's own background queue, and
they share everything that decides anything: which assets need work, what
counts as done, what a failure means, and who writes the store. All of that
lives behind `atlas_embed.py --serve` (see tagging.py), so the two cannot
drift into disagreeing about the same library.

What a driver does is narrow by design:

    ask the worker what to render
    render it, through Atlas's own renderer
    hand the pictures back
    repeat

What this costs, measured on this library rather than guessed. The render is
the whole job -- 9 ms to embed against a few hundred milliseconds to a few
seconds to draw -- so everything here follows from the render:

    31,495 distinct models, weighted across their real sizes: about 3.5 hours

An earlier estimate of 8.7 hours came from sampling one character pack, which
is the expensive end; 15,422 of the candidates are under 32 KB and 78% are
under 64 KB, where a render is a few hundred milliseconds.

So it is an overnight job, and three things follow:

  * It is resumable, and nothing records the queue -- whatever has no vector
    is the work. Stopping loses at most the batch in flight, and that only
    because the store publishes a batch at a time.
  * It is sliceable: --folder, --pack and --ext take the packs you are
    building with now instead of waiting behind 30,000 files you are not.
  * It leaves the machine usable. The embedder gets two threads, this process
    runs below normal priority, and --pace-ms puts a gap between renders.

Atlas has to be running: the renderer is its own, deliberately, so the
picture being embedded is the picture the app shows you.

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
import tagging                                      # noqa: E402

# A run of failures this long means the problem is not the files. Atlas
# answering but refusing everything looks exactly like 31,000 broken models
# otherwise, and would retire all of them after three runs.
GIVE_UP_AFTER_CONSECUTIVE = 25


class Worker:
    """atlas_embed.py --serve, as a child process over two pipes.

    One child for the whole run: the ONNX session costs about a second to
    construct, so a process per batch would spend longer loading the model
    than using it. It also holds the store, which is why there is exactly one
    of these at a time.
    """

    def __init__(self, threads, vectors_path, index_path):
        self.process = subprocess.Popen(
            [sys.executable, "-P", os.path.join(HERE, "atlas_embed.py"),
             "--serve", "--threads", str(threads),
             "--vectors", vectors_path, "--index", index_path],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, cwd=HERE, text=True, bufsize=1)

    def ask(self, **message):
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

    The renders happen in Atlas and the matrix multiplies in the worker, so
    this process is mostly waiting -- but it is the worker's parent, and on
    Windows a child inherits the parent's priority class.
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


def render(asset):
    """One PNG from Atlas's own renderer."""
    report = atlas_mcp.bridge_call("/render", {
        "path": asset["path"], "size": tagging.RENDER_SIZE})
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


def report_progress(out, done, total, started, failed):
    elapsed = time.perf_counter() - started
    rate = done / elapsed if elapsed else 0
    remaining = (total - done) / rate if rate else 0
    out.write("  %6d/%d  %.2f/s  %s left  %d failed\n"
              % (done, total, rate, format_duration(remaining), len(failed)))
    out.flush()


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
    vectors_path, index_path = tagging.store_paths()
    worker = Worker(arguments.threads, vectors_path, index_path)
    try:
        if arguments.retry_failed:
            forgotten = worker.ask(op="retry")["forgotten"]
            out.write("retry         %d previous failures forgotten\n"
                      % forgotten)

        selection = {"folder": arguments.folder, "pack": arguments.pack,
                     "ext": arguments.ext,
                     "max_attempts": arguments.max_attempts}
        work = worker.ask(op="next", limit=arguments.limit, **selection)

        out.write("%d distinct models selected, %d already embedded, "
                  "%d to do\n"
                  % (work["selected"], work["done"], work["remaining"]))
        out.write("store         %s\n" % vectors_path)
        out.write("priority      %s, %d worker threads, %d ms pace\n"
                  % (priority, arguments.threads, arguments.pace_ms))
        if work["given_up"]:
            out.write("given up      %d after %d failed attempts each "
                      "(--retry-failed to try them again)\n"
                      % (work["given_up"], arguments.max_attempts))
        if not work["assets"]:
            out.write("Nothing to do.\n")
            return 0
        if arguments.dry_run:
            for asset in work["assets"][:20]:
                out.write("  would render %s\n" % asset["relative_path"])
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
        # Every asset this run has taken off the queue. The worker answers
        # `next` from the store, and a render that has not been handed over
        # yet is not in the store -- so without this, topping up re-queues
        # whatever is still in the batch and renders it twice. It did: ten
        # assets produced twelve vectors.
        taken = {asset["asset_id"] for asset in pending}

        try:
            while pending:
                asset = pending.pop(0)
                try:
                    png = render(asset)
                except Exception as error:          # noqa: BLE001
                    reason = str(error)
                    # Blaming the file is only right when the file is at
                    # fault. If Atlas has gone -- closed mid-run, or the
                    # machine got busy enough to drop the connection -- then
                    # every remaining asset would be charged a failed
                    # attempt for something that is not about it, and three
                    # such runs would permanently skip thousands of good
                    # files. So check who is actually broken.
                    if atlas_mcp.bridge_version() is None:
                        interrupted = ("Atlas stopped answering, so the rest "
                                       "were left alone rather than blamed")
                        break
                    consecutive_failures += 1
                    if consecutive_failures >= GIVE_UP_AFTER_CONSECUTIVE:
                        interrupted = (
                            "%d renders failed in a row, so something "
                            "systemic is wrong and the rest were left alone"
                            % consecutive_failures)
                        break
                    failed.append((asset["relative_path"], reason[:120]))
                    worker.ask(op="failed", entries=[
                        {"asset_id": asset["asset_id"], "reason": reason}])
                    continue
                consecutive_failures = 0
                batch.append((asset, png))
                if arguments.pace_ms:
                    time.sleep(arguments.pace_ms / 1000.0)

                if len(batch) >= arguments.batch:
                    done += flush(worker, batch, out)
                    batch = []
                    report_progress(out, done, total, started, failed)

                # Topping up only when the queue is empty keeps this to one
                # `next` per batch-of-batches rather than one per asset, and
                # the answer stays current as vectors land.
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

        # Whatever is in hand gets written, on every path out. Discarding it
        # threw away up to seven renders, which on the larger models is a
        # minute of work, for no reason -- the store's append order makes a
        # partial batch exactly as safe as a full one.
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
        out.write("\n%d embedded in %s (%.0f ms each), %d failed\n"
                  % (done, format_duration(elapsed),
                     (elapsed * 1000 / done) if done else 0, len(failed)))
        for path, reason in failed[:10]:
            out.write("  failed  %s -- %s\n" % (path, reason))
        if len(failed) > 10:
            out.write("  ... and %d more failures\n" % (len(failed) - 10))
        return 0
    finally:
        worker.close()


def flush(worker, batch, out):
    """Hand a batch over. The worker embeds and keeps it; this counts."""
    reply = worker.ask(op="images", entries=[
        {"asset_id": asset["asset_id"],
         "png": base64.b64encode(png).decode("ascii")}
        for asset, png in batch])
    stored = reply.get("stored", 0)
    if stored != len(batch):
        out.write("  the worker kept %d of %d; the rest will be retried\n"
                  % (stored, len(batch)))
    return stored


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Render and embed Atlas assets. Atlas must be running.")
    parser.add_argument("--folder", help="only paths containing this folder")
    parser.add_argument("--pack",
                        help="only assets from archives matching this")
    parser.add_argument("--ext", help="only this extension (fbx or obj)")
    parser.add_argument("--limit", type=int,
                        help="stop after this many, for a first taste")
    parser.add_argument("--batch", type=int, default=tagging.DEFAULT_BATCH,
                        help="images per worker call (default %d)"
                             % tagging.DEFAULT_BATCH)
    parser.add_argument("--threads", type=int, default=2,
                        help="worker threads (default 2, kept low so the "
                             "machine stays usable)")
    parser.add_argument("--pace-ms", type=int, default=0,
                        help="pause between renders, to give Atlas and the "
                             "rest of the machine room")
    parser.add_argument("--max-attempts", type=int,
                        default=tagging.DEFAULT_MAX_ATTEMPTS,
                        help="give up on an asset after this many failed "
                             "renders (default %d; 0 means never give up)"
                             % tagging.DEFAULT_MAX_ATTEMPTS)
    parser.add_argument("--retry-failed", action="store_true",
                        help="forget every recorded failure and try them "
                             "all again")
    parser.add_argument("--dry-run", action="store_true",
                        help="say what would be rendered and stop")
    arguments = parser.parse_args(argv)
    return run(arguments, sys.stdout)


if __name__ == "__main__":
    sys.exit(main())
