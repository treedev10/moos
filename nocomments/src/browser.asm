BT_H        equ 36
BS_H        equ 22
SB_W        equ 14
PAD_X       equ 14
TB_BW       equ 30
GO_W        equ 40
ADDR_X      equ 4 * (TB_BW + 4) + 10
URL_MAX     equ 4000
HIST_MAX    equ 16
HIST_SIZE   equ 4096
HIST_SCROLL equ 4092
LINE_STEP   equ 48
MAX_REDIR   equ 8
C_CHROME    equ 0xE4E7EB
C_CHROME_TX equ 0x2A2E33
C_BTN       equ 0xD3D8DE
C_BTN_OFF   equ 0xA8AEB5

section .bss
alignb 4
br_url      resb 4096
br_addr     resb 4096
br_tmp      resb 4096
br_tmp2     resb 4096
br_hover_url resb 4096
br_frag     resb 256
br_status   resb 320
br_wintitle resb 200
alignb 4
br_addr_len resd 1
br_cur      resd 1
br_sel      resd 1
br_typing   resd 1
br_scroll   resd 1
br_lw       resd 1
br_loaded   resd 1
br_secure   resd 1
br_vx       resd 1
br_vy       resd 1
br_vw       resd 1
br_vh       resd 1
br_hist_n   resd 1
br_hist_pos resd 1
br_focus_i  resd 1
br_drag_s0  resd 1
br_want     resd 1
br_kind     resd 1
br_redirs   resd 1
br_bytes    resd 1
KIND_HTML   equ 0
KIND_TEXT   equ 1
KIND_OTHER  equ 2

section .data
ico_back    dw 0x0000, 0x0000, 0x0000, 0x0200, 0x0600, 0x0C00, 0x1800, 0x3FFC
            dw 0x3FFC, 0x1800, 0x0C00, 0x0600, 0x0200, 0x0000, 0x0000, 0x0000
ico_fwd     dw 0x0000, 0x0000, 0x0000, 0x0040, 0x0060, 0x0030, 0x0018, 0x3FFC
            dw 0x3FFC, 0x0018, 0x0030, 0x0060, 0x0040, 0x0000, 0x0000, 0x0000
ico_reload  dw 0x0000, 0x0000, 0x07C8, 0x1C78, 0x3018, 0x2038, 0x60F8, 0x6000
            dw 0x6000, 0x6006, 0x2004, 0x300C, 0x1C38, 0x07E0, 0x0000, 0x0000
ico_home    dw 0x0000, 0x0180, 0x03C0, 0x0660, 0x0C30, 0x1818, 0x300C, 0x7FFE
            dw 0x2004, 0x27E4, 0x2424, 0x2424, 0x2424, 0x3C3C, 0x0000, 0x0000
ico_lock    dw 0x0000, 0x0000, 0x07E0, 0x0C30, 0x0810, 0x0810, 0x1FF8, 0x1FF8
            dw 0x1FF8, 0x1F78, 0x1E38, 0x1F78, 0x1FF8, 0x1FF8, 0x0000, 0x0000
br_go_lbl   db "Go", 0
br_name     db "MOOS Browser", 0
br_dash     db " - ", 0
br_home     db "about:home", 0
br_about    db "about:", 0
br_vsrc     db "view-source:", 0
br_http     db "http://", 0
br_scheme_sep db "://", 0
ct_html     db "html", 0
ct_text     db "text/", 0
ct_json     db "json", 0
ct_js       db "javascript", 0
ct_xml      db "xml", 0
st_loading  db "Loading ", 0
st_dots     db " ...", 0
st_noload   db "MOOS cannot open that kind of link (only http:// and https:// pages).", 0
st_post     db "This form is sent with POST, which MOOS cannot do yet (only GET forms).", 0
st_field    db "A form field - click it and type", 0
st_send     db "Send the form", 0
br_empty    db 0
br_on       db "on", 0

br_home_page:
    db "<title>Start page</title>"
    db "<h1>MOOS Browser</h1>"
    db "<p>Type an address in the bar above and press <b>Enter</b>, or click a "
    db "link. The arrows go back and forward; drag the window's edges to make "
    db "it bigger - the page is laid out again to fit.</p>"
    db "<h3>Places to try</h3><ul>"
    db "<li><a href='http://info.cern.ch/hypertext/WWW/TheProject.html'>The "
    db "first web site</a> - CERN, 1991 (plain HTTP)</li>"
    db "<li><a href='http://neverssl.com/'>NeverSSL</a> - a site that stays "
    db "on plain HTTP</li>"
    db "<li><a href='https://www.google.com/'>Google</a> (HTTPS)</li>"
    db "<li><a href='https://github.com/treedev10/moos'>MOOS on GitHub</a> (HTTPS)</li>"
    db "<li><a href='https://raw.githubusercontent.com/treedev10/moos/HEAD/README.md'>"
    db "The MOOS README</a> - a plain text file</li>"
    db "<li><a href='about:test'>A test page</a> - what the browser can show</li>"
    db "</ul>"
    db "<h3>Keys</h3><table>"
    db "<tr><td><b>Ctrl+L</b></td><td>type an address (or just start typing)</td></tr>"
    db "<tr><td><b>Enter</b></td><td>go there / follow the chosen link</td></tr>"
    db "<tr><td><b>Tab</b></td><td>choose the next link</td></tr>"
    db "<tr><td><b>Arrows, PgUp, PgDn, Space, Home, End</b></td><td>scroll</td></tr>"
    db "<tr><td><b>Backspace</b>, <b>Ctrl+B</b></td><td>back</td></tr>"
    db "<tr><td><b>Ctrl+F</b></td><td>forward</td></tr>"
    db "<tr><td><b>Ctrl+R</b></td><td>reload</td></tr></table>"
    db "<h3>About</h3>"
    db "<p>This browser is part of MOOS and written from scratch in assembly. "
    db "It reads HTML itself and lays out headings, paragraphs, lists, tables, "
    db "quotes, preformatted text, forms and links, in <b>bold</b>, <i>italic</i>, "
    db "<u>underlined</u> and <code>code</code> styles. It talks HTTP and HTTPS "
    db "(TLS 1.3, with the certificate checked). It does not run JavaScript or "
    db "apply style sheets, and shows a picture's description instead of the "
    db "picture. Sites that only have ECDSA certificates cannot be reached yet.</p>"
    db 0

