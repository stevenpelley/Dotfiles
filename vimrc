set autoindent
set tabstop=2
set softtabstop=2
set expandtab
set shiftwidth=2
set number
set clipboard=unnamedplus
set path=$PWD
if !has("gui_running")
  set background=dark
endif

"if exists("+showtabline")
"     function MyTabLine()
"         let s = ''
"         let t = tabpagenr()
"         let i = 1
"         while i <= tabpagenr('$')
"             let buflist = tabpagebuflist(i)
"             let winnr = tabpagewinnr(i)
"             let s .= '%' . i . 'T'
"             let s .= (i == t ? '%1*' : '%2*')
"             let s .= ' '
"             let s .= i . ')'
"             let s .= ' %*'
"             let s .= (i == t ? '%#TabLineSel#' : '%#TabLine#')
"             let file = bufname(buflist[winnr - 1])
"             let file = fnamemodify(file, ':p:t')
"             if file == ''
"                 let file = '[No Name]'
"             endif
"             let s .= file
"             let i = i + 1
"         endwhile
"         let s .= '%T%#TabLineFill#%='
"         let s .= (tabpagenr('$') > 1 ? '%999XX' : 'X')
"         return s
"     endfunction
"     set stal=2
"     set tabline=%!MyTabLine()
"endif
