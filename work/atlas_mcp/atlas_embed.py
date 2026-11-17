"""SigLIP 2 embeddings for Atlas assets: the one process that holds the model.

Why a separate process at all. The ONNX sessions cost 55 MB (vision, bnb4) and
271 MB (text, int8) of resident memory and about a second to construct, so
they have to be loaded once and reused -- and the MCP server must not pay for
them, because most of what it does never touches an embedding. Keeping the
model here means the server, the tagging pass and the app all drive the same
code, and only when they need it.

What it produces. One 768-float vector per asset: SigLIP 2's `pooler_output`,
which is the pooled image or text embedding. Not `last_hidden_state`, which is
(196, 768) of per-patch features and is not comparable between images.

What it does not produce. Words. There is no tag, no label and no vocabulary
anywhere in this file or in what it writes. "Grungy" is answered by embedding
the word *grungy* at query time and ranking assets by cosine against it, which
is what buys open vocabulary: a query nobody thought of still works. The cost
is that an absolute score means nothing -- SigLIP 2 is trained with a sigmoid
loss, so real matches sit around 0.05 to 0.18 and only the ordering carries
information. Never threshold these numbers; rank them.

Modes:
    --probe                 check the model files and time one of each
    --text "some words"     one query vector, as JSON on stdout
    --search "some words"   rank the stored assets against a phrase
    --search-like ASSET_ID  rank them against an asset already embedded
    --serve                 newline-delimited JSON on stdin/stdout

The two --search modes need --vectors and --index, which the caller resolves:
this file deliberately knows nothing about where the catalog lives.

Run it with -P, not -I. Both keep the working directory off sys.path, which
is the protection that matters here -- a planted json.py next to the data
would otherwise be imported in preference to the real one. But -I also implies
-s, which hides user site-packages, and that is where pip puts onnxruntime,
numpy, Pillow and sentencepiece. Under -I this file cannot find its own
dependencies and says so, having been caught by it once.
"""

import argparse
import base64
import io
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
MODEL_DIR = os.path.join(HERE, "models", "siglip2-base-patch16-224")

# The vision tower in 4-bit (MatMulNBits) and the text tower in int8. Measured
# on this machine: bnb4 at 74 ms/image in batches of eight, text at 120 ms a
# query. The int8 *vision* build is unusable -- it contains ConvInteger(10),
# for which onnxruntime ships no CPU kernel, and fails at session load with
# NOT_IMPLEMENTED. fp16 and q4f16 both load and are slower here.
VISION_MODEL = "vision_model_bnb4.onnx"
TEXT_MODEL = "text_model_int8.onnx"
TOKENIZER = "tokenizer.model"

# Written into the store header, which has 32 bytes for it. A vector computed
# by a different model is not comparable, so the store refuses to open against
# a mismatch rather than quietly ranking nonsense.
MODEL_ID = "siglip2-b16-224-bnb4"

DIMS = 768
IMAGE_SIZE = 224

# From preprocessor_config.json: rescale by 1/255, then normalise with mean
# and standard deviation 0.5 on every channel, which maps to [-1, 1].
_RESCALE = 1.0 / 255.0
_MEAN = 0.5
_STD = 0.5

# From tokenizer_config.json: GemmaTokenizer, lowercased, EOS appended, no
# BOS, right-padded with id 0 to 64 tokens.
TEXT_TOKENS = 64
_PAD_ID = 0
_EOS_ID = 1

# Two threads by default. This runs behind an interactive application on the
# user's own machine, and the point of the queue it feeds is to leave the
# machine usable; onnxruntime otherwise takes every core it can see.
DEFAULT_THREADS = 2

# Eight was the fastest per-image rate measured. Larger batches did not help
# and cost render memory held in flight.
DEFAULT_BATCH = 8


class EmbedError(Exception):
    """Something the caller can act on, reported rather than raised onward."""


