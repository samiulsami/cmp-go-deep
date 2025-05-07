---@class cmp_go_deep.gopls_requests
---@field get_documentation fun(opts: cmp_go_deep.Options, gopls_client: vim.lsp.Client | nil, uri: string, range: lsp.Range): string|nil
---@field debounced_cache_workspace_symbols fun(opts: cmp_go_deep.Options, cache: cmp_go_deep.DB, gopls_client: vim.lsp.Client, bufnr: integer, project_path: string, cursor_prefix_word: string, utils: cmp_go_deep.utils, callback: any): nil
---@field public cache_workspace_symbols fun(opts: cmp_go_deep.Options, cache: cmp_go_deep.DB, gopls_client: vim.lsp.Client, bufnr: integer, project_path: string, cursor_prefix_word: string, utils: cmp_go_deep.utils, callback: any): nil
---@field public max_item_limit number
local gopls_requests = {}

--Max workspace symbols that gopls returns in one query https://github.com/golang/tools/blob/de18b0bf1345e2dda43ba4fa57605b4ccbbe67ab/gopls/internal/golang/workspace_symbol.go#L29-L29
gopls_requests.gopls_max_item_limit = 100

---@param opts cmp_go_deep.Options
---@param gopls_client vim.lsp.Client | nil
---@param uri string
---@param range lsp.Range
---@return string | nil
---TODO: try completionItem/resolve instead
gopls_requests.get_documentation = function(opts, gopls_client, uri, range)
	if gopls_client == nil then
		vim.notify("gopls client is nil", vim.log.levels.WARN)
		return nil
	end

	local params = {
		textDocument = { uri = uri },
		position = range.start,
	}

	local markdown = ""

	gopls_client:request("textDocument/hover", params, function(err, result)
		if err then
			vim.notify("failed to get documentation: " .. err.message, vim.log.levels.WARN)
			return
		end

		if result and result.contents then
			markdown = result.contents.value
		end
	end)

	vim.wait(opts.documentation_wait_timeout_ms, function()
		return markdown ~= ""
	end, 10)

	if markdown == "" and opts.timeout_notifications then
		vim.notify("timed out waiting for documentation", vim.log.levels.WARN)
	end

	return markdown
end

---@param opts cmp_go_deep.Options
---@param cache cmp_go_deep.DB
---@param gopls_client vim.lsp.Client
---@param bufnr integer
---@param project_path string
---@param cursor_prefix_word string
---@param utils cmp_go_deep.utils
---@param callback any
-- stylua: ignore
gopls_requests.cache_workspace_symbols = function(opts, cache, gopls_client, bufnr, project_path, cursor_prefix_word, utils, callback)
	local success, _ = gopls_client:request("workspace/symbol", { query = cursor_prefix_word }, function(_, result)
		if not result then
			return
		end
		cache:save(project_path, cursor_prefix_word, result)
		utils.process_request(opts, bufnr, cache, callback, project_path, cursor_prefix_word, gopls_requests.gopls_max_item_limit)
	end, bufnr)

	if not success then
		vim.notify("failed to get workspace symbols", vim.log.levels.WARN)
		return
	end
end

return gopls_requests
