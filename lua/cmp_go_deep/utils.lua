local gopls_requests = require("cmp_go_deep.gopls_requests")
local treesitter_implementations = require("cmp_go_deep.treesitter_implementations")
local completionItemKind = vim.lsp.protocol.CompletionItemKind

---@class cmp_go_deep.utils
---@field debounce fun(fn: fun(...), delay_ms: integer): fun(request_state: cmp_go_deep.utils.request_state, ...)
---@field symbol_to_completion_kind fun(lspKind: lsp.SymbolKind): integer
---@field get_cursor_prefix_word fun(win_id: integer): string
---@field get_unique_package_alias fun(used_aliases: table<string, boolean>, package_alias: string): string
---@field get_gopls_client fun(): vim.lsp.Client|nil
---@field get_documentation fun(opts: cmp_go_deep.Options, uri: string, range: lsp.Range): string|nil
---@field get_imported_paths fun(bufnr: integer): table<string, string>
---@field add_import_statement fun(bufnr: integer, package_name: string | nil, import_path: string): nil
---@field get_package_name fun(opts: cmp_go_deep.Options, uri: string, package_name_cache: table<string, string>): string|nil
local utils = {}

---@class cmp_go_deep.utils.request_state
---@field cancelled boolean

local symbol_to_completion_kind = {
	[10] = completionItemKind.Enum,
	[11] = completionItemKind.Interface,
	[12] = completionItemKind.Function,
	[13] = completionItemKind.Variable,
	[14] = completionItemKind.Constant,
	[23] = completionItemKind.Struct,
	[26] = completionItemKind.TypeParameter,
}

---@param fn fun( ...)
---@param delay_ms integer
---@return fun(request_state: cmp_go_deep.utils.request_state, ...)
utils.debounce = function(fn, delay_ms)
	local timer = vim.uv.new_timer()
	local prev_args = nil
	---@type cmp_go_deep.utils.request_state
	local prev_request_state = nil

	return function(request_state, ...)
		if timer:is_active() and prev_request_state then
			timer:stop()
			prev_request_state.cancelled = true
		end
		prev_request_state = request_state

		local args = { ... }
		prev_args = args
		timer:start(delay_ms, 0, function()
			vim.schedule(function()
				local cur_args = prev_args
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

---@return vim.lsp.Client | nil
utils.get_gopls_client = function()
	local gopls_clients = vim.lsp.get_clients({ name = "gopls" })
	if #gopls_clients > 0 then
		return gopls_clients[1]
	end
	return nil
end

---@param opts cmp_go_deep.Options
---@param uri string
---@param range lsp.Range
---@return string | nil
utils.get_documentation = function(opts, uri, range)
	if opts.get_documentation_implementation == "hover" then
		return gopls_requests.get_documentation(opts, utils.get_gopls_client(), uri, range)
	end

	--default to regex
	local filepath = vim.uri_to_fname(uri)
	local bufnr = vim.fn.bufadd(filepath)
	vim.fn.bufload(bufnr)

	local doc_lines = {}
	local start_line = range.start.line

	for i = start_line - 1, 0, -1 do
		local line = vim.api.nvim_buf_get_lines(bufnr, i, i + 1, false)[1]
		if not line or line:match("^%s*$") then
			break
		end

		local comment = line:match("^%s*//(.*)")
		if comment then
			table.insert(doc_lines, 1, vim.trim(comment))
		else
			break
		end
	end

	if vim.tbl_isempty(doc_lines) then
		return nil
	end

	local ft = vim.bo[bufnr].filetype
	return string.format("```%s\n%s\n```", ft, table.concat(doc_lines, "\n"))
end

---@param bufnr (integer)
---@return table<string, string>
utils.get_imported_paths = function(bufnr)
	return treesitter_implementations.get_imported_paths(bufnr)
end

---@param bufnr (integer)
---@param package_alias string | nil
---@param import_path string
utils.add_import_statement = function(bufnr, package_alias, import_path)
	treesitter_implementations.add_import_statement(bufnr, package_alias, import_path)
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
---@return string|nil
--- TODO: consider asking gopls for the package name, but this is probably faster
utils.get_package_name = function(opts, uri, package_name_cache)
	local cached = package_name_cache[uri]
	if cached then
		if cached == "" then
			return nil
		end
		return cached
	end

	if opts.get_package_name_implementation == "treesitter" then
		local pkg = treesitter_implementations.get_package_name(uri)
		if pkg then
			package_name_cache[uri] = pkg
			return pkg
		end
		package_name_cache[uri] = ""
		return ""
	end

	--default to regex
	--- FIXME: regex implementation doesn't work for package declarations like: "/* hehe */ package xd"
	local fname = vim.uri_to_fname(uri)
	if not fname then
		vim.notify("could not get file name from uri: " .. uri, vim.log.levels.WARN)
		package_name_cache[uri] = ""
		return nil
	end

	local file, err = io.open(fname, "r")
	if not file then
		vim.notify("could not open file: " .. err, vim.log.levels.WARN)
		package_name_cache[uri] = ""
		return nil
	end

	local in_block = false
	for line in file:lines() do
		local ln = line:match("^%s*(.-)%s*$")
		if not in_block and ln:find("^/%*") then
			in_block = true
			if ln:find("%*/") then
				in_block = false
			end
		elseif in_block then
			if ln:find("%*/") then
				in_block = false
			end
		elseif ln == "" or ln:find("^//") then
			-- ignore
		else
			local pkg = ln:match("^package%s+([%a_][%w_]*)")
			file:close()
			package_name_cache[uri] = pkg
			return pkg
		end
	end

	file:close()
	package_name_cache[uri] = ""
	return nil
end

return utils
