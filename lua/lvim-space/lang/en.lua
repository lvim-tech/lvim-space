return {
	-- UI
	INFO_LINE_PROJECTS = "➤ Press: [j] [k] | 󱁐 cwd 󰌑 project | [a]dd [r]ename [d]elete | [w]orkspaces [t]abs",
	INFO_LINE_PROJECTS_EMPTY = "➤ Press: [a]dd",
	INFO_LINE_WORKSPACES = "➤ Press: [j] [k] | 󰌑 workspace | [a]dd, [r]ename, [d]elete | [p]projects [t]abs",
	INFO_LINE_WORKSPACES_EMPTY = "➤ Press: [a]dd",
	INFO_LINE_TABS = "➤ Press: [j] [k] | 󰌑 tab | [a]dd, [r]ename, [d]elete | [p]projects [w]orkspaces",
	INFO_LINE_TABS_EMPTY = "➤ Press: [a]dd",
	INFO_LINE_FILES = "➤ Press: [j] [k] | 󰌑 tab | [a]dd, [r]ename, [d]elete | [p]projects [w]orkspaces",
	INFO_LINE_FILES_EMPTY = "➤ Press: [a]dd",
	PROJECTS = "Projects",
	PROJECT_PATH = "➤ Project path",
	PROJECT_NAME = "➤ Project name",
	PROJECT_NEW_NAME = "➤ Project new name",
	PROJECT_DELETE = "➤ Delete project '%s'? (y/n)",
	PROJECTS_EMPTY = "No projects added",
	WORKSPACES = "Workspaces",
	WORKSPACES_EMPTY = "No workspaces added",
	WORKSPACE_NAME = "➤ Workspace name",
	WORKSPACE_NEW_NAME = "➤ Workspace new name",
	WORKSPACE_DELETE = "➤ Delete workspace '%s'? (y/n)",
	TABS = "Tabs",
	TABS_EMPTY = "No tabs added",
	TAB_NAME = "➤ Tab name",
	TAB_NEW_NAME = "➤ Tab new name",
	TAB_DELETE = "➤ Delete tab '%s'? (y/n)",
	FILES = "Files",
	FILES_EMPTY = "No files added",
	FILES_NAME = "➤ File name",
	FILES_NEW_NAME = "➤ File new name",
	FILES_DELETE = "➤ Delete file '%s'? (y/n)",

	-- BASE
	FAILED_TO_CREATE_SAVE_DIRECTORY = "Failed to create the database file",

	-- DB
	FAILED_TO_CREATE_DB = "Failed to create the database",

	-- LOG
	CANNOT_OPEN_ERROR_LOG_FILE = "Cannot open error log file: ",

	-- PROJECTS
	PROJECT_NOT_ACTIVE = "No active project",
	PROJECT_ADD_FAILED = "Failed to add project",
	PROJECT_RENAME_FAILED = "Failed to rename project",
	PROJECT_DELETE_FAILED = "Failed to delete project",
	PROJECT_NAME_LEN = "The project name cannot be shorter than 3 characters",
	PROJECT_NAME_EXIST = "The project name cannot match the name of another project",
	PROJECT_PATH_EXIST = "The project path cannot match the name of another project",
	PROJECT_PATH_EMPTY = "The project path cannot be empty",
	-- PROJECTS DIRECTORY
	DIRECTORY_NOT_FOUND = "Directory not found",
	DIRECTORY_NOT_ACCESS = "Directory exists, but you do not have permission to access it",

	-- WORKSPACES
	WORKSPACE_NOT_ACTIVE = "No active workspace",
	WORKSPACE_NAME_LEN = "The workspace name cannot be shorter than 3 characters",
	WORKSPACE_NAME_EXIST = "The workspace name cannot match the name of another workspace",
	WORKSPACE_ADD_FAILED = "Failed to add workspace",
	WORKSPACE_RENAME_FAILED = "Failed to rename workspace",
	WORKSPACE_DELETE_FAILED = "Failed to delete workspace",

	-- TABS
	TAB_NOT_ACTIVE = "No active tab",
	TAB_NAME_LEN = "The tab name cannot be empty",
	TAB_NAME_EXIST = "The tab name cannot match the name of another tab",
	TAB_ADD_FAILED = "Failed to add tab",
	TAB_RENAME_FAILED = "Failed to rename tab",
	TAB_DELETE_FAILED = "Failed to delete tab",

	-- FILES
	FILE_NOT_ACTIVE = "No active file",
	FILE_PATH_LEN = "The file path cannot be empty",
	FILE_PATH_EXIST = "The file path cannot match the path of another file in this tab",
	FILE_ADD_FAILED = "Failed to add file",
	FILE_RENAME_FAILED = "Failed to rename file",
	FILE_DELETE_FAILED = "Failed to delete file",

	--

	DIRECTORY_NOT_ASSOCIATED_WITH_PROJECT = "The directory is not associated with any project",
	PROJECT_NOT_FOUND = "Project not found",

	FAILED_TO_OPEN_DATABASE_CONNECTION = "Failed to open database connection",
	SQLITE_NOT_FOUND_FALLBACK_JSON = "sqlite.lua not found – falling back to JSON files",
	UNABLE_TO_CREATE_DIRECTORY = "Unable to create directory: ",
	UNABLE_TO_CREATE_DATABASE_FILE = "Unable to create database file: ",
	ERROR_CREATING_TABLES = "Error creating tables: ",
	INSERT_BOOKMARK_FAILED = "Insert bookmark failed: ",
	BOOKMARK_INSERTED = "Bookmark '%s' (%s) inserted",
	UPDATE_BOOKMARK_FAILED = "Update bookmark failed: ",
	BOOKMARK_UPDATED = "Bookmark '%s' (%s) updated",
	GET_BOOKMARKS_FAILED = "Get bookmarks failed: ",
	DELETE_BOOKMARK_FAILED = "Delete bookmark failed: ",
	BOOKMARK_DELETED = "Bookmark '%s' deleted",
}
