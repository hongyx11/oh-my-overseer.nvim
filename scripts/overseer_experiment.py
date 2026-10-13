#!/usr/bin/env python3
"""Portable experiment plans, sequential execution, and Slurm jobs (stdlib only)."""

from __future__ import annotations

import argparse
from collections import deque
import copy
import datetime as dt
import itertools
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys

MARKER = "@@OVERSEER "
RESOURCE_FLAGS = {
    "partition": "partition",
    "account": "account",
    "qos": "qos",
    "constraint": "constraint",
    "gpus": "gpus",
    "cpus_per_task": "cpus-per-task",
    "memory": "mem",
    "time": "time",
    "nodes": "nodes",
    "ntasks": "ntasks",
}


def emit(event, **values):
    print(
        MARKER + json.dumps({"event": event, **values}, ensure_ascii=False), flush=True
    )


def read(path):
    return json.loads(Path(path).read_text())


def write(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")


def merge(base, child):
    result = copy.deepcopy(base)
    for key, value in child.items():
        result[key] = (
            merge(result[key], value)
            if isinstance(value, dict) and isinstance(result.get(key), dict)
            else copy.deepcopy(value)
        )
    return result


def choice_entries(values):
    entries = [
        {"id": str(v), "value": v} if not isinstance(v, dict) else copy.deepcopy(v)
        for v in values
    ]
    ids = [str(v["id"]) for v in entries]
    if len(set(ids)) != len(ids):
        raise ValueError("Duplicate option choice IDs")
    for entry in entries:
        entry["id"] = str(entry["id"])
    return entries


def selected_entries(option):
    lookup = {v["id"]: v for v in choice_entries(option.get("choices", []))}
    result = []
    for name in option.get("selected", []):
        key = str(name)
        if key not in lookup:
            raise ValueError("Unknown selection for " + option["id"] + ": " + key)
        if key not in [v["id"] for v in result]:
            result.append(lookup[key])
    return result


def resolve_config(source, library):
    if source.get("version") != 2:
        raise ValueError("Experiment must use the parameter-list schema (version 2)")
    config = copy.deepcopy(source)
    for field in ("args", "launcher"):
        if field in config and (
            not isinstance(config[field], list)
            or any(not isinstance(v, (str, int, float)) for v in config[field])
        ):
            raise ValueError(field + " must be an array of argument values")
    parameters, ids = [], set()
    reserved = {
        "project",
        "server",
        "run_id",
        "result",
        "run_dir",
        "preset",
        "target",
        "value",
    }
    for reference in config.get("parameters", []):
        name = reference["id"]
        if (
            not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name)
            or name in ids
            or name in reserved
        ):
            raise ValueError("Invalid, reserved, or duplicate option ID: " + name)
        ids.add(name)
        template = reference.get("template")
        if template and template not in library.get("options", {}):
            raise ValueError("Unknown shared option: " + template)
        option = merge(library.get("options", {}).get(template, {}), reference)
        for field in ("presets", "environment", "slurm", "requirements"):
            if field in reference:
                option[field] = copy.deepcopy(reference[field])
        option.pop("template", None)
        if option.get("reserved_id") and name != option["reserved_id"]:
            raise ValueError("This option name is reserved: " + option["reserved_id"])
        if "source" in option and not all(
            isinstance(option["source"].get(k), str) and option["source"][k]
            for k in ("directory", "pattern")
        ):
            raise ValueError("File options require source.directory and source.pattern")
        option["choices"] = choice_entries(option.get("choices", []))
        preset = option.get("preset")
        if preset and preset not in option.get("presets", {}):
            raise ValueError("Unknown preset for " + name + ": " + preset)
        if "selected" not in reference:
            option["selected"] = option.get("presets", {}).get(preset, [])
        selected_entries(option)
        for saved in option.get("presets", {}).values():
            selected_entries({**option, "selected": saved})
        if "nodes" in option.get("slurm", {}) and name != "nodes":
            raise ValueError("Slurm nodes must use the reserved option name nodes")
        if name == "nodes":
            if option.get("slurm", {}).get("nodes") != "${value}" or option.get("args"):
                raise ValueError(
                    "nodes is reserved for Slurm requests; bind slurm.nodes to ${value}"
                )
            for choice in option["choices"]:
                if choice.get("args") or choice.get("arguments") or "path" in choice:
                    raise ValueError("Slurm nodes choices contain node counts only")
                value = choice.get("value", choice["id"])
                if (
                    isinstance(value, bool)
                    or not str(value).isdigit()
                    or int(value) < 1
                ):
                    raise ValueError("Slurm node counts must be positive integers")
        parameters.append(option)
    config["parameters"] = parameters
    return config


