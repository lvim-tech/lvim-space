# LVIM SPACE

**LVIM SPACE** is a Neovim plugin for advanced management of projects, workspaces, tabs, and files, featuring a visual UI, persistent sessions, NerdFont icons, and both automatic and manual save options.

https://github.com/user-attachments/assets/6c20d82b-abb5-445a-a630-2aca3adb76ae

---

## Features

- **Projects**: Manage multiple projects, each with its own workspaces, tabs, and files.
- **Workspaces**: Each project can contain multiple workspaces (contexts). You can add, rename, delete, and switch workspaces.
- **Tabs**: Each workspace supports multiple tabs, each with its own window/buffer layout.
- **Files**: Tabs remember their files, window layout, and cursor positions.
- **Session Management**: Automatically or manually save and restore the state of your workspaces, tabs, and files.
- **Visual UI Panels**: Navigate and manage projects, workspaces, tabs, and files with a floating panel UI and icons.
- **NerdFont Icons**: Visual indicators for all entities (project, workspace, tab, file, empty, etc).
- **Autosave**: Choose between automatic or manual session saving.
- **User Commands**: Save state manually with `:LvimSpaceSave`.
- **API Integration**: Public API for integration with other plugins and status lines.
- **Highly Configurable**: Icons, keymaps, UI appearance, and more.

---

## API Integration

LVIM SPACE provides a public API for integration with other plugins, status lines, and custom configurations.

### Tab Information API

```lua
local pub = require("lvim-space.pub")
local tabs = pub.get_tab_info()
```

Returns an array of tab objects for the current workspace:

```lua
{
  { id = 1, name = "main", active = true },
  { id = 2, name = "feature", active = false },
  { id = 3, name = "testing", active = false }
}
```

**Properties:**

- `id` - Unique identifier of the tab
- `name` - Display name of the tab
- `active` - Boolean indicating if this is the currently active tab

**Use Cases:**

- Integration with status line plugins (tabby.nvim, lualine.nvim, etc.)
- Custom UI components showing workspace tabs
- Building external tools that interact with LVIM SPACE

**Example with tabby.nvim:**

```lua
local pub = require("lvim-space.pub")
local tabs = pub.get_tab_info()

for _, tab in ipairs(tabs) do
    local hl = tab.active and active_highlight or inactive_highlight
    -- Use tab.name and tab.active in your tabby configuration
end
```

---

## Keymaps

Below are the default keybindings, as set in your config. You can customize these in your `config.keymappings` section.

| Context | Action           | Key         | Description                                    |
| ------- | ---------------- | ----------- | ---------------------------------------------- |
| Global  | Projects         | `p`         | Open projects panel                            |
| Global  | Workspaces       | `w`         | Open workspaces panel                          |
| Global  | Tabs             | `t`         | Open tabs panel                                |
| Global  | Files            | `f`         | Open files panel                               |
| Action  | Add              | `a`         | Add new entity (project, workspace, tab, file) |
| Action  | Delete           | `d`         | Delete selected entity                         |
| Action  | Rename           | `r`         | Rename selected entity                         |
| Action  | Switch           | `<Space>`   | Switch/select entity                           |
| Action  | Enter/Select     | `<CR>`      | Enter/select entity                            |
| Action  | Split Vertical   | `v`         | Open in vertical split                         |
| Action  | Split Horizontal | `h`         | Open in horizontal split                       |
| Main    | Open Panel       | `<C-Space>` | Open main lvim-space panel                     |

> **Note**: Keybindings are context-sensitive and may change based on the active panel (projects, workspaces, tabs, files).

---

## User Commands

- `:LvimSpaceSave`  
  Manually save the full state (projects, workspaces, tabs, files) if autosave is disabled.

- `:LvimSpaceTabs`  
  Display information about all tabs in the current workspace (debugging command).

---

## Configuration Example

```lua
require("lvim-space").setup({
    save = "~/.local/share/nvim/lvim-space",
    lang = "en",
    notify = true,
    log = true,
    log_errors = true,
    log_warnings = true,
    log_info = true,
    log_debug = false,
    filetype = "lvim-space",
    title = "LVIM SPACE",
    title_position = "center",
    status_space = 2,
    max_height = 10,
    autosave = true,
    ui = {
        border = {
            sign = " ",
            main = { left = true, right = true },
            info = { left = true, right = true },
            prompt = { left = true, right = true, separate = ":" },
            input = { left = true, right = true },
        },
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
        },
        highlight = {
            bg = "#1a1a22",
            bg_line = "#1a1a22",
            fg = "#505067",
            fg_line = "#4a6494",
        },
    },
    keymappings = {
        main = "<C-Space>",
        global = {
            projects = "p",
            workspaces = "w",
            tabs = "t",
            files = "f",
        },
        action = {
            add = "a",
            delete = "d",
            rename = "r",
            path = "p",
            switch = "<Space>",
            enter = "<CR>",
            split_v = "v",
            split_h = "h",
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

---

## Manual Save

If `autosave = false`, use

```vim
:LvimSpaceSave
```

to persist the full state (projects, workspaces, tabs, files, layouts, etc).

---

## Requirements

- **Neovim 0.10+**
- **NerdFont** enabled terminal (for icons)

---

## Troubleshooting

- If icons do not display, ensure your terminal uses a NerdFont.
- If state is not saved/restored, check your autosave setting or use `:LvimSpaceSave`.
- For bugs or feature requests, please open an issue on the GitHub repository.

---

## License

MIT

---

**Enjoy organized, persistent, and beautiful Neovim sessions with lvim-space!**