def _require(module_name, why):
    """Import a third-party module, or say which install is missing and why.

    These four are the only non-stdlib dependencies in the project, and a
    bare ImportError inside a subprocess driven over a pipe is close to
    undiagnosable from the other end.
    """
    try:
        return __import__(module_name)
    except ImportError as error:
        raise EmbedError(
            "%s is not installed, and %s. Install it with:\n"
            "    python -m pip install %s\n"
            "Original error: %s"
            % (module_name, why, module_name, error))


def model_path(name):
    path = os.path.join(MODEL_DIR, name)
    if not os.path.exists(path):
        raise EmbedError(
            "%s is missing from %s. The model files are not in the "
            "repository -- see README.md, 'Visual tagging', for where they "
            "come from." % (name, MODEL_DIR))
    return path


class Embedder:
    """Holds the ONNX sessions. Both towers load lazily and independently.

    The tagging pass never embeds text and a search never embeds an image, so
    loading both would waste 271 MB or 55 MB of resident memory on every run
    that does one job.
    """

    def __init__(self, threads=DEFAULT_THREADS):
        self.threads = threads
        self._vision = None
        self._text = None
        self._tokenizer = None
        self._numpy = None

    # ---------------------------------------------------------- the sessions

    @property
    def numpy(self):
        if self._numpy is None:
            self._numpy = _require(
                "numpy", "the model's inputs and outputs are arrays")
        return self._numpy

    def _session(self, filename):
        onnxruntime = _require(
            "onnxruntime", "it is what runs the model")
        options = onnxruntime.SessionOptions()
        options.intra_op_num_threads = self.threads
        options.inter_op_num_threads = 1
        # The graph optimisations are already baked into these files, and
        # re-running them costs a second of load time for nothing.
        options.graph_optimization_level = (
            onnxruntime.GraphOptimizationLevel.ORT_ENABLE_BASIC)
        return onnxruntime.InferenceSession(
            model_path(filename), options,
            providers=["CPUExecutionProvider"])

    @property
    def vision(self):
        if self._vision is None:
            self._vision = self._session(VISION_MODEL)
        return self._vision

    @property
    def text(self):
        if self._text is None:
            self._text = self._session(TEXT_MODEL)
        return self._text

    @property
    def tokenizer(self):
        if self._tokenizer is None:
            sentencepiece = _require(
                "sentencepiece", "it is the model's own tokenizer")
            self._tokenizer = sentencepiece.SentencePieceProcessor(
                model_file=model_path(TOKENIZER))
        return self._tokenizer

    # ------------------------------------------------------------- images

    def _pixels(self, png_bytes):
        """One PNG to a (3, 224, 224) float array, the way SigLIP wants it.

        Flattened onto white rather than composited as-is: Atlas renders on a
        transparent background, and PIL's RGB conversion drops alpha to
        black, which turns every silhouette into a dark blob and makes two
        unrelated models look alike.
        """
        pillow = _require("PIL", "it is what decodes a render")
        del pillow
        from PIL import Image

        numpy = self.numpy
        with Image.open(io.BytesIO(png_bytes)) as opened:
            image = opened.convert("RGBA")
            backdrop = Image.new("RGBA", image.size, (255, 255, 255, 255))
            backdrop.alpha_composite(image)
            flat = backdrop.convert("RGB")
            if flat.size != (IMAGE_SIZE, IMAGE_SIZE):
                # resample=2 in preprocessor_config.json is BILINEAR.
                flat = flat.resize(
                    (IMAGE_SIZE, IMAGE_SIZE), Image.BILINEAR)
            data = numpy.asarray(flat, dtype=numpy.float32)

        data = (data * _RESCALE - _MEAN) / _STD
        return numpy.transpose(data, (2, 0, 1))

    def embed_images(self, png_list):
        """Vectors for a batch of PNGs, in the order given."""
        if not png_list:
            return []
        numpy = self.numpy
        batch = numpy.stack([self._pixels(png) for png in png_list])
        pooled = self.vision.run(
            ["pooler_output"], {"pixel_values": batch})[0]
        if pooled.shape[-1] != DIMS:
            raise EmbedError(
                "the vision tower returned %d dimensions, not %d -- the "
                "wrong output is being read" % (pooled.shape[-1], DIMS))
        return [row.astype(numpy.float32) for row in pooled]

    # --------------------------------------------------------------- text

    def _token_ids(self, text):
        """Lowercase, encode, append EOS, right-pad to 64. Truncates."""
        pieces = self.tokenizer.encode((text or "").strip().lower())
        pieces = list(pieces)[:TEXT_TOKENS - 1] + [_EOS_ID]
        return pieces + [_PAD_ID] * (TEXT_TOKENS - len(pieces))

    def embed_text(self, phrases):
        """Vectors for a list of phrases, in the order given."""
        if not phrases:
            return []
        numpy = self.numpy
        ids = numpy.asarray(
            [self._token_ids(phrase) for phrase in phrases], dtype=numpy.int64)
        pooled = self.text.run(["pooler_output"], {"input_ids": ids})[0]
        return [row.astype(numpy.float32) for row in pooled]


