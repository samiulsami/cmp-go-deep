local utils = require("cmp_go_deep.utils")
local gopls_requests = require("cmp_go_deep.gopls_requests")

---@class cmp_go_deep.Options
---@field public timeout_notifications boolean | nil -- whether to show timeout notifications. default: true
---@field public get_documentation_implementation "hover" | "regex" | nil -- how to get documentation. default: "regex"
---@field public get_package_name_implementation "treesitter" | "regex" | nil -- how to get package name (treesitter = slow but accurate | regex = fast but fails edge cases). default: "regex"
---@field public exclude_vendored_packages boolean | nil -- whether to exclude vendored packages. default: false
---@field public documentation_wait_timeout_ms integer | nil -- maximum time (in milliseconds) to wait for fetching documentation. default: 100
---@field public debounce_gopls_requests_ms integer | nil -- time to wait before "locking-in" the current request and sending it to gopls. default: 100.
---@field public debounce_cache_requests_ms integer | nil -- time to wait before "locking-in" the current request and loading data from cache. default: 250
---@field public db_path string | nil -- where to store the sqlite db. default: ~/.local/share/nvim/cmp_go_deep.sqlite3
---@field public db_size_limit_bytes number | nil -- max db size in bytes. default: 200MB
---@field public debug boolean | nil -- whether to enable debug logging. default: false

---@type cmp_go_deep.Options
local default_options = {
	timeout_notifications = true,
	get_documentation_implementation = "regex",
	get_package_name_implementation = "regex",
	exclude_vendored_packages = false,
	documentation_wait_timeout_ms = 100,
	debounce_gopls_requests_ms = 100,
	debounce_cache_requests_ms = 250,
	db_path = vim.fn.stdpath("data") .. "/cmp_go_deep.sqlite3",
	db_size_limit_bytes = 200 * 1024 * 1024,
	debug = false,
}

local source = {}

source.new = function()
	return setmetatable({}, { __index = source })
end

source.is_available = function()
	if vim.bo.filetype ~= "go" or utils.get_gopls_client() == nil then
		return false
	end
	return true
end

source.get_trigger_characters = function()
	return {
		"^[^a-zA-Z_]",
		"%.",
	}
end

source.complete = function(_, params, callback)
	local gopls_client = utils.get_gopls_client()
	if not gopls_client then
		vim.notify("gopls client is nil", vim.log.levels.WARN)
		return callback({ items = {}, isIncomplete = false })
	end

	local opts = vim.deepcopy(default_options, false)
	local extend_non_nil = function(old, new)
		for k, v in pairs(new) do
			if v ~= nil then
				old[k] = v
			end
		end
		return old
	end
	opts = extend_non_nil(opts, params.option or {})
	---@type cmp_go_deep.Options
	opts = extend_non_nil(opts, params.opts or {})

	if not source.cache then
		source.cache = require("cmp_go_deep.db").setup(opts)
	end

	if not gopls_requests.debounced_cache_workspace_symbols then
		gopls_requests.debounced_cache_workspace_symbols =
			utils.debounce(gopls_requests.cache_workspace_symbols, opts.debounce_gopls_requests_ms)
	end

	if not utils.debounced_process_request then
		utils.debounced_process_request = utils.debounce(utils.process_request, opts.debounce_cache_requests_ms)
	end

	local bufnr = vim.api.nvim_get_current_buf()
	local project_path = vim.fn.getcwd()
	local cursor_prefix_word = utils.get_cursor_prefix_word(0)

	gopls_requests.debounced_cache_workspace_symbols(
		opts,
		source.cache,
		gopls_client,
		bufnr,
		project_path,
		cursor_prefix_word
	)

	utils.debounced_process_request(
		opts,
		bufnr,
		source.cache,
		callback,
		project_path,
		cursor_prefix_word,
		gopls_requests.gopls_max_item_limit
	)
end

---@param completion_item lsp.CompletionItem
---@param callback fun(completion_item: lsp.CompletionItem|nil)
function source:resolve(completion_item, callback)
	local symbol = completion_item.data

	if symbol == nil then
		vim.notify("Warning: symbol data is missing", vim.log.levels.WARN)
		return callback(nil)
	end

	if not type(symbol.location) == "table" then
		vim.notify("Warning: symbol location is missing", vim.log.levels.WARN)
		return callback(completion_item)
	end

	---@type lsp.Location
	local location = symbol.location
	if not location or not location.uri or not location.range then
		vim.notify("Warning: symbol location is missing", vim.log.levels.WARN)
		return callback(completion_item)
	end

	---@type cmp_go_deep.Options|nil
	local opts = symbol.opts
	if not opts then
		vim.notify("Warning: symbol data is missing options", vim.log.levels.WARN)
		return callback(completion_item)
	end

	vim.schedule(function()
		---@type string|nil
		local documentation = utils.get_documentation(opts, location.uri, location.range)
		completion_item.documentation = {
			kind = "markdown",
			value = documentation or "",
		}
		callback(completion_item)
	end)
end

---@param completion_item lsp.CompletionItem
---@param callback fun(completion_item: lsp.CompletionItem|nil)
function source:execute(completion_item, callback)
	local symbol = completion_item.data
	if not symbol then
		return
	end

	local import_path = symbol.containerName
	local package_name = symbol.package_alias

	if import_path and vim.bo.filetype == "go" then
		utils.add_import_statement(symbol.bufnr, package_name, import_path)
	else
		vim.notify("Import path not found", vim.log.levels.WARN)
	end

	callback(completion_item)
end

return source
