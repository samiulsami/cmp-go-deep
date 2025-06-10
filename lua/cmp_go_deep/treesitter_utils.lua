local treesitter_implementations = {}

---@param bufnr (integer)
---@return TSNode | nil
local function get_root_node(bufnr)
	if bufnr == nil then
		return nil
	end

	if not vim.api.nvim_buf_is_loaded(bufnr) then
		vim.fn.bufload(bufnr)
	end

	local parser = vim.treesitter.get_parser(bufnr, "go")
	if parser == nil then
		return nil
	end
	local root = nil
	parser = parser:parse()
	if parser ~= nil then
		root = parser[1]:root()
	end
	return root
end

---@param opts cmp_go_deep.Options
---@param bufnr (integer)
---@param package_alias string | nil
---@param import_path string
treesitter_implementations.add_import_statement = function(opts, bufnr, package_alias, import_path)
	local root = get_root_node(bufnr)
	if root == nil then
		return
	end

	if not package_alias then
		package_alias = ""
	else
		package_alias = package_alias .. " "
	end

	---@type TSNode | nil
	local import_node = nil
	for node in root:iter_children() do
		if node:type() == "import_declaration" then
			import_node = node
			break
		end
	end

	if import_node then
		local start_row, _, end_row, _ = import_node:range()
		if import_node:named_child_count() == 1 then
			local child = import_node:named_child(0)
			if not child then
				if opts.notifications then
					vim.notify("could not parse import line with treesitter", vim.log.levels.WARN)
				end
				return
			end

			local type = child:type()
			if type == "interpreted_string_literal" or type == "raw_string_literal" or type == "import_spec" then
				vim.api.nvim_buf_set_lines(bufnr, start_row, end_row + 1, false, {
					"import (",
					"\t" .. vim.treesitter.get_node_text(child, bufnr),
					"\t" .. package_alias .. '"' .. import_path .. '"',
					")",
				})
				return
			end
		end

		local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)
		if not lines[#lines]:match("^%s*%)") then
			if opts.notifications then
				vim.notify("could not parse import block with treesitter", vim.log.levels.WARN)
			end
			return
		end

		table.insert(lines, #lines, "\t" .. package_alias .. '"' .. import_path .. '"')
		vim.api.nvim_buf_set_lines(bufnr, start_row, end_row + 1, false, lines)
	else
		local insert_line = 0
		for i, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
			if line:match("^package%s+") then
				insert_line = i
				break
			end
		end

		vim.api.nvim_buf_set_lines(bufnr, insert_line, insert_line, false, {
			"",
			"import (",
			"\t" .. package_alias .. '"' .. import_path .. '"',
			")",
			"",
		})
	end
end

---@param str string
---@return string
---@return integer count
local function trim_quotes(str)
	return str:gsub('^["`]+', ""):gsub('["`]+$', "")
end

---@param opts cmp_go_deep.Options
---@param bufnr (integer)
---@return table<string, string> -- key: import path, value: package alias
treesitter_implementations.get_imported_paths = function(opts, bufnr)
	local root = get_root_node(bufnr)
	if root == nil then
		return {}
	end

	---@type TSNode | nil
	local import_node = nil
	for i = 0, root:named_child_count() - 1 do
		local node = root:named_child(i)
		if node and node:type() == "import_declaration" then
			import_node = node
			break
		end
	end
	if import_node == nil then
		return {}
	end

	local imported_paths = {}
	---@param spec TSNode?
	local process_import_spec = function(spec)
		local path_node = spec and spec:field("path")[1]
		local name_node = spec and spec:field("name")[1]
		if path_node then
			local text = vim.treesitter.get_node_text(path_node, bufnr)
			if text then
				text = trim_quotes(text)
				local package_alias = name_node and vim.treesitter.get_node_text(name_node, bufnr)
				package_alias = package_alias or text:match("([^/]+)$")
				if package_alias == nil and opts.notifications then
					vim.notify("could not parse import line with treesitter " .. text, vim.log.levels.WARN)
				end
				imported_paths[text] = package_alias
			end
		end
	end

	for j = 0, import_node:named_child_count() - 1 do
		local child = import_node:named_child(j)
		if not child then
			goto continue
		end

		local type = child:type()
		if type == "import_spec" and child:named_child_count() > 0 then -- single line import
			process_import_spec(child:named_child(0))
			goto continue
		end

		if type == "import_spec_list" then -- multiline import
			for k = 0, child:child_count() - 1 do
				process_import_spec(child:named_child(k))
			end
			break
		end

		::continue::
	end

	return imported_paths
end

---@param uri string
---@return string|nil
treesitter_implementations.get_package_name = function(uri)
	local filepath = vim.uri_to_fname(uri)
	local bufnr = vim.fn.bufadd(filepath)
	local root = get_root_node(bufnr)
	if not root then
		return nil
	end

	for node in root:iter_children() do
		if node:type() == "package_clause" then
			for child in node:iter_children() do
				if child:type() == "package_identifier" then
					return vim.treesitter.get_node_text(child, bufnr)
				end
			end
		end
	end

	return nil
end

return treesitter_implementations
