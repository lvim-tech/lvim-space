# LVIM SPACE - v1.3.0

**LVIM SPACE** is a Neovim plugin for advanced management of projects, workspaces, tabs, and files, featuring a visual UI, persistent sessions, NerdFont icons, and both automatic and manual save options.

https://github.com/user-attachments/assets/6c20d82b-abb5-445a-a630-2aca3adb76ae

---

[![License: BSD-3-Clause](https://img.shields.io/badge/License-BSD--3--Clause-blue.svg)](https://github.com/lvim-tech/lvim-space/blob/main/LICENSE)

## Installation

Requires Neovim >= 0.11 and [lvim-utils](https://github.com/lvim-tech/lvim-utils) and [sqlite.lua](https://github.com/kkharji/sqlite.lua).

### lvim-installer (recommended)

Install and manage it from the LVIM package manager — open the **Plugins** tab and install / update / pin it:

```vim
:LvimInstaller plugins
```

lvim-installer installs plugins through Neovim's built-in `vim.pack`, so no external plugin manager is needed.

### lazy.nvim

```lua
return {
    "lvim-tech/lvim-space",
    dependencies = {
        "kkharji/sqlite.lua",
        "lvim-tech/lvim-utils",
    },
    config = function()
        require("lvim-space").setup({})
    end,
}
```

### packer.nvim

```lua
use({
    "lvim-tech/lvim-space",
    requires = {
        "kkharji/sqlite.lua",
        "lvim-tech/lvim-utils",
    },
    config = function()
        require("lvim-space").setup({})
    end,
})
```

### Native (vim.pack)

```lua
vim.pack.add({
    { src = "https://github.com/kkharji/sqlite.lua" },
    { src = "https://github.com/lvim-tech/lvim-utils" },
    { src = "https://github.com/lvim-tech/lvim-space" },
})
require("lvim-space").setup({})
```

---

## Features

- **Projects**: Manage multiple projects, each with its own workspaces, tabs, and files.
- **Workspaces**: Each project can contain multiple workspaces (contexts). You can add, rename, delete, and switch workspaces.
- **Tabs**: Each workspace supports multiple tabs, each with its own window/buffer layout.
- **Files**: Tabs remember their files, window layout, and cursor positions.
- **Reordering**: Move projects, workspaces, and tabs up/down to organize them exactly how you want.
- **Picker Search**: File search is the shared lvim-utils picker — fuzzy filter as you type, coloured filetype devicons, `<CR>` to open + add to the tab, `<C-v>`/`<C-x>` to open in a split. Every entity panel also gets a `/` key that opens the picker over its current list.
- **Session Management**: Automatically or manually save and restore the state of your workspaces, tabs, and files.
- **Dockable UI**: The panels, prompts and search render on the lvim-utils surface in one of three modes — `area` (the Emacs-style cmdline zone, default), `float` (a centred modal), or `bottom` (a bottom dock).
- **NerdFont Icons**: Visual indicators for all entities (project, workspace, tab, file, empty, etc).
- **Autosave**: Choose between automatic or manual session saving.
- **User Commands**: Full suite of commands for tab management, session control, and diagnostics.
- **API Integration**: Public API for integration with other plugins and status lines.
- **Highly Configurable**: Icons, keymaps, UI appearance, notifications, debug logging, and more.

---

## API Integration

LVIM SPACE provides a public API for integration with other plugins, status lines, and custom configurations.

```lua
local pub = require("lvim-space.pub")
```

### Available functions

| Function                   | Returns                                    | Description           |
| -------------------------- | ------------------------------------------ | --------------------- |
| `pub.get_tab_info()`       | `{ project_name, workspace_name, tabs[] }` | Full state summary    |
| `pub.get_active_tab()`     | `{ id, name }` or `nil`                    | Currently active tab  |
| `pub.get_workspace_name()` | `string` or `nil`                          | Active workspace name |
| `pub.get_project_name()`   | `string` or `nil`                          | Active project name   |
| `pub.has_project_for_cwd()` | `boolean`                                 | `true` when the cwd has a saved project (opens the DB first; safe to call early — e.g. from a dashboard `should_open` probe) |

`get_tab_info()` returns:

```lua
local info = {
    project_name = "my-project",
    workspace_name = "Workspace 1",
    tabs = {
        { id = 7, name = "Tab 1", active = true },
        { id = 8, name = "Tab 2", active = false },
    },
}
```

All functions return safe defaults (empty tables / `nil`) when the plugin has not been set up or no session is active — safe to call at any time.

**Example with tabby.nvim:**

```lua
local function get_lvim_space_tabs()
    local ok, pub = pcall(require, "lvim-space.pub")
    if not ok then
        return { project_name = "Unknown", workspace_name = "Unknown", tabs = {} }
    end
    return pub.get_tab_info()
end

local components = function()
    local comps = {}
    local lvim_data = get_lvim_space_tabs()

    for _, tab in ipairs(lvim_data.tabs or {}) do
        local hl = tab.active and active_highlight or inactive_highlight
        table.insert(comps, {
            type = "text",
            text = { "  " .. tab.name .. "  ", hl = hl },
        })
    end

    table.insert(comps, {
        type = "text",
        text = { "  " .. (lvim_data.workspace_name or "Unknown") .. "  " },
    })

    return comps
end

require("tabby").setup({ components = components })
```

---

## Keymaps

Below are the default keybindings. You can customize these in the `keymappings` section of your config.

| Context | Action           | Key         | Description                                    |
| ------- | ---------------- | ----------- | ---------------------------------------------- |
| Global  | Open panel       | `<C-Space>` | Open main lvim-space panel                     |
| Global  | Projects         | `p`         | Open projects panel                            |
| Global  | Workspaces       | `w`         | Open workspaces panel                          |
| Global  | Tabs             | `t`         | Open tabs panel                                |
| Global  | Files            | `f`         | Open files panel                               |
| Global  | Search           | `s`         | Open search panel                              |
| Action  | Add              | `a`         | Add new entity (project, workspace, tab, file) |
| Action  | Delete           | `d`         | Delete selected entity                         |
| Action  | Rename           | `r`         | Rename selected entity                         |
| Action  | Switch           | `<Space>`   | Load entity (keep panel open)                  |
| Action  | Enter/Select     | `<CR>`      | Enter entity (close panels, open deepest view) |
| Action  | Split Vertical   | `v`         | Open file in vertical split (files panel)      |
| Action  | Split Horizontal | `h`         | Open file in horizontal split (files panel)    |
| Action  | Move Up          | `K`         | Move selected entity up in order               |
| Action  | Move Down        | `J`         | Move selected entity down in order             |
| Action  | Filter           | `/`         | Open the picker over the current list to filter and jump |
| Nav     | Sector Down      | `<C-j>`     | Descend the focus sector (list → footer bar → messages) |
| Nav     | Sector Up        | `<C-k>`     | Ascend the focus sector (footer bar → list → editor)    |

> **Note**: Keybindings are context-sensitive and apply only inside the plugin's panels.
> `<C-j>`/`<C-k>` navigate the focus sectors (the same convention as the lvim-utils picker):
> `<C-j>` drops focus into the navigable footer bar, where `h`/`l` move along the buttons and
> `<CR>`/`<Space>` fire the focused one; `<C-k>` returns focus to the list.

### Search picker keys

Inside the file-search picker (`s` / `:LvimSpace open search`):

| Key      | Description                                                  |
| -------- | ------------------------------------------------------------ |
| _typing_ | Fuzzy-filter the file list as you type                       |
| `<CR>`   | Open the file in the editor and add it to the active tab     |
| `<C-v>`  | Open the selection in a vertical split (no tab change)       |
| `<C-x>`  | Open the selection in a horizontal split (no tab change)     |
| `<Esc>`  | Cancel                                                        |

---

## User Commands

Everything is routed through a single `:LvimSpace` command with subcommands and tab-completion.

### UI

| Command                   | Description                                                                 |
| ------------------------- | --------------------------------------------------------------------------- |
| `:LvimSpace`              | Open context-aware panel (projects → workspaces → tabs → files)             |
| `:LvimSpace open [panel]` | Open a specific panel (`projects`, `workspaces`, `tabs`, `files`, `search`) |

### Session

| Command           | Description                          |
| ----------------- | ------------------------------------ |
| `:LvimSpace save` | Manually save the full session state |

### Tab management

| Command                        | Description                                                  |
| ------------------------------ | ------------------------------------------------------------ |
| `:LvimSpace tab`               | Print current project / workspace / tab state to `:messages` |
| `:LvimSpace tab info`          | Same as above                                                |
| `:LvimSpace tab next`          | Switch to the next tab (wraps around)                        |
| `:LvimSpace tab prev`          | Switch to the previous tab (wraps around)                    |
| `:LvimSpace tab new [name]`    | Create a new tab with an optional name                       |
| `:LvimSpace tab close [id]`    | Close the specified tab (defaults to active tab)             |
| `:LvimSpace tab move-next`     | Move active tab one position forward                         |
| `:LvimSpace tab move-prev`     | Move active tab one position backward                        |
| `:LvimSpace tab goto <n>`      | Switch to tab at 1-based position `n`                        |
| `:LvimSpace tab rename <name>` | Rename the active tab                                        |

### Diagnostics

| Command                   | Description                              |
| ------------------------- | ---------------------------------------- |
| `:LvimSpace metrics`      | Show metrics report                      |
| `:LvimSpace metrics live` | Show auto-refreshing live metrics window |

---

## Configuration

Below is the full configuration with all available options and their defaults.

```lua
require("lvim-space").setup({
    -- Where the SQLite database is stored.
    save = "~/.local/share/nvim/lvim-space",

    -- Language pack to load (currently only "en" is bundled).
    lang = "en",

    -- Automatically save session state on buffer events.
    autosave = true,

    -- Automatically restore the last session on startup.
    autorestore = true,

    -- Open the files panel automatically after adding a file.
    open_panel_on_add_file = false,

    -- Shell command listing project files for the picker search (run in the
    -- project root). Requires its first token (fd by default) on PATH.
    search = "fd --type f --hidden --follow"
        .. " --exclude .git"
        .. " --exclude node_modules"
        .. " --exclude target"
        .. " --exclude build"
        .. " --exclude dist",

    -- -------------------------------------------------------------------------
    -- UI appearance
    -- -------------------------------------------------------------------------
    ui = {
        filetype = "lvim-space",
        title = "LVIM SPACE",
        -- Title alignment. nil (default) INHERITS the central lvim-utils
        -- `config.ui.title_pos` (default "left"); set "left" | "center" |
        -- "right" to override the placement for lvim-space alone.
        title_pos = nil,

        -- Where every panel, prompt and the search picker docks. Rendered
        -- through lvim-utils.ui.surface:
        --   "area"   (default) the Emacs-style cmdline/minibuffer zone —
        --            hosted above the messages when the lvim-utils msgarea
        --            zone is enabled, otherwise it grows 'cmdheight'; the
        --            editor and statusline stay above it.
        --   "float"  a centred modal with a border-title.
        --   "bottom" a bar docked over the bottom rows.
        mode = "area",

        -- Where the panel title is drawn. nil (default) INHERITS the central
        -- lvim-utils `config.ui.title_line` (default "row"):
        --   "row"        a content row at the top — TITLE flush-left, item
        --                count flush-right, matching the lvim-utils pickers.
        --   "border"     the native border-title on the top border.
        --   "statusline" published to the lvim-utils chrome overlay
        --                (minibuffer style — the heirline file segments give
        --                way to the panel title while a panel is open).
        -- Set this key only to override the placement for lvim-space alone;
        -- the frame border is the single shared lvim-utils `config.ui.border`.
        title_line = nil,

        spacing = 2, -- padding spaces in the status/info line

        icons = {
            error = " ",
            warn = " ",
            info = " ",
            project = " ",
            project_active = " ",
            workspace = " ",
            workspace_active = " ",
            tab = " ",
            tab_active = " ",
            file = " ",
            file_active = " ",
            empty = "󰇘 ",
            pre = "➤ ",
        },
    },

    -- -------------------------------------------------------------------------
    -- Highlight groups
    -- -------------------------------------------------------------------------
    -- When false (default), highlight groups are defined only if the active
    -- colorscheme has not already set them — the theme takes priority.
    -- When true, lvim-space always applies its own palette-based colors,
    -- overriding anything the colorscheme may have defined.
    highlights_force = false,

    -- -------------------------------------------------------------------------
    -- Notifications
    -- -------------------------------------------------------------------------
    notify = {
        enabled = true,
        min_level = vim.log.levels.INFO, -- suppress DEBUG / TRACE messages
        title = "Lvim Space",
        timeout = 3000, -- milliseconds
    },

    -- -------------------------------------------------------------------------
    -- Debug file logging (disabled by default)
    -- -------------------------------------------------------------------------
    debug = {
        enabled = false,
        min_level = vim.log.levels.DEBUG,
        file = vim.fn.stdpath("state") .. "/lvim-space/debug.log",
    },

    -- -------------------------------------------------------------------------
    -- Metrics collection (disabled by default, opt-in)
    -- -------------------------------------------------------------------------
    metrics = {
        enabled = false,
        max_examples = 3,
        max_top_messages = 5,
        default_refresh_interval = 2, -- seconds (live window)
        auto_save_interval = 3600000, -- milliseconds (0 = off)
    },

    -- -------------------------------------------------------------------------
    -- Keymaps
    -- -------------------------------------------------------------------------
    keymappings = {
        main = "<C-Space>",
        global = {
            projects = "p",
            workspaces = "w",
            tabs = "t",
            files = "f",
            search = "s",
        },
        action = {
            add = "a",
            delete = "d",
            rename = "r",
            switch = "<Space>",
            enter = "<CR>",
            split_v = "v",
            split_h = "h",
            move_down = "J",
            move_up = "K",
        },
    },

    -- Keys permitted inside plugin panels; all others are blocked. `<C-j>`/`<C-k>` are intentionally NOT
    -- listed: they belong to the surface's sector navigation, not the panel, so they fall through to the
    -- chassis. `K`/`J` are listed so the `uppercase_letters` blanket-disable does not no-op the reorder keys.
    key_control = {
        allowed = { "j", "k", "K", "J" },
        explicitly_disabled = {
            "$",
            "gg",
            "G",
            "<C-d>",
            "<C-u>",
            "<Left>",
            "<Right>",
            "<Up>",
            "<Down>",
            "<Space>",
            "BS",
        },
        disable_categories = {
            lowercase_letters = true,
            uppercase_letters = true,
            digits = true,
        },
    },
})
```

---

## UI & Appearance

- The UI renders on the shared **lvim-utils surface**. `ui.mode` selects where it docks:
  - **`area`** (default) — the Emacs-style cmdline/minibuffer zone. When the lvim-utils
    msgarea zone is enabled the panel is hosted **above** the messages (the editor and
    statusline stay in place); otherwise it falls back to growing `cmdheight`.
  - **`float`** — a centred modal with a border-title.
  - **`bottom`** — a bar docked over the bottom rows.
- Every mode draws the one shared lvim-utils frame border (`config.ui.border`). By default
  (`ui.title_line` inherits the central `"row"`) the title is a content row at the top of the
  panel — title flush-left, item count flush-right — matching the lvim-utils pickers. Set
  `ui.title_line = "border"` to move it onto the top border, or `"statusline"` to publish an
  `area` panel's title to the chrome overlay (minibuffer style).
- NerdFont icons are used everywhere for clarity.
- The hardware cursor is hidden in panels via the lvim-utils cursor module.
- Empty panels display an icon and message from your language configuration.
- State is stored in a SQLite database for reliability and speed.
- Highlight groups self-theme from the lvim-utils palette and are re-applied automatically when the colorscheme changes (they also follow a transparent theme).

---

## Manual Save

If `autosave = false`, persist the full state manually:

```
:LvimSpace save
```

---

## Requirements

- **Neovim 0.11+**
- **[sqlite.lua](https://github.com/kkharji/sqlite.lua)** — the session persistence backend (**required**; no state can be stored without it)
- **[lvim-utils](https://github.com/lvim-tech/lvim-utils)** — the UI renders through its `ui.surface`, `picker` and `cursor` modules and self-themes from its colour palette (**required**)
- **NerdFont** enabled terminal (for icons)
- **[fd](https://github.com/sharkdp/fd)** — the default file-search command (only needed for search; everything else works without it)

> Run `:checkhealth lvim-space` to verify the runtime. The search feature needs the first token of `search` (fd by default) on your `PATH`; all other features work without it.

---

## Troubleshooting

- Run `:checkhealth lvim-space` first — it reports a missing sqlite.lua / lvim-utils, an unwritable save dir, an invalid `ui.mode`, an `area` mode without the msgarea zone, or a missing search command.
- If icons do not display, ensure your terminal uses a NerdFont.
- If state is not saved/restored, check your `autosave` / `autorestore` setting or run `:LvimSpace save`.
- If the area panel grows `cmdheight` instead of floating above the messages, enable the lvim-utils msgarea zone, or set `ui.mode = "float"` / `"bottom"`.
- If search returns no results, verify the `search` command (fd by default) is installed and on your `PATH`.
- For debug logging, set `debug.enabled = true` in your config — logs are written to `debug.file`.
- For bugs or feature requests, please open an issue on the GitHub repository.

---

## License

BSD 3-Clause

---

**Enjoy organized, persistent, and beautiful Neovim sessions with lvim-space!**
