local gopls_requests = {}
--Max workspace symbols that gopls returns in one query https://github.com/golang/tools/blob/de18b0bf1345e2dda43ba4fa57605b4ccbbe67ab/gopls/internal/golang/workspace_symbol.go#L29-L29
local gopls_max_item_limit = 100

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

	gopls_client:request("textDocument/hover", params, function(err, result)
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

	gopls_client:request("workspace/executeCommand", {
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

---TODO: Implement/integrate this
---
---@param opts cmp_go_deep.Options
---@param gopls_client vim.lsp.Client | nil
---@param bufnr integer
---@param utils cmp_go_deep.utils
---@return table<integer, lsp.CompletionItem>, boolean
gopls_requests.textdocument_completion = function(opts, gopls_client, bufnr, utils)
	if gopls_client == nil then
		vim.notify("gopls client is nil", vim.log.levels.WARN)
		return {}, false
	end

	_ = utils

	local result = {}
	local done = false
	--- TODO: determine this dynamically
	local is_incomplete = false
	local cursor = vim.api.nvim_win_get_cursor(0)
	local position = { line = cursor[1] - 1, character = cursor[2] }

	local success, request_id = gopls_client:request("textDocument/completion", {
		textDocument = { uri = vim.uri_from_bufnr(bufnr) },
		position = position,
		context = { triggerKind = 1 },
	}, function(_, res)
		if not res or not res.items then
			done = true
			return
		end
		result = res.items
		done = true
	end, bufnr)

	if not success or not request_id then
		vim.notify("failed to get textDocument/completion", vim.log.levels.WARN)
		return {}, false
	end

	vim.wait(opts.textdocument_completion_timeout_ms, function()
		return done
	end, 10)

	if not done then
		vim.notify("timed out waiting for textDocument/completion", vim.log.levels.WARN)
		gopls_client:cancel_request(request_id)
		return {}, false
	end

	local items = {}
	for _, item in ipairs(result) do
		table.insert(items, {
			label = item.label,
			kind = item.kind,
			detail = item.detail,
			insertText = item.insertText or item.label,
			data = item.data or {},
			sortText = item.sortText or item.label,
		})
	end

	return result, is_incomplete
end

---@param opts cmp_go_deep.Options
---@param gopls_client vim.lsp.Client | nil
---@param bufnr (integer)
---@param utils cmp_go_deep.utils
---@return table<string, any>, boolean
gopls_requests.workspace_symbols = function(opts, gopls_client, bufnr, utils)
	if gopls_client == nil then
		vim.notify("gopls client is nil", vim.log.levels.WARN)
		return {}, false
	end

	local result = {}
	local done = false
	local success, request_id = gopls_client:request(
		"workspace/symbol",
		{ query = utils.get_cursor_prefix_word() },
		function(_, res)
			if not res then
				done = true
				return
			end
			result = res
			done = true
		end,
		0
	)

	if not success or not request_id then
		vim.notify("failed to get workspace/symbol", vim.log.levels.WARN)
		return {}, false
	end

	vim.wait(opts.workspace_symbol_timeout_ms, function()
		return done
	end, 10)

	if not done then
		vim.notify("timed out waiting for workspace symbols", vim.log.levels.WARN)
		gopls_client:cancel_request(request_id)
		return {}, false
	end

	local items = {}
	local package_name_cache = {}

	local is_incomplete = false
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
			local package_name =
				utils.get_package_name(symbol.location.uri, package_name_cache, opts.get_package_name_implementation)
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
			symbol.is_unimported = true
			table.insert(items, {
				label = package_name .. "." .. symbol.name,
				sortText = symbol.name,
				kind = kind,
				detail = '"' .. symbol.containerName .. '"',
				data = symbol,
			})
		end
	end

	is_incomplete = #result >= gopls_max_item_limit

	return items, is_incomplete
end

return gopls_requests
