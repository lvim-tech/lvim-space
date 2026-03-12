-- lua/lvim-space/utils/file_system.lua
-- File system utilities

local fn = vim.fn

local M = {}

--- Validate file path
---@param path string Path to validate
---@return boolean True if path is valid
local function is_valid_path(path)
    return path and path ~= ""
end

--- Execute a file operation safely with pcall
---@param operation function Operation to execute
---@param ... any Arguments to pass to operation
---@return boolean success, any result, string|nil error message
local function safe_operation(operation, ...)
    local ok, result = pcall(operation, ...)
    if not ok then
        return false, nil, tostring(result)
    end
    return true, result, nil
end

--- Ensure directory exists for a given path
---@param path string Path to file
---@return boolean success, string|nil error message
function M.ensure_dir(path)
    if not is_valid_path(path) then
        return false, "Invalid path"
    end

    local dir = fn.fnamemodify(path, ":h")
    if dir == "" or dir == "." then
        return true, nil
    end

    local success, _, err = safe_operation(fn.mkdir, dir, "p")
    if not success then
        return false, string.format("Failed to create directory: %s", err)
    end

    return true, nil
end

--- Append a line to a file
---@param path string Path to file
---@param line string Line to append
---@return boolean success, string|nil error message
function M.append_line(path, line)
    if not is_valid_path(path) then
        return false, "Invalid path"
    end

    local dir_ok, dir_err = M.ensure_dir(path)
    if not dir_ok then
        return false, dir_err
    end

    -- Ensure line ends with newline
    if not line:match("\n$") then
        line = line .. "\n"
    end

    local write_success, _, write_err = safe_operation(function()
        local file = io.open(path, "a")
        if not file then
            error(string.format("Failed to open file: %s", path))
        end
        file:write(line)
        file:close()
    end)

    if not write_success then
        return false, string.format("Failed to write to file: %s", write_err)
    end

    return true, nil
end

--- Read all lines from a file
---@param path string Path to file
---@return table|nil lines, string|nil error message
function M.read_lines(path)
    if not is_valid_path(path) then
        return nil, "Invalid path"
    end

    local file, err = io.open(path, "r")
    if not file then
        return nil, string.format("Failed to open file: %s", err)
    end

    local lines = {}
    for line in file:lines() do
        table.insert(lines, line)
    end
    file:close()

    return lines, nil
end

--- Write lines to a file (overwrites existing content)
---@param path string Path to file
---@param lines table Array of lines to write
---@return boolean success, string|nil error message
function M.write_lines(path, lines)
    if not is_valid_path(path) then
        return false, "Invalid path"
    end

    if type(lines) ~= "table" then
        return false, "Lines must be a table"
    end

    local dir_ok, dir_err = M.ensure_dir(path)
    if not dir_ok then
        return false, dir_err
    end

    local write_success, _, write_err = safe_operation(function()
        local file = io.open(path, "w")
        if not file then
            error(string.format("Failed to open file for writing: %s", path))
        end

        for _, line in ipairs(lines) do
            file:write(line .. "\n")
        end
        file:close()
    end)

    if not write_success then
        return false, string.format("Failed to write to file: %s", write_err)
    end

    return true, nil
end

--- Check if file exists
---@param path string Path to file
---@return boolean
function M.file_exists(path)
    if not is_valid_path(path) then
        return false
    end

    local file = io.open(path, "r")
    if file then
        file:close()
        return true
    end
    return false
end

--- Get file size in bytes
---@param path string Path to file
---@return integer|nil size, string|nil error message
function M.file_size(path)
    if not is_valid_path(path) then
        return nil, "Invalid path"
    end

    if not M.file_exists(path) then
        return nil, "File does not exist"
    end

    local file, err = io.open(path, "r")
    if not file then
        return nil, string.format("Failed to open file: %s", err)
    end

    local size = file:seek("end")
    file:close()

    return size, nil
end

--- Get file modification time
---@param path string Path to file
---@return integer|nil timestamp, string|nil error message
function M.file_mtime(path)
    if not is_valid_path(path) then
        return nil, "Invalid path"
    end

    local uv = vim.uv or vim.loop
    local stat = uv.fs_stat(path)
    if not stat then
        return nil, "Failed to stat file"
    end

    return stat.mtime.sec, nil
end

--- Copy file
---@param src string Source path
---@param dst string Destination path
---@return boolean success, string|nil error message
function M.copy_file(src, dst)
    if not is_valid_path(src) or not is_valid_path(dst) then
        return false, "Invalid source or destination path"
    end

    if not M.file_exists(src) then
        return false, "Source file does not exist"
    end

    local dir_ok, dir_err = M.ensure_dir(dst)
    if not dir_ok then
        return false, string.format("Failed to create destination directory: %s", dir_err)
    end

    local src_content, read_err = M.read_lines(src)
    if not src_content then
        return false, string.format("Failed to read source file: %s", read_err)
    end

    local write_ok, write_err = M.write_lines(dst, src_content)
    if not write_ok then
        return false, string.format("Failed to write destination file: %s", write_err)
    end

    return true, nil
end

--- Move/rename file
---@param src string Source path
---@param dst string Destination path
---@return boolean success, string|nil error message
function M.move_file(src, dst)
    if not is_valid_path(src) or not is_valid_path(dst) then
        return false, "Invalid source or destination path"
    end

    if not M.file_exists(src) then
        return false, "Source file does not exist"
    end

    local dir_ok, dir_err = M.ensure_dir(dst)
    if not dir_ok then
        return false, string.format("Failed to create destination directory: %s", dir_err)
    end

    local move_success, _, move_err = safe_operation(os.rename, src, dst)
    if not move_success then
        return false, string.format("Failed to move file: %s", move_err)
    end

    return true, nil
