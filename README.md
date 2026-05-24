# unified.nvim

A Neovim plugin for displaying inline unified diffs directly in your buffer.

<img width="1840" alt="image" src="https://github.com/user-attachments/assets/7655659e-c8af-40c5-ad70-59f67a2b16d9" />

> This is a fork of [axkirillov/unified.nvim](https://github.com/axkirillov/unified.nvim). All credit for the original design and implementation goes to the upstream author and contributors, thank you. This fork carries small additions (intra-line highlighting, embeddable diff API, optional file tree, etc.) on top of that foundation.

## Features

* **Inline Diffs**: View git diffs directly in your buffer, without needing a separate window.
* **Intra-line Highlights**: Within a changed line, only the bytes that actually differ get an extra emphasis on top of the line background.
* **File Tree Explorer**: A file tree explorer is displayed, showing all files that have been changed.
* **Git Gutter Signs**: Gutter signs are used to indicate added, modified, and deleted lines.
* **Customizable**: Configure the signs, highlights, and line symbols to your liking.
* **Auto-refresh**: The diff view automatically refreshes as you make changes to the buffer.

## Requirements

-   Neovim >= 0.5.0
-   Git
-   A [Nerd Font](https://www.nerdfonts.com/) installed and configured in your terminal/GUI is required to display file icons correctly in the file tree.
-   (Optional) [snacks.nvim](https://github.com/folke/snacks.nvim) - Required only if you want to use the Snacks file explorer backend instead of the default custom file tree.

## Installation

You can install `unified.nvim` using your favorite plugin manager.

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  'papricasix/unified.nvim',
  opts = {
    -- your configuration comes here
  }
}
```

### [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  'papricasix/unified.nvim',
  config = function()
    require('unified').setup({
      -- your configuration comes here
    })
  end
}
```

## Configuration

You can configure `unified.nvim` by passing a table to the `setup()` function. Here are the default settings:

```lua
require('unified').setup({
  signs = {
    add = "│",
    delete = "│",
    change = "│",
  },
  highlights = {
    add = "DiffAdd",
    delete = "DiffDelete",
    change = "DiffChange",
    add_text = "DiffText",    -- intra-line emphasis for added bytes
    delete_text = "DiffText", -- intra-line emphasis for deleted bytes
  },
  line_symbols = {
    add = "+",
    delete = "-",
    change = "~",
  },
  auto_refresh = true, -- Whether to automatically refresh diff when buffer changes
  file_tree = {
    enabled = false,         -- When true, :Unified opens a left-split file tree; when false, only the inline diff renders
    width = 30,              -- Width of the file tree window (columns, or 0-1 for relative)
    filename_first = true,   -- Show filename before directory path (Snacks backend only)
    auto_open_first_file = true, -- Auto-open the first changed file after :Unified
  },
})
```

> By default `file_tree.enabled = false`, so `:Unified` shows only the inline diff in the current buffer. Set `file_tree = { enabled = true }` to restore the file-tree side panel.

## Usage

### Basic Commands

1.  Open a file in a git repository.
2.  Make some changes to the file.
3.  Run the command `:Unified` to display the diff against `HEAD` and open the file tree.
4.  To close the diff view and file tree, run `:Unified reset`.
5.  To show the diff against a specific commit, run `:Unified <commit_ref>`, for example `:Unified HEAD~1`.

### Snacks Integration (Optional)

unified.nvim supports integration with [snacks.nvim](https://github.com/folke/snacks.nvim)'s git_diff picker as an alternative file browser. This provides a feature-rich experience with built-in diff previews, git status formatting, and staging capabilities.

**Installation:**

First, install snacks.nvim:

```lua
{
  'folke/snacks.nvim',
  priority = 1000,
  lazy = false,
  opts = {
    -- your snacks config
  }
}
```

**Commands:**

```vim
:Unified -s HEAD        " Use Snacks picker, compare against HEAD
:Unified -s HEAD~1      " Use Snacks picker, compare against HEAD~1
:Unified -s origin/main " Use Snacks picker, compare against origin/main
```

The Snacks picker provides:
- Built-in diff preview pane
- Git status indicators and formatting
- File staging with `<Tab>`
- File restoration with `<c-r>`
- All standard unified.nvim inline diff functionality when files are selected

### File Tree Interaction (Default Backend)

When the default file tree is open, you can use the following keymaps:

  * `j`/`k` or `<Down>`/`<Up>`: Move the cursor down/up between file nodes.
  * `l`: Open the file under the cursor in the main window, displaying its diff.
  * `q`: Close the file tree window.
  * `R`: Refresh the file tree.
  * `?`: Show a help dialog.

When the file tree opens, the first file is automatically opened in the main window.

The file tree displays the Git status of each file:

  - `M`: Modified
  - `A`: Added
  - `D`: Deleted
  - `R`: Renamed
  - `C`: Copied
  - `?`: Untracked

### Navigating Hunks

To navigate between hunks, you'll need to set your own keymaps:

```lua
vim.keymap.set('n', ']h', function() require('unified.navigation').next_hunk() end)
vim.keymap.set('n', '[h', function() require('unified.navigation').previous_hunk() end)
```

### Toggle API

For programmatic control, you can use the toggle function:

```lua
vim.keymap.set('n', '<leader>ud', require('unified').toggle, { desc = 'Toggle unified diff' })
```

This toggles the diff view on/off, remembering the previous commit reference.

### Hunk actions (API)

Unified provides a function-only API for hunk actions. Define your own keymaps or commands if desired.

Example keymaps:

```lua
local actions = require('unified.hunk_actions')
vim.keymap.set('n', 'gs', actions.stage_hunk,   { desc = 'Unified: Stage hunk' })
vim.keymap.set('n', 'gu', actions.unstage_hunk, { desc = 'Unified: Unstage hunk' })
vim.keymap.set('n', 'gr', actions.revert_hunk,  { desc = 'Unified: Revert hunk' })
```

Behavior notes:
- Operates on the hunk under the cursor inside a regular file buffer (not in the unified file tree buffer).
- Stage: applies a minimal single-hunk patch to the index.
- Unstage: reverse-applies the hunk patch from the index.
- Revert: reverse-applies the hunk patch to the working tree.
- Binary patches are skipped with a user message.
- After an action, the inline diff and file tree are refreshed automatically.

### Embedding the inline diff (for other plugins)

unified.nvim exposes a low-level primitive that renders an inline diff between a buffer's current contents and an arbitrary base string. No git, no file tree, no buffer/window management; your plugin keeps full control of those.

```lua
---@param buffer integer Buffer to draw the diff marks on
---@param base_text string Reference content to diff against
require("unified.diff").show_against_text(buffer, base_text)
```

This powers the [claudecode.nvim](https://github.com/papricasix/claudecode.nvim) integration (fork of [coder/claudecode.nvim](https://github.com/coder/claudecode.nvim)): when both plugins are installed, claudecode renders Claude-proposed file changes as a single inline-diff buffer instead of the default side-by-side vimdiff.

## Commands

  * `:Unified`: Shows the diff against `HEAD` using the default file tree.
  * `:Unified <commit_ref>`: Shows the diff against the specified commit reference (e.g., a commit hash, branch name, or tag) using the default file tree.
  * `:Unified -s <commit_ref>`: Shows the diff against the specified commit reference using the Snacks git_diff picker (requires snacks.nvim).
  * `:Unified reset`: Removes all unified diff highlights and signs from the current buffer and closes the file tree window if it is open.

## Development

### Running Tests

To run all automated tests:

```bash
make tests
```

To run a specific test function:

```bash
make test TEST=test_file_name.test_function_name
```

## License

MIT
