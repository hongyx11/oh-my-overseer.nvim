# Oh My Overseer experiments

Create named experiments, attach reusable options, and run the Cartesian product
of their selected values. Options can be threads, tile size, precision, layout,
iterations, or any other name. `nodes` is reserved for Slurm node requests.

The centered floating panel uses 85% of the editor, resizes with it, and preserves
source splits. Its configuration, runs, and live output views share one float
per tab. Telescope dialogs open above it. `Esc` or `q` returns to the source while
work continues; failures open their output automatically.

## Start and create an experiment

Requires Python 3.9+, Bash, and Telescope for option selection:

```lua
require("overseer").setup({
  results = { enabled = true },
  experiment = {
    python = "python3",
    library = "", -- empty uses stdpath("config")/overseer/option_sets.json
    width = 0.85,
    height = 0.85,
    border = "rounded",
  },
})
```

`:OverseerExperimentInit` creates an empty experiment if none exists and opens
it. `:OverseerExperiment` toggles the panel; `:OverseerExperimentRun` runs the
active experiment. Existing source files are preserved.

1. Press `N`, give the experiment a name, and choose **Start empty** or **Copy
   current settings**. Named files live in `.overseer/experiments/`.
2. Press `a` to attach a shared option or create a new option. New options accept
   a name and comma-separated values, then let you choose a command-line flag,
   environment variable, or placeholder binding.
3. Move with `j`/`k` to an option row and press **Enter** or **m**. Tab toggles a
   checkbox, Ctrl-a selects all, Ctrl-u clears all, and Enter applies the checked
   set. Escape cancels the dialog.
4. Use `s` on an option row to choose or save a named selection preset, edit
   values/bindings, save the option to the shared library, or remove it.
5. Set the preset, target, binary, arguments, and servers by pressing Enter on
   their rows. `C` configures; `T` discovers executable targets through CMake's
   File API after configuration. `B` builds and `r` runs.
6. Press `O` to switch experiments. The active file is remembered per project.

For example, save Threads with presets **development** `[1,2,4]` and **scaling**
`[1,2,4,8,16]`. Attach Threads to SpMV and SpGEMM; each experiment can choose a
different preset or override its selected values without changing the other.

The shared library starts with **Threads** and **Slurm nodes**. Threads supplies
`--threads`, `OMP_NUM_THREADS`, and CPU requirements. An experiment may override
its binding when its binary uses another flag or already includes `${threads}`
in common arguments. Slurm nodes supplies choices 2/4/16, presets **small** and
**scaling**, and the reserved `nodes` binding. It requests resources and does not
append a program flag.

The [SpMV example](../examples/spmv-experiment.json) is self-contained and uses
SpCraft's real `bench_ompspmv` CLI: two coordinate matrices under `dataset/output`,
threads 1/2/4, and float/double variants via `--precision`. Copy it into SpCraft's
`.overseer/experiment.json`. There is no assumed algorithm `--method` flag.

Labels, selected values, paths, and numbers use theme-aware highlights. Option
rows show how many available choices are selected. Success, warning, and failure
colors distinguish run status and important configure/build log messages. The
`OverseerExperiment*` highlight groups can be customized independently of other
editor floats.

## Controls

| Key | Action |
| --- | --- |
| `1`, `2`, `3` | Configuration, runs, latest live output |
| Enter / `m` | Modify the highlighted configuration/option row; inspect a Runs row |
| `a` | Add a shared option or create a new option |
| `s` on an option | Presets, values, bindings, publish, remove |
| `N`, `O` | New/copy experiment, choose saved experiment |
| `p`, `T`, `b` | Choose CMake preset, executable target, binary |
| `C`, `B`, `r` | Configure, build, run combinations sequentially |
| `w`, `e`, `R` | Save, close float and edit JSON, reload |
| `E`, `L` | Export a portable bundle, load another source JSON |
| `S`, `u`, `X` | Submit Slurm jobs, refresh states, cancel recorded jobs |
| `x`, `Esc` / `q` | Stop the active operation, close the float |

`3` follows the current configure/build/run output. Starting an operation clears
old snapshots. Scroll up to pause auto-scroll; press `3` again to follow. Enter
on a Runs row reads its saved output (last 300 lines). Runs are labeled with the
actual option names, so new options require no keymaps or table columns.

