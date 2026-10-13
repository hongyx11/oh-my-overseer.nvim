local overseer = require("overseer")

describe("task output windows", function()
  local task
  local source_win
  local source_buf

  before_each(function()
    overseer.setup({ dap = false })
    source_win = vim.api.nvim_get_current_win()
    source_buf = vim.api.nvim_get_current_buf()
    task = overseer.new_task({
      name = "Output window test",
      cmd = "test",
      strategy = "test",
      components = {},
    })
    task:start()
  end)

  after_each(function()
    overseer.close()
    if vim.api.nvim_win_is_valid(source_win) then
      vim.api.nvim_set_current_win(source_win)
      vim.api.nvim_win_set_buf(source_win, source_buf)
    end
    vim.cmd.only({ bang = true })
    task:dispose(true)
  end)

  for _, direction in ipairs({ "bottom", "left", "right" }) do
    it(
      "preserves the source window when closing output from the " .. direction .. " task list",
      function()
        overseer.open({ direction = direction, enter = true, focus_task_id = task.id })
        vim.api.nvim_feedkeys("o", "mx", false)

        local output_win = vim.api.nvim_get_current_win()
        assert.are_not.equal(source_win, output_win)
        assert.are.equal(source_buf, vim.api.nvim_win_get_buf(source_win))
        assert.are.equal(task:get_bufnr(), vim.api.nvim_win_get_buf(output_win))

        vim.cmd.quit()

        assert.is_false(vim.api.nvim_win_is_valid(output_win))
        assert.is_true(vim.api.nvim_win_is_valid(source_win))
        assert.are.equal(source_buf, vim.api.nvim_win_get_buf(source_win))
      end
    )
  end
end)