def load_config(path, project, library_path):
    path = Path(path).resolve()
    source = read(path)
    library = (
        read(library_path)
        if library_path and Path(library_path).is_file()
        else {"options": {}}
    )
    config = resolve_config(source, library)
    root = (
        Path(project).resolve()
        if project
        else (path.parent / config.get("project", "..")).resolve()
    )
    return config, root


def server_profiles(config):
    lookup = {
        v["id"]: v for v in choice_entries(config.get("servers", {}).get("choices", []))
    }

    def resolve(name, parents):
        if name in parents:
            raise ValueError("Server inheritance cycle: " + name)
        if name not in lookup:
            raise ValueError("Unknown server profile: " + name)
        own = lookup[name]
        base = resolve(own["extends"], (*parents, name)) if own.get("extends") else {}
        profile = merge(base, own)
        profile["id"] = name
        profile["parents"] = [name, *base.get("parents", [])]
        return profile

    return [
        resolve(str(name), ()) for name in config.get("servers", {}).get("selected", [])
    ]


def expand(value, variables):
    def replace(match):
        key = match.group(1)
        if key not in variables:
            raise ValueError("Unknown experiment placeholder: " + key)
        return str(variables[key])

    return re.sub(r"\$\{([\w_]+)\}", replace, str(value))


def path_on_server(path, root, profile):
    return (
        str(Path(path))
        if Path(path).is_absolute()
        else str(Path(profile.get("project_dir", str(root))) / path)
    )


def validate_profile(profile, resources, cpus):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", profile["id"]):
        raise ValueError("Server IDs must be safe file names")
    if profile.get("enabled", True) is False:
        raise ValueError("Server profile is disabled: " + profile["id"])
    if profile.get("kind", "local") not in {"local", "ssh"}:
        raise ValueError("Server kind must be local or ssh")
    if profile.get("kind") == "ssh":
        host = profile.get("host", "")
        if not host or host.startswith("-") or any(c.isspace() for c in host):
            raise ValueError("Set a valid SSH host for " + profile["id"])
        if (
            not profile.get("project_dir")
            or not Path(profile["project_dir"]).is_absolute()
        ):
            raise ValueError("Set an absolute remote project_dir for " + profile["id"])
    if resources is None:
        return
    unknown = set(resources) - set(RESOURCE_FLAGS)
    if unknown:
        raise ValueError("Unknown Slurm resource fields: " + ", ".join(sorted(unknown)))
    if any("\n" in str(v) or "\r" in str(v) for v in resources.values()):
        raise ValueError("Slurm resource values must occupy one line")
    for key in ("nodes", "ntasks", "cpus_per_task"):
        value = resources.get(key, 1)
        if not str(value).isdigit() or int(value) < 1:
            raise ValueError(key + " must be a positive integer")
    if int(resources.get("cpus_per_task", cpus)) < cpus:
        raise ValueError("cpus_per_task is smaller than the selected CPU requirement")


