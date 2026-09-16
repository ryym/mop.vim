# mop.vim

Vim / Neovim integration for [mop](https://github.com/ryym/mop), a Markdown
previewer that follows the editor.

## Requirements

- Vim with `+job` and `+timers`, or Neovim
- The `mop` CLI

## Installation

Install it with any plugin manager, for example [vim-plug](https://github.com/junegunn/vim-plug):

```vim
Plug 'ryym/mop.vim'
let g:mop_command = '/path/to/mop'   " when mop is not on PATH
```

## Usage

| Command     | Effect                                                 |
| ----------- | ------------------------------------------------------ |
| `:Mop`      | Open a preview of the current buffer and start syncing |
| `:MopClose` | Stop syncing and close the preview                     |

After `:Mop`:

- Buffer edits are sent with `mop update`, **including unsaved text**.
- The window's view is sent with `mop scroll`, so the preview follows where the window scrolls to.
- Closing the buffer or quitting the editor runs `mop close` automatically.

## Configuration

| Variable               | Default | Meaning                                 |
| ---------------------- | ------- | --------------------------------------- |
| `g:mop_command`        | `mop`   | Command to run                          |
| `g:mop_update_delay`   | 150     | Debounce before sending an edit (ms)    |
| `g:mop_scroll_delay`   | 60      | Debounce before sending a scroll (ms)   |
| `g:mop_viewport_ratio` | 0.0     | Where in the viewport to place the line |

See `:help mop` for details.
