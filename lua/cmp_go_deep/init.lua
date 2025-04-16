local utils = require("cmp_go_deep.utils")

---@class cmp_go_deep.Options
---@field public get_documentation_implementation "hover" | "regex" | nil
---@field public add_import_statement_implementation "treesitter" | "gopls" | nil
---@field public get_package_name_implementation "treesitter" | "regex" | nil
---@field public exclude_vendored_packages boolean | nil
---@field public documentation_wait_timeout_ms integer | nil

---@type cmp_go_deep.Options
local default_options = {
	get_documentation_implementation = "hover",
	add_import_statement_implementation = "treesitter",
	get_package_name_implementation = "regex",
	exclude_vendored_packages = false,
	documentation_wait_timeout_ms = 500,
}

--Max workspace symbols that gopls returns in one query https://github.com/golang/tools/blob/de18b0bf1345e2dda43ba4fa57605b4ccbbe67ab/gopls/internal/golang/workspace_symbol.go#L29-L29
local gopls_max_item_limit = 100

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
	local package_name_cache = {}

	gopls_client.request("workspace/symbol", { query = utils.get_cursor_prefix_word() }, function(_, result)
		if not result then
			return callback({ items = {}, isIncomplete = true })
		end

		local items = {}
		local imported_paths = utils.get_imported_paths(bufnr)

		for _, symbol in ipairs(result) do
			local kind = utils.symbol_to_completion_kind[symbol.kind]
			if
				kind ~= nil
				and symbol.name:match("^[A-Z]")
				and not imported_paths[symbol.containerName]
				and not symbol.location.uri:match("_test%.go$")
				and not (opts.exclude_vendored_packages and symbol.containerName:match("/vendor/"))
				and symbol.location.uri ~= vim.uri_from_bufnr(bufnr)
			then
				local package_name = utils.get_package_name(
					symbol.location.uri,
					package_name_cache,
					opts.get_package_name_implementation
				)
				if package_name == nil then
					package_name = symbol.containerName:match("([^/]+)$")
					vim.notify(
						"Package name not found for uri: "
							.. symbol.location.uri
							.. "\nDefaulting to directory name: "
							.. package_name,
						vim.log.levels.WARN
					)
				end

				symbol.bufnr = bufnr
				symbol.opts = opts
				table.insert(items, {
					label = package_name .. "." .. symbol.name,
					sortText = symbol.name,
					kind = kind,
					detail = '"' .. symbol.containerName .. '"',
					data = symbol,
				})
			end
		end

		local is_incomplete = #result >= gopls_max_item_limit
		callback({ items = items, isIncomplete = is_incomplete })
	end, 0)
end

---@param completion_item lsp.CompletionItem
---@param callback fun(completion_item: lsp.CompletionItem|nil)
function source:resolve(completion_item, callback)
	local symbol = completion_item.data

	--@type cmp_go_deep.Options
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

	--@type cmp_go_deep.Options
	local opts = symbol.opts

	local import_path = symbol.containerName
	if import_path and vim.bo.filetype == "go" then
		utils.add_import_statement(symbol.bufnr, import_path, opts.add_import_statement_implementation)
	else
		vim.notify("Import path not found", vim.log.levels.WARN)
	end

	callback(completion_item)
end

return source
