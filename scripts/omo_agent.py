#!/usr/bin/env python3
"""OMO's POSIX remote project store and detached job supervisor (stdlib only)."""

from __future__ import annotations

import argparse
import base64
from collections import deque
import copy
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time
import uuid

PROTOCOL = 1
MARKER = "@@OVERSEER "
TERMINAL = {"SUCCESS": 0, "FAILURE": 1, "CANCELED": 130, "LOST": 2}


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def digest(value):
    return hashlib.sha256(encoded(value)).hexdigest()


def atomic_json(path, value):
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex)
    with temporary.open("wb") as stream:
        stream.write(encoded(value))
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def read_json(path):
    return json.loads(path.read_text())


def safe_token(value, size):
    if not isinstance(value, str) or not re.fullmatch(
        "[a-f0-9]{" + str(size) + "}", value
    ):
        raise ValueError("Invalid object, revision, or job identifier")
    return value


def safe_path(value):
    path = PurePosixPath(value)
    if (
        not value
        or path.is_absolute()
        or ".." in path.parts
        or value != path.as_posix()
    ):
        raise ValueError("Invalid relative source path")
    return path


def validate_manifest(manifest):
    seen = set()
    mounts = manifest["mounts"]
    for mount in mounts:
        if len(safe_path(mount).parts) != 1:
            raise ValueError("Data mounts must be top-level paths")
    for entry in manifest["files"]:
        path = safe_path(entry["path"])
        if path.parts[0] == ".omo" or entry["path"] in seen:
            raise ValueError("Invalid or duplicate source path")
        if any(
            path == PurePosixPath(m) or PurePosixPath(m) in path.parents for m in mounts
        ):
            raise ValueError("Source path overlaps a remote data mount")
        if entry["kind"] == "file":
            safe_token(entry["sha"], 64)
            if not isinstance(entry["mode"], int) or not 0 <= entry["mode"] <= 0o777:
                raise ValueError("Invalid source file mode")
        elif entry["kind"] == "link":
            target = PurePosixPath(entry["target"])
            combined = os.path.normpath(str(path.parent / target))
            if target.is_absolute() or combined == ".." or combined.startswith("../"):
                raise ValueError("Source symlink points outside the workspace")
        else:
            raise ValueError("Unsupported source entry")
        seen.add(entry["path"])
    links = {e["path"] for e in manifest["files"] if e["kind"] == "link"}
    for entry in manifest["files"]:
        if any(str(p) in links for p in PurePosixPath(entry["path"]).parents):
            raise ValueError("Source path traverses a symlink")
    return digest(manifest)


def process_identity(pid):
    try:
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        return None if fields[0] == "Z" else {"pid": pid, "birth": fields[19]}
    except FileNotFoundError:
        return None


def alive(identity):
    return bool(identity and process_identity(identity["pid"]) == identity)


def append_event(folder, event, values):
    with (folder / "output.log").open("ab") as stream:
        stream.write((MARKER + json.dumps({"event": event, **values}) + "\n").encode())


def successful(request, folder):
    events = []
    for line in (folder / "output.log").read_text(errors="replace").splitlines():
        if line.startswith(MARKER):
            try:
                events.append(json.loads(line[len(MARKER) :]))
            except ValueError:
                pass
    finished = {e["id"]: e for e in events if e.get("event") == "finish"}
    return all(
        i in finished and finished[i]["exit_code"] == 0
        for i in request["expected_runs"]
    ) and (
        request["expected_build"] is None
        or any(
            e.get("event") == "built" and e.get("server") == request["expected_build"]
            for e in events
        )
    )


