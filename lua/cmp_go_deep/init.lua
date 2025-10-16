local utils = require("cmp_go_deep.utils")
local gopls_requests = require("cmp_go_deep.gopls_requests")

---@class cmp_go_deep.Options
---@field public notifications boolean | nil whether to show notifications. default: true
---@field public matching_strategy "substring" | "fuzzy" | "substring_fuzzy_fallback" | nil how to match symbols. default: "substring_fuzzy_fallback"
---@field public filetypes string[] | nil filetypes to enable the source for
---@field public get_documentation_implementation "hover" | "regex" | nil how to get documentation. default: "regex"
---@field public get_package_name_implementation "treesitter" | "regex" | nil how to get package name (treesitter = slow but accurate | regex = fast but fails edge cases). default: "regex"
---@field public exclude_vendored_packages boolean | nil whether to exclude vendored packages. default: false
---@field public documentation_wait_timeout_ms integer | nil maximum time (in milliseconds) to wait for fetching documentation. default: 100
---@field public debounce_gopls_requests_ms integer | nil time to wait before "locking-in" the current request and sending it to gopls. default: 0
---@field public debounce_cache_requests_ms integer | nil time to wait before "locking-in" the current request and loading data from cache. default: 0
---@field public db_path string | nil where to store the sqlite db. default: ~/.local/share/nvim/cmp_go_deep.sqlite3
---@field public debug boolean | nil whether to enable debug logging. default: false

---@type cmp_go_deep.Options
local default_options = {
	notifications = true,
	matching_strategy = "substring_fuzzy_fallback",
	filetypes = { "go" },
	get_documentation_implementation = "regex",
	get_package_name_implementation = "regex",
	exclude_vendored_packages = false,
	documentation_wait_timeout_ms = 100,
	debounce_gopls_requests_ms = 0,
	debounce_cache_requests_ms = 0,
	db_path = vim.fn.stdpath("data") .. "/cmp_go_deep.sqlite3",
	debug = false,
}

local source = {}

source.new = function()
	return setmetatable({}, { __index = source })
end

source.is_available = function()
	local gopls_client = utils.get_gopls_client()
	if gopls_client == nil then
		return false
	end

	if not source.gopls_warmed_up then
		source.gopls_warmed_up = true
		vim.schedule(function()
			-- stylua: ignore
			gopls_requests.workspace_symbols(default_options, gopls_client, vim.api.nvim_get_current_buf(), "", function() end)
		end)
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

	---@type cmp_go_deep.Options
	source.opts = vim.tbl_deep_extend("force", default_options, params.option or params.opts or {})

	local allowed_filetype = false
	for _, key in pairs(source.opts.filetypes) do
		if vim.bo.filetype == key then
			allowed_filetype = true
			break
		end
	end
	if not allowed_filetype then
		return callback({ items = {}, isIncomplete = false })
	end

	local cursor_prefix_word = utils.get_cursor_prefix_word(0)
	if cursor_prefix_word:match("[%.]") or cursor_prefix_word:match("[^%w_]") then
		return callback({ items = {}, isIncomplete = false })
	end

	-- FIXME: Debounce doesn't work unless we make this callback here
	callback({ items = {}, isIncomplete = true })

	if not source.cache then
		source.cache = require("cmp_go_deep.db").setup(source.opts)
		if not source.cache then
			return callback({ items = {}, isIncomplete = false })
		end
	end

	if not gopls_requests.debounced_workspace_symbols then
		gopls_requests.debounced_workspace_symbols =
			utils.debounce(gopls_requests.workspace_symbols, source.opts.debounce_gopls_requests_ms)
	end

	if not utils.debounced_process_symbols then
		utils.debounced_process_symbols = utils.debounce(utils.process_symbols, source.opts.debounce_cache_requests_ms)
	end

	---@type table<string, boolean>
	local processed_items = {}

	local bufnr = vim.api.nvim_get_current_buf()
	local project_path = vim.fn.getcwd()
	local vendor_path_prefix = "file://" .. project_path .. "/vendor/"
	local project_path_prefix = "file://" .. project_path .. "/"

	local cached_items = {}
	if source.opts.matching_strategy == "substring_fuzzy_fallback" or source.opts.matching_strategy == "substring" then
		cached_items = source.cache:load(cursor_prefix_word, true)
	end

	if source.opts.matching_strategy == "substring_fuzzy_fallback" or source.opts.matching_strategy == "fuzzy" then
		local iter = 13
		local tmp_cursor_prefix_word = cursor_prefix_word
		while #cached_items == 0 and iter > 0 and #tmp_cursor_prefix_word > 0 do
			cached_items = source.cache:load(tmp_cursor_prefix_word, false)
			iter = iter - 1
			tmp_cursor_prefix_word = tmp_cursor_prefix_word:sub(1, #tmp_cursor_prefix_word - 1)
		end
	end

	utils:debounced_process_symbols(
		source.opts,
		bufnr,
		callback,
		vendor_path_prefix,
		project_path_prefix,
		cached_items,
		processed_items,
		true
	)

	gopls_requests.debounced_workspace_symbols(source.opts, gopls_client, bufnr, cursor_prefix_word, function(result)
		if not result or #result == 0 then
			return callback({ items = {}, isIncomplete = false })
		end

		local filtered_result = {}
		for _, symbol in ipairs(result) do
			symbol.name = symbol.name:match("^[^%.]+%.(.*)") or symbol.name
			if
				utils.symbol_to_completion_kind(symbol.kind)
				and not symbol.name:match("/")
				and symbol.name:match("^[A-Z]")
				and not symbol.location.uri:match("test%.go$")
			then
				if string.sub(symbol.location.uri, 1, #vendor_path_prefix) == vendor_path_prefix then
					symbol.isVendored = true
					symbol.location.uri = symbol.location.uri:sub(#vendor_path_prefix + 1)
				elseif string.sub(symbol.location.uri, 1, #project_path_prefix) == project_path_prefix then
					symbol.isLocal = true
					symbol.location.uri = symbol.location.uri:sub(#project_path_prefix + 1)
				end
				symbol.fuzzy_text = cursor_prefix_word
				table.insert(filtered_result, symbol)
			end
		end

		source.cache:save(utils, filtered_result)
		local items = {}
		if
			source.opts.matching_strategy == "substring_fuzzy_fallback"
			or source.opts.matching_strategy == "substring"
		then
			items = source.cache:load(cursor_prefix_word, true)
		end

		if
			#items == 0 and source.opts.matching_strategy == "substring_fuzzy_fallback"
			or source.opts.matching_strategy == "fuzzy"
		then
			items = vim.tbl_extend("force", items, filtered_result)
		end

		utils:debounced_process_symbols(
			source.opts,
			bufnr,
			callback,
			vendor_path_prefix,
			project_path_prefix,
			items,
			processed_items,
			true
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
	local opts = source.opts
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
	if vim.bo.filetype ~= "go" then
		return
	end

	local symbol = completion_item.data
	if not symbol then
		return
	end

	---@type cmp_go_deep.Options|nil
	local opts = source.opts
	if not opts then
		return
	end

	local import_path = symbol.containerName
	local package_name = symbol.package_alias

	if not import_path then
		if opts.notifications then
			vim.notify("import path not found", vim.log.levels.WARN)
		end
		return
	end

	utils.add_import_statement(opts, symbol.bufnr, package_name, import_path)
	callback(completion_item)
end

return source
