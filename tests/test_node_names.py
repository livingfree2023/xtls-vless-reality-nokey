"""Exercise node-name prompting through a real controlling terminal."""
import os
import pty
import select
import time
from pathlib import Path

repo = str(Path(__file__).resolve().parent.parent)
for entered, country, expected in [('\n', 'HK', '🇭🇰HK.test-host.SS.V6'), ('WAWO200\n', 'HK', '🇭🇰HK.WAWO200.SS.V6'), ('WAWO200\n', '', 'WAWO200.SS.V6')]:
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(repo)
        command = '''source ./nokey.sh
current_hostname=test-host
curl() { printf '{"country":"%s"}' "$TEST_COUNTRY"; }
prepare_node_identity
printf 'RESULT:%s\\n' "$(format_node_name SS 6)"
'''
        os.environ['TEST_COUNTRY'] = country
        os.execvp('bash', ['bash', '-c', command])
    output = b''
    sent = False
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if not select.select([fd], [], [], 0.2)[0]:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        output += chunk
        if b'Node name [test-host]:' in output and not sent:
            os.write(fd, entered.encode())
            sent = True
    if not sent or ('RESULT:' + expected).encode() not in output:
        os.kill(pid, 9)
        raise AssertionError(output.decode(errors='replace'))
    _, status = os.waitpid(pid, 0)
    os.close(fd)
    assert status == 0
print('PASS: real TTY default/custom names and invalid-country fallback')
