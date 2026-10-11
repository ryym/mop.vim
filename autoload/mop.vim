" Implementation of mop.vim. See plugin/mop.vim for the settings and commands.
"
" Everything is fed to the `mop` CLI asynchronously; the editor never waits.
" The only exception is `mop close`, see s:close_request.

" bufnr -> {path, line, ratio, update_timer, scroll_timer}
let s:sessions = {}

function! s:error(msg) abort
  echohl ErrorMsg
  echomsg 'mop: ' . a:msg
  echohl None
endfunction

" The exit status `mop update`, `mop scroll` and `mop close` use when the
" document has no preview: either no daemon is running, or the running one
" does not know the document.
let s:exit_no_preview = 3

" s:run starts the CLI without blocking and returns a job handle, or v:null if
" it could not be started. The optional opts may have:
"   stdin: list of lines to feed to the command (default: none)
"   on_no_preview: called instead of reporting the error when the command
"                  exits with s:exit_no_preview (default: none)
function! s:run(args, ...) abort
  let l:opts = a:0 > 0 ? a:1 : {}
  let l:cmd = [g:mop_command] + a:args
  let l:stdin = get(l:opts, 'stdin', [])
  let l:text = empty(l:stdin) ? '' : join(l:stdin, "\n") . "\n"
  " Collect the exit status and stderr here and handle the result only once
  " both are in, because the callbacks delivering them run in no guaranteed
  " order.
  let l:state = {
        \ 'stderr': [],
        \ 'stderr_done': 0,
        \ 'status': v:null,
        \ 'on_no_preview': get(l:opts, 'on_no_preview', v:null),
        \ }

  if has('nvim')
    let l:job = jobstart(l:cmd, {
          \ 'stderr_buffered': 1,
          \ 'on_stderr': function('s:on_stderr_nvim', [l:state]),
          \ 'on_exit': function('s:on_exit_nvim', [l:state]),
          \ })
    if l:job <= 0
      call s:error('failed to run ' . g:mop_command)
      return v:null
    endif
    if !empty(l:text)
      call chansend(l:job, l:text)
    endif
    call chanclose(l:job, 'stdin')
    return l:job
  endif

  let l:job = job_start(l:cmd, {
        \ 'in_io': 'pipe',
        \ 'out_io': 'null',
        \ 'err_cb': function('s:on_stderr_vim', [l:state]),
        \ 'close_cb': function('s:on_close_vim', [l:state]),
        \ 'exit_cb': function('s:on_exit_vim', [l:state]),
        \ })
  if job_status(l:job) ==# 'fail'
    call s:error('failed to run ' . g:mop_command)
    return v:null
  endif
  let l:ch = job_getchannel(l:job)
  if !empty(l:text)
    call ch_sendraw(l:ch, l:text)
  endif
  call ch_close_in(l:ch)
  return l:job
endfunction

" Everything else has to wait for `mop open` to finish: until the document is
" registered, an update or a close would be answered with "document is not
" open". The gap is normally milliseconds, but the very first open may have to
" start the daemon.
function! s:running(job) abort
  if a:job is v:null
    return 0
  endif
  return has('nvim') ? jobwait([a:job], 0)[0] ==# -1 : job_status(a:job) ==# 'run'
endfunction

function! s:wait(job, timeout) abort
  if a:job is v:null
    return
  endif
  if has('nvim')
    call jobwait([a:job], a:timeout)
    return
  endif
  let l:waited = 0
  while job_status(a:job) ==# 'run' && l:waited < a:timeout
    sleep 10m
    let l:waited += 10
  endwhile
endfunction

function! s:on_stderr_nvim(state, job, data, event) abort
  let a:state.stderr = a:data
  let a:state.stderr_done = 1
  call s:finish(a:state)
endfunction

function! s:on_exit_nvim(state, job, status, event) abort
  let a:state.status = a:status
  call s:finish(a:state)
endfunction

function! s:on_stderr_vim(state, ch, msg) abort
  call add(a:state.stderr, a:msg)
endfunction

function! s:on_close_vim(state, ch) abort
  " Mark stderr as complete here rather than in exit_cb, because Vim may call
  " exit_cb before all of stderr has been read.
  let a:state.stderr_done = 1
  call s:finish(a:state)
endfunction

function! s:on_exit_vim(state, job, status) abort
  let a:state.status = a:status
  call s:finish(a:state)
endfunction

" s:finish handles how a command started by s:run ended, once both its exit
" status and its stderr are known: it calls on_no_preview when the command
" found no preview and that callback was given, and reports stderr as an error
" otherwise.
function! s:finish(state) abort
  if !a:state.stderr_done || a:state.status is v:null
    return
  endif
  if a:state.status ==# s:exit_no_preview && a:state.on_no_preview isnot v:null
    call a:state.on_no_preview()
    return
  endif
  let l:msg = substitute(join(a:state.stderr, "\n"), '\n\+$', '', '')
  if !empty(l:msg)
    call s:error(l:msg)
  endif
