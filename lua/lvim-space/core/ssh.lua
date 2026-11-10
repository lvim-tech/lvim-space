-- lvim-space.core.ssh: remote (SSH) projects on top of Neovim's `:connect ssh://` (|remote-ssh|).
--
-- A remote project is an ordinary project row whose `path` is `ssh://[user@]host[:port]/abs/path`. Neovim's
-- `:connect` takes no path, so opening one is a hand-off in two halves:
--
--   LOCAL  (`M.open`)          writes "which project was asked for" onto the server, then runs
--                              `:connect ssh://[user@]host[:port]`.
--   REMOTE (`M.apply_request`) the Neovim started there by remote-ssh reads that request during lvim-space's
--                              one-time initialisation, resolves it against ITS OWN database, changes into
--                              the directory, and deletes the request.
--
-- Every process this module starts goes through two seams — `M.run` (non-interactive, `vim.system` with an
-- argument LIST) and `M.terminal` (the interactive password prompt) — so the tests replace ssh wholesale and
-- nothing here ever builds a shell string. The project path never reaches the remote shell either: the
-- request travels on STDIN of a constant remote command, so there is nothing to quote and nothing to inject.
--
-- This module deliberately depends on neither the database, the session engine nor the UI: the callers hand
-- in what it needs (see `M.apply_request`), which keeps it loadable — and testable — without sqlite.
--
---@module "lvim-space.core.ssh"

local M = {}

--- The ssh executable. Tests never reach it (they replace `M.run` / `M.terminal`).
---@type string
M.exe = "ssh"

--- Where the request lives on the server, RELATIVE TO THE REMOTE `$HOME` (ssh starts the remote command
--- there). It sits inside the data directory remote-ssh itself owns and keeps across sessions
--- (`remote_data_dir = '.local/share/nvim-remote'` in `vim/net/_ssh.lua`). The remote half reads the very
--- same literal location rather than `stdpath("data")`, so writer and reader agree even when the server sets
--- `$XDG_DATA_HOME`.
---@type string
M.REMOTE_DIR = ".local/share/nvim-remote/lvim-space"

---@type string
M.REQUEST_FILE = "request.json"

