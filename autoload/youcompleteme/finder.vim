" Copyright (C) 2021 YouCompleteMe contributors
"
" This file is part of YouCompleteMe.
"
" YouCompleteMe is free software: you can redistribute it and/or modify
" it under the terms of the GNU General Public License as published by
" the Free Software Foundation, either version 3 of the License, or
" (at your option) any later version.
"
" YouCompleteMe is distributed in the hope that it will be useful,
" but WITHOUT ANY WARRANTY; without even the implied warranty of
" MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
" GNU General Public License for more details.
"
" You should have received a copy of the GNU General Public License
" along with YouCompleteMe.  If not, see <http://www.gnu.org/licenses/>.

" This is basic vim plugin boilerplate
let s:save_cpo = &cpoptions
set cpoptions&vim

scriptencoding utf-8

"
" Explanation for how this module works:
"
" The entry point is youcompleteme#finder#FindSymbol, which takes a scope
" argument:
"
" * 'document' scope - search document symbols - GoToDocumentOutline
" * 'workspace' scope - search workspace symbols - GoToSymbol
"
" In general, the approach is:
" - create a prompt buffer, and display it to use for input of a query
" - open up a popup to display the results in the middle of the screen
" - as the query changes, re-query the server to get the newly filtered results
" - as the server returns results, update the contents of the results-popup
" - use a popup-filter to implement some interractivity with the results, such
"   as down/up, and select item
" - when an item is selected, open its buffer in the window that was current
"   when the search started and jump to the selected item.
" - then populate the quickfix list with any matching results and close the
"   popup and prompt buffer.
"
" However, there is an important wrinke/distinction that leads to the code being
" a little more complicated than that: the 'search' mechanism for workspace and
" document symbols is different.
"
" The reaosn for this differece is what the servers provide in response to the 2
" requests:
"
" * 'document' scope - we use ycmd's filtering and sorting.
"    GoToDocumentOutline (LSP documentSymbol) request does not take any filter
"    argument. It returns all symbols in the current document. Therefore, we use
"    ycmd's filter_and_sort_candidates endpoint to use our own fuzzy search on
"    the results. This is a _great_ experience, it's _super_ fast and familar to
"    YCM users.
" * 'workspace' scope - we have to rely on the downstream server's filtering and
"   sorting.
"   GoToSymbol (LSP workspaceSymbol) request takes a query parameter to search
"   with. While the LSP spec states that an empty query means 'return
"   everything', no servers actually implement that, so we have to pass our
"   query down to the server.
"
" The result of this is that while a lot of the code is shared, there are
" slightly different steps involved in the process:
"
" * for 'document' requests, as soon as the popup is opened, we issue a
"   GoToDocumentOutline request, storing the results as `raw_results`, then
"   then immediately start filtering it with filter_and_sort_candidates, storing
"   the filtered results in `results`
" * for 'workspace' requests, as soon as the popup is opened, we issue a
"   GoToSymbol request with an empty query. This usually returns nothing, but if
"   any servers return anything then it would be stored in 'results'. As the
"   user types, we repeat the GoToSymbol request and update the 'results'
"
" In order to simplify the re-query code, we put the function used to filter
" results in the state variable as 'query_func'.
"
" As the expereince of completely different filtering and sorting for workspace
" vs document is so jarring, by default we actually pass all restuls from
" 'workspace' search through filter_and_sort_candidates too. This isn't perfect
" because it breaks the mental model when the server's filtering is dumb, but it
" at least means that sorting is consistent. This can be disabled by setting
" g:ycm_refilter_workspace_symbols to 0.
"
" The key functions are:
"
"  - FindSymbol - initiate the request - open the popup/prompt buffer, set up
"  the state object to defaults and initiate the first request
"  (RequestDocumentSymbols for 'documnt' and SearchWorkspace for 'workspace' )
"
"  - RequestDocumentSymbols - perform the GoToDocumentOutline request and store
"    the results in 'raw_results'
"
"  - SearchDocument - perform filter_and_sort_candidates request on the
"    'raw_results', and store the results in 'results', then call
"    "HandleSymbolSearchResults"
"
"  - SearchWorkspace - perform GoToSymbol request, and store the results in
"    'results', then call "HandleSymbolSearchResults"
"
"  - HandleSymbolSearchResults - redraw the popup with the 'results'
"
"  - HandleKeyPress - handle a keypress while the popup is visible, intercepts
"    things to handle interractivity
"
"  - PopupClosed - callback when the popup is closed. This openes the result in
"    the original window.
"
" The other functions are utility for the most part and handle things like
" TextChangedI event, starting/stopping drawing the spinner and such.

