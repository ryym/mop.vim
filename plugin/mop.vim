" mop.vim - Vim / Neovim integration for mop.
"
" Run :Mop in a Markdown buffer. The preview opens in the browser and then
" follows the buffer: edits are pushed with `mop update` (from the buffer, not
" the file on disk, so unsaved text shows up), and scrolling is pushed with
" `mop scroll`. :MopClose stops the sync.
"
" The implementation lives in autoload/mop.vim, so nothing beyond this file is
" loaded until :Mop is first run.

if exists('g:loaded_mop')
  finish
endif
let g:loaded_mop = 1

let g:mop_command = get(g:, 'mop_command', 'mop')

" Edits and scrolling fire far more often than a preview can be useful, so
" both are coalesced with a timer.
let g:mop_update_delay = get(g:, 'mop_update_delay', 150)
let g:mop_scroll_delay = get(g:, 'mop_scroll_delay', 60)

" Where the tracked line is placed in the preview window. The tracked line is
" the top of the editor window, so 0.0 puts the two viewports at the same
" place; raise it to leave some context above.
let g:mop_viewport_ratio = get(g:, 'mop_viewport_ratio', 0.0)

command! -bar Mop call mop#open()
command! -bar MopClose call mop#close_current()
