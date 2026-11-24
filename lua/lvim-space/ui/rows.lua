-- lvim-space.ui.rows: THE one row renderer for every lvim-space list — projects, workspaces, tabs, files and
-- the search results all go through here, so they read exactly like a lvim-picker list.
--
-- A row is `<space><icon><text><space>`. The ICON is the entity glyph (`config.ui.icons.<type>[_active]`) for
-- every entity EXCEPT a file, which gets a real FILETYPE devicon in its own colour (the picker's language) —
-- resolved through the shared `lvim-utils.icons` provider, so it follows the same icon provider / colour mode
-- as every other lvim-tech list. A file's ACTIVE state can no longer live in the glyph (the glyph is now the
-- filetype's), so it moves to the row TEXT: the active row is painted with the accent (`hl.active`).
--
-- The row LOOK is not just the text: the picker stripes its rows odd/even and paints the SELECTED row with a
-- stronger tint of the same accent instead of relying on `cursorline` (the cursor is hidden in these panels).
-- `M.hls` builds those highlight ops in the CHASSIS format, and the list PROVIDER returns them from its
-- `render` — so the surface applies them on every render it does. They must not be painted on the side: a
-- relayout rewrites the panel's lines and wipes any foreign extmark.
--
---@module "lvim-space.ui.rows"

local config = require("lvim-space.config")
local iconlib = require("lvim-utils.icons")

local M = {}

--- The row style config, with the defaults applied. Kept as a function (not a module-level local) so a
--- runtime `setup()` merge — or a theme swap that renames a group — is picked up on the next paint.
---@return { stripes: boolean, devicons: boolean, hl: table<string, string> }
local function rowcfg()
    local ui = config.ui or {}
    local r = ui.rows or {}
    local h = r.hl or {}
    return {
        stripes = r.stripes ~= false,
        devicons = ui.devicons ~= false,
        hl = {
            -- The picker's OWN list groups by default, so lvim-space and the pickers stay one look under any
            -- theme; override any of them in `config.ui.rows.hl` to steer lvim-space alone.
            odd = h.odd or "LvimUiMsgAreaRowOdd",
            even = h.even or "LvimUiMsgAreaRowEven",
            sel_odd = h.sel_odd or "LvimUiMsgAreaSelOdd",
            sel_even = h.sel_even or "LvimUiMsgAreaSelEven",
            active = h.active or "LvimSpaceActiveRow",
            project_name = h.project_name or "LvimSpaceProjectName",
            project_path = h.project_path or "LvimSpaceProjectPath",
        },
    }
end

--- A UI glyph (`"<glyph>"` + optional blanks) as lvim-icons shows it: in "material" mode its 2-cell image + the
--- image's group (its fg IS the image id, so it must be painted over the row's own fg); otherwise the glyph
--- unchanged and nil. `drop_blank`: the image is one cell wider than the glyph, so one blank after it is dropped
--- where the glyph sits in a column that has to stay aligned.
---@param icon string
---@param hl string|nil       the group whose colour the image takes (nil = Normal)
---@param drop_blank boolean|nil
---@return string text, string|nil img_hl
function M.image_cells(icon, hl, drop_blank)
    local t, h, img = iconlib.ui_text(icon, hl)
    if not img then
        return icon, nil
    end
    if drop_blank and t:sub(-1) == " " then
        t = t:sub(1, -2)
    end
    return t, h
end