br_test_page:
    db "<!DOCTYPE html><html><head><title>Test page</title>"
    db "<style>body { color: red }</style><script>document.write('no')</script>"
    db "</head><body>"
    db "<h1>Heading one</h1><h2>Heading two</h2><h3>Heading three</h3><h4>Heading four</h4>"
    db "<p>A paragraph with <b>bold</b>, <i>italic</i>, <u>underlined</u>, "
    db "<s>struck</s>, <code>code</code>, <mark>marked</mark>, <a href='#end'>a link "
    db "to the end of the page</a> and <q>a quotation</q>. Entities: &amp; &lt; &gt; "
    db "&copy; &eacute;t&eacute; &mdash; &hellip; &#169; &#x263A; caf", 0xC3, 0xA9
    db " na", 0xC3, 0xAF, "ve ", 0xE2, 0x80, 0x9C, "quotes", 0xE2, 0x80, 0x9D, ".</p>"
    db "<p style='text-align:center'>This line is centred.</p>"
    db "<p><font color='#B00000'>Red text</font>, <span style='color: #0060A0; "
    db "font-weight: bold'>blue bold text</span>, and <span hidden>this is "
    db "hidden</span><span style='display:none'>so is this</span>no gaps.</p>"
    db "<ul><li>First item</li><li>Second item<ul><li>Inside</li><li>Also "
    db "inside<ul><li>Deeper</li></ul></li></ul></li><li>Third item</ul>"
    db "<ol><li>One<li>Two<li>Three</ol>"
    db "<ol start=7><li>Seven<li>Eight</ol>"
    db "<blockquote>A quotation block, indented, with a bar beside it. It is "
    db "long enough to wrap onto a second line when the window is narrow.</blockquote>"
    db "<pre>Preformatted text", 10, "    keeps   its   spaces", 10, "  and new lines</pre>"
    db "<dl><dt>Term</dt><dd>Its description</dd></dl>"
    db "<table><tr><th>Name</th><th>Size</th></tr>"
    db "<tr><td>kernel</td><td>200 KB</td></tr><tr><td>font</td><td>4 KB</td></tr></table>"
    db "<hr><p>Images show their description: <img src='x.png' alt='a cow'>"
    db " <img src='y.png'></p>"
    db "<form><input type=text placeholder='Search'> <input type=submit value='Go'>"
    db " <input type=checkbox checked> <input type=radio> <button>A button</button></form>"
    db "<p>A long word: Pneumonoultramicroscopicsilicovolcanoconiosis"
    db "Pneumonoultramicroscopicsilicovolcanoconiosis</p>"
    db "<p id='end'>The end. <a href='about:home'>Back to the start page</a>.</p>"
    db "</body></html>", 0
br_test     db "about:test", 0

err_p1      db "<title>Problem loading page</title><h2>Could not load this page</h2><p><b>", 0
err_p2      db "</b></p><p>", 0
err_p3      db ".</p><p>Check the address, or try again with Reload. MOOS speaks "
            db "HTTP and HTTPS (TLS 1.3); sites that only offer ECDSA certificates "
            db "cannot be reached yet.</p>", 0
oth_p1      db "<title>Cannot show this</title><h2>MOOS cannot show this file</h2><p>It is <b>", 0
oth_p2      db "</b>, not a web page or text. To save it, use the Terminal: "
            db "<code>get &lt;address&gt; &lt;file&gt;</code></p>", 0
oth_unknown db "a file of an unknown type", 0

section .text

brow_init:
    pushad
    mov dword [br_hist_n], 0
    mov dword [br_hist_pos], 0
    mov dword [br_loaded], 0
    mov dword [br_scroll], 0
    mov dword [br_lw], 0
    mov dword [pg_hover], 0
    mov dword [pg_focus], 0
    mov byte [br_url], 0
    mov esi, br_home
    call brow_navigate
    call brow_addr_focus
    popad
    ret

brow_tick:
    push eax
    call pl_tick
    mov eax, [pl_state]
    cmp eax, PS_LOADING
    jb .pic
    cmp eax, PS_PLAY
    jbe .busy
.pic:
    call imgc_tick
    jnc .idle
    mov dword [br_lw], 0
    or byte [gui_dirty], 1
.busy:
    pop eax
    stc
    ret
.idle:
    pop eax
    clc
    ret

brow_closed:
    test dword [wn_f + APP_BROWSER * 4], WF_OPEN
    jnz .r
    cmp dword [br_loaded], 0
    je .r
    mov dword [br_loaded], 0
    call vid_reset
    call imgc_reset
.r: ret

brow_open_url:
    pushad
    mov dword [br_typing], 0
    call brow_navigate
    popad
    ret

brow_title:
    mov esi, br_wintitle
    cmp byte [esi], 0
    jne .r
    mov esi, br_name
.r: ret

brow_set_title:
    pushad
    mov edi, br_wintitle
    mov byte [edi], 0
    cmp byte [br_title], 0
    je .name
    mov esi, br_title
    call str_copy
    mov esi, br_dash
    call str_append
.name:
    mov esi, br_name
    call str_append
    popad
    ret

brow_areas:
    push eax
    mov eax, [cb_x]
    mov [br_vx], eax
    mov eax, [cb_y]
    add eax, BT_H
    mov [br_vy], eax
    mov eax, [cb_w]
    sub eax, SB_W
    jns .w
    xor eax, eax
.w: mov [br_vw], eax
    mov eax, [cb_h]
    sub eax, BT_H + BS_H
    jns .h
    xor eax, eax
.h: mov [br_vh], eax
    pop eax
    ret

brow_page_w:
    mov eax, [br_vw]
    sub eax, 2 * PAD_X
    cmp eax, 120
    jge .r
    mov eax, 120
.r: ret

brow_fit:
    push eax
    call brow_page_w
    cmp eax, [br_lw]
    je .r
    mov [br_lw], eax
    call html_layout
    mov dword [pg_focus], 0
    call brow_clamp
.r: pop eax
    ret

brow_max_scroll:
    mov eax, [ly_h]
    sub eax, [br_vh]
    jns .r
    xor eax, eax
.r: ret

brow_clamp:
    push eax
    call brow_max_scroll
    cmp [br_scroll], eax
    jle .lo
    mov [br_scroll], eax
.lo:
    cmp dword [br_scroll], 0
    jge .r
    mov dword [br_scroll], 0
.r: pop eax
    ret

brow_scroll_by:
    add [br_scroll], eax
    call brow_clamp
    or byte [gui_dirty], 1
    ret

app_brow_draw:
    pushad
    call brow_areas
    call brow_fit

    RECT [br_vx], [br_vy], [br_vw], [br_vh], C_PAGE_BG
    mov ecx, [br_vx]
    mov edx, [br_vy]
    mov esi, [br_vw]
    mov edi, [br_vh]
    call gfx_clip_set
    mov eax, [br_vx]
    add eax, PAD_X
    mov [pg_x0], eax
    mov eax, [br_vy]
    sub eax, [br_scroll]
    mov [pg_y0], eax
    mov eax, [br_vy]
    mov [pg_vt], eax
    add eax, [br_vh]
    mov [pg_vb], eax
    call vid_unseen
    call html_paint
    mov ecx, [cb_x]
    mov edx, [cb_y]
    mov esi, [cb_w]
    mov edi, [cb_h]
    call gfx_clip_set
    call brow_draw_scrollbar
    call brow_draw_toolbar
    call brow_draw_status
    popad
    ret

brow_thumb:
    push ebx
    push ecx
    mov ecx, [ly_h]
    cmp ecx, [br_vh]
    jle .none
    mov eax, [br_vh]
    mul dword [br_vh]
    div ecx
    cmp eax, 24
    jge .h
    mov eax, 24
.h: cmp eax, [br_vh]
    jbe .h2
    mov eax, [br_vh]
.h2:
    mov ebx, eax
    mov eax, [br_vh]
    sub eax, ebx
    mul dword [br_scroll]
    push ebx
    mov ebx, ecx
    sub ebx, [br_vh]
    div ebx
    pop ebx
    add eax, [br_vy]
    mov edx, ebx
    pop ecx
    pop ebx
    clc
    ret
.none:
    pop ecx
    pop ebx
    stc
    ret

brow_draw_scrollbar:
    pushad
    mov ecx, [br_vx]
    add ecx, [br_vw]
    RECT ecx, [br_vy], SB_W, [br_vh], 0xE9EBEE
    call brow_thumb
    jc .done
    mov ecx, [br_vx]
    add ecx, [br_vw]
    add ecx, 2
    RECT ecx, eax, SB_W - 4, edx, 0xA3AAB2
.done:
    popad
    ret

