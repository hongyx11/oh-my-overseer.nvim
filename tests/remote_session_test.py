import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
from omo_client import Connection, SourceSnapshot


class RemoteSessionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="omo source and jobs ")
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.remote = self.root / "remote"
        self.source.mkdir()
        self.remote.mkdir()
        self.profile = {"kind": "local", "project_dir": str(self.remote)}
        self.connection = Connection(self.profile, SCRIPTS / "omo_agent.py")
        self.jobs = []

    def tearDown(self):
        for job in self.jobs:
            self.connection.request("cancel", {"job": job})
            self.wait_terminal(job)
        self.connection.close()
        self.temporary.cleanup()

    def launch(self, script, revision):
        job = os.urandom(16).hex()
        request = {
            "job": job,
            "revision": revision,
            "script": script,
            "scheduler": "process",
            "resources": {},
            "setup": [],
            "launcher": [],
            "expected_runs": [],
            "expected_build": None,
        }
        state = self.connection.request("launch", request)
        self.jobs.append(job)
        return job, request, state

    def wait_terminal(self, job):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            value = self.connection.request("observe", {"job": job, "cursor": 0})
            if value["state"]["terminal"]:
                return value
            time.sleep(0.02)
        self.fail("Job did not finish")

    def test_incremental_sync_and_removed_files_publish_distinct_revisions(self):
        (self.source / "kept.txt").write_text("kept")
        (self.source / "renamed.txt").write_text("old")
        (self.source / "build").mkdir()
        (self.source / "build/ignored").write_text("artifact")
        with SourceSnapshot(self.source, [], []) as snapshot:
            first = snapshot.publish(self.connection, {})
        first_root = Path(first["workspace"])
        self.assertEqual(2, first["uploaded"])
        self.assertFalse((first_root / "build/ignored").exists())
        (self.source / "renamed.txt").rename(self.source / "new.txt")
        with SourceSnapshot(self.source, [], []) as snapshot:
            second = snapshot.publish(self.connection, {})
        second_root = Path(second["workspace"])
        self.assertEqual(0, second["uploaded"])
        self.assertNotEqual(first["revision"], second["revision"])
        self.assertTrue((first_root / "renamed.txt").exists())
        self.assertFalse((second_root / "renamed.txt").exists())
        self.assertTrue((second_root / "new.txt").exists())

    def test_build_context_changes_workspace_without_retransferring_source(self):
        (self.source / "source.txt").write_text("same source")
        with SourceSnapshot(self.source, [], []) as snapshot:
            first = snapshot.publish(self.connection, {"preset": "release"})
            second = snapshot.publish(self.connection, {"preset": "debug"})
        self.assertNotEqual(first["workspace"], second["workspace"])
        self.assertEqual(0, second["uploaded"])

    def test_cancel_while_queued_does_not_start_the_command(self):
        first, _, _ = self.launch("touch active; sleep 30", None)
        deadline = time.monotonic() + 5
        while not (self.remote / "active").exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        second, _, _ = self.launch("touch must-not-run", None)
        self.connection.request("cancel", {"job": second})
        self.assertEqual("CANCELED", self.wait_terminal(second)["state"]["status"])
        self.assertFalse((self.remote / "must-not-run").exists())
        self.connection.request("cancel", {"job": first})
        self.wait_terminal(first)

    def test_lost_supervisor_retires_its_recorded_child_without_relaunch(self):
        job, _, _ = self.launch("echo started; sleep 30", None)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            value = self.connection.request("observe", {"job": job, "cursor": 0})
            if value["state"]["child"] is not None:
                break
            time.sleep(0.02)
        os.kill(value["state"]["worker"]["pid"], 9)
        value = self.wait_terminal(job)
        self.assertEqual("LOST", value["state"]["status"])
        self.assertIn(b"not relaunched", base64.b64decode(value["data"]))

    def test_capture_is_frozen_before_upload_and_large_content_is_chunked(self):
        content = b"a" * (1024 * 1024 + 17)
        (self.source / "large.txt").write_bytes(content)
        with SourceSnapshot(self.source, [], []) as snapshot:
            (self.source / "large.txt").write_bytes(b"changed later")
            published = snapshot.publish(self.connection, {})
        self.assertEqual(
            content, (Path(published["workspace"]) / "large.txt").read_bytes()
        )

    def test_jobs_survive_observer_exit_and_logs_resume_without_duplication(self):
        job, _, _ = self.launch("printf 'first\\n'; sleep .2; printf 'second\\n'", None)
        self.connection.close()
        self.connection = Connection(self.profile, SCRIPTS / "omo_agent.py")
        value = self.wait_terminal(job)
        output = base64.b64decode(value["data"])
        self.assertEqual(b"first\nsecond\n", output)
        again = self.connection.request(
            "observe", {"job": job, "cursor": value["cursor"]}
        )
        self.assertEqual(b"", base64.b64decode(again["data"]))
        self.assertEqual("SUCCESS", value["state"]["status"])

    def test_launch_is_idempotent_and_conflicting_reuse_is_rejected(self):
        script = "printf 'once\\n' >> launches.txt"
        job, request, _ = self.launch(script, None)
        self.connection.request("launch", request)
        self.wait_terminal(job)
        self.assertEqual("once\n", (self.remote / "launches.txt").read_text())
        with self.assertRaisesRegex(RuntimeError, "different request"):
            self.connection.request("launch", {**request, "script": "false"})

    def test_cancel_stops_owned_process_and_keeps_final_output(self):
        job, _, _ = self.launch("printf 'before\\n'; sleep 30; printf 'after\\n'", None)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            value = self.connection.request("observe", {"job": job, "cursor": 0})
            if b"before" in base64.b64decode(value["data"]):
                break
            time.sleep(0.02)
        self.connection.request("cancel", {"job": job})
        value = self.wait_terminal(job)
        self.assertEqual("CANCELED", value["state"]["status"])
        self.assertNotIn(b"after", base64.b64decode(value["data"]))

    def test_sync_failure_cannot_publish_incomplete_revision(self):
        (self.source / "missing.txt").write_text("missing")
        with SourceSnapshot(self.source, [], []) as snapshot:
            self.connection.request("sync_begin", {"manifest": snapshot.manifest})
            with self.assertRaisesRegex(RuntimeError, "missing content"):
                self.connection.request("sync_commit", {"manifest": snapshot.manifest})
        self.assertFalse(any((self.remote / ".omo/workspaces").glob("*/source")))

    def test_sync_cannot_escape_workspace_and_external_symlinks_are_rejected(self):
        (self.source / "escape").symlink_to(self.root / "remote")
        with self.assertRaisesRegex(ValueError, "outside"):
            SourceSnapshot(self.source, [], [])
        with self.assertRaisesRegex(RuntimeError, "path"):
            self.connection.request(
                "sync_begin",
                {"manifest": {"files": [{"path": "../escape"}], "mounts": []}},
            )

    def test_running_revision_is_isolated_from_later_source_sync(self):
        (self.source / "value.txt").write_text("original\n")
        with SourceSnapshot(self.source, [], []) as snapshot:
            first = snapshot.publish(self.connection, {})
        job, _, _ = self.launch("sleep .2; cat value.txt", first["revision"])
        (self.source / "value.txt").write_text("new\n")
        with SourceSnapshot(self.source, [], []) as snapshot:
            second = snapshot.publish(self.connection, {})
        value = self.wait_terminal(job)
        self.assertEqual(b"original\n", base64.b64decode(value["data"]))
        self.assertNotEqual(first["revision"], second["revision"])


if __name__ == "__main__":
    unittest.main()
