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
- **Highly Configurable**: Icons, keymaps, UI appearance, and more.

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
            error = " ",
            warn = " ",
            info = " ",
            project = " ",
            project_active = " ",
            workspace = " ",
            workspace_active = " ",
            tab = " ",
            tab_active = " ",
            file = " ",
            file_active = " ",
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
