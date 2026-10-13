# Results interface

Oh My Overseer provides an optional interface for workflows where the useful
information is the final outcome and the program's output.

```lua
require("overseer").setup({
  results = {
    enabled = true,
    width = 0.45,
    focus_failure = true,
    history_limit = 10,
    run_tasks = { "Run" },
  },
  cmake = { enabled = true },
})
```

## Workflow behavior

Configure and Build run without opening the task list. Each active command has
one compact progress message, and the whole workflow gets one completion
notification. A child failure opens that child's actual output; the parent does
not produce another failure popup.

Tasks named in `run_tasks` open their live output in a full-height window on the
right without moving focus away from your source window. A task may also opt in
with `metadata = { results_output = true }`. Results reuse one window per tab.
Failures focus the results window by default; set `focus_failure = false` to
keep editing. A background workflow never switches tabs, and an older workflow
cannot replace the output of a newer workflow in the same project.

`q` in normal mode or `:q` closes only the results window. Terminal tasks can
still accept input by entering terminal mode. Configure and build output remains
available through history, including commands that completed successfully.

The interface suppresses automatic task-list, quickfix, and Trouble windows,
including VS Code `presentation.reveal` settings. Parsing and diagnostics remain
active. `:OverseerOpen` still opens the original task-management UI explicitly.

## Results and history commands

- `:OverseerResults` toggles the latest project's output.
- `:OverseerHistory` selects a recent workflow and then one of its command logs.
- `:OverseerTaskAction` still provides stop, restart, and other task actions.

History is held for the current Neovim session. Completed output is copied before
restarting a task, so older history entries keep their original logs. The
`history_limit` controls retained completed workflows per project. A visible
output or a failure that has not been shown is retained until it can be released.

Example mappings:

```lua
vim.keymap.set("n", "<leader>cO", "<cmd>OverseerResults<CR>")
vim.keymap.set("n", "<leader>cH", "<cmd>OverseerHistory<CR>")
vim.keymap.set("n", "<leader>cP", "<cmd>OverseerCMakePreset<CR>")
```

## CMake presets

`:OverseerCMakePreset` asks CMake for the available configure presets. Hidden and
unavailable platform presets are excluded by CMake itself. The selected preset
is saved per project under Neovim's state directory and survives editor restarts.

For an existing `.vscode/tasks.json` workflow using process tasks:

- Configure's `cmake --preset ...` uses the selected configure preset.
- Build's `cmake --build ...` uses that preset's binary directory, preserving
  explicit target and parallelism arguments.
- Test's `ctest --test-dir ...` or `ctest --preset ...` uses the same directory.
- A task named `Run` whose executable is under the original Build directory
  follows the selected directory. The CMake File API resolves the actual target
  executable immediately before Run starts, including different output layouts.

Presets may inherit from included files or user presets. Binary-directory macros
and preset environment variables are resolved; a selectable preset needs a
`binaryDir`. Build-preset defaults are not imported: explicit arguments in the
project's Build task remain the source of build targets and options. Arbitrary
shell scripts and unrelated executables are left as defined by the project.

The workflow captures the selection before starting. Choosing another preset
while it runs affects subsequent workflows, not its remaining steps. File API
queries are written only inside the selected build directory; source preset and
task files are not rewritten.

To prompt for a preset before the first workflow, use the asynchronous helper:

```lua
require("overseer.cmake").ensure(function(ready)
  if ready then
    require("overseer").run_task({ name = "Configure, build and run" })
  end
end)
```

An existing saved preset is reused. Canceling the initial picker stops the launch.
With no CMake presets in the current project, the helper allows the normal task
workflow to run.
