--- lvim-space type definitions (LuaLS / EmmyLua)
--- @meta

--------------------------------------------------------------------------------
-- DATABASE RECORDS
--------------------------------------------------------------------------------

--- A project record from the "projects" table.
--- @class LvimSpace.Project
--- @field id        integer  Primary key (autoincrement)
--- @field name      string   Display name (unique)
--- @field path      string   Absolute filesystem path with trailing slash (unique)
--- @field sort_order integer  Display order (default 1)

--- A workspace record from the "workspaces" table.
--- @class LvimSpace.Workspace
--- @field id         integer  Primary key (autoincrement)
--- @field project_id integer  Foreign key → projects.id (cascade delete)
--- @field name       string   Display name
--- @field tabs       string   JSON-encoded WorkspaceTabs
--- @field active     boolean  Whether this is the currently active workspace
--- @field sort_order integer  Display order (default 1)

--- A tab record from the "tabs" table.
--- @class LvimSpace.Tab
--- @field id           integer  Primary key (autoincrement)
--- @field workspace_id integer  Foreign key → workspaces.id (cascade delete)
--- @field name         string   Display name
--- @field data         string   JSON-encoded TabData
--- @field sort_order   integer  Display order (default 1)

--------------------------------------------------------------------------------
-- JSON PAYLOADS (stored serialised inside DB fields)
--------------------------------------------------------------------------------

--- Decoded content of Workspace.tabs (JSON).
--- @class LvimSpace.WorkspaceTabs
--- @field tab_ids    integer[]  Ordered list of tab IDs belonging to this workspace
--- @field tab_active integer    Currently active tab ID
--- @field created_at integer?   Unix timestamp of creation
--- @field updated_at integer?   Unix timestamp of last update

--- A single buffer entry inside TabData.buffers.
--- @class LvimSpace.BufferEntry
--- @field filePath    string   Absolute path to the file
--- @field bufnr       integer  Neovim buffer number at save time
--- @field filetype    string   Buffer filetype (e.g. "lua", "python")
--- @field cursor_line integer? Line number of the cursor when saved
--- @field cursor_col  integer? Column number of the cursor when saved
--- @field topline     integer? Top-most visible line number when saved
--- @field leftcol     integer? Left-most visible column when saved

--- A single window entry inside TabData.windows.
--- @class LvimSpace.WindowEntry
--- @field file_path    string   Absolute path of the file shown in this window
--- @field buffer_index integer  Index into TabData.buffers for this file
--- @field width        integer  Window width in columns
--- @field height       integer  Window height in rows
--- @field row          integer  Window top-left row (screen position)
--- @field col          integer  Window top-left column (screen position)
--- @field cursor_line  integer? Cursor line at save time
--- @field cursor_col   integer? Cursor column at save time
--- @field topline      integer? Top visible line at save time
--- @field leftcol      integer? Left visible column at save time

--- Decoded content of Tab.data (JSON).
--- @class LvimSpace.TabData
--- @field buffers        LvimSpace.BufferEntry[]  All open buffers in this tab
--- @field windows        LvimSpace.WindowEntry[]  All open windows in this tab
--- @field current_window integer                  Index of the focused window (1-based)
--- @field timestamp      integer                  Unix timestamp of when data was saved
--- @field tab_id         integer?                 Reference to the parent Tab.id

--------------------------------------------------------------------------------
-- IN-MEMORY / DERIVED STRUCTURES
--------------------------------------------------------------------------------

--- A file entry built by data.find_files() from the decoded TabData.
--- @class LvimSpace.FileEntry
--- @field id           string   Equals `path` (used as a unique key in UI maps)
--- @field path         string   Absolute filesystem path
--- @field name         string   Filename only (vim.fn.fnamemodify(path, ":t"))
--- @field bufnr_original integer Buffer number recorded at last save
--- @field tab_id       integer  ID of the parent tab
--- @field workspace_id integer  ID of the parent workspace

--- Buffer classification result produced by the internal classify_buffer().
--- @class LvimSpace.BufferClassification
--- @field is_special boolean  True for special buftypes, unnamed, or unlisted buffers
--- @field is_valid   boolean  False when bufnr is invalid; all other fields may be nil
--- @field is_listed  boolean? Whether the buffer is listed (buflisted option)
--- @field name       string?  Full buffer name (nvim_buf_get_name)
--- @field filetype   string?  Buffer filetype string

