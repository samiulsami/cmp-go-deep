local utils = require("cmp_go_deep.utils")
local gopls = require("cmp_go_deep.gopls")
local completion_item_kind = vim.lsp.protocol.CompletionItemKind

---@class cmp_go_deep.Options
---@field public notifications boolean|nil
---@field public filetypes string[]|nil
---@field public get_package_name_implementation "treesitter"|"regex"|nil
---@field public exclude_vendored_packages boolean|nil
---@field public exclude_internal_packages boolean|nil
---@field public debounce_gopls_requests_ms integer|nil
---@field public db_path string|nil
---@field public native_min_keyword_length integer|nil
---@field public native_max_items integer|nil

---@type cmp_go_deep.Options
local defaults = {
	notifications = true,
	filetypes = { "go" },
	get_package_name_implementation = "regex",
	exclude_vendored_packages = false,
	exclude_internal_packages = true,
	debounce_gopls_requests_ms = 75,
	db_path = vim.fn.stdpath("data") .. "/cmp_go_deep.sqlite3",
	native_min_keyword_length = 3,
	native_max_items = 10,
}

local native_augroup = vim.api.nvim_create_augroup("cmp_go_deep_native", { clear = false })

local native_kind_map = {
	[completion_item_kind.Enum] = "e",
	[completion_item_kind.Interface] = "i",
	[completion_item_kind.Function] = "f",
	[completion_item_kind.Variable] = "v",
	[completion_item_kind.Constant] = "c",
	[completion_item_kind.Struct] = "s",
	[completion_item_kind.TypeParameter] = "t",
}

local state = {
	opts = vim.deepcopy(defaults),
	buffer_opts = {},
	buffers = {},
	cache = nil,
	docs = {},
	warmed_clients = {},
}

local M = {}
local decode_user_data

local function resolve_opts(bufnr, extra_opts)
	return vim.tbl_deep_extend("force", defaults, state.opts, state.buffer_opts[bufnr] or {}, extra_opts or {})
end

local function ensure_db(opts)
	if state.cache then
		return state.cache
	end

	state.cache = require("cmp_go_deep.db").setup(opts)
	return state.cache
end

local function allowed_filetype(opts, bufnr)
	local filetype = vim.bo[bufnr].filetype
	for _, candidate in ipairs(opts.filetypes or {}) do
		if filetype == candidate then
			return true
		end
	end
	return false
end

