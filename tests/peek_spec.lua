local peek = require("review.peek")

describe("source peek line mapping", function()
  it("keeps modified-side lines unchanged", function()
    local diff_result = {
      changes = {
        {
          original = { start_line = 2, end_line = 3 },
          modified = { start_line = 2, end_line = 4 },
        },
      },
    }

    assert.equals(1, peek._test.map_original_line(diff_result, 1))
    assert.equals(2, peek._test.map_original_line(diff_result, 2))
    assert.equals(4, peek._test.map_original_line(diff_result, 3))
    assert.equals(5, peek._test.map_original_line(diff_result, 4))
  end)

  it("maps deleted lines to the following source line", function()
    local diff_result = {
      changes = {
        {
          original = { start_line = 3, end_line = 5 },
          modified = { start_line = 3, end_line = 3 },
        },
      },
    }

    assert.equals(2, peek._test.map_original_line(diff_result, 2))
    assert.equals(3, peek._test.map_original_line(diff_result, 3))
    assert.equals(3, peek._test.map_original_line(diff_result, 4))
    assert.equals(3, peek._test.map_original_line(diff_result, 5))
  end)

  it("keeps a column within the target line length", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "short", "a much longer line" })

    assert.equals(3, peek._test.clamp_column(bufnr, 1, 3))
    assert.equals(#"short", peek._test.clamp_column(bufnr, 1, 40))
    assert.equals(10, peek._test.clamp_column(bufnr, 2, 10))
    assert.equals(0, peek._test.clamp_column(bufnr, 1, 0))

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)
