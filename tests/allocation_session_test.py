import base64
import json
import os
from pathlib import Path
import shlex
import signal
import shutil
import sys
import tempfile
import time
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
from omo_client import Connection


class AllocationSessionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="omo allocation sessions ")
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("salloc", "srun", "sbatch", "scancel", "squeue", "sacct"):
            target = self.bin / name
            shutil.copyfile(Path(__file__).with_name("fake_slurm.py"), target)
            target.chmod(0o755)
        self.setup = [
            "export PATH=" + shlex.quote(str(self.bin)) + ":$PATH",
            "export OMO_FAKE_SLURM=" + shlex.quote(str(self.root / "scheduler")),
        ]
        self.profile = {"kind": "local", "project_dir": str(self.root)}
        self.connection = Connection(self.profile, SCRIPTS / "omo_agent.py")
        self.jobs = []

    def tearDown(self):
        for job in self.jobs:
            self.connection.request("cancel", {"job": job})
            self.wait(job)
        self.connection.request("allocations_release", {"experiment": "one"})
        self.connection.request("allocations_release", {"experiment": "two"})
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            values = self.connection.request(
                "allocations_observe", {"experiment": None}
            )
            if all(value["terminal"] for value in values):
                break
            time.sleep(0.05)
        self.connection.close()
        self.temporary.cleanup()

    def launch(self, experiment, script, scheduler):
        job = os.urandom(16).hex()
        request = {
            "job": job,
            "experiment": experiment,
            "revision": None,
            "script": script,
            "scheduler": scheduler,
            "resources": {"cpus_per_task": 1, "nodes": 1, "time": "00:10:00"},
            "setup": self.setup,
            "expected_runs": [],
            "expected_build": None,
            "server": "fake",
            "allocation": "fake",
            "client_folder": str(self.root),
            "trial_logs": {},
        }
        self.connection.request("launch", request)
        self.jobs.append(job)
        return job

    def wait(self, job):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            value = self.connection.request("observe", {"job": job, "cursor": 0})
            if value["state"]["terminal"]:
                return value
            time.sleep(0.03)
        self.fail("Job did not finish")

    def test_configure_build_and_run_reuse_one_allocation_after_disconnect(self):
        first = self.launch("one", "echo CONFIGURE", "allocation")
        value = self.wait(first)
        self.assertEqual("SUCCESS", value["state"]["status"])
        allocation = value["state"]["allocation_session"]
        self.connection.close()
        self.connection = Connection(self.profile, SCRIPTS / "omo_agent.py")
        second = self.launch("one", "echo BUILD", "allocation")
        third = self.launch("one", "echo RUN", "allocation")
        self.assertEqual(allocation, self.wait(second)["state"]["allocation_session"])
        self.assertEqual(allocation, self.wait(third)["state"]["allocation_session"])
        sessions = self.connection.request("allocations_observe", {"experiment": "one"})
        self.assertEqual(1, len(sessions))
        self.assertEqual("READY", sessions[0]["status"])
        calls = [
            json.loads(line)["argv"][0]
            for line in (self.root / "scheduler/calls.jsonl").read_text().splitlines()
        ]
        self.assertEqual(1, calls.count("salloc"))

    def test_canceling_a_step_keeps_the_allocation_until_explicit_release(self):
        job = self.launch("one", "echo ACTIVE; sleep 30", "allocation")
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            value = self.connection.request("observe", {"job": job, "cursor": 0})
            if b"ACTIVE" in base64.b64decode(value["data"]):
                break
            time.sleep(0.03)
        self.connection.request("cancel", {"job": job})
        self.assertEqual("CANCELED", self.wait(job)["state"]["status"])
        sessions = self.connection.request("allocations_observe", {"experiment": "one"})
        self.assertEqual("READY", sessions[0]["status"])
        self.connection.request("allocations_release", {"experiment": "one"})
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            sessions = self.connection.request(
                "allocations_observe", {"experiment": "one"}
            )
            if sessions[0]["terminal"]:
                break
            time.sleep(0.03)
        self.assertEqual("RELEASED", sessions[0]["status"])

    def test_expired_allocation_is_replaced_and_other_experiment_is_not_released(self):
        a = self.wait(self.launch("one", "echo FIRST", "allocation"))["state"]
        b = self.wait(self.launch("two", "echo OTHER", "allocation"))["state"]
        folder = self.root / ".omo/allocations" / a["allocation_session"]
        state = json.loads((folder / "state.json").read_text())
        os.killpg(state["child"]["pid"], signal.SIGTERM)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            values = self.connection.request(
                "allocations_observe", {"experiment": "one"}
            )
            if values[0]["terminal"]:
                break
            time.sleep(0.03)
        self.assertEqual("EXPIRED", values[0]["status"])
        newer = self.wait(self.launch("one", "echo NEW", "allocation"))["state"]
        self.assertNotEqual(a["allocation_session"], newer["allocation_session"])
        self.connection.request("allocations_release", {"experiment": "one"})
        other = self.connection.request("allocations_observe", {"experiment": "two"})
        self.assertEqual(b["allocation_session"], other[0]["id"])
        self.assertEqual("READY", other[0]["status"])

    def test_lost_allocation_supervisor_cancels_only_its_owned_scheduler_job(self):
        state = self.wait(self.launch("one", "echo READY", "allocation"))["state"]
        folder = self.root / ".omo/allocations" / state["allocation_session"]
        allocation = json.loads((folder / "state.json").read_text())
        os.kill(allocation["worker"]["pid"], signal.SIGKILL)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            values = self.connection.request(
                "allocations_observe", {"experiment": "one"}
            )
            if values[0]["terminal"]:
                break
            time.sleep(0.03)
        self.assertEqual("LOST", values[0]["status"])
        calls = [
            json.loads(line)["argv"]
            for line in (self.root / "scheduler/calls.jsonl").read_text().splitlines()
        ]
        self.assertEqual(
            [["scancel", state["job_id"]]], [c for c in calls if c[0] == "scancel"]
        )

    def test_pending_resource_request_can_be_released_without_a_job_id(self):
        scheduler = self.root / "scheduler"
        scheduler.mkdir()
        (scheduler / "pending").touch()
        job = self.launch("one", "echo SHOULD_NOT_RUN", "allocation")
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            states = self.connection.request(
                "allocations_observe", {"experiment": "one"}
            )
            if states and states[0]["child"]:
                break
            time.sleep(0.03)
        self.assertEqual("PENDING", states[0]["status"])
        self.assertIsNone(states[0]["job_id"])
        self.connection.request("allocations_release", {"experiment": "one"})
        value = self.wait(job)
        self.assertEqual("FAILURE", value["state"]["status"])
        self.assertNotIn(b"SHOULD_NOT_RUN", base64.b64decode(value["data"]))

    def test_experiments_own_independent_allocations_and_can_run_in_parallel(self):
        first = self.launch(
            "one",
            "touch one.started; while [ ! -e two.started ]; do sleep .02; done",
            "allocation",
        )
        second = self.launch(
            "two",
            "touch two.started; while [ ! -e one.started ]; do sleep .02; done",
            "allocation",
        )
        a, b = self.wait(first), self.wait(second)
        self.assertNotEqual(
            a["state"]["allocation_session"], b["state"]["allocation_session"]
        )
        self.assertEqual(
            2, len(self.connection.request("allocations_observe", {"experiment": None}))
        )


if __name__ == "__main__":
    unittest.main()