brow_draw_toolbar:
    pushad
    RECT [cb_x], [cb_y], [cb_w], BT_H, C_CHROME
    mov edx, [cb_y]
    add edx, BT_H - 1
    RECT [cb_x], edx, [cb_w], 1, 0xC2C7CD
    xor ebx, ebx
.btn:
    mov ecx, ebx
    imul ecx, TB_BW + 4
    add ecx, [cb_x]
    add ecx, 6
    mov edx, [cb_y]
    add edx, 6
    push ebx
    RECT ecx, edx, TB_BW, 24, C_BTN
    pop ebx
    mov eax, C_CHROME_TX
    cmp ebx, 0
    jne .nb
    cmp dword [br_hist_pos], 0
    jne .ico
    mov eax, C_BTN_OFF
    jmp .ico
.nb:
    cmp ebx, 1
    jne .ico
    mov edi, [br_hist_pos]
    inc edi
    cmp edi, [br_hist_n]
    jb .ico
    mov eax, C_BTN_OFF
.ico:
    call gfx_rgb
    mov esi, [br_icons + ebx * 4]
    mov ecx, ebx
    imul ecx, TB_BW + 4
    add ecx, [cb_x]
    add ecx, 6 + (TB_BW - 16) / 2
    mov edx, [cb_y]
    add edx, 6 + 4
    call gfx_icon
    inc ebx
    cmp ebx, 4
    jb .btn

    call brow_addr_box
    mov eax, 0xFFFFFF
    call gfx_rgb
    call gfx_fillrect
    mov eax, 0x9AA3AD
    cmp dword [br_typing], 0
    je .fr
    mov eax, 0x2F7FD0
.fr:
    call gfx_rgb
    call gfx_frame
    cmp dword [br_typing], 0
    je .fr1
    inc ecx
    inc edx
    sub esi, 2
    sub edi, 2
    call gfx_frame
    dec ecx
    dec edx
    add esi, 2
    add edi, 2
.fr1:
    push ecx
    push edx
    push esi
    push edi
    add ecx, 3
    sub esi, 6
    call gfx_clip_set
    pop edi
    pop esi
    pop edx
    pop ecx
    add ecx, 6
    add edx, 4
    cmp dword [br_secure], 0
    je .nolock
    cmp dword [br_typing], 0
    jne .nolock
    mov eax, 0x1E8E3E
    call gfx_rgb
    push esi
    mov esi, ico_lock
    call gfx_icon
    pop esi
    add ecx, 18
.nolock:
    call brow_addr_text
    mov ecx, [cb_x]
    mov edx, [cb_y]
    mov esi, [cb_w]
    mov edi, [cb_h]
    call gfx_clip_set
    mov ecx, [cb_x]
    add ecx, [cb_w]
    sub ecx, GO_W + 6
    mov edx, [cb_y]
    add edx, 6
    RECT ecx, edx, GO_W, 24, C_BTN
    mov ecx, [cb_x]
    add ecx, [cb_w]
    sub ecx, GO_W + 6 - (GO_W - 16) / 2
    mov edx, [cb_y]
    add edx, 10
    mov dword [gfx_scale], 1
    TEXT ecx, edx, br_go_lbl, C_CHROME_TX, -1
    popad
    ret

brow_addr_text:
    pushad
    mov [bat_x], ecx
    mov [bat_y], edx
    mov dword [gfx_cw], 8
    mov dword [gfx_style], 0
    call brow_addr_box
    sub esi, 30
    shr esi, 3
    mov [bat_fit], esi
    xor ebp, ebp
    cmp dword [br_typing], 0
    je .from
    mov eax, [br_cur]
    sub eax, [bat_fit]
    jl .from
    lea ebp, [eax + 1]
.from:
    mov eax, 0x101418
    cmp dword [br_typing], 0
    je .col
    cmp dword [br_sel], 0
    je .col
    mov eax, [br_addr_len]
    sub eax, ebp
    shl eax, 3
    mov esi, eax
    mov edi, 16
    mov ecx, [bat_x]
    mov edx, [bat_y]
    mov eax, 0x2F7FD0
    call gfx_rgb
    call gfx_fillrect
    mov eax, 0xFFFFFF
.col:
    call gfx_rgb
    mov [pt_fg], eax
    mov ecx, [bat_x]
    mov edx, [bat_y]
    mov esi, ebp
.c: cmp esi, [br_addr_len]
    jae .cursor
    mov al, [br_addr + esi]
    mov ebx, [pt_fg]
    push ebp
    mov ebp, -1
    call gfx_glyph
    pop ebp
    add ecx, 8
    inc esi
    jmp .c
.cursor:
    cmp dword [br_typing], 0
    je .done
    cmp dword [br_sel], 0
    jne .done
    mov ecx, [br_cur]
    sub ecx, ebp
    shl ecx, 3
    add ecx, [bat_x]
    mov edx, [bat_y]
    mov eax, 0x101418
    call gfx_rgb
    mov esi, 2
    mov edi, 16
    call gfx_fillrect
.done:
    popad
    ret

section .bss
alignb 4
bat_x       resd 1
bat_y       resd 1
bat_fit     resd 1
section .text

brow_addr_box:
    mov ecx, [cb_x]
    add ecx, ADDR_X
    mov edx, [cb_y]
    add edx, 6
    mov esi, [cb_w]
    sub esi, ADDR_X + GO_W + 14
    cmp esi, 40
    jge .w
    mov esi, 40
.w: mov edi, 24
    ret

brow_draw_status:
    pushad
    mov edx, [cb_y]
    add edx, [cb_h]
    sub edx, BS_H
    push edx
    RECT [cb_x], edx, [cb_w], BS_H, C_CHROME
    pop edx
    push edx
    RECT [cb_x], edx, [cb_w], 1, 0xC2C7CD
    pop edx
    add edx, 4
    mov ecx, [cb_x]
    add ecx, 8
    mov esi, br_status
    cmp dword [pg_hover], 0
    je .s
    mov esi, br_hover_url
.s: mov dword [gfx_scale], 1
    TEXT ecx, edx, esi, C_CHROME_TX, -1
    popad
    ret

section .data
br_icons    dd ico_back, ico_fwd, ico_reload, ico_home
section .text

brow_click:
    pushad
    call brow_areas
    mov eax, [mouse_y]
    cmp eax, [br_vy]
    jl .toolbar
    mov ebx, [br_vy]
    add ebx, [br_vh]
    cmp eax, ebx
    jge .done
    mov dword [br_typing], 0
    mov ebx, [br_vx]
    add ebx, [br_vw]
    cmp [mouse_x], ebx
    jge .scrollbar
    call vid_at
    jc .notvid
    call vd_from_rec
    call vid_click
    jmp .done
.notvid:

    mov dword [pg_field], 0
    mov eax, [mouse_x]
    sub eax, [br_vx]
    sub eax, PAD_X
    mov edx, [mouse_y]
    sub edx, [br_vy]
    add edx, [br_scroll]
    push eax
    call html_field_at
    test eax, eax
    pop ecx
    jnz .field
    mov eax, ecx
    call html_link_at
    test eax, eax
    jz .done
    call html_is_field
    je .field
    mov esi, eax
    call brow_follow
    jmp .done
.field:
    call brow_field_click
    jmp .done
.scrollbar:
    call brow_thumb
    jc .done
    mov ebx, [mouse_y]
    cmp ebx, eax
    jl .pgup
    add eax, edx
    cmp ebx, eax
    jge .pgdn
    mov eax, [br_scroll]
    mov [br_drag_s0], eax
    mov dword [drag_mode], DRAG_APP
    mov dword [drag_app], APP_BROWSER
    mov ebx, APP_BROWSER
    call wm_drag_start
    jmp .done
