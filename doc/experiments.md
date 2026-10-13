# Experiments (hongyx11 fork)

An experiment runs the Cartesian product of selected datasets, thread counts,
methods, and server profiles. One controller executes each combination in order;
there is never more than one active trial per interactive experiment. The reusable
right window has configuration, run status, and output views. Failed runs switch
it to their output automatically. Closing the panel keeps the experiment running.

## Start

Requires Python 3.9+, Bash, and Telescope for selection. Enable the results interface:

```lua
require("overseer").setup({
  results = { enabled = true, width = 0.45 },
  experiment = { python = "python3" },
})
```

`:OverseerExperimentInit` creates `.overseer/experiment.json` if missing and opens
it. Set the binary and its real arguments with `e`. Existing files are preserved.
`:OverseerExperiment` toggles the panel; `:OverseerExperimentRun` starts it.

The [SpMV example](../examples/spmv-experiment.json) is configured for SpCraft's
`bench_ompspmv`: two coordinate matrices under `dataset/output`, threads 1/2/4,
and float/double precision variants. Copy it into your SpCraft project's
`.overseer/experiment.json`. These variants use actual `--precision` arguments;
the benchmark does not expose an algorithm `--method` flag. Additional binaries
or algorithm arguments can be configured as methods.

## Panel controls

| Key | Action |
| --- | --- |
| `1`, `2`, `3` | Configuration, runs, live output |
| `p` | Choose a CMake configure preset and its build directory |
| `C` | Configure; creates the CMake File API query for target discovery |
| `T` | Choose a discovered executable target and its binary |
| `b` | Choose an executable file |
| `d`, `t`, `m`, `h` | Select datasets, thread counts, methods, hosts/resources |
| `B`, `r` | Build, run all combinations sequentially |
| Enter in Runs | Read that run's output snapshot (last 300 lines) |
| `w`, `e`, `R` | Save, edit JSON in the source window, reload JSON |
| `E`, `L` | Export a portable bundle, load another config for this project |
| `S`, `u`, `X` | Submit Slurm jobs, refresh their states, cancel recorded jobs |
| `x`, `q` | Stop the interactive operation, close the panel |

In selectors, type to filter and use arrows or Ctrl-n/Ctrl-p to move. **Tab toggles
a checkbox; Enter applies all checked entries.** Ctrl-a selects all entries and
Ctrl-u clears them. Escape closes without applying. Existing selections remain
checked when a selector opens. Selectors save the resulting configuration.

Dataset selection scans `.mtx` files recursively in `datasets.directory`, retaining
existing IDs and remote path mappings for known files. Targets come from CMake's
File API; configure with `C` before selecting `T`. Build commands are explicit
argument arrays: the first command configures, and all commands run for `B` or
before trials when `build.before_run` is true. Selecting a preset updates the
build directory and a binary path beneath the old build directory. It does not
rewrite custom command arrays.

Each launch freezes the configuration into `launch.json`. Editing selections
while an operation runs changes the next launch; its commands remain unchanged.
Restarting an experiment through the results API uses its frozen configuration.
The Runs view and per-run output use the active manifest, even after selections
change. History and existing regular Overseer tasks remain available.

## Configuration

Version 1 uses `choices` and `selected` for each dimension. IDs must be unique
within their dimension. Thread choices can be numbers; methods can be strings
or objects. Paths in a source config are relative to the project, whose path is
relative to the config file (`"project": ".."` for `.overseer/experiment.json`).

```json
{
  "version": 1,
  "name": "SpMV sweep",
  "project": "..",
  "binary": "build/bin/spmv",
  "args": ["--matrix", "${dataset}", "--threads", "${threads}", "--method", "${method}", "--output", "${result}"],
  "environment": { "OMP_NUM_THREADS": "${threads}" },
  "datasets": {
    "directory": "dataset/output",
    "choices": [{ "id": "d1", "path": "dataset/output/d1.mtx" }],
    "selected": ["d1"]
  },
  "threads": { "choices": [1, 2, 4], "selected": [1, 2, 4] },
  "methods": { "choices": ["a", "b", "c"], "selected": ["a", "b", "c"] },
  "servers": { "choices": [{ "id": "local", "kind": "local" }], "selected": ["local"] },
  "output_dir": "results/overseer",
  "stop_on_failure": false
}
```

Replace these argument names with the binary's actual CLI. Supported placeholders
in trial arguments, binary paths, and environments are `${project}`, `${dataset}`,
`${dataset_id}`, `${threads}`, `${method}`, `${server}`, `${run_id}`, `${result}`,
`${run_dir}`, `${preset}`, and `${target}`. Arguments and paths are individually
shell-quoted; avoid embedding shell syntax into argument arrays.

