#!/usr/bin/env python3
"""
Basic usage:
  python scripts/subset_fasta.py full_reference.fa reduced_reference.fa --size 10MB

Build a reproducible reduced FASTA by sampling one interval from every contig.
"""

from __future__ import annotations

import argparse
import gzip
import random
import re
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import TextIO


DEFAULT_SIZE = "10MB"
DEFAULT_SEED = 123
DEFAULT_LINE_WIDTH = 80
SIZE_UNITS = {
    "": 1,
    "B": 1,
    "KB": 1_000,
    "K": 1_000,
    "MB": 1_000_000,
    "M": 1_000_000,
    "GB": 1_000_000_000,
    "G": 1_000_000_000,
    "KIB": 1_024,
    "MIB": 1_048_576,
    "GIB": 1_073_741_824,
}


def parse_size(value: str) -> int:
    """Parse a positive base count with an optional SI or binary suffix."""
    match = re.fullmatch(r"\s*([0-9]+(?:\.[0-9]+)?)\s*([A-Za-z]*)\s*", value)
    if match is None or match.group(2).upper() not in SIZE_UNITS:
        raise argparse.ArgumentTypeError(
            "size must be a base count such as 10000000, 10MB, or 10MiB"
        )
    try:
        bases = Decimal(match.group(1)) * SIZE_UNITS[match.group(2).upper()]
    except InvalidOperation as exc:
        raise argparse.ArgumentTypeError(f"invalid size: {value!r}") from exc
    if bases != bases.to_integral_value() or bases < 1:
        raise argparse.ArgumentTypeError("size must resolve to a positive whole number of bases")
    return int(bases)


def positive_int(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"expected an integer, got {value!r}") from exc
    if parsed < 1:
        raise argparse.ArgumentTypeError("value must be at least 1")
    return parsed


def open_fasta(path: Path) -> TextIO:
    if path.name.endswith(".gz"):
        return gzip.open(path, "rt", encoding="ascii")
    return path.open("r", encoding="ascii")


def read_lengths(path: Path) -> list[tuple[str, int]]:
    records: list[tuple[str, int]] = []
    seen: set[str] = set()
    name: str | None = None
    length = 0

    with open_fasta(path) as fasta:
        for line_number, line in enumerate(fasta, start=1):
            if line.startswith(">"):
                if name is not None:
                    records.append((name, length))
                header = line[1:].strip()
                if not header:
                    raise ValueError(f"empty FASTA header at line {line_number}")
                name = header.split()[0]
                if name in seen:
                    raise ValueError(f"duplicate FASTA record name: {name}")
                seen.add(name)
                length = 0
            else:
                if name is None:
                    if line.strip():
                        raise ValueError(f"sequence before first FASTA header at line {line_number}")
                    continue
                length += len("".join(line.split()))

    if name is not None:
        records.append((name, length))
    if not records:
        raise ValueError("input contains no FASTA records")
    empty = [name for name, length in records if length == 0]
    if empty:
        raise ValueError(f"empty FASTA record: {empty[0]}")
    return records


def allocate_lengths(lengths: list[int], target_size: int) -> list[int]:
    """Allocate exactly target_size bases proportionally, including every record."""
    record_count = len(lengths)
    total_size = sum(lengths)
    if target_size < record_count:
        raise ValueError(
            f"requested size ({target_size}) is smaller than the number of contigs "
            f"({record_count}); at least one base per contig is required"
        )
    if target_size > total_size:
        raise ValueError(
            f"requested size ({target_size}) exceeds input size ({total_size})"
        )

    allocations = [1] * record_count
    remaining = target_size - record_count
    capacities = [length - 1 for length in lengths]
    total_capacity = sum(capacities)
    if remaining == 0 or total_capacity == 0:
        return allocations

    floors = [(remaining * capacity) // total_capacity for capacity in capacities]
    allocations = [base + extra for base, extra in zip(allocations, floors)]
    remainder = remaining - sum(floors)
    order = sorted(
        range(record_count),
        key=lambda index: ((remaining * capacities[index]) % total_capacity, -index),
        reverse=True,
    )
    for index in order[:remainder]:
        allocations[index] += 1
    return allocations


class WrappedWriter:
    def __init__(self, output: TextIO, width: int) -> None:
        self.output = output
        self.width = width
        self.column = 0

    def write(self, sequence: str) -> None:
        offset = 0
        while offset < len(sequence):
            count = min(self.width - self.column, len(sequence) - offset)
            self.output.write(sequence[offset : offset + count])
            self.column += count
            offset += count
            if self.column == self.width:
                self.output.write("\n")
                self.column = 0

    def finish(self) -> None:
        if self.column:
            self.output.write("\n")
            self.column = 0


def write_subset(
    input_path: Path,
    output_path: Path,
    records: list[tuple[str, int]],
    allocations: list[int],
    seed: int,
    line_width: int,
) -> None:
    rng = random.Random(seed)
    intervals = {
        name: (rng.randint(0, length - allocation), allocation)
        for (name, length), allocation in zip(records, allocations)
    }

    current_name: str | None = None
    source_position = 0
    writer: WrappedWriter | None = None
    with open_fasta(input_path) as source, output_path.open(
        "x", encoding="ascii", newline="\n"
    ) as output:
        for line in source:
            if line.startswith(">"):
                if writer is not None:
                    writer.finish()
                current_name = line[1:].strip().split()[0]
                start, length = intervals[current_name]
                output.write(
                    f">{current_name} source_interval={current_name}:{start + 1}-{start + length}\n"
                )
                source_position = 0
                writer = WrappedWriter(output, line_width)
                continue

            sequence = "".join(line.split())
            if not sequence or current_name is None or writer is None:
                continue
            start, selected_length = intervals[current_name]
            end = start + selected_length
            chunk_start = max(start, source_position)
            chunk_end = min(end, source_position + len(sequence))
            if chunk_start < chunk_end:
                writer.write(
                    sequence[
                        chunk_start - source_position : chunk_end - source_position
                    ]
                )
            source_position += len(sequence)
        if writer is not None:
            writer.finish()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Create an exact-size reduced FASTA by sampling one reproducible "
            "interval from every input contig, weighted by contig length."
        )
    )
    parser.add_argument("input", type=Path, help="input FASTA (.fa, .fasta, or gzip-compressed)")
    parser.add_argument("output", type=Path, help="new output FASTA path")
    parser.add_argument(
        "--size",
        type=parse_size,
        default=parse_size(DEFAULT_SIZE),
        help=f"total output bases (default: {DEFAULT_SIZE}; accepts KB/MB/GB or KiB/MiB/GiB)",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=DEFAULT_SEED,
        help="random seed for reproducible intervals (default: %(default)s)",
    )
    parser.add_argument(
        "--line-width",
        type=positive_int,
        default=DEFAULT_LINE_WIDTH,
        help="maximum output sequence characters per line (default: %(default)s)",
    )
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        if not args.input.is_file():
            raise ValueError(f"input is not a file: {args.input}")
        if args.input.resolve() == args.output.resolve():
            raise ValueError("input and output paths must differ")
        records = read_lengths(args.input)
        allocations = allocate_lengths([length for _, length in records], args.size)
        write_subset(
            args.input,
            args.output,
            records,
            allocations,
            args.seed,
            args.line_width,
        )
    except (OSError, ValueError) as exc:
        parser.error(str(exc))

    print(
        f"Wrote {args.size} bases from {len(records)} contigs to {args.output}",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
