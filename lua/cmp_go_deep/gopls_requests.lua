local gopls_requests = {}

---@param gopls_client vim.lsp.Client | nil
---@param timeout integer
---@param uri string
---@param range lsp.Range
---@return string | nil
---TODO: try completionItem/resolve instead
gopls_requests.get_documentation = function(gopls_client, timeout, uri, range)
	if gopls_client == nil then
		vim.notify("gopls client is nil", vim.log.levels.WARN)
		return nil
	end

	local params = {
		textDocument = { uri = uri },
		position = range.start,
	}

	local markdown = ""

	gopls_client.request("textDocument/hover", params, function(err, result)
		if err then
			vim.notify("failed to get documentation: " .. err.message, vim.log.levels.WARN)
			return
		end

		if result and result.contents then
			markdown = result.contents.value
		end
	end)

	vim.wait(timeout, function()
		return markdown ~= ""
	end, 10)

	if markdown == "" then
		vim.notify("timed out waiting for documentation", vim.log.levels.WARN)
	end

	return markdown
end

---@param gopls_client vim.lsp.Client | nil
---@param bufnr (integer)
---@param import_path string
---FIXME: sometimes fails (noop) for vendored pacakges
gopls_requests.add_import_statement = function(gopls_client, bufnr, import_path)
	if gopls_client == nil then
		vim.notify("gopls client is nil", vim.log.levels.WARN)
		return
	end

	gopls_client.request("workspace/executeCommand", {
		command = "gopls.add_import",
		arguments = { {
			URI = vim.uri_from_bufnr(bufnr),
			ImportPath = import_path,
		} },
	}, function(err, _, _)
		if err then
			vim.notify("failed to add import " .. import_path .. ": " .. err.message, vim.log.levels.WARN)
		end
	end)
end

return gopls_requests
