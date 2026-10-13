"""Source capture, incremental publication, and SSH transport for OMO sessions."""

from __future__ import annotations

import base64
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import selectors
import shlex
import subprocess
import sys
import tempfile
import uuid

SOURCE_EXCLUDES = (
    ".git",
    ".omo",
    ".overseer",
    ".nvim",
    ".cache",
    ".testenv",
    "__pycache__",
    ".venv",
    "venv",
    "build*/",
    "cmake-build*/",
    "dataset/",
    "datasets/",
    "results/",
    "compile_commands.json",
)
CHUNK = 256 * 1024


def excluded(relative, directory, patterns):
    for raw in patterns:
        if raw.endswith("/") and not directory:
            continue
        pattern = raw.strip("/")
        if fnmatch.fnmatchcase(relative, pattern):
            return True
        if "/" not in pattern and any(
            fnmatch.fnmatchcase(p, pattern) for p in Path(relative).parts
        ):
            return True
    return False


class SourceSnapshot:
    def __init__(self, root, patterns, mounts):
        self.temporary = tempfile.TemporaryDirectory(prefix="omo source capture ")
        self.objects = Path(self.temporary.name)
        self.manifest = {"files": [], "mounts": sorted(mounts)}
        self.root = Path(root).resolve()
        if not self.root.is_dir():
            self.temporary.cleanup()
            raise ValueError("Source project directory does not exist")
        policy = [*SOURCE_EXCLUDES, *patterns, *mounts]
        try:
            for parent, directories, files in os.walk(self.root, followlinks=False):
                parent = Path(parent)
                kept = []
                for name in sorted(directories):
                    path = parent / name
                    relative = path.relative_to(self.root).as_posix()
                    if excluded(relative, True, policy):
                        continue
                    if path.is_symlink():
                        files.append(name)
                    else:
                        kept.append(name)
                directories[:] = kept
                for name in sorted(files):
                    path = parent / name
                    relative = path.relative_to(self.root).as_posix()
                    if excluded(relative, False, policy):
                        continue
                    if path.is_symlink():
                        target = os.readlink(path)
                        if Path(
                            target
                        ).is_absolute() or not path.resolve().is_relative_to(self.root):
                            raise ValueError(
                                "Source symlink points outside the project: " + relative
                            )
                        entry = {"path": relative, "kind": "link", "target": target}
                    else:
                        hasher = hashlib.sha256()
                        temporary = self.objects / uuid.uuid4().hex
                        mode = path.stat().st_mode & 0o777
                        with path.open("rb") as source, temporary.open(
                            "wb"
                        ) as captured:
                            for chunk in iter(lambda: source.read(CHUNK), b""):
                                hasher.update(chunk)
                                captured.write(chunk)
                        sha = hasher.hexdigest()
                        temporary.replace(self.objects / sha)
                        entry = {
                            "path": relative,
                            "kind": "file",
                            "mode": mode,
                            "sha": sha,
                        }
                    self.manifest["files"].append(entry)
            self.manifest["files"].sort(key=lambda item: item["path"])
        except Exception:
            self.temporary.cleanup()
            raise

    def __enter__(self):
        return self

    def __exit__(self, kind, value, traceback):
        self.temporary.cleanup()

    def publish(self, connection, context):
        manifest = {**self.manifest, "build_context": context}
        result = connection.request("sync_begin", {"manifest": manifest})
        for sha in result["missing"]:
            transfer = uuid.uuid4().hex
            offset = 0
            with (self.objects / sha).open("rb") as stream:
                chunk = stream.read(CHUNK)
                while True:
                    following = stream.read(CHUNK)
                    connection.request(
                        "sync_chunk",
                        {
                            "sha": sha,
                            "transfer": transfer,
                            "offset": offset,
                            "data": base64.b64encode(chunk).decode(),
                            "final": not following,
                        },
                    )
                    offset += len(chunk)
                    if not following:
                        break
                    chunk = following
        published = connection.request("sync_commit", {"manifest": manifest})
        return {
            **published,
            "uploaded": len(result["missing"]),
            "files": len(self.manifest["files"]),
        }


def ssh_arguments(profile, sockets):
    return [
        "ssh",
        "-T",
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=10",
        *profile.get("ssh_options", []),
        "-o",
        "ControlMaster=auto",
        "-o",
        "ControlPersist=10m",
        "-o",
        "ControlPath=" + str(sockets / "%C"),
        profile["host"],
    ]


