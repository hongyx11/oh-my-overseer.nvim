#!/usr/bin/env python3
"""Portable experiment plans, sequential execution, and Slurm jobs (stdlib only)."""

from __future__ import annotations

import argparse
import base64
import codecs
from contextlib import ExitStack
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
import time
import uuid

from omo_client import Connection, SourceSnapshot

MARKER = "@@OVERSEER "
RESOURCE_FLAGS = {
    "partition": "partition",
    "account": "account",
    "qos": "qos",
    "constraint": "constraint",
    "gpus": "gpus",
    "gpus_per_node": "gpus-per-node",
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
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex)
    temporary.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    temporary.replace(path)


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


def node_value(value):
    return not isinstance(value, bool) and str(value).isdigit() and int(value) > 0


def gpu_value(value):
    return isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", value)


RESERVED_RESOURCES = {"nodes": node_value, "gpu_name": gpu_value}


def validate_resource_option(option, validate_value):
    name = option["id"]
    if option.get("slurm", {}).get(name) != "${value}" or any(
        option.get(k) for k in ("args", "environment", "launcher")
    ):
        raise ValueError(
            name
            + " is reserved for Slurm requests; bind slurm."
            + name
            + " to ${value}"
        )
    for choice in option["choices"]:
        if (
            any(choice.get(k) for k in ("args", "arguments", "environment", "launcher"))
            or "path" in choice
        ):
            raise ValueError("Slurm " + name + " choices contain resource values only")
        if not validate_value(choice.get("value", choice["id"])):
            raise ValueError(
                "Slurm "
                + name
                + " choices must contain "
                + ("positive integers" if name == "nodes" else "GPU model names")
            )


