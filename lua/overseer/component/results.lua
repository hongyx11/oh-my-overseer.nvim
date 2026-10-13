return {
  desc = "Show compact workflow status and reusable task results",
  constructor = function()
    local results = require("overseer.results")
    return {
      on_start = function(_, task)
        results.on_start(task)
      end,
      on_output_lines = function(_, task)
        results.on_output(task)
      end,
      on_complete = function(_, task, status)
        results.on_complete(task, status)
      end,
    }
  end,
}