A method object can set `id`, `label`, `value` (the `${method}` value), `args`
(appended to common args), `arguments` (replaces common args), `binary`,
`binaries` (map of server IDs to executables), and `environment`. A server can
also override `binary`, `arguments`, and `environment`. Method overrides take
precedence. Use a launcher executable and replacement arguments for MPI programs.

Optional build configuration:

```json
{
  "preset": "release",
  "target": "spmv",
  "build": {
    "directory": "build/release",
    "jobs": 4,
    "before_run": true,
    "commands": [
      ["cmake", "--preset", "${preset}", "-B", "${build_dir}"],
      ["cmake", "--build", "${build_dir}", "--target", "${target}", "--parallel", "${build_jobs}"]
    ]
  }
}
```

Build placeholders are `${project}`, `${preset}`, `${target}`, `${build_dir}`,
and `${build_jobs}`. A configure/build failure prevents that server's trials.
`stop_on_failure` decides whether a failed trial or server stops subsequent work.

## Hosts and resource profiles

Profiles may share a host while selecting different resources:

```json
{
  "servers": {
    "choices": [
      { "id": "server1", "kind": "ssh", "host": "my-cluster", "project_dir": "/scratch/me/spcraft", "setup": ["module load cuda"] },
      { "id": "server1-gpu", "extends": "server1", "slurm": { "partition": "gpu", "gpus": 1, "cpus_per_task": 4, "time": "00:15:00" } },
      { "id": "server1-h100", "extends": "server1-gpu", "slurm": { "constraint": "h100" } },
      { "id": "server1-a100", "extends": "server1-gpu", "slurm": { "constraint": "a100" } },
      { "id": "server2", "kind": "ssh", "host": "another-host", "project_dir": "/home/me/spcraft" }
    ],
    "selected": ["server1-h100"]
  }
}
```

`host` uses normal SSH configuration; authentication uses BatchMode. Set the real
remote project directory. Code, binaries, datasets, CMake presets, and modules
must already exist there; the runner does not synchronize files. `setup` contains
trusted shell commands. `enabled: false` prevents execution and is inherited;
remove it or set true once a profile is configured.

Dataset `paths` can override a path per profile or its parent, e.g.
`"paths": {"server1": "/datasets/d1.mtx"}`. Relative paths otherwise resolve under
each server's project directory. GPU profiles should select a GPU binary or method;
requesting a GPU alone does not convert an OpenMP binary into a GPU computation.

Supported Slurm fields: `partition`, `account`, `qos`, `constraint`, `gpus`,
`cpus_per_task`, `memory`, `time`, `nodes`, `ntasks`. CPU allocation must cover the
largest selected thread count. The sequential controller uses `ntasks: 1`.
Interactive `r` uses a single `srun` allocation for all trials on a Slurm profile;
a plain SSH profile executes directly. Server profiles execute sequentially.
`S` submits one batch job per selected profile, so separately submitted profiles
may run concurrently while trials within each job stay sequential.

## Export and run outside Neovim

`E` writes a bundle under the configured output directory:

- `experiment.json`: replayable selections with a project-relative path.
- `manifest.json`: expanded commands, environments, resources, and output paths.
- `runner.py`: standalone standard-library Python runner.
- `<profile>.sbatch`: reviewed, expanded batch script for each selected profile.

```bash
python3 runner.py run experiment.json
python3 runner.py build experiment.json
python3 runner.py submit experiment.json --output-dir submitted
python3 runner.py poll experiment.json --output-dir submitted
python3 runner.py cancel experiment.json --output-dir submitted
```

Use `--project /path/to/project` when relocating a bundle. Remote paths remain
explicit. Export does not copy binaries or datasets. To submit a generated script
manually, transfer it to the cluster and run `sbatch <profile>.sbatch`. Batch
scheduler output follows Slurm's default `slurm-%j.out`; each trial also writes
its own output log under the configured remote results directory.

Local runs write `results.json` with exit codes plus numbered per-trial folders
containing `output.log` and, if the binary writes `${result}`, `result.json`.
For remote interactive runs, the aggregate log and completion records are local;
individual trial logs/results remain on the server. Submitted batch completion
is polled with `squeue` then `sacct`; detailed trial logs can be read in the Runs
view over SSH. `jobs.json` records exact job IDs, and `.overseer/state.json` lets
the panel reconnect to those IDs after Neovim restarts. Cancel affects only those
recorded jobs. Submitted progress is job state plus logs, not a live per-trial
status stream. Live per-trial progress is provided for interactive runs.
