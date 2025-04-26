local utils = require("cmp_go_deep.utils")
local gopls_requests = require("cmp_go_deep.gopls_requests")

---@class cmp_go_deep.Options
---@field public textdocument_completion boolean | nil
---@field public get_documentation_implementation "hover" | "regex" | nil
---@field public add_import_statement_implementation "treesitter" | "gopls" | nil
---@field public get_package_name_implementation "treesitter" | "regex" | nil
---@field public exclude_vendored_packages boolean | nil
---@field public documentation_wait_timeout_ms integer | nil
---@field public workspace_symbol_timeout_ms integer | nil
---@field public textdocument_completion_timeout_ms integer | nil

---@type cmp_go_deep.Options
local default_options = {
	textdocument_completion = false,
	get_documentation_implementation = "hover",
	add_import_statement_implementation = "treesitter",
	get_package_name_implementation = "regex",
	exclude_vendored_packages = false,
	documentation_wait_timeout_ms = 500,
	workspace_symbol_timeout_ms = 2000,
	textdocument_completion_timeout_ms = 500,
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
	local opts = vim.tbl_deep_extend("force", default_options, params.option or {}, params.opts or {})

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
		return callback(nil)
	end

	if not symbol.is_unimported then
		return callback(completion_item)
	end

	---@type cmp_go_deep.Options
	local opts = symbol.opts

	local documentation = utils.get_documentation(
		symbol.location.uri,
		symbol.location.range,
		opts.get_documentation_implementation,
		opts.documentation_wait_timeout_ms
	)
	if not documentation then
		documentation = ""
	end
	completion_item.documentation = {
		kind = "markdown",
		value = documentation,
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

	---@type cmp_go_deep.Options
	local opts = symbol.opts

	local import_path = symbol.containerName
	if symbol.is_unimported and import_path and vim.bo.filetype == "go" then
		utils.add_import_statement(symbol.bufnr, import_path, opts.add_import_statement_implementation)
	else
		vim.notify("Import path not found", vim.log.levels.WARN)
	end

	callback(completion_item)
end

return source