local function current_line_prefix(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return ""
	end

	return vim.api.nvim_buf_call(bufnr, function()
		local _, col = unpack(vim.api.nvim_win_get_cursor(0))
		local line = vim.api.nvim_get_current_line()
		local before_cursor = line:sub(1, col)
		return before_cursor:match("[%w_]+$") or ""
	end)
end

local function valid_prefix(prefix)
	return prefix ~= "" and not prefix:match("[.]") and not prefix:match("[^%w_]")
end

local function complete_start_col()
	local row, col = unpack(vim.api.nvim_win_get_cursor(0))
	if not row then
		return -3
	end

	local line = vim.api.nvim_get_current_line()
	local before_cursor = line:sub(1, col)
	local prefix = before_cursor:match("[%w_]+$")
	if not prefix or prefix == "" then
		return -3
	end

	return col - #prefix
end

local function ensure_buffer_state(bufnr)
	local buf = state.buffers[bufnr]
	if buf then
		return buf
	end

	buf = {
		generation = 0,
		last_prefix = "",
		last_retriggered_prefix = "",
		pending_request_id = nil,
		pending_prefix = nil,
		pending_generation = nil,
		item_cache = {},
		cache_order = {},
		timer = vim.uv.new_timer(),
	}
	state.buffers[bufnr] = buf
	return buf
end

local function invalidate_item_cache(bufnr)
	local buf = ensure_buffer_state(bufnr)
	buf.item_cache = {}
	buf.cache_order = {}
	buf.last_retriggered_prefix = ""
end

local function cache_items(bufnr, prefix, items)
	local buf = ensure_buffer_state(bufnr)
	if buf.item_cache[prefix] == nil then
		buf.cache_order[#buf.cache_order + 1] = prefix
	end
	buf.item_cache[prefix] = items

	while #buf.cache_order > 32 do
		local oldest = table.remove(buf.cache_order, 1)
		buf.item_cache[oldest] = nil
	end
end

local function cancel_pending_request(bufnr)
	local buf = ensure_buffer_state(bufnr)
	local request_id = buf.pending_request_id
	if not request_id then
		return
	end

	local client = utils.get_gopls_client(bufnr)
	if client and client.cancel_request then
		pcall(client.cancel_request, client, request_id)
	end

	buf.pending_request_id = nil
	buf.pending_prefix = nil
	buf.pending_generation = nil
end

local function cleanup_buffer_state(bufnr)
	local buf = state.buffers[bufnr]
	if not buf then
		return
	end

	cancel_pending_request(bufnr)
	if buf.timer then
		buf.timer:stop()
		buf.timer:close()
	end

	state.buffers[bufnr] = nil
	state.buffer_opts[bufnr] = nil
end

local function new_context(opts, bufnr)
	local project_path = vim.fn.getcwd()
	local cache = ensure_db(opts)
	local ctx = {
		bufnr = bufnr,
		cache = cache,
		processed_items = {},
		vendor_path_prefix = "file://" .. project_path .. "/vendor/",
		project_path_prefix = "file://" .. project_path .. "/",
	}

	ctx.on_reject = function(rejected)
		if ctx.cache then
			ctx.cache:delete(utils, rejected)
		end
	end

	return ctx
end

local function normalize_symbols(prefix, result, vendor_path_prefix, project_path_prefix)
	local filtered = {}
	for _, symbol in ipairs(result or {}) do
		symbol.name = symbol.name:match("^[^%.]+%.(.*)") or symbol.name
		if utils.symbol_to_completion_kind(symbol.kind)
			and not symbol.name:match("/")
			and symbol.name:match("^[A-Z]")
			and not symbol.location.uri:match("test%.go$")
		then
			if symbol.location.uri:sub(1, #vendor_path_prefix) == vendor_path_prefix then
				symbol.isVendored = true
				symbol.location.uri = symbol.location.uri:sub(#vendor_path_prefix + 1)
			elseif symbol.location.uri:sub(1, #project_path_prefix) == project_path_prefix then
				symbol.isLocal = true
				symbol.location.uri = symbol.location.uri:sub(#project_path_prefix + 1)
			end
			symbol.fuzzy_text = string.lower(prefix)
			symbol.name_lower = string.lower(symbol.name)
			filtered[#filtered + 1] = symbol
		end
	end
	return filtered
end

local function load_processed_items(opts, ctx, prefix)
	if not ctx.cache then
		return {}
	end

	local items = utils:process_symbols(
		opts,
		ctx.bufnr,
		ctx.vendor_path_prefix,
		ctx.project_path_prefix,
		ctx.cache:load(prefix, "name_lower"),
		ctx.processed_items,
		ctx.on_reject
	)

	local fuzzy_prefix = string.lower(prefix)
	local remaining = 12
	while #items == 0 and remaining > 0 and #fuzzy_prefix > 0 do
		items = utils:process_symbols(
			opts,
			ctx.bufnr,
			ctx.vendor_path_prefix,
			ctx.project_path_prefix,
			ctx.cache:load(fuzzy_prefix, "fuzzy"),
			ctx.processed_items,
			ctx.on_reject
		)
		remaining = remaining - 1
		fuzzy_prefix = fuzzy_prefix:sub(1, #fuzzy_prefix - 1)
	end

	return items
end

local function make_complete_items(opts, items)
	local complete_items = {}
	for _, item in ipairs(items) do
		if opts.native_max_items > 0 and #complete_items >= opts.native_max_items then
			break
		end

		local symbol = item.data or {}
		local doc_key = utils.deterministic_symbol_hash(symbol)
		complete_items[#complete_items + 1] = {
			word = item.label,
			abbr = item.label,
			menu = item.detail or "",
			kind = native_kind_map[item.kind] or "",
			icase = 1,
			dup = 0,
			info = state.docs[doc_key] or "",
			user_data = vim.json.encode({
				cmp_go_deep = {
					doc_key = doc_key,
					import_path = symbol.containerName,
					package_alias = symbol.package_alias,
					uri = symbol.location and symbol.location.uri,
					range = symbol.location and symbol.location.range,
				},
			}),
		}
	end
	return complete_items
end

local function update_cached_item_docs(bufnr, doc_key, info)
	local buf = ensure_buffer_state(bufnr)
	for _, items in pairs(buf.item_cache) do
		for _, item in ipairs(items) do
			local user_data = decode_user_data(item.user_data)
			if user_data and user_data.doc_key == doc_key then
				item.info = info
			end
		end
	end
end

local function maybe_show_documentation(bufnr)
	local completed_item = vim.v.event.completed_item or {}
	if (completed_item.info or "") ~= "" then
		return
	end

	local user_data = decode_user_data(completed_item.user_data)
	if not user_data or not user_data.doc_key or not user_data.uri or not user_data.range then
		return
	end

	local info = state.docs[user_data.doc_key]
	if not info then
		info = utils.get_documentation(user_data.uri, user_data.range)
		state.docs[user_data.doc_key] = info
		update_cached_item_docs(bufnr, user_data.doc_key, info)
	end

	if info == "" then
		return
	end

	local data = vim.fn.complete_info({ "selected" })
	if type(data.selected) ~= "number" or data.selected < 0 then
		return
	end

	pcall(vim.api.nvim__complete_set, data.selected, { info = info })
end

local function build_items_for_prefix(bufnr, prefix, opts)
	local ctx = new_context(opts, bufnr)
	if not ctx.cache then
		return {}
	end

	local processed = load_processed_items(opts, ctx, prefix)
	local complete_items = make_complete_items(opts, processed)
	if #complete_items > 0 then
		cache_items(bufnr, prefix, complete_items)
	end
	return complete_items
end

local function maybe_retrigger_completion(bufnr, prefix)
	local buf = ensure_buffer_state(bufnr)
	if buf.last_retriggered_prefix == prefix then
		return
	end
	if not vim.bo[bufnr].autocomplete then
		return
	end

	vim.schedule(function()
		if not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_get_current_buf() ~= bufnr then
			return
		end
		if not vim.api.nvim_get_mode().mode:match("^i") then
			return
		end
		if vim.fn.pumvisible() == 1 then
			return
		end
		if current_line_prefix(bufnr) ~= prefix then
			return
		end

		buf.last_retriggered_prefix = prefix
		vim.api.nvim_feedkeys(vim.keycode("<C-x><C-u>"), "n", false)
	end)
end

local function warmup_gopls(bufnr, opts)
	local client = utils.get_gopls_client(bufnr)
	if not client then
		return nil
	end

	if not state.warmed_clients[client.id] then
		state.warmed_clients[client.id] = true
		gopls.workspace_symbols(opts, client, bufnr, "", function() end)
	end

	return client
end

local function request_symbols(bufnr, prefix, opts, immediate, skip_prefix_check)
	local buf = ensure_buffer_state(bufnr)
	buf.generation = buf.generation + 1
	local generation = buf.generation
	buf.last_prefix = prefix

	if buf.timer then
		buf.timer:stop()
	end

	local delay = immediate and 0 or math.max(opts.debounce_gopls_requests_ms or 0, 0)
	buf.timer:start(delay, 0, function()
		vim.schedule(function()
			if not vim.api.nvim_buf_is_valid(bufnr) then
				return
			end
			if buf.generation ~= generation then
				return
			end
			if not skip_prefix_check and current_line_prefix(bufnr) ~= prefix then
				return
			end

			local client = warmup_gopls(bufnr, opts)
			if not client then
				return
			end

			cancel_pending_request(bufnr)
			local ctx = new_context(opts, bufnr)
			if not ctx.cache then
				return
			end

			local ok, request_id = gopls.workspace_symbols(opts, client, bufnr, prefix, function(result)
				local current_buf = ensure_buffer_state(bufnr)
				if current_buf.pending_request_id == request_id then
					current_buf.pending_request_id = nil
					current_buf.pending_prefix = nil
					current_buf.pending_generation = nil
				end

				if not vim.api.nvim_buf_is_valid(bufnr) then
					return
				end

				local normalized = normalize_symbols(prefix, result or {}, ctx.vendor_path_prefix, ctx.project_path_prefix)
				if #normalized > 0 then
					ctx.cache:save(utils, normalized)
				end

				build_items_for_prefix(bufnr, prefix, opts)
				if current_buf.generation == generation and current_line_prefix(bufnr) == prefix then
					maybe_retrigger_completion(bufnr, prefix)
				end
			end)

			if ok then
				buf.pending_request_id = request_id
				buf.pending_prefix = prefix
				buf.pending_generation = generation
			end
		end)
	end)
end

local function ensure_prefetch(bufnr, opts, prefix, immediate, skip_prefix_check)
	local buf = ensure_buffer_state(bufnr)
	prefix = prefix or current_line_prefix(bufnr)

	if not allowed_filetype(opts, bufnr) then
		return
	end

	if #prefix < opts.native_min_keyword_length or not valid_prefix(prefix) then
		buf.last_prefix = prefix
		buf.last_retriggered_prefix = ""
		cancel_pending_request(bufnr)
		if buf.timer then
			buf.timer:stop()
		end
		return
	end

	if buf.last_prefix ~= prefix then
		buf.last_retriggered_prefix = ""
	end

	if buf.pending_prefix == prefix or buf.item_cache[prefix] ~= nil then
		buf.last_prefix = prefix
		return
	end

	request_symbols(bufnr, prefix, opts, immediate, skip_prefix_check)
end

decode_user_data = function(user_data)
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

function M.setup(opts)
	state.opts = vim.tbl_deep_extend("force", state.opts, opts or {})
	return M
end

function M.completefunc(findstart, base)
	if findstart == 1 then
		return complete_start_col()
	end

	local bufnr = vim.api.nvim_get_current_buf()
	local opts = resolve_opts(bufnr)
	if not allowed_filetype(opts, bufnr) then
		return { words = {}, refresh = "always" }
	end
	if #base < opts.native_min_keyword_length or not valid_prefix(base) then
		return { words = {}, refresh = "always" }
	end

	local buf = ensure_buffer_state(bufnr)
	local items = buf.item_cache[base]
	if items == nil then
		items = build_items_for_prefix(bufnr, base, opts)
		if #items == 0 then
			ensure_prefetch(bufnr, opts, base, true, true)
		end
	end

	return {
		words = items,
		refresh = "always",
	}
end

function M.attach_to_buffer(bufnr, opts)
	state.buffer_opts[bufnr] = vim.tbl_deep_extend("force", state.buffer_opts[bufnr] or {}, opts or {})
	local resolved = resolve_opts(bufnr)
	local buf = ensure_buffer_state(bufnr)

	if not buf.timer then
		buf.timer = vim.uv.new_timer()
	end

	if not _G.cmp_go_deep_completefunc then
		_G.cmp_go_deep_completefunc = function(findstart, base)
			return require("cmp_go_deep").completefunc(findstart, base)
		end
	end

	vim.bo[bufnr].completefunc = "v:lua.cmp_go_deep_completefunc"
	set_buffer_complete(bufnr)

	vim.api.nvim_clear_autocmds({ group = native_augroup, buffer = bufnr })

	vim.api.nvim_create_autocmd("CompleteDone", {
		group = native_augroup,
		buffer = bufnr,
		callback = function()
			require("cmp_go_deep").on_complete_done(bufnr)
		end,
	})

	vim.api.nvim_create_autocmd("CompleteChanged", {
		group = native_augroup,
		buffer = bufnr,
		callback = function()
			require("cmp_go_deep").on_complete_changed(bufnr)
		end,
	})

	vim.api.nvim_create_autocmd({ "TextChangedI", "TextChangedP" }, {
		group = native_augroup,
		buffer = bufnr,
		callback = function()
			local current_opts = resolve_opts(bufnr)
			ensure_prefetch(bufnr, current_opts, nil, false)
		end,
	})

	vim.api.nvim_create_autocmd("InsertLeave", {
		group = native_augroup,
		buffer = bufnr,
		callback = function()
			buf.last_prefix = ""
			buf.last_retriggered_prefix = ""
			cancel_pending_request(bufnr)
			if buf.timer then
				buf.timer:stop()
			end
		end,
	})

	vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
		group = native_augroup,
		buffer = bufnr,
		callback = function()
			cleanup_buffer_state(bufnr)
		end,
	})

	warmup_gopls(bufnr, resolved)
	ensure_prefetch(bufnr, resolved, nil, true)
end

function M.on_complete_done(bufnr)
	local user_data = decode_user_data(vim.v.completed_item.user_data)
	if not user_data or not user_data.import_path then
		return
	end

	local opts = resolve_opts(bufnr)
	if utils.get_imported_paths(opts, bufnr)[user_data.import_path] then
		return
	end

	vim.schedule(function()
		utils.add_import_statement(opts, bufnr, user_data.package_alias, user_data.import_path)
		invalidate_item_cache(bufnr)
	end)
end

function M.on_complete_changed(bufnr)
	maybe_show_documentation(bufnr)
end

return M
