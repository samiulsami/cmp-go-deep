local gopls = require("cmp_go_deep.gopls")
local treesitter = require("cmp_go_deep.treesitter")
local completionItemKind = vim.lsp.protocol.CompletionItemKind

---@class cmp_go_deep.CompleteUserData
---@field doc_key string|nil
---@field import_path string|nil
---@field package_alias string|nil
---@field uri string|nil
---@field range lsp.Range|nil

---@class cmp_go_deep.utils
---@field debounce fun(fn: fun(...), delay_ms: integer): fun(...)
---@field symbol_to_completion_kind fun(lspKind: lsp.SymbolKind): integer
---@field get_cursor_prefix_word fun(win_id: integer): string
---@field get_unique_package_alias fun(used_aliases: table<string, boolean>, package_alias: string): string
---@field get_gopls_client fun(bufnr?: integer): vim.lsp.Client|nil
---@field encode_complete_user_data fun(user_data: cmp_go_deep.CompleteUserData): string
---@field decode_complete_user_data fun(user_data: string|table|nil): cmp_go_deep.CompleteUserData|nil
---@field get_imported_paths fun(opts: cmp_go_deep.Options, bufnr: integer): table<string, string>
---@field add_import_statement fun(opts: cmp_go_deep.Options, bufnr: integer, package_name: string | nil, import_path: string): nil
---@field get_package_name fun(opts: cmp_go_deep.Options, uri: string, package_name_cache: table<string, string>): string|nil, boolean
---@field deterministic_symbol_hash fun(symbol: lsp.SymbolInformation): string
---@field symbol_hash fun(symbol: lsp.SymbolInformation): string
---@field process_symbols fun(self, opts: cmp_go_deep.Options, bufnr: integer, vendor_path_prefix: string, project_path_prefix: string, symbols: table, processed_items: table<string, boolean>, on_reject: fun(rejected: table)|nil): table
local utils = {}

local symbol_to_completion_kind = {
	[10] = completionItemKind.Enum,
	[11] = completionItemKind.Interface,
	[12] = completionItemKind.Function,
	[13] = completionItemKind.Variable,
	[14] = completionItemKind.Constant,
	[23] = completionItemKind.Struct,
	[26] = completionItemKind.TypeParameter,
}

---@param fn fun(...)
---@param delay_ms integer
---@return fun(...)
utils.debounce = function(fn, delay_ms)
	local timer = vim.uv.new_timer()
	if not timer then
		error("failed to create uv timer")
	end

	return function(...)
		local args = { ... }
		timer:start(delay_ms, 0, function()
			vim.schedule(function()
				local cur_args = args
				fn(unpack(cur_args))
			end)
		end)
	end
end

---@param lspKind lsp.SymbolKind
---@return integer
utils.symbol_to_completion_kind = function(lspKind)
	return symbol_to_completion_kind[lspKind]
end

---@param win_id integer
---@return string
utils.get_cursor_prefix_word = function(win_id)
	local pos = vim.api.nvim_win_get_cursor(win_id)
	if #pos < 2 then
		return ""
	end

	local col = pos[2]
	local start_col = col
	local end_col = col

	local line = vim.api.nvim_get_current_line()

	while start_col > 0 and not line:sub(start_col - 1, start_col - 1):match("%s") do
		start_col = start_col - 1
	end

	return line:sub(start_col, end_col)
end

---@param bufnr integer|nil
---@return vim.lsp.Client | nil
utils.get_gopls_client = function(bufnr)
	local gopls_clients = vim.lsp.get_clients(bufnr and { name = "gopls", bufnr = bufnr } or { name = "gopls" })
	if #gopls_clients > 0 then
		return gopls_clients[1]
	end
	return nil
end

---@param user_data cmp_go_deep.CompleteUserData
---@return string
utils.encode_complete_user_data = function(user_data)
	return vim.json.encode({ cmp_go_deep = user_data })
end

---@param user_data string|table|nil
---@return cmp_go_deep.CompleteUserData|nil
utils.decode_complete_user_data = function(user_data)
	if type(user_data) == "table" then
		return user_data.cmp_go_deep
	end

	if type(user_data) ~= "string" or user_data == "" then
		return nil
	end

	local ok, decoded = pcall(vim.json.decode, user_data)
	if not ok or type(decoded) ~= "table" then
		return nil
	end

	return decoded.cmp_go_deep
end

---@param opts cmp_go_deep.Options
---@param bufnr integer
---@return table<string, string>
utils.get_imported_paths = function(opts, bufnr)
	return treesitter.get_imported_paths(opts, bufnr)
end

---@param opts cmp_go_deep.Options
---@param bufnr integer
---@param package_alias string | nil
---@param import_path string
utils.add_import_statement = function(opts, bufnr, package_alias, import_path)
	treesitter.add_import_statement(opts, bufnr, package_alias, import_path)
end

---@param used_aliases table<string, boolean>
---@param package_alias string
---@return string
utils.get_unique_package_alias = function(used_aliases, package_alias)
	local alias = package_alias
	local i = 2
	while used_aliases[alias] do
		alias = package_alias .. i
		i = i + 1
	end
	return alias
end

