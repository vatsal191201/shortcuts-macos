#!/usr/bin/env python3
"""Builds Resources/semantic-model.bin from a pinned Model2Vec model.

The app uses this file for natural-language search ("refresh" finds "Reload Page").
The script is the only place that touches the network. The app itself never does.

Steps:
1. Download minishlab/potion-base-32M at a pinned revision, and check the SHA-256 of each file.
2. Reduce the 512 dimensions to 64 with PCA, and store each row as int8 with one float32 scale.
3. Sort the vocabulary by UTF-8 bytes, so that the app can binary-search it in the mapped file.
4. Write a test fixture with the reference tokens and vectors for the Swift tests.

Setup (one time):
    python3 -m venv .venv
    .venv/bin/pip install numpy safetensors tokenizers huggingface_hub
Run:
    .venv/bin/python scripts/build-semantic-model.py

File format (little-endian):
    magic "SCSM", version u32 = 1, count u32, dims u32
    offsets (count + 1) x u32   byte offsets into the string blob, in sorted order
    strings                     UTF-8 token strings, sorted by bytes
    padding to a 4-byte boundary
    scales  count x f32
    rows    count x dims x i8   row i belongs to sorted token i
"""

import hashlib
import json
import os
import struct
import sys

import numpy as np
from huggingface_hub import snapshot_download
from safetensors.numpy import load_file
from tokenizers import Tokenizer

REPO = "minishlab/potion-base-32M"
REVISION = "1e5a03f8eeb2c98b928fbbd846f22f816360919f"
SHA256 = {
    "model.safetensors": "99f6c33204c9231a7391871b7a3c91409b532c8f587a9ea44fc282303d8dec28",
    "tokenizer.json": "7d75cbc54318138807c401b0f0c9721117c628b39de8e8e0edb6cb17e0ee7d18",
}
DIMS = 64

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_MODEL = os.path.join(ROOT, "Resources", "semantic-model.bin")
OUT_FIXTURE = os.path.join(ROOT, "Tests", "ShortCutsCoreTests", "Fixtures", "semantic-fixture.json")

# Strings for the tokenizer and vector parity tests.
FIXTURE_TEXTS = [
    "Reopen Closed Tab", "reopen tab", "Save As…", "Show/Hide Sidebar", "Copy as Pathname",
    "Emoji & Symbols", "Café Settings", "naïve résumé", "x++ and C#", "e-mail don't 100%",
    "F5", "Enter Full Screen", "日本語テスト", "Ünïcödé", "a" * 120, "zzqqxx", "   spaced   out   ",
    "Tab\tand\nnewline", "Log Out Vatsal Bagri…", "Move to Trash",
]

# A small sample to report quality. The Swift tests check the same queries.
EVAL_TITLES = ["New Tab", "New Window", "New Private Window", "Reopen Closed Tab", "Close Tab", "Close Window",
               "Close All", "Open Location…", "Save Page As…", "Print…", "Undo", "Redo", "Cut", "Copy", "Paste",
               "Select All", "Find…", "Find Next", "Reload Page", "Stop", "Zoom In", "Zoom Out", "Actual Size",
               "Enter Full Screen", "Show Sidebar", "View Source", "Developer Tools", "Back", "Forward", "Home",
               "Show History", "Bookmark This Tab…", "Show All Bookmarks", "Duplicate Tab", "Pin Tab", "Mute Tab",
               "Show Downloads", "Minimize", "Move to Trash", "New Folder", "Get Info", "Empty Trash…",
               "Show Next Tab", "Show Previous Tab", "Settings…", "Hide Others", "Quit"]
EVAL_QUERIES = [("reopen tab", "Reopen Closed Tab"), ("undo close tab", "Reopen Closed Tab"),
                ("make text bigger", "Zoom In"), ("go back", "Back"), ("search in page", "Find…"),
                ("delete file", "Move to Trash"), ("incognito", "New Private Window"), ("refresh", "Reload Page"),
                ("save bookmark", "Bookmark This Tab…"), ("inspect element", "Developer Tools"),
                ("next tab", "Show Next Tab"), ("downloads", "Show Downloads"),
                ("make window full screen", "Enter Full Screen"), ("preferences", "Settings…"),
                ("copy the tab", "Duplicate Tab")]