end

--- Delete file
---@param path string Path to file
---@return boolean success, string|nil error message
function M.delete_file(path)
    if not is_valid_path(path) then
        return false, "Invalid path"
    end

    if not M.file_exists(path) then
        return false, "File does not exist"
    end

    local delete_success, _, delete_err = safe_operation(os.remove, path)
    if not delete_success then
        return false, string.format("Failed to delete file: %s", delete_err)
    end

    return true, nil
end

--- Get file extension
---@param path string Path to file
---@return string File extension or empty string
function M.file_extension(path)
    if not is_valid_path(path) then
        return ""
    end

    return fn.fnamemodify(path, ":e")
end

--- Get file name without extension
---@param path string Path to file
---@return string Base name or empty string
function M.file_basename(path)
    if not is_valid_path(path) then
        return ""
    end

    return fn.fnamemodify(path, ":t:r")
end

--- Get directory from path
---@param path string Path to file
---@return string Directory path or empty string
function M.file_dir(path)
    if not is_valid_path(path) then
        return ""
    end

    return fn.fnamemodify(path, ":h")
end

--- Create temporary file
---@param content string|nil Optional content to write
---@param extension string|nil File extension (default: "tmp")
---@return string|nil file_path, string|nil error message
function M.create_temp_file(content, extension)
    extension = extension or "tmp"

    local temp_dir = fn.tempname()
    local temp_file = string.format("%s.%s", temp_dir, extension)

    -- Remove the temporary directory created by tempname
    pcall(os.remove, temp_dir)

    if content then
        local ok, err = M.write_lines(temp_file, { content })
        if not ok then
            return nil, err
        end
    end

    return temp_file, nil
end

--- Find files recursively by pattern
---@param dir string Directory to search
---@param pattern string File pattern
---@return table files, string|nil error message
function M.find_files(dir, pattern)
    if not is_valid_path(dir) then
        return {}, "Invalid directory"
    end

    if not M.file_exists(dir) then
        return {}, "Directory does not exist"
    end

    local files = {}
    local find_success, _, find_err = safe_operation(function()
        local handle = io.popen(string.format('find "%s" -name "%s" -type f 2>/dev/null', dir, pattern))
        if handle then
            for line in handle:lines() do
                table.insert(files, line)
            end
            handle:close()
        end
    end)

    if not find_success then
        return {}, string.format("Failed to search files: %s", find_err)
    end

    return files, nil
end

--- Get plugin state file path
---@param file_name string File name
---@return string Full path to state file
function M.get_state_file(file_name)
    if not is_valid_path(file_name) then
        return ""
    end

    local state_dir = vim.fn.stdpath("state") .. "/lvim-space"
    vim.fn.mkdir(state_dir, "p")
    return state_dir .. "/" .. file_name
end

--- Read boolean from file (expects "true" or "false")
---@param path string Path to file
---@return boolean|nil value, string|nil error message
function M.read_bool(path)
    if not is_valid_path(path) then
        return nil, "Invalid path"
    end

    if not M.file_exists(path) then
        return nil, "File does not exist"
    end

    local lines, err = M.read_lines(path)
    if not lines then
        return nil, err
    end

    for _, line in ipairs(lines) do
        line = line:gsub("^%s*(.-)%s*$", "%1") -- Trim whitespace
        if line ~= "" then
            if line == "true" then
                return true, nil
            elseif line == "false" then
                return false, nil
            else
                return nil, string.format("Invalid boolean value: %s", line)
            end
        end
    end

    return nil, "File is empty"
end

--- Write boolean to file (writes "true" or "false")
---@param path string Path to file
---@param value boolean Boolean value
---@return boolean success, string|nil error message
function M.write_bool(path, value)
    if not is_valid_path(path) then
        return false, "Invalid path"
    end

    if type(value) ~= "boolean" then
        return false, "Value must be boolean"
    end

    local str = value and "true" or "false"
    return M.write_lines(path, { str })
end

--- Get or create boolean state file with default value
---@param filename string File name
---@param default_value boolean Default value (default: false)
---@return boolean|nil value, string|nil error message
function M.get_bool_state(filename, default_value)
    default_value = default_value or false

    if not is_valid_path(filename) then
        return nil, "Invalid filename"
    end

    local path = M.get_state_file(filename)

    if not M.file_exists(path) then
        local ok, err = M.write_bool(path, default_value)
        if not ok then
            return nil, err
        end
        return default_value, nil
    end

    local value, err = M.read_bool(path)
    if err then
        return nil, err
    end

    return value, nil
end

--- Calculate SHA256 hash of file content
---@param path string Path to file
---@return string|nil hash, string|nil error message
function M.file_hash(path)
    if not is_valid_path(path) then
        return nil, "Invalid path"
    end

    if not M.file_exists(path) then
        return nil, "File does not exist"
    end

    local lines, err = M.read_lines(path)
    if not lines then
        return nil, err
    end

    local content = table.concat(lines, "\n")
    return vim.fn.sha256(content), nil
end

--- Calculate hash of buffer content
---@param buf integer Buffer number
---@return string|nil hash, string|nil error message
function M.buffer_hash(buf)
    if not buf or buf == -1 or not vim.api.nvim_buf_is_valid(buf) then
        return nil, "Invalid buffer"
    end

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local content = table.concat(lines, "\n")
    return vim.fn.sha256(content), nil
end

--- Check if a directory path is readable and executable by the current user.
---@param path string Directory path
---@return boolean
function M.has_permission(path)
    local uv = vim.uv or vim.loop
    local stat = uv.fs_stat(path)
    if not stat or stat.type ~= "directory" then
        return false
    end
    return uv.fs_access(path, "r") and uv.fs_access(path, "x") or false
end

return M