class ProjectStore:
    def __init__(self, root):
        if not Path(root).is_absolute():
            raise ValueError("Project directory must be absolute")
        self.root = Path(root).resolve()
        self.directory = self.root / ".omo"
        for name in ("objects", "workspaces", "jobs", "locks"):
            (self.directory / name).mkdir(parents=True, exist_ok=True, mode=0o700)

    def folder(self, job):
        return self.directory / "jobs" / safe_token(job, 32)

    def update(self, folder, values):
        with (folder / "state.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            state = read_json(folder / "state.json")
            state.update(values)
            atomic_json(folder / "state.json", state)
            return state

    def finish(self, folder, status):
        return self.update(
            folder,
            {
                "status": status,
                "terminal": True,
                "exit_code": TERMINAL[status],
                "finished_at": time.time(),
            },
        )

    def sync_begin(self, request):
        manifest = request["manifest"]
        revision = validate_manifest(manifest)
        missing = sorted(
            {
                e["sha"]
                for e in manifest["files"]
                if e["kind"] == "file"
                and not (self.directory / "objects" / e["sha"]).is_file()
            }
        )
        return {"revision": revision, "missing": missing}

    def sync_chunk(self, request):
        sha = safe_token(request["sha"], 64)
        transfer = safe_token(request["transfer"], 32)
        target = self.directory / "objects" / sha
        temporary = target.with_name(sha + "." + transfer + ".part")
        offset = request["offset"]
        if (
            not isinstance(offset, int)
            or offset < 0
            or (temporary.stat().st_size if temporary.exists() else 0) != offset
        ):
            raise ValueError("Source transfer offset does not match")
        data = base64.b64decode(request["data"], validate=True)
        if len(data) > 256 * 1024:
            raise ValueError("Source chunk is too large")
        with temporary.open("ab") as stream:
            stream.write(data)
        if request["final"]:
            hasher = hashlib.sha256()
            with temporary.open("rb") as stream:
                for chunk in iter(lambda: stream.read(256 * 1024), b""):
                    hasher.update(chunk)
            if hasher.hexdigest() != sha:
                temporary.unlink()
                raise ValueError("Source content checksum mismatch")
            temporary.replace(target)
        return {"offset": offset + len(data)}

    def sync_commit(self, request):
        manifest = request["manifest"]
        revision = validate_manifest(manifest)
        parent = self.directory / "workspaces" / revision
        destination = parent / "source"
        with (self.directory / "locks" / (revision + ".publish")).open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            if not destination.is_dir():
                stage = (
                    self.directory / "workspaces" / (revision + "." + uuid.uuid4().hex)
                )
                source = stage / "source"
                source.mkdir(parents=True)
                try:
                    for entry in manifest["files"]:
                        path = source / entry["path"]
                        path.parent.mkdir(parents=True, exist_ok=True)
                        if entry["kind"] == "link":
                            path.symlink_to(entry["target"])
                        else:
                            obj = self.directory / "objects" / entry["sha"]
                            if not obj.is_file():
                                raise ValueError("Revision has missing content")
                            shutil.copyfile(obj, path)
                            path.chmod(entry["mode"] & 0o555)
                    for mount in manifest["mounts"]:
                        (source / mount).symlink_to(
                            self.root / mount, target_is_directory=True
                        )
                    atomic_json(stage / "manifest.json", manifest)
                    stage.replace(parent)
                finally:
                    if stage.exists():
                        shutil.rmtree(stage)
        return {"revision": revision, "workspace": str(destination)}

    def launch(self, request):
        folder = self.folder(request["job"])
        if request["scheduler"] not in EXECUTIONS:
            raise ValueError("Unknown scheduler")
        revision = request["revision"]
        cwd = (
            self.root
            if revision is None
            else self.directory / "workspaces" / safe_token(revision, 64) / "source"
        )
        if not cwd.is_dir():
            raise ValueError("Source revision has not been published")
        fingerprint = digest(request)
        with (self.directory / "locks/launch").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            if folder.exists():
                state = read_json(folder / "state.json")
                if state["fingerprint"] != fingerprint:
                    raise ValueError(
                        "Job identifier already belongs to a different request"
                    )
                return state
            folder.mkdir(mode=0o700)
            atomic_json(folder / "request.json", {**request, "cwd": str(cwd)})
            (folder / "script.sh").write_text(request["script"])
            (folder / "output.log").touch()
            state = {
                "job": request["job"],
                "fingerprint": fingerprint,
                "status": "QUEUED",
                "terminal": False,
                "exit_code": None,
                "created_at": time.time(),
                "worker": None,
                "child": None,
                "job_id": None,
                "scheduler": request["scheduler"],
                "revision": revision,
            }
            atomic_json(folder / "state.json", state)
            try:
                with (folder / "worker.log").open("ab") as errors:
                    process = subprocess.Popen(
                        [
                            sys.executable,
                            str(Path(__file__).resolve()),
                            "worker",
                            "--root",
                            str(self.root),
                            "--job",
                            request["job"],
                        ],
                        stdin=subprocess.DEVNULL,
                        stdout=errors,
                        stderr=errors,
                        start_new_session=True,
                        close_fds=True,
                    )
            except OSError:
                self.finish(folder, "FAILURE")
                raise
            return read_json(folder / "state.json")

    def refresh(self, folder):
        state = read_json(folder / "state.json")
        if state["terminal"]:
            return state
        execution = EXECUTIONS[state["scheduler"]](
            self, folder, read_json(folder / "request.json")
        )
        if execution.is_managed(state):
            return execution.refresh(state)
        if (state["worker"] and not alive(state["worker"])) or (
            state["worker"] is None and time.time() - state["created_at"] > 5
        ):
            if alive(state["child"]):
                try:
                    os.killpg(state["child"]["pid"], signal.SIGKILL)
                except ProcessLookupError:
                    pass
            append_event(
                folder,
                "error",
                {"message": "Job supervisor was lost; job was not relaunched"},
            )
            return self.finish(folder, "LOST")
        return state

    def observe(self, request):
        folder = self.folder(request["job"])
        state = self.refresh(folder)
        cursor = request["cursor"]
        size = (folder / "output.log").stat().st_size
        if not isinstance(cursor, int) or not 0 <= cursor <= size:
            raise ValueError("Log cursor is outside the saved output")
        with (folder / "output.log").open("rb") as stream:
            stream.seek(cursor)
            data = stream.read(256 * 1024)
        return {
            "state": state,
            "data": base64.b64encode(data).decode(),
            "cursor": cursor + len(data),
            "drained": cursor + len(data) == size,
        }

    def cancel(self, request):
        folder = self.folder(request["job"])
        state = self.refresh(folder)
        if not state["terminal"]:
            (folder / "cancel").touch()
            execution = EXECUTIONS[state["scheduler"]](
                self, folder, read_json(folder / "request.json")
            )
            if execution.is_managed(state):
                execution.cancel(state)
        return read_json(folder / "state.json")

    def trial_log(self, request):
        folder = self.folder(request["job"])
        launch = read_json(folder / "request.json")
        path = Path(launch["trial_logs"][str(request["run_id"])])
        with path.open("rb") as source:
            data = b"".join(deque(source, maxlen=300))
        return {"data": base64.b64encode(data).decode()}

    def list_jobs(self):
        return [
            self.refresh(path.parent)
            for path in sorted((self.directory / "jobs").glob("*/state.json"))
        ]

    def targets(self, request):
        launch = read_json(self.folder(request["job"]) / "request.json")
        root = Path(launch["cwd"])
        directory = root / request["build_dir"]
        reply = directory / ".cmake/api/v1/reply"
        indexes = sorted(reply.glob("index-*.json"))
        targets = {}
        if indexes:
            for obj in read_json(indexes[-1]).get("objects", []):
                if obj["kind"] == "codemodel":
                    for configuration in read_json(reply / obj["jsonFile"]).get(
                        "configurations", []
                    ):
                        for target in configuration.get("targets", []):
                            data = read_json(reply / target["jsonFile"])
                            if data.get("type") == "EXECUTABLE" and data.get(
                                "artifacts"
                            ):
                                path = directory / data["artifacts"][0]["path"]
                                targets[target["name"]] = {
                                    "id": target["name"],
                                    "binary": os.path.relpath(path, root),
                                }
        return sorted(targets.values(), key=lambda value: value["id"])

    def worker(self, job):
        folder = self.folder(job)
        request = read_json(folder / "request.json")
        self.update(folder, {"worker": process_identity(os.getpid())})
        execution = EXECUTIONS[request["scheduler"]](self, folder, request)
        key = request["revision"] or "local"
        with (self.directory / "locks" / (key + ".execute")).open("a") as lock:
            while True:
                if (folder / "cancel").exists():
                    self.finish(folder, "CANCELED")
                    return
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    time.sleep(0.05)
            try:
                execution.execute()
            except Exception as error:
                append_event(folder, "error", {"message": str(error)})
                self.finish(folder, "FAILURE")


class ProcessExecution:
    def __init__(self, store, folder, request):
        self.store, self.folder, self.request = store, folder, request

    def is_managed(self, state):
        return False

    def refresh(self, state):
        return state

    def cancel(self, state):
        return state

    def execute(self):
        command = (
            "set -e\n"
            + ("\n".join(self.request["setup"]) if self.request["launcher"] else "")
            + "\nexec "
            + shlex.join(
                [*self.request["launcher"], "bash", str(self.folder / "script.sh")]
            )
        )
        with (self.folder / "output.log").open("ab") as output:
            process = subprocess.Popen(
                ["bash", "-lc", command],
                cwd=self.request["cwd"],
                stdin=subprocess.DEVNULL,
                stdout=output,
                stderr=subprocess.STDOUT,
                start_new_session=True,
                close_fds=True,
            )
            self.store.update(
                self.folder,
                {"status": "RUNNING", "child": process_identity(process.pid)},
            )
            canceled = None
            while process.poll() is None:
                if (self.folder / "cancel").exists():
                    if canceled is None:
                        canceled = time.monotonic()
                        os.killpg(process.pid, signal.SIGTERM)
                    elif time.monotonic() - canceled > 3:
                        os.killpg(process.pid, signal.SIGKILL)
                time.sleep(0.05)
            if canceled is not None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        status = (
            "CANCELED"
            if (self.folder / "cancel").exists()
            else (
                "SUCCESS"
                if process.returncode == 0 and successful(self.request, self.folder)
                else "FAILURE"
            )
        )
        self.store.finish(self.folder, status)


class SlurmExecution:
    def __init__(self, store, folder, request):
        self.store, self.folder, self.request = store, folder, request

    def command(self, argv, text):
        setup = "\n".join(self.request["setup"])
        command = "set -e\n" + setup + "\nexec " + shlex.join(argv)
        result = subprocess.run(
            ["bash", "-lc", command],
            input=text,
            text=True,
            capture_output=True,
            cwd=self.request["cwd"],
        )
        if result.returncode != 0:
            detail = (result.stdout + result.stderr).strip()
            raise RuntimeError("Slurm command failed: " + detail)
        return result

    def is_managed(self, state):
        return state["job_id"] is not None

    def execute(self):
        result = self.command(
            [
                "sbatch",
                "--parsable",
                "--open-mode=append",
                "--output=" + str(self.folder / "output.log"),
                "--error=" + str(self.folder / "output.log"),
            ],
            self.request["script"],
        )
        job_id = result.stdout.strip().split(";", 1)[0]
        if not job_id.isdigit():
            raise ValueError("Unexpected sbatch job ID: " + result.stdout)
        state = self.store.update(
            self.folder, {"status": "SUBMITTED", "job_id": job_id, "last_poll": 0}
        )
        append_event(
            self.folder,
            "submitted",
            {
                "server": self.request["server"],
                "allocation": self.request["allocation"],
                "slurm": self.request["resources"],
                "job_id": job_id,
                "folder": self.request["client_folder"],
            },
        )
        if (self.folder / "cancel").exists():
            self.cancel(state)

    def refresh(self, state):
        if time.time() - state.get("last_poll", 0) < 2:
            return state
        try:
            result = self.command(
                ["squeue", "--noheader", "--jobs", state["job_id"], "--format", "%T"],
                None,
            )
            status = result.stdout.strip()
            if not status:
                result = self.command(
                    [
                        "sacct",
                        "--noheader",
                        "--parsable2",
                        "--jobs",
                        state["job_id"],
                        "--format",
                        "JobIDRaw,State",
                    ],
                    None,
                )
                status = next(
                    (
                        line.split("|")[1].split()[0].rstrip("+")
                        for line in result.stdout.splitlines()
                        if line.split("|")[0] == state["job_id"]
                    ),
                    "UNKNOWN",
                )
            self.store.update(
                self.folder,
                {"status": status, "last_poll": time.time(), "observation_error": None},
            )
            if status == "COMPLETED":
                return self.store.finish(
                    self.folder,
                    "SUCCESS" if successful(self.request, self.folder) else "FAILURE",
                )
            if status.startswith("CANCELLED") or status == "CANCELED":
                return self.store.finish(self.folder, "CANCELED")
            if status in {
                "FAILED",
                "TIMEOUT",
                "NODE_FAIL",
                "OUT_OF_MEMORY",
                "BOOT_FAIL",
                "DEADLINE",
                "PREEMPTED",
                "REVOKED",
            }:
                return self.store.finish(self.folder, "FAILURE")
        except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
            self.store.update(
                self.folder, {"last_poll": time.time(), "observation_error": str(error)}
            )
        return read_json(self.folder / "state.json")

    def cancel(self, state):
        self.command(["scancel", state["job_id"]], None)
        self.store.update(self.folder, {"last_poll": 0})


EXECUTIONS = {"process": ProcessExecution, "slurm": SlurmExecution}


def serve(root):
    try:
        store = ProjectStore(root)
    except OSError as error:
        print(
            json.dumps(
                {
                    "protocol": PROTOCOL,
                    "error": "Cannot open the configured project directory: "
                    + str(error),
                }
            ),
            flush=True,
        )
        return
    operations = {
        "sync_begin": store.sync_begin,
        "sync_chunk": store.sync_chunk,
        "sync_commit": store.sync_commit,
        "launch": store.launch,
        "observe": store.observe,
        "cancel": store.cancel,
        "trial_log": store.trial_log,
        "targets": store.targets,
    }
    print(json.dumps({"protocol": PROTOCOL}), flush=True)
    for line in sys.stdin:
        try:
            message = json.loads(line)
            result = operations[message["op"]](message["request"])
            response = {"result": result}
        except Exception as error:
            response = {"error": str(error)}
        print(json.dumps(response), flush=True)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--version",
        action="version",
        version="Oh My Overseer agent protocol " + str(PROTOCOL),
    )
    parser.add_argument("action", choices=("serve", "worker", "list", "logs", "cancel"))
    parser.add_argument("--root", required=True)
    parser.add_argument("--job")
    args = parser.parse_args(argv)
    if args.action == "serve":
        serve(args.root)
    elif args.action == "worker":
        ProjectStore(args.root).worker(safe_token(args.job, 32))
    elif args.action == "list":
        print(json.dumps(ProjectStore(args.root).list_jobs(), indent=2))
    elif args.action == "logs":
        store = ProjectStore(args.root)
        sys.stdout.buffer.write((store.folder(args.job) / "output.log").read_bytes())
    else:
        print(json.dumps(ProjectStore(args.root).cancel({"job": args.job})))


if __name__ == "__main__":
    main(sys.argv[1:])