.pgup:
    call brow_page_step
    neg eax
    call brow_scroll_by
    jmp .done
.pgdn:
    call brow_page_step
    call brow_scroll_by
    jmp .done
.toolbar:
    mov eax, [mouse_x]
    sub eax, [cb_x]
    sub eax, 6
    js .done
    xor edx, edx
    mov ecx, TB_BW + 4
    div ecx
    cmp eax, 4
    jae .addr
    cmp edx, TB_BW
    jae .done
    cmp eax, 1
    jb .back
    je .fwd
    cmp eax, 2
    je .reload
    mov esi, br_home
    mov dword [br_typing], 0
    call brow_navigate
    jmp .done
.back:
    call brow_back
    jmp .done
.fwd:
    call brow_forward
    jmp .done
.reload:
    call brow_reload
    jmp .done
.addr:
    mov eax, [cb_x]
    add eax, [cb_w]
    sub eax, GO_W + 6
    cmp [mouse_x], eax
    jl .in_addr
    call brow_go_typed
    jmp .done
.in_addr:
    call brow_addr_box
    cmp [mouse_x], ecx
    jl .done
    cmp dword [br_typing], 0
    je .first
    cmp dword [br_sel], 0
    jne .place
.place:
    mov dword [br_sel], 0
    mov eax, [mouse_x]
    sub eax, ecx
    sub eax, 6 - 4
    jns .p1
    xor eax, eax
.p1:
    shr eax, 3
    cmp eax, [br_addr_len]
    jbe .p2
    mov eax, [br_addr_len]
.p2:
    mov [br_cur], eax
    jmp .done
.first:
    call brow_addr_focus
.done:
    or byte [gui_dirty], 1
    popad
    ret

brow_page_step:
    mov eax, [br_vh]
    sub eax, 40
    cmp eax, LINE_STEP
    jge .r
    mov eax, LINE_STEP
.r: ret

brow_drag:
    pushad
    call brow_areas
    call brow_thumb
    jc .done
    mov ebx, [br_vh]
    sub ebx, edx
    jle .done
    mov eax, [mouse_y]
    sub eax, [drag_my]
    push eax
    call brow_max_scroll
    mov ecx, eax
    pop eax
    imul ecx
    idiv ebx
    add eax, [br_drag_s0]
    mov [br_scroll], eax
    call brow_clamp
    or byte [gui_dirty], 1
.done:
    popad
    ret

brow_hover:
    pushad
    call brow_areas
    xor eax, eax
    mov ebx, [mouse_y]
    cmp ebx, [br_vy]
    jl .set
    mov ecx, [br_vy]
    add ecx, [br_vh]
    cmp ebx, ecx
    jge .set
    mov ecx, [br_vx]
    add ecx, [br_vw]
    cmp [mouse_x], ecx
    jge .set
    mov eax, [mouse_x]
    sub eax, [br_vx]
    sub eax, PAD_X
    mov edx, [mouse_y]
    sub edx, [br_vy]
    add edx, [br_scroll]
    push eax
    call html_field_at
    test eax, eax
    pop ecx
    jnz .set
    mov eax, ecx
    call html_link_at
.set:
    cmp eax, [pg_hover]
    je .done
    mov [pg_hover], eax
    or byte [gui_dirty], 1
    test eax, eax
    jz .done
    call html_is_field
    jne .link
    mov esi, st_field
    cmp dword [eax + IN_TYPE], IT_TEXT
    je .fs
    cmp dword [eax + IN_TYPE], IT_PASSWORD
    je .fs
    mov esi, st_send
.fs:
    mov edi, br_hover_url
    call str_copy
    jmp .done
.link:
    mov esi, eax
    mov edi, br_hover_url
    call brow_resolve
    jnc .done
    mov edi, br_hover_url
    call str_copy
.done:
    popad
    ret

brow_unhover:
    cmp dword [pg_hover], 0
    je .r
    mov dword [pg_hover], 0
    or byte [gui_dirty], 1
.r: ret

brow_wheel:
    push eax
    imul eax, -LINE_STEP
    call brow_scroll_by
    pop eax
    ret

brow_key:
    pushad
    or byte [gui_dirty], 1
    cmp eax, 12
    je .ctrl_l
    cmp eax, 18
    je .reload
    cmp eax, 2
    je .back
    cmp eax, 6
    je .fwd
    cmp eax, 27
    je .esc
    cmp dword [br_typing], 2
    je .field
    cmp dword [br_typing], 0
    jne .typing
.page:
    call pl_page_key
    jnc .done
    cmp eax, KEY_UP
    je .up
    cmp eax, KEY_DOWN
    je .down
    cmp eax, KEY_PGUP
    je .pgup
    cmp eax, KEY_PGDN
    je .pgdn
    cmp eax, ' '
    je .pgdn
    cmp eax, KEY_HOME
    je .home
    cmp eax, KEY_END
    je .end
    cmp eax, 9
    je .tab
    cmp eax, 10
    je .enter
    cmp eax, 8
    je .back
    cmp eax, ' '
    jb .done
    cmp eax, '~'
    ja .done
    mov dword [br_typing], 1
    mov dword [br_sel], 1
    jmp .typing
.up:
    mov eax, -LINE_STEP
    jmp .by
.down:
    mov eax, LINE_STEP
    jmp .by
.pgup:
    call brow_page_step
    neg eax
    jmp .by
.pgdn:
    call brow_page_step
.by:
    call brow_scroll_by
    jmp .done
.home:
    mov dword [br_scroll], 0
    jmp .done
.end:
    call brow_max_scroll
    mov [br_scroll], eax
    jmp .done
.tab:
    call brow_next_link
    jmp .done
.enter:
    mov esi, [pg_focus]
    test esi, esi
    jz .done
    call brow_follow
    jmp .done
.ctrl_l:
    call brow_addr_focus
    jmp .done
.reload:
    call brow_reload
    jmp .done
.back:
    call brow_back
    jmp .done
.fwd:
    call brow_forward
    jmp .done
.typing:
    cmp eax, 10
    je .go
    cmp eax, 9
    je .leave
    cmp eax, 8
    je .bs
    cmp eax, KEY_DEL
    je .del
    cmp eax, KEY_LEFT
    je .left
    cmp eax, KEY_RIGHT
    je .right
    cmp eax, KEY_HOME
    je .ahome
    cmp eax, KEY_END
    je .aend
    cmp eax, KEY_UP
    je .page
    cmp eax, KEY_DOWN
    je .page
    cmp eax, KEY_PGUP
    je .page
    cmp eax, KEY_PGDN
    je .page
    cmp eax, ' '
    jb .done
    cmp eax, '~'
    ja .done
    call brow_addr_sel_clear
    mov ecx, [br_addr_len]
    cmp ecx, URL_MAX
    jae .done
    mov edi, [br_cur]
.ins:
    cmp ecx, edi
    jbe .put
    mov dl, [br_addr + ecx - 1]
    mov [br_addr + ecx], dl
    dec ecx
    jmp .ins
.put:
    mov [br_addr + edi], al
    inc dword [br_addr_len]
    inc dword [br_cur]
    mov ecx, [br_addr_len]
    mov byte [br_addr + ecx], 0
    jmp .done
.bs:
    cmp dword [br_sel], 0
    je .bs1
    call brow_addr_sel_clear
    jmp .done
.bs1:
    cmp dword [br_cur], 0
    je .done
    dec dword [br_cur]
.del:
    cmp dword [br_sel], 0
    je .del1
    call brow_addr_sel_clear
    jmp .done
