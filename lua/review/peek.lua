local M = {}

---@class ReviewPeekState
---@field tabpage number
---@field win number
---@field diff_bufnr number
---@field source_bufnr number|nil
---@field cursor number[]
---@field view table
---@field winopts table<string, any>
---@field cleared_bufnr number|nil
---@field diff_bufhidden string|nil
local state = nil

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.WARN, { title = "review.nvim" })
end

local function is_valid_buffer(bufnr)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function source_path(ref)
  local path
  if type(ref) == "table" then
    path = ref.absolute
  elseif type(ref) == "string" then
    path = ref
  end

  if not path or path == "" then
    return nil
  end
  return vim.fn.fnamemodify(path, ":p")
end

--- Map an original-side line to the corresponding modified-side line.
---@param diff_result table|nil
---@param line number
---@return number
local function map_original_line(diff_result, line)
  if not diff_result or not diff_result.changes then
    return line
  end

  local offset = 0
  for _, change in ipairs(diff_result.changes) do
    local original = change.original
    local modified = change.modified
    local original_count = original.end_line - original.start_line
    local modified_count = modified.end_line - modified.start_line

    if line < original.start_line then
      return math.max(1, line + offset)
    end

    if line < original.end_line then
      if modified_count == 0 then
        return math.max(1, modified.start_line)
      end
      local line_offset = math.min(line - original.start_line, modified_count - 1)
      return math.max(1, modified.start_line + line_offset)
    end

    offset = offset + modified_count - original_count
  end

  return math.max(1, line + offset)
end

--- Clamp a column to the target line so cursor placement cannot fail when
--- the source line is shorter than the diff line the cursor came from.
---@param bufnr number
---@param line number
---@param col number
---@return number
local function clamp_column(bufnr, line, col)
  if col <= 0 then
    return 0
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)
  local line_length = #(lines[1] or "")
  return math.min(col, line_length)
end

local function get_source_buffer(win, path)
  local ok, helpers = pcall(require, "codediff.ui.view.helpers")
  if ok and helpers.open_real_file then
    local opened, bufnr = pcall(helpers.open_real_file, win, path)
    if opened and is_valid_buffer(bufnr) then
      return bufnr
    end
  end

  local bufnr = vim.fn.bufadd(path)
  if vim.api.nvim_buf_is_loaded(bufnr) then
    vim.api.nvim_win_set_buf(win, bufnr)
    return bufnr
  end

  vim.api.nvim_set_current_win(win)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

local function save_window_options(win)
  local options = {
    "number",
    "relativenumber",
    "cursorline",
    "signcolumn",
    "wrap",
    "scrollbind",
    "cursorbind",
    "diff",
    "foldmethod",
    "foldenable",
    "statuscolumn",
    "winbar",
  }

  local saved = {}
  for _, option in ipairs(options) do
    saved[option] = vim.wo[win][option]
  end
  return saved
end

local function clear_review_decorations(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, vim.api.nvim_create_namespace("review"), 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, vim.api.nvim_create_namespace("review_padding"), 0, -1)
end

local function clear_diff_decorations(bufnr, original_bufnr, modified_bufnr)
  if bufnr ~= original_bufnr and bufnr ~= modified_bufnr then
    return nil
  end

  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if ok and lifecycle.clear_highlights then
    pcall(lifecycle.clear_highlights, bufnr)
  end
  clear_review_decorations(bufnr)

  -- The source buffer can also be the working-tree side of the diff. Avoid
  -- re-rendering its diff decorations while it is being used as a source view.
  local auto_refresh_ok, auto_refresh = pcall(require, "codediff.ui.auto_refresh")
  if auto_refresh_ok and auto_refresh.disable then
    pcall(auto_refresh.disable, bufnr)
  end

  return bufnr
end