-- ── project icons ─────────────────────────────────────────────────────────────────────────────────────────
-- A project row leads with the icon of what the project IS: its main language (read from the files that name it —
-- `Cargo.toml` is Rust — else from the files that are most of it), else the icon of its folder (by the folder's name),
-- and an `ssh://` project with the icon of a server. All of them Material icons through the shared icon provider.

--- Files that name a language, the first that is there wins; the value is a file name the provider knows the icon of.
local LANG_MARKERS = {
    { "Cargo.toml", "main.rs" },
    { "go.mod", "main.go" },
    { "deno.json", "main.ts" },
    { "tsconfig.json", "main.ts" },
    { "package.json", "main.js" },
    { "pyproject.toml", "main.py" },
    { "requirements.txt", "main.py" },
    { "setup.py", "main.py" },
    { "pubspec.yaml", "main.dart" },
    { "pom.xml", "Main.java" },
    { "build.gradle", "Main.java" },
    { "build.gradle.kts", "Main.kt" },
    { "composer.json", "index.php" },
    { "Gemfile", "main.rb" },
    { "mix.exs", "main.ex" },
    { "build.zig", "main.zig" },
    { "Package.swift", "main.swift" },
    { "flake.nix", "flake.nix" },
    { "CMakeLists.txt", "main.cpp" },
    { "init.lua", "init.lua" },
    { ".luarc.json", "init.lua" },
    { "stylua.toml", "init.lua" },
    { "lua", "init.lua" },
}

--- Extensions that count as "the language" when no marker says it (the most frequent one of the top two levels wins).
local LANG_EXT = {
    rs = true, go = true, ts = true, tsx = true, js = true, jsx = true, py = true, lua = true, dart = true, java = true,
    kt = true, php = true, rb = true, ex = true, zig = true, swift = true, c = true, cpp = true, h = true, cs = true,
    hs = true, nix = true, sh = true, vue = true, svelte = true, scala = true, clj = true, ml = true, sql = true,
}

local SKIP_DIRS = { [".git"] = true, node_modules = true, target = true, build = true, dist = true, vendor = true, [".venv"] = true }

---@type table<string, { name: string, opts: table|nil }>
local project_icon_cache = {}

--- What a project's icon is made of: a file name (its language) or a folder (by name), for the provider.
---@param path string
---@return { name: string, opts: table|nil }
local function project_icon_spec(path)
    if not path or path == "" then
        return { name = "folder", opts = { kind = "directory" } }
    end
    if path:match("^ssh://") then
        return { name = "server", opts = { kind = "directory" } }
    end
    local hit = project_icon_cache[path]
    if hit then
        return hit
    end
    local spec
    local uv = vim.uv or vim.loop
    for _, m in ipairs(LANG_MARKERS) do
        if uv.fs_stat(path .. "/" .. m[1]) then
            spec = { name = m[2] }
            break
        end
    end
    if not spec then
        -- no marker in the root: a folder of projects (a monorepo) — the languages of the folders under it; two or more
        -- different ones is a mixed project, one is its language
        local langs, n = {}, 0
        local h = uv.fs_scandir(path)
        while h and n < 80 do
            local name, kind = uv.fs_scandir_next(h)
            if not name then
                break
            end
            if kind == "directory" and name:sub(1, 1) ~= "." and not SKIP_DIRS[name] then
                n = n + 1
                for _, m in ipairs(LANG_MARKERS) do
                    if m[1] ~= "lua" and uv.fs_stat(path .. "/" .. name .. "/" .. m[1]) then
                        langs[m[2]] = true
                        break
                    end
                end
            end
        end
        local found = vim.tbl_keys(langs)
        if #found >= 2 then
            spec = { name = "stack", opts = { kind = "directory" } }
        elseif #found == 1 then
            spec = { name = found[1] }
        end
    end
    if not spec then
        -- the language by what most of the files are (two levels, a bounded count)
        local count, budget = {}, 400
        local function scan(dir, depth)
            local h = uv.fs_scandir(dir)
            while h and budget > 0 do
                local name, kind = uv.fs_scandir_next(h)
                if not name then
                    break
                end
                budget = budget - 1
                if kind == "file" then
                    local ext = name:match("%.([%w]+)$")
                    if ext and LANG_EXT[ext] then
                        count[ext] = (count[ext] or 0) + 1
                    end
                elseif kind == "directory" and depth < 2 and not SKIP_DIRS[name] and name:sub(1, 1) ~= "." then
                    scan(dir .. "/" .. name, depth + 1)
                end
            end
        end
        scan(path, 1)
        local best, best_n, second_n = nil, 1, 0
        for ext, n in pairs(count) do
            if n > best_n or (n == best_n and best and ext < best) then
                if best then
                    second_n = math.max(second_n, best_n)
                end
                best, best_n = ext, n
            else
                second_n = math.max(second_n, n)
            end
        end
        if best and best_n >= 3 and second_n >= best_n * 0.6 then
            -- two languages of about the same weight: a mix
            spec = { name = "stack", opts = { kind = "directory" } }
        elseif best then
            spec = { name = "main." .. best }
        end
    end
    -- no language: the folder, by its name (`docs`, `tests`, `src`, … have their own)
    spec = spec or { name = path:match("([^/]+)/*$") or "folder", opts = { kind = "directory" } }
    project_icon_cache[path] = spec
    return spec
end

--- The row icon of a project (see above), or nil to fall back to the entity glyph.
---@param path string|nil
---@return string|nil glyph, string|nil hl
local function project_icon(path)
    local spec = project_icon_spec(path)
    local opts = { provider = (config.ui or {}).icon_provider, color_mode = (config.ui or {}).icon_color_mode }
    for k, v in pairs(spec.opts or {}) do
        opts[k] = v
    end
    local ok, r = pcall(iconlib.get, spec.name, opts)
    if ok and r and r.glyph and r.glyph ~= "" then
        return r.glyph .. " ", r.hl
    end
    return nil
end

--- The icon for one row: a filetype DEVICON (with its own highlight) for a file, else the entity glyph.
--- Returns the glyph plus the highlight to paint it with (nil = inherit the row's stripe colour).
---@param type_name string   entity type ("project" | "workspace" | "tab" | "file")
---@param active boolean     is this the active entity
---@param path string|nil    the file path (file rows only — the devicon is resolved from it)
---@return string glyph, string|nil hl
function M.icon(type_name, active, path)
    local common = require("lvim-space.ui.common") -- required here: common requires this module back
    if type_name == "file" and rowcfg().devicons and path and path ~= "" then
        local r = iconlib.get(path, {
            provider = (config.ui or {}).icon_provider,
            color_mode = (config.ui or {}).icon_color_mode,
        })
        if r and r.glyph and r.glyph ~= "" then
            return r.glyph .. " ", r.hl
        end
    end
    -- a workspace is a desktop, a tab is a layout of windows: the Material folders of those names
    local kind_icon = ({ workspace = "desktop", tab = "layout" })[type_name]
    if kind_icon and rowcfg().devicons then
        local ok, r = pcall(iconlib.get, kind_icon, {
            provider = (config.ui or {}).icon_provider,
            color_mode = (config.ui or {}).icon_color_mode,
            kind = "directory",
        })
        if ok and r and r.glyph and r.glyph ~= "" then
            return r.glyph .. " ", r.hl
        end
    end
    if type_name == "project" and rowcfg().devicons and path and path ~= "" then
        local g, h = project_icon(path)
        if g then
            return g, h
        end
    end
    local glyph = common.get_entity_icon(type_name, active, false)
    if type_name ~= "file" then
        -- the entity glyph is a UI icon: an image in "material" mode, in the row's colour
        local cfg = rowcfg()
        local t, img_hl = M.image_cells(glyph, active and cfg.hl.active or cfg.hl.odd, true)
        if img_hl then
            return t, img_hl
        end
    end
    return glyph, nil
end

--- Build ONE list row + the span its icon occupies (byte columns, for the colour extmark).
---@param text string        the row's text (already formatted by the panel)
---@param type_name string   entity type
---@param active boolean     is this the active entity
---@param path string|nil    file path (file rows)
---@return string line, { c0: integer, c1: integer, hl: string|nil } span
function M.line(text, type_name, active, path)
    local glyph, ghl = M.icon(type_name, active, path)
    -- A REMOTE project's mark leads its text (`projects.format_project`): a UI icon too, so in "material" mode
    -- it becomes an image with its own span. Done here, not in the formatter, because the formatter's text
    -- also feeds the filter picker, which must keep the plain glyph.
    local mark_span
    if type_name == "project" then
        local mark = ((config.ui or {}).icons or {}).project_remote or ""
        if mark ~= "" and text:sub(1, #mark) == mark and path and path:match("^ssh://") and rowcfg().devicons then
            -- the server icon leads the row now: the text mark would say it twice
            text = text:sub(#mark + 1)
        elseif mark ~= "" and text:sub(1, #mark) == mark then
            local cfg = rowcfg()
            local t, img_hl = M.image_cells(mark, active and cfg.hl.active or cfg.hl.odd)
            if img_hl then
                text = t .. text:sub(#mark + 1)
                -- byte span after the leading air + the row glyph (blanks under it only take the bg)
                mark_span = { 1 + #glyph, 1 + #glyph + #t, img_hl }
            end
        end
    end
    -- 1 space of breathing room at BOTH ends of every row: the leading space keeps the glyph off column 0.
    local lead = 1
    local line = " " .. glyph .. text .. " "
    -- `line_bytes` bounds the ACTIVE accent to the row's own text (see M.hls): a full-row span would take the
    -- stripe's background with it.
    -- a project row: the name and the `[path]` after it get their own colours (the byte spans in the line)
    local name_span, path_span
    if type_name == "project" then
        local at = text:find(" %[[^%[]*%]$")
        if at then
            local base = lead + #glyph
            name_span = { base, base + at - 1 }
            path_span = { base + at - 1, base + #text }
        end
    end
    return line,
        {
            c0 = lead,
            c1 = lead + #glyph,
            hl = ghl,
            active = active,
            line_bytes = #line,
            mark = mark_span,
            name = name_span,
            path = path_span,
        }
end

--- The highlight ops for `n` rows, in the CHASSIS format (`{ row0, col0, col_end, group, priority }`, with
--- `col_end = -1` meaning a full-row tint that reaches the window edge): odd/even stripes, the selected row's
--- stronger tint, the active entity's accent, and each icon in its own filetype colour.
---
--- This is the SURFACE's own mechanism (the list provider returns these from `render`, and `surface.paint`
--- applies them) — deliberately not extmarks painted on the side: every relayout re-renders the panel and
--- rewrites its lines, which wipes any foreign extmark. That is exactly how the stripes vanished the moment the
--- preview started re-fitting the frame.
---@param n integer  row count
---@param spans table[]|nil  per-row `{ c0, c1, hl, active }` from `M.line` (index = 1-based row)
---@param sel integer|nil  the 1-based selected row (the cursor row)
---@return table[]
function M.hls(n, spans, sel)
    local cfg = rowcfg()
    local out = {}
    for i = 1, n do
        local odd = (i % 2) == 1
        local sp = spans and spans[i] or nil
        if cfg.stripes then
            local group = (i == sel) and (odd and cfg.hl.sel_odd or cfg.hl.sel_even)
                or (odd and cfg.hl.odd or cfg.hl.even)
            out[#out + 1] = { i - 1, 0, -1, group, (i == sel) and 200 or 100 }
        end
        if sp and sp.active then
            -- The ACTIVE entity (the loaded file / current tab …). With a devicon in the glyph slot the icon can
            -- no longer carry this, so the row TEXT does. TEXT — not the row: a full-row span (`col_end = -1`,
            -- hl_eol) painted with this fg-only group wiped the row's own stripe background, so an active row
            -- that happened to land on an EVEN (yellow) stripe turned blue and the alternation read as three
            -- blue rows in a row. Bounded to the line's own columns, the accent colours the text and the stripe
            -- underneath survives.
            out[#out + 1] = { i - 1, 0, sp.line_bytes or -1, cfg.hl.active, 210 }
        end
        if sp and sp.hl and sp.c1 > sp.c0 then
            out[#out + 1] = { i - 1, sp.c0, sp.c1, sp.hl, 220 }
        end
        if sp and sp.name then
            out[#out + 1] = { i - 1, sp.name[1], sp.name[2], cfg.hl.project_name, 215 }
        end
        if sp and sp.path then
            out[#out + 1] = { i - 1, sp.path[1], sp.path[2], cfg.hl.project_path, 215 }
        end
        if sp and sp.mark then
            -- an image mark inside the text (a remote project's): its own group above the stripe / accent
            out[#out + 1] = { i - 1, sp.mark[1], sp.mark[2], sp.mark[3], 220 }
        end
    end
    return out
end

return M
