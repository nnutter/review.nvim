local M = {}

local marks = require("review.marks")
local config = require("review.config")
local normalize_path = require("review.utils").normalize_path

---@type number|nil Current tabpage with active codediff session
local current_tabpage = nil

---@type number|nil Autocmd group for buffer events
local buf_augroup = nil

---Get a string path from CodeDiff's path reference.
---Older CodeDiff versions returned strings; newer versions return a table with
---absolute and relative fields.
---@param path string|table|nil
---@return string|nil
local function path_string(path)
  if type(path) == "table" then
    if path.absolute and path.absolute ~= "" then
      return path.absolute
    end
    return path.relative
  end
  return path
end

--- Reset codediff's view keymap scope after review fired FileType.
--- FileType plugins (e.g. treesitter textobjects owning ]c/[c) install
--- buffer-local maps that clobber codediff's. Codediff's registry yields
--- to foreign maps: once clobbered, even its own re-setup passes stand
--- down (displaced) and can never reinstall, so merely re-running the
--- pass is not enough. Releasing the view scope first drops slot state
--- entirely; the following setup pass then claims fresh and installs
--- over anything -- the same end state as a fresh open. Review's own
--- claims live outside the view scope (and close carries priority), so
--- they survive untouched. Skipped in merge sessions (the pass would
--- drop the conflict do/dp overrides) and when the internals are
--- unavailable (older codediff).
---@param tabpage number
local function reset_view_keymaps(tabpage)
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then
    return
  end
  local vk_ok, view_keymaps = pcall(require, "codediff.ui.view.keymaps")
  if not vk_ok or type(view_keymaps.setup_all_keymaps) ~= "function" then
    return
  end
  if type(lifecycle.release_keymap_scope) ~= "function" then
    return
  end
  local orig_buf, mod_buf = lifecycle.get_buffers(tabpage)
  if not orig_buf or not mod_buf then
    return
  end
  local is_explorer = false
  local is_conflict = false
  pcall(function()
    is_explorer = lifecycle.get_mode(tabpage) == "explorer"
    local result_buf = lifecycle.get_result(tabpage)
    is_conflict = result_buf ~= nil
  end)
  if is_conflict then
    return
  end
  pcall(lifecycle.release_keymap_scope, tabpage, "view")
  pcall(view_keymaps.setup_all_keymaps, tabpage, orig_buf, mod_buf, is_explorer)
end

---Set filetype for a buffer based on file path
---@param bufnr number
---@param path string|table|nil
---@return boolean changed true when the filetype was set (FileType fired)
local function set_buffer_filetype(bufnr, path)
  path = path_string(path)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if not path or path == "" then
    return false
  end

  -- Use Neovim's built-in filetype detection
  local ft = vim.filetype.match({ filename = path, buf = bufnr })
  if not ft then
    return false
  end
  -- Skip when the buffer already has this filetype (normally set by
  -- codediff itself). Re-setting the option refires FileType even when
  -- the value is unchanged.
  local current = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
  if current == ft then
    return false
  end
  vim.api.nvim_set_option_value("filetype", ft, { buf = bufnr })
  return true
end

---@return number|nil tabpage id
function M.get_current_tabpage()
  return current_tabpage
end

---@return table|nil codediff lifecycle module
local function get_lifecycle()
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then
    return nil
  end
  return lifecycle
end

---@return table|nil codediff session
function M.get_session()
  if not current_tabpage then
    return nil
  end
  local lifecycle = get_lifecycle()
  if not lifecycle then
    return nil
  end
  return lifecycle.get_session(current_tabpage)
end

---Relativize a path against the git root for consistent storage/lookup
---@param path string|nil
---@param lifecycle table
---@param tabpage number
---@return string|nil
local function relativize_path(path, lifecycle, tabpage)
  path = path_string(path)
  if not path or path == "" then
    return nil
  end
  local git_ctx = lifecycle.get_git_context(tabpage)
  if git_ctx and git_ctx.git_root then
    local abs = vim.fn.fnamemodify(path, ":p")
    return normalize_path(abs:gsub("^" .. vim.pesc(git_ctx.git_root) .. "/", ""))
  end
  return normalize_path(vim.fn.fnamemodify(path, ":."))
end

---@return string|nil file path
---@return number|nil line number
---@return "old"|"new"|nil side
function M.get_cursor_position()
  local lifecycle = get_lifecycle()
  if not lifecycle or not current_tabpage then
    return nil, nil, nil
  end

  local sess = lifecycle.get_session(current_tabpage)
  if not sess then
    return nil, nil, nil
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local current_buf = vim.api.nvim_get_current_buf()

  -- Get paths from session
  local orig_path, mod_path = lifecycle.get_paths(current_tabpage)
  local orig_buf, mod_buf = lifecycle.get_buffers(current_tabpage)

  -- Determine which file we're on based on buffer
  local file_path
  local side
  if current_buf == orig_buf then
    file_path = orig_path
    side = "old"
  elseif current_buf == mod_buf then
    file_path = mod_path
    side = "new"
  else
    -- Try to get path from buffer name
    local bufname = vim.api.nvim_buf_get_name(current_buf)
    if bufname and bufname ~= "" then
      -- Strip codediff:// prefix if present
      if bufname:match("^codediff://") then
        file_path = mod_path or orig_path
      else
        file_path = vim.fn.fnamemodify(bufname, ":.")
      end
    end
  end

  if not file_path then
    return nil, nil, nil
  end

  return relativize_path(file_path, lifecycle, current_tabpage), cursor[1], side
