local M = {}

local config = require("unified.config")
local hunk_store = require("unified.hunk_store")

-- Compute the byte-range of the differing region between two lines.
-- Returns (prefix_len, old_change_end, new_change_end) as 0-indexed byte offsets,
-- where the change region is [prefix_len, *_change_end) on each side.
-- Returns nil if the lines are identical.
local function intra_line_diff(old, new)
  if old == new then
    return nil
  end
  local len_old, len_new = #old, #new
  local max_prefix = math.min(len_old, len_new)
  local prefix = 0
  while prefix < max_prefix and old:byte(prefix + 1) == new:byte(prefix + 1) do
    prefix = prefix + 1
  end
  -- Back off if we stopped mid UTF-8 codepoint
  while prefix > 0 do
    local b = old:byte(prefix + 1)
    if not b or b < 0x80 or b >= 0xC0 then
      break
    end
    prefix = prefix - 1
  end

  local old_end, new_end = len_old, len_new
  while old_end > prefix and new_end > prefix and old:byte(old_end) == new:byte(new_end) do
    old_end = old_end - 1
    new_end = new_end - 1
  end
  -- Advance past trailing continuation bytes so we don't cut a codepoint
  while old_end < len_old and new_end < len_new do
    local b = old:byte(old_end + 1)
    if not b or b < 0x80 or b >= 0xC0 then
      break
    end
    old_end = old_end + 1
    new_end = new_end + 1
  end

  return prefix, old_end, new_end
end

-- Walk a hunk and pair each consecutive run of `-` lines with the following run
-- of `+` lines. For each pair, compute an intra-line diff so we can highlight
-- the differing region with a stronger color.
--
-- Returns two tables:
--   delete_intra : array keyed by the ordinal of the `-` line within the hunk
--                  (0-based across all `-` lines in this hunk),
--                  value = { prefix_len, old_change_end }
--   add_intra    : map keyed by 0-indexed buffer line, value = { prefix_len, new_change_end }
local function compute_hunk_intra_diffs(hunk)
  local delete_intra = {}
  local add_intra = {}
  local lines = hunk.lines
  local n = #lines
  local i = 1
  local new_buf_line = hunk.new_start - 1
  local del_ordinal = 0

  while i <= n do
    local c = lines[i]:sub(1, 1)
    if c == "-" then
      local del_start = i
      while i <= n and lines[i]:sub(1, 1) == "-" do
        i = i + 1
      end
      local del_count = i - del_start

      if i <= n and lines[i]:sub(1, 1) == "+" then
        local add_start = i
        local add_buf_start = new_buf_line
        while i <= n and lines[i]:sub(1, 1) == "+" do
          i = i + 1
          new_buf_line = new_buf_line + 1
        end
        local add_count = i - add_start

        local pair_count = math.min(del_count, add_count)
        for k = 0, pair_count - 1 do
          local old_text = lines[del_start + k]:sub(2)
          local new_text = lines[add_start + k]:sub(2)
          local prefix, old_e, new_e = intra_line_diff(old_text, new_text)
          if prefix then
            delete_intra[del_ordinal + k] = { prefix, old_e }
            add_intra[add_buf_start + k] = { prefix, new_e }
          end
        end
      end

      del_ordinal = del_ordinal + del_count
    elseif c == "+" then
      while i <= n and lines[i]:sub(1, 1) == "+" do
        i = i + 1
        new_buf_line = new_buf_line + 1
      end
    else
      new_buf_line = new_buf_line + 1
      i = i + 1
    end
  end

  return delete_intra, add_intra
end

-- Build the virt_line chunks for a single deleted line, splitting on the
-- intra-line diff range so the differing portion can be highlighted brighter.
local function build_deleted_chunks(text, intra, win_width)
  local display_width = vim.fn.strdisplaywidth(text)
  local pad = ""
  if display_width < win_width then
    pad = string.rep(" ", win_width - display_width)
  end

  if not intra then
    return { { text .. pad, "UnifiedDiffDelete" } }
  end

  local s, e = intra[1], intra[2]
  if e <= s then
    return { { text .. pad, "UnifiedDiffDelete" } }
  end

  local chunks = {}
  if s > 0 then
    table.insert(chunks, { text:sub(1, s), "UnifiedDiffDelete" })
  end
  table.insert(chunks, { text:sub(s + 1, e), "UnifiedDiffDeleteText" })
  if e < #text then
    table.insert(chunks, { text:sub(e + 1), "UnifiedDiffDelete" })
  end
  if pad ~= "" then
    table.insert(chunks, { pad, "UnifiedDiffDelete" })
  end
  return chunks