let s:highlight_group_for_symbol_kind = {
      \ 'Array': 'Identifier',
      \ 'Boolean': 'Boolean',
      \ 'Class': 'Structure',
      \ 'Constant': 'Constant',
      \ 'Constructor': 'Function',
      \ 'Enum': 'Structure',
      \ 'EnumMember': 'Identifier',
      \ 'Event': 'Identifier',
      \ 'Field': 'Identifier',
      \ 'Function': 'Function',
      \ 'Interface': 'Structure',
      \ 'Key': 'Identifier',
      \ 'Method': 'Function',
      \ 'Module': 'Include',
      \ 'Namespace': 'Type',
      \ 'Null': 'Keyword',
      \ 'Number': 'Number',
      \ 'Object': 'Structure',
      \ 'Operator': 'Operator',
      \ 'Package': 'Include',
      \ 'Property': 'Identifier',
      \ 'String': 'String',
      \ 'Struct': 'Structure',
      \ 'TypeParameter': 'Typedef',
      \ 'Variable': 'Identifier',
      \ }
let s:initialized_text_properties = v:false

let s:icon_spinner = [ '/', '-', '\', '|', '/', '-', '\', '|' ]
let s:icon_done = 'X'
let s:spinner_delay = 100
let s:prompt = 'Find Symbol: '
let s:find_symbol_status = {}

" Entry point {{{

function! youcompleteme#finder#FindSymbol( scope ) abort
  if !py3eval( 'vimsupport.VimSupportsPopupWindows()' )
    echo 'Sorry, this feature is not supported in your editor'
    return
  endif

  if !s:initialized_text_properties
    call prop_type_add( 'YCM-symbol-Normal', { 'highlight': 'Normal' } )
    for k in keys( s:highlight_group_for_symbol_kind )
      call prop_type_add(
            \ 'YCM-symbol-' . k,
            \ { 'highlight': s:highlight_group_for_symbol_kind[ k ] } )
    endfor
    call prop_type_add( 'YCM-symbol-file', { 'highlight': 'Comment' } )
    call prop_type_add( 'YCM-symbol-line-num', { 'highlight': 'Number' } )
    let s:initialized_text_properties = v:true
  endif

  let s:find_symbol_status = {
        \ 'selected': -1,
        \ 'query': '',
        \ 'results': [],
        \ 'raw_results': v:none,
        \ 'waiting': 0,
        \ 'pending': 0,
        \ 'winid': win_getid(),
        \ 'bufnr': bufnr(),
        \ 'prompt_bufnr': -1,
        \ 'prompt_winid': -1,
        \ 'filter': v:none,
        \ 'id': v:none,
        \ 'cursorline_match': v:none,
        \ 'spinner': 0,
        \ 'spinner_timer': -1,
        \ }

  let opts = {
        \ 'padding': [ 1, 2, 1, 2 ],
        \ 'wrap': 0,
        \ 'minwidth': &columns / 3 * 2,
        \ 'minheight': &lines / 3 * 2,
        \ 'maxwidth': &columns / 3 * 2,
        \ 'maxheight': &lines / 3 * 2,
        \ 'line': &lines / 6,
        \ 'col': &columns / 6,
        \ 'pos': 'topleft',
        \ 'drag': 1,
        \ 'resize': 1,
        \ 'close': 'button',
        \ 'border': [],
        \ 'callback': function( 's:PopupClosed' ),
        \ 'filter': function( 's:HandleKeyPress' ),
        \ 'highlight': 'Normal',
        \ }

  if &ambiwidth ==# 'single' && &encoding ==? 'utf-8'
    let opts[ 'borderchars' ] = [ '─', '│', '─', '│', '╭', '╮', '┛', '╰' ]
  endif

  if a:scope ==# 'document'
    let s:find_symbol_status.query_func = function( 's:SearchDocument' )
  else
    let s:find_symbol_status.query_func = function( 's:SearchWorkspace' )
  endif

  let s:find_symbol_status.id = popup_create( 'Type to query for stuff', opts )

  " Kick off the request now
  let s:find_symbol_status.waiting = 1
  if a:scope ==# 'document'
    call s:StartSpinner()
    call s:RequestDocumentSymbols()
  else
    call s:SearchWorkspace( '' )
  endif

  let bufnr = bufadd( '_ycm_filter_' )
  silent call bufload( bufnr )
  silent topleft 1split _ycm_filter_
  " Disable ycm/completion in this buffer
  call setbufvar( bufnr, 'ycm_largefile', 1 )

  let s:find_symbol_status.prompt_bufnr = bufnr
  let s:find_symbol_status.prompt_winid = win_getid()

  setlocal buftype=prompt noswapfile modifiable nomodified noreadonly
  setlocal nobuflisted bufhidden=delete textwidth=0
  call prompt_setprompt( bufnr(), s:prompt )
  augroup YCMPromptFindSymbol
    autocmd!
    autocmd TextChanged,TextChangedI <buffer> call s:OnQueryTextChanged()
    autocmd WinLeave <buffer> call s:Cancel()
    autocmd CmdLineEnter <buffer> call s:Cancel()
  augroup END
  startinsert
endfunction

function! s:OnQueryTextChanged() abort
  if s:find_symbol_status.id < 0
    return
  endif

  let bufnr = s:find_symbol_status.prompt_bufnr
  let query = getbufline( bufnr, '$' )[ 0 ]
  let s:find_symbol_status.query = query[ len( s:prompt ) : ]
  let s:find_symbol_status.pending = 1
  call s:RequeryFinderPopup()
  setlocal nomodified
endfunction


function! s:Cancel() abort
  if s:find_symbol_status.id < 0
    return
  endif

  call popup_close( s:find_symbol_status.id, -1 )
endfunction
" }}}

" Popup and keyboard events {{{

function! s:HandleKeyPress( id, key ) abort
  let redraw = 0
  let handled = 0

  " The input for the search/query is taken from the prompt buffer and the
  " TextChangedI event
  if a:key ==# "\<C-j>" ||
        \ a:key ==# "\<Down>" ||
        \ a:key ==# "\<C-n>" ||
        \ a:key ==# "\<Tab>"
    let s:find_symbol_status.selected += 1
    " wrap
    if s:find_symbol_status.selected >= len( s:find_symbol_status.results )
      let s:find_symbol_status.selected = 0
    endif
    let redraw = 1
    let handled = 1
  elseif a:key ==# "\<C-k>" ||
        \ a:key ==# "\<Up>" ||
        \ a:key ==# "\<C-p>" ||
        \ a:key ==# "\<S-Tab>"
    let s:find_symbol_status.selected -= 1
    " wrap
    if s:find_symbol_status.selected < 0
      let s:find_symbol_status.selected =
            \ len( s:find_symbol_status.results ) - 1
    endif
    let redraw = 1
    let handled = 1
  elseif a:key ==# "\<PageDown>" || a:key ==# "\<kPageDown>"
    let s:find_symbol_status.selected +=
          \ popup_getpos( s:find_symbol_status.id ).core_height
    " Don't wrap
    if s:find_symbol_status.selected >= len( s:find_symbol_status.results )
      let s:find_symbol_status.selected =
            \ len( s:find_symbol_status.results ) - 1
    endif
    let redraw = 1
    let handled = 1
  elseif a:key ==# "\<PageUp>" || a:key ==# "\<kPageUp>"
    let s:find_symbol_status.selected -=
          \ popup_getpos( s:find_symbol_status.id ).core_height
    " Don't wrap
    if s:find_symbol_status.selected < 0
      let s:find_symbol_status.selected = 0
    endif
    let redraw = 1
    let handled = 1
  elseif a:key ==# "\<C-c>"
    call popup_close( a:id, -1 )
    let handled = 1
  elseif a:key ==# "\<CR>"
    if s:find_symbol_status.selected >= 0
      call popup_close( a:id, s:find_symbol_status.selected )
      let handled = 1
    endif
  elseif a:key ==# "\<Home>" || a:key ==# "\<kHome>"
    let s:find_symbol_status.selected = 0
    let redraw = 1
    let handled = 1
  elseif a:key ==# "\<End>" || a:key ==# "\<kEnd>"
    let s:find_symbol_status.selected = len( s:find_symbol_status.results ) - 1
    let redraw = 1
    let handled = 1
  endif

  if redraw
    call s:RedrawFinderPopup()
  endif

  return handled
endfunction


" Handle the popup closing: jump to the selected item
function! s:PopupClosed( id, selected ) abort
  stopinsert
  call win_gotoid( s:find_symbol_status.prompt_winid )
  silent bwipe!

  " Return to original window
  call win_gotoid( s:find_symbol_status.winid )

  if a:selected >= 0
    let selected = s:find_symbol_status.results[ a:selected ]

    py3 vimsupport.JumpToLocation(
          \ filename = vimsupport.ToUnicode( vim.eval( 'selected.filepath' ) ),
          \ line = int( vim.eval( 'selected.line_num' ) ),
          \ column = int( vim.eval( 'selected.column_num' ) ),
          \ file_only = 0,
          \ modifiers = '',
          \ command = 'same-buffer'
          \ )

    if len( s:find_symbol_status.results ) > 1
      " Also, populate the quickfix list
      py3 vimsupport.SetQuickFixList(
            \ [ vimsupport.BuildQfListItem( x ) for x in
            \ vim.eval( 's:find_symbol_status.results' ) ] )


      " Emulate :echo, to avoid a redraw getting rid of the message.
      let txt = 'Added ' . len( getqflist() ) . ' entries to quickfix list.'
      call popup_notification(
            \ txt,
            \ {
              \  'line':      1,
              \  'col':       &columns - len( txt ),
              \  'padding':   [ 0, 0, 0, 0 ],
              \  'border':    [ 0, 0, 0, 0 ],
              \  'highlight': 'PMenu'
            \ } )

      " But don't open it, as this could take up valuable actual screen space
      " py3 vimsupport.OpenQuickFixList()
    endif
  endif


  call s:StopSpinner()
  let s:find_symbol_status.id = -1
endfunction

"}}}

" Results handling and re-query {{{

" Render a set of results returned from the filter/search function
function! s:HandleSymbolSearchResults( results ) abort
  let s:find_symbol_status.waiting = 0
  let s:find_symbol_status.results = []
  call s:StopSpinner()

  if s:find_symbol_status.id < 0
    " Popup was closed, ignore this event
    return
  endif

  let s:find_symbol_status.results = a:results
  call s:RedrawFinderPopup()
  call s:RequeryFinderPopup()
endfunction


" Set the popup text
function! s:RedrawFinderPopup() abort
  " Clamp selected. If there are any results, the first one is selected by
  " default
  let s:find_symbol_status.selected = max( [
        \   s:find_symbol_status.selected,
        \   len( s:find_symbol_status.results ) > 0 ? 0 : -1
        \ ] )
  let s:find_symbol_status.selected = min( [
        \   s:find_symbol_status.selected,
        \   len( s:find_symbol_status.results ) - 1
        \ ] )

  if empty( s:find_symbol_status.results )
    call popup_settext( s:find_symbol_status.id, 'No results' )
    let s:find_symbol_status.selected = -1
  else
    let popup_width = popup_getpos( s:find_symbol_status.id ).core_width

    let buffer = []

    for result in s:find_symbol_status.results
      " Calculate  the text to use. Try and include the full path and line
      " number, (right aligned), but truncate if there isn't space for the
      " description and the file path. Include at least 8 spaces between them
      " (if there's room).
      if result->has_key( 'extra_data' )
        let kind = result[ 'extra_data' ][ 'kind' ]
        let name = result[ 'extra_data' ][ 'name' ]
        let desc = kind .. ': ' .. name
        if s:highlight_group_for_symbol_kind->has_key( kind )
          let prop = 'YCM-symbol-' . kind
        else
          let prop = 'YCM-symbol-Normal'
        endif
        let props = [
            \ { 'col': 1,
            \   'length': len( kind ) + 2,
            \   'type': 'YCM-symbol-Normal'  },
            \ { 'col': len( kind ) + 3,
            \   'length': len( name ),
            \   'type': prop },
            \ ]
      elseif result->has_key( 'description' )
        let desc = result[ 'description' ]
        let props = [
            \ { 'col': 1, 'length': len( desc ), 'type': 'YCM-symbol-Normal' },
            \ ]
      else
        let desc = 'Invalid entry: ' . string( result )
        let props = []
      endif

      let line_num = result[ 'line_num' ]
      let path = fnamemodify( result[ 'filepath' ], ':.' )
               \ .. ':'
               \ .. line_num

      let spaces = popup_width - len( desc ) - len( path )
      let spacing = 8
      if spaces < spacing
        let spaces = spacing
        let path_len_to_use = popup_width - spacing - len( desc ) - 3
        if path_len_to_use > 0
          let path = '...' . strpart( path, len( path ) - path_len_to_use )
        else
          let path = '...:' .. line_num
        endif
      endif
      let line = desc .. repeat( ' ', spaces ) .. path
      call add( buffer, {
            \ 'text': line,
            \ 'props': props + [
              \ { 'col': popup_width - len( path ) + 1,
              \   'length': len( path ) - len( line_num ),
              \   'type': 'YCM-symbol-file' },
              \ { 'col': popup_width - len( line_num ) + 1,
              \   'length': len( line_num ),
              \   'type': 'YCM-symbol-line-num' }
              \ ]
            \ } )
    endfor

    call popup_settext( s:find_symbol_status.id, buffer )
  endif

  if s:find_symbol_status.selected > -1
    " Move the cursor so that cursorline highlights the selected item. Also
    " scroll the window if the selected item is not in view. To make scrolling
    " feel natural we position the current line a the bottom of the window if
    " the new current line is below the current viewport, and at the top if the
    " new current line is above the viewport.
    let new_line =  s:find_symbol_status.selected + 1
    let pos = popup_getpos( s:find_symbol_status.id )

    call win_execute( s:find_symbol_status.id,
                    \ 'call cursor( [' . string( new_line ) . ', 1] )' )

    if new_line < pos.firstline
      " New line is above the viewport, scroll so that this line is at the top
      " of the window.
      call win_execute( s:find_symbol_status.id, "normal z\<CR>" )
    elseif new_line >= ( pos.firstline + pos.core_height )
      " New line is below the viewport, scroll so that this line is at the
      " bottom of the window.
      call win_execute( s:find_symbol_status.id, ':normal z-' )
    endif
    " Otherwise, new item is already displayed - don't scroll the window.

    if !getwinvar( s:find_symbol_status.id, '&cursorline' )
      call win_execute( s:find_symbol_status.id, 'set cursorline' )
    endif
  else
    call win_execute( s:find_symbol_status.id, 'set nocursorline' )
  endif

endfunction

function! s:SetTitle() abort
  if s:find_symbol_status.spinner_timer > -1
    let status = s:icon_spinner[ s:find_symbol_status.spinner ]
  else
    let status = s:icon_done
  endif

  call popup_setoptions( s:find_symbol_status.id, {
        \ 'title': ' [' . status . '] Search for symbol: '
        \            . s:find_symbol_status.query . ' '
        \ } )
endfunction



" Re-query or re-filter by calling the filter function
function! s:RequeryFinderPopup() abort
  " Update the title even if we delay the query, as this makes the UI feel
  " snappy
  call s:SetTitle()

  if s:find_symbol_status.waiting == 1
    let s:find_symbol_status.pending = 1
  elseif s:find_symbol_status.pending == 1
    let s:find_symbol_status.pending = 0
    let s:find_symbol_status.waiting = 1
    call win_execute( s:find_symbol_status.winid,
          \ 'call s:find_symbol_status.query_func('
          \ . 's:find_symbol_status.query )' )
  endif
endfunction

function! s:ParseGoToResponse( results ) abort
  if type( a:results ) == v:t_none || empty( a:results )
    let results = []
  elseif type( a:results ) != v:t_list
    if type( a:results ) == v:t_dict && has_key( a:results, 'error' )
      let results = {}
    else
      let results = [ a:results ]
    endif
  else
    let results = a:results
  endif

  call map( results,
        \ { i,v -> extend( v,
              \ { 'key': v->get( 'extra_data',
              \                  {} )->get( 'name',
              \                             v[ 'description' ] ) } ) } )

  return results
endfunction

" }}}

" Spinner {{{

function! s:StartSpinner() abort
  call s:StopSpinner()

  let s:find_symbol_status.spinner = 0
  let s:find_symbol_status.spinner_timer = timer_start( s:spinner_delay,
        \ function( 's:TickSpinner' ) )

  call s:SetTitle()
endfunction

function! s:StopSpinner() abort
  call timer_stop( s:find_symbol_status.spinner_timer )
  let s:find_symbol_status.spinner_timer = -1

  call s:SetTitle()
endfunction

function! s:TickSpinner( timer_id ) abort
  let s:find_symbol_status.spinner = ( s:find_symbol_status.spinner + 1 ) %
        \ len( s:icon_spinner )

  let s:find_symbol_status.spinner_timer = timer_start( s:spinner_delay,
        \ function( 's:TickSpinner' ) )

  call s:SetTitle()
endfunction

" }}}

" Workspace search {{{

function! s:SearchWorkspace( query ) abort
  call s:StartSpinner()

  let s:find_symbol_status.raw_results = v:none
  call youcompleteme#GetRawCommandResponseAsync(
        \ function( 's:HandleWorkspaceSymbols' ),
        \ 'GoToSymbol',
        \ a:query )
