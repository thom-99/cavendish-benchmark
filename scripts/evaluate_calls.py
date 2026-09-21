"""Run the symbolic-VCF evaluation described in truvari.md from the project root."""

import csv
import hashlib
import json
import subprocess
import tempfile
from collections import Counter
from importlib.metadata import version
from pathlib import Path

import pysam
import truvari


CALLERS = ("sniffles", "cutesv", "dysgu")
MODES = ("primary", "dup-to-ins")
TYPES = {"INS", "DEL", "DUP", "INV"}
PREP = Path("data/evaluation")
REPORT = Path("results/report/metrics.tsv")
OPTIONS = [
    "--pick", "single", "--passonly", "--sizemin", "50",
    "--sizefilt", "50", "--sizemax", "-1", "--refdist", "500",
    "--pctsize", "0.7", "--pctseq", "0", "--pctovl", "0",
    "--no-decompose",
]


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def main():
    sources = {"truth": Path("data/simulated/truth.vcf")}
    sources.update({c: Path(f"data/variant_calls/{c}.vcf.gz") for c in CALLERS})
    outputs = [Path(f"results/truvari/{c}/{m}") for c in CALLERS for m in MODES]
    for source in sources.values():
        if not source.is_file():
            raise SystemExit(f"Missing input: {source}")
    for target in [PREP, REPORT, *outputs]:
        if target.exists():
            raise SystemExit(f"Refusing to overwrite {target}; archive it before rerunning.")

    PREP.mkdir(parents=True)
    manifest = {
        "versions": {name: version(name) for name in ("truvari", "pysam")},
        "bcftools": subprocess.check_output(["bcftools", "--version"], text=True).splitlines()[0],
        "common_options": OPTIONS,
        "inputs": {},
        "runs": [],
    }
    for name, source in sources.items():
        counts = Counter()
        types = Counter()
        with source.open("rb") as handle:
            checksum = hashlib.file_digest(handle, "sha256").hexdigest()
        prepared = PREP / f"{name}.vcf.gz"
        with tempfile.TemporaryDirectory(prefix="prepare-", dir=PREP) as tmp:
            filtered = Path(tmp) / "typed.vcf"
            with pysam.VariantFile(str(source)) as src:
                with pysam.VariantFile(str(filtered), "w", header=src.header) as dst:
                    for record in src:
                        svtype = record.info.get("SVTYPE", "UNKNOWN")
                        types[svtype] += 1
                        counts["input"] += 1
                        if svtype not in TYPES:
                            counts["excluded_type"] += 1
                            continue
                        dst.write(record)
                        counts["prepared"] += 1
                        # Follow the installed Truvari's FILTER and size semantics.
                        wrapped = truvari.VariantRecord(record)
                        if wrapped.is_filtered():
                            counts["excluded_filter"] += 1
                        elif wrapped.var_size() < 50:
                            counts["excluded_size"] += 1
                        else:
                            counts["eligible"] += 1
            run("bcftools", "sort", "-Oz", "-o", prepared, filtered)
        run("bcftools", "index", "--tbi", prepared)
        manifest["inputs"][name] = {
            "path": str(source), "sha256": checksum,
            "prepared_path": str(prepared), "counts": dict(counts),
            "input_types": dict(types),
        }
    manifest_path = PREP / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")

    rows = []
    for caller in CALLERS:
        for mode in MODES:
            output = Path(f"results/truvari/{caller}/{mode}")
            output.parent.mkdir(parents=True, exist_ok=True)
            command = [
                "truvari", "bench", "--base", str(PREP / "truth.vcf.gz"),
                "--comp", str(PREP / f"{caller}.vcf.gz"),
                "--output", str(output), *OPTIONS,
            ]
            if mode == "dup-to-ins":
                command.append("--dup-to-ins")
            run(*command)
            summary = json.loads((output / "summary.json").read_text())
            for kind, key in (("tp-base", "TP-base"), ("tp-comp", "TP-comp"),
                              ("fn", "FN"), ("fp", "FP")):
                vcf = output / f"{kind}.vcf.gz"
                with pysam.VariantFile(str(vcf)) as records:
                    count = sum(1 for _ in records)
                if count != summary[key] or not Path(f"{vcf}.tbi").is_file():
                    raise RuntimeError(f"Output validation failed: {vcf}")
            if summary["base cnt"] != manifest["inputs"]["truth"]["counts"].get("eligible", 0):
                raise RuntimeError(f"Unexpected truth denominator: {output}")
            if summary["comp cnt"] != manifest["inputs"][caller]["counts"].get("eligible", 0):
                raise RuntimeError(f"Unexpected caller denominator: {output}")
            # Refinement is not part of this symbolic-allele benchmark.
            (output / "candidate.refine.bed").unlink(missing_ok=True)
            manifest["runs"].append({"caller": caller, "mode": mode, "command": command})
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
            rows.append({"caller": caller, "analysis": mode, **{
                key: summary[key] for key in (
                    "TP-base", "TP-comp", "FP", "FN", "base cnt", "comp cnt",
                    "precision", "recall", "f1",
                )
            }})
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    with REPORT.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]), delimiter="\t")
        writer.writeheader()
        writer.writerows(rows)
    print(f"Evaluation complete: {REPORT}")


if __name__ == "__main__":
    main()
