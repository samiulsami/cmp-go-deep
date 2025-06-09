--FIXME: don't use recursion.
local function scan_directory(root_dir, callback)
	local uv = vim.loop
	local files = {}
	local pending = 0

	local function scan_dir(path)
		pending = pending + 1

		uv.fs_scandir(path, function(err, handle)
			if err then
				pending = pending - 1
				if pending == 0 then
					callback(files)
				end
				return
			end

			while true do
				local name, type = uv.fs_scandir_next(handle)
				if not name then
					break
				end

				if type == "file" and string.match(name, "%.go$") then
					table.insert(files, path .. "/" .. name)
				elseif type == "directory" then
					scan_dir(path .. name)
				end
			end

			pending = pending - 1
			if pending == 0 then
				callback(files)
			end
		end)
	end

	scan_dir(root_dir)
end

local handle = io.popen("go env GOROOT")
if not handle then
	vim.notify("failed to get GOROOT", vim.log.levels.ERROR)
	return
end

local goroot = handle:read("*a"):gsub("%s+", "")
if not goroot then
	vim.notify("failed to get GOROOT", vim.log.levels.ERROR)
	handle:close()
	return
end

handle:close()

local src_dir = goroot .. "/src/"
scan_directory(src_dir, function(files)
	vim.schedule(function()
		vim.notify("Symbols found: " .. #files)
		local gopls_client = require("cmp_go_deep.utils").get_gopls_client()
		if gopls_client == nil then
			vim.notify("gopls client is nil", vim.log.levels.ERROR)
			return
		end

		for _, file in ipairs(files) do
			local uri = "file://" .. file

			gopls_client:request("textDocument/documentSymbol", {
				textDocument = {
					uri = uri,
				},
			}, function(err, result)
				if err then
					vim.notify("error fetching document symbols for file: " .. file, vim.log.levels.ERROR)
					return
				end
				vim.notify(#result .. " symbols found for file: " .. file, vim.log.levels.INFO)
			end)
		end
	end)
end)