local function restore_diff_decorations(tabpage, cleared_bufnr)
  if not cleared_bufnr then
    return
  end

  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then
    return
  end

  local session = lifecycle.get_session(tabpage)
  if not session then
    return
  end

  local original_bufnr, modified_bufnr = lifecycle.get_buffers(tabpage)
  if not is_valid_buffer(original_bufnr) or not is_valid_buffer(modified_bufnr) then
    return
  end

  local lines_diff = session.stored_diff_result
  if lines_diff then
    local original_lines = vim.api.nvim_buf_get_lines(original_bufnr, 0, -1, false)
    local modified_lines = vim.api.nvim_buf_get_lines(modified_bufnr, 0, -1, false)

    if session.layout == "inline" then
      local inline_ok, inline = pcall(require, "codediff.ui.inline")
      if inline_ok then
        pcall(inline.render_inline_diff, modified_bufnr, lines_diff, original_lines, modified_lines)
      end
    else
      local core_ok, core = pcall(require, "codediff.ui.core")
      if core_ok then
        pcall(core.render_diff, original_bufnr, modified_bufnr, original_lines, modified_lines, lines_diff)
      end
    end
  end

  local auto_refresh_ok, auto_refresh = pcall(require, "codediff.ui.auto_refresh")
  if auto_refresh_ok and auto_refresh.enable then
    local original_virtual = lifecycle.is_original_virtual(tabpage)
    local modified_virtual = lifecycle.is_modified_virtual(tabpage)
    if cleared_bufnr == original_bufnr and not original_virtual then
      pcall(auto_refresh.enable, original_bufnr)
    elseif cleared_bufnr == modified_bufnr and not modified_virtual then
      pcall(auto_refresh.enable, modified_bufnr)
    end
  end

  pcall(require("review.marks").refresh)
end

local function set_source_window_options(win)
  vim.wo[win].number = true
  vim.wo[win].relativenumber = true
  vim.wo[win].cursorline = true
  vim.wo[win].signcolumn = "yes"
  vim.wo[win].wrap = false
  vim.wo[win].scrollbind = false
  vim.wo[win].cursorbind = false
  vim.wo[win].diff = false
  vim.wo[win].statuscolumn = ""
end

--- Whether a source-file peek is currently active.
---@return boolean
function M.is_active()
  return state ~= nil
end

--- Whether a buffer is the source buffer currently being peeked.
---@param bufnr number
---@return boolean
function M.is_active_buffer(bufnr)
  return state ~= nil and state.source_bufnr == bufnr
end

--- Install the temporary mappings used by source peek.
---@param bufnr number
function M.setup_keymaps(bufnr)
  if not M.is_active_buffer(bufnr) then
    return
  end

  local close = function()
    M.close()
  end
  vim.keymap.set("n", "q", close, {
    buffer = bufnr,
    nowait = true,
    silent = true,
    desc = "Return to review",
  })
  vim.keymap.set("n", "<Esc>", close, {
    buffer = bufnr,
    nowait = true,
    silent = true,
    desc = "Return to review",
  })
end

