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
		{ query = utils.get_cursor_prefix_word(0) },
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
		if opts.timeout_notifications then
			vim.notify("timed out waiting for workspace symbols", vim.log.levels.WARN)
		end
		gopls_client:cancel_request(request_id)
		return {}, false
	end

	local items = {}
	local package_name_cache = {}

	local is_incomplete = false
	local imported_paths = utils.get_imported_paths(bufnr)

	---@type table<string, boolean>
	local used_aliases = {}
	for _, v in pairs(imported_paths) do
		used_aliases[v] = true
	end

	---TODO: better type checking and error handling
	for _, symbol in ipairs(result) do
		local kind = utils.symbol_to_completion_kind(symbol.kind)
		if
			kind
			and symbol.name:match("^[A-Z]")
			and not imported_paths[symbol.containerName]
			and not symbol.location.uri:match("_test%.go$")
			and not (opts.exclude_vendored_packages and symbol.location.uri:match("/vendor/"))
			and symbol.location.uri ~= vim.uri_from_bufnr(bufnr)
		then
			local package_name =
				utils.get_package_name(symbol.location.uri, package_name_cache, opts.get_package_name_implementation)
			if package_name == nil then
				package_name = symbol.containerName:match("([^/]+)$"):gsub("-", "_")
				vim.notify(
					"Package name not found for uri: "
						.. symbol.location.uri
						.. "\nDefaulting to directory name: "
						.. package_name,
					vim.log.levels.WARN
				)
			end

			local package_alias = utils.get_unique_package_alias(used_aliases, package_name)
			if package_alias ~= package_name then
				symbol.package_alias = package_alias
			end
			symbol.bufnr = bufnr
			symbol.opts = opts
			symbol.is_unimported = true

			table.insert(items, {
				label = package_alias .. "." .. symbol.name,
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
