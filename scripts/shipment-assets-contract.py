"""Isolated public-asset proxy contract; no Saleor, provider or environment credentials."""
import json
import pathlib
import re
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid


def docker(*args):
    return subprocess.check_output(["docker", *args], text=True, stderr=subprocess.STDOUT).strip()


def main():
    source = pathlib.Path(__file__).with_name("reconcile-shipment-dev.sh").read_text()
    config = re.search(r"<<'NGINX'\n(.*?)\nNGINX", source, re.S).group(1)
    image = "nginx:1.31-alpine3.24"  # Same official release as the main media service.
    prefix = "shipment-assets-proof-" + uuid.uuid4().hex[:8]
    network = prefix
    containers = []
    docker("pull", image)
    docker("network", "create", network)
    try:
        with tempfile.TemporaryDirectory() as temporary:
            folder = pathlib.Path(temporary)
            proxy_config = folder / "proxy.conf"
            proxy_config.write_text(config)
            proxy_config.chmod(0o644)

            def upstream(version):
                name = prefix + "-" + version
                conf = folder / (version + ".conf")
                conf.write_text('pid /tmp/nginx.pid; events {} http { access_log off; '
                    'client_body_temp_path /tmp/client; proxy_temp_path /tmp/proxy; '
                    'fastcgi_temp_path /tmp/fastcgi; uwsgi_temp_path /tmp/uwsgi; scgi_temp_path /tmp/scgi; server { listen 3000; '
                    'location = /_nuxt/widget.js { default_type application/json; return 200 '
                    '\'{"version":"' + version + '","authorization":"$http_authorization","cookie":"$http_cookie"}\'; } '
                    'location / { return 404; } } }')
                conf.chmod(0o644)
                containers.append(name)
                docker("run", "-d", "--name", name, "--network", network, "--network-alias", "shipment-operator",
                    "--user", "101:101", "--read-only", "--cap-drop", "ALL", "--tmpfs", "/tmp",
                    "-v", str(conf) + ":/etc/nginx/proof.conf:ro", "--entrypoint", "nginx", image,
                    "-c", "/etc/nginx/proof.conf", "-g", "daemon off;")
                return name

            first = upstream("previous")
            first_ip = json.loads(docker("inspect", "--format", "{{json .NetworkSettings.Networks}}", first))[network]["IPAddress"]
            proxy = prefix + "-proxy"
            containers.append(proxy)
            docker("run", "-d", "--name", proxy, "--network", network, "--user", "101:101",
                "--read-only", "--cap-drop", "ALL", "--tmpfs", "/tmp", "-p", "127.0.0.1::8080",
                "-v", str(proxy_config) + ":/etc/nginx/proof.conf:ro", "--entrypoint", "nginx", image,
                "-c", "/etc/nginx/proof.conf", "-g", "daemon off;")
            port = docker("port", proxy, "8080/tcp").split(":")[-1]
            base = "http://127.0.0.1:" + port
            path = "/shipment-operator/assets/_nuxt/widget.js"

            def asset(version):
                for _ in range(30):
                    try:
                        request = urllib.request.Request(base + path, headers={"Authorization": "Bearer synthetic", "Cookie": "synthetic=1"})
                        with urllib.request.urlopen(request, timeout=2) as response:
                            body = json.load(response)
                        if body.get("version") == version:
                            assert body["authorization"] == body["cookie"] == "", body
                            return
                    except (urllib.error.URLError, json.JSONDecodeError):
                        pass
                    time.sleep(0.2)
                raise AssertionError("Asset proxy did not follow " + version)

            asset("previous")
            with urllib.request.urlopen(urllib.request.Request(base + path, method="HEAD"), timeout=2) as response:
                assert response.status == 200
            for target, method, status in [("/graphql/", "GET", 404),
                ("/shipment-operator/assets/_nuxt/../api/shipment-operator/order", "GET", 404),
                (path, "POST", 403)]:
                try:
                    urllib.request.urlopen(urllib.request.Request(base + target, method=method), timeout=2)
                    raise AssertionError("Unexpected allowed route")
                except urllib.error.HTTPError as error:
                    assert error.code == status, error.code
            docker("rm", "-f", first)
            def hold_address(label):
                name = prefix + "-hold-" + label
                containers.append(name)
                docker("run", "-d", "--name", name, "--network", network, "--entrypoint", "/bin/sh", image, "-c", "exec tail -f /dev/null")
            hold_address("previous")
            second = upstream("candidate")
            second_ip = json.loads(docker("inspect", "--format", "{{json .NetworkSettings.Networks}}", second))[network]["IPAddress"]
            assert second_ip != first_ip, "The replacement must exercise a different Docker IP"
            asset("candidate")
            docker("rm", "-f", second)
            hold_address("candidate")
            upstream("rollback")
            asset("rollback")
            print("Shipment asset contract passed: GET/HEAD, credential stripping, route isolation and replacement/rollback DNS.")
    except Exception:
        for name in containers:
            subprocess.run(["docker", "logs", name])
        raise
    finally:
        for name in reversed(containers):
            subprocess.run(["docker", "rm", "-f", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["docker", "network", "rm", network], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
