import os
from pathlib import Path
import shutil
import subprocess
import sys
root = Path(__file__).resolve().parent
stage = root / sys.argv[1]
stage.mkdir(exist_ok=True)
run = root / 'run'
shutil.rmtree(run)
run.mkdir()
env = dict(os.environ, PYTHONPATH=str(root / 'hooks'), DYSGU_CAPTURE=str(stage), DYSGU_STRICT='1' if 'strict' in sys.argv[1] else '0')
with (stage / 'test.log').open('w') as log:
    result = subprocess.run(['dysgu', 'test', '--verbose'], cwd=run, env=env, stdout=log, stderr=subprocess.STDOUT)
(stage / 'runner-exit.txt').write_text(str(result.returncode) + '\n')
for vcf in run.glob('*.vcf'):
    shutil.copyfile(vcf, stage / vcf.name)
print(stage, 'runner exit:', result.returncode)