# ------------------------------------------------------------------ ranking


def normalise(numpy, vectors):
    """Unit-length rows, so a dot product is a cosine.

    The zero guard matters: an all-zero row would divide by zero and poison
    every score in the matrix with NaN, which sorts unpredictably rather than
    last.
    """
    lengths = numpy.linalg.norm(vectors, axis=-1, keepdims=True)
    return vectors / numpy.maximum(lengths, 1e-12)


def rank_against(numpy, matrix, query_vector):
    """Cosine of every row against one query, as a float array.

    `matrix` is the store's mmap, cast to floats and reshaped -- nothing is
    copied until this multiply, which is the point of the flat file.
    """
    rows = normalise(numpy, numpy.asarray(matrix, dtype=numpy.float32))
    query = normalise(numpy, numpy.asarray(query_vector, dtype=numpy.float32))
    return rows @ query


# -------------------------------------------------------------------- modes


def run_probe(embedder, out):
    """Load both towers and time one of each, so a failure is seen here."""
    numpy = embedder.numpy
    report = ["model dir     %s" % MODEL_DIR]

    for label, name in (("vision", VISION_MODEL), ("text", TEXT_MODEL),
                        ("tokenizer", TOKENIZER)):
        path = model_path(name)
        report.append("%-13s %s (%.0f MB)"
                      % (label, name, os.path.getsize(path) / (1 << 20)))

    started = time.perf_counter()
    blank = _blank_png(embedder)
    vectors = embedder.embed_images([blank] * 2)
    vision_ms = (time.perf_counter() - started) * 1000
    report.append("vision        %d dims, %.0f ms for 2 images (load included)"
                  % (len(vectors[0]), vision_ms))

    started = time.perf_counter()
    phrases = ["a grungy metal barrel", "a clean white wall"]
    text_vectors = embedder.embed_text(phrases)
    text_ms = (time.perf_counter() - started) * 1000
    report.append("text          %d dims, %.0f ms for 2 phrases (load "
                  "included)" % (len(text_vectors[0]), text_ms))

    # Two unrelated phrases must not come out as the same vector; that is the
    # failure an int8 tower that silently mis-executes would produce.
    scores = rank_against(numpy, numpy.stack(text_vectors), text_vectors[0])
    report.append("sanity        self %.4f, other %.4f -- these must differ"
                  % (scores[0], scores[1]))
    report.append("model id      %s" % MODEL_ID)
    out.write("\n".join(report) + "\n")
    return 0


def _blank_png(embedder):
    """A grey 224x224 PNG, for timing without touching the library."""
    from PIL import Image
    buffer = io.BytesIO()
    Image.new("RGB", (IMAGE_SIZE, IMAGE_SIZE), (128, 128, 128)).save(
        buffer, format="PNG")
    del embedder
    return buffer.getvalue()


