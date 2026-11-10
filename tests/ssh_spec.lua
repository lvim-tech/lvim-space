-- Remote (SSH) projects: `lvim-space.core.ssh`.
--
-- No server is ever contacted and no ssh is ever started: the module's two process seams (`run` for
-- the non-interactive calls, `terminal` for the password prompt) are replaced by a scripted fake that
-- records the exact argument lists, and `vim.api.nvim_cmd` is intercepted for `:connect`. What these
-- tests therefore prove is what lvim-space ASKS ssh and Neovim to do -- not that a real server answers.

local ssh = require("lvim-space.core.ssh")

local sandbox = vim.env.LVIM_TEST_HOME
local CONTROL = "ControlPath=" .. vim.fs.joinpath(vim.fn.stdpath("cache"), "ssh", "mux_%C")
local DIR = ".local/share/nvim-remote/lvim-space"
local WRITE_CMD = ("mkdir -p %s && cat > %s/request.json.tmp && mv %s/request.json.tmp %s/request.json"):format(
    DIR,
    DIR,
    DIR,
    DIR
)

--- The non-interactive option block, as Neovim's own remote-ssh passes it.
---@param tail string[]
---@return string[]
local function batch(tail)
    local argv = {
        "ssh",
        "-T",
        "-o",
        "BatchMode=yes",
        "-o",
        "ControlMaster=auto",
        "-o",
        CONTROL,
        "-o",
        "ControlPersist=10m",
        "-o",
        "RemoteCommand=none",
    }
    return vim.list_extend(argv, tail)
end

---@class FakeSsh
---@field calls table[]      every seam call except the preflight, in order: { kind = "run"|"terminal"|"connect", argv, stdin }
---@field log string[]       EVERY call in order, preflight included: "check"|"write"|"clear"|"probe"|"fix"|"terminal"|"connect"|"confirm"
---@field restore fun()

--- Replace ssh, the terminal and `:connect` with a script. `answers.run(argv, n)` returns the exit
--- result of the n-th non-interactive call; `answers.terminal` the terminal's exit code.
--- What a healthy server answers the probe: everything remote-ssh needs, lvim-space with remote projects.
local HEALTHY = table.concat({
    "os=Linux",
    "arch=x86_64",
    "shell=bash",
    "tmp_ok=1",
    "has_curl=1",
    "has_tar=1",
    "has_sha256sum=1",
    "has_node=1",
    "has_npm=1",
    "has_python3=1",
    "has_venv=1",
    "plugin=ssh",
}, "\n") .. "\n"

