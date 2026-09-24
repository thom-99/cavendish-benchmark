from pathlib import Path
import hashlib
import shutil
import sys
import dysgu
root = Path(__file__).resolve().parent
installed = next(Path(dysgu.__file__).parent.glob('cluster*.so'))
backup = root / 'original-binary' / installed.name
if not backup.exists():
    backup.parent.mkdir(exist_ok=True)
    shutil.copy2(installed, backup)
source = backup if sys.argv[1] == 'restore' else root / sys.argv[1] / 'dysgu' / installed.name
# Replace the file, avoiding any writes through Conda's possible hardlinks.
temporary = installed.with_suffix('.so.check-tmp')
shutil.copy2(source, temporary)
temporary.replace(installed)
print(installed, hashlib.sha256(installed.read_bytes()).hexdigest())
