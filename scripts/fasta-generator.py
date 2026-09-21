#!/usr/bin/env python3
"""
Generate a reproducible random FASTA reference.

  scripts/fasta-generator.py \
    --contigs 2 \
    --size 2000000 \
    --seed 123 \
    --output pilot_reference.fa
"""




from __future__ import annotations

import argparse
import random
from pathlib import Path
from typing import TextIO


DEFAULT_CONTIGS = 2
DEFAULT_SIZE = 2_000_000
DEFAULT_LINE_WIDTH = 80
DEFAULT_SEED = 123
DNA_ALPHABET = "ACGT"


def positive_int(value: str) -> int:
    """Parse a strictly positive integer for argparse."""
    try:
        parsed = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"expected an integer, got {value!r}") from exc
    if parsed < 1:
        raise argparse.ArgumentTypeError("value must be at least 1")
    return parsed


def contig_lengths(total_size: int, contig_count: int) -> list[int]:
    """Distribute total_size bases as evenly as possible among contigs."""
    if total_size < contig_count:
        raise ValueError("--size must be at least as large as --contigs")
    base_length, remainder = divmod(total_size, contig_count)
    return [base_length + (index < remainder) for index in range(contig_count)]


def write_random_sequence(
    output: TextIO, length: int, line_width: int, rng: random.Random
) -> None:
    """Write length random DNA bases without holding a whole contig in memory."""
    remaining = length
    while remaining:
        chunk_size = min(line_width, remaining)
        output.write("".join(rng.choices(DNA_ALPHABET, k=chunk_size)))
        output.write("\n")
        remaining -= chunk_size


def generate_fasta(
    output_path: Path,
    total_size: int,
    contig_count: int,
    line_width: int,
    seed: int,
) -> None:
    """Generate a FASTA whose sequence lengths sum to total_size."""
    lengths = contig_lengths(total_size, contig_count)
    rng = random.Random(seed)

    with output_path.open("w", encoding="ascii", newline="\n") as output:
        for index, length in enumerate(lengths, start=1):
            output.write(f">chr{index}\n")
            write_random_sequence(output, length, line_width, rng)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Generate a random FASTA reference. --size is the total number of "
            "sequence bases, distributed evenly across all contigs."
        )
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=Path("pilot_reference.fa"),
        help="output FASTA path (default: %(default)s)",
    )
    parser.add_argument(
        "-c",
        "--contigs",
        "--chroms",
        dest="contigs",
        type=positive_int,
        default=DEFAULT_CONTIGS,
        help="number of contigs/chromosomes (default: %(default)s)",
    )
    parser.add_argument(
        "-s",
        "--size",
        type=positive_int,
        default=DEFAULT_SIZE,
        help="total sequence bases across all contigs (default: %(default)s)",
    )
    parser.add_argument(
        "--line-width",
        type=positive_int,
        default=DEFAULT_LINE_WIDTH,
        help="maximum sequence characters per FASTA line (default: %(default)s)",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=DEFAULT_SEED,
        help="random seed for reproducible output (default: %(default)s)",
    )
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    try:
        generate_fasta(
            output_path=args.output,
            total_size=args.size,
            contig_count=args.contigs,
            line_width=args.line_width,
            seed=args.seed,
        )
        print('run successfully')
    except (OSError, ValueError) as exc:
        parser.error(str(exc))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
