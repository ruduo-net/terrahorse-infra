"""Exercise startup without Docker, credentials, registration, or live jobs."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("start-pr-runner.sh")
STUB = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['FIXTURE_LOG'], 'a') as log:
    log.write(json.dumps([name, *args]) + '\n')
state = json.loads(os.environ['FIXTURE_STATE'])
if name == 'uname':
    print('Darwin' if args == ['-s'] else 'arm64')
elif name == 'docker':
    if args[:2] == ['context', 'show']:
        print('desktop-linux')
    elif args[:2] == ['context', 'inspect']:
        print('unix://' + os.environ['HOME'] + '/.docker/run/docker.sock')
    elif args[:1] == ['info']:
        print('docker-desktop|Docker Desktop|aarch64')
    elif 'ps' in args:
        if state.get('ps_failure'):
            sys.exit(1)
        if state.get('running') and args[-1] == 'application-runner':
            print('fixture-running-container')
    elif 'RUNNER_PREFLIGHT_ONLY=1' in args:
        if 'exec' in args:
            sys.exit(state.get('exec_status', 0))
        if state.get('empty'):
            sys.exit(10)
elif name == 'gh':
    if 'registration-token' in ' '.join(args):
        print('fixture-registration-token')
    elif '--jq' in args:
        query = args[args.index('--jq') + 1]
        if '[.id,' in query and not state.get('no_remote'):
            label = ('terrahorse-pr-app' if 'terrahorse-m4-app' in query else
                     'terrahorse-pr-runtime' if 'terrahorse-m4-runtime' in query
                     else 'terrahorse-deploy')
            busy = 'true' if state.get('busy') and label == 'terrahorse-pr-app' else 'false'
            print('123\t' + busy + '\t' + ('wrong' if state.get('bad_label') else label))
'''


class StartupTest(unittest.TestCase):
    def run_start(self, **state):
        with tempfile.TemporaryDirectory(prefix="runner-start-test-") as directory:
            root = Path(directory)
            for name in ("docker", "gh", "uname"):
                stub = root / name
                stub.write_text(STUB)
                stub.chmod(0o755)
            log = root / "calls.jsonl"
            env = dict(os.environ, PATH=directory + os.pathsep + os.environ["PATH"],
                       FIXTURE_LOG=str(log), FIXTURE_STATE=json.dumps(state))
            for key in ("DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_DEFAULT_PLATFORM"):
                env.pop(key, None)
            result = subprocess.run(["sh", str(SCRIPT)], env=env,
                                    capture_output=True, text=True)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            return result, calls

    def assert_started(self, result, calls, registrations=0):
        self.assertEqual(result.returncode, 0, result.stderr)
        starts = [call for call in calls if call[0] == "docker" and "up" in call]
        self.assertEqual(len(starts), 2)
        self.assertTrue(all("--no-recreate" in call for call in starts))
        tokens = [call for call in calls if call[0] == "gh"
                  and "registration-token" in " ".join(call)]
        self.assertEqual(len(tokens), registrations)

    def assert_refused(self, result, calls):
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call[0] == "docker" and "up" in call for call in calls))
        self.assertFalse(any("registration-token" in " ".join(call) for call in calls))

    def test_busy_running_application_does_not_block_stopped_deployer(self):
        result, calls = self.run_start(running=True, busy=True)
        self.assert_started(result, calls)
        checks = [call for call in calls if "RUNNER_PREFLIGHT_ONLY=1" in call]
        self.assertEqual(len(checks), 3)
        self.assertIn("exec", checks[0])
        self.assertIn("RUNNER_EXPECTED_ID=123", checks[0])
        self.assertIn("RUNNER_NAME=terrahorse-m4-app", checks[0])
        self.assertNotIn("run", checks[0])
        self.assertEqual(checks[-1][-1], "deployment-runner")

    def test_idle_running_application_is_checked_in_place(self):
        result, calls = self.run_start(running=True)
        self.assert_started(result, calls)
        self.assertEqual(sum("exec" in call for call in calls), 1)

    def test_existing_stopped_runners_need_no_tokens(self):
        self.assert_started(*self.run_start())

    def test_new_runners_are_registered_before_start(self):
        self.assert_started(*self.run_start(no_remote=True, empty=True), registrations=3)

    def test_busy_runner_without_running_container_is_rejected(self):
        self.assert_refused(*self.run_start(busy=True))

    def test_unreadable_container_state_is_rejected(self):
        self.assert_refused(*self.run_start(ps_failure=True))

    def test_running_registration_mismatch_is_rejected(self):
        self.assert_refused(*self.run_start(running=True, busy=True, exec_status=1))

    def test_busy_runner_label_mismatch_is_rejected(self):
        self.assert_refused(*self.run_start(running=True, busy=True, bad_label=True))

    def test_running_container_without_remote_registration_is_rejected(self):
        self.assert_refused(*self.run_start(running=True, no_remote=True))

    def test_registered_runner_missing_local_state_is_rejected(self):
        self.assert_refused(*self.run_start(empty=True))

    def test_local_state_missing_remote_registration_is_rejected(self):
        self.assert_refused(*self.run_start(no_remote=True))


if __name__ == "__main__":
    unittest.main()