--- The preflight calls are answered apart from `answers.run` (and do not advance its counter), so a test of
--- the authentication sequence states only that sequence. `answers.probe(n)` / `answers.fix(n)` script them;
--- by default the server is HEALTHY and a fix succeeds. `answers.confirm` answers the question (default no).
---@param answers { run: (fun(argv: string[], n: integer): table), terminal: integer|nil, connect_error: string|nil, supported: boolean|nil, probe: (fun(n: integer): table)|nil, fix: (fun(n: integer): table)|nil, confirm: boolean|nil }
---@return FakeSsh
local function fake(answers)
    local saved = {
        run = ssh.run,
        terminal = ssh.terminal,
        supported = ssh.supported,
        confirm = ssh.confirm,
        nvim_cmd = vim.api.nvim_cmd,
    }
    local f = { calls = {}, log = {}, probes = {}, fixes = {}, questions = {} }
    local runs, probes, fixes = 0, 0, 0
    ssh.supported = function()
        return answers.supported ~= false
    end
    ssh.confirm = function(message)
        f.log[#f.log + 1] = "confirm"
        f.questions[#f.questions + 1] = message
        return answers.confirm == true
    end
    ssh.run = function(argv, opts, cb)
        local last = argv[#argv]
        if last == ssh.PROBE_CMD then
            probes = probes + 1
            f.log[#f.log + 1] = "probe"
            f.probes[#f.probes + 1] = { argv = argv, stdin = opts and opts.stdin }
            return cb(answers.probe and answers.probe(probes) or { code = 0, stdout = HEALTHY, stderr = "" })
        end
        if last:match("^sh %-s lvim%-space%-fix ") then
            fixes = fixes + 1
            f.log[#f.log + 1] = "fix"
            f.fixes[#f.fixes + 1] = { argv = argv, stdin = opts and opts.stdin }
            return cb(answers.fix and answers.fix(fixes) or { code = 0, stdout = "", stderr = "" })
        end
        runs = runs + 1
        f.log[#f.log + 1] = argv[2] == "-O" and "check" or (last:match("^rm ") and "clear" or "write")
        f.calls[#f.calls + 1] = { kind = "run", argv = argv, stdin = opts and opts.stdin }
        cb(answers.run(argv, runs))
    end
    ssh.terminal = function(argv, on_exit)
        f.log[#f.log + 1] = "terminal"
        f.calls[#f.calls + 1] = { kind = "terminal", argv = argv }
        on_exit(answers.terminal or 0)
    end
    vim.api.nvim_cmd = function(cmd, opts)
        if type(cmd) == "table" and cmd.cmd == "connect" then
            f.log[#f.log + 1] = "connect"
            f.calls[#f.calls + 1] = { kind = "connect", argv = cmd.args }
            if answers.connect_error then
                error(answers.connect_error, 0)
            end
            return ""
        end
        return saved.nvim_cmd(cmd, opts)
    end
    f.restore = function()
        ssh.run, ssh.terminal, ssh.supported, ssh.confirm = saved.run, saved.terminal, saved.supported, saved.confirm
        vim.api.nvim_cmd = saved.nvim_cmd
    end
    return f
end

--- Run `ssh.open` against a fake and return what happened.
---@param project table
---@param auth string|nil
---@param answers table
---@return table[] calls, table outcome
local function open(project, auth, answers, extra)
    local f = fake(answers)
    local outcome = {}
    local warnings = {}
    local o = vim.tbl_extend("force", extra or {}, {
        auth = auth,
        on_warn = function(code, detail)
            warnings[#warnings + 1] = { code = code, detail = detail }
        end,
        on_done = function(success, code, detail)
            outcome = { ok = success, code = code, detail = detail }
        end,
    })
    local ok, err = pcall(ssh.open, project, o)
    f.restore()
    if not ok then
        error(err, 0)
    end
    return f.calls, outcome, f, warnings
end

--- The sequence of seam kinds, with `run` calls told apart by what they are.
---@param calls table[]
---@return string[]
local function kinds(calls)
    local out = {}
    for i, call in ipairs(calls) do
        local kind = call.kind
        if kind == "run" then
            kind = call.argv[2] == "-O" and "check" or (call.argv[#call.argv]:match("^rm ") and "clear" or "write")
        end
        out[i] = kind
    end
    return out
end

local OK = { code = 0, stdout = "", stderr = "" }
local DENIED = { code = 255, stdout = "", stderr = "user@box: Permission denied (publickey,password).\n" }
local NO_MASTER = { code = 255, stdout = "", stderr = "Control socket connect: No such file or directory\n" }

local PROJECT = { name = "site", path = "ssh://deploy@box.example:2222/srv/www/site" }

describe("lvim-space ssh: parsing a remote project path")

it("host and absolute path alone", function()
    eq({ host = "box", path = "/srv/app" }, (ssh.parse("ssh://box/srv/app")))
end)

it("user and port", function()
    eq(
        { user = "deploy", host = "10.0.0.7", port = 2222, path = "/srv/app" },
        (ssh.parse("ssh://deploy@10.0.0.7:2222/srv/app"))
    )
end)

it("the stored form is canonical: no trailing or doubled slash, surrounding space dropped", function()
    eq("ssh://me@box:22/srv/app", (ssh.validate("  ssh://me@box:22//srv/app/  ")))
    eq("ssh://box/", (ssh.validate("ssh://box/")), "the root stays the root")
end)

it("what :connect is given has no path", function()
    eq("ssh://deploy@box.example:2222", ssh.address(assert(ssh.parse(PROJECT.path))))
    eq("ssh://box", ssh.address(assert(ssh.parse("ssh://box/srv"))))
end)

it("a missing host is refused", function()
    eq({ nil, "SSH_HOST_REQUIRED" }, { ssh.parse("ssh:///srv/app") })
    eq({ nil, "SSH_HOST_REQUIRED" }, { ssh.parse("ssh://me@/srv/app") })
    eq({ nil, "SSH_HOST_REQUIRED" }, { ssh.parse("ssh://:22/srv/app") })
end)

it("a path that is not absolute is refused", function()
    eq({ nil, "SSH_PATH_NOT_ABSOLUTE" }, { ssh.parse("ssh://box") }, "no path at all")
    eq({ nil, "SSH_PATH_NOT_ABSOLUTE" }, { ssh.parse("ssh://box/~/app") }, "home-relative")
    eq({ nil, "SSH_PATH_NOT_ABSOLUTE" }, { ssh.parse("ssh://box/./app") }, "dot")
    eq({ nil, "SSH_PATH_NOT_ABSOLUTE" }, { ssh.parse("ssh://box/srv/../etc") }, "dot-dot")
    eq({ nil, "SSH_PATH_NOT_ABSOLUTE" }, { ssh.parse("ssh://box/srv\n/app") }, "a control character")
end)

it("a bad port is refused", function()
    for _, uri in ipairs({ "ssh://box:0/srv", "ssh://box:65536/srv", "ssh://box:abc/srv", "ssh://box:/srv" }) do
        eq({ nil, "SSH_PORT_INVALID" }, { ssh.parse(uri) }, uri)
    end
end)

it("a user or host that could be read as an ssh option, or carries a secret, is refused", function()
    eq({ nil, "SSH_HOST_INVALID" }, { ssh.parse("ssh://-oProxyCommand=x/srv") })
    eq({ nil, "SSH_USER_INVALID" }, { ssh.parse("ssh://-l@box/srv") })
    eq({ nil, "SSH_USER_INVALID" }, { ssh.parse("ssh://me:secret@box/srv") })
    eq({ nil, "SSH_USER_INVALID" }, { ssh.parse("ssh://@box/srv") })
    eq({ nil, "SSH_HOST_INVALID" }, { ssh.parse("ssh://bo x/srv") })
end)

it("what is not an ssh:// URI is not parsed as one", function()
    eq({ nil, "SSH_URI_INVALID" }, { ssh.parse("/srv/app") })
    eq({ nil, "SSH_URI_INVALID" }, { ssh.parse("box:/srv/app") })
    eq({ nil, "SSH_URI_INVALID" }, { ssh.parse(nil) })
end)

it("a duplicate is refused, compared in the canonical form", function()
    local stored = { ["ssh://box/srv/app"] = true }
    local function exists(path)
        return stored[path]
    end
    eq({ nil, "PROJECT_PATH_EXIST" }, { ssh.validate("ssh://box/srv/app/", exists) })
    eq("ssh://box/srv/other", (ssh.validate("ssh://box/srv/other", exists)))
    eq("ssh://me@box/srv/app", (ssh.validate("ssh://me@box/srv/app", exists)), "another login is another project")
end)

it("the default name is the last path component, or the host for the root", function()
    eq("site", ssh.default_name("ssh://box/srv/www/site/"))
    eq("box", ssh.default_name("ssh://me@box/"))
end)

describe("lvim-space ssh: the commands")

it("the ControlPath is the one Neovim's remote-ssh uses", function()
    eq(vim.fs.joinpath(vim.fn.stdpath("cache"), "ssh", "mux_%C"), ssh.control_path())
end)

it("Neovim's own remote-ssh still builds that path, and those options, the same way", function()
    -- `vim.net._ssh` is private: it is never called, only READ here. If Neovim moves the socket, renames
    -- the app or changes how it multiplexes, lvim-space would silently stop sharing its connection (and
    -- its request would land where nobody looks) -- so this fails loudly instead.
    local file = vim.fs.joinpath(vim.env.VIMRUNTIME, "lua", "vim", "net", "_ssh.lua")
    local fd = io.open(file, "r")
    if not fd then
        skip("Neovim's own remote-ssh still builds that path", "this Neovim has no " .. file)
        return
    end
    local src = fd:read("*a")
    fd:close()
    truthy(
        src:find("vim%.fs%.joinpath%(vim%.fn%.stdpath%('cache'%)[^\n,]*,%s*'ssh'%)"),
        "the mux dir is no longer joinpath(stdpath('cache'), 'ssh')"
    )
    truthy(src:find("vim%.fs%.joinpath%(mux_dir,%s*'mux_%%C'%)"), "the socket is no longer <mux dir>/mux_%C")
    truthy(src:find("%('ControlPath=%%s'%):format%(mux_path%)"), "ControlPath is no longer that socket")
    for _, option in ipairs({ "'-T'", "'BatchMode=yes'", "'ControlMaster=auto'", "'ControlPersist=10m'" }) do
        truthy(src:find(option, 1, true), "remote-ssh no longer passes " .. option)
    end
    truthy(src:find("local appname = 'nvim-remote'", 1, true), "the remote appname is no longer nvim-remote")
    truthy(
        src:find("local remote_data_dir = ('.local/share/%s'):format(appname)", 1, true),
        "the remote data dir is no longer .local/share/<appname>"
    )
    eq(DIR, ssh.REMOTE_DIR, "and the request is kept inside that data dir")
end)

it("the check, write and master commands, without and with a port", function()
    local plain = assert(ssh.parse("ssh://box/srv/app"))
    local full = assert(ssh.parse(PROJECT.path))
    eq({ "ssh", "-O", "check", "-o", CONTROL, "--", "box" }, ssh.check_argv(plain))
    eq({ "ssh", "-O", "check", "-o", CONTROL, "-p", "2222", "--", "deploy@box.example" }, ssh.check_argv(full))
    eq(batch({ "--", "box", WRITE_CMD }), ssh.write_argv(plain))
    eq(batch({ "-p", "2222", "--", "deploy@box.example", WRITE_CMD }), ssh.write_argv(full))
    eq(
        { "ssh", "-o", "ControlMaster=yes", "-o", CONTROL, "-o", "ControlPersist=10m", "-f", "-N", "--", "box" },
        ssh.master_argv(plain)
    )
    eq({
        "ssh",
        "-o",
        "ControlMaster=yes",
        "-o",
        CONTROL,
        "-o",
        "ControlPersist=10m",
        "-f",
        "-N",
        "-p",
        "2222",
        "--",
        "deploy@box.example",
    }, ssh.master_argv(full))
end)

it("a hostile project path or name never reaches the remote shell", function()
    local nasty = { name = "x'; rm -rf ~ #", path = "ssh://box/srv/a b/$(reboot)/'q'/`id`;x" }
    local calls, outcome = open(nasty, "key", {
        run = function()
            return OK
        end,
    })
    eq(true, outcome.ok)
    eq(batch({ "--", "box", WRITE_CMD }), calls[1].argv, "the remote command is the same constant")
    eq({
        version = 1,
        path = "/srv/a b/$(reboot)/'q'/`id`;x",
        name = "x'; rm -rf ~ #",
        client = vim.v.servername ~= "" and vim.v.servername or nil,
    }, vim.json.decode(calls[1].stdin), "path and name travel as data on stdin")
end)

describe("lvim-space ssh: opening a remote project (local side)")

it("auth = key: writes the request, then connects — no check, no terminal", function()
    local calls, outcome = open(PROJECT, "key", {
        run = function()
            return OK
        end,
    })
    eq({ "write", "connect" }, kinds(calls))
    eq(batch({ "-p", "2222", "--", "deploy@box.example", WRITE_CMD }), calls[1].argv)
    eq({
        version = 1,
        path = "/srv/www/site",
        name = "site",
        -- This editor's address: Quit on the server comes back here.
        client = vim.v.servername ~= "" and vim.v.servername or nil,
    }, vim.json.decode(calls[1].stdin))
    eq({ "ssh://deploy@box.example:2222" }, calls[2].argv)
    eq({ ok = true }, outcome)
end)

it("auth = key: a refused login is reported and nothing connects", function()
    local calls, outcome = open(PROJECT, "key", {
        run = function()
            return DENIED
        end,
    })
    eq({ "write" }, kinds(calls))
    eq({ ok = false, code = "SSH_WRITE_FAILED", detail = "user@box: Permission denied (publickey,password)." }, outcome)
end)

it("auth = password: no live connection opens the terminal, then check, write, connect", function()
    local calls, outcome = open(PROJECT, "password", {
        run = function(_, n)
            return n == 1 and NO_MASTER or OK
        end,
        terminal = 0,
    })
    eq({ "check", "terminal", "check", "write", "connect" }, kinds(calls))
    eq({ "ssh", "-O", "check", "-o", CONTROL, "-p", "2222", "--", "deploy@box.example" }, calls[1].argv)
    eq({
        "ssh",
        "-o",
        "ControlMaster=yes",
        "-o",
        CONTROL,
        "-o",
        "ControlPersist=10m",
        "-f",
        "-N",
        "-p",
        "2222",
        "--",
        "deploy@box.example",
    }, calls[2].argv)
    eq({ "ssh://deploy@box.example:2222" }, calls[5].argv)
    eq({ ok = true }, outcome)
end)

it("auth = password: a live connection is reused without a terminal", function()
    local calls, outcome = open(PROJECT, "password", {
        run = function()
            return OK
        end,
    })
    eq({ "check", "write", "connect" }, kinds(calls))
    eq({ ok = true }, outcome)
end)

it("auth = password: a cancelled prompt does nothing more and says so", function()
    local calls, outcome = open(PROJECT, "password", {
        run = function()
            return NO_MASTER
        end,
        terminal = 130,
    })
    eq({ "check", "terminal" }, kinds(calls))
    eq({ ok = false, code = "SSH_AUTH_FAILED", detail = "ssh exited with status 130" }, outcome)
end)

it("auth = password: a terminal that ends cleanly but leaves no connection is still a failure", function()
    local calls, outcome = open(PROJECT, "password", {
        run = function()
            return NO_MASTER
        end,
        terminal = 0,
    })
    eq({ "check", "terminal", "check" }, kinds(calls))
    eq(false, outcome.ok)
    eq("SSH_AUTH_FAILED", outcome.code)
end)

it("auth = auto: a live connection goes straight through", function()
    local calls, outcome = open(PROJECT, "auto", {
        run = function()
            return OK
        end,
    })
    eq({ "check", "write", "connect" }, kinds(calls))
    eq({ ok = true }, outcome)
end)

it("auth = auto: a key that works needs no terminal", function()
    local calls, outcome = open(PROJECT, nil, {
        run = function(_, n)
            return n == 1 and NO_MASTER or OK
        end,
    })
    eq({ "check", "write", "connect" }, kinds(calls), "auto is the default")
    eq({ ok = true }, outcome)
end)

it("auth = auto: when the key attempt is refused it falls back to the password terminal", function()
    local calls, outcome = open(PROJECT, "auto", {
        run = function(_, n)
            if n == 1 then
                return NO_MASTER
            elseif n == 2 then
                return DENIED
            end
            return OK
        end,
        terminal = 0,
    })
    eq({ "check", "write", "terminal", "check", "write", "connect" }, kinds(calls))
    eq(calls[2].argv, calls[5].argv, "the same write, now over the shared connection")
    eq({ ok = true }, outcome)
end)

it("auth = auto: a failure of the REMOTE command is not an auth problem — no terminal", function()
    local calls, outcome = open(PROJECT, "auto", {
        run = function(_, n)
            if n == 1 then
                return NO_MASTER
            end
            return { code = 1, stdout = "", stderr = "mkdir: cannot create directory: Read-only file system\n" }
        end,
    })
    eq({ "check", "write" }, kinds(calls))
    eq({
        ok = false,
        code = "SSH_WRITE_FAILED",
        detail = "mkdir: cannot create directory: Read-only file system",
    }, outcome)
end)

it("auth = auto: the password prompt cancelled after a refused key connects nothing", function()
    local calls, outcome = open(PROJECT, "auto", {
        run = function(_, n)
            return n == 1 and NO_MASTER or DENIED
        end,
        terminal = 1,
    })
    eq({ "check", "write", "terminal" }, kinds(calls))
    eq("SSH_AUTH_FAILED", outcome.code)
end)

it("an ssh that cannot be started at all is a reported failure", function()
    local calls, outcome = open(PROJECT, "key", {
        run = function()
            return { code = -1, stdout = "", stderr = "ENOENT: no such file or directory" }
        end,
    })
    eq({ "write" }, kinds(calls))
    eq({ ok = false, code = "SSH_WRITE_FAILED", detail = "ENOENT: no such file or directory" }, outcome)
end)

it("a :connect that refuses to start withdraws the request", function()
    local calls, outcome = open(PROJECT, "key", {
        run = function()
            return OK
        end,
        connect_error = "E6101: boom",
    })
    eq({ "write", "connect", "clear" }, kinds(calls))
    eq(batch({ "-p", "2222", "--", "deploy@box.example", "rm -f " .. DIR .. "/request.json" }), calls[3].argv)
    eq({ ok = false, code = "SSH_CONNECT_FAILED", detail = "E6101: boom" }, outcome)
end)

it("a Neovim without :connect ssh:// refuses before touching ssh", function()
    local calls, outcome = open(PROJECT, "auto", {
        supported = false,
        run = function()
            return OK
        end,
    })
    eq({}, calls)
    eq({ ok = false, code = "SSH_UNSUPPORTED" }, outcome)
end)

it("a stored path that is not a valid remote path is refused before touching ssh", function()
    local calls, outcome = open({ name = "x", path = "ssh://box" }, "auto", {
        run = function()
            return OK
        end,
    })
    eq({}, calls)
    eq({ ok = false, code = "SSH_PATH_NOT_ABSOLUTE" }, outcome)
end)

it("this Neovim's own answer to `supported` matches what it ships", function()
    local has = vim.fn.exists(":connect") == 2
        and vim.uv.fs_stat(vim.fs.joinpath(vim.env.VIMRUNTIME, "lua", "vim", "net", "_ssh.lua")) ~= nil
    eq(has, ssh.supported())
end)

describe("lvim-space ssh: picking the request up (remote side)")

---@class FakeStore
---@field rows table[]
---@field deps table

--- An in-memory stand-in for `lvim-space.api.data` (sqlite is not installed where the suite runs).
---@param rows table[]|nil
---@return FakeStore
local function store(rows)
    local s = { rows = rows or {} }
    s.deps = {
        find_project_by_path = function(path)
            for _, row in ipairs(s.rows) do
                if row.path == path then
                    return row
                end
            end
            return nil
        end,
        is_project_name_exist = function(name)
            for _, row in ipairs(s.rows) do
                if row.name == name then
                    return { row.id }
                end
            end
            return nil
        end,
        add_project = function(path, name)
            s.rows[#s.rows + 1] = { id = #s.rows + 1, path = path, name = name }
            return #s.rows
        end,
    }
    return s
end

--- Run `fn` as the remote Neovim would see things: a home inside the sandbox, the given start reason,
--- an optional pending request. The cwd and the seams are put back afterwards.
---@param reason string
---@param request string|nil  raw content of the request file (nil = no file)
---@param fn fun(home: string, project_dir: string, request_file: string)
local function remote(reason, request, fn)
    local home = vim.uv.fs_realpath(sandbox) .. "/remote-home"
    local project_dir = home .. "/work/site"
    vim.fn.mkdir(project_dir, "p")
    vim.fn.mkdir(vim.fs.joinpath(home, DIR), "p")
    local request_file = vim.fs.joinpath(home, DIR, "request.json")
    os.remove(request_file)
    if request then
        local fd = assert(io.open(request_file, "w"))
        fd:write(type(request) == "function" and request(project_dir) or request)
        fd:close()
    end

    local saved = { home = ssh.home, start_reason = ssh.start_reason, cwd = vim.uv.cwd() }
    ssh.home = function()
        return home
    end
    ssh.start_reason = function()
        return reason
    end
    local ok, err = pcall(fn, home, project_dir, request_file)
    ssh.home, ssh.start_reason = saved.home, saved.start_reason
    vim.api.nvim_set_current_dir(saved.cwd)
    if not ok then
        error(err, 0)
    end
end

--- A request for the sandbox project directory.
---@param name string|nil
---@return fun(project_dir: string): string
local function request_for(name)
    return function(project_dir)
        return vim.json.encode({ version = 1, path = project_dir, name = name })
    end
end

it("the request is looked for where the local side wrote it", function()
    remote("remote-ssh", nil, function(home)
        eq(home .. "/" .. DIR .. "/request.json", ssh.request_path())
    end)
end)

it("a project this server already knows is entered, not duplicated, and the request is deleted", function()
    remote("remote-ssh", request_for("site"), function(_, project_dir, request_file)
        local s = store({ { id = 1, name = "old-name", path = project_dir .. "/" } })
        eq({ true }, { ssh.apply_request(s.deps) })
        eq(project_dir, vim.uv.cwd())
        eq(1, #s.rows, "no second row")
        eq("old-name", s.rows[1].name, "the server's own name is kept")
        eq(nil, vim.uv.fs_stat(request_file), "the request is used once")
    end)
end)

it("a project this server has never seen is created with the requested name", function()
    remote("remote-ssh", request_for("site"), function(_, project_dir, request_file)
        local s = store()
        eq({ true }, { ssh.apply_request(s.deps) })
        eq(project_dir, vim.uv.cwd())
        eq({ { id = 1, name = "site", path = project_dir .. "/" } }, s.rows, "stored the way the cwd lookup matches")
        eq(nil, vim.uv.fs_stat(request_file))
    end)
end)

it("a requested name that another project already has is made unique", function()
    remote("remote-ssh", request_for("site"), function(_, project_dir)
        local s = store({ { id = 1, name = "site", path = "/elsewhere/" }, { id = 2, name = "site-2", path = "/b/" } })
        eq({ true }, { ssh.apply_request(s.deps) })
        eq({ id = 3, name = "site-3", path = project_dir .. "/" }, s.rows[3])
    end)
end)

it("a request without a name falls back to the directory name", function()
    remote("remote-ssh", request_for(nil), function()
        local s = store()
        eq({ true }, { ssh.apply_request(s.deps) })
        eq("site", s.rows[1].name)
    end)
end)

it("no request: nothing happens", function()
    remote("remote-ssh", nil, function()
        local s = store()
        local cwd = vim.uv.cwd()
        eq({ false }, { ssh.apply_request(s.deps) })
        eq(cwd, vim.uv.cwd())
        eq({}, s.rows)
    end)
end)

it("an ordinary start ignores a request and leaves it alone", function()
    remote("normal", request_for("site"), function(_, _, request_file)
        local s = store()
        local cwd = vim.uv.cwd()
        eq({ false }, { ssh.apply_request(s.deps) })
        eq(cwd, vim.uv.cwd())
        eq({}, s.rows)
        truthy(vim.uv.fs_stat(request_file), "only a remote-ssh start may consume it")
    end)
end)

it("a request for a directory that is not there changes nothing, says why, and is deleted", function()
    remote(
        "remote-ssh",
        vim.json.encode({ version = 1, path = "/no/such/dir/anywhere", name = "x" }),
        function(_, _, file)
            local s = store()
            local cwd = vim.uv.cwd()
            eq({ false, "DIRECTORY_NOT_FOUND", "/no/such/dir/anywhere" }, { ssh.apply_request(s.deps) })
            eq(cwd, vim.uv.cwd())
            eq({}, s.rows)
            eq(nil, vim.uv.fs_stat(file))
        end
    )
end)

it("the client's address travels with the request, for Quit to go back there", function()
    local request = function(project_dir)
        return vim.json.encode({ version = 1, path = project_dir, name = "site", client = "/run/user/1000/nvim.1.0" })
    end
    remote("remote-ssh", request, function()
        vim.g.lvim_remote_client = nil
        local s = store()
        eq({ true }, { ssh.apply_request(s.deps) })
        eq("/run/user/1000/nvim.1.0", vim.g.lvim_remote_client)
        vim.g.lvim_remote_client = nil
    end)
end)

it("a request that cannot be understood is discarded", function()
    for _, raw in ipairs({ "not json", "[]", '{"path":"relative/dir"}', '{"name":"x"}', "" }) do
        remote("remote-ssh", raw, function(_, _, file)
            local s = store()
            eq({ false }, { ssh.apply_request(s.deps) }, raw)
            eq({}, s.rows)
            eq(nil, vim.uv.fs_stat(file), "discarded: " .. raw)
        end)
    end
end)

it("this Neovim reports a start reason that is not remote-ssh, so the suite itself is a normal start", function()
    truthy(ssh.start_reason() ~= "remote-ssh")
    eq(nil, ssh.take_request())
end)

describe("lvim-space ssh: local projects are untouched")

it("a local path is never taken for a remote one", function()
    for _, path in ipairs({
        "/srv/app/",
        "~/work",
        "./ssh://x",
        "/home/me/ssh:/box",
        "sshfs://box/x",
        "",
        "SSH://box/x",
    }) do
        eq(false, ssh.is_remote(path), path)
    end
    eq(false, ssh.is_remote(nil))
    eq(true, ssh.is_remote("ssh://box/srv"))
end)

-- The rest needs the real store. sqlite.lua is a declared dependency that is not installed where the suite
-- usually runs; when it is, the same flows are driven through the real data layer and the projects panel.
local has_sqlite = pcall(require, "sqlite.db")

--- Open the real database inside the sandbox.
---@return table data, table db
local function real_store()
    local config = require("lvim-space.config")
    config.save = sandbox .. "/store"
    local db = require("lvim-space.persistence.db")
    truthy(db.init(), "the sandbox database opens")
    truthy(vim.startswith(vim.fn.expand(config.save), sandbox), "inside the sandbox")
    return require("lvim-space.api.data"), db
end

if not has_sqlite then
    skip("local and remote projects side by side in the real store", "needs sqlite.lua, which is not installed here")
    skip("the remote side against the real store", "needs sqlite.lua, which is not installed here")
else
    it("local and remote projects side by side in the real store", function()
        local data = real_store()
        local local_dir = vim.uv.fs_realpath(sandbox) .. "/local-project"
        vim.fn.mkdir(local_dir, "p")

        truthy(data.add_project(local_dir .. "/", "local-one"), "a local project is added as before")
        local uri = assert(ssh.validate("ssh://me@box/srv/app/", data.is_project_path_exist))
        truthy(data.add_project(uri, "remote-one"), "a remote project goes in the same column")
        eq({ nil, "PROJECT_PATH_EXIST" }, { ssh.validate("ssh://me@box/srv/app", data.is_project_path_exist) })

        local cwd = vim.uv.cwd()
        vim.api.nvim_set_current_dir(local_dir)
        local found = data.find_project_by_cwd()
        vim.api.nvim_set_current_dir(cwd)
        eq("local-one", found and found.name, "the cwd lookup still finds the local project")
        eq("remote-one", data.find_project_by_path(uri).name)
    end)

    it("the remote side against the real store", function()
        local data = real_store()
        remote("remote-ssh", request_for("from-laptop"), function(_, project_dir)
            eq({ true }, {
                ssh.apply_request({
                    find_project_by_path = data.find_project_by_path,
                    is_project_name_exist = data.is_project_name_exist,
                    add_project = data.add_project,
                }),
            })
            local found = data.find_project_by_cwd()
            eq("from-laptop", found and found.name, "created, and found by the cwd lookup context loading uses")
            eq(project_dir .. "/", found.path)
        end)
    end)
end

describe("lvim-space ssh: checking the server before :connect")

--- A probe answer built from `HEALTHY` with some lines replaced or added.
---@param changes table<string, string|false>  key -> new value, or false to drop the line
---@return table
local function probe_with(changes)
    changes = vim.deepcopy(changes) -- it is consumed below; the caller's table stays as it was
    local lines = {}
    for line in HEALTHY:gmatch("[^\n]+") do
        local key = line:match("^([%w_]+)=")
        if changes[key] == nil then
            lines[#lines + 1] = line
        elseif changes[key] then
            lines[#lines + 1] = key .. "=" .. changes[key]
        end
        changes[key] = nil
    end
    for key, value in pairs(changes) do
        if value then
            lines[#lines + 1] = key .. "=" .. value
        end
    end
    return { code = 0, stdout = table.concat(lines, "\n") .. "\n", stderr = "" }
end

local function always_ok()
    return OK
end

it("assess: a healthy server blocks nothing and warns about nothing", function()
    local v = ssh.assess(ssh.parse_facts(HEALTHY))
    eq(nil, v.blocking)
    eq(nil, v.env)
    eq({}, v.warnings)
end)

it("assess: each blocking finding, in the order remote-ssh would trip over it", function()
    local function code(changes)
        local v = ssh.assess(ssh.parse_facts(probe_with(changes).stdout))
        return v.blocking and v.blocking.code
    end
    eq("SSH_REMOTE_PLATFORM", code({ os = "FreeBSD" }))
    eq("SSH_REMOTE_PLATFORM", code({ arch = "i686" }))
    eq("SSH_REMOTE_TMP", code({ tmp_ok = false }))
    eq("SSH_REMOTE_TOOLS", code({ has_curl = false }))
    eq(nil, code({ has_sha256sum = false, has_shasum = "1" }), "shasum stands in for sha256sum")
    eq(nil, code({ has_curl = false, installed = "1" }), "an installed release needs no download tools")
    eq(nil, code({ has_curl = false, has_nvim = "1" }), "nor does an nvim on PATH")
    eq("SSH_REMOTE_RUNTIME_DIR", code({ runtime_dir_missing = "/run/user/9", shell = "fish" }), "fish: not fixable")
    local v =
        ssh.assess(ssh.parse_facts(probe_with({ has_curl = false, has_tar = false, has_sha256sum = false }).stdout))
    eq("curl, tar, sha256sum", v.blocking.detail, "every missing tool is named")
end)

it("assess: a missing runtime dir under bash or zsh goes into that shell's own startup file", function()
    local v = ssh.assess(ssh.parse_facts(probe_with({ runtime_dir_missing = "/run/user/2018" }).stdout))
    eq(".bashrc", v.env.rc)
    eq({ { kind = "runtime_dir", what = "/run/user/2018", lines = { ssh.RUNTIME_DIR_LINE } } }, v.env.changes)
    v = ssh.assess(ssh.parse_facts(probe_with({ runtime_dir_missing = "/run/user/2018", shell = "zsh" }).stdout))
    eq(".zshenv", v.env.rc)
end)

--- The node / python lines of a CloudLinux host: every alt version, on PATH none of them.
local ALT = {
    has_node = false,
    has_npm = false,
    has_python3 = false,
    has_venv = false,
}
local ALT_LINES = table.concat({
    "node_candidate=v16.20.2 /opt/alt/alt-nodejs16/root/usr/bin",
    "node_candidate=v22.23.4 /opt/alt/alt-nodejs22/root/usr/bin",
    "node_candidate=v23.1.0 /opt/alt/alt-nodejs23/root/usr/bin",
    "node_candidate=v24.22.2 /opt/alt/alt-nodejs24/root/usr/bin",
    "python_candidate=3.8.18 /opt/alt/python38/bin",
    "python_candidate=3.11.9 /opt/alt/python311/bin",
    "python_candidate=3.9.21 /opt/alt/python39/bin",
}, "\n")

--- `probe_with(changes)` plus the candidate lines.
local function alt_probe(changes)
    local p = probe_with(vim.tbl_extend("force", vim.deepcopy(ALT), changes or {}))
    p.stdout = p.stdout .. ALT_LINES .. "\n"
    return p
end

it("assess: runtimes off PATH are found and the newest suitable one is put on it", function()
    local v = ssh.assess(ssh.parse_facts(alt_probe().stdout))
    eq(nil, v.blocking)
    eq(".bashrc", v.env.rc)
    eq(
        { "node", "python" },
        vim.tbl_map(function(c)
            return c.kind
        end, v.env.changes)
    )
    eq({ ssh.path_line("/opt/alt/alt-nodejs24/root/usr/bin"), "export PATH" }, v.env.changes[1].lines, "newest LTS")
    eq({ ssh.path_line("/opt/alt/python311/bin"), "export PATH" }, v.env.changes[2].lines, "newest 3.x from 3.9")
end)

it("assess: picking runtimes", function()
    local function c(v, dir)
        return { version = v, dir = dir }
    end
    eq(
        "/b",
        ssh.pick_node({ c({ 22, 1 }, "/a"), c({ 24, 0 }, "/b"), c({ 25, 3 }, "/c") }).dir,
        "an LTS over a newer odd line"
    )
    eq("/c", ssh.pick_node({ c({ 19, 0 }, "/c"), c({ 16, 9 }, "/d") }).dir, "no LTS from 18 up: the newest from 18 up")
    eq(nil, ssh.pick_node({ c({ 16, 0 }, "/d") }), "nothing new enough")
    eq(nil, ssh.pick_python({ c({ 3, 8, 1 }, "/p") }), "3.8 is too old")
    eq("/q", ssh.pick_python({ c({ 3, 9, 1 }, "/p"), c({ 3, 12, 0 }, "/q") }).dir)
end)

it("assess: a missing runtime with nothing to offer only warns", function()
    local v = ssh.assess(ssh.parse_facts(probe_with(ALT).stdout))
    eq(nil, v.blocking)
    eq(nil, v.env)
    eq({ { code = "SSH_REMOTE_NO_NODE" }, { code = "SSH_REMOTE_NO_PYTHON" } }, v.warnings)
end)

it("assess: a runtime off PATH under a shell lvim-space cannot configure is named, not changed", function()
    local v = ssh.assess(ssh.parse_facts(alt_probe({ shell = "fish" }).stdout))
    eq(nil, v.env)
    eq("SSH_REMOTE_ENV_MANUAL", v.warnings[1].code)
    truthy(v.warnings[1].detail:find("/opt/alt/alt-nodejs24/root/usr/bin", 1, true))
end)

it("parse_facts: a candidate whose directory is not plain is ignored", function()
    local f = ssh.parse_facts(
        "node_candidate=v22.1.0 /opt/x;rm -rf ~\nnode_candidate=v22.1.0 /opt/a'b\n"
            .. "node_candidate=v22.1.0 relative/bin\nnode_candidate=v22.1.0 /ok/bin\n"
    )
    eq({ { version = { 22, 1, 0 }, dir = "/ok/bin" } }, f.node_candidates)
end)

it("a healthy server: write, probe, connect", function()
    local _, outcome, f = open(PROJECT, "key", { run = always_ok })
    eq({ "write", "probe", "connect" }, f.log)
    eq(batch({ "-p", "2222", "--", "deploy@box.example", ssh.PROBE_CMD }), f.probes[1].argv)
    eq(ssh.PROBE_SCRIPT, f.probes[1].stdin, "the probe travels on stdin")
    eq({ ok = true }, outcome)
end)

it("a blocking finding withdraws the request and never connects", function()
    local _, outcome, f = open(PROJECT, "key", {
        run = always_ok,
        probe = function()
            return probe_with({ tmp_ok = false })
        end,
    })
    eq({ "write", "probe", "clear" }, f.log)
    eq({ ok = false, code = "SSH_REMOTE_TMP", detail = "/tmp" }, outcome)
end)

it("a probe that fails is reported, and the request withdrawn", function()
    local _, outcome, f = open(PROJECT, "key", {
        run = always_ok,
        probe = function()
            return { code = 1, stdout = "", stderr = "sh: not found\n" }
        end,
    })
    eq({ "write", "probe", "clear" }, f.log)
    eq({ ok = false, code = "SSH_PROBE_FAILED", detail = "sh: not found" }, outcome)
end)

it("environment needed, user agrees: one question, one block, probe again, connect", function()
    local _, outcome, f = open(PROJECT, "key", {
        run = always_ok,
        confirm = true,
        probe = function(n)
            return n == 1 and alt_probe({ runtime_dir_missing = "/run/user/2018" }) or probe_with({})
        end,
    })
    eq({ "write", "probe", "confirm", "fix", "probe", "connect" }, f.log)
    local q = f.questions[1]
    truthy(q:find("/run/user/2018", 1, true), "the question names the runtime dir")
    truthy(q:find("node 24.22.2", 1, true), "the node it puts on PATH")
    truthy(q:find("python 3.11.9", 1, true), "and the python")
    truthy(q:find("~/.bashrc", 1, true), "and the file it changes")
    eq(batch({ "-p", "2222", "--", "deploy@box.example", "sh -s lvim-space-fix .bashrc" }), f.fixes[1].argv)
    eq(ssh.FIX_SCRIPT .. table.concat({
        ssh.RUNTIME_DIR_LINE,
        ssh.path_line("/opt/alt/alt-nodejs24/root/usr/bin"),
        "export PATH",
        ssh.path_line("/opt/alt/python311/bin"),
        "export PATH",
    }, "\n") .. "\n", f.fixes[1].stdin, "the script, then the lines as data")
    eq({ ok = true }, outcome)
end)

it("missing runtime dir, user declines: nothing on the server changes, nothing connects", function()
    local _, outcome, f = open(PROJECT, "key", {
        run = always_ok,
        confirm = false,
        probe = function()
            return probe_with({ runtime_dir_missing = "/run/user/2018" })
        end,
    })
    eq({ "write", "probe", "confirm", "clear" }, f.log)
    eq({ ok = false, code = "SSH_REMOTE_RUNTIME_DIR", detail = "/run/user/2018" }, outcome)
end)

it("only runtimes needed, user declines: it connects anyway, and warns what will not install", function()
    local _, outcome, f, warnings = open(PROJECT, "key", {
        run = always_ok,
        confirm = false,
        probe = function()
            return alt_probe()
        end,
    })
    eq({ "write", "probe", "confirm", "connect" }, f.log)
    eq(
        { "SSH_REMOTE_NO_NODE", "SSH_REMOTE_NO_PYTHON" },
        vim.tbl_map(function(w)
            return w.code
        end, warnings)
    )
    eq(true, outcome.ok)
end)

it("fix_environment = always writes without asking; never reports without asking", function()
    local probe = function(n)
        return n == 1 and probe_with({ runtime_dir_missing = "/run/user/2018" }) or probe_with({})
    end
    local _, outcome, f = open(PROJECT, "key", { run = always_ok, probe = probe }, { fix_environment = "always" })
    eq({ "write", "probe", "fix", "probe", "connect" }, f.log)
    eq(true, outcome.ok)
    _, outcome, f = open(PROJECT, "key", { run = always_ok, probe = probe }, { fix_environment = "never" })
    eq({ "write", "probe", "clear" }, f.log)
    eq("SSH_REMOTE_RUNTIME_DIR", outcome.code)
end)

it("a block the shell does not read stops after the second probe instead of looping", function()
    local _, outcome, f = open(PROJECT, "key", {
        run = always_ok,
        confirm = true,
        probe = function()
            return alt_probe()
        end,
    })
    eq({ "write", "probe", "confirm", "fix", "probe", "clear" }, f.log)
    eq("SSH_REMOTE_RC_NOT_READ", outcome.code)
end)

it("a failed fix is reported and nothing connects", function()
    local _, outcome, f = open(PROJECT, "key", {
        run = always_ok,
        confirm = true,
        probe = function()
            return probe_with({ runtime_dir_missing = "/run/user/2018" })
        end,
        fix = function()
            return { code = 1, stdout = "", stderr = "Permission denied\n" }
        end,
    })
    eq({ "write", "probe", "confirm", "fix", "clear" }, f.log)
    eq({ ok = false, code = "SSH_REMOTE_FIX_FAILED", detail = "Permission denied" }, outcome)
end)

it("lvim-space missing or old on the server warns, and still connects", function()
    for _, state in ipairs({ "none", "old" }) do
        local _, outcome, f, warnings = open(PROJECT, "key", {
            run = always_ok,
            probe = function()
                return probe_with({ plugin = state })
            end,
        })
        eq({ "write", "probe", "connect" }, f.log)
        eq({ { code = "SSH_REMOTE_PLUGIN_" .. state:upper() } }, warnings)
        eq(true, outcome.ok)
    end
end)

describe("lvim-space ssh: the remote scripts, run by a real sh")

--- Run `script` with `sh -s <args>` in a throwaway HOME; returns stdout, exit code, HOME.
---@param script string
---@param args string[]
---@param env table|nil
---@param home string|nil
local function sh(script, args, env, home)
    home = home or vim.fn.tempname()
    vim.fn.mkdir(home, "p")
    local argv = vim.list_extend({ "sh", "-s" }, args)
    local res = vim.system(argv, {
        stdin = script,
        text = true,
        env = vim.tbl_extend("force", { HOME = home, SHELL = "/bin/bash" }, env or {}),
        clear_env = true,
    }):wait()
    return res.stdout, res.code, home
end

it("the probe reports what it sees and changes nothing", function()
    local out, code, home = sh(ssh.PROBE_SCRIPT, { "lvim-space-probe" }, {
        PATH = vim.env.PATH,
        XDG_RUNTIME_DIR = "/nonexistent/run/user/1",
    })
    eq(0, code)
    local f = ssh.parse_facts(out)
    truthy(f.os and f.arch, "platform")
    eq("bash", f.shell)
    eq("/nonexistent/run/user/1", f.runtime_dir_missing)
    eq("none", f.plugin)
    eq({}, vim.fn.readdir(home), "HOME is left as it was")

    vim.fn.mkdir(home .. "/.local/share/nvim-remote/site/pack/core/opt/lvim-space/lua/lvim-space/core", "p")
    eq("old", ssh.parse_facts((sh(ssh.PROBE_SCRIPT, { "x" }, { PATH = vim.env.PATH }, home))).plugin)
    vim.fn.writefile({}, home .. "/.local/share/nvim-remote/site/pack/core/opt/lvim-space/lua/lvim-space/core/ssh.lua")
    eq("ssh", ssh.parse_facts((sh(ssh.PROBE_SCRIPT, { "x" }, { PATH = vim.env.PATH }, home))).plugin)
    local present =
        ssh.parse_facts((sh(ssh.PROBE_SCRIPT, { "x" }, { PATH = vim.env.PATH, XDG_RUNTIME_DIR = home }, home)))
    eq(nil, present.runtime_dir_missing, "an existing runtime dir is not reported")
end)

it("the probe finds a runtime off PATH where nvm keeps it", function()
    local home = vim.fn.tempname()
    local bin = home .. "/.nvm/versions/node/v22.4.1/bin"
    vim.fn.mkdir(bin, "p")
    for _, tool in ipairs({ "node", "npm" }) do
        vim.fn.writefile({ "#!/bin/sh", "echo v22.4.1" }, bin .. "/" .. tool)
        vim.uv.fs_chmod(bin .. "/" .. tool, tonumber("755", 8))
    end
    local f = ssh.parse_facts((sh(ssh.PROBE_SCRIPT, { "x" }, { PATH = "/usr/bin:/bin" }, home)))
    eq({ { version = { 22, 4, 1 }, dir = bin } }, f.node_candidates)
end)

--- Run the fix as the local side sends it: the script, then `lines` as data.
local function fix(home, rc, lines)
    local _, code = sh(ssh.FIX_SCRIPT .. table.concat(lines, "\n") .. "\n", { "lvim-space-fix", rc }, {
        PATH = vim.env.PATH,
    }, home)
    return code
end

it("the fix writes one block at the top, merges later lines into it, keeps the file", function()
    local home = vim.fn.tempname()
    vim.fn.mkdir(home, "p")
    local rc = home .. "/.bashrc"
    vim.fn.writefile({ "# existing", '[ -z "$PS1" ] && return', "alias ll='ls -l'" }, rc)
    vim.uv.fs_chmod(rc, tonumber("640", 8))
    local nodebin = home .. "/node/bin"
    vim.fn.mkdir(nodebin, "p")
    vim.fn.writefile({ "#!/bin/sh", "echo node-here" }, nodebin .. "/node")
    vim.uv.fs_chmod(nodebin .. "/node", tonumber("755", 8))

    eq(0, fix(home, ".bashrc", { ssh.RUNTIME_DIR_LINE }))
    eq(0, fix(home, ".bashrc", { ssh.path_line(nodebin), "export PATH" }))
    eq(0, fix(home, ".bashrc", { ssh.RUNTIME_DIR_LINE, ssh.path_line(nodebin), "export PATH" }), "again: no change")

    local lines = vim.fn.readfile(rc)
    eq(ssh.ENV_MARKER, lines[1], "at the very top, before any early return")
    local count = function(text)
        return #vim.tbl_filter(function(l)
            return l == text
        end, lines)
    end
    eq(1, count(ssh.ENV_MARKER), "one block")
    eq(1, count(ssh.RUNTIME_DIR_LINE), "each line once")
    eq(1, count(ssh.path_line(nodebin)))
    eq({ "# existing", '[ -z "$PS1" ] && return', "alias ll='ls -l'" }, vim.list_slice(lines, #lines - 2))
    eq("640", ("%o"):format(vim.uv.fs_stat(rc).mode % 512), "the mode is kept")
    eq(
        {},
        vim.tbl_filter(function(n)
            return n:find("^%.lvim%-space%-rc") ~= nil
        end, vim.fn.readdir(home)),
        "no temporary file left behind"
    )

    -- Sourcing the result, as a non-interactive login shell would.
    local probe = 'set +e; . "$HOME/.bashrc" 2>/dev/null; echo "x=${XDG_RUNTIME_DIR-unset}"; node; '
        .. '. "$HOME/.bashrc" 2>/dev/null; echo "$PATH" | tr ":" "\\n" | grep -c node/bin'
    local out = sh(probe, {}, { PATH = "/usr/bin:/bin", XDG_RUNTIME_DIR = "/nonexistent/x" }, home)
    eq("x=unset\nnode-here\n1\n", out, "dir unset, node found, PATH not grown by a second source")
    eq("x=" .. home .. "\n", (sh('set +e; . "$HOME/.bashrc" 2>/dev/null; echo "x=${XDG_RUNTIME_DIR-unset}"', {}, {
        PATH = "/usr/bin:/bin",
        XDG_RUNTIME_DIR = home,
    }, home)), "an existing runtime dir is kept")
end)

it("the fix folds the block an earlier version wrote into the current one", function()
    local home = vim.fn.tempname()
    vim.fn.mkdir(home, "p")
    vim.fn.writefile({
        ssh.FIX_MARKER,
        "# The jail exports XDG_RUNTIME_DIR without the directory; Neovim remote-ssh then cannot listen.",
        ssh.RUNTIME_DIR_LINE,
        "# <<< lvim-space <<<",
        "",
        "# user stuff",
    }, home .. "/.bashrc")
    eq(0, fix(home, ".bashrc", { ssh.path_line("/opt/alt/alt-nodejs24/root/usr/bin"), "export PATH" }))
    eq({
        ssh.ENV_MARKER,
        "# What Neovim remote-ssh, and the tools installed for it, need here. Managed by lvim-space.",
        ssh.RUNTIME_DIR_LINE,
        ssh.path_line("/opt/alt/alt-nodejs24/root/usr/bin"),
        "export PATH",
        "# <<< lvim-space <<<",
        "",
        "# user stuff",
    }, vim.fn.readfile(home .. "/.bashrc"))
end)

it("the fix creates the startup file when there is none", function()
    local home = vim.fn.tempname()
    vim.fn.mkdir(home, "p")
    eq(0, fix(home, ".zshenv", { ssh.RUNTIME_DIR_LINE }))
    eq(ssh.ENV_MARKER, vim.fn.readfile(home .. "/.zshenv")[1])
end)

describe("lvim-space ssh: mirroring the plugins before :connect")

--- A sync stand-in that records what it was asked and answers as scripted.
local function sync_stub(ok, err)
    local asked = {}
    return asked, function(uri, cb)
        asked[#asked + 1] = uri
        cb(ok, err)
    end
end

it("the plugins are mirrored after the request is written, then the server is checked", function()
    local asked, sync = sync_stub(true)
    local _, outcome, f = open(PROJECT, "key", { run = always_ok }, { sync = sync })
    eq({ "ssh://deploy@box.example:2222" }, asked, "the address :connect will use")
    eq({ "write", "probe", "connect" }, f.log)
    eq(true, outcome.ok)
end)

it("a failed mirror withdraws the request and never connects", function()
    local _, sync = sync_stub(false, "rsync is not installed on the server")
    local _, outcome, f = open(PROJECT, "key", { run = always_ok }, { sync = sync })
    eq({ "write", "clear" }, f.log)
    eq({ ok = false, code = "SSH_SYNC_FAILED", detail = "rsync is not installed on the server" }, outcome)
end)

it("after a mirror, the server's lvim-space is this one: no warning about an old copy", function()
    local _, sync = sync_stub(true)
    local _, outcome, _, warnings = open(PROJECT, "key", {
        run = always_ok,
        probe = function()
            return probe_with({ plugin = "old" })
        end,
    }, { sync = sync })
    eq({}, warnings)
    eq(true, outcome.ok)
end)

describe("lvim-space ssh: Neovim's own Connect? question")

--- run_connect with `vim.fn.confirm` and `:connect` replaced: returns what :connect saw `confirm` answer,
--- for the remote-ssh question and for another one, and what `confirm` is afterwards.
local function connect_with(answer)
    local saved_confirm, saved_cmd = vim.fn.confirm, vim.api.nvim_cmd
    local stub = function()
        return 3 -- what a user would pick
    end
    vim.fn.confirm = stub
    local seen = {}
    vim.api.nvim_cmd = function(cmd)
        eq("connect", cmd.cmd)
        seen.remote = vim.fn.confirm("This will install Nvim…", "Connect? &Yes\n&Update Nvim\n&No", 1, "Question")
        seen.other = vim.fn.confirm("Save changes?", "&Yes\n&No", 2)
        return ""
    end
    local ok, _, accepted = ssh.run_connect("ssh://box", answer)
    seen.accepted = accepted
    seen.after = vim.fn.confirm
    vim.fn.confirm, vim.api.nvim_cmd = saved_confirm, saved_cmd
    return ok, seen, stub
end

it("answered Yes only when asked to, and only that question, only during :connect", function()
    local ok, seen, stub = connect_with(true)
    eq(true, ok)
    eq(1, seen.remote, "remote-ssh's question: Yes")
    eq(3, seen.other, "any other question is the user's")
    eq(stub, seen.after, "confirm is restored")
    eq(true, seen.accepted)
    ok, seen = connect_with(false)
    eq(3, seen.remote, "not answering: the user is asked")
    eq(false, seen.accepted, "the user picked No (3): not accepted, so not remembered")
end)

it("the first successful connect to an address is remembered, so the next one is answered", function()
    local addr = "ssh://lvim-test-" .. vim.uv.hrtime()
    eq(false, ssh.known_host(addr))
    ssh.remember_host(addr)
    eq(true, ssh.known_host(addr))
    eq(false, ssh.known_host(addr .. "x"))
end)

it("open: confirm_connect decides whether :connect is answered", function()
    local saved = ssh.run_connect
    local answered = {}
    ssh.run_connect = function(addr, answer)
        answered[#answered + 1] = answer
        return true, nil, true
    end
    local ok, err = pcall(function()
        local proj = { name = "p", path = "ssh://lvim-fresh-" .. vim.uv.hrtime() .. "/srv" }
        open(proj, "key", { run = always_ok }, { confirm_connect = "first" })
        open(proj, "key", { run = always_ok }, { confirm_connect = "first" })
        open(proj, "key", { run = always_ok }, { confirm_connect = "always" })
        open(proj, "key", { run = always_ok }, { confirm_connect = "never" })
    end)
    ssh.run_connect = saved
    if not ok then
        error(err, 0)
    end
    eq({ false, true, false, true }, answered, "first: asked once; always: asked; never: answered")
end)

it("update_nvim answers Update Nvim, and plain Yes where a stable Neovim does not offer it", function()
    local saved_confirm, saved_cmd = vim.fn.confirm, vim.api.nvim_cmd
    local got = {}
    vim.fn.confirm = function()
        return 3
    end
    vim.api.nvim_cmd = function()
        got[#got + 1] = vim.fn.confirm("…", "Connect? &Yes\n&Update Nvim\n&No", 1)
        got[#got + 1] = vim.fn.confirm("…", "Connect? &Yes\n&No", 1)
        return ""
    end
    local _, _, accepted = ssh.run_connect("ssh://box", "update")
    vim.fn.confirm, vim.api.nvim_cmd = saved_confirm, saved_cmd
    eq({ 2, 1 }, got)
    eq(true, accepted)
end)

it("open with update_nvim connects with the update answer, whatever confirm_connect says", function()
    local saved = ssh.run_connect
    local answered
    ssh.run_connect = function(_, answer)
        answered = answer
        return true, nil, true
    end
    local ok, err = pcall(open, PROJECT, "key", { run = always_ok }, { update_nvim = true, confirm_connect = "always" })
    ssh.run_connect = saved
    if not ok then
        error(err, 0)
    end
    eq("update", answered)
end)