Each experiment has its own task, logs, run manifest, and submitted job IDs.
Switching experiments does not stop active work. Each launch captures resolved
choices and bindings into `launch.json`; changing a shared definition or another
experiment cannot change an already launched command. Restart uses this snapshot.

## Parameter-list configuration

Source schema version 2 replaces the fixed dataset/thread/method sections with
an ordered `parameters` list. The original file `.overseer/experiment.json` and
named experiment files use the same schema. Project paths are relative to the
source file: `".."` for the original file, `"../.."` for named experiment files.

```json
{
  "version": 2,
  "name": "SpGEMM tuning",
  "project": "../..",
  "binary": "build/bin/spgemm",
  "args": ["--output", "${result}"],
  "parameters": [
    { "id": "threads", "template": "threads", "preset": "development" },
    {
      "id": "tile_size",
      "label": "Tile size",
      "choices": [8, 16, 32],
      "selected": [8, 16],
      "presets": { "small": [8, 16], "wide": [16, 32] },
      "args": ["--tile-size", "${value}"]
    }
  ],
  "servers": { "choices": [{ "id": "local", "kind": "local" }], "selected": ["local"] },
  "output_dir": "results/overseer",
  "stop_on_failure": false
}
```

Use flags supported by the actual binary. No parameters means one run per server;
an option with no selected values prevents launching. Parameter IDs must be unique
identifiers. IDs `project`, `server`, `run_id`, `result`, `run_dir`, `preset`,
`target`, and `value` belong to the runner. `nodes` has the Slurm semantics below.
Choice IDs must be unique within an option; scalar numbers and strings derive an
ID from their value, and object choices can provide `id`, `label`, and `value`.

`template` references the shared library. `preset` selects a named saved set;
explicit `selected` overrides it. The UI clears `preset` when applying a custom
selection. Overrides of `choices`, `presets`, `args`, `environment`, `slurm`, and
`requirements` belong to the experiment; they do not edit the shared definition.
Saving a selection preset adds the set without replacing shared bindings. Saving
an entire option explicitly publishes its definition; replacing an existing
shared option is a separate dialog choice. Shared changes affect future loads,
not frozen launches or exported bundles.

```json
{
  "version": 1,
  "options": {
    "tile_sizes": {
      "label": "Tile size",
      "choices": [8, 16, 32],
      "presets": { "development": [8, 16], "large": [32] },
      "args": ["--tile-size", "${value}"]
    }
  }
}
```

`${value}` in an option binding is its current selected value. `${tile_size}` or
any other parameter ID can be used in common arguments, environments, binary
paths, and launchers. Other trial placeholders are `${project}`, `${server}`,
`${run_id}`, `${result}`, `${run_dir}`, `${preset}`, and `${target}`. Every argv
item is quoted individually; arguments are arrays, not shell expressions.

Options may define `args` (appended arguments), `environment`, and
`requirements.cpus`. Object choices can append `args`, replace common
`arguments`, override `binary`, provide `binaries` keyed by server or parent
profile ID, or override `launcher` and `environment`. Options are applied in list
order; a later explicit override wins. CPU requirements must be positive and fit
the allocation. Unknown placeholders and selection IDs fail before execution.

A file option uses `source: {"directory":"dataset/output","pattern":"*.mtx"}`
and choices such as `{"id":"d1","path":"dataset/output/d1.mtx"}`. Enter rescans
that directory recursively, preserving known IDs and path metadata. `paths`
can override a dataset per profile or parent, e.g. `{"server1":"/datasets/d1.mtx"}`.
Other paths are relative to each server's project directory.

## Slurm nodes and hosts

```json
{
  "parameters": [
    { "id": "nodes", "template": "nodes", "preset": "scaling" }
  ],
  "servers": {
    "choices": [
      { "id": "server1", "kind": "ssh", "host": "my-cluster", "project_dir": "/scratch/me/project", "slurm": { "partition": "cpu", "time": "00:15:00" } },
      { "id": "server1-gpu", "extends": "server1", "slurm": { "partition": "gpu", "gpus": 1 } },
      { "id": "server1-h100", "extends": "server1-gpu", "slurm": { "constraint": "h100" } },
      { "id": "server1-a100", "extends": "server1-gpu", "slurm": { "constraint": "a100" } }
    ],
    "selected": ["server1"]
  }
}
```