.del1:
    mov edi, [br_cur]
    cmp edi, [br_addr_len]
    jae .done
.dl:
    mov al, [br_addr + edi + 1]
    mov [br_addr + edi], al
    inc edi
    cmp edi, [br_addr_len]
    jb .dl
    dec dword [br_addr_len]
    jmp .done
.left:
    mov dword [br_sel], 0
    cmp dword [br_cur], 0
    je .done
    dec dword [br_cur]
    jmp .done
.right:
    mov dword [br_sel], 0
    mov eax, [br_cur]
    cmp eax, [br_addr_len]
    jae .done
    inc dword [br_cur]
    jmp .done
.ahome:
    mov dword [br_sel], 0
    mov dword [br_cur], 0
    jmp .done
.aend:
    mov dword [br_sel], 0
    mov eax, [br_addr_len]
    mov [br_cur], eax
    jmp .done
.leave:
    mov dword [br_typing], 0
    jmp .done
.go:
    call brow_go_typed
    jmp .done
.field:
    mov edi, [pg_field]
    test edi, edi
    jz .unfield
    cmp eax, 10
    je .submit
    cmp eax, 9
    je .unfield
    cmp eax, 8
    je .fbs
    cmp eax, KEY_UP
    je .page
    cmp eax, KEY_DOWN
    je .page
    cmp eax, KEY_PGUP
    je .page
    cmp eax, KEY_PGDN
    je .page
    cmp eax, ' '
    jb .done
    cmp eax, '~'
    ja .done
    mov ecx, [edi + IN_LEN]
    cmp ecx, IN_MAXLEN
    jae .done
    mov [edi + IN_TEXT + ecx], al
    inc dword [edi + IN_LEN]
    jmp .done
.fbs:
    cmp dword [edi + IN_LEN], 0
    je .done
    dec dword [edi + IN_LEN]
    jmp .done
.submit:
    mov eax, [edi + IN_FORM]
    xor ebx, ebx
    call brow_submit
    jmp .done
.unfield:
    mov dword [br_typing], 0
    mov dword [pg_field], 0
    jmp .done
.esc:
    cmp dword [br_typing], 1
    jne .unfield
    call brow_addr_unfocus
    mov esi, br_url
    mov edi, br_tmp2
    call str_copy
    cmp byte [br_frag], 0
    je .esc1
    mov esi, br_frag_mark
    call str_append
    mov esi, br_frag
    call str_append
.esc1:
    mov esi, br_tmp2
    call brow_addr_set
.done:
    popad
    ret

brow_field_click:
    pushad
    mov edi, eax
    mov ecx, [edi + IN_TYPE]
    cmp ecx, IT_TEXT
    je .type
    cmp ecx, IT_PASSWORD
    je .type
    mov dword [br_typing], 0
    cmp ecx, IT_CHECK
    je .check
    cmp ecx, IT_RADIO
    je .radio
    cmp ecx, IT_SUBMIT
    jne .done
    mov ebx, edi
    mov eax, [edi + IN_FORM]
    call brow_submit
    jmp .done
.type:
    mov [pg_field], edi
    mov dword [br_typing], 2
    jmp .done
.check:
    xor dword [edi + IN_CHK], 1
    jmp .done
.radio:
    mov esi, BR_INPUTS
    mov ecx, [ly_ni]
.r: jecxz .on
    cmp dword [esi + IN_TYPE], IT_RADIO
    jne .rn
    mov eax, [esi + IN_FORM]
    cmp eax, [edi + IN_FORM]
    jne .rn
    push esi
    push edi
    mov esi, [esi + IN_NAME]
    mov edi, [edi + IN_NAME]
    test esi, esi
    jz .rs
    test edi, edi
    jz .rs
    call str_eq
    jmp .rc
.rs:
    test esp, esp
.rc:
    pop edi
    pop esi
    jne .rn
    mov dword [esi + IN_CHK], 0
.rn:
    add esi, IN_SIZE
    dec ecx
    jmp .r
.on:
    mov dword [edi + IN_CHK], 1
.done:
    or byte [gui_dirty], 1
    popad
    ret

brow_submit:
    pushad
    mov dword [br_typing], 0
    mov dword [pg_field], 0
    test eax, eax
    js .done
    cmp eax, [ly_nf]
    jae .done
    lea ebp, [BR_FORMS + eax * 8]
    mov [bs_form], eax
    mov [bs_button], ebx
    cmp dword [ebp + FM_POST], 0
    je .get
    mov esi, st_post
    call brow_status_set
    jmp .done
.get:
    mov esi, [ebp + FM_ACTION]
    test esi, esi
    jnz .act
    mov esi, br_empty
.act:
    mov edi, br_tmp2
    call brow_resolve
    jc .done
    mov esi, br_tmp2
.q: mov al, [esi]
    test al, al
    jz .qe
    cmp al, '?'
    je .qe
    cmp al, '#'
    je .qe
    inc esi
    jmp .q
.qe:
    mov byte [esi], '?'
    lea edi, [esi + 1]
    mov dword [bs_first], 1
    mov ebx, BR_INPUTS
    xor ecx, ecx
.f: cmp ecx, [ly_ni]
    jae .go
    mov eax, [ebx + IN_FORM]
    cmp eax, [bs_form]
    jne .fn
    cmp dword [ebx + IN_NAME], 0
    je .fn
    mov eax, [ebx + IN_TYPE]
    cmp eax, IT_TEXT
    je .typed
    cmp eax, IT_PASSWORD
    je .typed
    cmp eax, IT_HIDDEN
    je .value
    cmp eax, IT_SUBMIT
    je .button
    cmp eax, IT_CHECK
    je .ticked
    cmp eax, IT_RADIO
    jne .fn
.ticked:
    cmp dword [ebx + IN_CHK], 0
    je .fn
    mov esi, [ebx + IN_VALUE]
    test esi, esi
    jnz .pair_z
    mov esi, br_on
    jmp .pair_z
.button:
    cmp ebx, [bs_button]
    jne .fn
.value:
    mov esi, [ebx + IN_VALUE]
    test esi, esi
    jnz .pair_z
    mov esi, br_empty
.pair_z:
    push esi
    call str_len
    pop esi
    jmp .pair
.typed:
    lea esi, [ebx + IN_TEXT]
    mov ecx, [ebx + IN_LEN]
    push ecx
    jmp .pair2
.pair:
    push ecx
.pair2:
    mov eax, edi
    sub eax, br_tmp2
    cmp eax, URL_MAX - 200
    pop eax
    jae .go
    push ecx
    push esi
    cmp dword [bs_first], 0
    jne .nfirst
    mov byte [edi], '&'
    inc edi
.nfirst:
    mov dword [bs_first], 0
    mov esi, [ebx + IN_NAME]
    push esi
    call str_len
    pop esi
    call url_encode
    mov byte [edi], '='
    inc edi
    pop esi
    pop ecx
    mov ecx, eax
    call url_encode
    mov ecx, ebx
    sub ecx, BR_INPUTS
    shr ecx, 8
.fn:
    add ebx, IN_SIZE
    inc ecx
    jmp .f
.go:
    mov byte [edi], 0
    mov esi, br_tmp2
    call brow_navigate
.done:
    popad
    ret

url_encode:
    push eax
    push ecx
    push esi
.l: jecxz .e
    lodsb
    dec ecx
    cmp al, ' '
    je .plus
    call is_alnum
    jnc .keep
    cmp al, '-'
    je .keep
    cmp al, '_'
    je .keep
    cmp al, '.'
    je .keep
    cmp al, '~'
    je .keep
    push eax
    mov al, '%'
    stosb
    pop eax
    push eax
    shr al, 4
    call .hex
    pop eax
    and al, 0x0F
    call .hex
    jmp .l
