" vint: -ProhibitUnusedVariable

function! lsp#ui#vim#code_action#complete(input, command, len) abort
    let l:server_names = filter(lsp#get_allowed_servers(), 'lsp#capabilities#has_code_action_provider(v:val)')
    let l:kinds = []
    for l:server_name in l:server_names
        let l:kinds += lsp#capabilities#get_code_action_kinds(l:server_name)
    endfor
    return filter(copy(l:kinds), { _, kind -> kind =~ '^' . a:input })
endfunction

"
" @param option = {
"   selection: v:true | v:false = Provide by CommandLine like `:'<,'>LspCodeAction`
"   sync: v:true | v:false      = Specify enable synchronous request. Example use case is `BufWritePre`
"   query: string               = Specify code action kind query. If query provided and then filtered code action is only one, invoke code action immediately.
"   ui: 'float' | 'preview'
" }
"
function! lsp#ui#vim#code_action#do(option) abort
    let l:selection = get(a:option, 'selection', v:false)
    let l:sync = get(a:option, 'sync', v:false)
    let l:query = get(a:option, 'query', '')
    let l:ui = get(a:option, 'ui', g:lsp_code_action_ui)
    if empty(l:ui)
        let l:ui = lsp#utils#_has_popup_menu() ? 'float' : 'preview'
    endif

    let l:server_names = filter(lsp#get_allowed_servers(), 'lsp#capabilities#has_code_action_provider(v:val)')
    if len(l:server_names) == 0
        return lsp#utils#error('Code action not supported for ' . &filetype)
    endif

    if l:selection
        let l:range = lsp#utils#range#_get_recent_visual_range()
    else
        let l:range = lsp#utils#range#_get_current_line_range()
    endif

    let l:ctx = {
    \ 'count': len(l:server_names),
    \ 'results': [],
    \}
    let l:bufnr = bufnr('%')
    let l:command_id = lsp#_new_command()
    for l:server_name in l:server_names
        let l:diagnostic = lsp#internal#diagnostics#under_cursor#get_diagnostic({'server': l:server_name})
        call lsp#send_request(l:server_name, {
                    \ 'method': 'textDocument/codeAction',
                    \ 'params': {
                    \   'textDocument': lsp#get_text_document_identifier(),
                    \   'range': empty(l:diagnostic) || l:selection ? l:range : l:diagnostic['range'],
                    \   'context': {
                    \       'diagnostics' : empty(l:diagnostic) ? [] : [l:diagnostic],
                    \       'triggerKind': 2,
                    \       'only': ['', 'quickfix', 'refactor', 'refactor.extract', 'refactor.inline', 'refactor.rewrite', 'source', 'source.organizeImports'],
                    \   },
                    \ },
                    \ 'sync': l:sync,
                    \ 'on_notification': function('s:handle_code_action', [l:ui, l:ctx, l:server_name, l:command_id, l:sync, l:query, l:bufnr]),
                    \ })
    endfor
    echo 'Retrieving code actions ...'
endfunction

