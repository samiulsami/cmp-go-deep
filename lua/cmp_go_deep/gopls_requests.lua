---@class cmp_go_deep.gopls_requests
---@field get_documentation fun(opts: cmp_go_deep.Options, gopls_client: vim.lsp.Client | nil, uri: string, range: lsp.Range): string|nil
---@field debounced_workspace_symbols fun(opts:cmp_go_deep.Options, gopls_client: vim.lsp.Client, bufnr: integer, cursor_prefix_word: string, callback: fun(items: lsp.SymbolInformation[]): nil): nil
---@field public workspace_symbols fun(opts:cmp_go_deep.Options, gopls_client: vim.lsp.Client, bufnr: integer, cursor_prefix_word: string, callback: fun(items: lsp.SymbolInformation[]): nil): nil
local gopls_requests = {}

---@param opts cmp_go_deep.Options
---@param gopls_client vim.lsp.Client | nil
---@param uri string
---@param range lsp.Range
---@return string | nil
---TODO: try completionItem/resolve instead
gopls_requests.get_documentation = function(opts, gopls_client, uri, range)
	if gopls_client == nil then
		if opts.notifications then
			vim.notify("gopls client is nil", vim.log.levels.WARN)
		end
		return nil
	end

	local params = {
		textDocument = { uri = uri },
		position = range.start,
	}

	local markdown = ""

	gopls_client:request("textDocument/hover", params, function(err, result)
		if err then
			if opts.notifications then
				vim.notify("failed to get documentation: " .. err.message, vim.log.levels.WARN)
			end
			return
		end

		if result and result.contents then
			markdown = result.contents.value
		end
	end)

	vim.wait(opts.documentation_wait_timeout_ms, function()
		return markdown ~= ""
	end, 10)

	if markdown == "" and opts.notifications then
		if opts.notifications then
			vim.notify("timed out waiting for documentation", vim.log.levels.WARN)
		end
	end

	return markdown
end

---@param opts cmp_go_deep.Options
---@param gopls_client vim.lsp.Client
---@param bufnr integer
---@param cursor_prefix_word string
---@param callback fun(items: lsp.SymbolInformation[]): nil
-- stylua: ignore
gopls_requests.workspace_symbols = function(opts, gopls_client, bufnr, cursor_prefix_word, callback)
	local success, _ = gopls_client:request("workspace/symbol", { query = cursor_prefix_word }, function(_, result)
		if not result then
			return
		end
		callback(result)
	end, bufnr)

	if not success then
		if opts.notifications then
			vim.notify("failed to get workspace symbols", vim.log.levels.WARN)
		end
		return
	end
end

return gopls_requests
