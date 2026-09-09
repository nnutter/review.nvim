local peek = require("review.peek")
local config = require("review.config")
local keymaps = require("review.keymaps")

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

describe("source peek jumplist leave", function()
  local tabpage
  local orig_buf
  local mod_buf
  local source_path
  local saved_lifecycle

  before_each(function()
    config.setup()
    tabpage = vim.api.nvim_get_current_tabpage()

    orig_buf = vim.api.nvim_create_buf(false, true)
    mod_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(orig_buf, 0, -1, false, { "one", "two", "three" })
    vim.api.nvim_buf_set_lines(mod_buf, 0, -1, false, { "one", "two", "three" })

    source_path = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "one", "two", "three" }, source_path)

    saved_lifecycle = package.loaded["codediff.ui.lifecycle"]
    package.loaded["codediff.ui.lifecycle"] = {
      get_session = function(tab)
        if tab ~= tabpage then
          return nil
        end
        return { stored_diff_result = { changes = {} }, layout = "split" }
      end,
      get_buffers = function()
        return orig_buf, mod_buf
      end,
      get_paths = function()
        return nil, source_path
      end,
      find_tabpage_by_buffer = function(bufnr)
        if bufnr == orig_buf or bufnr == mod_buf then
          return tabpage
        end
        return nil
      end,
      set_buf_keymap = function(tab, bufnr, mode, lhs, rhs, opts)
        vim.keymap.set(mode, lhs, rhs, vim.tbl_extend("force", opts or {}, { buffer = bufnr }))
        return true
      end,
      del_buf_keymap = function(_, bufnr, mode, lhs)
        pcall(vim.keymap.del, mode, lhs, { buffer = bufnr })
      end,
    }

    vim.api.nvim_set_current_buf(orig_buf)
    keymaps.setup_keymaps(tabpage)
  end)

  after_each(function()
    peek.on_session_closed()
    keymaps.cleanup()
    package.loaded["codediff.ui.lifecycle"] = saved_lifecycle
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name == source_path then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
    end
    for _, bufnr in ipairs({ orig_buf, mod_buf }) do
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
    end
    if source_path then
      pcall(vim.fn.delete, source_path)
    end
  end)

  it("closes peek when jumping back to the diff buffer so p works again", function()
    vim.api.nvim_set_current_buf(orig_buf)
    peek.open()
    assert.is_true(peek.is_active())

    -- Simulate <C-o>: the jumplist restores the diff buffer in the peek
    -- window without going through peek.close(). The BufEnter handler
    -- must notice the leave and restore the diff pane.
    vim.api.nvim_set_current_buf(orig_buf)
    assert.is_false(peek.is_active())
    assert.equals(orig_buf, vim.api.nvim_get_current_buf())

    local map = vim.fn.maparg("p", "n", false, true)
    assert.is_true(type(map) == "table" and next(map) ~= nil)

    peek.open()
    assert.is_true(peek.is_active())
    peek.close()
  end)
end)