.plus:
    mov al, '+'
.keep:
    stosb
    jmp .l
.hex:
    add al, '0'
    cmp al, '9'
    jbe .h
    add al, 'A' - '9' - 1
.h: stosb
    ret
.e: pop esi
    pop ecx
    pop eax
    ret

section .bss
alignb 4
bs_form     resd 1
bs_button   resd 1
bs_first    resd 1
section .text

brow_addr_focus:
    push eax
    mov dword [br_typing], 1
    mov dword [br_sel], 1
    mov esi, br_addr
    call str_len
    mov [br_addr_len], ecx
    mov [br_cur], ecx
    pop eax
    ret

brow_addr_set:
    pushad
    mov edi, br_tmp2
    cmp esi, br_addr
    jne .copy
    mov edi, br_addr
    jmp .len
.copy:
    mov edi, br_addr
    xor ecx, ecx
.c: lodsb
    stosb
    test al, al
    jz .len
    inc ecx
    cmp ecx, URL_MAX
    jb .c
    mov byte [edi], 0
.len:
    mov esi, br_addr
    call str_len
    mov [br_addr_len], ecx
    mov [br_cur], ecx
    popad
    ret

brow_addr_sel_clear:
    cmp dword [br_sel], 0
    je .r
    mov dword [br_sel], 0
    mov dword [br_addr_len], 0
    mov dword [br_cur], 0
    mov byte [br_addr], 0
.r: ret

brow_go_typed:
    pushad
    mov dword [br_typing], 0
    mov dword [br_sel], 0
    mov esi, br_addr
    mov edi, br_tmp2
    call str_copy
    mov esi, br_tmp2
    call brow_navigate
    popad
    ret

brow_next_link:
    pushad
    mov ecx, [ly_n]
    test ecx, ecx
    jz .done
    mov ebx, [br_focus_i]
    cmp dword [pg_focus], 0
    jne .l
    mov ebx, -1
.l: inc ebx
    cmp ebx, [ly_n]
    jb .chk
    xor ebx, ebx
.chk:
    mov esi, ebx
    shl esi, 5
    add esi, BR_ITEMS
    mov eax, [esi + DI_LINK]
    test eax, eax
    jz .n
    cmp eax, [pg_focus]
    jne .found
.n: loop .l
    jmp .done
.found:
    mov [pg_focus], eax
    mov [br_focus_i], ebx
    mov eax, [esi + DI_Y]
    cmp eax, [br_scroll]
    jl .show
    movzx edx, word [esi + DI_H]
    add edx, eax
    mov ecx, [br_scroll]
    add ecx, [br_vh]
    cmp edx, ecx
    jle .done
.show:
    mov ecx, [br_vh]
    shr ecx, 2
    sub eax, ecx
    mov [br_scroll], eax
    call brow_clamp
.done:
    popad
    ret

brow_follow:
    pushad
    mov edi, br_tmp2
    call brow_resolve
    jc .cant
    mov esi, br_tmp2
    call brow_navigate
    popad
    ret
.cant:
    mov esi, st_noload
    mov edi, br_status
    call str_copy
    popad
    ret

brow_resolve:
    pushad
    mov ebx, br_url
    cmp byte [br_base], 0
    je .base
    push esi
    push edi
    mov esi, br_base
    mov edi, br_tmp
    mov ebx, br_url
    call url_join
    pop edi
    pop esi
    jc .base
    mov ebx, br_tmp
.base:
    call url_join
    popad
    ret

brow_navigate:
    pushad
    mov edi, br_tmp
    call url_tidy
    mov esi, br_tmp
    call brow_hist_push
    mov esi, br_tmp
    mov eax, -1
    call brow_load
    popad
    ret

brow_back:
    pushad
    mov eax, [br_hist_pos]
    test eax, eax
    jz .r
    call brow_hist_save
    dec dword [br_hist_pos]
    call brow_hist_load
.r: popad
    ret

brow_forward:
    pushad
    mov eax, [br_hist_pos]
    inc eax
    cmp eax, [br_hist_n]
    jae .r
    call brow_hist_save
    inc dword [br_hist_pos]
    call brow_hist_load
.r: popad
    ret

brow_reload:
    pushad
    cmp dword [br_hist_n], 0
    je .r
    call brow_hist_save
    call brow_hist_load
.r: popad
    ret

brow_hist_entry:
    mov edi, eax
    shl edi, 12
    add edi, BR_HIST
    ret

brow_hist_save:
    push eax
    push edi
    cmp dword [br_hist_n], 0
    je .r
    mov eax, [br_hist_pos]
    call brow_hist_entry
    mov eax, [br_scroll]
    mov [edi + HIST_SCROLL], eax
.r: pop edi
    pop eax
    ret

brow_hist_load:
    pushad
    mov eax, [br_hist_pos]
    call brow_hist_entry
    mov esi, edi
    mov edi, br_tmp
    call str_copy
    mov eax, [esi + HIST_SCROLL]
    mov esi, br_tmp
    call brow_load
    popad
    ret

brow_hist_push:
    pushad
    call brow_hist_save
    xor eax, eax
    cmp dword [br_hist_n], 0
    je .at
    mov eax, [br_hist_pos]
    inc eax
.at:
    cmp eax, HIST_MAX
    jb .room
    push esi
    mov edi, BR_HIST
    lea esi, [edi + HIST_SIZE]
    mov ecx, (HIST_MAX - 1) * HIST_SIZE / 4
    rep movsd
    pop esi
    mov eax, HIST_MAX - 1
.room:
    mov [br_hist_pos], eax
    lea ecx, [eax + 1]
    mov [br_hist_n], ecx
    call brow_hist_entry
    mov ecx, URL_MAX
.c: lodsb
    stosb
    test al, al
    jz .e
    loop .c
    mov byte [edi], 0
.e: mov eax, [br_hist_pos]
    call brow_hist_entry
    mov dword [edi + HIST_SCROLL], 0
    popad
    ret

brow_status_set:
    pushad
    mov edi, br_status
    mov ecx, 300
.l: lodsb
    stosb
    test al, al
    jz .e
    loop .l
    mov byte [edi], 0
.e: popad
    ret

brow_load:
    pushad
    mov [br_want], eax
    call brow_addr_set
    call brow_addr_unfocus
    mov dword [pg_hover], 0
    mov dword [pg_focus], 0
    mov byte [br_frag], 0
    call brow_split_frag
.nofrag:

    cmp byte [br_frag], 0
    je .fetch
    cmp dword [br_loaded], 0
    je .fetch
    mov edi, br_url
    call str_eq
    jne .fetch
    jmp .placed
.fetch:
    mov edi, br_url
    call str_copy
    call html_forms_reset
    call imgc_reset
    call vid_reset
    mov dword [br_loaded], 0
    mov dword [br_secure], 0
    mov dword [br_redirs], 0
    mov dword [br_kind], KIND_HTML
    mov edi, br_about
    xchg esi, edi
    call str_iprefix
    xchg esi, edi
    je .about

    call out_begin
    PRINTF `Loading %s ...`, br_url
    call brow_status_outbuf
    mov byte [gui_dirty], 1
    call gui_redraw
    mov esi, br_url
    call yt_match
    jc .again
    mov dword [br_loaded], 1
    call yt_page
    mov [br_bytes], ecx
    call yt_secure
    mov [br_secure], eax
    call html_parse
    jmp .parsed
