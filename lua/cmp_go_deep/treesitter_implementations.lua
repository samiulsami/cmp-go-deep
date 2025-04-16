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

---@param bufnr (integer)
---@param import_path string
treesitter_implementations.add_import_statement = function(bufnr, import_path)
	local root = get_root_node(bufnr)
	if root == nil then
		return
	end

	local import_node = nil
	for node in root:iter_children() do
		if node:type() == "import_declaration" then
			import_node = node
			break
		end
	end

	if import_node then
		local start_row, _, end_row, _ = import_node:range()
		local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)

		if import_node:named_child_count() == 1 then
			local child = import_node:named_child(0)
			local type = child:type()

			if type == "interpreted_string_literal" or type == "raw_string_literal" or type == "import_spec" then
				local import_text = vim.treesitter.get_node_text(child, bufnr)
				local indent = "\t"
				local new_lines = {
					"import (",
					indent .. import_text,
					indent .. '"' .. import_path .. '"',
					")",
				}
				vim.api.nvim_buf_set_lines(bufnr, start_row, end_row + 1, false, new_lines)
				return
			end
		end

		for i = #lines, 1, -1 do
			if lines[i]:match("^%s*%)") then
				table.insert(lines, i, '\t"' .. import_path .. '"')
				break
			end
		end

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
			'\t"' .. import_path .. '"',
			")",
			"",
		})
	end
end

---@param bufnr (integer)
---@return table<string, boolean>
treesitter_implementations.get_imported_paths = function(bufnr)
	local root = get_root_node(bufnr)
	if root == nil then
		return {}
	end

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

	for j = 0, import_node:named_child_count() - 1 do
		local child = import_node:named_child(j)
		if not child then
			goto continue
		end

		local type = child:type()

		if type == "interpreted_string_literal" or type == "raw_string_literal" then
			local text = vim.treesitter.get_node_text(child, bufnr)
			text = text:gsub('^["`]+', ""):gsub('["`]+$', "")
			imported_paths[text] = true
			goto continue
		end

		if type == "import_spec_list" then
			for k = 0, child:named_child_count() - 1 do
				local spec = child:named_child(k)
				local path_node = spec and spec:field("path")[1]
				if path_node then
					local text = vim.treesitter.get_node_text(path_node, bufnr)
					text = text:gsub('^["`]+', ""):gsub('["`]+$', "")
					imported_paths[text] = true
				end
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