def _open_store_for_reading(vectors_path, index_path):
    sys.path.insert(0, HERE)
    import embedding_store
    return embedding_store.EmbeddingStore.open(
        vectors_path, index_path, expect_model_id=MODEL_ID)


def run_search(embedder, out, vectors_path, index_path, phrase=None,
               like_asset_id=None, top=20):
    """Rank every stored asset against a phrase, or against another asset.

    Prints JSON: the query, how many vectors were searched, and the top
    matches as {asset_id, score}. Scores are cosines from a sigmoid-trained
    model, so they are small and only their order means anything -- the
    output says so, because a caller that thresholds them will be wrong.
    """
    numpy = embedder.numpy
    store = _open_store_for_reading(vectors_path, index_path)
    try:
        if store.count == 0:
            json.dump({"ok": False,
                       "error": "the store holds no vectors yet; run "
                                "tag_assets.py first"}, out)
            out.write("\n")
            return 1

        if like_asset_id is not None:
            row = store.row_of(like_asset_id)
            if row is None:
                json.dump({"ok": False,
                           "error": "%s has no vector yet" % like_asset_id},
                          out)
                out.write("\n")
                return 1
            query_vector = numpy.asarray(store.vector(row),
                                         dtype=numpy.float32)
            described = "like:" + like_asset_id
        else:
            query_vector = embedder.embed_text([phrase])[0]
            described = phrase

        if len(query_vector) != store.dims:
            json.dump({"ok": False,
                       "error": "the query has %d dimensions and the store "
                                "holds %d, so they cannot be compared"
                                % (len(query_vector), store.dims)}, out)
            out.write("\n")
            return 1

        started = time.perf_counter()
        # store.dims, not DIMS: the store header is the authority on its own
        # width, and taking the model's constant instead reshaped a 4-wide
        # test store as 768 and raised rather than saying anything useful.
        matrix = numpy.frombuffer(
            store.matrix(), dtype=numpy.float32).reshape(
                store.count, store.dims)
        scores = rank_against(numpy, matrix, query_vector)
        # argsort then reverse: argpartition would be faster but the whole
        # sort of 32,000 floats is under a millisecond and this is clearer.
        order = numpy.argsort(scores)[::-1][:max(1, top)]
        names = store.asset_ids_by_row()
        results = [{"asset_id": names[index], "score": float(scores[index])}
                   for index in order
                   if names[index] is not None
                   and names[index] != like_asset_id]
        elapsed_ms = round((time.perf_counter() - started) * 1000)

        del matrix
        json.dump({"ok": True, "query": described, "model_id": MODEL_ID,
                   "searched": store.count, "ms": elapsed_ms,
                   "note": "cosines from a sigmoid-trained model: rank them, "
                           "do not threshold them",
                   "results": results}, out)
        out.write("\n")
        return 0
    finally:
        store.close()


def run_text(embedder, phrase, out):
    vector = embedder.embed_text([phrase])[0]
    json.dump({"text": phrase, "model_id": MODEL_ID,
               "vector": [float(value) for value in vector]}, out)
    out.write("\n")
    return 0


# The serve protocol. One JSON object per line in, one per line out, in the
# same order -- the same shape as the MCP's own transport, for the same reason:
# it needs no framing and survives being read by a human.
#
#   {"op": "ping"}
#       -> {"ok": true, "model_id": "...", "dims": 768, "store": true}
#   {"op": "next", "limit": 8, "pack": "POLYGON_Town"}
#       -> {"ok": true, "selected": 31495, "done": 264, "given_up": 0,
#           "remaining": 8, "assets": [{"asset_id": .., "path": ..}, ..]}
#   {"op": "images", "entries": [{"asset_id": "...", "png": "<base64>"}]}
#       -> {"ok": true, "stored": 8, "count": 272, "ms": 612}
#   {"op": "failed", "entries": [{"asset_id": "...", "reason": "..."}]}
#       -> {"ok": true, "recorded": 1}
#   {"op": "text", "phrases": ["grungy"]}
#       -> {"ok": true, "vectors": [[...]]}
#
# `images` appends rather than returning vectors. The store is only crash-safe
# while one writer keeps an ordering that spans the vector file and its index,
# and a second writer in another language is how that gets broken -- so a
# driver renders pictures and this holds the pen. A driver that genuinely
# wants the numbers asks for `text`, which writes nothing.
#
# Serving the store needs --vectors and --index; without them the three ops
# that touch it refuse and say so, rather than quietly inventing a path.