--- Cursor / scroll state collected per-path during session save.
--- @class LvimSpace.BufferCursorInfo
--- @field cursor_line integer  Line number
--- @field cursor_col  integer  Column number
--- @field topline     integer  Top visible line
--- @field leftcol     integer  Left visible column

--- Queued cursor-restore item used inside restore_session_layout().
--- @class LvimSpace.CursorRestoreInfo
--- @field win         integer  Window handle to restore cursor in
--- @field cursor_line integer? Line to restore
--- @field cursor_col  integer? Column to restore
--- @field topline     integer? Topline to restore
--- @field leftcol     integer? Leftcol to restore

--- Item passed inside the order-table to reorder_* functions.
--- @class LvimSpace.OrderItem
--- @field id    integer  Entity ID (project / workspace / tab)
--- @field order integer  New sort_order value

--------------------------------------------------------------------------------
-- GLOBAL STATE
--------------------------------------------------------------------------------

--- The global runtime state table (lua/lvim-space/api/state.lua).
--- Starts as an empty table and is populated at runtime.
--- @class LvimSpace.State
--- @field project_id        integer?          Active project ID
--- @field workspace_id      integer?          Active workspace ID
--- @field tab_ids           integer[]?        All tab IDs in the active workspace
--- @field tab_active        integer?          Currently active tab ID
--- @field lang              table?            Loaded language strings (lang/en.lua)
--- @field disable_auto_close boolean?         Temporarily disables UI auto-close
--- @field file_active        string?          Active file path (FileEntry.id)
--- @field ui                 LvimSpace.UIState? UI window/buffer handles

--- Handles to the floating windows created by the UI layer.
--- @class LvimSpace.UIState
--- @field content      LvimSpace.UIWindow   Main content panel
--- @field status_line  LvimSpace.UIWindow   Status / info bar
--- @field prompt_window { win: integer }    Prompt label window (no dedicated buffer)
--- @field input_window  LvimSpace.UIWindow  User text-input window

--- A (buffer, window) pair for a managed floating window.
--- @class LvimSpace.UIWindow
--- @field win integer  Neovim window handle
--- @field buf integer  Neovim buffer handle

--------------------------------------------------------------------------------
-- SESSION CACHE (internal to core/session.lua)
--------------------------------------------------------------------------------

--- Internal cache table used by core/session.lua.
--- @class LvimSpace.SessionCache
--- @field last_save          integer          uv.now() value at last successful save
--- @field current_tab_id     integer?         Tab ID currently restored in the editor
--- @field is_restoring       boolean          Guard flag – true while restore is running
--- @field pending_save       integer?         Timer handle for the debounced save
--- @field cleanup_timer      integer?         Timer handle for periodic cache cleanup
--- @field buffer_cache       table<string, integer>  file_path → bufnr (weak values)
--- @field buffer_type_cache  table<integer, LvimSpace.BufferClassification>  bufnr → classification (weak kv)
--- @field path_validation_cache table<string, boolean>  file_path → is_valid (weak keys)
--- @field cache_stats        LvimSpace.CacheStats

--- Hit/miss/eviction counters for the session cache.
--- @class LvimSpace.CacheStats
--- @field hits      integer  Number of cache hits
--- @field misses    integer  Number of cache misses
--- @field evictions integer  Number of full cache evictions

--- Return value of session.get_cache_stats().
--- @class LvimSpace.CacheStatsResult
--- @field buffer_cache_entries integer   Current entries in buffer_cache
--- @field type_cache_entries   integer   Current entries in buffer_type_cache
--- @field path_cache_entries   integer   Current entries in path_validation_cache
--- @field is_restoring         boolean   Whether a restore is in progress
--- @field current_tab_id       integer?  Currently restored tab
--- @field last_save            integer   uv.now() at last save
--- @field cache_hits           integer   Total cache hits
--- @field cache_misses         integer   Total cache misses
--- @field cache_evictions      integer   Total full evictions
--- @field hit_ratio            number    hits / (hits + misses), range [0, 1]

