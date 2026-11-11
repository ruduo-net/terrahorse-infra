from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "aws/invoice/refresh-dev-credentials.sh"


class RefreshInvoiceCredentialsTest(unittest.TestCase):
    def test_refresh_replaces_only_valid_role_credentials(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            directory = Path(temporary_directory)
            mock_aws = directory / "aws"
            mock_aws.write_text(
                "#!/bin/sh\n"
                'test "$1 $2" = "sts assume-role" || exit 1\n'
                'test "$4" = "arn:aws:iam::123456789012:role/terrahorse-invoice-dev" || exit 1\n'
                'test "$8" = "eu-north-1" || exit 1\n'
                'printf "%s\\n" "$MOCK_CREDENTIALS"\n'
                'exit "$MOCK_STS_STATUS"\n'
            )
            mock_aws.chmod(0o700)
            runtime_dir = directory / "runtime"
            runtime_dir.mkdir()
            script = directory / "refresh"
            script.write_text(
                SCRIPT.read_text().replace("/run/terrahorse-invoice", str(runtime_dir))
            )
            target = runtime_dir / "credentials.json"
            credentials = {
                "AccessKeyId": "test-access-key",
                "SecretAccessKey": "test-secret-key",
                "SessionToken": "test-session-token",
                "Expiration": (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat(),
            }

            def refresh(value, sts_status=0):
                return subprocess.run(
                    ["bash", str(script),
                     "arn:aws:iam::123456789012:role/terrahorse-invoice-dev", "eu-north-1"],
                    env={
                        **os.environ,
                        "PATH": f"{directory}{os.pathsep}{os.environ['PATH']}",
                        "MOCK_CREDENTIALS": json.dumps(value),
                        "MOCK_STS_STATUS": str(sts_status),
                    },
                    capture_output=True,
                    text=True,
                    check=False,
                )

            first = refresh(credentials)
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(first.stdout, "")
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o640)
            with target.open() as original:
                rotated = {**credentials, "SessionToken": "rotated-session"}
                self.assertEqual(refresh(rotated).returncode, 0)
                self.assertEqual(json.load(original), {**credentials, "Version": 1})

            self.assertNotEqual(refresh({"Expiration": "missing keys"}).returncode, 0)
            expired = {**credentials, "Expiration": "2000-01-01T00:00:00Z"}
            self.assertNotEqual(refresh(expired).returncode, 0)
            self.assertNotEqual(refresh(credentials, sts_status=1).returncode, 0)
            self.assertEqual(json.loads(target.read_text()), {**rotated, "Version": 1})
            self.assertEqual(list(runtime_dir.iterdir()), [target])


if __name__ == "__main__":
    unittest.main()