endfunction


function! s:HandleWorkspaceSymbols( results ) abort
  let results = s:ParseGoToResponse( a:results )

  if g:ycm_refilter_workspace_symbols && !empty( results )
    " This is kinda wonky, but seems to work well enough.
    "
    " We get the server to give us a result set, then use our own
    " filter_and_sort_candidates on the result set filtered by the server
    "
    " The reason for this is:
    "  - server filterins will differ by server and this leads to horrible wonky
    "    user experience
    "  - ycmd filter is consistent, even if not perfect
    "  - servers are supposed to return _all_ symbols if we request a query of ""
    "    but no actual servers obey this part of the spec.
    "
    " So as a compromise we let the server filter the results, then we _refilter_
    " and sort them using ycmd's method. This provides consistency with the
    " filtering and sorting on the completion popup menu, with the disadvantage of
    " additional latency.
    "
    " We're not currently sure this is going to be perfecct, so we have a hidden
    " option to disable this re-filter/sort.
    "
    let results = py3eval(
          \ 'ycm_state.FilterAndSortItems( '
          \ . ' vim.eval( "results" ),'
          \ . ' "description",'
          \ . ' vim.eval( "s:find_symbol_status.query" ) )' )
  endif

  eval s:HandleSymbolSearchResults( results )
endfunction

