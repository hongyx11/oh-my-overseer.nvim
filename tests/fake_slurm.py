#!/usr/bin/env python3
"""An isolated executable scheduler fixture; never contacts Slurm."""

import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys


def main(argv):
    root = Path(os.environ["OMO_FAKE_SLURM"])
    root.mkdir(parents=True, exist_ok=True)
    name = Path(argv[0]).name
    args = argv[1:]
    text = sys.stdin.read() if name == "sbatch" else None
    with (root / "calls.jsonl").open("a") as stream:
        stream.write(json.dumps({"argv": [name, *args], "input": text}) + "\n")
    if name == "sbatch":
        with (root / "counter").open("a+") as counter:
            fcntl.flock(counter, fcntl.LOCK_EX)
            counter.seek(0)
            number = int(counter.read() or "300") + 1
            counter.seek(0)
            counter.truncate()
            counter.write(str(number))
        (root / (str(number) + ".sbatch")).write_text(text)
        status = "RUNNING"
        if os.environ.get("OMO_FAKE_SLURM_RUN") == "1":
            output = next(a.split("=", 1)[1] for a in args if a.startswith("--output="))
            with Path(output).open("ab") as stream:
                result = subprocess.run(
                    ["bash", "-c", text], stdout=stream, stderr=stream
                )
            status = "COMPLETED" if result.returncode == 0 else "FAILED"
        (root / (str(number) + ".state")).write_text(status)
        print(number)
    elif name == "scancel":
        (root / (args[0] + ".state")).write_text("CANCELLED")
    elif name in {"squeue", "sacct"}:
        job = args[args.index("--jobs") + 1]
        status = (root / (job + ".state")).read_text()
        if name == "sacct":
            print(job + "|" + status + "|")
        elif status not in {"COMPLETED", "FAILED", "CANCELLED"}:
            print(status)
    elif name in {"salloc", "srun"}:
        while args and args[0].startswith("--"):
            args.pop(0)
        os.execvp(args[0], args)
    else:
        raise ValueError("Unknown fixture command: " + name)


if __name__ == "__main__":
    main(sys.argv)
