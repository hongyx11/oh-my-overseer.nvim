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
            "#!/usr/bin/env python3\nimport argparse,json,os,pathlib\np=argparse.ArgumentParser()\np.add_argument('--dataset');p.add_argument('--threads');p.add_argument('--method');p.add_argument('--output')\na=p.parse_args()\nassert pathlib.Path(a.dataset).is_file()\nassert os.environ['OMP_NUM_THREADS']==a.threads\npathlib.Path(a.output).write_text(json.dumps(vars(a)))\nprint('trial',a.dataset,a.threads,a.method)\n"
        )
        self.binary.chmod(493)
        self.config = {
            "version": 2,
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
            "parameters": [
                {
                    "id": "dataset",
                    "label": "Datasets",
                    "choices": [
                        {"id": name, "path": "data/" + name + " quoted's.mtx"}
                        for name in ("d1", "d2", "d3")
                    ],
                    "selected": ["d1", "d2", "d3"],
                },
                {
                    "id": "threads",
                    "choices": [1, 2, 4],
                    "selected": [1, 2, 4],
                    "requirements": {"cpus": "${value}"},
                },
                {
                    "id": "method",
                    "choices": ["a", "b", "c"],
                    "selected": ["a", "b", "c"],
                },
            ],
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

    def cli(self, action, folder, module, file):
        return subprocess.run(
            [
                sys.executable,
                str(module),
                action,
                str(file),
                "--output-dir",
                str(folder),
            ],
            text=True,
            capture_output=True,
        )

    def test_cartesian_product_has_27_unique_stable_runs(self):
        plan = runner.plan(self.config, self.root, self.root / "out", True)
        self.assertEqual(27, plan["total"])
        self.assertEqual(list(range(1, 28)), [r["id"] for r in plan["runs"]])
        combinations = {
            (
                r["choices"]["dataset"],
                r["parameters"]["threads"],
                r["parameters"]["method"],
            )
            for r in plan["runs"]
        }
        self.assertEqual(27, len(combinations))
        self.assertEqual(
            ["a", "b", "c"], [r["parameters"]["method"] for r in plan["runs"][:3]]
        )

    def test_sequential_execution_records_all_27_exact_commands_and_outputs(self):
        folder = self.root / "out"
        result = self.cli("run", folder, MODULE_PATH, self.file)
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
        self.assertTrue(all((r["exit_code"] == 0 for r in report["runs"])))
        for run in runner.read(folder / "manifest.json")["runs"]:
            output = runner.read(Path(run["folder"]) / "result.json")
            self.assertEqual(str(run["parameters"]["threads"]), output["threads"])
            self.assertEqual(run["parameters"]["method"], output["method"])
            self.assertTrue((Path(run["folder"]) / "output.log").is_file())

    def test_exported_runner_replays_without_neovim_from_another_cwd(self):
        exported = self.root / "bundle"
        result = self.cli("export", exported, MODULE_PATH, self.file)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        saved = runner.read(exported / "experiment.json")
        self.assertFalse(Path(saved["project"]).is_absolute())
        result = self.cli(
            "run",
            self.root / "replayed",
            exported / "runner.py",
            exported / "experiment.json",
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
        self.config["parameters"][0]["choices"][0]["paths"] = {
            "server1": "/matrices/d1 quoted's.mtx"
        }
        plan = runner.plan(self.config, self.root, self.root / "out", True)
        profile = plan["profiles"][0]
        self.assertEqual("cluster", profile["host"])
        self.assertEqual("h100", profile["slurm"]["constraint"])
        self.assertEqual("/matrices/d1 quoted's.mtx", plan["runs"][0]["argv"][2])
        script = runner.script(self.config, plan, plan["allocations"][0], "run", True)
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
            runner.plan(self.config, self.root, self.root / "out", True)
        self.config["servers"]["choices"][0] = {
            "id": "local",
            "slurm": {"cpus_per_task": 2},
        }
        with self.assertRaisesRegex(ValueError, "CPU requirement"):
            runner.plan(self.config, self.root, self.root / "out", True)

    def test_failure_policy_continues_or_stops_as_configured(self):
        self.config["binary"] = "/usr/bin/false"
        self.config["parameters"][2]["selected"] = ["a"]
        runner.write(self.file, self.config)
        folder = self.root / "continued"
        self.assertEqual(1, self.cli("run", folder, MODULE_PATH, self.file).returncode)
        self.assertEqual(9, runner.read(folder / "results.json")["completed"])
        self.config["stop_on_failure"] = True
        runner.write(self.file, self.config)
        folder = self.root / "stopped"
        self.assertEqual(1, self.cli("run", folder, MODULE_PATH, self.file).returncode)
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

        def simulate(argv, record, log):
            for number in range(1, 28):
                record({"event": "finish", "id": number, "exit_code": 0})
            return 0

        with patch.object(runner, "execute", side_effect=simulate) as execute:
            self.assertEqual(0, runner.run(self.config, self.root, folder, "run"))
        execute.assert_called_once()
        argv = execute.call_args.args[0]
        self.assertEqual("salloc", argv[0])
        self.assertIn("--cpus-per-task=4", argv)
        self.assertEqual(27, argv[-1].count('"event": "start"'))

    def test_setup_failure_prevents_running_binary(self):
        self.config["servers"]["choices"][0]["setup"] = ["false"]
        runner.write(self.file, self.config)
        folder = self.root / "bad-setup"
        result = self.cli("run", folder, MODULE_PATH, self.file)
        self.assertEqual(1, result.returncode)
        self.assertNotIn('"event": "start"', result.stdout)
        self.assertFalse((folder / "0001/result.json").exists())

    def test_log_uses_frozen_manifest_after_configuration_changes(self):
        self.config["parameters"][1]["selected"] = [1]
        self.config["parameters"][0]["selected"] = ["d1"]
        self.config["parameters"][2]["selected"] = ["a"]
        runner.write(self.file, self.config)
        folder = self.root / "logged"
        self.assertEqual(0, self.cli("run", folder, MODULE_PATH, self.file).returncode)
        self.config["parameters"][2]["selected"] = ["c"]
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
            "#!/usr/bin/env python3\nimport os,pathlib,time\npathlib.Path('active.pid').write_text(str(os.getpid()))\ntime.sleep(30)\n"
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

    def test_arbitrary_options_execute_without_dataset_thread_or_method_axes(self):
        self.binary.write_text(
            "#!/usr/bin/env python3\n"
            "import argparse,json,pathlib\n"
            "p=argparse.ArgumentParser();p.add_argument('--tile');p.add_argument('--layout');p.add_argument('--output')\n"
            "a=p.parse_args();pathlib.Path(a.output).write_text(json.dumps(vars(a)))\n"
            "print(a.tile,a.layout)\n"
        )
        self.config["parameters"] = [
            {
                "id": "tile_size",
                "choices": [8, 16],
                "selected": [8, 16],
                "args": ["--tile", "${value}"],
            },
            {
                "id": "storage_layout",
                "choices": ["csr", "csc"],
                "selected": ["csr", "csc"],
                "args": ["--layout", "${value}"],
            },
        ]
        self.config["args"] = ["--output", "${result}"]
        self.config["environment"] = {}
        runner.write(self.file, self.config)
        folder = self.root / "arbitrary"
        result = self.cli("run", folder, MODULE_PATH, self.file)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        manifest = runner.read(folder / "manifest.json")
        self.assertEqual(4, manifest["total"])
        for run in manifest["runs"]:
            report = runner.read(Path(run["folder"]) / "result.json")
            self.assertEqual(str(run["parameters"]["tile_size"]), report["tile"])
            self.assertEqual(run["parameters"]["storage_layout"], report["layout"])

    def test_shared_option_presets_resolve_independent_experiment_selections(self):
        library = {
            "options": {
                "worker_counts": {
                    "choices": [1, 2, 4, 8],
                    "presets": {"development": [1, 2], "scaling": [1, 2, 4, 8]},
                }
            }
        }
        source = {
            "version": 2,
            "parameters": [
                {"id": "workers", "template": "worker_counts", "preset": "development"}
            ],
        }
        first = runner.resolve_config(source, library)
        source["parameters"][0]["preset"] = "scaling"
        second = runner.resolve_config(source, library)
        self.assertEqual([1, 2], first["parameters"][0]["selected"])
        self.assertEqual([1, 2, 4, 8], second["parameters"][0]["selected"])
        second["parameters"][0]["selected"] = [8]
        self.assertEqual([1, 2], first["parameters"][0]["selected"])
        self.assertNotIn("template", first["parameters"][0])
        self.assertEqual(
            [1, 2], library["options"]["worker_counts"]["presets"]["development"]
        )

    def test_export_freezes_shared_definitions_and_runs_without_the_library(self):
        library_path = self.root / "shared.json"
        library = {
            "options": {
                "algorithms": {
                    "choices": ["a", "b", "c"],
                    "presets": {"development": ["a", "b"]},
                }
            }
        }
        runner.write(library_path, library)
        self.config["parameters"][2] = {
            "id": "method",
            "template": "algorithms",
            "preset": "development",
        }
        runner.write(self.file, self.config)
        config, root = runner.load_config(self.file, None, library_path)
        bundle = self.root / "frozen"
        runner.export(config, root, bundle)
        library_path.unlink()
        saved = runner.read(bundle / "experiment.json")
        self.assertNotIn("template", saved["parameters"][2])
        result = self.cli(
            "run",
            self.root / "replayed-frozen",
            bundle / "runner.py",
            bundle / "experiment.json",
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual(
            18, runner.read(self.root / "replayed-frozen/results.json")["completed"]
        )

    def test_reserved_nodes_create_distinct_slurm_jobs_with_one_controller_each(self):
        self.config["parameters"] = [
            {
                "id": "nodes",
                "choices": [2, 4, 16],
                "selected": [2, 4, 16],
                "slurm": {"nodes": "${value}"},
            }
        ]
        self.config["binary"], self.config["args"], self.config["environment"] = (
            "/usr/bin/true",
            [],
            {},
        )
        self.config["servers"]["choices"][0]["slurm"] = {"time": "00:01:00"}
        config = runner.resolve_config(self.config, {"options": {}})
        folder = self.root / "nodes"
        plan = runner.plan(config, self.root, folder, True)
        self.assertEqual(
            [2, 4, 16], [int(a["slurm"]["nodes"]) for a in plan["allocations"]]
        )
        submitted = []

        def submit(argv, **kwargs):
            submitted.append(kwargs["input"])
            return subprocess.CompletedProcess(
                argv, 0, str(300 + len(submitted)) + "\n", ""
            )

        with patch.object(runner.subprocess, "run", side_effect=submit):
            self.assertEqual(0, runner.submit(config, self.root, folder))
        self.assertEqual(3, len(submitted))
        for nodes, text in zip([2, 4, 16], submitted):
            self.assertIn("#SBATCH --nodes=" + str(nodes), text)
            self.assertEqual(1, text.count('"event": "start"'))
            self.assertIn("srun --nodes=1 --ntasks=1", text)
            self.assertEqual(
                0,
                subprocess.run(
                    ["bash", "-n"], input=text, text=True, capture_output=True
                ).returncode,
            )
        jobs = runner.read(folder / "jobs.json")
        self.assertEqual(3, len({j["allocation"] for j in jobs}))
        self.assertEqual(["301", "302", "303"], [j["job_id"] for j in jobs])

    def test_reserved_nodes_reject_wrong_names_bindings_and_nonpositive_values(self):
        library = {
            "options": {
                "nodes": {
                    "reserved_id": "nodes",
                    "choices": [2, 4],
                    "slurm": {"nodes": "${value}"},
                }
            }
        }
        for option in [
            {"id": "ranks", "template": "nodes", "selected": [2]},
            {
                "id": "nodes",
                "choices": [2],
                "selected": [2],
                "args": ["--nodes", "${value}"],
            },
            {
                "id": "nodes",
                "choices": [0],
                "selected": [0],
                "slurm": {"nodes": "${value}"},
            },
        ]:
            with self.assertRaises(ValueError):
                runner.resolve_config({"version": 2, "parameters": [option]}, library)
        self.config["parameters"] = [
            {
                "id": "nodes",
                "choices": [2],
                "selected": [2],
                "slurm": {"nodes": "${value}"},
            }
        ]
        self.config["args"], self.config["environment"] = [], {}
        with self.assertRaisesRegex(ValueError, "Slurm server"):
            runner.plan(self.config, self.root, self.root / "invalid-nodes", True)

    def test_empty_parameter_list_runs_once_and_schema_rejects_bad_references(self):
        self.config["parameters"], self.config["args"], self.config["environment"] = (
            [],
            [],
            {},
        )
        self.config["binary"] = "/usr/bin/true"
        self.assertEqual(
            1, runner.plan(self.config, self.root, self.root / "single", True)["total"]
        )
        for source in [
            {"version": 1},
            {"version": 2, "parameters": [{"id": "workers", "template": "missing"}]},
            {
                "version": 2,
                "parameters": [
                    {
                        "id": "x",
                        "choices": [1],
                        "presets": {"bad": [2]},
                        "selected": [1],
                    }
                ],
            },
            {"version": 2, "parameters": [{"id": "x"}, {"id": "x"}]},
        ]:
            with self.assertRaises(ValueError):
                runner.resolve_config(source, {"options": {}})

    def test_scheduler_success_cannot_hide_failed_or_unstarted_trials(self):
        self.config["parameters"], self.config["args"], self.config["environment"] = (
            [],
            [],
            {},
        )
        self.config["binary"] = "/usr/bin/true"
        self.config["servers"]["choices"][0]["slurm"] = {}

        def failed(argv, record, log):
            record({"event": "finish", "id": 1, "exit_code": 7})
            return 0

        with patch.object(runner, "execute", side_effect=failed):
            self.assertEqual(
                1,
                runner.run(
                    self.config, self.root, self.root / "scheduler-failed", "run"
                ),
            )
        with patch.object(runner, "execute", return_value=0):
            self.assertEqual(
                1,
                runner.run(
                    self.config, self.root, self.root / "scheduler-empty", "run"
                ),
            )


if __name__ == "__main__":
    unittest.main()