--- Open the current file in the focused diff pane.
function M.open()
  if state then
    return
  end

  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then
    return
  end

  local tabpage = vim.api.nvim_get_current_tabpage()
  local session = lifecycle.get_session(tabpage)
  if not session then
    return
  end

  local original_bufnr, modified_bufnr = lifecycle.get_buffers(tabpage)
  local current_bufnr = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  if current_bufnr ~= original_bufnr and current_bufnr ~= modified_bufnr then
    notify("Source peek is only available from a diff pane")
    return
  end

  local _, modified_ref = lifecycle.get_paths(tabpage)
  local path = source_path(modified_ref)
  if not path and current_bufnr == modified_bufnr then
    local current_name = vim.api.nvim_buf_get_name(current_bufnr)
    if current_name ~= "" and not current_name:match("^codediff://") then
      path = vim.fn.fnamemodify(current_name, ":p")
    end
  end
  if not path or vim.fn.filereadable(path) ~= 1 then
    notify("The current file is not available in the working tree")
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(win)
  local view = vim.fn.winsaveview()
  state = {
    tabpage = tabpage,
    win = win,
    diff_bufnr = current_bufnr,
    source_bufnr = nil,
    cursor = cursor,
    view = view,
    winopts = save_window_options(win),
    cleared_bufnr = nil,
    diff_bufhidden = vim.bo[current_bufnr].bufhidden,
  }

  -- Virtual diff buffers are wiped as soon as they lose their last window,
  -- which would destroy the session's buffer while the source file is shown.
  -- Keep the buffer alive until the peek closes.
  vim.bo[current_bufnr].bufhidden = "hide"

  local opened, source_bufnr = pcall(get_source_buffer, win, path)
  if not opened or not is_valid_buffer(source_bufnr) then
    state = nil
    notify("Unable to open source file: " .. tostring(source_bufnr), vim.log.levels.ERROR)
    return
  end
  state.source_bufnr = source_bufnr

  state.cleared_bufnr = clear_diff_decorations(source_bufnr, original_bufnr, modified_bufnr)

  -- Strip the review mappings from the source buffer (it must not answer to
  -- q/close) and install the peek mappings; other buffers are left untouched.
  require("review.keymaps").apply_for_buffer(tabpage, source_bufnr)

  local source_line = cursor[1]
  if current_bufnr == original_bufnr then
    source_line = map_original_line(session.stored_diff_result, source_line)
  end
  source_line = math.min(math.max(source_line, 1), vim.api.nvim_buf_line_count(source_bufnr))
  local source_col = clamp_column(source_bufnr, source_line, cursor[2])

  vim.api.nvim_set_current_win(win)
  set_source_window_options(win)
  pcall(vim.api.nvim_win_set_cursor, win, { source_line, source_col })
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! zz")
  end)
end

--- Close source peek and restore the diff pane.
function M.close()
  local current = state
  if not current then
    return
  end

  M.clear_keymaps(current.source_bufnr)
  state = nil

  if current.win and vim.api.nvim_win_is_valid(current.win) then
    if current.diff_bufnr and vim.api.nvim_buf_is_valid(current.diff_bufnr) then
      vim.api.nvim_set_current_win(current.win)
      vim.api.nvim_win_set_buf(current.win, current.diff_bufnr)

      if current.diff_bufhidden then
        vim.bo[current.diff_bufnr].bufhidden = current.diff_bufhidden
      end

      for option, value in pairs(current.winopts) do
        vim.wo[current.win][option] = value
      end

      pcall(vim.api.nvim_win_set_cursor, current.win, current.cursor)
      vim.api.nvim_win_call(current.win, function()
        vim.fn.winrestview(current.view)
      end)
    end
  end

  restore_diff_decorations(current.tabpage, current.cleared_bufnr)

  -- Restore review mappings on the buffers peek touched. The diff buffer lost
  -- nothing but the peek guard, and the source buffer may have been one of the
  -- session's diff buffers (working-tree side) whose mappings were stripped.
  local keymaps_ok, keymaps = pcall(require, "review.keymaps")
  if keymaps_ok then
    keymaps.apply_for_buffer(current.tabpage, current.diff_bufnr)
    if current.source_bufnr ~= current.diff_bufnr then
      local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
      local session = ok and lifecycle.get_session(current.tabpage) or nil
      if session then
        local orig_bufnr, mod_bufnr = lifecycle.get_buffers(current.tabpage)
        if current.source_bufnr == orig_bufnr or current.source_bufnr == mod_bufnr then
          keymaps.apply_for_buffer(current.tabpage, current.source_bufnr)
        end
      end
    end
  end
end

--- Drop peek state when the review session is closed externally.
function M.on_session_closed()
  if not state then
    return
  end
  M.clear_keymaps(state.source_bufnr)
  if state.diff_bufhidden and state.diff_bufnr and vim.api.nvim_buf_is_valid(state.diff_bufnr) then
    vim.bo[state.diff_bufnr].bufhidden = state.diff_bufhidden
  end
  state = nil
end

function M.clear_keymaps(bufnr)
  if not is_valid_buffer(bufnr) then
    return
  end
  pcall(vim.keymap.del, "n", "q", { buffer = bufnr })
  pcall(vim.keymap.del, "n", "<Esc>", { buffer = bufnr })
end

M._test = {
  map_original_line = map_original_line,
  clamp_column = clamp_column,
}

return M