function! s:handle_code_action(ui, ctx, server_name, command_id, sync, query, bufnr, data) abort
    " Ignore old request.
    if a:command_id != lsp#_last_command()
        return
    endif

    call add(a:ctx['results'], {
    \    'server_name': a:server_name,
    \    'data': a:data,
    \})
    let a:ctx['count'] -= 1
    if a:ctx['count'] ># 0
        return
    endif

    let l:total_code_actions = []
    for l:result in a:ctx['results']
        let l:server_name = l:result['server_name']
        let l:data = l:result['data']
        " Check response error.
        if lsp#client#is_error(l:data['response'])
            call lsp#utils#error('Failed to CodeAction for ' . l:server_name . ': ' . lsp#client#error_message(l:data['response']))
            continue
        endif

        " Check code actions.
        let l:code_actions = l:data['response']['result']

        " Filter code actions.
        if !empty(a:query)
            let l:code_actions = filter(l:code_actions, { _, action -> get(action, 'kind', '') =~# '^' . a:query })
        endif
        if empty(l:code_actions)
            continue
        endif

        " Client-side hierarchical filtering for context.only
        " (servers may return actions outside the 'only' filter; filter here too)
        let l:only_kinds = ['', 'quickfix', 'refactor', 'refactor.extract', 'refactor.inline', 'refactor.rewrite', 'source', 'source.organizeImports']
        let l:code_actions = filter(l:code_actions, { _, action ->
            \ !has_key(action, 'kind') || action['kind'] ==# '' ||
            \   len(filter(copy(l:only_kinds), { _, k -> action['kind'] ==# k || action['kind'] =~# '^' . k . '\.' })) > 0
            \ })

        for l:code_action in l:code_actions
            let l:item = {
            \   'server_name': l:server_name,
            \   'code_action': l:code_action,
            \ }
            if get(l:code_action, 'isPreferred', v:false)
                let l:total_code_actions = [l:item] + l:total_code_actions
            else
                call add(l:total_code_actions, l:item)
            endif
        endfor
    endfor

    if len(l:total_code_actions) == 0
        echo 'No code actions found'
        return
    endif
    call lsp#log('s:handle_code_action', l:total_code_actions)

    if len(l:total_code_actions) == 1 && !empty(a:query)
        let l:action = l:total_code_actions[0]
        if s:handle_disabled_action(l:action) | return | endif
        " Clear 'Retrieving code actions ...' message
        echo ''
        call s:handle_one_code_action(l:action['server_name'], a:sync, a:bufnr, l:action['code_action'])
        return
    endif

    " Prompt to choose code actions when empty query provided.
    let l:items = []
    for l:action in l:total_code_actions
        let l:title = printf('[%s] %s', l:action['server_name'], l:action['code_action']['title'])
        if has_key(l:action['code_action'], 'kind') && l:action['code_action']['kind'] !=# ''
            let l:title .= ' (' . l:action['code_action']['kind'] . ')'
        endif
        if has_key(l:action['code_action'], 'disabled')
            let l:title .= ' (disabled)'
        endif
        call add(l:items, { 'title': l:title, 'item': l:action })
    endfor

    " Clear 'Retrieving code actions ...' message
    echo ''
    if lsp#utils#_has_popup_menu() && a:ui ==? 'float'
        call lsp#internal#ui#popupmenu#open({
            \   'title': 'Code actions',
            \   'items': mapnew(l:items, { idx, item -> item.title}),
            \   'pos': 'topleft',
            \   'line': 'cursor+1',
            \   'col': 'cursor',
            \   'callback': funcref('s:popup_accept_code_action', [a:sync, a:bufnr, l:items]),
            \ })
    else
        call lsp#internal#ui#quickpick#open({
            \ 'items': l:items,
            \ 'key': 'title',
            \ 'on_accept': funcref('s:quickpick_accept_code_action', [a:sync, a:bufnr]),
            \ })
    endif
endfunction

function! s:popup_accept_code_action(sync, bufnr, items, id, selected, ...) abort
    if a:selected <= 0
        echo ''
        return
    endif
    let l:item = a:items[a:selected - 1]['item']
    if s:handle_disabled_action(l:item) | return | endif
    call s:handle_one_code_action(l:item['server_name'], a:sync, a:bufnr, l:item['code_action'])
endfunction

function! s:quickpick_accept_code_action(sync, bufnr, data, ...) abort
    call lsp#internal#ui#quickpick#close()
    if empty(a:data['items'])
        echo ''
        return
    endif
    let l:selected = a:data['items'][0]['item']
    if s:handle_disabled_action(l:selected) | return | endif
    call s:handle_one_code_action(l:selected['server_name'], a:sync, a:bufnr, l:selected['code_action'])
endfunction

function! s:handle_disabled_action(code_action) abort
    if has_key(a:code_action, 'disabled')
        echo 'This action is disabled: ' . a:code_action['disabled']['reason']
        return v:true
    endif
    return v:false
endfunction

"
" Determine if a CodeAction needs to be resolved.
" Matches neovim's logic: resolve if action is missing edit or command,
" and the server supports codeAction/resolve.
"
function! s:needs_resolve(server_name, code_action) abort
    " Don't resolve standalone Command objects (command is a string).
    if has_key(a:code_action, 'command') && type(a:code_action['command']) == type('')
        return v:false
    endif
    " Resolve if server supports it and action doesn't have both edit and command.
    return !(has_key(a:code_action, 'edit') && has_key(a:code_action, 'command'))
        \ && lsp#capabilities#has_code_action_resolve_provider(a:server_name)
endfunction

"
" Resolve a CodeAction via codeAction/resolve.
" On failure, falls back to the original action if it has edit or command.
" On success, applies the resolved action directly (no re-check for resolve).
"
function! s:resolve_code_action(server_name, sync, bufnr, code_action) abort
    call lsp#send_request(a:server_name, {
        \ 'method': 'codeAction/resolve',
        \ 'params': a:code_action,
        \ 'sync': a:sync,
        \ 'on_notification': function('s:on_resolve_code_action',
        \     [a:server_name, a:sync, a:bufnr, a:code_action]),
        \ })
