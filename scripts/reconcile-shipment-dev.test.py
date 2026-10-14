"""Credential-free execution of the real Bash reconciler with isolated CLI fixtures."""
import json
import os
import pathlib
import re
import subprocess
import tempfile
import unittest

SOURCE = pathlib.Path(__file__).with_name("reconcile-shipment-dev.sh")
ACCOUNT = "462432303731"
REGISTRY = f"{ACCOUNT}.dkr.ecr.eu-north-1.amazonaws.com"

MOCK = r'''#!/usr/bin/env python3
import json,os,pathlib,sys,signal
a=sys.argv[1:]; name=pathlib.Path(sys.argv[0]).name
root=pathlib.Path(os.environ['FIXTURE']); s=json.loads((root/'state').read_text())
with (root/'calls').open('a') as f: f.write(json.dumps([name,*a])+'\n')
def out(v): print(json.dumps(v) if isinstance(v,(dict,list)) else v)
def option(k): return a[a.index(k)+1]
if name=='aws':
  if 'get-caller-identity' in a: out(s['account'])
  elif 'get-login-password' in a: out('fake-password')
  elif 'get-parameter' in a:
    key=option('--name').split('/')[-1]
    if key=='status': out(s['status'])
    elif key=='config': out(s['config'])
    else:
      if key==s.get('missing'): sys.exit(1)
      out('test-'+key)
elif name=='curl':
  if a[-1].endswith('/api/token'): out('metadata-token')
  elif a[-1].endswith('/instance-id'): out('i-dev')
  elif s.get('health_failure'): sys.exit(1)
  elif '/en/shipment-operator' in a[-1]: out('<script src="https://dev.terrahorse.lt/shipment-operator/assets/_nuxt/widget.js"></script>')
  elif '/assets/_nuxt/' in a[-1]:
    if s.get('asset_failure'): sys.exit(1)
    out('public widget asset')
  else: out({'status':'ok','service':'shipment-operator','version':'test-release'})
elif name=='openssl': pass
elif name=='docker':
  if a[0]=='login': sys.stdin.read()
  elif a[:2]==['network','inspect']: out([{'Driver':'bridge','Scope':'local','Containers':{x:{} for x in s['members']}}])
  elif a[0]=='ps': out('a'*12)
  elif a[0]=='inspect' and option('--format')=='{{.Image}}': out('sha256:'+'c'*64)
  elif a[0]=='inspect': out(s['members'][a[-1]])
  elif a[:2]==['image','inspect']: out(s.get('contract','1'))
  elif a[0]=='create': out('release-container')
  elif a[0]=='cp':
    filename=a[1].split('/')[-1]
    p=pathlib.Path(a[2])
    p.write_text(json.dumps(s['release']) if filename=='release.json' else 'services: {}\n')
  elif a[0]=='compose' and 'up' in a:
    countfile=root/'ups'; count=int(countfile.read_text())+1 if countfile.exists() else 1; countfile.write_text(str(count))
    if count==s.get('signal_on_up'): os.kill(os.getppid(),signal.SIGTERM)
    if s.get('rollback_failure') and count>=3: sys.exit(1)
    if count==1 and s.get('startup_failure'): sys.exit(1)
'''


class ReconcileTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = pathlib.Path(self.temp.name)
        self.runtime = self.folder / "runtime"
        self.state = {
            "account": ACCOUNT,
            "status": {"state": "succeeded", "instance_id": "i-dev", "release": f"{REGISTRY}/terrahorse-release@sha256:" + "a" * 64},
            "members": {"api": "terrahorse-ec2:api", "cache": "terrahorse-ec2:cache"},
            "release": {"release": "test-release", "storefront_image": f"{REGISTRY}/terrahorse@sha256:" + "b" * 64},
            "config": {
                "SHIPMENT_OPERATOR_PUBLIC_URL": "https://dev.terrahorse.lt",
                "SALEOR_DASHBOARD_URL": "https://dashboard-dev.terrahorse.lt/",
                "SALEOR_OPERATOR_API_URL": "https://api:8443/graphql/",
                "NUXT_PUBLIC_SALEOR_API_URL": "https://api-dev.terrahorse.lt/graphql/",
                "SALEOR_CHANNEL": "lt",
                "SALEOR_VENIPAK_PARCEL_LOCKER_METHOD_ID": "locker",
                "SALEOR_VENIPAK_COURIER_METHOD_ID": "courier",
            },
        }
        for name in ("aws", "docker", "curl", "openssl"):
            path = self.folder / name
            path.write_text(MOCK)
            path.chmod(0o755)
        ca = self.folder / "ca.crt"
        ca.touch()
        source = SOURCE.read_text().replace("root=/opt/terrahorse/shipment", f"root={self.runtime}").replace("certificate=/opt/terrahorse/data/tls/api.crt", f"certificate={ca}").replace("/run/terrahorse-reconcile.lock", str(self.folder / "lock"))
        self.script = self.folder / "reconcile.sh"
        self.script.write_text(source)

    def run_reconcile(self):
        (self.folder / "state").write_text(json.dumps(self.state))
        result = subprocess.run(["bash", str(self.script)], env={**os.environ, "PATH": f"{self.folder}:{os.environ['PATH']}", "FIXTURE": str(self.folder)}, capture_output=True, text=True)
        calls = [json.loads(line) for line in (self.folder / "calls").read_text().splitlines()]
        self.assertNotIn("fake-password", result.stdout + result.stderr)
        self.assertNotIn("test-SALEOR_COMMERCE_APP_TOKEN", result.stdout + result.stderr)
        return result, calls

    def test_success_and_unchanged_reconcile(self):
        result, _ = self.run_reconcile()
        self.assertEqual(result.returncode, 0, result.stderr)
        active = (self.runtime / "active").resolve()
        self.assertEqual((active / ".env").stat().st_mode & 0o777, 0o600)
        result, _ = self.run_reconcile()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.runtime / "active").resolve(), active)
        self.assertEqual(len(list((self.runtime / "releases").iterdir())), 1)

    def test_wrong_account_and_host_fail_before_docker(self):
        for field in ("account", "host"):
            with self.subTest(field=field):
                original = self.state["account"], self.state["status"]["instance_id"]
                if field == "account": self.state["account"] = "999999999999"
                else: self.state["status"]["instance_id"] = "i-prod"
                result, calls = self.run_reconcile()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(call[0] == "docker" for call in calls))
                self.state["account"], self.state["status"]["instance_id"] = original

    def test_unknown_network_member_and_missing_model_refuse_startup(self):
        for error in ("member", "model"):
            with self.subTest(error=error):
                self.state["members"].pop("unknown", None)
                self.state.pop("missing", None)
                if error == "member": self.state["members"]["unknown"] = "unrelated:service"
                else: self.state["missing"] = "SALEOR_SHIPMENT_PAGE_TYPE_ID"
                result, calls = self.run_reconcile()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(call[0] == "docker" and "up" in call for call in calls))

    def test_first_start_failure_tears_down(self):
        self.state["startup_failure"] = True
        result, calls = self.run_reconcile()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(any(call[0] == "docker" and "down" in call for call in calls))
        self.assertFalse((self.runtime / "active").exists())
        self.assertEqual(list((self.runtime / "releases").iterdir()), [])

    def test_termination_during_first_start_tears_down(self):
        self.state["signal_on_up"] = 1
        result, calls = self.run_reconcile()
        self.assertEqual(result.returncode, 143)
        self.assertTrue(any(call[0] == "docker" and "down" in call and "--remove-orphans" in call for call in calls))
        self.assertFalse((self.runtime / "active").exists())
        self.assertEqual(list((self.runtime / "releases").iterdir()), [])

    def test_termination_during_upgrade_restores_previous(self):
        result, _ = self.run_reconcile()
        self.assertEqual(result.returncode, 0, result.stderr)
        active = (self.runtime / "active").resolve()
        self.state["release"]["release"] = "new-release"
        self.state["signal_on_up"] = 2
        result, calls = self.run_reconcile()
        self.assertEqual(result.returncode, 143)
        self.assertEqual((self.runtime / "active").resolve(), active)
        self.assertIn(str(active / ".env"), calls[-1])
        self.assertIn("--remove-orphans", calls[-1])
        self.assertEqual(len(list((self.runtime / "releases").iterdir())), 1)

    def test_termination_during_cleanup_does_not_abandon_rollback(self):
        result, _ = self.run_reconcile()
        self.assertEqual(result.returncode, 0, result.stderr)
        active = (self.runtime / "active").resolve()
        self.state["release"]["release"] = "new-release"
        self.state["health_failure"] = True
        self.state["signal_on_up"] = 3
        result, calls = self.run_reconcile()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.runtime / "active").resolve(), active)
        self.assertIn(str(active / ".env"), calls[-1])
        self.assertEqual(len(list((self.runtime / "releases").iterdir())), 1)

    def test_failed_restore_stops_project_and_retains_diagnostics(self):
        result, _ = self.run_reconcile()
        self.assertEqual(result.returncode, 0, result.stderr)
        active = (self.runtime / "active").resolve()
        self.state["release"]["release"] = "new-release"
        self.state["health_failure"] = True
        self.state["rollback_failure"] = True
        result, calls = self.run_reconcile()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.runtime / "active").resolve(), active)
        self.assertIn("down", calls[-1])
        self.assertIn("--remove-orphans", calls[-1])
        self.assertEqual(len(list((self.runtime / "releases").iterdir())), 2)

    def test_regular_active_path_refuses_compose(self):
        self.runtime.mkdir()
        (self.runtime / "active").write_text("manual recovery marker")
        result, calls = self.run_reconcile()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call[0] == "docker" and "compose" in call for call in calls))

    def test_asset_overlay_is_kept_with_legacy_rollback(self):
        result, _ = self.run_reconcile()
        self.assertEqual(result.returncode, 0, result.stderr)
        active = (self.runtime / "active").resolve()
        overlay = active / "compose.shipment-assets.yml"
        overlay.unlink()
        self.state["release"]["release"] = "new-release"
        self.state["health_failure"] = True
        result, calls = self.run_reconcile()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("NUXT_APP_CDN_URL: https://dev.terrahorse.lt/shipment-operator/assets", overlay.read_text())
        self.assertIn(str(overlay), calls[-1])

    def test_asset_rule_preserves_storefront_assets_graphql_and_media(self):
        source = SOURCE.parent.parent.joinpath("aws/cloudflare.tf").read_text()
        pattern = re.findall(r'path\s*=\s*"(\^/[^"\n]+)"', source)[0]
        self.assertIsNotNone(re.fullmatch(pattern, "/shipment-operator/assets/_nuxt/widget.js"))
        for path in ("/_nuxt/widget.js", "/graphql/", "/media/product.jpg", "/api/shipment-operator/order"):
            self.assertIsNone(re.fullmatch(pattern, path))

    def test_unowned_or_mutable_release_refuses_pull(self):
        self.state["status"]["release"] = "unrelated.invalid/release:latest"
        result, calls = self.run_reconcile()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call[0] == "docker" for call in calls))

    def test_missing_channel_refuses_startup(self):
        self.state["config"].pop("SALEOR_CHANNEL")
        result, calls = self.run_reconcile()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call[0] == "docker" and "up" in call for call in calls))

    def test_dashboard_path_rule_preserves_existing_routes(self):
        source = SOURCE.parent.parent.joinpath("aws/cloudflare.tf").read_text()
        pattern = re.findall(r'path\s*=\s*"(\^/[^"\n]+)"', source)[1]
        for path in ("/en/shipment-operator", "/api/shipment-operator/manifest"):
            self.assertIsNotNone(re.fullmatch(pattern, path))
        for path in ("/dashboard/orders", "/dashboard/assets/index.js", "/_nuxt/widget.js", "/graphql/", "/api/payment/start", "/health"):
            self.assertIsNone(re.fullmatch(pattern, path))

    def test_incompatible_bundle_and_wrong_origin_refuse_startup(self):
        for error in ("contract", "origin"):
            with self.subTest(error=error):
                self.state["contract"] = "0" if error == "contract" else "1"
                self.state["config"]["SHIPMENT_OPERATOR_PUBLIC_URL"] = "https://unexpected.invalid" if error == "origin" else "https://dev.terrahorse.lt"
                result, calls = self.run_reconcile()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(call[0] == "docker" and "up" in call for call in calls))

    def test_failed_upgrade_restores_previous(self):
        result, _ = self.run_reconcile()
        self.assertEqual(result.returncode, 0, result.stderr)
        active = (self.runtime / "active").resolve()
        self.state["release"]["release"] = "new-release"
        self.state["health_failure"] = True
        result, calls = self.run_reconcile()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.runtime / "active").resolve(), active)
        self.assertEqual(calls[-1][0], "docker")
        self.assertIn(str(active / ".env"), calls[-1])
        self.assertEqual(len(list((self.runtime / "releases").iterdir())), 1)

    def test_failed_asset_probe_restores_previous(self):
        result, _ = self.run_reconcile()
        self.assertEqual(result.returncode, 0, result.stderr)
        active = (self.runtime / "active").resolve()
        self.state["release"]["release"] = "new-release"
        self.state["asset_failure"] = True
        result, calls = self.run_reconcile()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.runtime / "active").resolve(), active)
        self.assertIn(str(active / ".env"), calls[-1])


if __name__ == "__main__":
    unittest.main()
