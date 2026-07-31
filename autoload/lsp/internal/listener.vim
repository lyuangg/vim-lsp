let s:has_listener = exists('*listener_add')
let s:buf_state = {}

function! lsp#internal#listener#is_enabled() abort
    return s:has_listener
endfunction

function! lsp#internal#listener#start(buf) abort
    if !s:has_listener
        return
    endif
    if has_key(s:buf_state, a:buf)
        return
    endif
    let s:buf_state[a:buf] = {
        \ 'listener_id': listener_add(function('s:on_change'), a:buf),
        \ 'changes': [],
        \ 'lsp_cache': {},
        \ 'lines_cache': {},
        \ 'diff_cache': {},
        \ }
endfunction

function! lsp#internal#listener#stop(buf) abort
    if !has_key(s:buf_state, a:buf)
        return
    endif
    call listener_remove(s:buf_state[a:buf].listener_id)
    call remove(s:buf_state, a:buf)
endfunction

function! lsp#internal#listener#flush(buf) abort
    if !has_key(s:buf_state, a:buf)
        return []
    endif
    let l:state = s:buf_state[a:buf]
    call listener_flush(a:buf)
    let l:tick = getbufvar(a:buf, 'changedtick')
    if !empty(l:state.lsp_cache) && l:state.lsp_cache.tick == l:tick
        return l:state.lsp_cache.changes
    endif
    let l:raw = l:state.changes
    let l:state.changes = []
    if empty(l:raw)
        let l:state.lsp_cache = {'tick': l:tick, 'changes': []}
        return []
    endif
    if len(l:raw) == 1
        let l:lsp_changes = s:single_change(a:buf, l:raw[0])
    else
        " Multiple changes accumulated. Each change's lnum/end references the
        " buffer state at the time it was recorded, so reading the replaced
        " text range-by-range from the final buffer would be wrong.
        " Merge them into ONE change covering the whole affected region (in
        " original coordinates) and send the current text of that region. This
        " keeps didChange incremental during continuous typing instead of
        " falling back to sending the full document.
        let l:lsp_changes = s:merge_changes(a:buf, l:raw)
    endif
    let l:state.lsp_cache = {'tick': l:tick, 'changes': l:lsp_changes}
    return l:lsp_changes
endfunction

" Convert a single listener change into an LSP TextDocumentContentChangeEvent.
" listener_add reports the changed line range as [lnum, end) (1-based, end
" exclusive) plus the net number of added lines. The whole range is replaced
" by the current text of those lines.
function! s:single_change(buf, c) abort
    let l:new_end = a:c.lnum + (a:c.end - a:c.lnum) + a:c.added
    if a:c.lnum < l:new_end
        let l:text = join(getbufline(a:buf, a:c.lnum, l:new_end - 1), "\n") . "\n"
    else
        let l:text = ''
    endif
    return [{
        \ 'range': {
        \   'start': {'line': a:c.lnum - 1, 'character': 0},
        \   'end': {'line': a:c.end - 1, 'character': 0},
        \ },
        \ 'text': l:text,
        \ }]
endfunction

" Merge accumulated listener changes into a single change whose range covers
" the whole affected region.
"
" With only insertions (added >= 0), every change's reported lnum/end is at
" or below its original position, so the union [min_lnum, max_end) is a
" superset of the affected original lines and no change touches lines above
" min_lnum. The region still starts at min_lnum in the final buffer, its
" final size is (max_end - min_lnum) original lines plus the net added line
" count, and replacing that range with the current text of the region is
" always a valid LSP content change that matches the buffer exactly.
"
" When a change deleted whole lines (added < 0), a later change's line
" numbers reference the shifted buffer state, so the union can't be derived
" from the raw values alone. Fall back to sending the full document, which is
" always valid per the LSP spec.
function! s:merge_changes(buf, changes) abort
    let l:min_lnum = a:changes[0].lnum
    let l:max_end = a:changes[0].end
    let l:sum_added = a:changes[0].added
    if l:sum_added < 0
        return [{'text': join(lsp#utils#buffer#_get_lines(a:buf), "\n")}]
    endif
    for l:c in a:changes[1:]
        if l:c.added < 0
            return [{'text': join(lsp#utils#buffer#_get_lines(a:buf), "\n")}]
        endif
        if l:c.lnum < l:min_lnum | let l:min_lnum = l:c.lnum | endif
        if l:c.end > l:max_end | let l:max_end = l:c.end | endif
        let l:sum_added += l:c.added
    endfor
    let l:new_end_line = l:min_lnum + (l:max_end - l:min_lnum) + l:sum_added
    if l:min_lnum < l:new_end_line
        let l:text = join(getbufline(a:buf, l:min_lnum, l:new_end_line - 1), "\n") . "\n"
    else
        let l:text = ''
    endif
    return [{
        \ 'range': {
        \   'start': {'line': l:min_lnum - 1, 'character': 0},
        \   'end': {'line': l:max_end - 1, 'character': 0},
        \ },
        \ 'text': l:text,
        \ }]
endfunction

function! lsp#internal#listener#get_lines_cached(buf) abort
    let l:tick = getbufvar(a:buf, 'changedtick')
    if has_key(s:buf_state, a:buf)
        let l:cache = s:buf_state[a:buf].lines_cache
        if !empty(l:cache) && l:cache.tick == l:tick
            return l:cache.lines
        endif
    endif
    let l:lines = lsp#utils#buffer#_get_lines(a:buf)
    if has_key(s:buf_state, a:buf)
        let s:buf_state[a:buf].lines_cache = {'tick': l:tick, 'lines': l:lines}
    endif
    return l:lines
endfunction

function! lsp#internal#listener#get_diff_cached(buf, old_content) abort
    let l:tick = getbufvar(a:buf, 'changedtick')
    if has_key(s:buf_state, a:buf)
        let l:cache = s:buf_state[a:buf].diff_cache
        if !empty(l:cache) && l:cache.tick == l:tick && l:cache.old is a:old_content
            return l:cache.changes
        endif
    endif
    let l:new_content = lsp#internal#listener#get_lines_cached(a:buf)
    let l:changes = lsp#utils#diff#compute(a:old_content, l:new_content)
    if has_key(s:buf_state, a:buf)
        let s:buf_state[a:buf].diff_cache = {'tick': l:tick, 'old': a:old_content, 'changes': l:changes}
    endif
    return l:changes
endfunction

function! s:on_change(buf, start, end, added, changes) abort
    if !has_key(s:buf_state, a:buf)
        return
    endif
    let l:state = s:buf_state[a:buf]
    for l:change in a:changes
        call add(l:state.changes, {
            \ 'lnum': l:change.lnum,
            \ 'end': l:change.end,
            \ 'added': l:change.added,
            \ })
    endfor
endfunction
