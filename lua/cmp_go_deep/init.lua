local utils = require("cmp_go_deep.utils")
local gopls = require("cmp_go_deep.gopls")

---@class cmp_go_deep.Options
---@field public notifications boolean | nil whether to show notifications. default: true
---@field public get_package_name_implementation "treesitter" | nil how to get package name. default: "treesitter"
---@field public exclude_vendored_packages boolean | nil whether to exclude vendored packages. default: false
---@field public exclude_internal_packages boolean | nil whether to exclude internal packages that cannot be imported. default: true
---@field public debounce_gopls_requests_ms integer | nil time to wait before "locking-in" the current request and sending it to gopls. default: 0
---@field public db_path string | nil where to store the sqlite db. default: ~/.local/share/nvim/cmp_go_deep.sqlite3
---@field public debug boolean | nil whether to enable debug logging. default: false
---@field public min_keyword_length integer | nil minimum completion prefix length. default: 3
---@field public max_items integer | nil maximum completion items to return. default: 10

---@type cmp_go_deep.Options
local default_options = {
	notifications = true,
	get_package_name_implementation = "treesitter",
	exclude_vendored_packages = false,
	exclude_internal_packages = true,
	debounce_gopls_requests_ms = 0,
	db_path = vim.fn.stdpath("data") .. "/cmp_go_deep.sqlite3",
	debug = false,
	min_keyword_length = 3,
	max_items = 10,
}

-- help complete-items
-- help complete-functions
-- help complete()
---@class cmp_go_deep.BufferState
---@field debounced_gopls_request? fun(opts: cmp_go_deep.Options, gopls_client: vim.lsp.Client, bufnr: integer, cursor_prefix_word: string, callback: fun(result: lsp.SymbolInformation[]))

---@class cmp_go_deep.NativeCompleteItem
---@field word string
---@field abbr string
---@field menu string
---@field info string
---@field kind integer
---@field icase integer
---@field dup integer
---@field user_data string
---@field label string
---@field detail string
---@field filterText string
---@field sortText string
---@field data lsp.SymbolInformation

---@class cmp_go_deep.CompleteFuncResult
---@field words cmp_go_deep.NativeCompleteItem[]
---@field refresh 'always'

---@class cmp_go_deep.State
---@field buffers table<integer, cmp_go_deep.BufferState>
---@field cache cmp_go_deep.DB|nil

local augroup = vim.api.nvim_create_augroup("cmp_go_deep", { clear = false })

---@type cmp_go_deep.State
local state = {
	buffers = {},
	cache = nil,
}

local M = {}

---@return cmp_go_deep.Options
local function global_opts()
	if type(vim.g.cmp_go_deep) == "table" then
		return vim.g.cmp_go_deep
	end

	return {}
end

---@return cmp_go_deep.Options
local function resolve_opts()
	return vim.tbl_deep_extend("force", default_options, global_opts())
end

---@param opts cmp_go_deep.Options
---@return cmp_go_deep.DB?
local function ensure_db(opts)
	if state.cache then
		return state.cache
	end

	state.cache = require("cmp_go_deep.db").setup(opts)
	return state.cache
end

---@param prefix string
---@return boolean
local function valid_prefix(prefix)
	return prefix ~= "" and not prefix:match("[%.]") and not prefix:match("[^%w_]")
end

