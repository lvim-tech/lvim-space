# LVIM SPACE - v1.3.0

**LVIM SPACE** is a Neovim plugin for advanced management of projects, workspaces, tabs, and files, featuring a visual UI, persistent sessions, NerdFont icons, and both automatic and manual save options.

https://github.com/user-attachments/assets/6c20d82b-abb5-445a-a630-2aca3adb76ae

---

## Installation

### Lazy

```lua
{
  "lvim-tech/lvim-space",
  dependencies = {
    "kkharji/sqlite.lua",
    "lvim-tech/lvim-utils",
  },
  config = function()
    require("lvim-space").setup({
      -- Your configuration here
    })
  end
}
```

### Packer

```lua
use({
    "lvim-tech/lvim-space",
    requires = {
        "kkharji/sqlite.lua",
    },
    config = function()
        require("lvim-space").setup({
            -- Your configuration here
        })
    end,
})
```

---

## Features

- **Projects**: Manage multiple projects, each with its own workspaces, tabs, and files.
- **Workspaces**: Each project can contain multiple workspaces (contexts). You can add, rename, delete, and switch workspaces.
- **Tabs**: Each workspace supports multiple tabs, each with its own window/buffer layout.
- **Files**: Tabs remember their files, window layout, and cursor positions.
- **🆕 Reordering**: Move projects, workspaces, and tabs up/down to organize them exactly how you want.
- **🆕 File Search**: Powerful fuzzy search functionality for quickly finding and opening files in your project with intelligent matching and highlighting.
- **Session Management**: Automatically or manually save and restore the state of your workspaces, tabs, and files.
- **Visual UI Panels**: Navigate and manage projects, workspaces, tabs, and files with a floating panel UI and icons.
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

| Function | Returns | Description |
|---|---|---|
| `pub.get_tab_info()` | `{ project_name, workspace_name, tabs[] }` | Full state summary |
| `pub.get_active_tab()` | `{ id, name }` or `nil` | Currently active tab |
| `pub.get_workspace_name()` | `string` or `nil` | Active workspace name |
| `pub.get_project_name()` | `string` or `nil` | Active project name |

`get_tab_info()` returns:

