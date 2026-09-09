local hooks = require("review.hooks")

-- Regression test: re-setting an unchanged filetype refires FileType,
-- which lets third-party FileType maps (e.g. treesitter textobjects
-- ]c/[c) clobber codediff's buffer-local maps after installation.
describe("review.hooks filetype", function()
  local bufnr
  local group
  local filetype_fires

  before_each(function()
    bufnr = vim.api.nvim_create_buf(false, true)
    filetype_fires = 0
    group = vim.api.nvim_create_augroup("review_filetype_test", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
      group = group,
      buffer = bufnr,
      callback = function()
        filetype_fires = filetype_fires + 1
      end,
    })
  end)

  after_each(function()
    pcall(vim.api.nvim_del_augroup_by_id, group)
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  it("does not refire FileType when the buffer already has the filetype", function()
    vim.api.nvim_set_option_value("filetype", "python", { buf = bufnr })
    assert.equals(1, filetype_fires)
    assert.is_false(hooks._test.set_buffer_filetype(bufnr, "/repo/src/app.py"))
    assert.equals(1, filetype_fires)
    assert.equals("python", vim.api.nvim_get_option_value("filetype", { buf = bufnr }))
  end)

  it("sets the filetype when the buffer has none", function()
    assert.is_true(hooks._test.set_buffer_filetype(bufnr, "/repo/src/app.py"))
    assert.equals(1, filetype_fires)
    assert.equals("python", vim.api.nvim_get_option_value("filetype", { buf = bufnr }))
  end)

  it("accepts codediff path tables", function()
    hooks._test.set_buffer_filetype(bufnr, { absolute = "/repo/src/app.py", relative = "src/app.py" })
    assert.equals("python", vim.api.nvim_get_option_value("filetype", { buf = bufnr }))
  end)
end)

describe("review.hooks view keymap reset", function()
  local tabpage
  local diff1, diff2
  local saved_lifecycle
  local saved_view_keymaps
  local calls

  before_each(function()
    tabpage = vim.api.nvim_get_current_tabpage()
    diff1 = vim.api.nvim_create_buf(false, true)
    diff2 = vim.api.nvim_create_buf(false, true)
    calls = {}

    saved_lifecycle = package.loaded["codediff.ui.lifecycle"]
    saved_view_keymaps = package.loaded["codediff.ui.view.keymaps"]
    package.loaded["codediff.ui.lifecycle"] = {
      get_buffers = function()
        return diff1, diff2
      end,
      get_mode = function()
        return "explorer"
      end,
      get_result = function()
        return nil, nil
      end,
      release_keymap_scope = function(tab, scope)
        table.insert(calls, { op = "release", tab = tab, scope = scope })
      end,
    }
    package.loaded["codediff.ui.view.keymaps"] = {
      setup_all_keymaps = function(tab, orig, mod, is_explorer)
        table.insert(calls, { op = "setup", tab = tab, orig = orig, mod = mod, is_explorer = is_explorer })
      end,
    }
  end)

  after_each(function()
    package.loaded["codediff.ui.lifecycle"] = saved_lifecycle
    package.loaded["codediff.ui.view.keymaps"] = saved_view_keymaps
    for _, b in ipairs({ diff1, diff2 }) do
      if b and vim.api.nvim_buf_is_valid(b) then
        vim.api.nvim_buf_delete(b, { force = true })
      end
    end
  end)

  it("releases before re-running the view pass for the session buffers", function()
    hooks._test.reset_view_keymaps(tabpage)
    assert.equals(2, #calls)
    assert.equals("release", calls[1].op)
    assert.equals("view", calls[1].scope)
    assert.equals("setup", calls[2].op)
    assert.equals(tabpage, calls[2].tab)
    assert.equals(diff1, calls[2].orig)
    assert.equals(diff2, calls[2].mod)
    assert.is_true(calls[2].is_explorer)
  end)

  it("skips merge sessions to keep conflict overrides", function()
    package.loaded["codediff.ui.lifecycle"].get_result = function()
      return diff1, 1
    end
    hooks._test.reset_view_keymaps(tabpage)
    assert.equals(0, #calls)
  end)

  it("skips silently without the internal module (older codediff)", function()
    package.loaded["codediff.ui.view.keymaps"] = nil
    hooks._test.reset_view_keymaps(tabpage)
    assert.equals(0, #calls)
  end)
end)