endfunction

function! s:on_resolve_code_action(server_name, sync, bufnr, original, data) abort
    if lsp#client#is_error(a:data['response'])
        if has_key(a:original, 'edit') || has_key(a:original, 'command')
            call s:apply_action(a:server_name, a:sync, a:bufnr, a:original)
        else
            call lsp#utils#error('Code action resolve failed: ' . lsp#client#error_message(a:data['response']))
        endif
    else
        call s:apply_action(a:server_name, a:sync, a:bufnr, a:data['response']['result'])
    endif
endfunction

"
" Execute a CodeAction or Command by applying its edit and/or sending its command.
"
function! s:apply_action(server_name, sync, bufnr, action) abort
    " has WorkspaceEdit.
    if has_key(a:action, 'edit')
        call lsp#utils#workspace_edit#apply_workspace_edit(a:action['edit'])
    endif

    " Command (string form) - standalone Command object.
    if has_key(a:action, 'command') && type(a:action['command']) == type('')
        let l:cmd_name = get(a:action, 'command', '')
        call lsp#ui#vim#execute_command#_execute({
        \   'server_name': a:server_name,
        \   'command_name': l:cmd_name,
        \   'command_args': get(a:action, 'arguments', v:null),
        \   'sync': a:sync,
        \   'bufnr': a:bufnr,
        \ })

    " Command (object form) - CodeAction.command is a Command object.
    elseif has_key(a:action, 'command') && type(a:action['command']) == type({})
        let l:cmd_name = get(a:action['command'], 'command', '')
        call lsp#ui#vim#execute_command#_execute({
        \   'server_name': a:server_name,
        \   'command_name': l:cmd_name,
        \   'command_args': get(a:action['command'], 'arguments', v:null),
        \   'sync': a:sync,
        \   'bufnr': a:bufnr,
        \ })
    endif
endfunction

"
" Handle one code action or command response.
"
function! s:handle_one_code_action(server_name, sync, bufnr, action) abort
    " Standalone Command (command is a string) — apply directly, no resolve.
    if has_key(a:action, 'command') && type(a:action['command']) == type('')
        call s:apply_action(a:server_name, a:sync, a:bufnr, a:action)
        return
    endif

    " CodeAction: resolve if server supports it and action is incomplete.
    if s:needs_resolve(a:server_name, a:action)
        call s:resolve_code_action(a:server_name, a:sync, a:bufnr, a:action)
        return
    endif

    call s:apply_action(a:server_name, a:sync, a:bufnr, a:action)
endfunction