```lua
{
  project_name   = "my-project",
  workspace_name = "Workspace 1",
  tabs = {
    { id = 7, name = "Tab 1", active = true  },
    { id = 8, name = "Tab 2", active = false },
  }
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
| Action  | Split Vertical   | `v`         | Open file in vertical split                    |
| Action  | Split Horizontal | `h`         | Open file in horizontal split                  |
| Action  | Move Up          | `<C-k>`     | Move selected entity up in order               |
| Action  | Move Down        | `<C-j>`     | Move selected entity down in order             |

> **Note**: Keybindings are context-sensitive and apply only inside the plugin's floating panels.

---

## User Commands

Everything is routed through a single `:LvimSpace` command with subcommands and tab-completion.

### UI

| Command | Description |
|---|---|
| `:LvimSpace` | Open context-aware panel (projects → workspaces → tabs → files) |
| `:LvimSpace open [panel]` | Open a specific panel (`projects`, `workspaces`, `tabs`, `files`, `search`) |

### Session

| Command | Description |
|---|---|
| `:LvimSpace save` | Manually save the full session state |

### Tab management

| Command | Description |
|---|---|
| `:LvimSpace tab` | Print current project / workspace / tab state to `:messages` |
| `:LvimSpace tab info` | Same as above |
| `:LvimSpace tab next` | Switch to the next tab (wraps around) |
| `:LvimSpace tab prev` | Switch to the previous tab (wraps around) |
| `:LvimSpace tab new [name]` | Create a new tab with an optional name |
| `:LvimSpace tab close [id]` | Close the specified tab (defaults to active tab) |
| `:LvimSpace tab move-next` | Move active tab one position forward |
| `:LvimSpace tab move-prev` | Move active tab one position backward |
| `:LvimSpace tab goto <n>` | Switch to tab at 1-based position `n` |
| `:LvimSpace tab rename <name>` | Rename the active tab |

### Diagnostics

| Command | Description |
|---|---|
| `:LvimSpace metrics` | Show metrics report |
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

    -- fd command used for file search (requires fd and fzf on PATH).
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
        filetype       = "lvim-space",
        title          = "LVIM SPACE",
        title_position = "center",  -- "left" | "center" | "right"
        max_height     = 10,
        spacing        = 2,         -- padding spaces in the status/info line

        border = {
            sign   = " ",
            main   = { left = true, right = true },
            info   = { left = true, right = true },
            prompt = { left = true, right = true, separate = ":" },
            input  = { left = true, right = true },
        },

        icons = {
            error            = " ",
            warn             = " ",
            info             = " ",
            project          = " ",
            project_active   = " ",
            workspace        = " ",
            workspace_active = " ",
            tab              = " ",
            tab_active       = " ",
            file             = " ",
            file_active      = " ",
            empty            = "󰇘 ",
            pre              = "➤ ",
        },

        highlight = {
            bg               = "#1a1a22",
            bg_line          = "#1a1a22",
            fg               = "#505067",
            fg_line          = "#4a6494",
            bg_fuzzy         = "#1a1a22",   -- background for fuzzy match highlights
            fg_fuzzy_primary = "#b65252",   -- primary character match colour
            fg_fuzzy_secondary = "#a26666", -- secondary character match colour
        },
    },

    -- -------------------------------------------------------------------------
    -- Notifications
    -- -------------------------------------------------------------------------
    notify = {
        enabled   = true,
        min_level = vim.log.levels.INFO, -- suppress DEBUG / TRACE messages
        title     = "Lvim Space",
        timeout   = 3000,               -- milliseconds
    },

    -- -------------------------------------------------------------------------
    -- Debug file logging (disabled by default)
    -- -------------------------------------------------------------------------
    debug = {
        enabled   = false,
        min_level = vim.log.levels.DEBUG,
        file      = vim.fn.stdpath("state") .. "/lvim-space/debug.log",
    },

    -- -------------------------------------------------------------------------
    -- Metrics collection (disabled by default, opt-in)
    -- -------------------------------------------------------------------------
    metrics = {
        enabled                  = false,
        max_examples             = 3,
        max_top_messages         = 5,
        default_refresh_interval = 2,       -- seconds (live window)
        auto_save_interval       = 3600000, -- milliseconds (0 = off)
    },

    -- -------------------------------------------------------------------------
    -- Keymaps
    -- -------------------------------------------------------------------------
    keymappings = {
        main = "<C-Space>",
        global = {
            projects   = "p",
            workspaces = "w",
            tabs       = "t",
            files      = "f",
            search     = "s",
        },
        action = {
            add       = "a",
            delete    = "d",
            rename    = "r",
            switch    = "<Space>",
            enter     = "<CR>",
            split_v   = "v",
            split_h   = "h",
            move_down = "<C-j>",
            move_up   = "<C-k>",
        },
    },

    -- Keys permitted inside plugin panels; all others are blocked.
    key_control = {
        allowed = { "j", "k", "<C-j>", "<C-k>" },
        explicitly_disabled = {
            "$", "gg", "G", "<C-d>", "<C-u>",
            "<Left>", "<Right>", "<Up>", "<Down>",
            "<Space>", "BS",
        },
        disable_categories = {
            lowercase_letters = true,
            uppercase_letters = true,
            digits            = true,
        },
    },
})
```

---

## UI & Appearance

- The UI uses floating windows with customizable borders and highlights.
- NerdFont icons are used everywhere for clarity.
- Empty panels display an icon and message from your language configuration.
- State is stored in a SQLite database for reliability and speed.
- Highlight groups are re-applied automatically when the colorscheme changes.

---

## Manual Save

If `autosave = false`, persist the full state manually:

```
:LvimSpaceSave
```

---

## Requirements

- **Neovim 0.10+**
- **NerdFont** enabled terminal (for icons)
- **[fd](https://github.com/sharkdp/fd)** — used by the file search feature
- **[fzf](https://github.com/junegunn/fzf)** — used by the file search feature
- **[sqlite.lua](https://github.com/kkharji/sqlite.lua)** — Neovim SQLite wrapper
- **[lvim-utils](https://github.com/lvim-tech/lvim-utils)** — cursor management and UI components

> The search feature requires both `fd` and `fzf` on your `PATH`. All other features work without them.

---

## Troubleshooting

- If icons do not display, ensure your terminal uses a NerdFont.
- If state is not saved/restored, check your `autosave` / `autorestore` setting or run `:LvimSpaceSave`.
- If search returns no results, verify that `fd` and `fzf` are installed and on your `PATH`.
- For debug logging, set `debug.enabled = true` in your config — logs are written to `debug.file`.
- For bugs or feature requests, please open an issue on the GitHub repository.

---

## License

BSD 3-Clause

---

**Enjoy organized, persistent, and beautiful Neovim sessions with lvim-space!**