" }}}

" Document Search {{{

function! s:SearchDocument( query ) abort
  if type( s:find_symbol_status.raw_results ) == v:t_none
    call s:StopSpinner()
    call popup_settext( s:find_symbol_status.id,
          \ 'No symbols found in document' )
    return
  endif

  call s:StartSpinner()

  " Call filter_and_sort_candidates on the results (synchronously)
  let response = py3eval(
        \ 'ycm_state.FilterAndSortItems( '
        \ . ' vim.eval( "s:find_symbol_status.raw_results" ),'
        \ . ' "description",'
        \ . ' vim.eval( "a:query" ) )' )

  eval s:HandleSymbolSearchResults( response )
endfunction


function! s:RequestDocumentSymbols()
  call youcompleteme#GetRawCommandResponseAsync(
        \ function( 's:HandleDocumentSymbols' ),
        \ 'GoToDocumentOutline' )
endfunction


function! s:HandleDocumentSymbols( results ) abort
  let s:find_symbol_status.raw_results = s:ParseGoToResponse( a:results )
  call s:SearchDocument( '' )
endfunction

" }}}

" Utility for testing {{{

function! youcompleteme#finder#GetState() abort
  return s:find_symbol_status
endfunction

" }}}

" This is basic vim plugin boilerplate
let &cpoptions = s:save_cpo
unlet s:save_cpo

" vim: foldmethod=marker