end

-- Parse diff and return a structured representation
function M.parse_diff(diff_text)
  local lines = vim.split(diff_text, "\n")
  local hunks = {}
  local current_hunk = nil

  for _, line in ipairs(lines) do
    if line:match("^@@") then
      -- Hunk header line like "@@ -1,7 +1,6 @@"
      if current_hunk then
        table.insert(hunks, current_hunk)
      end

      -- Parse line numbers
      local old_start, old_count, new_start, new_count = line:match("@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")

      old_count = old_count ~= "" and tonumber(old_count) or 1
      new_count = new_count ~= "" and tonumber(new_count) or 1

      current_hunk = {
        old_start = tonumber(old_start),
        old_count = old_count,
        new_start = tonumber(new_start),
        new_count = new_count,
        lines = {},
      }
    elseif current_hunk and (line:match("^%+") or line:match("^%-") or line:match("^ ")) then
      table.insert(current_hunk.lines, line)
    elseif current_hunk and line == "" then
      -- Empty context line (some git versions strip the leading space from blank lines)
      table.insert(current_hunk.lines, " ")
    end
  end

  if current_hunk then
    table.insert(hunks, current_hunk)
  end

  return hunks
end

function M.display_deleted_file(buffer, blob_text)
  local ns_id = config.ns_id
  vim.api.nvim_buf_clear_namespace(buffer, ns_id, 0, -1)
  vim.fn.sign_unplace("unified_diff", { buffer = buffer })

  local lines = vim.split(blob_text, "\n", { plain = true })
  local was_modifiable = vim.bo[buffer].modifiable
  local was_readonly = vim.bo[buffer].readonly

  if not was_modifiable then
    vim.bo[buffer].modifiable = true
  end
  if was_readonly then
    vim.bo[buffer].readonly = false
  end

  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)

  vim.bo[buffer].modified = false
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].readonly = true

  for i = 0, #lines - 1 do
    vim.api.nvim_buf_set_extmark(buffer, ns_id, i, 0, {
      line_hl_group = "UnifiedDiffDelete",
    })
  end

  vim.bo[buffer].readonly = true
end