.again:
    mov esi, br_url
    mov edi, br_vsrc
    xchg esi, edi
    call str_iprefix
    xchg esi, edi
    jne .get
    add esi, 12
    mov dword [br_kind], KIND_TEXT
.get:
    mov byte [url_insecure], 0
    mov byte [gui_capture], 2
    call url_fetch
    mov byte [gui_capture], 0
    jc .failed
    mov eax, [http_status]
    cmp eax, 301
    je .redir
    cmp eax, 302
    je .redir
    cmp eax, 303
    je .redir
    cmp eax, 307
    je .redir
    cmp eax, 308
    jne .got
.redir:
    cmp byte [http_location], 0
    je .got
    inc dword [br_redirs]
    cmp dword [br_redirs], MAX_REDIR
    ja .got
    mov esi, http_location
    mov edi, br_tmp2
    mov ebx, br_url
    call url_join
    jc .got
    mov esi, br_tmp2
    call brow_split_frag
    mov edi, br_url
    call str_copy
    call out_begin
    PRINTF `Loading %s ... (redirected)`, br_url
    call brow_status_outbuf
    mov byte [gui_dirty], 1
    call gui_redraw
    jmp .again
.got:
    mov dword [br_loaded], 1
    movzx eax, byte [url_scheme]
    mov [br_secure], eax
    mov esi, PKG_BUF
    mov ecx, [pkg_len]
    mov [br_bytes], ecx
    cmp ecx, 3
    jb .kind
    cmp word [esi], 0xBBEF
    jne .kind
    cmp byte [esi + 2], 0xBF
    jne .kind
    add esi, 3
    sub ecx, 3
.kind:
    cmp dword [br_kind], KIND_TEXT
    je .text
    call brow_kind
    cmp dword [br_kind], KIND_TEXT
    je .text
    cmp dword [br_kind], KIND_OTHER
    je .other
    call html_parse
    jmp .parsed
.text:
    call html_parse_text
    mov byte [br_title], 0
    jmp .parsed
.other:
    call brow_other_page
    jmp .parsed
.about:
    mov esi, br_url
    mov edi, br_test
    call str_icmp
    je .test
    mov esi, br_home
    mov edi, br_url
    call str_copy
    mov esi, br_home_page
    jmp .builtin
.test:
    mov esi, br_test_page
.builtin:
    call str_len
    mov dword [br_loaded], 1
    call html_parse
    jmp .parsed
.failed:
    call brow_error_page
.parsed:
    mov eax, APP_BROWSER
    call wm_content
    call brow_areas
    call brow_page_w
    mov [br_lw], eax
    call html_layout
    call brow_set_title

    mov esi, br_url
    mov edi, br_addr
    call str_copy
    cmp byte [br_frag], 0
    je .status
    mov esi, br_frag_mark
    call str_append
    mov esi, br_frag
    call str_append
.status:
    mov esi, br_addr
    call brow_addr_set
    call brow_done_status
.placed:

    mov eax, [br_want]
    cmp eax, -1
    jne .scroll
    xor eax, eax
    cmp byte [br_frag], 0
    je .scroll
    mov esi, br_frag
    call html_anchor_y
    jnc .anch
    xor eax, eax
    jmp .scroll
.anch:
    sub eax, 6
.scroll:
    mov [br_scroll], eax
    call brow_clamp
    or byte [gui_dirty], 1
    popad
    ret

section .data
br_frag_mark db "#", 0
section .text

brow_split_frag:
    pushad
.f: mov al, [esi]
    test al, al
    jz .done
    cmp al, '#'
    je .frag
    inc esi
    jmp .f
.frag:
    mov byte [esi], 0
    inc esi
    mov edi, br_frag
    mov ecx, 250
.c: lodsb
    stosb
    test al, al
    jz .done
    loop .c
    mov byte [edi], 0
.done:
    popad
    ret

brow_addr_unfocus:
    mov dword [br_typing], 0
    mov dword [br_sel], 0
    mov dword [pg_field], 0
    ret

brow_status_outbuf:
    pushad
    mov edi, [out_ptr]
    mov byte [edi], 0
    mov byte [out_mode], 0
    mov esi, OUTBUF
    call brow_status_set
    popad
    ret

brow_done_status:
    pushad
    call out_begin
    cmp dword [br_loaded], 0
    je .failed
    mov eax, [br_url]
    and eax, 0x00FFFFFF
    cmp eax, 'abo'
    je .builtin
    mov eax, [br_bytes]
    add eax, 1023
    shr eax, 10
    PRINTF `Done - %d KB`, eax
    cmp dword [http_status], 200
    je .ok
    PRINTF ` - the server answered %d`, dword [http_status]
.ok:
    cmp dword [br_secure], 0
    je .plain
    PRINTF ` - secure: HTTPS, TLS 1.3, certificate checked`
    jmp .show
.plain:
    PRINTF ` - not encrypted (plain HTTP)`
    jmp .show
.builtin:
    PRINTF `MOOS Browser - built-in page`
    jmp .show
.failed:
    PRINTF `Could not load the page.`
.show:
    call brow_status_outbuf
    popad
    ret

brow_kind:
    pushad
    mov dword [br_kind], KIND_HTML
    cmp byte [http_ctype], 0
    je .sniff
    mov esi, http_ctype
    mov edi, ct_html
    call str_has_ci
    je .done
    mov dword [br_kind], KIND_TEXT
    mov edi, ct_text
    call str_has_ci
    je .done
    mov edi, ct_json
    call str_has_ci
    je .done
    mov edi, ct_js
    call str_has_ci
    je .done
    mov edi, ct_xml
    call str_has_ci
    je .done
    mov dword [br_kind], KIND_OTHER
    jmp .done
.sniff:
    jecxz .done
.s: cmp byte [esi], ' '
    ja .first
    inc esi
    loop .s
    jmp .done
.first:
    cmp byte [esi], '<'
    je .done
    mov dword [br_kind], KIND_TEXT
.done:
    popad
    ret

str_has_ci:
    push esi
.l: cmp byte [esi], 0
    je .no
    xchg esi, edi
    call str_iprefix
    xchg esi, edi
    je .out
    inc esi
    jmp .l
.no:
    or esi, esi
.out:
    pop esi
    ret

brow_error_page:
    pushad
    mov dword [br_loaded], 0
    mov edi, BR_TMP
    mov esi, err_p1
    call str_copy
    mov esi, br_url
    call html_escape_append
    mov esi, err_p2
    call str_append
    mov esi, [url_err]
    call html_escape_append
    mov esi, err_p3
    call str_append
    mov esi, BR_TMP
    call str_len
    call html_parse
    popad
    ret

brow_other_page:
    pushad
    mov edi, BR_TMP
    mov esi, oth_p1
    call str_copy
    mov esi, http_ctype
    cmp byte [esi], 0
    jne .t
    mov esi, oth_unknown
.t: call html_escape_append
    mov esi, oth_p2
    call str_append
    mov esi, BR_TMP
    call str_len
    call html_parse
    popad
    ret

html_escape_append:
    pushad
    push esi
    mov esi, edi
    call str_len
    add edi, ecx
    pop esi
.l: lodsb
    test al, al
    jz .e
    cmp al, '&'
    je .amp
    cmp al, '<'
    je .lt
    stosb
    jmp .l
.amp:
    mov eax, '&amp'
    stosd
    mov al, ';'
    stosb
    jmp .l
.lt:
    mov eax, '&lt;'
    stosd
    jmp .l
.e: mov byte [edi], 0
    popad
    ret

url_tidy:
    pushad
.sp:
    cmp byte [esi], ' '
    jne .go
    inc esi
    jmp .sp