end

---@return string|nil file path
---@return number|nil start line
---@return number|nil end line
---@return "old"|"new"|nil side
function M.get_visual_range()
  local start_line = vim.fn.line("'<")
  local end_line = vim.fn.line("'>")
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end

  local file, _, side = M.get_cursor_position()
  if not file then
    return nil, nil, nil, nil
  end

  return file, start_line, end_line, side
end

---@return number|nil original buffer
---@return number|nil modified buffer
function M.get_buffers()
  local lifecycle = get_lifecycle()
  if not lifecycle or not current_tabpage then
    return nil, nil
  end
  return lifecycle.get_buffers(current_tabpage)
end

---@return string|nil original path
---@return string|nil modified path
function M.get_paths()
  local lifecycle = get_lifecycle()
  if not lifecycle or not current_tabpage then
    return nil, nil
  end
  local orig_path, mod_path = lifecycle.get_paths(current_tabpage)
  return relativize_path(orig_path, lifecycle, current_tabpage),
    relativize_path(mod_path, lifecycle, current_tabpage)
end

-- Called when codediff session is created
function M.on_session_created(tabpage)
  current_tabpage = tabpage

  local lifecycle = get_lifecycle()
  if not lifecycle then
    return
  end

  local orig_buf, mod_buf = lifecycle.get_buffers(tabpage)

  -- Set filetype for syntax highlighting (needed for commit reviews).
  -- Setting it fires FileType, so re-assert codediff's maps afterwards:
  -- FileType plugins may have claimed keys out from under them.
  local raw_orig_path, raw_mod_path = lifecycle.get_paths(tabpage)
  local ft_changed = set_buffer_filetype(orig_buf, raw_orig_path)
  ft_changed = set_buffer_filetype(mod_buf, raw_mod_path) or ft_changed
  if ft_changed then
    reset_view_keymaps(tabpage)
  end

  -- Make buffers readonly if configured
  local cfg = config.get()
  if cfg.codediff.readonly then
    if orig_buf and vim.api.nvim_buf_is_valid(orig_buf) then
      vim.api.nvim_set_option_value("modifiable", false, { buf = orig_buf })
      vim.api.nvim_set_option_value("readonly", true, { buf = orig_buf })
    end
    if mod_buf and vim.api.nvim_buf_is_valid(mod_buf) then
      vim.api.nvim_set_option_value("modifiable", false, { buf = mod_buf })
      vim.api.nvim_set_option_value("readonly", true, { buf = mod_buf })
    end
  end

  -- Clear old autocmds
  if buf_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, buf_augroup)
  end
  buf_augroup = vim.api.nvim_create_augroup("review_buf_marks", { clear = true })

  -- Set up BufEnter autocmd to render marks when entering codediff buffers
  -- This ensures marks are rendered even if buffers weren't ready initially
  vim.api.nvim_create_autocmd("BufEnter", {
    group = buf_augroup,
    callback = function()
      if vim.api.nvim_get_current_tabpage() ~= current_tabpage then
        return
      end
      local bufnr = vim.api.nvim_get_current_buf()
      local ob, mb = lifecycle.get_buffers(current_tabpage)
      if bufnr ~= ob and bufnr ~= mb then
        return
      end
      marks.refresh()
    end,
  })

  -- Initial render with delay for buffers to be ready
  vim.defer_fn(function()
    marks.refresh()
  end, 100)

  -- Focus the modified (right) pane
  vim.defer_fn(function()
    M._focus_modified_pane(lifecycle, tabpage)
  end, 150)

  -- Show the commit-info pane above the explorer (commit reviews only;
  -- deferred so the explorer window exists). Re-runs on CodeDiffFileSelect
  -- via on_session_created, refreshing content for the same range.
  vim.defer_fn(function()
    if current_tabpage ~= tabpage then
      return
    end
    pcall(require("review.commit_info").show, tabpage)
  end, 250)
end

function M._focus_modified_pane(lifecycle, tabpage)
  local cur_cfg = vim.api.nvim_win_get_config(vim.api.nvim_get_current_win())
  if cur_cfg.relative ~= "" then
    return
  end
  local sess = lifecycle.get_session(tabpage)
  if sess and sess.modified_win and vim.api.nvim_win_is_valid(sess.modified_win) then
    vim.api.nvim_set_current_win(sess.modified_win)
  end
end

-- Called when codediff session is closed
function M.on_session_closed()
  require("review.peek").on_session_closed()
  pcall(require("review.commit_info").hide)
  current_tabpage = nil
  -- Clean up autocmds
  if buf_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, buf_augroup)
    buf_augroup = nil
  end
  require("review.keymaps").cleanup()
end

-- Called when file changes in explorer mode
function M.on_file_changed(tabpage)
  current_tabpage = tabpage

  local lifecycle = get_lifecycle()
  if not lifecycle then
    return
  end

  -- Re-render comments
  vim.defer_fn(function()
    marks.refresh()
  end, 50)
end

M._test = {
  path_string = path_string,
  set_buffer_filetype = set_buffer_filetype,
  reset_view_keymaps = reset_view_keymaps,
}

return M