function M.display_inline_diff(buffer, hunks)
  local ns_id = config.ns_id

  vim.api.nvim_buf_clear_namespace(buffer, ns_id, 0, -1)

  -- Clear existing signs
  vim.fn.sign_unplace("unified_diff", { buffer = buffer })

  local new_hunk_lines = {}

  -- Track if we placed any marks
  local mark_count = 0
  local sign_count = 0

  -- Get current buffer line count for safety checks
  local buf_line_count = vim.api.nvim_buf_line_count(buffer)

  -- Track which lines have been marked already to avoid duplicates
  local marked_lines = {}

  -- For detecting multiple consecutive new lines
  local consecutive_added_lines = {}

  local in_changed_block = false

  for _, hunk in ipairs(hunks) do
    local line_idx = math.max(hunk.new_start - 1, 0)
    local old_idx = 0
    local new_idx = 0
    local delete_intra, add_intra = compute_hunk_intra_diffs(hunk)
    local del_ordinal = 0

    -- First pass: identify ranges of consecutive added lines
    local current_start = nil
    local added_count = 0

    -- Analyze hunk lines to find consecutive added lines
    for _, line in ipairs(hunk.lines) do
      local first_char = line:sub(1, 1)

      if first_char == "+" then
        -- Start a new range or extend current range
        if current_start == nil then
          current_start = hunk.new_start - 1 + new_idx
          added_count = 1
        else
          added_count = added_count + 1
        end
      else
        -- End of added range, record it if we found multiple additions
        if current_start ~= nil and added_count > 0 then
          consecutive_added_lines[current_start] = added_count
          current_start = nil
          added_count = 0
        end
      end

      -- Update counters for proper position tracking
      if first_char == " " then
        new_idx = new_idx + 1
      elseif first_char == "+" then
        new_idx = new_idx + 1
      end
    end

    -- Record final range if needed
    if current_start ~= nil and added_count > 0 then
      consecutive_added_lines[current_start] = added_count
    end

    line_idx = hunk.new_start - 1
    old_idx = 0
    new_idx = 0
    in_changed_block = false

    local deleted_lines = {}
    local deleted_attach_line = nil

    local function flush_deleted_lines()
      if #deleted_lines == 0 then
        return
      end
      if buf_line_count == 0 then
        deleted_lines = {}
        deleted_attach_line = nil
        return
      end

      local attach_line = math.min(deleted_attach_line, buf_line_count - 1)
      -- Find the window displaying this buffer to get the correct width
      local win_width = 0
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == buffer then
          win_width = vim.api.nvim_win_get_width(win)
          break
        end
      end
      if win_width == 0 then
        win_width = vim.api.nvim_win_get_width(0)
      end
      -- Ensure at least some width so empty deleted lines are still visible
      if win_width == 0 then
        win_width = 80
      end
      local virt_lines = {}
      for _, entry in ipairs(deleted_lines) do
        table.insert(virt_lines, build_deleted_chunks(entry.text, entry.intra, win_width))
      end
      local mark_id = vim.api.nvim_buf_set_extmark(buffer, ns_id, attach_line, 0, {
        virt_lines = virt_lines,
        virt_lines_above = deleted_attach_line > 0,
      })
      if mark_id > 0 then
        mark_count = mark_count + #deleted_lines
      end

      deleted_lines = {}
      deleted_attach_line = nil
    end

    for _, line in ipairs(hunk.lines) do
      local first_char = line:sub(1, 1)

      if first_char == "+" or first_char == "-" then
        if not in_changed_block then
          table.insert(new_hunk_lines, line_idx + 1)
          in_changed_block = true
        end
      else
        in_changed_block = false
      end

      if first_char == " " then
        -- Context line
        flush_deleted_lines()
        line_idx = line_idx + 1
        old_idx = old_idx + 1
        new_idx = new_idx + 1
      elseif first_char == "+" then
        -- Added or modified line
        flush_deleted_lines()
        local hl_group = "UnifiedDiffAdd"

        -- Process only if line is within range and not already marked
        if line_idx < buf_line_count and not marked_lines[line_idx] then
          -- Check if this is part of consecutive added lines
          local consecutive_count = consecutive_added_lines[line_idx - new_idx + old_idx] or 0

          -- Use hl_group + hl_eol (instead of line_hl_group) so that a
          -- higher-priority intra-line extmark can override the bg.
          local extmark_opts = {
            sign_text = config.values.line_symbols.add .. " ", -- Add sign in gutter
            sign_hl_group = config.values.highlights.add,
            end_row = line_idx + 1,
            end_col = 0,
            hl_group = hl_group,
            hl_eol = true,
          }
          local mark_id = vim.api.nvim_buf_set_extmark(buffer, ns_id, line_idx, 0, extmark_opts)
          if mark_id > 0 then
            mark_count = mark_count + 1
            sign_count = sign_count + 1
            marked_lines[line_idx] = true

            local intra = add_intra[line_idx]
            if intra and intra[2] > intra[1] then
              vim.api.nvim_buf_set_extmark(buffer, ns_id, line_idx, intra[1], {
                end_col = intra[2],
                hl_group = "UnifiedDiffAddText",
                priority = 4097,
              })
            end

            -- If part of consecutive additions, highlight subsequent lines
            if consecutive_count > 1 then
              for i = 1, consecutive_count - 1 do
                local next_line_idx = line_idx + i

                -- Process only if next line is within range and not already marked
                if next_line_idx < buf_line_count and not marked_lines[next_line_idx] then
                  local consec_extmark_opts = {
                    sign_text = config.values.line_symbols.add .. " ", -- Add sign in gutter
                    sign_hl_group = config.values.highlights.add,
                    end_row = next_line_idx + 1,
                    end_col = 0,
                    hl_group = hl_group,
                    hl_eol = true,
                  }
                  local consec_mark_id =
                    vim.api.nvim_buf_set_extmark(buffer, ns_id, next_line_idx, 0, consec_extmark_opts)
                  if consec_mark_id > 0 then
                    mark_count = mark_count + 1
                    sign_count = sign_count + 1
                    marked_lines[next_line_idx] = true

                    local next_intra = add_intra[next_line_idx]
                    if next_intra and next_intra[2] > next_intra[1] then
                      vim.api.nvim_buf_set_extmark(buffer, ns_id, next_line_idx, next_intra[1], {
                        end_col = next_intra[2],
                        hl_group = "UnifiedDiffAddText",
                        priority = 4097,
                      })
                    end
                  end
                end
              end
            end
          end
        end

        line_idx = line_idx + 1
        new_idx = new_idx + 1
      elseif first_char == "-" then
        local line_text = line:sub(2)
        if deleted_attach_line == nil then
          deleted_attach_line = math.max(line_idx, 0)
        end
        table.insert(deleted_lines, { text = line_text, intra = delete_intra[del_ordinal] })
        del_ordinal = del_ordinal + 1

        old_idx = old_idx + 1
      end
    end

    flush_deleted_lines()
  end

  if #new_hunk_lines > 0 then
    table.sort(new_hunk_lines)
    local unique_lines = { new_hunk_lines[1] }
    for i = 2, #new_hunk_lines do
      if new_hunk_lines[i] > unique_lines[#unique_lines] then
        table.insert(unique_lines, new_hunk_lines[i])
      end
    end
    hunk_store.set(buffer, unique_lines)
  else
    hunk_store.clear(buffer)
  end
  return mark_count > 0
end

-- Function to check if diff is currently displayed in a buffer
function M.is_diff_displayed(buffer)
  buffer = buffer or vim.api.nvim_get_current_buf()
  local ns_id = config.ns_id
  local marks = vim.api.nvim_buf_get_extmarks(buffer, ns_id, 0, -1, {})
  return #marks > 0
end

---@param commit string
---@param buffer_id? integer Optional buffer ID to show diff in. Defaults to current buffer.
function M.show(commit, buffer_id)
  local buffer = buffer_id or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buffer) then
    vim.api.nvim_echo({ { "Invalid buffer provided to diff.show", "ErrorMsg" } }, false, {})
    return false
  end

  local ft = vim.api.nvim_buf_get_option(buffer, "filetype")

  if ft == "unified_tree" then
    return false
  end

  local git = require("unified.git")
  return git.show_git_diff_against_commit(commit, buffer)