endfunction

" What is tracked is the top line of the window, not the cursor. Moving the
" cursor around within the visible region does not change what the reader is
" looking at, so the preview must not twitch along with it. The value is read
" at event time because the timer callback below may run while another buffer
" is current.
function! s:viewline() abort
  return line('w0')
endfunction

function! s:clamp(ratio) abort
  return a:ratio < 0.0 ? 0.0 : (a:ratio > 1.0 ? 1.0 : a:ratio)
endfunction

function! s:stop_timer(session, key) abort
  if a:session[a:key] >= 0
    call timer_stop(a:session[a:key])
    let a:session[a:key] = -1
  endif
endfunction

function! s:record(bufnr) abort
  let l:session = get(s:sessions, a:bufnr, {})
  if empty(l:session)
    return {}
  endif
  let l:session.line = s:viewline()
  let l:session.ratio = s:clamp(g:mop_viewport_ratio)
  return l:session
endfunction

function! s:on_change(bufnr) abort
  let l:session = s:record(a:bufnr)
  if empty(l:session)
    return
  endif
  " An update carries the line as well, so a pending scroll would be
  " redundant and could fight with it.
  call s:stop_timer(l:session, 'scroll_timer')
  call s:stop_timer(l:session, 'update_timer')
  let l:session.update_timer = timer_start(
        \ g:mop_update_delay, {-> s:flush_update(a:bufnr)})
endfunction

function! s:on_scroll(bufnr) abort
  let l:session = get(s:sessions, a:bufnr, {})
  if empty(l:session)
    return
  endif
  " The event also fires for resizes, horizontal scrolling and (on the
  " fallback path) plain cursor movement. Nothing is sent unless the visible
  " region actually moved.
  if s:viewline() ==# l:session.line
    return
  endif
  call s:record(a:bufnr)
  " While an update is pending it will carry the newest position anyway.
  if l:session.update_timer >= 0
    return
  endif
  call s:stop_timer(l:session, 'scroll_timer')
  let l:session.scroll_timer = timer_start(
        \ g:mop_scroll_delay, {-> s:flush_scroll(a:bufnr)})
endfunction

function! s:flush_update(bufnr) abort
  let l:session = get(s:sessions, a:bufnr, {})
  if empty(l:session)
    return
  endif
  let l:session.update_timer = -1
  if s:running(l:session.open_job)
    " Try again rather than block the editor inside a timer callback.
    let l:session.update_timer = timer_start(
          \ g:mop_update_delay, {-> s:flush_update(a:bufnr)})
    return
  endif
  " The buffer is the source of truth here, not the file: that is the whole
  " point of `mop update`.
  let l:lines = getbufline(a:bufnr, 1, '$')
  call s:run(['update', l:session.path,
        \ '--line', string(l:session.line),
        \ '--viewport-ratio', printf('%.3f', l:session.ratio)], {
        \ 'stdin': l:lines,
        \ 'on_no_preview': {-> s:on_no_preview(a:bufnr, l:session)},
        \ })
endfunction

function! s:flush_scroll(bufnr) abort
  let l:session = get(s:sessions, a:bufnr, {})
  if empty(l:session)
    return
  endif
  let l:session.scroll_timer = -1
  if s:running(l:session.open_job)
    let l:session.scroll_timer = timer_start(
          \ g:mop_scroll_delay, {-> s:flush_scroll(a:bufnr)})
    return
  endif
  call s:run(['scroll', l:session.path,
        \ '--line', string(l:session.line),
        \ '--viewport-ratio', printf('%.3f', l:session.ratio)], {
        \ 'on_no_preview': {-> s:on_no_preview(a:bufnr, l:session)},
        \ })
endfunction

