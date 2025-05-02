local utils = require("cmp_go_deep.utils")
local gopls_requests = require("cmp_go_deep.gopls_requests")

---@class cmp_go_deep.Options
---@field public timeout_notifications boolean | nil -- whether to show timeout notifications. default: true
---@field public get_documentation_implementation "hover" | "regex" | nil -- how to get documentation. default: "hover"
---@field public get_package_name_implementation "treesitter" | "regex" | nil -- how to get package name\n(treesitter = slow but accurate | regex = fast but fails edge cases). default: "regex"
---@field public exclude_vendored_packages boolean | nil -- whether to exclude vendored packages. default: false
---@field public documentation_wait_timeout_ms integer | nil -- maximum time (in milliseconds) to wait for fetching documentation. default: 100
---@field public workspace_symbol_timeout_ms integer | nil -- maximum time (in milliseconds) to wait for workspace/symbols before defaulting to cached results. default: 150
---@field public debounce_ms integer | nil -- time to wait before "locking-in" the current request and sending it to gopls. default: 350.
---@field public db_path string | nil -- where to store the sqlite db. default: ~/.local/share/nvim/cmp_go_deep.sqlite3
---@field public db_size_limit_bytes number | nil -- max db size in bytes. default: 200MB
---@field public debug boolean | nil -- whether to enable debug logging. default: false

---@type cmp_go_deep.Options
local default_options = {
	timeout_notifications = true,
	get_documentation_implementation = "hover",
	get_package_name_implementation = "regex",
	exclude_vendored_packages = false,
	documentation_wait_timeout_ms = 100,
	workspace_symbol_timeout_ms = 150,
	debounce_ms = 350,
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
	return { "." }
end

source.complete = function(_, params, callback)
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

	if not gopls_requests.debounced_request then
		gopls_requests.debounced_request = utils.debounce(gopls_requests.workspace_symbols, opts.debounce_ms)
	end

	local bufnr = vim.api.nvim_get_current_buf()
	vim.schedule(function()
		---@type cmp_go_deep.utils.request_state
		---TODO: return cached results upon cancellation
		local request_state = {
			cancelled = false,
		}
		gopls_requests.debounced_request(
			request_state,
			opts,
			source.cache,
			utils.get_gopls_client(),
			callback,
			bufnr,
			utils
		)

		vim.wait(opts.debounce_ms, function()
			return not request_state.cancelled
		end)
	end)
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
