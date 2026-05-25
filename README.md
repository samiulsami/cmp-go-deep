# cmp-go-deep

Native Neovim completion for deep Go symbol lookup from unimported packages.

It queries `gopls` `workspace/symbol`, caches normalized results in sqlite, filters them down to valid unimported symbols, and serves them through `completefunc`. Accepting a completion inserts the missing import automatically.

## Requirements

- Neovim master / 0.13+
- `gopls`
- [sqlite.lua](https://github.com/kkharji/sqlite.lua)

## Setup

```lua
require("cmp_go_deep").setup({
	debounce_gopls_requests_ms = 75,
	native_min_keyword_length = 2,
	native_max_items = 20,
})

vim.api.nvim_create_autocmd("LspAttach", {
	callback = function(ev)
		local client = vim.lsp.get_client_by_id(ev.data.client_id)
		if client and client.name == "gopls" and vim.bo[ev.buf].filetype == "go" then
			require("cmp_go_deep").attach_to_buffer(ev.buf)
		end
	end,
})
```

Use native insert completion as usual. `cmp-go-deep` handles `completefunc`, async prefetch, cached matches, and `CompleteDone` import insertion.

## Default options

```lua
{
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
```

## Flow

1. `attach_to_buffer()` installs `completefunc` and autocommands.
2. Typing triggers async `workspace/symbol` prefetch with debounce.
3. Results are normalized and saved to sqlite.
4. `completefunc()` returns cached native completion items.
5. `CompleteDone` inserts the selected import when needed.

## Notes

- This plugin now supports only native Neovim completion.
- Standard library results still depend on what `gopls` has indexed.