`nodes` must bind `slurm.nodes` to `${value}` and contain positive integer node
counts. It cannot be renamed or bound to a command-line flag. Resource options
require a server profile with `slurm`; selecting local execution without Slurm
fails before requesting resources.

The planner groups trials by server and resolved resource settings. Nodes
2/4/16 produce three allocations/batch scripts. Interactive execution obtains
one `salloc` allocation per group and runs its trials sequentially as `srun`
steps. Batch submission creates one job per group, with a single controller.
Separately submitted jobs may run concurrently. `jobs.json` tracks each allocation
and job ID independently, including multiple allocations on the same host.

A plain serial/OpenMP program uses one task on one node per step. For a distributed
binary, configure a launcher, for example
`"launcher": ["srun","--nodes","${nodes}","--ntasks","${nodes}"]` for one MPI
rank per node. Node requests alone do not turn a serial binary into an MPI program.
Allocation `ntasks` defaults to the node count (or 1 without nodes); explicit task
and CPU settings remain profile policy. [Slurm salloc documentation](https://slurm.schedmd.com/salloc.html)
describes the allocation/controller lifetime.

Supported resource fields: `partition`, `account`, `qos`, `constraint`, `gpus`,
`cpus_per_task`, `memory`, `time`, `nodes`, and `ntasks`. Hosts use normal SSH
configuration with BatchMode authentication. Remote project paths must be absolute;
code, binaries, datasets, modules, and presets must already exist there. `setup`
contains trusted shell commands. `enabled: false` disables an inherited profile.
The runner does not synchronize files or convert an OpenMP binary into a GPU one.

## CMake and export

Build commands are explicit argv arrays. The first configures; all commands run
for `B` or before trials if `build.before_run` is true:

```json
{
  "preset": "release",
  "target": "spgemm",
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
and `${build_jobs}`. Preset selection changes the build directory and a binary
under the old directory without rewriting custom command arrays. Failed builds
prevent that group's trials; `stop_on_failure` controls subsequent work.

`E` exports resolved `experiment.json`, expanded `manifest.json`, standalone
`runner.py`, and one `<allocation>.sbatch` per group. Definitions and selections
are embedded, so the bundle needs neither Neovim nor the shared option library:

```bash
python3 runner.py run experiment.json
python3 runner.py submit experiment.json --output-dir submitted
python3 runner.py poll experiment.json --output-dir submitted
python3 runner.py cancel experiment.json --output-dir submitted
```

Use `--project /path/to/project` after relocating a bundle. Source configs with
shared references require `--library /path/to/option_sets.json` outside Neovim.
Exports do not copy binaries or datasets. Remote paths remain explicit.

Local runs write aggregate logs, `results.json`, and numbered trial folders with
`output.log` and, if the binary writes `${result}`, `result.json`. Remote trial
logs/results remain on the server and can be read from Runs over SSH. Submitted
progress is job state plus saved logs; interactive runs stream per-trial progress.
State is read with `squeue` then `sacct`. Cancellation affects only the recorded
job IDs. Scheduler exit status cannot hide failed or unstarted trials.

## Ownership and schema change

The Python resolver owns option/preset validation and reference resolution; the
pure planner owns Cartesian expansion, argv/env expansion, and allocation grouping.
Process/file effects are owned by load, run, export, submit, and job operations.
The Neovim store owns atomic JSON writes, the active source file, and library
publication; the panel owns row dialogs and per-experiment tasks/logs. Floating
window lifetime is per tab, independent of experiment task lifetime.

The fixed dataset/thread/method schema and its key dispatch have been removed.
Current source configs and examples use the parameter-list schema; historical
results and old exported runners remain historical artifacts. Launch snapshots
are resolved values, never live library references. Tests cover arbitrary options,
shared preset isolation, named experiments, node allocations, frozen replay,
streaming, cancellation, failure focus, and source-layout preservation.