--- Exit status ssh itself uses for "could not connect / could not authenticate" (anything else is the remote
--- command's own status).
---@type integer
M.SSH_FAILURE = 255

---@class LvimSpaceSshTarget
---@field user string|nil  Login name, when the URI names one.
---@field host string      Host name or IPv4 address.
---@field port integer|nil Port, when the URI names one.
---@field path string      Absolute, normalised path on the server (no trailing slash, except `/`).

---@class LvimSpaceSshResult
---@field code integer    Exit status (-1 when the process could not be started at all).
---@field stdout string|nil
---@field stderr string|nil

-- ---------------------------------------------------------------------------
-- URI
-- ---------------------------------------------------------------------------

--- Whether a stored project path denotes a remote project.
---@param path any
---@return boolean
function M.is_remote(path)
    return type(path) == "string" and path:match("^%s*ssh://") ~= nil
end

--- Parse `ssh://[user@]host[:port]/abs/path`. Syntax only — nothing is contacted.
---
--- User and host are restricted to plain name characters and may not start with `-`: they end up as ssh
--- arguments, and although every command also passes `--` first, a value that looks like an option has no
--- business being stored. Credentials in the URI (`user:secret@`) are refused by the same rule.
---@param uri any
---@return LvimSpaceSshTarget|nil target
---@return string|nil err_code One of the `SSH_*` language keys.
function M.parse(uri)
    if type(uri) ~= "string" then
        return nil, "SSH_URI_INVALID"
    end
    local rest = vim.trim(uri):match("^ssh://(.*)$")
    if not rest then
        return nil, "SSH_URI_INVALID"
    end
    local authority, path = rest:match("^([^/]*)(.*)$")

    local user, hostport = authority:match("^(.*)@([^@]*)$")
    if not user then
        hostport = authority
    elseif not user:match("^[%w_%.][%w_%.%-]*$") then
        return nil, "SSH_USER_INVALID"
    end

    local host, port = hostport, nil
    local h, p = hostport:match("^([^:]*):(.*)$")
    if h then
        host = h
        local n = p:match("^%d+$") and tonumber(p) or nil
        if not n or n < 1 or n > 65535 then
            return nil, "SSH_PORT_INVALID"
        end
        port = n
    end
    if host == "" then
        return nil, "SSH_HOST_REQUIRED"
    end
    if not host:match("^[%w][%w_%.%-]*$") then
        return nil, "SSH_HOST_INVALID"
    end

    -- The path must be absolute and already normal: `~`, `.` and `..` would each mean something only the
    -- remote shell or kernel can resolve, and the remote half matches the project by its literal path.
    if path == "" or path:find("%c") then
        return nil, "SSH_PATH_NOT_ABSOLUTE"
    end
    path = path:gsub("/+", "/")
    if #path > 1 then
        path = path:gsub("/$", "")
    end
    for segment in path:gmatch("[^/]+") do
        if segment == "." or segment == ".." or segment:sub(1, 1) == "~" then
            return nil, "SSH_PATH_NOT_ABSOLUTE"
        end
    end

    return { user = user, host = host, port = port, path = path }, nil
end

--- `[user@]host` — the ssh destination.
---@param t LvimSpaceSshTarget
---@return string
function M.target(t)
    return t.user and (t.user .. "@" .. t.host) or t.host
end

--- `ssh://[user@]host[:port]` — what `:connect` takes (it has no path component).
---@param t LvimSpaceSshTarget
---@return string
function M.address(t)
    return "ssh://" .. M.target(t) .. (t.port and (":" .. t.port) or "")
end

--- The canonical stored form, `ssh://[user@]host[:port]/abs/path`.
---@param t LvimSpaceSshTarget
---@return string
function M.format(t)
    return M.address(t) .. t.path
end

--- Validate a remote project path typed by the user: syntax, then uniqueness.
---@param input string
---@param exists (fun(canonical: string): any)|nil Truthy when a project with that path is already stored.
---@return string|nil canonical The canonical URI to store, or nil on failure.
---@return string|nil err_code
function M.validate(input, exists)
    local t, err = M.parse(input)
    if not t then
        return nil, err
    end
    local canonical = M.format(t)
    if exists and exists(canonical) then
        return nil, "PROJECT_PATH_EXIST"
    end
    return canonical, nil
end

--- A default project name for a remote path: its last component, or the host for `/`.
---@param uri string
---@return string
function M.default_name(uri)
    local t = M.parse(uri)
    if not t then
        return ""
    end
    return t.path:match("([^/]+)$") or t.host
end

-- ---------------------------------------------------------------------------
-- Compatibility with Neovim's remote-ssh
-- ---------------------------------------------------------------------------

--- The ControlPath Neovim's remote-ssh multiplexes over. It MUST be computed exactly as `get_ssh_cmd()` in
--- `vim/net/_ssh.lua` does, so our commands and `:connect` share one master connection (a password typed
--- for ours is then never asked for again). That module is private and is not called; the spec reads its
--- source from `$VIMRUNTIME` and fails if this shape is no longer there.
---@return string
function M.control_path()
    return vim.fs.joinpath(vim.fn.stdpath("cache"), "ssh", "mux_%C")
end

--- Whether this Neovim has `:connect ssh://` at all.
---@return boolean
function M.supported()
    return vim.fn.exists(":connect") == 2 and #vim.api.nvim_get_runtime_file("lua/vim/net/_ssh.lua", false) > 0
end

-- ---------------------------------------------------------------------------
-- Argument lists (pure)
-- ---------------------------------------------------------------------------

--- `[-p port] -- target`, the tail every command shares (same order as Neovim's own).
---@param t LvimSpaceSshTarget
---@return string[]
local function dest(t)
    local out = {}
    if t.port then
        out[#out + 1] = "-p"
        out[#out + 1] = tostring(t.port)
    end
    out[#out + 1] = "--"
    out[#out + 1] = M.target(t)
    return out
end

--- The options Neovim's remote-ssh runs every command with: never prompt, share the master.
---@return string[]
local function batch_options()
    return {
        "-T",
        "-o",
        "BatchMode=yes",
        "-o",
        "ControlMaster=auto",
        "-o",
        "ControlPath=" .. M.control_path(),
        "-o",
        "ControlPersist=10m",
        "-o",
        "RemoteCommand=none",
    }
end

--- `ssh -O check`: is a master connection for this target alive on the shared ControlPath?
---@param t LvimSpaceSshTarget
---@return string[]
function M.check_argv(t)
    return vim.list_extend({ M.exe, "-O", "check", "-o", "ControlPath=" .. M.control_path() }, dest(t))
end

--- The command that stores the request on the server. The remote command is a CONSTANT (the payload arrives
--- on stdin), written through a temporary name so the remote half never reads a half-written file.
---@param t LvimSpaceSshTarget
---@return string[]
function M.write_argv(t)
    local file = M.REMOTE_DIR .. "/" .. M.REQUEST_FILE
    local argv = vim.list_extend({ M.exe }, batch_options())
    vim.list_extend(argv, dest(t))
    argv[#argv + 1] = ("mkdir -p %s && cat > %s.tmp && mv %s.tmp %s"):format(M.REMOTE_DIR, file, file, file)
    return argv
end

--- The command that withdraws a request (used when `:connect` itself refuses to start).
---@param t LvimSpaceSshTarget
---@return string[]
function M.clear_argv(t)
    local argv = vim.list_extend({ M.exe }, batch_options())
    vim.list_extend(argv, dest(t))
    argv[#argv + 1] = ("rm -f %s/%s"):format(M.REMOTE_DIR, M.REQUEST_FILE)
    return argv
end

-- ---------------------------------------------------------------------------
-- Preflight: what the server offers remote-ssh, checked before `:connect`
-- ---------------------------------------------------------------------------

--- The remote command that runs the probe. `sh -s` reads the script from stdin, so the command is the same
--- under any login shell (bash, zsh, fish, csh); the trailing word only names the call.
---@type string
M.PROBE_CMD = "sh -s lvim-space-probe"

--- The probe. Prints `key=value` lines and changes nothing (the temporary directory it makes is removed).
--- Every fact it reports is one remote-ssh, or installing tools there, depends on: the platform its
--- auto-install supports, a writable `/tmp` (where it puts the socket), the tools it installs with, an
--- already installed release, the runtime directory a newer remote Nvim listens in, whether the remote
--- config has lvim-space, and the runtimes the plugin manager there installs language tools WITH — `node` /
--- `npm` and `python3` (with `venv`). When those are not on PATH it lists installations the host has elsewhere
--- (`<version> <bin dir>` per line): CloudLinux's alt-nodejs / alt-python, nvm, mise.
---@type string
M.PROBE_SCRIPT = [[
echo "os=$(uname -s)"
echo "arch=$(uname -m)"
echo "shell=${SHELL##*/}"
if [ -n "$XDG_RUNTIME_DIR" ] && [ ! -d "$XDG_RUNTIME_DIR" ]; then echo "runtime_dir_missing=$XDG_RUNTIME_DIR"; fi
d=$(mktemp -d /tmp/lvim-space.XXXXXX 2>/dev/null) && rmdir "$d" && echo "tmp_ok=1"
for c in curl tar sha256sum shasum nvim node npm python3; do command -v "$c" >/dev/null 2>&1 && echo "has_$c=1"; done
if command -v python3 >/dev/null 2>&1 && python3 -c 'import venv, ensurepip' >/dev/null 2>&1; then echo "has_venv=1"; fi
for n in "$HOME"/.local/share/nvim-remote/releases/*/bin/nvim; do [ -x "$n" ] && echo "installed=1" && break; done
p=
for d in "$HOME"/.local/share/nvim-remote/site/pack/*/*/lvim-space; do [ -d "$d" ] && p=$d && break; done
if [ -z "$p" ]; then echo "plugin=none"; elif [ -f "$p/lua/lvim-space/core/ssh.lua" ]; then echo "plugin=ssh"; else echo "plugin=old"; fi
for d in /opt/alt/alt-nodejs*/root/usr/bin "$HOME"/.nvm/versions/node/*/bin "$HOME"/.local/share/mise/installs/node/*/bin; do
  if [ -x "$d/node" ] && [ -x "$d/npm" ]; then echo "node_candidate=$("$d/node" --version 2>/dev/null) $d"; fi
done
for d in /opt/alt/python3*/bin "$HOME"/.local/share/mise/installs/python/*/bin; do
  if [ -x "$d/python3" ] && "$d/python3" -c 'import venv, ensurepip' >/dev/null 2>&1; then
    echo "python_candidate=$("$d/python3" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null) $d"
  fi
done
exit 0
]]

--- The startup file each login shell reads for a NON-interactive ssh command, which is how remote-ssh's
--- script is run. Only these two can be changed automatically.
---@type table<string, string>
M.RC_FILES = { bash = ".bashrc", zsh = ".zshenv" }

--- The marker of the block lvim-space keeps in that file, so it is found again (and can be removed by hand).
---@type string
M.ENV_MARKER = "# >>> lvim-space: remote-ssh environment >>>"

--- The marker an earlier version used for a block holding only the runtime-dir line. Its lines are kept and
--- the block is folded into the current one.
---@type string
M.FIX_MARKER = "# >>> lvim-space: remote-ssh runtime dir >>>"

--- The fix. Run as `sh -s lvim-space-fix <file>` (`$2` is the startup file, relative to `$HOME`) with the
--- block's lines on stdin AFTER the script: the script is one function, called on its last line, so the
--- shell has read exactly the script when `cat` takes the rest — the lines arrive as data, never as code
--- on the command line. Every earlier lvim-space block is taken out of the file; their lines and the new
--- ones, without comments and duplicates, become one block at the very TOP, before any early `return` for
--- non-interactive shells further down. Written through `cat >`, so the file keeps its owner, mode and inode.
---@type string
M.FIX_SCRIPT = [[
lvim_space_fix() {
  f="$HOME/$2"
  new=$(cat)
  [ -n "$new" ] || return 0
  t=$(mktemp "$HOME/.lvim-space-rc.XXXXXX") || return 1
  old=
  if [ -f "$f" ]; then
    old=$(awk '/^# >>> lvim-space: remote-ssh/ { b = 1; next } /^# <<< lvim-space <<</ { b = 0; next } b' "$f")
  fi
  {
    echo '# >>> lvim-space: remote-ssh environment >>>'
    echo '# What Neovim remote-ssh, and the tools installed for it, need here. Managed by lvim-space.'
    printf '%s\n%s\n' "$old" "$new" | awk 'NF && $0 !~ /^#/ && !seen[$0]++'
    echo '# <<< lvim-space <<<'
    echo
    if [ -f "$f" ]; then
      awk '/^# >>> lvim-space: remote-ssh/ { b = 1; next }
           b && /^# <<< lvim-space <<</ { b = 0; s = 1; next }
           b { next }
           s && $0 == "" { s = 0; next }
           { s = 0; print }' "$f"
    fi
  } > "$t" && cat "$t" > "$f"
  s=$?
  rm -f "$t"
  return $s
}
lvim_space_fix "$@"
]]

---@class LvimSpaceSshCandidate
---@field version integer[]  { major, minor, patch }
---@field dir string         the bin directory

---@class LvimSpaceSshFacts
---@field os string|nil
---@field arch string|nil
---@field shell string|nil
---@field runtime_dir_missing string|nil
---@field tmp_ok boolean
---@field has table<string, boolean>
---@field installed boolean
---@field plugin "none"|"old"|"ssh"|nil
---@field node_candidates LvimSpaceSshCandidate[]
---@field python_candidates LvimSpaceSshCandidate[]

--- A directory safe to write into a shell line inside single quotes: absolute, and nothing but letters,
--- digits, `.`, `_`, `-` and `/`.
---@param dir string
---@return boolean
local function safe_dir(dir)
    return type(dir) == "string" and dir:match("^/[%w%._%-/]+$") ~= nil and not dir:find("//", 1, true)
end

--- `v22.23.4 /dir` or `3.11.9 /dir` → candidate, or nil.
---@param value string
---@return LvimSpaceSshCandidate|nil
local function candidate(value)
    local ver, dir = value:match("^v?([%d%.]+)%s+(%S+)$")
    if not ver or not safe_dir(dir) then
        return nil
    end
    local v = {}
    for n in ver:gmatch("%d+") do
        v[#v + 1] = tonumber(n)
    end
    return #v > 0 and { version = v, dir = dir } or nil
end

--- Parse the probe's output.
---@param stdout string|nil
---@return LvimSpaceSshFacts
function M.parse_facts(stdout)
    local f = { has = {}, tmp_ok = false, installed = false, node_candidates = {}, python_candidates = {} }
    for line in (stdout or ""):gmatch("[^\r\n]+") do
        local key, value = line:match("^([%w_]+)=(.*)$")
        if key then
            local tool = key:match("^has_(.+)$")
            if tool then
                f.has[tool] = true
            elseif key == "tmp_ok" or key == "installed" then
                f[key] = true
            elseif key == "node_candidate" or key == "python_candidate" then
                local c = candidate(value)
                if c then
                    table.insert(f[key:gsub("_candidate$", "_candidates")], c)
                end
            elseif value ~= "" then
                f[key] = value
            end
        end
    end
    return f
end

---@param a integer[]
---@param b integer[]
---@return boolean
local function newer(a, b)
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x ~= y then
            return x > y
        end
    end
    return false
end

--- The Node.js to put on PATH: the newest LTS line (an even major) from 18 up, else the newest from 18 up.
---@param list LvimSpaceSshCandidate[]
---@return LvimSpaceSshCandidate|nil
function M.pick_node(list)
    local best_lts, best
    for _, c in ipairs(list) do
        if c.version[1] >= 18 then
            if not best or newer(c.version, best.version) then
                best = c
            end
            if c.version[1] % 2 == 0 and (not best_lts or newer(c.version, best_lts.version)) then
                best_lts = c
            end
        end
    end
    return best_lts or best
end

--- The Python to put on PATH: the newest 3.x from 3.9 up (with `venv` and `ensurepip`, which the probe checked).
---@param list LvimSpaceSshCandidate[]
---@return LvimSpaceSshCandidate|nil
function M.pick_python(list)
    local best
    for _, c in ipairs(list) do
        if c.version[1] == 3 and (c.version[2] or 0) >= 9 and (not best or newer(c.version, best.version)) then
            best = c
        end
    end
    return best
end

--- The shell line that puts `dir` first on PATH, once.
---@param dir string  checked by `safe_dir`
---@return string
function M.path_line(dir)
    return ("case \":$PATH:\" in *:'%s':*) ;; *) [ -d '%s' ] && PATH='%s':\"$PATH\" ;; esac"):format(dir, dir, dir)
end

--- The shell line that drops an XDG_RUNTIME_DIR whose directory does not exist.
M.RUNTIME_DIR_LINE = '[ -n "$XDG_RUNTIME_DIR" ] && [ ! -d "$XDG_RUNTIME_DIR" ] && unset XDG_RUNTIME_DIR'

local SUPPORTED_OS = { Linux = true, Darwin = true }
local SUPPORTED_ARCH = { x86_64 = true, aarch64 = true, arm64 = true }

---@class LvimSpaceSshChange
---@field kind "runtime_dir"|"node"|"python"
---@field what string   for the question: the directory, and the version for a runtime
---@field lines string[]

---@class LvimSpaceSshAssessment
---@field blocking { code: string, detail: string|nil }|nil  What stops remote-ssh, if anything.
---@field env { rc: string, changes: LvimSpaceSshChange[] }|nil  Environment changes the server needs, when they can be made.
---@field warnings { code: string, detail: string|nil }[]   What does not stop the connection.

---@param v integer[]
---@return string
local function version_text(v)
    return table.concat(v, ".")
end

--- What the facts mean for remote-ssh. Pure, so every case is a table in the spec.
---@param f LvimSpaceSshFacts
---@return LvimSpaceSshAssessment
function M.assess(f)
    local out = { warnings = {} }
    if not (f.os and SUPPORTED_OS[f.os]) or not (f.arch and SUPPORTED_ARCH[f.arch]) then
        out.blocking = { code = "SSH_REMOTE_PLATFORM", detail = ("%s %s"):format(f.os or "?", f.arch or "?") }
        return out
    end
    if not f.tmp_ok then
        out.blocking = { code = "SSH_REMOTE_TMP", detail = "/tmp" }
        return out
    end
    -- Without an installed release (ours, or `nvim` on PATH, which remote-ssh may use), it installs one.
    if not f.installed and not f.has.nvim then
        local missing = {}
        for _, tool in ipairs({ "curl", "tar" }) do
            if not f.has[tool] then
                missing[#missing + 1] = tool
            end
        end
        if not f.has.sha256sum and not f.has.shasum then
            missing[#missing + 1] = "sha256sum"
        end
        if #missing > 0 then
            out.blocking = { code = "SSH_REMOTE_TOOLS", detail = table.concat(missing, ", ") }
            return out
        end
    end

    local rc = M.RC_FILES[f.shell or ""]
    local changes = {}
    if f.runtime_dir_missing then
        if not rc then
            out.blocking = {
                code = "SSH_REMOTE_RUNTIME_DIR",
                detail = ("%s (login shell %s: unset XDG_RUNTIME_DIR there when the directory is missing)"):format(
                    f.runtime_dir_missing,
                    f.shell or "?"
                ),
            }
            return out
        end
        changes[#changes + 1] = {
            kind = "runtime_dir",
            what = f.runtime_dir_missing,
            lines = { M.RUNTIME_DIR_LINE },
        }
    end

    -- The runtimes the plugin manager on the server installs language tools with. Missing ones never stop
    -- the connection: only the tools that need them cannot be installed there.
    local runtimes = {
        {
            kind = "node",
            present = f.has.node and f.has.npm,
            pick = M.pick_node(f.node_candidates or {}),
            missing = "SSH_REMOTE_NO_NODE",
        },
        {
            kind = "python",
            present = f.has.python3 and f.has.venv,
            pick = M.pick_python(f.python_candidates or {}),
            missing = "SSH_REMOTE_NO_PYTHON",
        },
    }
    for _, r in ipairs(runtimes) do
        if not r.present then
            if not r.pick then
                out.warnings[#out.warnings + 1] = { code = r.missing }
            elseif not rc then
                out.warnings[#out.warnings + 1] = {
                    code = "SSH_REMOTE_ENV_MANUAL",
                    detail = ("%s %s in %s (login shell %s)"):format(
                        r.kind,
                        version_text(r.pick.version),
                        r.pick.dir,
                        f.shell or "?"
                    ),
                }
            else
                changes[#changes + 1] = {
                    kind = r.kind,
                    what = ("%s %s (%s)"):format(r.kind, version_text(r.pick.version), r.pick.dir),
                    lines = { M.path_line(r.pick.dir), "export PATH" },
                }
            end
        end
    end
    if #changes > 0 then
        out.env = { rc = rc, changes = changes }
    end

    if f.plugin == "none" then
        out.warnings[#out.warnings + 1] = { code = "SSH_REMOTE_PLUGIN_NONE" }
    elseif f.plugin == "old" then
        out.warnings[#out.warnings + 1] = { code = "SSH_REMOTE_PLUGIN_OLD" }
    end
    return out
end

--- The question asked before the environment block is written.
---@param env { rc: string, changes: LvimSpaceSshChange[] }
---@return string
function M.env_question(env)
    local lines = { ("The server needs these in ~/%s for remote Neovim and the tools installed there:"):format(env.rc) }
    for _, c in ipairs(env.changes) do
        if c.kind == "runtime_dir" then
            lines[#lines + 1] = ("  - unset XDG_RUNTIME_DIR=%s, which does not exist (Neovim cannot start)"):format(
                c.what
            )
        else
            lines[#lines + 1] = ("  - put %s on PATH"):format(c.what)
        end
    end
    lines[#lines + 1] = "Write them (one marked block at the top of the file)?"
    return table.concat(lines, "\n")
end

--- The block's lines, as the fix reads them from stdin.
---@param env { rc: string, changes: LvimSpaceSshChange[] }
---@return string
function M.env_input(env)
    local out = {}
    for _, c in ipairs(env.changes) do
        vim.list_extend(out, c.lines)
    end
    return table.concat(out, "\n") .. "\n"
end

--- The probe as an ssh call (its script goes on stdin).
---@param t LvimSpaceSshTarget
---@return string[]
function M.probe_argv(t)
    local argv = vim.list_extend({ M.exe }, batch_options())
    vim.list_extend(argv, dest(t))
    argv[#argv + 1] = M.PROBE_CMD
    return argv
end

--- The fix as an ssh call (its script goes on stdin). `rc` is one of `M.RC_FILES`, never user input.
---@param t LvimSpaceSshTarget
---@param rc string
---@return string[]
function M.fix_argv(t, rc)
    local argv = vim.list_extend({ M.exe }, batch_options())
    vim.list_extend(argv, dest(t))
    argv[#argv + 1] = "sh -s lvim-space-fix " .. rc
    return argv
end

-- ---------------------------------------------------------------------------
-- Neovim's own "Connect?" question
-- ---------------------------------------------------------------------------

--- Hosts `:connect` has already succeeded to, from here: `stdpath("state")/lvim-space/ssh-hosts.json`.
---@return string
local function hosts_file()
    return vim.fs.joinpath(vim.fn.stdpath("state"), "lvim-space", "ssh-hosts.json")
end

---@return table<string, boolean>
local function read_hosts()
    local fd = io.open(hosts_file(), "r")
    if not fd then
        return {}
    end
    local raw = fd:read("*a")
    fd:close()
    local ok, data = pcall(vim.json.decode, raw or "")
    return (ok and type(data) == "table") and data or {}
end

--- Whether `:connect` has succeeded to this address before.
---@param addr string  ssh://[user@]host[:port]
---@return boolean
function M.known_host(addr)
    return read_hosts()[addr] == true
end

--- Remember that `:connect` succeeded to this address.
---@param addr string
function M.remember_host(addr)
    local hosts = read_hosts()
    if hosts[addr] then
        return
    end
    hosts[addr] = true
    pcall(vim.fn.mkdir, vim.fs.dirname(hosts_file()), "p")
    local fd = io.open(hosts_file(), "w")
    if fd then
        fd:write(vim.json.encode(hosts))
        fd:close()
    end
end

--- Run `:connect addr`. With `answer`, Neovim's own "Connect? Yes / Update Nvim / No" question (remote-ssh asks
--- it on EVERY connect: it installs Nvim there and overwrites ~/.config/nvim-remote) is answered "Yes" — that
--- question only, and only for this call. `vim.fn.confirm` is replaced while `:connect` runs, which is where
--- remote-ssh asks, synchronously, before it starts anything; it is restored before this returns. A question
--- worded differently (a later Neovim) is not recognised and is asked as usual.
---@param addr string
---@param answer boolean|"update"  true = "Yes", "update" = "Update Nvim" (Yes where it is not offered), false = ask
---@return boolean ok
---@return any err
---@return boolean accepted  the remote-ssh question was answered Yes / Update Nvim (here or by the user)
function M.run_connect(addr, answer)
    local cmd = { cmd = "connect", args = { addr } }
    local real = vim.fn.confirm
    local choice -- what the remote-ssh question got: answered here, or picked by the user
    vim.fn.confirm = function(msg, choices, ...)
        if type(choices) == "string" and choices:find("^Connect%?") and choices:find("&Yes", 1, true) then
            if answer == "update" then
                -- "Update Nvim" is offered only by a nightly (prerelease) Neovim; without it, plain Yes.
                choice = choices:find("&Update", 1, true) and 2 or 1
            elseif answer then
                choice = 1
            else
                choice = real(msg, choices, ...)
            end
            return choice
        end
        return real(msg, choices, ...)
    end
    local ok, err = pcall(vim.api.nvim_cmd, cmd, {})
    vim.fn.confirm = real
    -- "Yes" (1) or "Update Nvim" (2) connected; "No", or a question never asked (not recognised), did not
    -- prove anything worth remembering.
    return ok, err, choice == 1 or choice == 2
end

--- Ask the user a yes/no question. THE one place lvim-space asks during a connect; tests replace it.
---@param message string
---@return boolean
function M.confirm(message)
    return vim.fn.confirm(message, "&Yes\n&No", 2) == 1
end

--- The INTERACTIVE master: no BatchMode, so ssh may ask for a password (or a host-key confirmation) in the
--- terminal. `-f` sends it to the background as soon as it has authenticated, which ends the terminal job.
--- `ControlPersist` alone would not: it backgrounds the master only once the initial client closes, and
--- under `-N` that client never closes, so the terminal would hang after the password until closed by hand.
---@param t LvimSpaceSshTarget
---@return string[]
function M.master_argv(t)
    return vim.list_extend({
        M.exe,
        "-o",
        "ControlMaster=yes",
        "-o",
        "ControlPath=" .. M.control_path(),
        "-o",
        "ControlPersist=10m",
        "-f",
        "-N",
    }, dest(t))
end

-- ---------------------------------------------------------------------------
-- The two process seams
-- ---------------------------------------------------------------------------

--- Run a non-interactive command. THE one place a process is started without a terminal; tests replace it.
---@param argv string[]
---@param opts { stdin: string|nil, timeout: integer|nil }|nil
---@param cb fun(res: LvimSpaceSshResult) Called on the main loop.
function M.run(argv, opts, cb)
    opts = opts or {}
    local ok, err = pcall(
        vim.system,
        argv,
        { text = true, stdin = opts.stdin, timeout = opts.timeout },
        vim.schedule_wrap(function(res)
            cb({ code = res.code, stdout = res.stdout, stderr = res.stderr })
        end)
    )
    if not ok then
        vim.schedule(function()
            cb({ code = -1, stdout = "", stderr = tostring(err) })
        end)
    end
end

--- Run an interactive command in a floating terminal. THE one place a terminal is opened; tests replace it.
--- Closing the window ends the job, which is reported as a non-zero exit.
---@param argv string[]
---@param on_exit fun(code: integer) Called on the main loop once the job has ended.
function M.terminal(argv, on_exit)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    local width = math.max(20, math.min(100, vim.o.columns - 4))
    local height = math.max(3, math.min(12, vim.o.lines - 4))
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
        col = math.max(0, math.floor((vim.o.columns - width) / 2)),
        style = "minimal",
        border = "rounded",
        title = " ssh ",
        title_pos = "center",
    })
    local function finish(code)
        vim.schedule(function()
            if vim.api.nvim_win_is_valid(win) then
                pcall(vim.api.nvim_win_close, win, true)
            end
            if vim.api.nvim_buf_is_valid(buf) then
                pcall(vim.api.nvim_buf_delete, buf, { force = true })
            end
            on_exit(code)
        end)
    end
    local ok, job = pcall(vim.fn.jobstart, argv, {
        term = true,
        on_exit = function(_, code)
            finish(code)
        end,
    })
    if not ok or type(job) ~= "number" or job <= 0 then
        finish(-1)
        return
    end
    vim.cmd.startinsert()
end

-- ---------------------------------------------------------------------------
-- LOCAL half: hand the project over and connect
-- ---------------------------------------------------------------------------

--- The first meaningful line of a failed command's output, for the user-facing message.
---@param res LvimSpaceSshResult
---@return string
local function detail(res)
    local text = vim.trim(res.stderr or "")
    if text == "" then
        text = vim.trim(res.stdout or "")
    end
    local line = text:match("[^\r\n]+") or ""
    if line == "" then
        line = "ssh exited with status " .. tostring(res.code)
    end
    return line
end

---@class LvimSpaceSshOpenOpts
---@field auth "auto"|"key"|"password"|nil  How to authenticate (default "auto").
---@field timeout integer|nil               Timeout (ms) for each non-interactive ssh call.
---@field fix_environment "ask"|"always"|"never"|nil  The environment block on the server (default "ask").
---@field update_nvim boolean|nil  answer Neovim's "Connect?" with "Update Nvim" (the project panel's update action)
---@field confirm_connect "first"|"always"|"never"|nil  Neovim's own "Connect?" question: asked the first time per address (default), every time, or never
---@field sync (fun(uri: string, cb: fun(ok: boolean, err: string|nil)))|nil  Mirror the plugins to the
---      server before connecting (lvim-pack's `remote_sync`). A failure stops the connection.
---@field on_warn (fun(code: string, detail: string|nil))|nil  A finding that does not stop the connection.
---@field on_done (fun(ok: boolean, err_code: string|nil, detail: string|nil))|nil

--- Open a remote project: store the request on the server, then `:connect`.
---
--- `auth`:
---   "key"      — go straight to the non-interactive write; never prompt.
---   "password" — unless a master connection is already alive, open the terminal so the password can be typed.
---   "auto"     — reuse a live master; else try non-interactively; only if ssh ITSELF fails (status 255: no
---                connection or no authentication) fall back to the terminal.
---
--- On any failure nothing is connected and `on_done(false, code, detail)` says why.
---@param project { path: string, name: string|nil }
---@param opts LvimSpaceSshOpenOpts|nil
function M.open(project, opts)
    opts = opts or {}
    local done = opts.on_done or function() end
    local auth = opts.auth
    if auth ~= "key" and auth ~= "password" then
        auth = "auto"
    end

    local t, parse_err = M.parse(project and project.path)
    if not t then
        return done(false, parse_err, nil)
    end
    if not M.supported() then
        return done(false, "SSH_UNSUPPORTED", nil)
    end

    local run_opts = { timeout = opts.timeout }
    local payload = vim.json.encode({ version = 1, path = t.path, name = project.name or M.default_name(project.path) })

    local function connect()
        local addr = M.address(t)
        local policy = opts.confirm_connect or "first"
        local answer = policy == "never" or (policy == "first" and M.known_host(addr))
        if opts.update_nvim then
            answer = "update"
        end
        local ok, err, accepted = M.run_connect(addr, answer)
        if ok then
            -- Remembered only when the question was accepted: a "No" there must not turn into a "Yes" later.
            if accepted then
                M.remember_host(addr)
            end
            return done(true, nil, nil)
        end
        -- Nothing will read the request now: withdraw it, so a LATER plain `:connect` does not act on it.
        M.run(M.clear_argv(t), run_opts, function()
            done(false, "SSH_CONNECT_FAILED", tostring(err))
        end)
    end

    --- Stop before `:connect`: withdraw the request just written, then report.
    local function abort(code, text)
        M.run(M.clear_argv(t), run_opts, function()
            done(false, code, text)
        end)
    end

    --- Probe the server; write the environment block when allowed; connect only when nothing blocks remote-ssh.
    ---@param fixed boolean  the fix has already run (a second probe that still finds the problem stops)
    ---@param synced boolean  the plugins were just mirrored: the server's lvim-space is this one
    local function preflight(fixed, synced)
        M.run(M.probe_argv(t), { stdin = M.PROBE_SCRIPT, timeout = opts.timeout }, function(res)
            if res.code ~= 0 then
                return abort("SSH_PROBE_FAILED", detail(res))
            end
            local verdict = M.assess(M.parse_facts(res.stdout))
            if verdict.blocking then
                return abort(verdict.blocking.code, verdict.blocking.detail)
            end
            if verdict.env then
                local env = verdict.env
                if fixed then
                    -- The block is in the startup file, yet a fresh session still needs it: this shell does not
                    -- read that file for a non-interactive command.
                    local what = vim.tbl_map(function(c)
                        return c.what
                    end, env.changes)
                    return abort("SSH_REMOTE_RC_NOT_READ", ("~/%s (%s)"):format(env.rc, table.concat(what, "; ")))
                end
                local policy = opts.fix_environment or "ask"
                local allowed = policy == "always" or (policy == "ask" and M.confirm(M.env_question(env)))
                if not allowed then
                    -- Only the runtime dir stops remote-ssh; a runtime left off PATH just limits what installs there.
                    for _, c in ipairs(env.changes) do
                        if c.kind == "runtime_dir" then
                            return abort("SSH_REMOTE_RUNTIME_DIR", c.what)
                        end
                    end
                    for _, c in ipairs(env.changes) do
                        verdict.warnings[#verdict.warnings + 1] = {
                            code = c.kind == "node" and "SSH_REMOTE_NO_NODE" or "SSH_REMOTE_NO_PYTHON",
                            detail = c.what,
                        }
                    end
                else
                    return M.run(
                        M.fix_argv(t, env.rc),
                        { stdin = M.FIX_SCRIPT .. M.env_input(env), timeout = opts.timeout },
                        function(fix)
                            if fix.code ~= 0 then
                                return abort("SSH_REMOTE_FIX_FAILED", detail(fix))
                            end
                            preflight(true, synced)
                        end
                    )
                end
            end
            for _, w in ipairs(synced and {} or verdict.warnings) do
                if opts.on_warn then
                    opts.on_warn(w.code, w.detail)
                end
            end
            connect()
        end)
    end

    ---@param on_fail fun(res: LvimSpaceSshResult)
    local function write(on_fail)
        M.run(M.write_argv(t), { stdin = payload, timeout = opts.timeout }, function(res)
            if res.code ~= 0 then
                return on_fail(res)
            end
            if not opts.sync then
                return preflight(false, false)
            end
            opts.sync(M.address(t), function(ok, err)
                if not ok then
                    return abort("SSH_SYNC_FAILED", err)
                end
                preflight(false, true)
            end)
        end)
    end

    local function write_failed(res)
        done(false, "SSH_WRITE_FAILED", detail(res))
    end

    local function interactive()
        -- ssh does not create the socket's directory; Neovim makes the same one before its own commands.
        pcall(vim.fn.mkdir, vim.fs.dirname(M.control_path()), "p")
        M.terminal(M.master_argv(t), function(code)
            if code ~= 0 then
                return done(false, "SSH_AUTH_FAILED", "ssh exited with status " .. tostring(code))
            end
            -- The terminal ending cleanly is not proof: only a live master lets the BatchMode steps through.
            M.run(M.check_argv(t), run_opts, function(res)
                if res.code ~= 0 then
                    return done(false, "SSH_AUTH_FAILED", detail(res))
                end
                write(write_failed)
            end)
        end)
    end

    if auth == "key" then
        return write(write_failed)
    end

    M.run(M.check_argv(t), run_opts, function(check)
        if check.code == 0 then
            return write(write_failed)
        end
        if auth == "password" then
            return interactive()
        end
        write(function(res)
            if res.code == M.SSH_FAILURE then
                interactive()
            else
                write_failed(res)
            end
        end)
    end)
end

-- ---------------------------------------------------------------------------
-- REMOTE half: pick the request up
-- ---------------------------------------------------------------------------

--- Why this Neovim started (`v:startreason`; nil on a Neovim that predates it). A function so tests can
--- stand in for the read-only variable.
---@return string|nil
function M.start_reason()
    local ok, reason = pcall(function()
        return vim.v.startreason
    end)
    return ok and reason or nil
end

--- The home directory the request path is relative to. A function so tests can redirect it.
---@return string
function M.home()
    return vim.uv.os_homedir() or vim.env.HOME or ""
end

--- Absolute path of the request file on THIS machine.
---@return string
function M.request_path()
    return vim.fs.joinpath(M.home(), M.REMOTE_DIR, M.REQUEST_FILE)
end

--- Read AND DELETE the pending request, when this Neovim was started by remote-ssh. The file is removed
--- whether or not it could be understood: a request is good for one start only.
---@return { path: string, name: string|nil }|nil request
function M.take_request()
    if M.start_reason() ~= "remote-ssh" then
        return nil
    end
    local file = M.request_path()
    local fd = io.open(file, "r")
    if not fd then
        return nil
    end
    local raw = fd:read("*a")
    fd:close()
    os.remove(file)

    local ok, req = pcall(vim.json.decode, raw or "")
    if not ok or type(req) ~= "table" or type(req.path) ~= "string" or req.path:sub(1, 1) ~= "/" then
        return nil
    end
    local name = type(req.name) == "string" and vim.trim(req.name) or ""
    return { path = req.path, name = name ~= "" and name or nil }
end

---@class LvimSpaceSshRequestDeps
---@field find_project_by_path fun(path: string): table|nil
---@field is_project_name_exist fun(name: string): any
---@field add_project fun(path: string, name: string): any

--- Act on the pending request: change into the requested directory and make sure a project row exists for
--- it (created with the requested name when this server has never seen it). The caller's normal context
--- loading then finds the project by cwd and restores its session. Without a request this is a no-op.
---
--- The directory is entered FIRST and the project is keyed by the resulting cwd, because that is exactly
--- what the cwd lookup compares against later (a symlinked path would otherwise never match).
---@param deps LvimSpaceSshRequestDeps The data layer (`lvim-space.api.data` in production).
---@return boolean applied True when the request was applied.
---@return string|nil err_code Set when a request existed but could not be applied.
---@return string|nil detail
function M.apply_request(deps)
    local req = M.take_request()
    if not req then
        return false, nil, nil
    end
    if vim.fn.isdirectory(req.path) ~= 1 then
        return false, "DIRECTORY_NOT_FOUND", req.path
    end
    local ok, err = pcall(vim.api.nvim_set_current_dir, req.path)
    if not ok then
        return false, "SSH_REMOTE_CD_FAILED", tostring(err)
    end
    local dir = vim.uv.cwd() or req.path
    if not dir:match("/$") then
        dir = dir .. "/"
    end
    if deps.find_project_by_path(dir) then
        return true, nil, nil
    end

    local base = req.name or dir:match("([^/]+)/$") or "remote"
    local name, n = base, 1
    while deps.is_project_name_exist(name) do
        n = n + 1
        name = ("%s-%d"):format(base, n)
    end
    local id = deps.add_project(dir, name)
    if type(id) ~= "number" or id <= 0 then
        return false, "PROJECT_ADD_FAILED", dir
    end
    return true, nil, nil
end

return M