end

---@param buffer integer
---@param base_text string
---@return boolean success
function M.show_against_text(buffer, base_text)
  buffer = buffer or vim.api.nvim_get_current_buf()
  if buffer == 0 then
    buffer = vim.api.nvim_get_current_buf()
  end
  if not vim.api.nvim_buf_is_valid(buffer) then
    return false
  end
  if type(base_text) ~= "string" then
    return false
  end

  local ns_id = config.ns_id
  vim.api.nvim_buf_clear_namespace(buffer, ns_id, 0, -1)
  vim.fn.sign_unplace("unified_diff", { buffer = buffer })
  hunk_store.clear(buffer)

  local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
  local cur_text = table.concat(lines, "\n")
  if vim.bo[buffer].endofline then
    cur_text = cur_text .. "\n"
  end

  if cur_text == base_text then
    return true
  end

  local diff_output = vim.diff(base_text, cur_text, { result_type = "unified", ctxlen = 3 })
  if type(diff_output) ~= "string" or diff_output == "" then
    return true
  end

  local hunks = M.parse_diff(diff_output)
  return M.display_inline_diff(buffer, hunks)
end

function M.show_current(commit)
  if not commit then
    local state = require("unified.state")
    local ok
    ok, commit = pcall(state.get_commit_base)
    commit = ok and commit or "HEAD"
  end

  local buf = vim.api.nvim_get_current_buf()
  local ft = vim.api.nvim_buf_get_option(buf, "filetype")
  if ft == "unified_tree" then
    return false
  end

  return M.show(commit, buf)
end

return M