class _Session:
    """What one --serve run holds open: the model, the store, the catalog.

    All three are expensive to construct and cheap to keep, which is the
    whole reason this is a process rather than a script per batch.
    """

    def __init__(self, embedder, vectors_path=None, index_path=None):
        self.embedder = embedder
        self.vectors_path = vectors_path
        self.index_path = index_path
        self._store = None
        self._tagging = None

    @property
    def tagging(self):
        if self._tagging is None:
            sys.path.insert(0, HERE)
            import tagging
            self._tagging = tagging
        return self._tagging

    @property
    def store(self):
        if self._store is None:
            if not self.vectors_path or not self.index_path:
                raise EmbedError(
                    "this needs --vectors and --index. The worker owns the "
                    "store, but it does not guess where the catalog is.")
            self._store = self.tagging.open_or_create_store(
                self.vectors_path, self.index_path)
        return self._store

    def close(self):
        if self._store is not None:
            self._store.close()
            self._store = None


def _serve_ping(session, message):
    return {"ok": True, "model_id": MODEL_ID, "dims": DIMS,
            "store": bool(session.vectors_path and session.index_path)}


def _serve_next(session, message):
    """What to render next. The queue, answered from the store."""
    limit = message.get("limit")
    limit = None if limit is None else max(1, int(limit))
    tagging = session.tagging
    with tagging.open_catalog_readonly() as connection:
        work = tagging.work_list(
            session.store, connection,
            folder=message.get("folder"),
            pack=message.get("pack"),
            ext=message.get("ext"),
            max_attempts=int(message.get("max_attempts")
                             or tagging.DEFAULT_MAX_ATTEMPTS),
            limit=limit)
    reply = {"ok": True}
    reply.update(work.as_dict())
    return reply


def _serve_images(session, message):
    """Embed these pictures and keep them."""
    entries = message.get("entries") or []
    if not entries:
        return {"ok": True, "stored": 0, "count": session.store.count,
                "ms": 0}
    pngs = []
    for entry in entries:
        encoded = entry.get("png")
        if not encoded:
            raise EmbedError("an entry has no png")
        if not entry.get("asset_id"):
            raise EmbedError("an entry has no asset_id to store it under")
        pngs.append(base64.b64decode(encoded))

    started = time.perf_counter()
    vectors = embedder_vectors(session.embedder, pngs, len(entries))
    now_ms = int(time.time() * 1000)
    session.store.append(
        [(entry["asset_id"], vector, entry.get("source") or "render", now_ms)
         for entry, vector in zip(entries, vectors)])
    # A file that failed twice and then worked must not keep the attempts
    # against it, or a later run gives up on something that is fine.
    for entry in entries:
        session.store.forget_failure(entry["asset_id"])
    return {"ok": True, "stored": len(entries),
            "count": session.store.count,
            "ms": round((time.perf_counter() - started) * 1000)}


def embedder_vectors(embedder, pngs, expected):
    vectors = embedder.embed_images(pngs)
    if len(vectors) != expected:
        raise EmbedError(
            "the model returned %d vectors for %d images, so none of them "
            "can be trusted to belong to the right asset"
            % (len(vectors), expected))
    return vectors


def _serve_failed(session, message):
    """Record renders that could not be produced, so they are not retried
    for ever. The driver decides what counts as the file's fault."""
    entries = message.get("entries") or []
    now_ms = int(time.time() * 1000)
    for entry in entries:
        asset_id = entry.get("asset_id")
        if not asset_id:
            raise EmbedError("a failure has no asset_id")
        session.store.record_failure(
            asset_id, entry.get("reason") or "unknown", now_ms)
    return {"ok": True, "recorded": len(entries)}