.go:
    call url_has_scheme
    jnc .copy
    push esi
    mov esi, br_http
    call str_copy_noterm
    pop esi
.copy:
    mov ecx, URL_MAX - 8
.c: lodsb
    test al, al
    jz .e
    stosb
    loop .c
.e: mov byte [edi], 0
.trim:
    cmp byte [edi - 1], ' '
    jne .done
    dec edi
    mov byte [edi], 0
    jmp .trim
.done:
    popad
    ret

url_has_scheme:
    push ecx
    push esi
    xor ecx, ecx
.l: mov al, [esi + ecx]
    cmp al, '-'
    je .next
    or al, 0x20
    cmp al, 'a'
    jb .end
    cmp al, 'z'
    ja .end
.next:
    inc ecx
    jmp .l
.end:
    cmp byte [esi + ecx], ':'
    jne .no
    cmp ecx, 2
    jb .no
    mov eax, ecx
    clc
    jmp .out
.no:
    stc
.out:
    pop esi
    pop ecx
    ret

url_join:
    pushad
    mov [uj_out], edi
.sp:
    cmp byte [esi], ' '
    ja .go
    cmp byte [esi], 0
    je .go
    inc esi
    jmp .sp
.go:
    call url_has_scheme
    jc .relative
    mov edi, br_http
    call .is
    je .whole
    mov edi, url_https
    call .is
    je .whole
    mov edi, br_about
    call .is
    je .whole
    mov edi, br_vsrc
    call .is
    je .whole
    popad
    stc
    ret
.is:
    xchg esi, edi
    call str_iprefix
    xchg esi, edi
    ret
.whole:
    mov edi, [uj_out]
    call uj_copy
    jmp .dots
.relative:

    mov edx, ebx
    push esi
    mov esi, ebx
    mov edi, br_scheme_sep
    call str_find
    pop esi
    jc .noorigin
    lea edx, [eax + 3]
.host:
    mov al, [edx]
    test al, al
    jz .hend
    cmp al, '/'
    je .hend
    cmp al, '?'
    je .hend
    cmp al, '#'
    je .hend
    inc edx
    jmp .host
.noorigin:
    mov edi, [uj_out]
    call uj_copy
    jmp .dots
.hend:
    mov edi, [uj_out]
    cmp word [esi], '//'
    je .proto
    cmp byte [esi], '/'
    je .root
    cmp byte [esi], '#'
    je .frag
    cmp byte [esi], '?'
    je .query
    cmp byte [esi], 0
    je .same

    mov ecx, edx
.lp:
    mov al, [ecx]
    test al, al
    jz .lpe
    cmp al, '?'
    je .lpe
    cmp al, '#'
    je .lpe
    inc ecx
    jmp .lp
.lpe:
    cmp ecx, edx
    jbe .noslash
    dec ecx
    cmp byte [ecx], '/'
    jne .lpe
    inc ecx
    call .base_to
    jmp .rest
.noslash:
    mov ecx, edx
    call .base_to
    mov al, '/'
    stosb
    jmp .rest
.proto:
    mov ecx, ebx
.pc:
    cmp byte [ecx], ':'
    je .pce
    inc ecx
    jmp .pc
.pce:
    inc ecx
    call .base_to
    jmp .rest
.root:
    mov ecx, edx
    call .base_to
    jmp .rest
.frag:
    mov ecx, ebx
.fc:
    cmp byte [ecx], 0
    je .fce
    cmp byte [ecx], '#'
    je .fce
    inc ecx
    jmp .fc
.fce:
    call .base_to
    jmp .rest
.query:
    mov ecx, ebx
.qc:
    cmp byte [ecx], 0
    je .qce
    cmp byte [ecx], '?'
    je .qce
    cmp byte [ecx], '#'
    je .qce
    inc ecx
    jmp .qc
.qce:
    call .base_to
    jmp .rest
.same:
    mov ecx, edx
.sc:
    cmp byte [ecx], 0
    je .sce
    cmp byte [ecx], '#'
    je .sce
    inc ecx
    jmp .sc
.sce:
    call .base_to
.rest:
    call uj_copy
.dots:
    mov edi, [uj_out]
    call url_dots
    popad
    clc
    ret

.base_to:
    push esi
    mov esi, ebx
.bt:
    cmp esi, ecx
    jae .bte
    movsb
    jmp .bt
.bte:
    pop esi
    ret

section .bss
alignb 4
uj_out      resd 1
section .text

uj_copy:
    push eax
    push ecx
    mov ecx, [uj_out]
    add ecx, URL_MAX - 4
.l: cmp edi, ecx
    jae .e
    lodsb
    cmp al, ' '
    jb .e
    je .pct
    cmp al, 0x7F
    jae .pct
    cmp al, '"'
    je .pct
    stosb
    jmp .l
.pct:
    push eax
    mov al, '%'
    stosb
    pop eax
    push eax
    shr al, 4
    call .hex
    pop eax
    and al, 0x0F
    call .hex
    jmp .l
.hex:
    add al, '0'
    cmp al, '9'
    jbe .h
    add al, 'A' - '9' - 1
.h: stosb
    ret
.e: mov byte [edi], 0
    pop ecx
    pop eax
    ret

str_find:
    push esi
.l: cmp byte [esi], 0
    je .no
    xchg esi, edi
    call str_prefix_cs
    xchg esi, edi
    je .yes
    inc esi
    jmp .l
.yes:
    mov eax, esi
    pop esi
    clc
    ret
.no:
    pop esi
    stc
    ret

str_prefix_cs:
    push eax
    push esi
    push edi
.l: mov al, [esi]
    test al, al
    jz .out
    cmp al, [edi]
    jne .out
    inc esi
    inc edi
    jmp .l
.out:
    pop edi
    pop esi
    pop eax
    ret

url_dots:
    pushad
    mov esi, edi
    mov edi, br_scheme_sep
    call str_find
    jc .done
    lea esi, [eax + 3]
.h: mov al, [esi]
    test al, al
    jz .done
    cmp al, '/'
    je .path
    cmp al, '?'
    je .done
    cmp al, '#'
    je .done
    inc esi
    jmp .h
.path:
    mov ebx, esi
    mov edi, esi
.seg:
    mov al, [esi]
    cmp al, '/'
    jne .tail
    mov edx, esi
    inc edx
    mov ecx, edx
.se:
    mov al, [ecx]
    test al, al
    jz .sgot
    cmp al, '/'
    je .sgot
    cmp al, '?'
    je .sgot
    cmp al, '#'
    je .sgot
    inc ecx
    jmp .se
.sgot:
    mov eax, ecx
    sub eax, edx
    cmp eax, 1
    jne .two
    cmp byte [edx], '.'
    jne .keep
    call .last_slash
    mov esi, ecx
    jmp .seg
.two:
    cmp eax, 2
    jne .keep
    cmp word [edx], '..'
    jne .keep
.up:
    cmp edi, ebx
    jbe .upd
    dec edi
    cmp byte [edi], '/'
    jne .up
.upd:
    call .last_slash
    mov esi, ecx
    jmp .seg
.keep:
    mov ecx, ecx
.k: cmp esi, ecx
    jae .seg
    movsb
    jmp .k

.last_slash:
    mov al, [ecx]
    cmp al, '/'
    je .ls
    mov byte [edi], '/'
    inc edi
.ls:
    ret
.tail:
    cmp edi, ebx
    ja .t
    mov byte [edi], '/'
    inc edi
.t: lodsb
    stosb
    test al, al
    jnz .t
.done:
    popad
    ret
