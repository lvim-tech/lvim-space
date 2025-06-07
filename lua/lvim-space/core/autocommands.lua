local api = vim.api
local db = require("lvim-space.persistence.db")
local session = require("lvim-space.core.session")
local state = require("lvim-space.api.state")
local data = require("lvim-space.api.data")
local log = require("lvim-space.api.log")
local notify = require("lvim-space.api.notify")

local M = {}

local CONFIG = {
    autocommand_group = "LvimSpaceAutocommands",
    initialization_timeout = 500,
    save_timeout = 1000,
    retry_attempts = 3,
    retry_delay = 100,
}

local cache = {
    initialization_state = {
        db_initialized = false,
        session_initialized = false,
        context_loaded = false,
        initialization_time = nil,
    },
    stats = {
        successful_saves = 0,
        failed_saves = 0,
        context_reloads = 0,
        initialization_attempts = 0,
    },
    timers = {
        initialization_timer = nil,
        save_timer = nil,
    },
    flags = {
        is_initializing = false,
        is_saving = false,
        cleanup_started = false,
    },
}

local function clear_timer(timer_name)
    if cache.timers[timer_name] then
        vim.fn.timer_stop(cache.timers[timer_name])
        cache.timers[timer_name] = nil
    end
end

local function create_timeout_timer(timeout_ms, callback, description)
    return vim.fn.timer_start(timeout_ms, function()
        log.warn(string.format("Timeout reached for: %s", description))
        callback()
    end)
end

local function async_retry(func, description, max_attempts, delay_ms)
    max_attempts = max_attempts or CONFIG.retry_attempts
    delay_ms = delay_ms or CONFIG.retry_delay

    local attempt = 1

    local function try_execute()
        local success, result = pcall(func)

        if success and result then
            log.info(string.format("%s: Success on attempt %d/%d", description, attempt, max_attempts))
            return true
        end

        if attempt >= max_attempts then
            log.error(string.format("%s: Failed after %d attempts", description, max_attempts))
            return false
        end

        log.warn(
            string.format("%s: Attempt %d/%d failed, retrying in %dms", description, attempt, max_attempts, delay_ms)
        )

        attempt = attempt + 1
        vim.defer_fn(try_execute, delay_ms)
        return nil
    end

    return try_execute()
end

local function load_initial_context_state()
    if cache.flags.is_initializing then
        log.warn("load_initial_context_state: Already initializing, skipping")
        return false
    end

    log.info("load_initial_context_state: Starting initial context loading")

    state.project_id = nil
    state.workspace_id = nil
    state.tab_active = nil
    state.tab_ids = {}

    local function load_context()
        local current_project = data.find_project_by_cwd()
        if not current_project then
            log.info("No project found for current directory, context remains empty")
            cache.initialization_state.context_loaded = false
            return false
        end

        state.project_id = current_project.id
        cache.initialization_state.context_loaded = true

        log.info(string.format("Found project - ID: %s, Name: %s", state.project_id, current_project.name))

        cache.stats.context_reloads = cache.stats.context_reloads + 1
        return true
    end

    return async_retry(load_context, "Context loading", 2, 50)
end

local function initialize_database()
    if cache.initialization_state.db_initialized then
        log.info("initialize_database: Database already initialized")
        return true
    end

    log.info("initialize_database: Starting database initialization")

    local function init_db()
        local success = db.init()
        if not success then
            log.error("initialize_database: Database initialization failed")
            notify.error(state.lvim.FAILED_TO_INIT_DB)
            return false
        end

        cache.initialization_state.db_initialized = true
        log.info("initialize_database: Database initialized successfully")
        return true
    end

    return async_retry(init_db, "Database initialization")
end

local function initialize_session()
    if cache.initialization_state.session_initialized then
        log.info("initialize_session: Session already initialized")
        return true
    end

    log.info("initialize_session: Starting session manager initialization")

    if not session or not session.init then
        log.error("initialize_session: Session module not available")
        return false
    end

    local function init_session()
        local success, error_msg = pcall(session.init)
        if not success then
            log.error("initialize_session: Failed to initialize session: " .. tostring(error_msg))
            return false
        end

        cache.initialization_state.session_initialized = true
        log.info("initialize_session: Session manager initialized successfully")
        return true
    end

    return async_retry(init_session, "Session initialization")
end