function! mop#open() abort
  let l:bufnr = bufnr('%')
  let l:path = expand('%:p')
  if &filetype !=# 'markdown'
    call s:error('not a markdown buffer')
    return
  endif
  if empty(l:path)
    call s:error('this buffer has no file name')
    return
  endif
  if !filereadable(l:path)
    " `mop open` reads the file from disk to register it, so it has to exist.
    call s:error('write the file first: ' . l:path)
    return
  endif

  if has_key(s:sessions, l:bufnr)
    " Already syncing: just re-open, which returns the existing URL without
    " adding a second tab.
    call s:run(['open', l:path])
    return
  endif

  let l:job = s:run(['open', l:path])
  if l:job is v:null
    return
  endif

  let s:sessions[l:bufnr] = {
        \ 'path': l:path,
        \ 'line': s:viewline(),
        \ 'ratio': s:clamp(g:mop_viewport_ratio),
        \ 'open_job': l:job,
        \ 'update_timer': -1,
        \ 'scroll_timer': -1,
        \ }
  " Sync the position once, so :Mop in an already scrolled buffer does not
  " leave the preview sitting at the top until something else happens.
  let s:sessions[l:bufnr].scroll_timer = timer_start(
        \ g:mop_scroll_delay, {-> s:flush_scroll(l:bufnr)})

  execute 'augroup mop_buffer_' . l:bufnr
    autocmd!
    execute 'autocmd TextChanged,TextChangedI,InsertLeave <buffer=' . l:bufnr
          \ . '> call s:on_change(' . l:bufnr . ')'
    " WinScrolled is registered globally below. CursorMoved is only needed as
    " a fallback for editors that lack it; s:on_scroll drops the events that
    " did not move the visible region either way.
    if !exists('##WinScrolled')
      execute 'autocmd CursorMoved,CursorMovedI <buffer=' . l:bufnr
            \ . '> call s:on_scroll(' . l:bufnr . ')'
    endif
    " BufUnload also fires when ":e" reloads this same file (buffer contents
    " are freed and re-read, but the buffer itself survives), so closing on
    " it would drop the session on every reload. BufWipeout only fires when
    " the buffer is actually gone.
    execute 'autocmd BufWipeout <buffer=' . l:bufnr
          \ . '> call s:close_preview(' . l:bufnr . ')'
  augroup END

  echo 'mop: syncing ' . fnamemodify(l:path, ':~:.')
endfunction

" s:stop_sync stops syncing the buffer without telling the daemon.
function! s:stop_sync(bufnr) abort
  let l:session = s:sessions[a:bufnr]
  call s:stop_timer(l:session, 'update_timer')
  call s:stop_timer(l:session, 'scroll_timer')
  unlet s:sessions[a:bufnr]

  execute 'autocmd! mop_buffer_' . a:bufnr
  execute 'augroup! mop_buffer_' . a:bufnr
endfunction

" s:on_no_preview stops syncing the buffer after a request of the given
" session found its document has no preview, and tells the user the preview
" has ended.
function! s:on_no_preview(bufnr, session) abort
  " Ignore the report unless it is about the current session, because several
  " requests may fail the same way, and :Mop may have started a new session
  " for the buffer since this one was sent.
  if get(s:sessions, a:bufnr, {}) isnot a:session
    return
  endif
  " End the session quietly instead of reporting an error on every edit,
  " because a lost preview is one nobody is looking at: the daemon only exits
  " after a long time with no browser connected. Skip `mop close` as the
  " daemon has nothing left to close.
  call s:stop_sync(a:bufnr)
  echomsg 'mop: preview ended: ' . fnamemodify(a:session.path, ':~:.')
endfunction

function! s:close_preview(bufnr) abort
  let l:session = get(s:sessions, a:bufnr, {})
  if empty(l:session)
    return
  endif
  call s:stop_sync(a:bufnr)

  " Closing before the open request landed would leave the document
  " registered forever, so this one waits.
  call s:wait(l:session.open_job, 2000)
  call s:close_request(l:session.path)
endfunction

" close runs synchronously. BufWipeout and VimLeavePre fire while the editor
" is quitting, and a job started there is killed before it can even exec. It is a localhost
" request, and `mop close` never starts a daemon, so it cannot stall.
function! s:close_request(path) abort
  call system(join([shellescape(g:mop_command), 'close', shellescape(a:path)], ' '))
endfunction

function! mop#close_current() abort
  let l:bufnr = bufnr('%')
  if !has_key(s:sessions, l:bufnr)
    call s:error('this buffer is not being previewed')
    return
  endif
  call s:close_preview(l:bufnr)
  echo 'mop: stopped'
endfunction

" Being in the autoload script, these are only registered once :Mop is first
" run, so an editor that never previews anything pays nothing for them.
augroup mop_global
  autocmd!
  " Leaving the editor should not leave documents registered in the daemon.
  autocmd VimLeavePre * call s:close_all_previews()
  " WinScrolled's pattern matches the window, not the buffer, so it cannot be
  " registered per buffer. It is harmless while nothing is being previewed:
  " s:on_scroll returns immediately when the buffer has no session.
  if exists('##WinScrolled')
    autocmd WinScrolled * call s:on_scroll(bufnr('%'))
  endif
augroup END

" Buffers are usually unloaded before this runs, so there is normally nothing
" left here. It is the safety net for sessions that survived that.
function! s:close_all_previews() abort
  for l:bufnr in keys(s:sessions)
    call s:close_preview(l:bufnr)
  endfor
endfunction