---@param bufnr integer
---@return string
local function current_prefix(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return ""
	end

	return vim.api.nvim_buf_call(bufnr, function()
		return utils.get_cursor_prefix_word(0)
	end)
end

---@return integer
local function complete_start_col()
	local cursor_prefix_word = utils.get_cursor_prefix_word(0)
	if not valid_prefix(cursor_prefix_word) then
		return -3
	end

	local _, col = unpack(vim.api.nvim_win_get_cursor(0))
	return col - #cursor_prefix_word
end

---@param bufnr integer
---@return cmp_go_deep.BufferState
local function ensure_buffer_state(bufnr)
	---@type cmp_go_deep.BufferState?
	local buffer_state = state.buffers[bufnr]
	if buffer_state then
		return buffer_state
	end

	---@type cmp_go_deep.BufferState
	buffer_state = {
		debounced_gopls_request = nil,
	}
	state.buffers[bufnr] = buffer_state
	return buffer_state
end

---@param bufnr integer
local function cleanup_buffer_state(bufnr)
	state.buffers[bufnr] = nil
end

---@return string, string
local function get_project_path_prefixes()
	local project_path = vim.fn.getcwd()
	return "file://" .. project_path .. "/vendor/", "file://" .. project_path .. "/"
end

---@param items cmp_go_deep.NativeCompleteItem[]
---@param max_items integer
local function limit_items(items, max_items)
	if #items > max_items then
		while #items > max_items do
			table.remove(items)
		end
	end
end

---@param items cmp_go_deep.NativeCompleteItem[]
local function apply_native_item_fields(items)
	for _, item in ipairs(items) do
		---@type lsp.SymbolInformation
		local symbol = item.data or {}
		item.info = ""
		item.user_data = utils.encode_complete_user_data({
			import_path = symbol.containerName,
			package_alias = symbol.package_alias,
			uri = symbol.location and symbol.location.uri,
			range = symbol.location and symbol.location.range,
		})
		item.word = item.label
		item.abbr = item.label
		item.menu = item.detail or ""
		item.icase = 1
		item.dup = 0
	end
end

---@param cursor_prefix_word string
---@param result lsp.SymbolInformation[]
---@param vendor_path_prefix string
---@param project_path_prefix string
---@return lsp.SymbolInformation[]
local function normalize_symbols(cursor_prefix_word, result, vendor_path_prefix, project_path_prefix)
	---@type lsp.SymbolInformation[]
	local filtered_result = {}

	for _, symbol in ipairs(result) do
		symbol.name = symbol.name:match("^[^%.]+%.(.*)") or symbol.name
		if
			utils.symbol_to_completion_kind(symbol.kind)
			and not symbol.name:match("/")
			and symbol.name:match("^[A-Z]")
			and not symbol.location.uri:match("test%.go$")
		then
			if string.sub(symbol.location.uri, 1, #vendor_path_prefix) == vendor_path_prefix then
				symbol.isVendored = true
				symbol.location.uri = symbol.location.uri:sub(#vendor_path_prefix + 1)
			elseif string.sub(symbol.location.uri, 1, #project_path_prefix) == project_path_prefix then
				symbol.isLocal = true
				symbol.location.uri = symbol.location.uri:sub(#project_path_prefix + 1)
			end
			symbol.fuzzy_text = string.lower(cursor_prefix_word)
			symbol.name_lower = string.lower(symbol.name)
			table.insert(filtered_result, symbol)
		end
	end

	return filtered_result
end

---@param opts cmp_go_deep.Options
---@param bufnr integer
---@param cursor_prefix_word string
---@return cmp_go_deep.NativeCompleteItem[], table<string, boolean>, string, string, fun(rejected: lsp.SymbolInformation[])
local function get_cached_items(opts, bufnr, cursor_prefix_word)
	local cache = ensure_db(opts)
	if not cache then
		return {}, {}, "", "", function() end
	end

	local vendor_path_prefix, project_path_prefix = get_project_path_prefixes()

	---@type table<string, boolean>
	local processed_items = {}

	---@param rejected lsp.SymbolInformation[]
	local on_reject = function(rejected)
		cache:delete(utils, rejected)
	end

	---@type cmp_go_deep.NativeCompleteItem[]
	local cached_items = utils:process_symbols(
		opts,
		bufnr,
		vendor_path_prefix,
		project_path_prefix,
		cache:load(cursor_prefix_word, "name_lower"),
		processed_items,
		on_reject
	)

	local iter = 13
	local tmp_cursor_prefix_word = string.lower(cursor_prefix_word)
	while #cached_items == 0 and iter > 0 and #tmp_cursor_prefix_word > 0 do
		cached_items = utils:process_symbols(
			opts,
			bufnr,
			vendor_path_prefix,
			project_path_prefix,
			cache:load(tmp_cursor_prefix_word, "fuzzy"),
			processed_items,
			on_reject
		)
		iter = iter - 1
		tmp_cursor_prefix_word = tmp_cursor_prefix_word:sub(1, #tmp_cursor_prefix_word - 1)
	end

	limit_items(cached_items, opts.max_items)
	apply_native_item_fields(cached_items)

	return cached_items, processed_items, vendor_path_prefix, project_path_prefix, on_reject
end

---@param bufnr integer
---@param opts cmp_go_deep.Options
---@param gopls_client vim.lsp.Client
---@param cursor_prefix_word string
---@param processed_items table<string, boolean>
---@param vendor_path_prefix string
---@param project_path_prefix string
---@param on_reject fun(rejected: lsp.SymbolInformation[])
---@param cached_items cmp_go_deep.NativeCompleteItem[]
local function request_symbols(
	bufnr,
	opts,
	gopls_client,
	cursor_prefix_word,
	processed_items,
	vendor_path_prefix,
	project_path_prefix,
	on_reject,
	cached_items
)
	local buffer_state = ensure_buffer_state(bufnr)
	if not buffer_state.debounced_gopls_request then
		buffer_state.debounced_gopls_request = utils.debounce(gopls.workspace_symbols, opts.debounce_gopls_requests_ms)
	end

	---@param result lsp.SymbolInformation[]
	buffer_state.debounced_gopls_request(opts, gopls_client, bufnr, cursor_prefix_word, function(result)
		local cache = ensure_db(opts)
		if not cache then
			return
		end

		local filtered_result =
			normalize_symbols(cursor_prefix_word, result or {}, vendor_path_prefix, project_path_prefix)
		cache:save(utils, filtered_result)

		if #cached_items > 0 or current_prefix(bufnr) ~= cursor_prefix_word then
			return
		end

		---@type cmp_go_deep.NativeCompleteItem[]
		local items = utils:process_symbols(
			opts,
			bufnr,
			vendor_path_prefix,
			project_path_prefix,
			cache:load(cursor_prefix_word, "fuzzy"),
			processed_items,
			on_reject
		)
		limit_items(items, opts.max_items)
		apply_native_item_fields(items)
	end)
end

---@param bufnr integer
local function set_buffer_complete(bufnr)
	local current = vim.api.nvim_buf_call(bufnr, function()
		return vim.opt_local.complete:get()
	end)

	if type(current) == "string" then
		current = vim.split(current, ",", { trimempty = true })
	end

	local filtered = { "F" }
	for _, item in ipairs(current) do
		if item ~= "F" and tostring(item):sub(1, 1) ~= "F" then
			filtered[#filtered + 1] = item
		end
	end

	vim.api.nvim_buf_call(bufnr, function()
		vim.opt_local.complete = filtered
	end)
end

---@param opts cmp_go_deep.Options|nil
---@param findstart integer
---@param base string
---@return integer|cmp_go_deep.CompleteFuncResult
function M.completefunc(findstart, base)
	if findstart == 1 then
		return complete_start_col()
	end

	local bufnr = vim.api.nvim_get_current_buf()
	local opts = resolve_opts()

	local gopls_client = utils.get_gopls_client(bufnr)
	if gopls_client == nil then
		return { words = {}, refresh = "always" }
	end

	local cursor_prefix_word = base
	if #cursor_prefix_word < opts.min_keyword_length or not valid_prefix(cursor_prefix_word) then
		return { words = {}, refresh = "always" }
	end

	if not ensure_db(opts) then
		return { words = {}, refresh = "always" }
	end

	local cached_items, processed_items, vendor_path_prefix, project_path_prefix, on_reject =
		get_cached_items(opts, bufnr, cursor_prefix_word)

	request_symbols(
		bufnr,
		opts,
		gopls_client,
		cursor_prefix_word,
		processed_items,
		vendor_path_prefix,
		project_path_prefix,
		on_reject,
		cached_items
	)

	return { words = cached_items, refresh = "always" }
end

---@param bufnr integer
function M.attach_to_buffer(bufnr)
	ensure_buffer_state(bufnr)

	if not _G.cmp_go_deep_completefunc then
		_G.cmp_go_deep_completefunc = function(findstart, base)
			return require("cmp_go_deep").completefunc(findstart, base)
		end
	end

	vim.bo[bufnr].completefunc = "v:lua.cmp_go_deep_completefunc"
	set_buffer_complete(bufnr)

	vim.api.nvim_clear_autocmds({ group = augroup, buffer = bufnr })

	vim.api.nvim_create_autocmd("CompleteDone", {
		group = augroup,
		buffer = bufnr,
		callback = function()
			require("cmp_go_deep").on_complete_done(bufnr)
		end,
	})

	vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
		group = augroup,
		buffer = bufnr,
		callback = function()
			cleanup_buffer_state(bufnr)
		end,
	})
end

---@param bufnr integer
function M.on_complete_done(bufnr)
	if vim.v.event.reason and vim.v.event.reason ~= "accept" then
		return
	end

	local user_data = utils.decode_complete_user_data(vim.v.completed_item.user_data)
	if not user_data or not user_data.import_path then
		return
	end

	local opts = resolve_opts()
	if utils.get_imported_paths(opts, bufnr)[user_data.import_path] then
		return
	end

	vim.schedule(function()
		utils.add_import_statement(opts, bufnr, user_data.package_alias, user_data.import_path)
	end)
end

return M