--- Return value of session.get_session_info().
--- @class LvimSpace.SessionInfo
--- @field tab_id       integer  The tab whose data was queried
--- @field buffer_count integer  Number of buffers in saved data
--- @field window_count integer  Number of windows in saved data
--- @field timestamp    integer  Unix timestamp of the saved data

--------------------------------------------------------------------------------
-- UI / ENTITY SYSTEM
--------------------------------------------------------------------------------

--- Descriptor for a managed entity type used by ui/common.lua.
--- @class LvimSpace.EntityType
--- @field name                        string   Logical name ("project", "workspace", "tab", "file", "search")
--- @field table                       string   SQLite table name
--- @field state_id                    string?  Key in State that holds the active entity ID
--- @field empty_message               string   Lang key shown when list is empty
--- @field info_empty                  string   Lang key for info bar when empty
--- @field info                        string   Lang key for info bar
--- @field title                       string   Panel title lang key
--- @field min_name_len                integer  Minimum allowed name length
--- @field name_len_error              string   Lang key for name-too-short error
--- @field name_exist_error            string   Lang key for duplicate-name error
--- @field add_failed                  string   Lang key for add-failure notice
--- @field added_success               string   Lang key for add-success notice
--- @field rename_failed               string   Lang key for rename-failure notice
--- @field renamed_success             string   Lang key for rename-success notice
--- @field delete_confirm              string   Lang key for delete confirmation prompt
--- @field delete_failed               string   Lang key for delete-failure notice
--- @field deleted_success             string   Lang key for delete-success notice
--- @field not_active                  string   Lang key when no entity is active
--- @field error_message               string   Lang key for generic error
--- @field switched_to                 string   Lang key after successful switch
--- @field switch_failed               string   Lang key when switch fails
--- @field reorder_invalid_order_error string   Lang key for invalid new order
--- @field reorder_failed_error        string   Lang key for reorder failure
--- @field reorder_missing_params_error string  Lang key for missing reorder params
--- @field ui_cache_error              string   Lang key for UI cache errors
--- @field already_at_top              string   Lang key when entity is already first
--- @field already_at_bottom           string   Lang key when entity is already last

--- Options table accepted by ui.create_window().
--- @class LvimSpace.WindowConfig
--- @field relative   string    Always "editor" for plugin windows
--- @field row        integer   Top-left row (screen coordinates)
--- @field col        integer   Top-left column (screen coordinates)
--- @field width      integer   Window width in columns
--- @field height     integer   Window height in rows
--- @field style      string    Usually "minimal"
--- @field border     string|string[]  Border definition passed to nvim_open_win
--- @field zindex     integer?  Z-stack order
--- @field focusable  boolean?  Whether the window can receive focus
--- @field title      string?   Window title string
--- @field title_pos  string?   "left" | "center" | "right"

--------------------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------------------

--- @class LvimSpace.BorderSideConfig
--- @field left  boolean  Show left border segment
--- @field right boolean  Show right border segment

--- @class LvimSpace.BorderPromptConfig : LvimSpace.BorderSideConfig
--- @field separate string  Separator character between prompt label and input

--- @class LvimSpace.BorderConfig
--- @field sign   string                         Character used as padding/sign
--- @field main   LvimSpace.BorderSideConfig     Main content panel borders
--- @field info   LvimSpace.BorderSideConfig     Info/status bar borders
--- @field prompt LvimSpace.BorderPromptConfig   Prompt label borders
--- @field input  LvimSpace.BorderSideConfig     Input field borders

--- @class LvimSpace.IconsConfig
--- @field error            string  Icon for error messages
--- @field warn             string  Icon for warning messages
--- @field info             string  Icon for info messages
--- @field project          string  Icon for inactive project
--- @field project_active   string  Icon for active project
--- @field workspace        string  Icon for inactive workspace
--- @field workspace_active string  Icon for active workspace
--- @field tab              string  Icon for inactive tab
--- @field tab_active       string  Icon for active tab
--- @field file             string  Icon for inactive file
--- @field file_active      string  Icon for active file
--- @field empty            string  Icon shown when a list is empty
--- @field pre              string  Prefix icon shown before the active item