local function save_current_session(force)
    if cache.flags.is_saving and not force then
        log.info("save_current_session: Save already in progress, skipping")
        return false
    end

    if cache.flags.cleanup_started then
        log.info("save_current_session: Cleanup started, skipping save")
        return false
    end

    cache.flags.is_saving = true

    if not force then
        clear_timer("save_timer")
        cache.timers.save_timer = vim.fn.timer_start(200, function()
            cache.timers.save_timer = nil
            save_current_session(true)
        end)
        cache.flags.is_saving = false
        return true
    end

    log.info("save_current_session: Starting session save procedure")

    local function perform_save()
        if not session or not session.save_current_state then
            log.warn("save_current_session: Session module or save function not available")
            return false
        end

        if not state.tab_active then
            log.info("save_current_session: No active tab to save")
            return false
        end

        log.info("save_current_session: Saving session for active tab ID: " .. tostring(state.tab_active))

        local success, error_msg = pcall(function()
            return session.save_current_state(state.tab_active, true)
        end)

        if not success then
            log.error("save_current_session: Failed to save session: " .. tostring(error_msg))
            notify.error(state.lvim.FAILED_TO_SAVE_SESSION)
            cache.stats.failed_saves = cache.stats.failed_saves + 1
            return false
        end

        cache.stats.successful_saves = cache.stats.successful_saves + 1
        log.info("save_current_session: Session saved successfully")
        return true
    end

    local timeout_timer = create_timeout_timer(CONFIG.save_timeout, function()
        cache.flags.is_saving = false
        log.error("save_current_session: Save operation timed out")
    end, "Session save")

    local result = async_retry(perform_save, "Session save", 2, 100)

    if timeout_timer then
        vim.fn.timer_stop(timeout_timer)
    end

    cache.flags.is_saving = false
    return result
end

local function cleanup_database()
    if cache.flags.cleanup_started then
        log.info("cleanup_database: Cleanup already in progress")
        return true
    end

    cache.flags.cleanup_started = true
    log.info("cleanup_database: Starting database cleanup")

    if not db or not db.close_db_connection then
        log.warn("cleanup_database: Database module or close function not available")
        return false
    end

    local function perform_cleanup()
        local success, error_msg = pcall(db.close_db_connection)
        if not success then
            log.error("cleanup_database: Failed to close database connection: " .. tostring(error_msg))
            notify.error(state.lvim.FAILED_TO_CLEANUP_DB)
            return false
        end

        cache.initialization_state.db_initialized = false
        log.info("cleanup_database: Database connection closed successfully")
        return true
    end

    return async_retry(perform_cleanup, "Database cleanup", 1, 0)
end

