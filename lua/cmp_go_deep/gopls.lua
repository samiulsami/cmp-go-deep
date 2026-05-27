local gopls = {}

---@param opts cmp_go_deep.Options
---@param gopls_client vim.lsp.Client
---@param bufnr integer
---@param cursor_prefix_word string
---@param callback fun(items: lsp.SymbolInformation[]): nil
-- stylua: ignore
gopls.workspace_symbols = function(opts, gopls_client, bufnr, cursor_prefix_word, callback)
	local success, request_id = gopls_client:request("workspace/symbol", { query = cursor_prefix_word }, function(_, result)
		callback(result or {})
	end, bufnr)

	if not success then
		if opts.notifications then
			vim.notify("failed to get workspace symbols", vim.log.levels.WARN)
		end
		return false, nil
	end

	return true, request_id
end

return gopls