--- @class LvimSpace.HighlightConfig
--- @field bg                 string  Background hex colour for the panel
--- @field bg_line            string  Background hex colour for the selected line
--- @field fg                 string  Foreground hex colour for regular items
--- @field fg_line            string  Foreground hex colour for the selected line
--- @field bg_fuzzy           string  Background hex colour for the fuzzy-search panel
--- @field fg_fuzzy_primary   string  Foreground hex colour for primary fuzzy matches
--- @field fg_fuzzy_secondary string  Foreground hex colour for secondary fuzzy matches

--- @class LvimSpace.UIConfig
--- @field border    LvimSpace.BorderConfig     Border configuration
--- @field icons     LvimSpace.IconsConfig      Icon strings
--- @field highlight LvimSpace.HighlightConfig  Highlight colours

--- @class LvimSpace.GlobalKeymappings
--- @field projects   string  Key to open the projects panel
--- @field workspaces string  Key to open the workspaces panel
--- @field tabs       string  Key to open the tabs panel
--- @field files      string  Key to open the files panel
--- @field search     string  Key to open the search panel

--- @class LvimSpace.ActionKeymappings
--- @field add       string  Key to add a new entity
--- @field delete    string  Key to delete the entity under cursor
--- @field rename    string  Key to rename the entity under cursor
--- @field switch    string  Key to switch to the entity under cursor
--- @field enter     string  Key to open/enter the entity under cursor
--- @field split_v   string  Key to open file in a vertical split
--- @field split_h   string  Key to open file in a horizontal split
--- @field move_down string  Key to move entity down in the list
--- @field move_up   string  Key to move entity up in the list

--- @class LvimSpace.KeymappingsConfig
--- @field main   string                       Main toggle keybinding
--- @field global LvimSpace.GlobalKeymappings  Panel-navigation keys
--- @field action LvimSpace.ActionKeymappings  In-panel action keys

--- @class LvimSpace.DisableCategoriesConfig
--- @field lowercase_letters boolean  Disable all a-z keys inside plugin windows
--- @field uppercase_letters boolean  Disable all A-Z keys inside plugin windows
--- @field digits            boolean  Disable all 0-9 keys inside plugin windows

--- @class LvimSpace.KeyControlConfig
--- @field allowed             string[]                          Keys that pass through even if a category is disabled
--- @field explicitly_disabled string[]                          Keys that are always blocked inside plugin windows
--- @field disable_categories  LvimSpace.DisableCategoriesConfig Category-level key blocking

--- Root configuration table (lua/lvim-space/config.lua).
--- @class LvimSpace.Config
--- @field save                    string                     Absolute path to the data directory
--- @field lang                    string                     Language code (e.g. "en")
--- @field notify                  boolean                    Enable vim.notify messages
--- @field filetype                string                     Filetype set on plugin buffers
--- @field title                   string                     Panel window title text
--- @field title_position          string                     Title alignment: "left" | "center" | "right"
--- @field spacing                 integer                    Padding spaces in the status line (config.ui.spacing)
--- @field max_height              integer                    Maximum panel height in rows
--- @field autosave                boolean                    Automatically save session on buffer events
--- @field autorestore             boolean                    Automatically restore session when cwd matches a project
--- @field open_panel_on_add_file  boolean                    Open file panel after adding a new file
--- @field search                  string                     Shell command used for the file-search panel (fd / find)
--- @field ui                      LvimSpace.UIConfig         UI appearance settings
--- @field keymappings             LvimSpace.KeymappingsConfig Keybinding configuration
--- @field key_control             LvimSpace.KeyControlConfig  Key-blocking rules for plugin windows

--------------------------------------------------------------------------------
-- DATABASE LAYER OPTIONS
--------------------------------------------------------------------------------

--- Options accepted by db.find() (passed to sqlite.tbl:get()).
--- @class LvimSpace.DbFindOptions
--- @field sort_by       string?   Column name to sort by
--- @field sort_order_dir string?  "ASC" | "DESC"
--- @field order_by      table?   Raw order_by clause forwarded to sqlite.lua
--- @field where         table?   Conditions (populated internally from the conditions arg)

return {}