def _serve_retry(session, message):
    return {"ok": True, "forgotten": session.store.clear_failures()}


def _serve_text(session, message):
    phrases = message.get("phrases") or []
    if not phrases:
        raise EmbedError("no phrases given")
    vectors = session.embedder.embed_text(phrases)
    return {"ok": True,
            "vectors": [[float(value) for value in vector]
                        for vector in vectors]}


_OPERATIONS = {
    "ping": _serve_ping,
    "next": _serve_next,
    "images": _serve_images,
    "failed": _serve_failed,
    "retry": _serve_retry,
    "text": _serve_text,
}


def run_serve(embedder, stdin, out, vectors_path=None, index_path=None):
    session = _Session(embedder, vectors_path, index_path)
    try:
        for line in stdin:
            line = line.strip()
            if not line:
                continue
            try:
                message = json.loads(line)
            except ValueError as error:
                reply = {"ok": False, "error": "unreadable line: %s" % error}
            else:
                handler = _OPERATIONS.get(message.get("op"))
                if handler is None:
                    reply = {"ok": False,
                             "error": "no such op %r; expected one of %s"
                                      % (message.get("op"),
                                         ", ".join(sorted(_OPERATIONS)))}
                else:
                    try:
                        reply = handler(session, message)
                    except EmbedError as error:
                        reply = {"ok": False, "error": str(error)}
                    except Exception as error:      # noqa: BLE001
                        # A driver waiting on a reply must get one. Dying
                        # here leaves it blocked on a pipe that will never
                        # answer.
                        reply = {"ok": False,
                                 "error": "%s: %s"
                                          % (type(error).__name__, error)}
            out.write(json.dumps(reply) + "\n")
            out.flush()
        return 0
    finally:
        session.close()


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="SigLIP 2 embeddings for Atlas assets.")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--probe", action="store_true",
                       help="check the model files and time one of each")
    group.add_argument("--text", metavar="PHRASE",
                       help="print one query vector as JSON")
    group.add_argument("--search", metavar="PHRASE",
                       help="rank the stored assets against this phrase")
    group.add_argument("--search-like", metavar="ASSET_ID",
                       help="rank them against an asset already embedded")
    group.add_argument("--serve", action="store_true",
                       help="newline-delimited JSON on stdin and stdout")
    parser.add_argument("--vectors", help="path to embeddings.f32")
    parser.add_argument("--index", help="path to embeddings_index.sqlite")
    parser.add_argument("--top", type=int, default=20,
                        help="how many matches to print (default 20)")
    parser.add_argument("--threads", type=int, default=DEFAULT_THREADS,
                        help="onnxruntime intra-op threads (default %d, kept "
                             "low so the machine stays usable)"
                             % DEFAULT_THREADS)
    arguments = parser.parse_args(argv)

    embedder = Embedder(threads=max(1, arguments.threads))
    try:
        if arguments.probe:
            return run_probe(embedder, sys.stdout)
        if arguments.text is not None:
            return run_text(embedder, arguments.text, sys.stdout)
        if arguments.search is not None or arguments.search_like is not None:
            if not arguments.vectors or not arguments.index:
                raise EmbedError(
                    "--search needs --vectors and --index. This file does "
                    "not know where the catalog lives; the caller does.")
            return run_search(
                embedder, sys.stdout, arguments.vectors, arguments.index,
                phrase=arguments.search,
                like_asset_id=arguments.search_like, top=arguments.top)
        return run_serve(embedder, sys.stdin, sys.stdout,
                         vectors_path=arguments.vectors,
                         index_path=arguments.index)
    except EmbedError as error:
        sys.stderr.write("%s\n" % error)
        return 2


if __name__ == "__main__":
    sys.exit(main())
