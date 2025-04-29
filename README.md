# cmp-go-deep

A GoLang ```deep-completion``` source for [nvim-cmp](https://github.com/hrsh7th/nvim-cmp) / [blink-cmp](https://github.com/Saghen/blink.cmp), that works alongside [cmp-nvim-lsp](https://github.com/hrsh7th/cmp-nvim-lsp) / [blink-cmp](https://github.com/Saghen/blink.cmp)'s LSP source and provides completion suggestions for <b> "<i>UNIMPORTED</i> LOCAL, STANDARD LIBRARY, AND VENDORED PACKAGES ONLY".</b> 

#### Why?

At the time of writing, the GoLang Language Server (```gopls@v0.18.1```) doesn't seem to support deep completions for unimported pacakges. For example, with deep completion enabled, typing ```'cha'``` could suggest ```'rand.NewChaCha8()'``` as a possible completion option - but that is not the case no matter how high the completion budget is set for ```gopls```.


#### How?


Query  ```gopls's``` ```workspace/symbol``` endpoint, convert the resulting symbols into ```completionItemKinds```, filter the results to only include the ones that are unimported, then finally feed them back into ```nvim-cmp``` / ```blink.cmp```

---
#### Demo

* Note: Due to how gopls indexes packages, completions for standard library packages are not available until at least one of them is manually imported.
<p align="center">
  <img src="./demo.gif" alt="demo" />
</p>

---
## Requirements
- [nvim-cmp](https://github.com/hrsh7th/nvim-cmp) 

OR
- [blink.cmp](https://github.com/saghen/blink.cmp)

## Setup
#### Lazy.nvim
##### - nvim-cmp
```lua
{
    "hrsh7th/nvim-cmp",
    dependencies = {
        { "samiulsami/cmp-go-deep" },
    },
    ...
    require("cmp").setup({
        sources = {{
            name = "go_deep",
            option = {
                -- See below for configuration options
            },
        }},
    })
}
```
##### - blink.cmp <i>(requires saghen/blink.compat)</i>
```lua
{
	"saghen/blink.cmp",
	dependencies = {
		{ "samiulsami/cmp-go-deep" },
		{ "saghen/blink.compat" },
	},
	opts = {
		sources = {
			default = {
				"go_deep",
			},
			providers = {
				go_deep = {
					name = "go_deep",
					module = "blink.compat.source",
					opts = {
						-- See below for configuration options
					},
				},
			},
		},
	},
}
```
### Default options
```lua
{
	-- Timeout in milliseconds for getting workspace symbols from gopls.
	-- Warning: Setting this too high causes a noticeable delay in huge codebases.
	workspace_symbol_timeout_ms = 150,

	-- Enable/disable timeout notifications
	timeout_notifications = true,

	-- Timeout in milliseconds for getting documentation
	-- Note: Only used when `get_documentation_implementation` is not `"regex"`.
	documentation_wait_timeout_ms = 200,

	-- Whether to get documentation with lsp 'textDocument/hover', or extract it with regex
	-- options: "hover" | "regex"
	get_documentation_implementation = "hover",

	-- Whether to get package name with 'treesitter' or 'regex'
	-- Known issue: The `regex` implementation doesn't work for package names declared like: `/* hehe */ package xd`
	get_package_name_implementation = "regex",

	-- Whether to exclude vendored packages from completions
	-- Note: Enabling this option has a negligible effect on performance.
	exclude_vendored_packages = false,
}
```
---
#### TODO
- [ ] Cache results for faster completions.
- [ ] Remove the indirect dependency on ```cmp-nvim-lsp``` or ```blink.cmp's``` LSP source.