class LocalTransport:
    def __init__(self, profile, agent):
        self.profile, self.agent = profile, agent

    def command(self):
        return [
            sys.executable,
            str(self.agent),
            "serve",
            "--root",
            self.profile["project_dir"],
        ]


class SshTransport:
    def __init__(self, profile, agent):
        self.profile, self.agent = profile, agent
        sockets = Path.home() / ".cache/omo/ssh"
        sockets.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.ssh = ssh_arguments(profile, sockets)

    def command(self):
        content = self.agent.read_bytes()
        sha = hashlib.sha256(content).hexdigest()
        bootstrap = (
            "import hashlib,os,pathlib,sys,uuid; "
            "data=sys.stdin.buffer.read(); "
            "assert hashlib.sha256(data).hexdigest()==" + repr(sha) + "; "
            "root=pathlib.Path.home()/'.local/share/omo/agents'/" + repr(sha) + "; "
            "root.mkdir(parents=True,exist_ok=True,mode=448); "
            "path=root/'omo_agent.py'; temp=root/uuid.uuid4().hex; "
            "temp.write_bytes(data); temp.chmod(448); os.replace(temp,path); "
            "bindir=pathlib.Path.home()/'.local/bin'; bindir.mkdir(parents=True,exist_ok=True); "
            "link=bindir/'omo'; "
            "assert not link.exists() or (link.is_symlink() and link.resolve().is_relative_to(root.parent)), 'Existing omo executable belongs to another installation'; "
            "alias=bindir/('omo.'+uuid.uuid4().hex); alias.symlink_to(path); os.replace(alias,link); "
            "print(path)"
        )
        python = self.profile.get("python", "python3")
        result = subprocess.run(
            [*self.ssh, shlex.join([python, "-c", bootstrap])],
            input=content,
            capture_output=True,
            check=True,
            timeout=30,
        )
        remote_agent = result.stdout.decode().strip()
        if not remote_agent.startswith("/") or "\n" in remote_agent:
            raise ValueError("Remote agent bootstrap returned an invalid path")
        return [
            *self.ssh,
            shlex.join(
                [python, remote_agent, "serve", "--root", self.profile["project_dir"]]
            ),
        ]


TRANSPORTS = {"local": LocalTransport, "ssh": SshTransport}


class Connection:
    def __init__(self, profile, agent):
        self.errors = tempfile.TemporaryFile()
        self.process = None
        self.timeout = profile.get("agent_timeout", 60)
        transport = TRANSPORTS[profile.get("kind", "local")](profile, agent)
        try:
            self.process = subprocess.Popen(
                transport.command(),
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=self.errors,
                text=True,
                bufsize=1,
            )
            response = self.receive()
            if response.get("error"):
                raise RuntimeError(response["error"])
            if response.get("protocol") != 1:
                raise ValueError("Remote agent protocol does not match the client")
        except Exception:
            self.close()
            raise

    def __enter__(self):
        return self

    def __exit__(self, kind, value, traceback):
        self.close()

    def receive(self):
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            if not selector.select(self.timeout):
                raise ConnectionError(
                    "OMO agent timed out; reconnect to inspect the job"
                )
        line = self.process.stdout.readline()
        if not line:
            self.errors.seek(0)
            detail = self.errors.read().decode(errors="replace")[-2000:]
            raise ConnectionError("OMO agent disconnected: " + detail.strip())
        try:
            return json.loads(line)
        except ValueError as error:
            raise ConnectionError(
                "OMO agent returned an invalid response: " + line[:200]
            ) from error

    def request(self, operation, request):
        try:
            self.process.stdin.write(
                json.dumps({"op": operation, "request": request}) + "\n"
            )
            self.process.stdin.flush()
        except (BrokenPipeError, OSError) as error:
            raise ConnectionError(
                "OMO agent disconnected; reconnect to inspect the job"
            ) from error
        result = self.receive()
        if "error" in result:
            raise RuntimeError(result["error"])
        return result["result"]

    def close(self):
        if self.process is not None:
            try:
                self.process.stdin.close()
            except (BrokenPipeError, OSError):
                pass
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                self.process.wait(timeout=2)
            self.process.stdout.close()
            self.process = None
        self.errors.close()
