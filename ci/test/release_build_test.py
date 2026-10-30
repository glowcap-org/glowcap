"""Exercise release SDK selection at the workflow's actual shell boundary."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from workflow_test import ROOT, shell_step


class ReleaseBuild(unittest.TestCase):
    def test_archive_build_selects_the_sdk_only_on_macos(self):
        script = shell_step((ROOT / '.github/workflows/release.yml').read_text(),
                            'Build the release tarball')
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            log = directory / 'arguments.json'
            sdk = directory / 'SDK with spaces'
            for name, source in {
                'zig': '#!/usr/bin/env python3\nimport json,os,sys\n'
                       'open(os.environ["ARGUMENT_LOG"], "w").write(json.dumps(sys.argv[1:]))\n',
                'xcrun': '#!/bin/bash\n[[ "$*" == "--sdk macosx --show-sdk-path" ]] || exit 2\n'
                         '[[ "$SDK_FAIL" == 0 ]] || exit 1\nprintf "%s\\n" "$SDK_PATH"\n',
            }.items():
                path = directory / name
                path.write_text(source)
                path.chmod(0o755)
            for runner, failed in [('Linux', False), ('macOS', False), ('macOS', True)]:
                with self.subTest(runner=runner, sdk_failed=failed):
                    log.unlink(missing_ok=True)
                    target = 'aarch64-macos.15.0' if runner == 'macOS' else 'aarch64-linux-gnu.2.39'
                    env = dict(os.environ, PATH=str(directory) + os.pathsep + os.environ['PATH'],
                               RUNNER_OS=runner, SDK_FAIL=str(int(failed)), SDK_PATH=str(sdk),
                               ARGUMENT_LOG=str(log))
                    result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c',
                                             script.replace('${{ matrix.target }}', target)],
                                            cwd=directory, env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode == 0, not failed, result.stderr)
                    if failed:
                        self.assertFalse(log.exists())
                        continue
                    expected = ['build', '-Doptimize=ReleaseSafe', 'release-pack', 'glowcap-pack',
                                '-Dcpu=baseline', '-Dtarget=' + target]
                    if runner == 'macOS':
                        expected += ['--sysroot', str(sdk)]
                    self.assertEqual(json.loads(log.read_text()), expected)
