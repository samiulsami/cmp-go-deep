local utils = require("cmp_go_deep.utils")
local gopls_requests = require("cmp_go_deep.gopls_requests")

---@class cmp_go_deep.Options
---@field public timeout_notifications boolean | nil
---@field public get_documentation_implementation "hover" | "regex" | nil
---@field public get_package_name_implementation "treesitter" | "regex" | nil
---@field public exclude_vendored_packages boolean | nil
---@field public documentation_wait_timeout_ms integer | nil
---@field public workspace_symbol_timeout_ms integer | nil

---@type cmp_go_deep.Options
local default_options = {
	textdocument_completion = false,
	timeout_notifications = true,
	get_documentation_implementation = "hover",
	get_package_name_implementation = "regex",
	exclude_vendored_packages = false,
	documentation_wait_timeout_ms = 500,
	workspace_symbol_timeout_ms = 150,
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
	opts = extend_non_nil(opts, params.opts or {})

	local gopls_client = utils.get_gopls_client()
	if not gopls_client then
		return callback({ items = {}, isIncomplete = false })
	end

	local bufnr = vim.api.nvim_get_current_buf()
	local workspace_items, is_wssymbols_complete = gopls_requests.workspace_symbols(opts, gopls_client, bufnr, utils)

	callback({ items = workspace_items, isIncomplete = is_wssymbols_complete })
end

---@param completion_item lsp.CompletionItem
---@param callback fun(completion_item: lsp.CompletionItem|nil)
function source:resolve(completion_item, callback)
	local symbol = completion_item.data

	if symbol == nil then
		vim.notify("Warning: symbol data is missing", vim.log.levels.WARN)
		return callback(nil)
	end

	if not symbol.is_unimported then
		return callback(completion_item)
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

	---@type string|nil
	local documentation = utils.get_documentation(
		location.uri,
		location.range,
		opts.get_documentation_implementation,
		opts.documentation_wait_timeout_ms
	)

	completion_item.documentation = {
		kind = "markdown",
		value = documentation or "",
	}
	callback(completion_item)
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

	if symbol.is_unimported and import_path and vim.bo.filetype == "go" then
		utils.add_import_statement(symbol.bufnr, package_name, import_path)
	else
		vim.notify("Import path not found", vim.log.levels.WARN)
	end

	callback(completion_item)
end

return source