def option_value(option, choice, root, profile):
    value = choice.get("value", choice["id"])
    if "path" in choice:
        value = choice["path"]
        for name in profile["parents"]:
            if name in choice.get("paths", {}):
                value = choice["paths"][name]
                break
        value = path_on_server(value, root, profile)
    return value


def plan(config, root, output_dir, validate):
    profiles = server_profiles(config)
    options = config.get("parameters", [])
    selections = [selected_entries(option) for option in options]
    if validate and (not profiles or any(not items for items in selections)):
        raise ValueError("Select a server and at least one value for each option")
    runs, allocations = [], []
    for profile in profiles:
        profile["project_dir"] = (
            str(root)
            if profile.get("kind", "local") == "local"
            else profile.get("project_dir", "")
        )
        server_output = (
            str(Path(output_dir).resolve())
            if profile.get("kind", "local") == "local"
            else path_on_server(
                config.get("output_dir", "results/overseer")
                + "/"
                + Path(output_dir).name,
                root,
                profile,
            )
        )
        groups = {}
        for combination in itertools.product(*selections):
            number = len(runs) + 1
            folder = str(Path(server_output) / f"{number:04d}")
            parameters = {
                option["id"]: option_value(option, choice, root, profile)
                for option, choice in zip(options, combination)
            }
            variables = {
                "project": profile["project_dir"],
                "server": profile["id"],
                "run_id": f"{number:04d}",
                "result": folder + "/result.json",
                "run_dir": folder,
                "preset": config.get("preset", ""),
                "target": config.get("target", ""),
                **parameters,
            }
            binary = profile.get("binary", config.get("binary", ""))
            arguments = profile.get("arguments", config.get("args", []))
            launcher = profile.get("launcher", config.get("launcher", []))
            extra = []
            environment = {
                **config.get("environment", {}),
                **profile.get("environment", {}),
            }
            resources = copy.deepcopy(profile.get("slurm"))
            cpus = 1
            for option, choice in zip(options, combination):
                local = {**variables, "value": parameters[option["id"]]}
                binary = choice.get("binary", binary)
                for name in profile["parents"]:
                    if name in choice.get("binaries", {}):
                        binary = choice["binaries"][name]
                        break
                arguments = choice.get("arguments", arguments)
                launcher = choice.get("launcher", launcher)
                extra.extend(
                    expand(v, local)
                    for v in [*option.get("args", []), *choice.get("args", [])]
                )
                environment.update(
                    {
                        k: expand(v, local)
                        for k, v in {
                            **option.get("environment", {}),
                            **choice.get("environment", {}),
                        }.items()
                    }
                )
                cpus = max(
                    cpus,
                    int(expand(option.get("requirements", {}).get("cpus", 1), local)),
                )
                binding = {**option.get("slurm", {}), **choice.get("slurm", {})}
                if binding:
                    if validate and "slurm" not in profile:
                        raise ValueError(
                            "Option "
                            + option["id"]
                            + " requests Slurm resources; select a Slurm server profile"
                        )
                    resources = {
                        **(resources or {}),
                        **{k: expand(v, local) for k, v in binding.items()},
                    }
            if cpus < 1:
                raise ValueError("CPU requirements must be positive")
            if validate and not binary:
                raise ValueError("Choose an executable binary")
            environment = {str(k): expand(v, variables) for k, v in environment.items()}
            if any(not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", k) for k in environment):
                raise ValueError("Invalid environment variable name")
            run = {
                "id": number,
                "server": profile["id"],
                "parameters": parameters,
                "choices": {
                    option["id"]: choice["id"]
                    for option, choice in zip(options, combination)
                },
                "argv": [
                    path_on_server(expand(binary, variables), root, profile),
                    *[expand(v, variables) for v in arguments],
                    *extra,
                ],
                "launcher": [expand(v, variables) for v in launcher],
                "cwd": profile["project_dir"],
                "environment": environment,
                "folder": folder,
                "required_cpus": cpus,
            }
            runs.append(run)
            key = json.dumps(resources, sort_keys=True)
            if key not in groups:
                groups[key] = {
                    "server": profile["id"],
                    "profile": profile,
                    "slurm": resources,
                    "run_ids": [],
                }
            groups[key]["run_ids"].append(number)
        if not groups:
            groups["empty"] = {
                "server": profile["id"],
                "profile": profile,
                "slurm": profile.get("slurm"),
                "run_ids": [],
            }
        for index, allocation in enumerate(groups.values(), 1):
            allocation["id"] = (
                profile["id"] if len(groups) == 1 else profile["id"] + f"--{index:03d}"
            )
            cpus = max(
                (r["required_cpus"] for r in runs if r["id"] in allocation["run_ids"]),
                default=1,
            )
            if allocation["slurm"] is not None:
                allocation["slurm"].setdefault("cpus_per_task", cpus)
                allocation["slurm"].setdefault(
                    "ntasks", int(allocation["slurm"].get("nodes", 1))
                )
            if validate:
                validate_profile(profile, allocation["slurm"], cpus)
            allocations.append(allocation)
    return {
        "version": 2,
        "name": config.get("name", "Experiment"),
        "profiles": profiles,
        "parameters": [
            {"id": o["id"], "label": o.get("label", o["id"])} for o in options
        ],
        "allocations": allocations,
        "runs": runs,
        "total": len(runs),
        "stop_on_failure": config.get("stop_on_failure", False),
    }


def marker_line(event, **values):
    return "printf '%s\\n' " + shlex.quote(
        MARKER + json.dumps({"event": event, **values})
    )


def build_commands(config, profile):
    build = config.get("build", {})
    variables = {
        "project": profile["project_dir"],
        "preset": config.get("preset", ""),
        "target": config.get("target", ""),
        "build_dir": build.get("directory", "build"),
        "build_jobs": build.get("jobs", 4),
    }
    return [[expand(v, variables) for v in argv] for argv in build.get("commands", [])]


def script(config, manifest, allocation, mode, batch):
    profile = allocation["profile"]
    build_only = mode in {"build", "configure"}
    configure_only = mode == "configure"
    runs = [r for r in manifest["runs"] if r["id"] in allocation["run_ids"]]
    lines = ["#!/usr/bin/env bash"]
    if batch:
        resources = allocation["slurm"] or {"ntasks": 1, "cpus_per_task": 1}
        for key, value in resources.items():
            if value != "":
                lines.append(
                    "#SBATCH --" + RESOURCE_FLAGS[key] + "=" + shlex.quote(str(value))
                )
        lines.append(
            "#SBATCH --job-name="
            + re.sub(r"[^\w-]", "_", manifest["name"] + "-" + profile["id"])
        )
    lines.extend(
        ["set -uo pipefail", "cd " + shlex.quote(profile["project_dir"]) + " || exit 1"]
    )
    for setup in profile.get("setup", []):
        lines.append("{\n" + setup + "\n} || exit 1")
    for key, value in profile.get("environment", {}).items():
        if "${" not in str(value):
            lines.append("export " + key + "=" + shlex.quote(str(value)))
    if build_only or config.get("build", {}).get("before_run", False):
        directory = config.get("build", {}).get("directory")
        if directory:
            query = str(Path(directory) / ".cmake/api/v1/query")
            lines.extend(
                [
                    "mkdir -p " + shlex.quote(query) + " || exit 1",
                    ": > " + shlex.quote(query + "/codemodel-v2"),
                ]
            )
        commands = build_commands(config, profile)
        if not commands:
            raise ValueError("Set build.commands before configuring or building")
        for argv in commands[:1] if configure_only else commands:
            lines.append(marker_line("build", server=profile["id"], argv=argv))
            lines.append("if " + shlex.join(argv) + "; then :; else")
            lines.append(marker_line("build_failed", server=profile["id"]))
            lines.extend(["exit 1", "fi"])
    if build_only:
        return "\n".join([*lines, marker_line("built", server=profile["id"]), ""])
    lines.append("failures=0")
    for run in runs:
        values = {k: run[k] for k in ("id", "server", "parameters", "choices")}
        lines.extend(
            [
                "mkdir -p " + shlex.quote(run["folder"]) + " || exit 1",
                marker_line("start", total=manifest["total"], **values),
            ]
        )
        env = [k + "=" + str(v) for k, v in run["environment"].items()]
        launcher = run["launcher"]
        if not launcher and allocation["slurm"] is not None:
            launcher = [
                "srun",
                "--nodes=1",
                "--ntasks=1",
                "--cpus-per-task=" + str(allocation["slurm"]["cpus_per_task"]),
            ]
        lines.append(
            shlex.join(["env", *env, *launcher, *run["argv"]])
            + " 2>&1 | tee "
            + shlex.quote(run["folder"] + "/output.log")
        )
        lines.append("code=${PIPESTATUS[0]}")
        # Exit code is dynamic; the rest is serialized and shell-quoted once.
        prefix = (
            MARKER + json.dumps({"event": "finish", **values})[:-1] + ', "exit_code": '
        )
        lines.append(
            "printf '%s%s%s\\n' " + shlex.quote(prefix) + ' "$code" ' + shlex.quote("}")
        )
        lines.append(
            'if [ "$code" -ne 0 ]; then failures=$((failures+1)); '
            + ('exit "$code"; ' if manifest["stop_on_failure"] else "")
            + "fi"
        )
    lines.append('[ "$failures" -eq 0 ]')
    return "\n".join([*lines, ""])


def ssh(profile, command, tty):
    return [
        "ssh",
        "-tt" if tty else "-T",
        "-o",
        "BatchMode=yes",
        *profile.get("ssh_options", []),
        profile["host"],
        command,
    ]


def allocation_args(resources):
    return [
        "--" + RESOURCE_FLAGS[k] + "=" + str(v) for k, v in resources.items() if v != ""
    ]


def execute(argv, on_event, log):
    process = subprocess.Popen(
        argv,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        start_new_session=True,
    )

    def interrupt(signum, _frame):
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
        raise KeyboardInterrupt

    previous = {
        sig: signal.signal(sig, interrupt)
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    }
    try:
        with Path(log).open("w") as output:
            for line in process.stdout:
                print(line, end="", flush=True)
                output.write(line)
                clean = line.strip()
                if clean.startswith(MARKER):
                    event = json.loads(clean[len(MARKER) :])
                    on_event(event)
        return process.wait()
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def export(config, root, folder):
    folder = Path(folder).resolve()
    folder.mkdir(parents=True, exist_ok=True)
    saved = copy.deepcopy(config)
    saved["project"] = os.path.relpath(root, folder)
    write(folder / "experiment.json", saved)
    manifest = plan(config, root, folder, True)
    write(folder / "manifest.json", manifest)
    if Path(__file__).resolve() != (folder / "runner.py").resolve():
        shutil.copyfile(__file__, folder / "runner.py")
    for allocation in manifest["allocations"]:
        text = script(config, manifest, allocation, "run", True)
        (folder / (allocation["id"] + ".sbatch")).write_text(text)
    return manifest


def run(config, root, folder, mode):
    folder.mkdir(parents=True, exist_ok=True)
    manifest = plan(config, root, folder, mode == "run")
    for allocation in manifest["allocations"]:
        cpus = max(
            (
                r["required_cpus"]
                for r in manifest["runs"]
                if r["id"] in allocation["run_ids"]
            ),
            default=1,
        )
        if allocation["slurm"] is not None and "slurm" not in allocation["profile"]:
            raise ValueError("Select a Slurm server profile for resource options")
        validate_profile(allocation["profile"], allocation["slurm"], cpus)
    write(folder / "manifest.json", manifest)
    results, events = [], []

    def record(event):
        events.append(event)
        if event.get("event") == "finish":
            results.append(event)
            write(
                folder / "results.json",
                {
                    "total": manifest["total"],
                    "completed": len(results),
                    "runs": results,
                },
            )

    code = 0
    for allocation in manifest["allocations"]:
        profile = allocation["profile"]
        text = script(config, manifest, allocation, mode, False)
        argv = ["bash", "-c", text]
        if allocation["slurm"] is not None:
            emit(
                "allocation",
                server=profile["id"],
                allocation=allocation["id"],
                slurm=allocation["slurm"],
            )
            argv = [
                "salloc",
                *allocation_args(allocation["slurm"]),
                "bash",
                "-lc",
                text,
            ]
        if profile.get("kind") == "ssh":
            argv = ssh(profile, shlex.join(argv), True)
        emit("server", server=profile["id"], allocation=allocation["id"])
        previous_runs, previous_events = len(results), len(events)
        status = execute(argv, record, folder / (allocation["id"] + ".log"))
        new_runs = results[previous_runs:]
        new_events = events[previous_events:]
        finished = (
            len(new_runs) == len(allocation["run_ids"])
            if mode == "run"
            else any(e.get("event") == "built" for e in new_events)
        )
        failed = (
            status != 0 or not finished or any(r["exit_code"] != 0 for r in new_runs)
        )
        failed = failed or any(e.get("event") == "build_failed" for e in new_events)
        code = max(code, int(failed))
        if failed and manifest["stop_on_failure"]:
            break
    emit(
        "complete",
        total=manifest["total"],
        completed=len(results),
        failed=sum(r["exit_code"] != 0 for r in results),
        exit_code=code,
        folder=str(folder),
    )
    return code


def submit(config, root, folder):
    manifest = export(config, root, folder)
    for allocation in manifest["allocations"]:
        if allocation["slurm"] is None:
            raise ValueError(
                "Add Slurm resources to profile "
                + allocation["server"]
                + " before submitting"
            )
    jobs = []
    for allocation in manifest["allocations"]:
        profile = allocation["profile"]
        text = (folder / (allocation["id"] + ".sbatch")).read_text()
        argv = ["sbatch", "--parsable"]
        if profile.get("kind") == "ssh":
            argv = ssh(profile, shlex.join(argv), False)
        result = subprocess.run(
            argv, input=text, text=True, capture_output=True, check=True
        )
        job_id = result.stdout.strip().split(";", 1)[0]
        if not job_id.isdigit():
            raise ValueError("Unexpected sbatch job ID: " + result.stdout)
        job = {
            "server": profile["id"],
            "allocation": allocation["id"],
            "slurm": allocation["slurm"],
            "job_id": job_id,
            "profile": profile,
        }
        jobs.append(job)
        write(folder / "jobs.json", jobs)
        emit(
            "submitted",
            server=profile["id"],
            allocation=allocation["id"],
            slurm=allocation["slurm"],
            job_id=job_id,
            folder=str(folder),
        )
    return 0


def job_action(folder, action):
    jobs = read(folder / "jobs.json")
    for job in jobs:
        profile, job_id = job["profile"], job["job_id"]
        argv = (
            ["scancel", job_id]
            if action == "cancel"
            else ["squeue", "--noheader", "--jobs", job_id, "--format", "%T"]
        )
        if profile.get("kind") == "ssh":
            argv = ssh(profile, shlex.join(argv), False)
        result = subprocess.run(argv, text=True, capture_output=True, check=True)
        status = "CANCELED" if action == "cancel" else result.stdout.strip()
        if action == "poll" and not status:
            argv = [
                "sacct",
                "--noheader",
                "--parsable2",
                "--jobs",
                job_id,
                "--format",
                "JobIDRaw,State",
            ]
            if profile.get("kind") == "ssh":
                argv = ssh(profile, shlex.join(argv), False)
            result = subprocess.run(argv, text=True, capture_output=True, check=True)
            status = next(
                (
                    line.split("|")[1]
                    for line in result.stdout.splitlines()
                    if line.split("|")[0] == job_id
                ),
                "UNKNOWN",
            )
        job["status"] = status
        emit(
            "job",
            server=job["server"],
            allocation=job["allocation"],
            job_id=job_id,
            status=status,
        )
    write(folder / "jobs.json", jobs)
    return 0


def dispatch(args):
    if args.action == "parse-args":
        print(json.dumps(shlex.split(args.text)))
        return 0
    if args.action == "format":
        write(args.config, read(args.config))
        return 0
    config, root = load_config(args.config, args.project, args.library)
    if args.action == "resolve":
        print(json.dumps(config))
        return 0
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    folder = (
        Path(args.output_dir).resolve()
        if args.output_dir
        else root / config.get("output_dir", "results/overseer") / stamp
    )
    if args.action == "log":
        if args.run_id is None or not args.output_dir:
            raise ValueError("Use --run-id and --output-dir to view a run log")
        manifest = read(folder / "manifest.json")
        trial = next((r for r in manifest["runs"] if r["id"] == args.run_id), None)
        if not trial:
            raise ValueError("Unknown run ID")
        profile = next(p for p in manifest["profiles"] if p["id"] == trial["server"])
        log = str(Path(trial["folder"]) / "output.log")
        if profile.get("kind") == "ssh":
            subprocess.run(
                ssh(profile, shlex.join(["tail", "-n", "300", log]), False), check=True
            )
        else:
            with Path(log).open() as source:
                print("".join(deque(source, maxlen=300)), end="")
        return 0
    if args.action == "targets":
        directory = root / config.get("build", {}).get("directory", "build")
        reply = directory / ".cmake/api/v1/reply"
        indexes = sorted(reply.glob("index-*.json"))
        targets = {}
        if indexes:
            for obj in read(indexes[-1]).get("objects", []):
                if obj["kind"] == "codemodel":
                    for configuration in read(reply / obj["jsonFile"]).get(
                        "configurations", []
                    ):
                        for target in configuration.get("targets", []):
                            data = read(reply / target["jsonFile"])
                            if data.get("type") == "EXECUTABLE" and data.get(
                                "artifacts"
                            ):
                                path = directory / data["artifacts"][0]["path"]
                                targets[target["name"]] = {
                                    "id": target["name"],
                                    "binary": os.path.relpath(path, root),
                                }
        print(json.dumps(sorted(targets.values(), key=lambda v: v["id"])))
        return 0
    if args.action == "describe":
        manifest = plan(config, root, folder, validate=False)
        print(json.dumps({"project": str(root), "config": config, "plan": manifest}))
        return 0
    if args.action in {"poll", "cancel"}:
        if not args.output_dir:
            raise ValueError("Use --output-dir for the submitted experiment")
        return job_action(folder, args.action)
    if args.action == "export":
        manifest = export(config, root, folder)
        emit("exported", folder=str(folder), total=manifest["total"])
        return 0
    if args.action == "submit":
        return submit(config, root, folder)
    return run(config, root, folder, args.action)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action",
        choices=[
            "format",
            "resolve",
            "parse-args",
            "describe",
            "targets",
            "configure",
            "run",
            "build",
            "export",
            "submit",
            "poll",
            "cancel",
            "log",
        ],
    )
    parser.add_argument("config")
    parser.add_argument("--project")
    parser.add_argument("--library")
    parser.add_argument("--output-dir")
    parser.add_argument("--run-id", type=int)
    parser.add_argument("--text")
    return dispatch(parser.parse_args(argv))


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        emit("canceled")
        sys.exit(130)
    except (ValueError, OSError, subprocess.CalledProcessError, KeyError) as error:
        emit("error", message=str(error))
        sys.exit(2)