---@param opts cmp_go_deep.Options
---@param uri string
---@param package_name_cache table<string, string>
---@return string|nil, boolean
utils.get_package_name = function(opts, uri, package_name_cache)
	local cached = package_name_cache[uri]
	if cached then
		if cached == "" then
			return nil, true
		end
		return cached, true
	end

	local stat = vim.uv.fs_stat(vim.uri_to_fname(uri))
	if not (stat and stat.type == "file") then
		return nil, false
	end

	local pkg = treesitter.get_package_name(uri)
	if pkg then
		package_name_cache[uri] = pkg
		return pkg, true
	end

	package_name_cache[uri] = ""
	return nil, true
end

---@param path string
---@return boolean
utils.is_internal_package = function(path)
	return path:match("^internal/") or path:match("/internal/") or path:match("/internal$") or path == "internal"
end

--- Go rule: code can import internal only if it's in a subtree rooted at the parent of "internal"
---@param symbol_file_path string
---@param current_file_path string
---@return boolean
utils.can_import_internal = function(symbol_file_path, current_file_path)
	if not utils.is_internal_package(symbol_file_path) then
		return true
	end

	local internal_parent = symbol_file_path:match("^(.-)/internal/") or symbol_file_path:match("^(.-)/internal$")
	if not internal_parent or internal_parent == "" then
		return false
	end

	local current_dir = vim.fn.fnamemodify(current_file_path, ":h")
	return current_dir == internal_parent or current_dir:sub(1, #internal_parent + 1) == internal_parent .. "/"
end

---@param symbol lsp.SymbolInformation
---@return string
utils.deterministic_symbol_hash = function(symbol)
	local ordered = symbol.name
		.. " #"
		.. symbol.kind
		.. " #"
		.. symbol.containerName
		.. " #"
		.. string.format(
			"%d-%d,%d-%d",
			symbol.location.range.start.character,
			symbol.location.range.start.line,
			symbol.location.range["end"].character,
			symbol.location.range["end"].line
		)
	return vim.fn.sha256(ordered)
end

utils.symbol_hash = utils.deterministic_symbol_hash

---@param opts cmp_go_deep.Options
---@param bufnr integer
---@param vendor_path_prefix string
---@param project_path_prefix string
---@param symbols table
---@param processed_items table<string, boolean>
---@param on_reject fun(rejected: table)|nil
---@return table
function utils:process_symbols(
	opts,
	bufnr,
	vendor_path_prefix,
	project_path_prefix,
	symbols,
	processed_items,
	on_reject
)
	local items = {}
	local rejected_items = {}
	local package_name_cache = {}
	local imported_paths = utils.get_imported_paths(opts, bufnr)

	---@type table<string, boolean>
	local used_aliases = {}
	for _, v in pairs(imported_paths) do
		used_aliases[v] = true
	end

	local current_buf_uri = vim.uri_from_bufnr(bufnr)
	local current_buf_dir = vim.fn.fnamemodify(current_buf_uri, ":h")
	local current_file_path = vim.uri_to_fname(current_buf_uri)

	for _, symbol in ipairs(symbols) do
		local hash = self.deterministic_symbol_hash(symbol)
		if processed_items[hash] then
			goto continue
		end
		processed_items[hash] = true

		if symbol.isVendored then
			symbol.location.uri = vendor_path_prefix .. symbol.location.uri
		elseif symbol.isLocal then
			symbol.location.uri = project_path_prefix .. symbol.location.uri
		end

		if opts.exclude_internal_packages then
			if symbol.isLocal then
				local symbol_file_path = vim.uri_to_fname(symbol.location.uri)
				if not utils.can_import_internal(symbol_file_path, current_file_path) then
					rejected_items[#rejected_items + 1] = symbol
					goto continue
				end
			elseif utils.is_internal_package(symbol.containerName) then
				rejected_items[#rejected_items + 1] = symbol
				goto continue
			end
		end

		local symbol_dir = vim.fn.fnamemodify(symbol.location.uri, ":h")
		local kind = utils.symbol_to_completion_kind(symbol.kind)

		if
			kind
			and not imported_paths[symbol.containerName]
			and symbol.location.uri ~= current_buf_uri
			and symbol_dir ~= current_buf_dir
			and not (opts.exclude_vendored_packages and symbol.isVendored)
		then
			local package_name, file_exists = utils.get_package_name(opts, symbol.location.uri, package_name_cache)
			if not file_exists then
				rejected_items[#rejected_items + 1] = symbol
				goto continue
			end

			if package_name == nil then
				package_name = symbol.containerName:match("([^/]+)$"):gsub("-", "_")
			end
			if not package_name then
				rejected_items[#rejected_items + 1] = symbol
				goto continue
			end

			local package_alias = utils.get_unique_package_alias(used_aliases, package_name)
			if package_alias ~= package_name then
				symbol.package_alias = package_alias
			end

			symbol.bufnr = bufnr

			table.insert(items, {
				label = package_alias .. "." .. symbol.name,
				filterText = package_alias .. symbol.containerName .. symbol.name,
				sortText = package_alias .. symbol.containerName .. symbol.name,
				kind = kind,
				detail = '"' .. symbol.containerName .. '"',
				data = symbol,
			})
		else
			rejected_items[#rejected_items + 1] = symbol
		end

		::continue::
	end

	if on_reject and #rejected_items > 0 then
		vim.schedule(function()
			on_reject(rejected_items)
		end)
	end

	return items
end

return utils
