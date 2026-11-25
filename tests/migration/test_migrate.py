#!/usr/bin/env python3
"""
Tests for migrate-from-huly.sh that need no running Docker daemon (only the docker
compose CLI, for `docker compose config`). Each test builds an upstream Huly folder from
the pristine files in migration/huly-v0.7.426, changes it the way a user would, runs the
migration with --dry-run against a copy of this repository and checks the staged result.

Run: python3 -m unittest discover -s tests/migration -v
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BASE = os.path.join(REPO, "migration", "huly-v0.7.426")
sys.path.insert(0, os.path.join(REPO, "migration"))
sys.path.insert(0, os.path.dirname(__file__))

import customize_huly  # noqa: E402
import huly_migrate  # noqa: E402

CONF = {
    "HOST_ADDRESS": "huly.example.com", "SECURE": "true", "HTTP_PORT": "8090", "HTTP_BIND": "127.0.0.1",
    "TITLE": "Huly", "DEFAULT_LANGUAGE": "en", "LAST_NAME_FIRST": "true", "CR_DATABASE": "defaultdb",
    "CR_USERNAME": "selfhost", "COCKROACH_SECRET": "cr-secret", "REDPANDA_ADMIN_USER": "superadmin",
    "REDPANDA_SECRET": "rp-secret", "HULY_SECRET": "huly-secret", "VOLUME_ELASTIC_PATH": "",
    "VOLUME_FILES_PATH": "", "VOLUME_CR_DATA_PATH": "", "VOLUME_CR_CERTS_PATH": "", "VOLUME_REDPANDA_PATH": "",
}


def tree_hash(path):
    h = hashlib.sha256()
    for root, dirs, files in os.walk(path):
        dirs[:] = sorted(d for d in dirs if d not in (".git", ".migration", "__pycache__"))
        for name in sorted(files):
            full = os.path.join(root, name)
            h.update(os.path.relpath(full, path).encode())
            if not os.path.islink(full):
                h.update(open(full, "rb").read())
    return h.hexdigest()


class MigrationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="migrate-test-")
        self.huly = os.path.join(self.tmp, "huly-selfhost")
        self.repo = os.path.join(self.tmp, "platform-selfhost")
        os.makedirs(self.huly)
        for f in ("compose.yml", ".huly.nginx"):
            shutil.copy(os.path.join(BASE, f), self.huly)
        template = open(os.path.join(BASE, ".template.huly.conf")).read()
        conf = re.sub(r"\$\{(\w+)\}", lambda m: CONF.get(m.group(1), ""), template)
        open(os.path.join(self.huly, "huly_v7.conf"), "w").write(conf)
        os.symlink("huly_v7.conf", os.path.join(self.huly, ".env"))
        for name, value in ((".huly.secret", "huly-secret"), (".cr.secret", "cr-secret"), (".rp.secret", "rp-secret")):
            open(os.path.join(self.huly, name), "w").write(value + "\n")
        shutil.copytree(REPO, self.repo, symlinks=True,
                        ignore=shutil.ignore_patterns(".git", ".migration", "__pycache__", "backups", "node_modules",
                                                      "huly_v7.conf", "custom.conf", "compose.override.yml", "*.secret"))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def edit(self, name, old, new):
        path = os.path.join(self.huly, name)
        text = open(path).read()
        self.assertIn(old, text, f"fixture: {old!r} not in {name}")
        open(path, "w").write(text.replace(old, new, 1))

    def migrate(self, *args, expect=0):
        r = subprocess.run([os.path.join(self.repo, "migrate-from-huly.sh"), self.huly, "--dry-run", *args],
                           capture_output=True, text=True)
        self.output = r.stdout + r.stderr
        self.assertEqual(r.returncode, expect, self.output)
        return self.output

    def staged(self, name):
        path = os.path.join(self.repo, ".migration", "stage", name)
        return open(path).read() if os.path.exists(path) else None

    def plan(self):
        return open(os.path.join(self.repo, ".migration", "plan.md")).read()

    def effective_compose(self):
        """compose.yml + the staged override, as docker compose resolves them."""
        shutil.copy(os.path.join(self.repo, ".migration", "stage", "compose.override.yml"), self.repo)
        r = subprocess.run(["docker", "compose", "--project-directory", self.repo, "-p", "t",
                            "-f", os.path.join(self.repo, "compose.yml"),
                            "-f", os.path.join(self.repo, "compose.override.yml"),
                            "config", "--format", "json", "--no-interpolate"],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        cfg = json.loads(r.stdout)
        for svc in cfg["services"].values():
            svc["environment"] = huly_migrate.env_to_dict(svc.get("environment"))
        return cfg

    # ------------------------------------------------------------------ tests

    def test_pristine_install_carries_values_only(self):
        self.migrate()
        self.assertIsNone(self.staged("compose.override.yml"))
        self.assertIsNone(self.staged(".huly.nginx"))
        self.assertIsNone(self.staged("custom.conf"))
        seed = self.staged("huly_v7.conf")
        self.assertIn("HOST_ADDRESS=huly.example.com", seed)
        self.assertIn("DOCKER_NAME=huly_v7", seed)
        self.assertIn("DB_TYPE=cockroach", seed)
        self.assertNotIn("TITLE=", seed, "upstream default title must not be carried")
        self.assertNotIn("HULY_VERSION", seed)
        self.assertEqual(self.staged(".cr.secret").strip(), "cr-secret")

    def test_dry_run_changes_nothing(self):
        customize_huly.main(self.huly)
        before = (tree_hash(self.huly), tree_hash(self.repo))
        self.migrate()
        self.assertEqual(before, (tree_hash(self.huly), tree_hash(self.repo)))

    def test_typical_customizations(self):
        customize_huly.main(self.huly)
        self.migrate()
        cfg = self.effective_compose()
        svc = cfg["services"]
        self.assertEqual(svc["mail"]["image"], "platformcollective/mail:${HULY_VERSION}")
        self.assertEqual(svc["mail"]["environment"]["SMTP_PASSWORD"], "${SMTP_PASSWORD}")
        self.assertEqual(svc["mailpit"]["image"], "axllent/mailpit:v1.21")
        env = svc["transactor"]["environment"]
        self.assertEqual(env.get("MIGRATION_TEST_FLAG"), "kept")
        # our own changes to transactor survive
        self.assertEqual(env.get("FRONT_URL"), "http${SECURE:+s}://${HOST_ADDRESS}")
        self.assertIn("mem_limit", svc["transactor"])
        self.assertIn("mailpit", svc["nginx"]["depends_on"])
        # changes identical to ours are not carried over
        override = self.staged("compose.override.yml")
        self.assertNotIn("redpanda", override)
        self.assertNotIn("minio:", override)
        self.assertNotIn("account:", override)
        self.assertNotIn("front:", override)
        for name, s in svc.items():
            self.assertFalse(s.get("image", "").startswith("hardcoreeng/"), name)
        self.assertIn("SMTP_PASSWORD=mailpit-accepts-anything", self.staged("custom.conf"))

        nginx = self.staged(".huly.nginx")
        self.assertIn("client_max_body_size 1G;", nginx)
        self.assertNotIn("client_max_body_size 100M;", nginx)
        self.assertIn("location /_mailpit/ {", nginx)
        self.assertIn("resolver 127.0.0.11", nginx, "our own nginx changes must survive")

    def test_uncommented_location_uses_our_version(self):
        text = open(os.path.join(self.huly, ".huly.nginx")).read()
        start = text.index("    #location /_love {")
        end = text.index("#}", start) + 2
        block = re.sub(r"(?m)^(\s*)#", r"\1", text[start:end])
        open(os.path.join(self.huly, ".huly.nginx"), "w").write(text[:start] + block + text[end:])
        self.migrate()
        nginx = self.staged(".huly.nginx")
        m = re.search(r"\n    location /_love \{(.*?)\n    \}", nginx, re.S)
        self.assertIsNotNone(m, nginx)
        self.assertIn("set $upstream http://love:8096;", m.group(1))
        self.assertNotRegex(m.group(1), r"\n\s*#")
        self.assertIn("#location /_aibot {", nginx, "other commented blocks stay commented")

    def test_conflict_stops_by_default(self):
        self.edit("compose.yml", "      - FRONT_URL=http://localhost:8087\n", "      - FRONT_URL=https://huly.example.com\n")
        self.migrate(expect=1)
        self.assertIn("FRONT_URL", self.plan().split("## Conflicts")[1])

    def test_conflict_theirs_and_ours(self):
        self.edit("compose.yml", "      - FRONT_URL=http://localhost:8087\n", "      - FRONT_URL=https://huly.example.com\n")
        self.migrate("--on-conflict=theirs")
        env = self.effective_compose()["services"]["transactor"]["environment"]
        self.assertEqual(env["FRONT_URL"], "https://huly.example.com")
        self.migrate("--on-conflict=ours")
        self.assertIsNone(self.staged("compose.override.yml"))

    def test_removed_env_and_service(self):
        self.edit("compose.yml", "      - LAST_NAME_FIRST=${LAST_NAME_FIRST:-true}\n", "")
        text = open(os.path.join(self.huly, "compose.yml")).read()
        start, end = text.index("  rekoni:\n"), text.index("  transactor:\n")
        open(os.path.join(self.huly, "compose.yml"), "w").write(text[:start] + text[end:])
        self.migrate()
        svc = self.effective_compose()["services"]
        self.assertNotIn("LAST_NAME_FIRST", svc["transactor"]["environment"])
        self.assertIn("SERVER_SECRET", svc["transactor"]["environment"])
        self.assertEqual(svc["rekoni"].get("profiles"), ["disabled"])

    def test_pinned_and_renamed_images(self):
        self.edit("compose.yml", "  # hulypulse:\n",
                  "  hulypulse:\n    image: hardcoreeng/service_hulypulse:${HULY_PULSE_VERSION:-0.1.29}\n"
                  "    restart: unless-stopped\n  # hulypulse_old:\n")
        self.edit("compose.yml", "hardcoreeng/front:${HULY_VERSION}", "hardcoreeng/front:v0.7.426")
        self.migrate()
        svc = self.effective_compose()["services"]
        self.assertEqual(svc["hulypulse"]["image"], "platformcollective/hulypulse:${HULY_VERSION}")
        self.assertEqual(svc["front"]["image"], "platformcollective/front:${HULY_VERSION}")

    def test_unknown_upstream_image_is_refused(self):
        self.edit("compose.yml", "  rekoni:\n", "  mystery:\n    image: hardcoreeng/mystery:${HULY_VERSION}\n  rekoni:\n")
        self.migrate(expect=1)
        self.assertIn("hardcoreeng/mystery", self.plan().split("## Cannot migrate")[1])

    def test_relative_paths(self):
        self.edit("huly_v7.conf", "VOLUME_FILES_PATH=", "VOLUME_FILES_PATH=./data/files")
        os.makedirs(os.path.join(self.huly, "data", "files"))
        open(os.path.join(self.huly, "extra.yaml"), "w").write("x: 1\n")
        self.edit("compose.yml", "  rekoni:\n",
                  "  sidecar:\n    image: alpine:3\n    volumes:\n      - ./extra.yaml:/extra.yaml:ro\n"
                  "      - ./data:/data\n  rekoni:\n")
        self.migrate()
        self.assertIn(f"VOLUME_FILES_PATH={self.huly}/data/files", self.staged("huly_v7.conf"))
        self.assertEqual(self.staged("extra.yaml"), "x: 1\n")
        vols = {v["target"]: v["source"] for v in self.effective_compose()["services"]["sidecar"]["volumes"]}
        self.assertEqual(vols["/data"], os.path.join(self.huly, "data"))
        self.assertTrue(vols["/extra.yaml"].endswith("extra.yaml"))

    def test_custom_docker_name_and_title(self):
        self.edit("huly_v7.conf", "DOCKER_NAME=huly_v7", "DOCKER_NAME=acme")
        self.edit("huly_v7.conf", "TITLE=Huly", "TITLE=Acme Tracker")
        self.migrate()
        seed = self.staged("huly_v7.conf")
        self.assertIn("DOCKER_NAME=acme", seed)
        self.assertIn("TITLE='Acme Tracker'", seed)

    def test_secret_in_config_wins_over_file(self):
        self.edit("huly_v7.conf", "CR_USER_PASSWORD=cr-secret", "CR_USER_PASSWORD=edited-by-hand")
        self.migrate()
        self.assertEqual(self.staged(".cr.secret").strip(), "edited-by-hand")

    def test_v6_install_is_refused(self):
        os.remove(os.path.join(self.huly, ".env"))
        os.rename(os.path.join(self.huly, "huly_v7.conf"), os.path.join(self.huly, "huly.conf"))
        self.migrate(expect=1)
        self.assertIn("v0.6", self.output)


class NginxRoundTrip(unittest.TestCase):
    """Without changes, parse + render must give back the same config (whitespace aside),
    or every migrated install would get a reshuffled .huly.nginx."""

    @staticmethod
    def norm(text):
        return [re.sub(r"^#\s*", "#", line.strip()) for line in text.splitlines() if line.strip().strip("#").strip()]

    def test_roundtrip(self):
        for path in (os.path.join(REPO, ".huly.nginx"), os.path.join(BASE, ".huly.nginx")):
            text = open(path).read()
            rendered = "\n".join(huly_migrate.render_nginx(huly_migrate.parse_nginx(text)))
            self.assertEqual(self.norm(rendered), self.norm(text), path)


if __name__ == "__main__":
    unittest.main()
