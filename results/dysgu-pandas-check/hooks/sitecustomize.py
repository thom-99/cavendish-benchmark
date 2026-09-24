import os
import sys
import warnings

if os.environ.get('DYSGU_STRICT') == '1':
    from pandas.errors import ChainedAssignmentError
    warnings.simplefilter('error', ChainedAssignmentError)

# Preserve each command's VCF before later test commands overwrite it.
if len(sys.argv) > 1 and sys.argv[1] == 'test':
    import json
    import pathlib
    import shutil
    import subprocess
    original = subprocess.Popen
    destination = pathlib.Path(os.environ['DYSGU_CAPTURE'])
    class CapturingPopen(original):
        counter = 0
        def wait(self, *args, **kwargs):
            result = super().wait(*args, **kwargs)
            if not getattr(self, '_captured', False):
                self._captured = True
                CapturingPopen.counter += 1
                number = CapturingPopen.counter
                command = self.args
                with (destination / 'commands.jsonl').open('a') as stream:
                    stream.write(json.dumps({'number': number, 'command': command, 'returncode': result}) + '\n')
                if '-o' in command:
                    output = pathlib.Path(command[command.index('-o') + 1])
                    if output.exists():
                        shutil.copyfile(output, destination / f'{number:02d}-{output.name}')
            return result
    subprocess.Popen = CapturingPopen
