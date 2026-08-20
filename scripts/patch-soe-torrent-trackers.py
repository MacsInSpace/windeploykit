#!/usr/bin/env python3
"""Add announce-list (multi-tracker) to SOE .torrent files without changing info hash."""

from __future__ import annotations

import argparse
import os
import sys
from typing import Any

DEFAULT_TRACKERS = [
    "http://tracker.example.com/announce.php",
    "http://deploy.example.com/announce",
]


def bencode_encode(value: Any) -> bytes:
    if isinstance(value, int):
        return b"i" + str(value).encode() + b"e"
    if isinstance(value, bytes):
        return str(len(value)).encode() + b":" + value
    if isinstance(value, str):
        data = value.encode("utf-8")
        return str(len(data)).encode() + b":" + data
    if isinstance(value, list):
        return b"l" + b"".join(bencode_encode(v) for v in value) + b"e"
    if isinstance(value, dict):
        out = b"d"
        for key in sorted(value.keys(), key=lambda k: k if isinstance(k, bytes) else k.encode()):
            out += bencode_encode(key) + bencode_encode(value[key])
        return out + b"e"
    raise TypeError(f"unsupported type: {type(value)!r}")


def bencode_decode(data: bytes, index: int = 0) -> tuple[Any, int]:
    if data[index : index + 1] == b"i":
        end = data.index(b"e", index)
        return int(data[index + 1 : end]), end + 1
    if data[index : index + 1] == b"l":
        index += 1
        items: list[Any] = []
        while data[index : index + 1] != b"e":
            item, index = bencode_decode(data, index)
            items.append(item)
        return items, index + 1
    if data[index : index + 1] == b"d":
        index += 1
        obj: dict[Any, Any] = {}
        while data[index : index + 1] != b"e":
            key, index = bencode_decode(data, index)
            val, index = bencode_decode(data, index)
            obj[key] = val
        return obj, index + 1
    colon = data.index(b":", index)
    length = int(data[index:colon])
    start = colon + 1
    return data[start : start + length], start + length


def patch_torrent(path: str, trackers: list[str]) -> None:
    if not trackers:
        raise ValueError("at least one tracker URL is required")
    with open(path, "rb") as fh:
        raw = fh.read()
    meta, _ = bencode_decode(raw)
    if not isinstance(meta, dict):
        raise ValueError(f"{path}: expected dict root")

    meta[b"announce"] = trackers[0].encode("utf-8")
    if len(trackers) > 1:
        meta[b"announce-list"] = [[url.encode("utf-8") for url in trackers]]
    elif b"announce-list" in meta:
        del meta[b"announce-list"]

    patched = bencode_encode(meta)
    with open(path, "wb") as fh:
        fh.write(patched)


def main() -> int:
    parser = argparse.ArgumentParser(description="Embed BitTorrent tracker URLs in .torrent files.")
    parser.add_argument(
        "--tracker",
        action="append",
        dest="trackers",
        help="Announce URL (repeat for multiple; same tier). Default: DE + deploy.",
    )
    parser.add_argument("files", nargs="+", help=".torrent file paths")
    args = parser.parse_args()

    trackers = args.trackers if args.trackers else list(DEFAULT_TRACKERS)
    for path in args.files:
        if not os.path.isfile(path):
            print(f"skip missing: {path}", file=sys.stderr)
            continue
        patch_torrent(path, trackers)
        print(f"patched {os.path.basename(path)} -> {', '.join(trackers)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