local function perform_initialization()
    if cache.flags.is_initializing then
        log.warn("perform_initialization: Initialization already in progress")
        return
    end

    cache.flags.is_initializing = true
    cache.stats.initialization_attempts = cache.stats.initialization_attempts + 1

    local start_time = vim.uv and vim.uv.now() or vim.loop.now()

    log.info("perform_initialization: Starting lvim-space initialization")

    local init_timeout = create_timeout_timer(CONFIG.initialization_timeout, function()
        cache.flags.is_initializing = false
        log.error("perform_initialization: Initialization timed out")
    end, "Full initialization")

    local init_steps = {
        { name = "Database", func = initialize_database },
        { name = "Context", func = load_initial_context_state },
        { name = "Session", func = initialize_session },
    }

    local function execute_step(step_index)
        if step_index > #init_steps then
            local end_time = vim.uv and vim.uv.now() or vim.loop.now()
            cache.initialization_state.initialization_time = end_time - start_time

            if init_timeout then
                vim.fn.timer_stop(init_timeout)
            end

            cache.flags.is_initializing = false
            log.info(
                string.format(
                    "perform_initialization: Completed in %.2fms",
                    cache.initialization_state.initialization_time / 1000
                )
            )
            return
        end

        local step = init_steps[step_index]
        log.info(string.format("perform_initialization: Executing step %d/%d: %s", step_index, #init_steps, step.name))

        vim.schedule(function()
            local success = step.func()
            if success ~= nil then
                if not success then
                    log.warn(string.format("perform_initialization: Step %s failed, continuing", step.name))
                end
                execute_step(step_index + 1)
            else
                vim.defer_fn(function()
                    execute_step(step_index + 1)
                end, 50)
            end
        end)
    end

    execute_step(1)
end

local function on_vim_enter()
    log.info("on_vim_enter: VimEnter event triggered")

    vim.schedule(function()
        perform_initialization()
    end)
end

local function on_vim_leave()
    log.info("on_vim_leave: Starting lvim-space cleanup procedures")

    for timer_name in pairs(cache.timers) do
        clear_timer(timer_name)
    end

    local session_saved = save_current_session(true)
    if not session_saved then
        log.info("on_vim_leave: Session save skipped or failed")
    end

    local db_cleanup = cleanup_database()
    if not db_cleanup then
        log.warn("on_vim_leave: Database cleanup failed")
    end

    log.info("on_vim_leave: lvim-space cleanup procedures completed")
end

local function setup_additional_autocommands(augroup)
    api.nvim_create_autocmd({ "FocusLost", "CursorHold" }, {
        group = augroup,
        pattern = "*",
        callback = function()
            if cache.initialization_state.session_initialized then
                save_current_session(false)
            end
        end,
        desc = "lvim-space: Auto-save session on focus lost or cursor hold",
    })

    api.nvim_create_autocmd("DirChanged", {
        group = augroup,
        pattern = "*",
        callback = function()
            log.info("DirChanged: Directory changed, reloading context")
            load_initial_context_state()
        end,
        desc = "lvim-space: Reload context on directory change",
    })

    api.nvim_create_autocmd("User", {
        group = augroup,
        pattern = "LvimSpaceHealthCheck",
        callback = function()
            M.health_check()
        end,
        desc = "lvim-space: Health check on user event",
    })
end

local function setup_user_commands()
    api.nvim_create_user_command("LvimSpaceSave", function()
        log.info("User command :LvimSpaceSave invoked")

        local ok = false
        local ok1, mod = pcall(require, "lvim-space.core.manual_save")
        if ok1 and mod and type(mod.save_all) == "function" then
            ok = mod.save_all()
        else
            ok = (M.force_save_session() == true)
        end
        if ok then
            notify.info("LvimSpace: State saved successfully.")
        else
            notify.error("LvimSpace: Failed to save state.")
        end
    end, { desc = "Manually save lvim-space state" })
end

M.init = function()
    log.info("autocommands.init: Setting up lvim-space autocommands")

    local augroup = api.nvim_create_augroup(CONFIG.autocommand_group, { clear = true })

    api.nvim_create_autocmd("VimEnter", {
        group = augroup,
        pattern = "*",
        callback = on_vim_enter,
        desc = "lvim-space: Main initialization on VimEnter",
    })

    api.nvim_create_autocmd("VimLeavePre", {
        group = augroup,
        pattern = "*",
        callback = on_vim_leave,
        desc = "lvim-space: Save session and cleanup on VimLeavePre",
    })

    setup_additional_autocommands(augroup)
    setup_user_commands()

    log.info("autocommands.init: lvim-space autocommands configured successfully")
end

M.reload_context = function()
    log.info("autocommands.reload_context: Manually reloading context")
    return load_initial_context_state()
end

M.force_save_session = function()
    log.info("autocommands.force_save_session: Manually saving current session")
    return save_current_session(true)
end

M.force_initialization = function()
    log.info("autocommands.force_initialization: Manually triggering initialization")
    cache.flags.is_initializing = false
    perform_initialization()
end

M.get_autocommand_group = function()
    return CONFIG.autocommand_group
end

M.get_stats = function()
    return {
        initialization_state = vim.deepcopy(cache.initialization_state),
        stats = vim.deepcopy(cache.stats),
        flags = vim.deepcopy(cache.flags),
        config = vim.deepcopy(CONFIG),
    }
end

M.get_initialization_state = function()
    return cache.initialization_state
end

M.is_fully_initialized = function()
    return cache.initialization_state.db_initialized
        and cache.initialization_state.session_initialized
        and not cache.flags.is_initializing
end

M.health_check = function()
    local health = {
        status = "healthy",
        issues = {},
        stats = M.get_stats(),
    }

    if not cache.initialization_state.db_initialized then
        table.insert(health.issues, "Database not initialized")
        health.status = "unhealthy"
    end

    if not cache.initialization_state.session_initialized then
        table.insert(health.issues, "Session not initialized")
        health.status = "unhealthy"
    end

    local save_failure_rate = cache.stats.failed_saves
        / math.max(1, cache.stats.successful_saves + cache.stats.failed_saves)

    if save_failure_rate > 0.1 then
        table.insert(health.issues, string.format("High save failure rate: %.1f%%", save_failure_rate * 100))
        health.status = "degraded"
    end

    if cache.flags.is_initializing and cache.initialization_state.initialization_time then
        local current_time = vim.uv and vim.uv.now() or vim.loop.now()
        if current_time - cache.initialization_state.initialization_time > 10000 then
            table.insert(health.issues, "Initialization stuck")
            health.status = "unhealthy"
        end
    end

    log.info(string.format("Health check completed: %s (%d issues)", health.status, #health.issues))
    return health
end

M.reset_state = function()
    log.warn("autocommands.reset_state: Resetting internal state (for debugging)")

    for timer_name in pairs(cache.timers) do
        clear_timer(timer_name)
    end

    cache.initialization_state = {
        db_initialized = false,
        session_initialized = false,
        context_loaded = false,
        initialization_time = nil,
    }

    cache.flags = {
        is_initializing = false,
        is_saving = false,
        cleanup_started = false,
    }

    log.info("autocommands.reset_state: State reset completed")
end

return M
