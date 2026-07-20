#!/usr/bin/env python3
"""Normalize and rebase Card 3 OpenMetrics before promtool ingestion."""

from __future__ import annotations

import gzip
import os
import re
import sys
import time
from pathlib import Path
from typing import NoReturn


META_RE = re.compile(r"^# (HELP|TYPE) ([a-zA-Z_:][a-zA-Z0-9_:]*) (.*)$")


def fail(message: str) -> NoReturn:
    print(f"normalize_openmetrics: {message}", file=sys.stderr)
    raise SystemExit(2)


def sample_parts(line: str) -> tuple[str, str, int] | None:
    if not line or line.startswith("#"):
        return None
    try:
        prefix, value, timestamp = line.rsplit(maxsplit=2)
        return prefix, value, int(timestamp)
    except (ValueError, TypeError):
        fail(f"sample must end with an integer Unix-seconds timestamp: {line[:160]}")


def reorder_metadata(lines: list[str]) -> list[str]:
    """Put adjacent TYPE/HELP metadata in OpenMetrics' conventional order."""
    output: list[str] = []
    index = 0
    while index < len(lines):
        first = META_RE.match(lines[index])
        second = META_RE.match(lines[index + 1]) if index + 1 < len(lines) else None
        if (
            first
            and second
            and first.group(1) == "TYPE"
            and second.group(1) == "HELP"
            and first.group(2) == second.group(2)
        ):
            output.extend((lines[index + 1], lines[index]))
            index += 2
            continue
        output.append(lines[index])
        index += 1
    return output


def main() -> None:
    source = Path(os.environ.get("SOURCE_PATH", "/input/card3_bake_history.openmetrics.gz"))
    destination = Path(os.environ.get("OUTPUT_PATH", "/work/normalized.openmetrics"))
    tsdb = Path(os.environ.get("TSDB_PATH", "/prometheus"))
    step = int(os.environ.get("STEP_SECONDS", "60"))
    lag_steps = int(os.environ.get("BAKE_LAG_STEPS", "1"))

    if step <= 0 or lag_steps < 0:
        fail("STEP_SECONDS must be positive and BAKE_LAG_STEPS must be non-negative")
    if not source.is_file():
        fail(f"source file not found: {source}")
    if tsdb.exists() and any(p.is_dir() and len(p.name) == 26 for p in tsdb.iterdir()):
        fail(f"TSDB already contains blocks: {tsdb}; reset the PVC before rebaking")

    opener = gzip.open if source.suffix == ".gz" else open
    with opener(source, "rt", encoding="utf-8") as handle:
        raw_lines = [line.rstrip("\n") for line in handle]

    lines = [line for line in raw_lines if line.strip() != "# EOF"]
    timestamps = [parts[2] for line in lines if (parts := sample_parts(line))]
    if not timestamps:
        fail("no timestamped samples found")

    source_end = max(timestamps)
    target_end = (int(time.time()) // step) * step - lag_steps * step
    shift = target_end - source_end
    normalized: list[str] = []
    for line in reorder_metadata(lines):
        parts = sample_parts(line)
        if parts is None:
            normalized.append(line)
        else:
            prefix, value, timestamp = parts
            normalized.append(f"{prefix} {value} {timestamp + shift}")
    normalized.append("# EOF")

    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text("\n".join(normalized) + "\n", encoding="utf-8")
    print(
        "normalized "
        f"samples={len(timestamps)} source_end={source_end} target_end={target_end} "
        f"shift_seconds={shift} output={destination}"
    )


if __name__ == "__main__":
    main()