def gpu_resources(resources):
    if resources is None or "gpu_name" not in resources:
        return resources
    result = copy.deepcopy(resources)
    name = result.pop("gpu_name")
    if not gpu_value(name):
        raise ValueError("Invalid Slurm GPU name")
    keys = [key for key in ("gpus", "gpus_per_node") if key in result] or [
        "gpus_per_node"
    ]
    for key in keys:
        count = str(result.get(key, 1)).rsplit(":", 1)[-1]
        if not node_value(count):
            raise ValueError("GPU count must be a positive integer")
        result[key] = name + ":" + count
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
    sync = config.get("sync", {})
    if not isinstance(sync, dict):
        raise ValueError("sync must be an object")
    if "on_save" in sync and not isinstance(sync["on_save"], bool):
        raise ValueError("sync.on_save must be true or false")
    for field in ("exclude", "mounts"):
        if field in sync and (
            not isinstance(sync[field], list)
            or any(not isinstance(v, str) or not v for v in sync[field])
        ):
            raise ValueError("sync." + field + " must be a list of strings")
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
        for resource_name in RESERVED_RESOURCES:
            if resource_name in option.get("slurm", {}) and name != resource_name:
                raise ValueError(
                    "Slurm "
                    + resource_name
                    + " must use the reserved option name "
                    + resource_name
                )
        if name in RESERVED_RESOURCES:
            validate_resource_option(option, RESERVED_RESOURCES[name])
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
    for key in ("gpus", "gpus_per_node"):
        if key in resources and not re.fullmatch(
            r"(?:[A-Za-z0-9][A-Za-z0-9_.-]*:)?[1-9][0-9]*", str(resources[key])
        ):
            raise ValueError(key + " must be a positive count or GPU-name:count")
    if "gpus" in resources and int(str(resources["gpus"]).rsplit(":", 1)[-1]) < int(
        resources.get("nodes", 1)
    ):
        raise ValueError(
            "Total GPUs must include at least one GPU per requested node; use gpus_per_node for per-node counts"
        )
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
        value = path_on_server(
            value,
            root,
            {**profile, "project_dir": profile.get("data_dir", profile["project_dir"])},
        )
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
                {
                    **profile,
                    "project_dir": profile.get("data_dir", profile["project_dir"]),
                },
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
            batch_resources = (
                merge(resources or {}, profile.get("slurm_batch", {}))
                if resources is not None
                else None
            )
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
                    resolved_binding = {k: expand(v, local) for k, v in binding.items()}
                    resources = {**(resources or {}), **resolved_binding}
                    batch_resources = {**(batch_resources or {}), **resolved_binding}
            resources = gpu_resources(resources)
            batch_resources = gpu_resources(batch_resources)
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
                    "batch_resources": batch_resources,
                    "run_ids": [],
                }
            groups[key]["run_ids"].append(number)
        if not groups:
            groups["empty"] = {
                "server": profile["id"],
                "profile": profile,
                "slurm": gpu_resources(profile.get("slurm")),
                "batch_resources": (
                    gpu_resources(
                        merge(profile.get("slurm", {}), profile.get("slurm_batch", {}))
                    )
                    if "slurm" in profile
                    else None
                ),
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
            if allocation["batch_resources"] is None:
                allocation["batch_resources"] = {"cpus_per_task": cpus, "ntasks": 1}
            else:
                allocation["batch_resources"].setdefault("cpus_per_task", cpus)
                allocation["batch_resources"].setdefault(
                    "ntasks", int(allocation["batch_resources"].get("nodes", 1))
                )
            if validate:
                validate_profile(profile, allocation["slurm"], cpus)
                validate_profile(profile, allocation["batch_resources"], cpus)
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
        resources = allocation["batch_resources"]
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
        if not launcher and (batch or allocation["slurm"] is not None):
            launcher = [
                "srun",
                "--nodes=1",
                "--ntasks=1",
                "--cpus-per-task="
                + str(allocation["batch_resources"]["cpus_per_task"]),
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


def allocation_args(resources):
    return [
        "--" + RESOURCE_FLAGS[k] + "=" + str(v) for k, v in resources.items() if v != ""
    ]


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
    for name in ("omo_client.py", "omo_agent.py"):
        source = Path(__file__).resolve().with_name(name)
        if source != (folder / name).resolve():
            shutil.copyfile(source, folder / name)
    for allocation in manifest["allocations"]:
        text = script(config, manifest, allocation, "run", True)
        (folder / (allocation["id"] + ".sbatch")).write_text(text)
    return manifest


class Detached(Exception):
    pass


def execution_manifest(config, root, folder, mode):
    manifest = plan(config, root, folder, mode in {"run", "submit"})
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
        validate_profile(
            allocation["profile"],
            allocation["batch_resources"] if mode == "submit" else allocation["slurm"],
            cpus,
        )
        if mode == "submit" and allocation["slurm"] is None:
            raise ValueError(
                "Select Slurm resources before submission on " + allocation["server"]
            )
    return manifest


def setup_lines(profile):
    lines = list(profile.get("setup", []))
    for key, value in profile.get("environment", {}).items():
        if "${" not in str(value):
            lines.append("export " + key + "=" + shlex.quote(str(value)))
    return lines


def source_config(config, root, manifest, connections):
    prepared = copy.deepcopy(config)
    choices = {p["id"]: p for p in prepared["servers"]["choices"]}
    remote = [p for p in manifest["profiles"] if p.get("kind", "local") == "ssh"]
    if not remote:
        return prepared
    policy = config.get("sync", {})
    excludes = list(policy.get("exclude", []))
    directory = config.get("build", {}).get("directory", "build")
    if not Path(directory).is_absolute():
        excludes.append(directory.rstrip("/") + "/")
    with SourceSnapshot(
        root, excludes, policy.get("mounts", ["dataset", "datasets"])
    ) as snapshot:
        published = {}
        for profile in remote:
            context = {
                "build": config.get("build", {}),
                "preset": config.get("preset", ""),
                "target": config.get("target", ""),
                "setup": profile.get("setup", []),
                "environment": profile.get("environment", {}),
                "gpu_options": [
                    option
                    for option in config.get("parameters", [])
                    if option["id"] == "gpu_name"
                ],
            }
            key = (
                profile["host"],
                profile["project_dir"],
                json.dumps(context, sort_keys=True),
            )
            emit("sync", server=profile["id"])
            if key not in published:
                published[key] = snapshot.publish(connections[profile["id"]], context)
            revision = published[key]
            emit("synced", server=profile["id"], **revision)
            choice = choices[profile["id"]]
            choice.update(
                {
                    "project_dir": revision["workspace"],
                    "data_dir": profile["project_dir"],
                    "agent_root": profile["project_dir"],
                    "revision": revision["revision"],
                }
            )
    return prepared


class JobObserver:
    def __init__(self, connection, entry, folder, record):
        self.connection, self.entry, self.record = connection, entry, record
        self.path = folder / (entry["allocation"] + "." + entry["job"] + ".log")
        self.cursor = 0
        self.pending = ""
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")
        if self.path.exists():
            with self.path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(256 * 1024), b""):
                    self.consume(chunk)
                    self.cursor += len(chunk)

    def consume(self, data):
        text = self.decoder.decode(data)
        print(text, end="", flush=True)
        self.pending += text
        while "\n" in self.pending:
            line, self.pending = self.pending.split("\n", 1)
            if line.startswith(MARKER):
                try:
                    self.record(json.loads(line[len(MARKER) :]))
                except ValueError:
                    pass

    def observe(self):
        value = self.connection.request(
            "observe", {"job": self.entry["job"], "cursor": self.cursor}
        )
        data = base64.b64decode(value["data"])
        if data:
            with self.path.open("ab") as output:
                output.write(data)
                output.flush()
            self.consume(data)
        self.cursor = value["cursor"]
        state = value["state"]
        old = self.entry.get("state", {})
        if state.get("status") != old.get("status") or state.get("job_id") != old.get(
            "job_id"
        ):
            emit(
                "remote_job",
                server=self.entry["server"],
                allocation=self.entry["allocation"],
                job=self.entry["job"],
                folder=self.entry["client_folder"],
                **{k: state[k] for k in ("status", "terminal", "job_id", "exit_code")},
            )
        if state.get("observation_error") and state.get("observation_error") != old.get(
            "observation_error"
        ):
            emit("warning", message=state["observation_error"])
        self.entry["state"] = state
        return state, value["drained"]


class ExecutionSession:
    def __init__(self, folder):
        self.folder = Path(folder)
        self.agent = Path(__file__).resolve().with_name("omo_agent.py")
        self.receipt = self.folder / "session.json"
        self.resources = ExitStack()
        self.connections = {}
        self.results = {}
        self.data = None

    def __enter__(self):
        return self

    def __exit__(self, kind, value, traceback):
        self.resources.close()

    def connection(self, profile):
        key = (
            profile.get("kind", "local"),
            profile.get("host", ""),
            profile.get("agent_root", profile["project_dir"]),
            tuple(profile.get("ssh_options", [])),
        )
        if key not in self.connections:
            endpoint = {
                **profile,
                "project_dir": profile.get("agent_root", profile["project_dir"]),
            }
            self.connections[key] = self.resources.enter_context(
                Connection(endpoint, self.agent)
            )
        return self.connections[key]

    def checkpoint(self):
        write(self.receipt, self.data)

    def record(self, event):
        if event.get("event") == "finish":
            self.results[event["id"]] = event
            write(
                self.folder / "results.json",
                {
                    "total": self.data["total"],
                    "completed": len(self.results),
                    "runs": list(self.results.values()),
                },
            )

    def prepare(self, config, root, mode):
        if self.receipt.exists():
            raise ValueError(
                "This output directory already owns an execution session; reconnect or choose another directory"
            )
        self.folder.mkdir(parents=True, exist_ok=True)
        launch = self.folder / "launch.json"
        if not launch.exists():
            write(launch, {**config, "project": str(root)})
        baseline = execution_manifest(config, root, self.folder, mode)
        connections = {p["id"]: self.connection(p) for p in baseline["profiles"]}
        prepared = source_config(config, root, baseline, connections)
        manifest = execution_manifest(prepared, root, self.folder, mode)
        write(self.folder / "manifest.json", manifest)
        entries = []
        for allocation in manifest["allocations"]:
            profile = allocation["profile"]
            job = uuid.uuid4().hex
            launcher = (
                ["salloc", *allocation_args(allocation["slurm"])]
                if allocation["slurm"] is not None and mode != "submit"
                else []
            )
            request = {
                "job": job,
                "revision": profile.get("revision"),
                "script": script(
                    prepared,
                    manifest,
                    allocation,
                    "run" if mode == "submit" else mode,
                    mode == "submit",
                ),
                "scheduler": "slurm" if mode == "submit" else "process",
                "launcher": launcher,
                "setup": setup_lines(profile),
                "resources": (
                    allocation["batch_resources"]
                    if mode == "submit"
                    else allocation["slurm"] or {}
                ),
                "server": profile["id"],
                "allocation": allocation["id"],
                "client_folder": str(self.folder),
                "expected_runs": (
                    allocation["run_ids"] if mode in {"run", "submit"} else []
                ),
                "expected_build": (
                    profile["id"] if mode in {"build", "configure"} else None
                ),
                "trial_logs": {
                    str(r["id"]): r["folder"] + "/output.log"
                    for r in manifest["runs"]
                    if r["id"] in allocation["run_ids"]
                },
            }
            entries.append(
                {
                    "job": job,
                    "profile": profile,
                    "allocation": allocation["id"],
                    "server": profile["id"],
                    "client_folder": str(self.folder),
                    "request": request,
                    "attempted": False,
                }
            )
        self.data = {
            "mode": mode,
            "total": manifest["total"],
            "stop_on_failure": manifest["stop_on_failure"],
            "entries": entries,
        }
        self.checkpoint()
        emit("session", folder=str(self.folder), mode=mode)

    def restore(self):
        self.data = read(self.receipt)
        emit("session", folder=str(self.folder), mode=self.data["mode"])

    def observer(self, entry):
        return JobObserver(
            self.connection(entry["profile"]), entry, self.folder, self.record
        )

    def launch(self, entry):
        entry["attempted"] = True
        self.checkpoint()
        self.connection(entry["profile"]).request("launch", entry["request"])

    def follow(self, entry, submission):
        observer = self.observer(entry)
        while True:
            state, drained = observer.observe()
            self.checkpoint()
            if drained and (
                state["terminal"] or (submission and state["job_id"] is not None)
            ):
                return state["exit_code"] or 0
            time.sleep(0.2)

    def execute(self, submission):
        code = 0
        try:
            for entry in self.data["entries"]:
                self.launch(entry)
                status = self.follow(entry, submission)
                code = max(code, status)
                if status and self.data["stop_on_failure"]:
                    break
        except KeyboardInterrupt:
            self.cancel()
            emit("canceled")
            return 130
        emit(
            "complete",
            total=self.data["total"],
            completed=len(self.results),
            failed=sum(e["exit_code"] != 0 for e in self.results.values()),
        )
        return code

    def cancel(self):
        for entry in self.data["entries"]:
            if entry["attempted"]:
                self.connection(entry["profile"]).request(
                    "cancel", {"job": entry["job"]}
                )
        emit("cancel_requested")
        return 0

    def poll(self):
        for entry in self.data["entries"]:
            if entry["attempted"]:
                self.observer(entry).observe()
        self.checkpoint()
        return 0


def run(config, root, folder, mode):
    with ExecutionSession(folder) as session:
        session.prepare(config, root, mode)
        return session.execute(mode == "submit")


def submit(config, root, folder):
    return run(config, root, folder, "submit")


def job_action(folder, action):
    with ExecutionSession(folder) as session:
        session.restore()
        return {
            "poll": session.poll,
            "cancel": session.cancel,
            "reconnect": lambda: session.execute(False),
        }[action]()


def synchronize(config, root, folder):
    with ExecutionSession(folder) as session:
        baseline = plan(config, root, folder, False)
        for profile in baseline["profiles"]:
            validate_profile(profile, None, 1)
        connections = {p["id"]: session.connection(p) for p in baseline["profiles"]}
        source_config(config, root, baseline, connections)
    emit("sync_complete")
    return 0


def dispatch(args):
    if args.action == "parse-args":
        print(json.dumps(shlex.split(args.text)))
        return 0
    if args.action == "format":
        write(args.config, read(args.config))
        return 0
    if args.action in {"poll", "cancel", "reconnect", "log"}:
        if not args.output_dir:
            raise ValueError("Use --output-dir for the saved execution session")
        folder = Path(args.output_dir).resolve()
        if args.action != "log":
            return job_action(folder, args.action)
        if args.run_id is None:
            raise ValueError("Use --run-id to view a trial log")
        with ExecutionSession(folder) as session:
            session.data = read(session.receipt)
            entry = next(
                (
                    e
                    for e in session.data["entries"]
                    if args.run_id in e["request"]["expected_runs"]
                ),
                None,
            )
            if entry is None:
                raise ValueError("Unknown run ID")
            result = session.connection(entry["profile"]).request(
                "trial_log", {"job": entry["job"], "run_id": args.run_id}
            )
            print(base64.b64decode(result["data"]).decode(errors="replace"), end="")
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
    if args.action == "targets":
        if args.output_dir and (folder / "session.json").is_file():
            with ExecutionSession(folder) as session:
                session.data = read(session.receipt)
                entry = session.data["entries"][0]
                result = session.connection(entry["profile"]).request(
                    "targets",
                    {
                        "job": entry["job"],
                        "build_dir": config.get("build", {}).get("directory", "build"),
                    },
                )
                print(json.dumps(result))
                return 0
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
    if args.action == "export":
        manifest = export(config, root, folder)
        emit("exported", folder=str(folder), total=manifest["total"])
        return 0
    if args.action == "sync":
        return synchronize(config, root, folder)
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
            "sync",
            "reconnect",
        ],
    )
    parser.add_argument("config")
    parser.add_argument("--project")
    parser.add_argument("--library")
    parser.add_argument("--output-dir")
    parser.add_argument("--run-id", type=int)
    parser.add_argument("--text")
    previous = {
        sig: signal.signal(sig, lambda *_: (_ for _ in ()).throw(Detached()))
        for sig in (signal.SIGTERM, signal.SIGHUP)
    }
    try:
        return dispatch(parser.parse_args(argv))
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (Detached, ConnectionError) as error:
        emit(
            "disconnected",
            message=str(error)
            or "Observer detached; reconnect to inspect the saved job",
        )
        sys.exit(3)
    except KeyboardInterrupt:
        emit("canceled")
        sys.exit(130)
    except (
        ValueError,
        RuntimeError,
        OSError,
        subprocess.CalledProcessError,
        KeyError,
    ) as error:
        emit("error", message=str(error))
        sys.exit(2)
