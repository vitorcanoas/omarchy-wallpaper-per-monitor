"""Linux boundary regressions; all configuration changes use throwaway homes."""
import importlib.util
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'bin/wallpaper-monitor-config.py'


class Boundaries(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='wpm-test-', dir=Path.home())
        self.home = Path(self.tmp.name)
        self.env = dict(os.environ, HOME=str(self.home), XDG_RUNTIME_DIR=str(self.home))

    def tearDown(self):
        self.tmp.cleanup()

    def helper(self, *args, **kwargs):
        return subprocess.run(['/usr/bin/python3', '-I', '-B', str(HELPER), *map(str,args)],
                              env=self.env, capture_output=True, timeout=12, **kwargs)

    def test_environment_startup(self):
        marker = self.home / 'executed'
        startup = self.home / 'startup'
        startup.write_text(f'printf injected > {marker}\n')
        fake = self.home / 'python'
        fake.write_text(f'#!/usr/bin/bash\nprintf injected > {marker}\n')
        fake.chmod(0o700)
        for entry in ['install.sh', 'uninstall.sh', 'bin/wp', 'bin/wallpaper-monitor', 'bin/wallpaper-monitor-menu']:
            env = dict(self.env, BASH_ENV=str(startup), PYTHON3=str(fake), DRY_RUN='invalid')
            subprocess.run([str(ROOT / entry), '--help'], env=env, capture_output=True, timeout=12)
            self.assertFalse(marker.exists(), entry)

    def test_read_boundaries(self):
        target = self.home / 'config'
        for kind in ['symlink', 'fifo', 'oversized', 'writable']:
            if kind == 'symlink': target.symlink_to('/etc/passwd')
            elif kind == 'fifo': os.mkfifo(target)
            else:
                target.write_bytes(b'x' * (262145 if kind == 'oversized' else 1))
                if kind == 'writable': target.chmod(0o666)
            result = self.helper('read', '--root', self.home, '--rel', 'config')
            self.assertEqual(result.returncode, 1, (kind, result.stderr))
            self.assertEqual(result.stdout, b'')
            target.unlink()
        target.write_text('{"monitors": {}}')
        self.assertEqual(self.helper('read', '--root', self.home, '--rel', 'config').returncode, 0)
        (self.home / 'link').symlink_to(self.home, target_is_directory=True)
        self.assertEqual(self.helper('read', '--root', self.home, '--rel', 'link/config').returncode, 1)

    def test_resolve_external_link(self):
        target = self.home / 'image.png'; target.write_bytes(b'image')
        root = self.home / 'root'; root.mkdir()
        (root / 'background').symlink_to(target)
        r = self.helper('resolve-link', '--root', root, '--rel', 'background', '--require-regular')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), str(target).encode())
        target.unlink()
        self.assertNotEqual(self.helper('resolve-link', '--root', root, '--rel', 'background',
                                        '--require-regular').returncode, 0)
        self.assertNotEqual(self.helper('resolve-link', '--root', '/', '--rel',
                                        'nonexistent-wallpaper-test', '--require-regular').returncode, 0)

    def test_process_budgets(self):
        cases = [("print('ok')", 0),
                 ("import os; os.write(1,b'x'*65536)", 6),
                 ("import os; os.write(2,b'x'*65536)", 6),
                 ("import time; time.sleep(5)", 7)]
        for code, expected in cases:
            r = self.helper('run', '--setsid', '--deadline-ms', 400,
                            '--kill-grace-ms', 100, '--max-output-bytes', 1024,
                            '--', '/usr/bin/python3', '-I', '-c', code)
            self.assertEqual(r.returncode, expected, r.stderr)

    def test_stalled_stderr_does_not_delay_cleanup(self):
        code = "import os,time; os.write(2,(b'x'*3000+b'\\n')*4); time.sleep(5)"
        child = subprocess.Popen(['/usr/bin/python3', '-I', '-B', str(HELPER),
            'run', '--setsid', '--deadline-ms', '200', '--kill-grace-ms', '100',
            '--', '/usr/bin/python3', '-I', '-c', code], env=self.env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        fcntl.fcntl(child.stderr.fileno(), fcntl.F_SETPIPE_SZ, 4096)
        try:
            self.assertEqual(child.wait(timeout=2), 7)
        finally:
            if child.poll() is None: child.kill()
            child.communicate(timeout=3)

    def test_descendants_reaped(self):
        for detach in [False, True]:
            for success in [False, True]:
                pidfile = self.home / 'pid'
                code = f'''import os, signal, time
p = os.fork()
if p == 0:
    {"os.setsid()" if detach else "pass"}
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    open({str(pidfile)!r}, 'w').write(str(os.getpid()))
    os.close(1)
    os.close(2)
    time.sleep(8)
else:
    time.sleep(0.1)
    {"pass" if success else "time.sleep(8)"}
'''
                pid = None
                try:
                    r = self.helper('run', '--setsid', '--deadline-ms', 500,
                                    '--kill-grace-ms', 100, '--', '/usr/bin/python3', '-I', '-c', code)
                    pid = int(pidfile.read_text())
                    self.assertEqual(r.returncode, 0 if success else 7, r.stderr)
                    self.assertFalse(Path(f'/proc/{pid}').exists(), (detach, success, pid))
                finally:
                    if pid is not None:
                        try: os.kill(pid, signal.SIGKILL)
                        except ProcessLookupError: pass
                    pidfile.unlink(missing_ok=True)

    def test_signal_reaps_descendants(self):
        pidfile = self.home / 'signalled-child'
        code = f"import os,signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); open({str(pidfile)!r},'w').write(str(os.getpid())); time.sleep(8)"
        helper = subprocess.Popen(['/usr/bin/python3', '-I', '-B', str(HELPER),
            'run', '--setsid', '--deadline-ms', '5000', '--kill-grace-ms', '100',
            '--', '/usr/bin/python3', '-I', '-c', code], env=self.env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        pid = None
        try:
            for _ in range(100):
                if pidfile.exists(): break
                time.sleep(.01)
            pid = int(pidfile.read_text())
            helper.terminate()
            helper.communicate(timeout=3)
            self.assertEqual(helper.returncode, 143)
            self.assertFalse(Path(f'/proc/{pid}').exists())
        finally:
            if helper.poll() is None: helper.kill(); helper.communicate()
            if pid:
                try: os.kill(pid, signal.SIGKILL)
                except ProcessLookupError: pass

    def test_prune_rejects_writable_directory(self):
        (self.home / 'tree/sub').mkdir(parents=True)
        (self.home / 'tree/sub/keep').write_text('keep')
        (self.home / 'tree/sub').chmod(0o777)
        r = self.helper('prune-dir', '--root', self.home, '--rel', 'tree', '--remove-all')
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertTrue((self.home / 'tree/sub/keep').exists())

    def test_parent_descriptor_survives_swap(self):
        spec = importlib.util.spec_from_file_location('wpm_helper', HELPER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        parent = self.home / 'parent'; parent.mkdir()
        (parent / 'config').write_text('{}')
        fd, name = module.open_parent(str(self.home), 'parent/config')
        original, info = module.open_target_file(fd, name, 1024)
        try:
            parent.rename(self.home / 'held')
            parent.symlink_to(self.home / 'elsewhere', target_is_directory=True)
            (self.home / 'elsewhere').mkdir()
            module.publish(fd, name, b'{"ok":true}', info, 0o644)
            self.assertEqual((self.home / 'held/config').read_bytes(), b'{"ok":true}')
            self.assertFalse((self.home / 'elsewhere/config').exists())
        finally:
            os.close(original); os.close(fd)

    def test_install_cli_uninstall(self):
        for command in ['install.sh', 'install.sh']:
            r = subprocess.run([str(ROOT / command)], env=self.env, capture_output=True, timeout=30)
            self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        config = self.home / '.config/omarchy/background-per-monitor.json'
        config.write_text('{"monitors": {"DP-1":"/a.png","DP-2":"/b.png"}}')
        cli = self.home / '.local/bin/wallpaper-monitor'
        children = [subprocess.Popen([str(cli), 'clear', name], env=self.env,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE) for name in ['DP-1','DP-2']]
        for child in children:
            out, err = child.communicate(timeout=15)
            self.assertEqual(child.returncode, 0, err + out)
        self.assertEqual(json.loads(config.read_text())['monitors'], {})
        for command in ['uninstall.sh', 'uninstall.sh']:
            r = subprocess.run([str(ROOT / command)], env=self.env, capture_output=True, timeout=30)
            self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertFalse(cli.is_symlink())


if __name__ == '__main__':
    unittest.main()