NOISE_QUERIES = ["banana", "weather tomorrow", "qwerty", "my mother", "football score"]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def main():
    path = snapshot_download(REPO, revision=REVISION, allow_patterns=list(SHA256))
    for name, expected in SHA256.items():
        actual = sha256(os.path.join(path, name))
        if actual != expected:
            sys.exit(f"SHA-256 mismatch for {name}: {actual}")

    tokenizer = Tokenizer.from_file(os.path.join(path, "tokenizer.json"))
    vocab = tokenizer.get_vocab()                      # token -> original id
    table = load_file(os.path.join(path, "model.safetensors"))["embeddings"].astype(np.float64)
    assert table.shape[0] == len(vocab), "vocabulary and table differ in size"

    # PCA to DIMS dimensions. Cosine similarity does not depend on the sign of a component.
    centered = table - table.mean(axis=0)
    _, _, vt = np.linalg.svd(centered, full_matrices=False)
    reduced = centered @ vt[:DIMS].T
    scales = np.abs(reduced).max(axis=1) / 127.0
    scales[scales == 0] = 1.0
    quantized = np.clip(np.round(reduced / scales[:, None]), -127, 127).astype(np.int8)

    # Sort tokens by UTF-8 bytes. Row i of the file belongs to sorted token i.
    tokens = sorted(vocab, key=lambda t: t.encode("utf-8"))
    order = np.array([vocab[t] for t in tokens])
    rows = quantized[order]
    row_scales = scales[order].astype(np.float32)
    sorted_index = {t: i for i, t in enumerate(tokens)}

    blob = bytearray()
    offsets = [0]
    for t in tokens:
        blob += t.encode("utf-8")
        offsets.append(len(blob))
    header = b"SCSM" + struct.pack("<III", 1, len(tokens), DIMS)
    body = header + struct.pack(f"<{len(offsets)}I", *offsets) + bytes(blob)
    body += b"\0" * ((-len(body)) % 4)
    body += row_scales.astype("<f4").tobytes() + rows.tobytes()
    os.makedirs(os.path.dirname(OUT_MODEL), exist_ok=True)
    with open(OUT_MODEL, "wb") as f:
        f.write(body)

    # Reference embedding: tokens without special tokens and without [UNK], mean of the
    # dequantized rows, then L2 normalization. The Swift code must do the same.
    def tokens_of(text):
        return [t for t in tokenizer.encode(text, add_special_tokens=False).tokens if t != "[UNK]"]

    def embed(text):
        toks = tokens_of(text)
        if not toks:
            return None
        idx = [sorted_index[t] for t in toks]
        v = (rows[idx].astype(np.float64) * row_scales[idx, None]).mean(axis=0)
        return v / (np.linalg.norm(v) + 1e-12)

    fixture = {
        "source": f"{REPO}@{REVISION}",
        "dims": DIMS,
        "cases": [{"text": t,
                   "tokens": tokenizer.encode(t, add_special_tokens=False).tokens,
                   "vector": None if embed(t) is None else [round(float(x), 6) for x in embed(t)]}
                  for t in FIXTURE_TEXTS],
    }
    os.makedirs(os.path.dirname(OUT_FIXTURE), exist_ok=True)
    with open(OUT_FIXTURE, "w", encoding="utf-8") as f:
        json.dump(fixture, f, ensure_ascii=False, indent=1)

    # Report quality and the similarity of right and unrelated matches.
    def clean(title):
        return title.replace("…", "")

    title_vecs = np.array([embed(clean(t)) for t in EVAL_TITLES])
    top1 = top3 = 0
    right = []
    for q, want in EVAL_QUERIES:
        sims = title_vecs @ embed(q)
        ranked = [EVAL_TITLES[i] for i in np.argsort(-sims)]
        r = ranked.index(want) + 1
        top1 += r == 1
        top3 += r <= 3
        right.append(float(sims[EVAL_TITLES.index(want)]))
    noise = [float((title_vecs @ embed(q)).max()) for q in NOISE_QUERIES]
    print(f"wrote {OUT_MODEL}: {len(body) / 1e6:.2f} MB, {len(tokens)} tokens x {DIMS} dims, sha256 {sha256(OUT_MODEL)}")
    print(f"wrote {OUT_FIXTURE}")
    print(f"sample: top-1 {top1}/{len(EVAL_QUERIES)}, top-3 {top3}/{len(EVAL_QUERIES)}")
    print("similarity of the right title: " + ", ".join(f"{x:.2f}" for x in sorted(right)))
    print("best similarity for unrelated queries: " + ", ".join(f"{q}={x:.2f}" for q, x in zip(NOISE_QUERIES, noise)))


if __name__ == "__main__":
    main()
