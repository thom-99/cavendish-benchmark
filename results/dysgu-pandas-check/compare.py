from pathlib import Path
import hashlib
import json
import subprocess
root = Path(__file__).resolve().parent
stages = ['original', 'original-strict', 'rebuilt-original-normal', 'patched-normal', 'patched-strict', 'patched-all-warnings-strict']
summary = {}
for stage in stages:
    path = root / stage
    commands = [json.loads(line) for line in (path/'commands.jsonl').read_text().splitlines()]
    log = (path/'test.log').read_text()
    summary[stage] = {
        'commands_passed': sum(c['returncode'] == 0 for c in commands),
        'commands_failed': sum(c['returncode'] != 0 for c in commands),
        'chained_assignment_occurrences': log.count('ChainedAssignmentError:'),
        'runner_exit': int((path/'runner-exit.txt').read_text()),
    }
    assert len(commands) == 7
comparisons = []
for stage in ['rebuilt-original-normal', 'patched-normal', 'patched-strict', 'patched-all-warnings-strict']:
    assert summary[stage]['commands_passed'] == 7
    for original in sorted((root/'original').glob('*.vcf')):
        output = root / stage / original.name
        comparison = subprocess.run(['cmp', '--', str(original), str(output)], capture_output=True, text=True)
        assert comparison.returncode == 0, (stage, original.name, comparison.stdout)
        comparisons.append({'stage': stage, 'file': original.name, 'bytes': original.stat().st_size,
                            'cmp_exit': comparison.returncode,
                            'sha256': hashlib.sha256(output.read_bytes()).hexdigest()})
for stage in ['patched-normal', 'patched-strict', 'patched-all-warnings-strict']:
    assert summary[stage]['chained_assignment_occurrences'] == 0
report = {'runs': summary, 'byte_comparisons': comparisons}
(root/'comparison.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(summary, indent=2))
print(f'{len(comparisons)} full-file cmp comparisons passed (six per-command VCFs and four final VCFs per run).')
