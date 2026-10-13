import importlib.util
import json
import os
import signal
import time
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts/overseer_experiment.py"
spec = importlib.util.spec_from_file_location("experiment_runner", MODULE_PATH)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class ExperimentRunnerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="overseer experiment ")
        self.root = Path(self.directory.name)
        (self.root / "data").mkdir()
        for name in ("d1", "d2", "d3"):
            (self.root / "data" / (name + " quoted's.mtx")).write_text("test dataset\n")
        self.binary = self.root / "probe.py"
        self.binary.write_text(
            "#!/usr/bin/env python3\n"
            "import argparse,json,os,pathlib\n"
            "p=argparse.ArgumentParser()\n"
            "p.add_argument('--dataset');p.add_argument('--threads');p.add_argument('--method');p.add_argument('--output')\n"
            "a=p.parse_args()\n"
            "assert pathlib.Path(a.dataset).is_file()\n"
            "assert os.environ['OMP_NUM_THREADS']==a.threads\n"
            "pathlib.Path(a.output).write_text(json.dumps(vars(a)))\n"
            "print('trial',a.dataset,a.threads,a.method)\n"
        )
        self.binary.chmod(0o755)
        self.config = {
            "version": 1,
            "name": "matrix test",
            "project": ".",
            "binary": "probe.py",
            "args": [
                "--dataset",
                "${dataset}",
                "--threads",
                "${threads}",
                "--method",
                "${method}",
                "--output",
                "${result}",
            ],
            "environment": {"OMP_NUM_THREADS": "${threads}"},
            "datasets": {
                "choices": [
                    {"id": name, "path": "data/" + name + " quoted's.mtx"}
                    for name in ("d1", "d2", "d3")
                ],
                "selected": ["d1", "d2", "d3"],
            },
            "threads": {"choices": [1, 2, 4], "selected": [1, 2, 4]},
            "methods": {"choices": ["a", "b", "c"], "selected": ["a", "b", "c"]},
            "servers": {
                "choices": [{"id": "local", "kind": "local"}],
                "selected": ["local"],
            },
            "output_dir": "results",
            "stop_on_failure": False,
        }
        self.file = self.root / "experiment.json"
        runner.write(self.file, self.config)

    def tearDown(self):
        self.directory.cleanup()

    def cli(self, action, folder, module=MODULE_PATH, file=None):
        return subprocess.run(
            [
                sys.executable,
                str(module),
                action,
                str(file or self.file),
                "--output-dir",
                str(folder),
            ],
            text=True,
            capture_output=True,
        )

    def test_cartesian_product_has_27_unique_stable_runs(self):
        plan = runner.plan(self.config, self.root, self.root / "out")
        self.assertEqual(27, plan["total"])
        self.assertEqual(list(range(1, 28)), [r["id"] for r in plan["runs"]])
        combinations = {(r["dataset"], r["threads"], r["method"]) for r in plan["runs"]}
        self.assertEqual(27, len(combinations))
        self.assertEqual(["a", "b", "c"], [r["method"] for r in plan["runs"][:3]])

    def test_sequential_execution_records_all_27_exact_commands_and_outputs(self):
        folder = self.root / "out"
        result = self.cli("run", folder)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        events = [
            json.loads(line[len(runner.MARKER) :])
            for line in result.stdout.splitlines()
            if line.startswith(runner.MARKER)
        ]
        sequence = [
            (e["event"], e["id"]) for e in events if e["event"] in {"start", "finish"}
        ]
        self.assertEqual(
            [(name, i) for i in range(1, 28) for name in ("start", "finish")], sequence
        )
        report = runner.read(folder / "results.json")
        self.assertEqual(27, report["completed"])
        self.assertTrue(all(r["exit_code"] == 0 for r in report["runs"]))
        for run in runner.read(folder / "manifest.json")["runs"]:
            output = runner.read(Path(run["folder"]) / "result.json")
            self.assertEqual(str(run["threads"]), output["threads"])
            self.assertEqual(run["method"], output["method"])
            self.assertTrue((Path(run["folder"]) / "output.log").is_file())

    def test_exported_runner_replays_without_neovim_from_another_cwd(self):
        exported = self.root / "bundle"
        result = self.cli("export", exported)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        saved = runner.read(exported / "experiment.json")
        self.assertFalse(Path(saved["project"]).is_absolute())
        result = self.cli(
            "run",
            self.root / "replayed",
            module=exported / "runner.py",
            file=exported / "experiment.json",
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual(
            27, runner.read(self.root / "replayed/results.json")["completed"]
        )

    def test_inherited_gpu_profile_maps_remote_datasets_and_quotes_commands(self):
        self.config["servers"] = {
            "choices": [
                {
                    "id": "server1",
                    "kind": "ssh",
                    "host": "cluster",
                    "project_dir": "/remote/project space",
                    "environment": {"DEVICE": "gpu"},
                },
                {
                    "id": "server1-h100",
                    "extends": "server1",
                    "slurm": {"constraint": "h100", "gpus": 1, "cpus_per_task": 4},
                },
            ],
            "selected": ["server1-h100"],
        }
        self.config["datasets"]["choices"][0]["paths"] = {
            "server1": "/matrices/d1 quoted's.mtx"
        }
        plan = runner.plan(self.config, self.root, self.root / "out")
        profile = plan["profiles"][0]
        self.assertEqual("cluster", profile["host"])
        self.assertEqual("h100", profile["slurm"]["constraint"])
        self.assertEqual("/matrices/d1 quoted's.mtx", plan["runs"][0]["argv"][2])
        script = runner.script(self.config, plan, profile, batch=True)
        self.assertIn("#SBATCH --gpus=1", script)
        self.assertIn("#SBATCH --constraint=h100", script)
        self.assertEqual(
            0,
            subprocess.run(
                ["bash", "-n"], input=script, text=True, capture_output=True
            ).returncode,
        )
        argv = runner.ssh(profile, "echo test", tty=True)
        self.assertEqual("cluster", argv[-2])
        self.assertIn("-tt", argv)

    def test_disabled_or_undersized_profiles_fail_before_execution(self):
        self.config["servers"]["choices"][0]["enabled"] = False
        with self.assertRaisesRegex(ValueError, "disabled"):
            runner.plan(self.config, self.root, self.root / "out")
        self.config["servers"]["choices"][0] = {
            "id": "local",
            "slurm": {"cpus_per_task": 2},
        }
        with self.assertRaisesRegex(ValueError, "thread count"):
            runner.plan(self.config, self.root, self.root / "out")

    def test_failure_policy_continues_or_stops_as_configured(self):
        self.config["binary"] = "/usr/bin/false"
        self.config["methods"]["selected"] = ["a"]
        runner.write(self.file, self.config)
        folder = self.root / "continued"
        self.assertEqual(1, self.cli("run", folder).returncode)
        self.assertEqual(9, runner.read(folder / "results.json")["completed"])
        self.config["stop_on_failure"] = True
        runner.write(self.file, self.config)
        folder = self.root / "stopped"
        self.assertEqual(1, self.cli("run", folder).returncode)
        self.assertEqual(1, runner.read(folder / "results.json")["completed"])

    def test_slurm_submission_poll_and_cancel_are_scoped_to_recorded_job_ids(self):
        self.config["servers"]["choices"][0]["slurm"] = {
            "cpus_per_task": 4,
            "time": "00:05:00",
        }
        folder = self.root / "submitted"
        calls = []

        def command(argv, **kwargs):
            calls.append(argv)
            if argv[0] == "sbatch":
                self.assertIn("#SBATCH --cpus-per-task=4", kwargs["input"])
                return subprocess.CompletedProcess(argv, 0, "12345\n", "")
            return subprocess.CompletedProcess(
                argv, 0, "RUNNING\n" if argv[0] == "squeue" else "", ""
            )

        with patch.object(runner.subprocess, "run", side_effect=command):
            self.assertEqual(0, runner.submit(self.config, self.root, folder))
            self.assertEqual(0, runner.job_action(folder, "poll"))
            self.assertEqual(0, runner.job_action(folder, "cancel"))
        self.assertEqual(["scancel", "12345"], calls[-1])
        self.assertEqual("CANCELED", runner.read(folder / "jobs.json")[0]["status"])

    def test_no_partial_submission_when_a_later_profile_has_no_slurm_config(self):
        self.config["servers"] = {
            "choices": [
                {"id": "local", "slurm": {"cpus_per_task": 4}},
                {
                    "id": "other",
                    "kind": "ssh",
                    "host": "cluster",
                    "project_dir": "/project",
                },
            ],
            "selected": ["local", "other"],
        }
        with patch.object(runner.subprocess, "run") as command:
            with self.assertRaisesRegex(ValueError, "Slurm resources"):
                runner.submit(self.config, self.root, self.root / "submission")
            command.assert_not_called()

    def test_interactive_slurm_allocates_once_for_all_trials(self):
        self.config["servers"]["choices"][0]["slurm"] = {"cpus_per_task": 4}
        folder = self.root / "allocated"
        with patch.object(runner, "execute", return_value=0) as execute:
            self.assertEqual(0, runner.run(self.config, self.root, folder))
        execute.assert_called_once()
        argv = execute.call_args.args[0]
        self.assertEqual("srun", argv[0])
        self.assertIn("--cpus-per-task=4", argv)
        self.assertEqual(27, argv[-1].count('"event": "start"'))

    def test_setup_failure_prevents_running_binary(self):
        self.config["servers"]["choices"][0]["setup"] = ["false"]
        runner.write(self.file, self.config)
        folder = self.root / "bad-setup"
        result = self.cli("run", folder)
        self.assertEqual(1, result.returncode)
        self.assertNotIn('"event": "start"', result.stdout)
        self.assertFalse((folder / "0001/result.json").exists())

    def test_log_uses_frozen_manifest_after_configuration_changes(self):
        self.config["threads"]["selected"] = [1]
        self.config["datasets"]["selected"] = ["d1"]
        self.config["methods"]["selected"] = ["a"]
        runner.write(self.file, self.config)
        folder = self.root / "logged"
        self.assertEqual(0, self.cli("run", folder).returncode)
        self.config["methods"]["selected"] = ["c"]
        runner.write(self.file, self.config)
        result = subprocess.run(
            [
                sys.executable,
                str(MODULE_PATH),
                "log",
                str(self.file),
                "--output-dir",
                str(folder),
                "--run-id",
                "1",
            ],
            text=True,
            capture_output=True,
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("trial", result.stdout)
        self.assertTrue(result.stdout.rstrip().endswith("1 a"))

    def test_stopping_runner_terminates_the_active_trial_process(self):
        self.binary.write_text(
            "#!/usr/bin/env python3\n"
            "import os,pathlib,time\n"
            "pathlib.Path('active.pid').write_text(str(os.getpid()))\n"
            "time.sleep(30)\n"
        )
        folder = self.root / "canceled"
        process = subprocess.Popen(
            [
                sys.executable,
                str(MODULE_PATH),
                "run",
                str(self.file),
                "--output-dir",
                str(folder),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            deadline = time.monotonic() + 5
            while (
                not (self.root / "active.pid").exists() and time.monotonic() < deadline
            ):
                time.sleep(0.02)
            self.assertTrue((self.root / "active.pid").exists())
            pid = int((self.root / "active.pid").read_text())
            process.send_signal(signal.SIGTERM)
            output, errors = process.communicate(timeout=8)
            self.assertEqual(130, process.returncode, output + errors)
            self.assertIn('"event": "canceled"', output)
            deadline = time.monotonic() + 3
            while Path(f"/proc/{pid}").exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertFalse(
                Path(f"/proc/{pid}").exists(), "trial process remains alive"
            )
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()


if __name__ == "__main__":
    unittest.main()
