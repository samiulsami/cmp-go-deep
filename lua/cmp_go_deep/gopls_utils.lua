---@class cmp_go_deep.gopls_utils
---@field get_gopls_client fun(): vim.lsp.Client | nil
---@field get_documentation fun(opts: cmp_go_deep.Options, gopls_client: vim.lsp.Client | nil, uri: string, range: lsp.Range): string|nil
---@field debounced_workspace_symbols fun(opts:cmp_go_deep.Options, gopls_client: vim.lsp.Client, bufnr: integer, cursor_prefix_word: string, callback: fun(items: lsp.SymbolInformation[]): nil): nil
---@field public workspace_symbols fun(opts:cmp_go_deep.Options, gopls_client: vim.lsp.Client, bufnr: integer, cursor_prefix_word: string, callback: fun(items: lsp.SymbolInformation[]): nil): nil
---@field public scan_gosymbols_in_dir fun(dir: string, callback: fun(files: string[]): nil): nil
---@field public load_internal_symbols_into_cache fun(self, opts: cmp_go_deep.Options, gopls_client: vim.lsp.Client | nil, utils: cmp_go_deep.utils, cache: cmp_go_deep.cache): nil
local gopls_utils = {}

---@return vim.lsp.Client | nil
gopls_utils.get_gopls_client = function()
	local gopls_clients = vim.lsp.get_clients({ name = "gopls" })
	if #gopls_clients > 0 then
		return gopls_clients[1]
	end
	return nil
end

---@param opts cmp_go_deep.Options
---@param gopls_client vim.lsp.Client | nil
---@param uri string
---@param range lsp.Range
---@return string | nil
---TODO: try completionItem/resolve instead
gopls_utils.get_documentation = function(opts, gopls_client, uri, range)
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
gopls_utils.workspace_symbols = function(opts, gopls_client, bufnr, cursor_prefix_word, callback)
	local success, _ = gopls_client:request("workspace/symbol", { query = cursor_prefix_word }, function(err, result)
		if err then
			if opts.notifications then
				vim.notify("failed to get workspace symbols: " .. vim.inspect(err), vim.log.levels.WARN)
			end
			return
		end
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

--- @param dir string
--- @param callback fun(files: table<string, string>): nil
gopls_utils.scan_gosymbols_in_dir = function(dir, callback)
	local files = {}
	local pending = 0

	local function scan_dir(path)
		pending = pending + 1

		vim.uv.fs_scandir(path, function(err, handle)
			if err then
				pending = pending - 1
				vim.notify("failed to scan dir: " .. err, vim.log.levels.ERROR)
				if pending <= 0 then
					callback(files)
				end
				return
			end

			local max_iterations = 10000
			while max_iterations > 0 do
				max_iterations = max_iterations - 1
				local name, type = vim.uv.fs_scandir_next(handle)
				if not name then
					break
				end
				if type == "file" and string.match(name, "%.go$") then
					table.insert(files, path .. name)
				elseif type == "directory" then
					scan_dir(path .. name .. "/")
				end
			end

			pending = pending - 1
			if pending <= 0 then
				callback(files)
			end
		end)
	end

	scan_dir(dir)
end

---@param symbols table
---@param filepath string
---@return string | nil
local function save_symbols_into_file(symbols, filepath)
	local file, err = io.open(filepath, "w")
	if not file then
		return "failed to open file for writing: " .. err
	end

	file:write(vim.fn.json_encode(symbols))
	file:close()
end

---@param filepath string
---@return table | nil
---@return string | nil
local function load_symbols_from_file(filepath)
	local file, err = io.open(filepath, "r")
	if not file then
		return nil, "failed to open file for reading: " .. err
	end

	local json_string = file:read("*a")
	file:close()

	vim.notify("Loaded " .. #json_string .. " bytes from " .. filepath, vim.log.levels.INFO)

	local decoded = vim.fn.json_decode(json_string)

	vim.notify("Loaded " .. #decoded .. " internal symbols", vim.log.levels.INFO)
	return decoded, nil
end

---@param opts cmp_go_deep.Options
---@param gopls_client vim.lsp.Client | nil
---@param utils cmp_go_deep.utils
---@param cache cmp_go_deep.cache
function gopls_utils:load_internal_symbols_into_cache(opts, gopls_client, utils, cache)
	if gopls_client == nil then
		if opts.notifications then
			vim.notify("gopls client is nil", vim.log.levels.WARN)
		end
		return
	end

	local go_root, err = utils:get_go_root()
	if err then
		if opts.notifications then
			vim.notify("failed to get go_root: " .. err, vim.log.levels.ERROR)
		end
		return
	end

	local src_dir = go_root .. "/src/"

	local go_version, gover_err = utils.get_go_version()
	if gover_err then
		if opts.notifications then
			vim.notify("failed to get go_version: " .. gover_err, vim.log.levels.ERROR)
		end
		return
	end

	local internal_symbols, load_err = load_symbols_from_file(opts.internal_symbols_path)
	if load_err then
		vim.notify("failed to load internal symbols: " .. load_err, vim.log.levels.ERROR)
		return
	end
	if internal_symbols and internal_symbols.go_version == go_version then
		vim.notify("Internal symbols are up to date. found " .. #internal_symbols .. " symbols", vim.log.levels.INFO)
		cache:save_internal_symbols_in_memory(internal_symbols)
		return
	end

	internal_symbols = {}

	vim.notify("Loading internal symbols into cache...", vim.log.levels.INFO)

	self.scan_gosymbols_in_dir(src_dir, function(files)
		vim.schedule(function()
			local pending = #files
			for _, file in ipairs(files) do
				local filepath = file
				local uri = "file://" .. filepath
				local module_name = filepath:gsub(src_dir, "")
				module_name = module_name:gsub("/.*%.go$", "")

				gopls_client:request("textDocument/documentSymbol", {
					textDocument = {
						uri = uri,
					},
				}, function(gopls_err, result)
					if gopls_err then
						pending = pending - 1
						if opts.notifications then
							vim.notify(
								"error fetching document symbols for file: " .. file .. ": " .. vim.inspect(gopls_err),
								vim.log.levels.ERROR
							)
						end
						return
					end

					if result == nil then
						pending = pending - 1
						return
					end

					local symbol_information = {}

					for _, symbol in ipairs(result) do
						symbol.location = {
							uri = uri,
							range = symbol.range,
						}
						symbol.containerName = module_name
						symbol.children = nil
						symbol.range = nil
						symbol.selectionRange = nil
						symbol.detail = nil

						local sanitized_symbol = utils:sanitize_raw_symbol(symbol)
						if sanitized_symbol then
							symbol.fuzzy_text = symbol.containerName .. symbol.name
							table.insert(symbol_information, sanitized_symbol)
						end
					end

					for _, symbol in ipairs(symbol_information) do
						table.insert(internal_symbols, symbol)
					end

					pending = pending - 1
					if pending <= 0 then
						internal_symbols.go_version = go_version
						local err = save_symbols_into_file(internal_symbols, opts.internal_symbols_path)
						if err then
							if opts.notifications then
								vim.notify("Failed to save internal symbols: " .. err, vim.log.levels.ERROR)
							end
						end
						cache:save_internal_symbols_in_memory(internal_symbols)
						if opts.notifications then
							vim.notify("Indexed " .. #internal_symbols .. " internal symbols", vim.log.levels.INFO)
						end
					end
				end)
			end
		end)
	end)
end

return gopls_utils
