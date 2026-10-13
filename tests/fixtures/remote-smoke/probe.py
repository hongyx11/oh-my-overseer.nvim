#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path
import socket
import sys
import time


def benchmark_run(args):
    result = {
        "label": args.label,
        "node": socket.gethostname(),
        "job": os.environ.get("SLURM_JOB_ID"),
        "gpu": os.environ.get("CUDA_VISIBLE_DEVICES"),
    }
    print("PROBE_START " + json.dumps(result), flush=True)
    print("PROBE_STDERR " + args.label, file=sys.stderr, flush=True)
    time.sleep(args.pause)
    Path(args.output).write_text(json.dumps(result))
    print("PROBE_FINISH " + args.label, flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--label", required=True)
    parser.add_argument("--pause", type=float, required=True)
    parser.add_argument("--output", required=True)
    benchmark_run(parser.parse_args())


if __name__ == "__main__":
    main()
