# stacker.nvim

Quickly access and manage recently used neovim buffers

Inspired by [harpoon](https://github.com/ThePrimeagen/harpoon)

## Note

stacker.nvim is still under development. Some features such as session storage will encounter errors in some cases.

## Installation

### With lazy.nvim

Add the following to your lazy config:

```lua
{
  "tripplyons/stacker.nvim",
}
```

Then, call the setup command, and create keybinds:

```lua
local stacker = require('stacker')
stacker.setup({})

-- <leader>1 will navigate to the most recently used buffer, <leader>2 for 2nd most recently used buffer, etc.
for i = 1, 9 do
  vim.keymap.set('n', '<leader>' .. i, function()
    stacker.navigate(i)
  end)
end

-- <leader>0 will navigate to the 10th most recently used buffer
vim.keymap.set('n', '<leader>0', function()
  stacker.navigate(10)
end)

-- <leader>dh will delete the buffer history
vim.keymap.set('n', '<leader>dh', function()
  stacker.clear_history()
end)
```

## Customization

### Default Options

```lua
{
  max_buffers = 10,
  separator = '  ',
  show_tabline = true,
  storage_path = vim.fn.stdpath('data') .. '/stacker.json',
  load_cursor_position = false,
  use_storage = false,
}
```

### Custom Colors

```lua
inactive_color = '#808080' -- replace with a custom color
active_color = '#ffffff' -- replace with a custom color
number_color = '#ff0000' -- replace with a custom color
vim.cmd('highlight! StackerInactive guibg=NONE guifg='..inactive_color)
vim.cmd('highlight! StackerActive guibg=NONE guifg='..active_color)
vim.cmd('highlight! StackerNumber guibg=NONE guifg='..number_color)
```
