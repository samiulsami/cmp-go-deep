local utils = require("cmp_go_deep.utils")
local gopls_requests = require("cmp_go_deep.gopls_requests")

---@class cmp_go_deep.Options
---@field public notifications boolean | nil -- whether to show notifications. default: true
---@field public get_documentation_implementation "hover" | "regex" | nil -- how to get documentation. default: "regex"
---@field public get_package_name_implementation "treesitter" | "regex" | nil -- how to get package name (treesitter = slow but accurate | regex = fast but fails edge cases). default: "regex"
---@field public exclude_vendored_packages boolean | nil -- whether to exclude vendored packages. default: false
---@field public documentation_wait_timeout_ms integer | nil -- maximum time (in milliseconds) to wait for fetching documentation. default: 100
---@field public debounce_gopls_requests_ms integer | nil -- time to wait before "locking-in" the current request and sending it to gopls. default: 350
---@field public debounce_cache_requests_ms integer | nil -- time to wait before "locking-in" the current request and loading data from cache. default: 50
---@field public db_path string | nil -- where to store the sqlite db. default: ~/.local/share/nvim/cmp_go_deep.sqlite3
---@field public db_size_limit_bytes number | nil -- max db size in bytes. default: 200MB
---@field public debug boolean | nil -- whether to enable debug logging. default: false

---@type cmp_go_deep.Options
local default_options = {
	notifications = true,
	get_documentation_implementation = "regex",
	get_package_name_implementation = "regex",
	exclude_vendored_packages = false,
	documentation_wait_timeout_ms = 100,
	debounce_gopls_requests_ms = 250,
	debounce_cache_requests_ms = 50,
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
	return { "[%w_]" }
end

source.complete = function(_, params, callback)
	local gopls_client = utils.get_gopls_client()
	if not gopls_client then
		return callback({ items = {}, isIncomplete = false })
	end

	local cursor_prefix_word = utils.get_cursor_prefix_word(0)
	if cursor_prefix_word:match("[%.]") or cursor_prefix_word:match("[^%w_]") then
		return callback({ items = {}, isIncomplete = false })
	end

	---@type cmp_go_deep.Options
	local opts = vim.tbl_deep_extend("force", default_options, params.option or params.opts or {})

	if not source.cache then
		source.cache = require("cmp_go_deep.db").setup(opts)
	end

	if not gopls_requests.debounced_workspace_symbols then
		gopls_requests.debounced_workspace_symbols =
			utils.debounce(gopls_requests.workspace_symbols, opts.debounce_gopls_requests_ms)
	end

	if not utils.debounced_process_symbols then
		utils.debounced_process_symbols = utils.debounce(utils.process_symbols, opts.debounce_cache_requests_ms)
	end

	---@type table<string, boolean>
	local processed_items = {}

	local bufnr = vim.api.nvim_get_current_buf()
	local project_path = vim.fn.getcwd()
	local vendor_path_prefix = "file://" .. project_path .. "/vendor/"
	local project_path_prefix = "file://" .. project_path .. "/"

	utils:debounced_process_symbols(
		opts,
		bufnr,
		callback,
		vendor_path_prefix,
		project_path_prefix,
		source.cache:load(cursor_prefix_word),
		processed_items,
		true
	)

	gopls_requests.debounced_workspace_symbols(opts, gopls_client, bufnr, cursor_prefix_word, function(result)
		if not result then
			return callback({ items = {}, isIncomplete = false })
		end

		local filtered_result = {}
		for _, symbol in ipairs(result) do
			if
				utils.symbol_to_completion_kind(symbol.kind)
				and symbol.name:match("^[A-Z]")
				and not symbol.location.uri:match("_test%.go$")
				and (#cursor_prefix_word > 2 or symbol.name:find(cursor_prefix_word, 1, true))
			then
				if string.sub(symbol.location.uri, 1, #vendor_path_prefix) == vendor_path_prefix then
					symbol.isVendored = true
					symbol.location.uri = symbol.location.uri:sub(#vendor_path_prefix + 1)
				elseif string.sub(symbol.location.uri, 1, #project_path_prefix) == project_path_prefix then
					symbol.isLocal = true
					symbol.location.uri = symbol.location.uri:sub(#project_path_prefix + 1)
				end
				table.insert(filtered_result, symbol)
			end
		end

		source.cache:save(utils, filtered_result)

		local toProcess = filtered_result
		if #cursor_prefix_word > 2 then
			toProcess = source.cache:load(cursor_prefix_word)
		end

		utils:debounced_process_symbols(
			opts,
			bufnr,
			callback,
			vendor_path_prefix,
			project_path_prefix,
			toProcess,
			processed_items,
			#result >= 100
		)
	end)
end

---@param completion_item lsp.CompletionItem
---@param callback fun(completion_item: lsp.CompletionItem|nil)
function source:resolve(completion_item, callback)
	local symbol = completion_item.data

	if symbol == nil then
		return callback(nil)
	end

	---@type cmp_go_deep.Options|nil
	local opts = symbol.opts
	if not opts then
		vim.notify("Warning: symbol data is missing options", vim.log.levels.WARN)
		return callback(completion_item)
	end

	if not type(symbol.location) == "table" then
		if opts.notifications then
			vim.notify("Warning: symbol location is missing", vim.log.levels.WARN)
		end
		return callback(completion_item)
	end

	---@type lsp.Location
	local location = symbol.location
	if not location or not location.uri or not location.range then
		if opts.notifications then
			vim.notify("Warning: symbol location is missing", vim.log.levels.WARN)
		end
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

	---@type cmp_go_deep.Options|nil
	local opts = symbol.opts
	if not opts then
		return
	end

	if import_path and vim.bo.filetype == "go" then
		utils.add_import_statement(opts, symbol.bufnr, package_name, import_path)
	elseif opts and opts.notifications then
		vim.notify("Import path not found", vim.log.levels.WARN)
	end

	callback(completion_item)
end

return source
