# dysgu pandas warning verification

Tested on 2026-09-24 using the existing Pixi environment: dysgu 1.9.0,
pandas 3.0.5, Python 3.11.16. Every suite invoked `dysgu test --verbose`
through `pixi run python run_suite.py STAGE`, using dysgu's installed test data.

The proposed one-line fix removes the warning and preserves every VCF byte.

| Run | Commands passed | Commands failed | ChainedAssignmentError occurrences |
| --- | ---: | ---: | ---: |
| Installed original | 7 | 0 | 4 |
| Original, targeted warning as error | 2 | 5 | 4 |
| Unedited local rebuild (compiler control) | 7 | 0 | 4 |
| Patched | 7 | 0 | 0 |
| Patched, targeted warning as error | 7 | 0 | 0 |
| Patched, all warnings as errors (`PYTHONWARNINGS=error`) | 7 | 0 | 0 |

The original strict run had four calls fail on ChainedAssignmentError, followed
by merge failure on empty input VCFs. The test runner itself returns zero even
when child commands fail; `commands.jsonl` records each child's actual status.

`compare.py` ran GNU `cmp` against the installed original's outputs. All six
per-command VCF snapshots and four final VCFs matched for the unedited rebuild
and all three patched runs: 40 full-file comparisons, all exit status zero.
This includes the PacBio and single-/two-process region outputs, which the
built-in test overwrites. Full headers and records were compared without
normalization, sorting, stripping, or other modification. Logs differ as
expected because of timestamps, durations, and the removed warnings.
`comparison.json` contains byte sizes, SHA-256 digests, and comparison results.

## Source and build isolation

Source: https://github.com/kcleal/dysgu/archive/v1.9.0.tar.gz

Archive SHA-256:
`7557365bb066026f8a373a1adaf1d34d74e72dcacc8d60ecfea20c465d0e32dc`

The archive hash matches the installed Conda package's recipe. Comparing every
original archive file against the extracted tree confirmed that only
`dysgu/cluster.pyx` changed. The exact diff is `proposed-change.diff`:

```diff
-        df["sample"] = [sample_name] * len(df)
+        df = df.assign(sample=sample_name)
```

`build_cluster.py` builds only the cluster extension using local Cython 3.3.0,
setuptools, g++, and the existing Pixi headers/libraries. Both original and
patched source were built identically. Other dysgu modules, test data, and
Pixi dependency files were unchanged. The unedited rebuild reproduces the
warning and all installed-original VCFs, controlling for the rebuild itself.

`hooks/sitecustomize.py` records child exit codes and copies each output after
the child finishes. Strict runs install an error filter specifically for
`pandas.errors.ChainedAssignmentError`; the additional all-warnings run also
sets `PYTHONWARNINGS=error`. All stages use the same working directory and
installed package paths to avoid introducing path differences in VCF headers.

The initial sandbox attempt blocked multiprocessing sockets. All reported
runs were rerun with socket access enabled.

## Retained artifacts and environment state

Each named run directory contains its full `test.log`, `commands.jsonl`, six
numbered VCF snapshots, and four final VCFs. Build scripts, build logs, original
and patched binaries, source archive, and edited source are retained here.

The installed original cluster binary was restored after testing and verified
with `cmp` against its backup. Its SHA-256 is:
`1c7d768886f40f5ee752f1b5b02efca5471ce72dd087b7bb526890e4b24cd1b3`.
No tracked repository files changed. The local source copy retains the patch.

To repeat the byte verification from the repository root:

```sh
pixi run python results/dysgu-pandas-check/compare.py
```

These results cover dysgu's bundled test data; they do not establish equivalence
for every possible input dataset.
