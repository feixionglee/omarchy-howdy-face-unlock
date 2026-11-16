import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("lock_state", ROOT / "bin/howdy-lock-state.py")
state = importlib.util.module_from_spec(spec)
spec.loader.exec_module(state)


class LockStateTest(unittest.TestCase):
    def test_any_enabled_clone_uses_custom_integration(self):
        self.assertEqual(state.integration([
            {"id": "omarchy.lock", "enabled": False},
            {"id": "someone.personal-lock", "enabled": True, "clonedFrom": "omarchy.lock"},
        ]), "custom")

    def test_disabled_clone_does_not_suppress_legacy_repair(self):
        self.assertEqual(state.integration([
            {"id": "someone.personal-lock", "enabled": False, "clonedFrom": "omarchy.lock"},
            {"id": "omarchy.lock", "enabled": True},
        ]), "legacy")

    def test_explorer_keeps_existing_patch_support(self):
        self.assertEqual(state.integration([
            {"id": state.EXPLORER, "enabled": True, "clonedFrom": "omarchy.lock"},
        ]), "legacy")

    def test_unavailable_ambiguous_or_invalid_registry_is_unknown(self):
        for rows in (None, {}, [], [None], [{"id": "omarchy.lock", "enabled": "true"}], [
            {"id": "omarchy.lock", "enabled": True},
            {"id": "mine.lock", "enabled": True, "clonedFrom": "omarchy.lock"},
        ]):
            with self.subTest(rows=rows):
                self.assertEqual(state.integration(rows), "unknown")

    def test_runtime_health_requires_explicit_booleans(self):
        for payload, expected in [
            ({"howdy": True, "passwordPam": True}, "ok"),
            ({"howdy": False, "passwordPam": True}, "broken"),
            ({"howdy": True, "passwordPam": False}, "broken"),
            ({"howdy": True}, "unknown"),
            ({"howdy": "true", "passwordPam": True}, "unknown"),
            ({}, "unknown"), (None, "unknown"),
        ]:
            self.assertEqual(state.runtime_health(payload), expected)

    def test_custom_lock_without_status_never_falls_back_to_stock_file(self):
        rows = [{"id": "mine.lock", "enabled": True, "clonedFrom": "omarchy.lock"}]
        with patch.object(state, "query", side_effect=[{}, rows]), patch.object(state, "legacy_health") as fallback:
            self.assertEqual(state.health(), "unknown")
            fallback.assert_not_called()

    def test_runtime_failure_is_not_hidden_by_a_patched_file(self):
        with patch.object(state, "query", return_value={"howdy": False, "passwordPam": True}):
            self.assertEqual(state.health(), "broken")

    def test_legacy_fallback_uses_the_enabled_lock(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            pam = home / "pam"
            pam.touch()
            stock = home / "stock.qml"
            stock.write_text("omarchy-lock-howdy")
            explorer = home / ".config/omarchy/plugins" / state.EXPLORER / "Service.qml"
            explorer.parent.mkdir(parents=True)
            explorer.write_text("unpatched")
            rows = [{"id": state.EXPLORER, "enabled": True, "clonedFrom": "omarchy.lock"}]
            self.assertEqual(state.legacy_health(rows, pam, stock, home), "broken")
            explorer.write_text("omarchy-lock-howdy")
            self.assertEqual(state.legacy_health(rows, pam, stock, home), "ok")
            pam.unlink()
            self.assertEqual(state.legacy_health(rows, pam, stock, home), "broken")

    def test_query_errors_return_unknown_data(self):
        for error in (OSError("missing"), subprocess.TimeoutExpired("omarchy", 5)):
            with patch.object(state.subprocess, "run", side_effect=error):
                self.assertIsNone(state.query(["omarchy"]))
        for output, code in [("not json", 0), ("{}", 1)]:
            with patch.object(state.subprocess, "run", return_value=subprocess.CompletedProcess([], code, output)):
                self.assertIsNone(state.query(["omarchy"]))


class IntegrationGuardTest(unittest.TestCase):
    def test_setup_configures_pam_but_never_patches_a_custom_lock(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            (home / "bin").mkdir()
            (home / "bin/howdy-lock-state.py").write_text("print('custom')\n")
            stock = home / "stock.qml"
            stock.write_text("original stock file")
            script = '''
set -eu
source "$1/modules/lock-screen.sh"
root="$HOME"
PAM_HOWDY="$HOME/pam"
LOCK_QML="$HOME/stock.qml"
sudo() { [[ $1 == tee ]] || exit 99; command "$@"; }
omarchy() { [[ "$1 $2 $3" == 'hook install post-update' ]] || exit 98; }
configure_lock_screen_integration
'''
            result = subprocess.run(["bash", "-c", script, "test", str(ROOT)],
                                    env={**os.environ, "HOME": d, "PATH": "/usr/bin"}, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("pam_howdy.so", (home / "pam").read_text())
            self.assertEqual(stock.read_text(), "original stock file")
            self.assertFalse((home / "stock.qml.orig").exists())

    def test_setup_refuses_unknown_lock_before_privileged_writes(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            (home / "bin").mkdir()
            (home / "bin/howdy-lock-state.py").write_text("print('unknown')\n")
            script = '''
source "$1/modules/lock-screen.sh"
root="$HOME"
sudo() { echo unexpected-sudo >&2; return 99; }
configure_lock_screen_integration
'''
            result = subprocess.run(["bash", "-c", script, "test", str(ROOT)],
                                    env={**os.environ, "HOME": d, "PATH": "/usr/bin"}, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("unexpected-sudo", result.stderr)

    def test_legacy_update_still_reaches_existing_repair_path(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            plugin = home / ".config/omarchy/plugins/io.github.feixionglee.howdy-face-unlock"
            (plugin / "bin").mkdir(parents=True)
            (plugin / "manifest.json").write_text("{}")
            (plugin / "bin/howdy-lock-state.py").write_text("print('legacy')\n")
            stock = home / "system/shell/plugins/lock/Service.qml"
            stock.parent.mkdir(parents=True)
            stock.write_text("unpatched stock")
            fakebin = home / "bin"
            fakebin.mkdir()
            sudo = fakebin / "sudo"
            # Refuse authorization: exercise the repair gate without writes.
            sudo.write_text("#!/bin/sh\nexit 1\n")
            sudo.chmod(0o755)
            result = subprocess.run(["bash", str(ROOT / "hooks/post-update.d/repair-howdy-lock.hook")],
                                    env={**os.environ, "HOME": d, "PATH": str(fakebin) + ":/usr/bin",
                                         "OMARCHY_PATH": str(home / "system")}, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("sudo not available", result.stdout)
            self.assertEqual(stock.read_text(), "unpatched stock")

    def test_update_hook_never_patches_custom_or_unknown_lock(self):
        for mode in ("custom", "unknown"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as d:
                home = Path(d)
                plugin = home / ".config/omarchy/plugins/io.github.feixionglee.howdy-face-unlock"
                (plugin / "bin").mkdir(parents=True)
                (plugin / "manifest.json").write_text("{}")
                (plugin / "bin/howdy-lock-state.py").write_text(
                    "import sys\nprint(" + repr(mode) + " if sys.argv[1] == 'integration' else 'unknown')\n")
                fakebin = home / "bin"
                fakebin.mkdir()
                sudo = fakebin / "sudo"
                sudo.write_text("#!/bin/sh\necho unexpected-sudo >&2\nexit 99\n")
                sudo.chmod(0o755)
                env = {**os.environ, "HOME": d, "PATH": str(fakebin) + ":/usr/bin"}
                result = subprocess.run(["bash", str(ROOT / "hooks/post-update.d/repair-howdy-lock.hook")],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("unexpected-sudo", result.stderr)
                self.assertIn("not modified", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
