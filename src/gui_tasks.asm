; =============================================================================
;  gui_tasks.asm - the Task Manager (desktop app 6) and the desktop's CPU
;  accounting
;
;  MOOS has no processes and no scheduler: the desktop is one loop (cmd_gui
;  in gui.asm) that polls the mouse and the keyboard, hands what happened
;  to the window manager and the apps, and redraws. So "CPU usage" here
;  means: of the processor's time, how much went into real work (handling
;  input, app code, drawing, waiting for the network inside an app) and how
;  much into polling while nothing happened.
;
;  It is measured with the time-stamp counter (RDTSC, in cycles). Every
;  cycle is charged to exactly one owner:
;    CPU_IDLE   the main loop's rounds in which nothing happens: polling
;               the mouse and the keyboard, glancing at the clock, ticks
;               that found nothing to do
;    1 - 15     a desktop app: everything between cpu_enter and cpu_leave
;               around a call into the app (init, draw, key, click, wheel,
;               hover, drag, and a tick that did some work)
;    CPU_DESK   the rest of the desktop's work: window manager, taskbar,
;               wallpaper, mouse cursor, copying frames to the screen
;  Owners nest: cpu_enter keeps the previous owner on a small stack and
;  cpu_leave goes back to it (the browser redraws the whole desktop while a
;  page loads; the other windows' drawing is still charged to them).
;
;  Once a second (100 timer ticks) cpu_sample turns the counts into
;  thousandths of that second per owner, measures the TSC's rate against
;  the timer, the network traffic (net.asm's counters) and the frames
;  drawn, and adds a point to the 60-second histories. When the loop was
;  held up longer (a page loading), the whole stretch is averaged and fills
;  one point per second.
;
;  The Task Manager window shows, updated after every sample:
;    - the open windows: name, state, CPU %, memory, and an "End task"
;      button (closes the window and gives the app's big blocks back)
;    - CPU: the last 60 seconds as a graph, the current %, the TSC's MHz
;    - network: bytes received / sent per second (graph) and in total
;    - memory: kernel code and variables, the fixed buffers, big blocks by
;      owner (big_owned), and the RAM installed and still free (the
;      firmware's memory map, efi_memmap)
;    - uptime and the desktop's frames per second
;  Keys: Up / Down pick a row, Enter brings that window to the front,
;  Delete (or E) ends it; Page Up / Page Down / Home / End and the mouse
;  wheel scroll when it does not all fit. The layout follows the window's
;  size: two columns when it is wide, one when it is narrow, and the graphs
;  grow into any room left at the bottom.
;
;  Once a second only the Task Manager's own content is drawn again and
;  copied to the screen when its window is on top (gui_content_dirty), so
;  watching the numbers costs little of what it measures.
; =============================================================================
CPU_IDLE    equ 0                   ; owners of CPU time (see above)
CPU_DESK    equ 16
CPU_N       equ 17
CPU_DEPTH   equ 16                  ; how deep cpu_enter may nest
CPU_HIST      equ 60                  ; seconds of history

TK_ROW_H    equ 22                  ; the Task Manager's layout
TK_LINE     equ 18
TK_WIDE     equ 600                 ; two columns from this width
TK_COLS_W   equ 500                 ; all table columns from this width

TK_C_HEAD   equ 0x8FA6BC            ; colours
TK_C_TEXT   equ 0xC8D4E0
TK_C_DIM    equ 0x8A96A2
TK_C_VALUE  equ 0xFFFFFF
TK_C_CPU    equ 0x4C9BE8
TK_C_RX     equ 0x5CC77E
TK_C_TX     equ 0xE8A04C
TK_C_GRAPH  equ 0x0B0F14
TK_C_GRID   equ 0x1E2A36
TK_C_FRAME  equ 0x3A4A5A
TK_C_SEL    equ 0x24384C
TK_C_BTN    equ 0x7A2E2E
TK_LEFT_FIX equ 118                 ; the left column without its graphs
TK_GH_CPU   equ 90                  ; graph heights side by side with the
TK_GH_NET   equ 70                  ; memory list (more if there is room)
TK_GH_CPU1  equ 64                  ; ... and in one column
TK_GH_NET1  equ 56
TK_GH_MAX   equ 280                 ; never taller than this

section .bss
alignb 8
cpu_acc     resd 2 * CPU_N          ; cycles by owner, this second (64-bit)
cpu_last    resd 2                  ; TSC when the current owner took over
cpu_t0      resd 2                  ; TSC when this second began
cpu_owner   resd 1                  ; who is charged now
cpu_sp      resd 1
cpu_stack   resd CPU_DEPTH          ; owners to go back to (cpu_leave)
cpu_tick0   resd 1                  ; ticks when this second began
cpu_pm      resd CPU_N              ; the last sample: thousandths by owner
cpu_busy    resd 1                  ; ... all but idle
cpu_mhz     resd 1                  ; ... the TSC's rate
cpu_samples resd 1                  ; samples taken (counts up)
cpu_shift   resd 1
gui_frames  resd 1                  ; frames drawn since the last sample
gui_fps     resd 1                  ; ... per second, at the last sample
net_rx_last resd 2                  ; traffic counters at the last sample
net_tx_last resd 2
net_rx_rate resd 1                  ; bytes per second, last sample
net_tx_rate resd 1
cpuh_cpu    resd CPU_HIST             ; rings: busy thousandths, bytes/s in,
cpuh_rx     resd CPU_HIST             ; bytes/s out
cpuh_tx     resd CPU_HIST
cpuh_head   resd 1                  ; the next slot to write
cpuh_n      resd 1                  ; points so far (at most CPU_HIST)

tk_bss_start:                       ; (the Task Manager's own memory)
tk_x        resd 1                  ; layout while drawing
tk_y        resd 1
tk_w        resd 1
tk_cx       resd 1                  ; the column being drawn
tk_cw       resd 1
tk_ytop     resd 1
tk_yleft    resd 1
tk_y0       resd 1                  ; where the content starts (scrolled)
tk_scroll   resd 1                  ; pixels scrolled down
tk_content_h resd 1                 ; the content's height, last drawn
tk_mem_h    resd 1                  ; the memory list's height, last drawn
tk_gh_cpu   resd 1                  ; the graphs' heights this time
tk_gh_net   resd 1
tk_wide     resd 1
tk_full     resd 1
tk_col_st   resd 1                  ; table columns (from tk_x)
tk_col_cpu  resd 1
tk_col_mem  resd 1
tk_btn_x    resd 1                  ; End-task buttons (from cb_x)
tk_btn_w    resd 1
tk_rows_top resd 1                  ; first row (from cb_y)
tk_rows     resd 1                  ; rows in the table, and their apps
tk_row_app  resd 16
tk_sel      resd 1                  ; the selected row
tk_seen     resd 1                  ; cpu_samples when last refreshed
tk_ram_kb   resd 1                  ; the firmware's memory map
tk_free_kb  resd 1
tk_gscale   resd 1                  ; tk_graph: value at the top,
tk_ginset   resd 1                  ; 1 = thinner bars (a second series)
tk_gx       resd 1
tk_gy       resd 1
tk_gw       resd 1
tk_gh       resd 1
tk_gcol     resd 1
tk_gi       resd 1
tk_b        resb 128                ; a line being built
tk_bss_end:
TK_MEM      equ tk_bss_end - tk_bss_start

section .data
tk_names    dd 0, tn_term, tn_edit, tn_ide, tn_brow, tn_set, tn_tasks
tn_term     db "Terminal", 0
tn_edit     db "Text Editor", 0
tn_ide      db "Script IDE", 0
tn_brow     db "Browser", 0
tn_set      db "Settings", 0
tn_tasks    db "Task Manager", 0
; memory each app has in the kernel's own variables and buffers
tk_fixed    dd 0, GUI_LOG + 168, TX_SIZE, TX_SIZE, 0x200000, 88, TK_MEM
tk_h_win    db "Window", 0
tk_h_state  db "State", 0
tk_h_cpu    db "CPU", 0
tk_h_mem    db "Memory", 0
tk_s_focus  db "focused", 0
tk_s_run    db "running", 0
tk_s_min    db "minimized", 0
tk_s_desk   db "Desktop", 0
tk_s_dwork  db "drawing", 0
tk_end_l    db "End task", 0
tk_end_s    db "End", 0
tk_t_cpu    db "CPU", 0
tk_t_idle   db "   idle ", 0
tk_t_60     db "last 60 s   TSC ", 0
tk_t_mhz    db " MHz   ", 0
tk_t_fps    db " frames/s", 0
tk_t_net    db "Network", 0
tk_t_in     db "   in ", 0
tk_t_out    db "   out ", 0
tk_t_ps     db "/s", 0
tk_t_tot    db "total in ", 0
tk_t_tot2   db ", out ", 0
tk_t_pk     db " packets", 0
tk_t_scale  db "top: ", 0
tk_t_nonet  db "not connected", 0
tk_t_mem    db "Memory", 0
tk_m_kcode  db "Kernel code + data", 0
tk_m_kvar   db "Kernel variables", 0
tk_m_fixed  db "Fixed buffers", 0
tk_m_screen db "  screen", 0
tk_m_down   db "  downloads", 0
tk_m_web    db "  web pages", 0
tk_m_stack  db "  stack, room to grow", 0
tk_m_other  db "  files, network, other", 0
tk_m_big    db "Big blocks", 0
tk_m_moos   db "MOOS in total", 0
tk_m_ram    db "RAM installed", 0
tk_m_free   db "Free (firmware)", 0
tk_m_unk    db "?", 0
tk_t_up     db "Uptime ", 0
tk_t_days   db "d ", 0
tk_own_snd  db "  sound", 0
tk_own_net  db "  network", 0
tk_own_med  db "  video / audio", 0
tk_own_img  db "  pictures", 0
tk_own_sys  db "  system", 0
tk_own_app  db "  app ", 0
tk_own_pre  db "  ", 0

section .text

; ============================================================ accounting
; cpu_reset: start counting from now (the desktop starts)
cpu_reset:
    pushad
    mov edi, cpu_acc
    mov ecx, 2 * CPU_N
    xor eax, eax
    rep stosd
    mov edi, cpu_pm
    mov ecx, CPU_N
    rep stosd
    mov [cpu_sp], eax
    mov [cpuh_n], eax
    mov [cpuh_head], eax
    mov [gui_frames], eax
    mov [gui_fps], eax
    mov [cpu_busy], eax
    mov [net_rx_rate], eax
    mov [net_tx_rate], eax
    mov dword [cpu_owner], CPU_DESK
    mov eax, [net_rx_bytes]
    mov [net_rx_last], eax
    mov eax, [net_rx_bytes + 4]
    mov [net_rx_last + 4], eax
    mov eax, [net_tx_bytes]
    mov [net_tx_last], eax
    mov eax, [net_tx_bytes + 4]
    mov [net_tx_last + 4], eax
    mov eax, [ticks]
    mov [cpu_tick0], eax
    rdtsc
    mov [cpu_last], eax
    mov [cpu_last + 4], edx
    mov [cpu_t0], eax
    mov [cpu_t0 + 4], edx
    popad
    ret

; cpu_charge: the cycles since cpu_last go to the current owner
; (EAX, EDX changed)
cpu_charge:
    push ecx
    push esi
    push edi
    rdtsc
    mov esi, eax
    mov edi, edx
    sub eax, [cpu_last]
    sbb edx, [cpu_last + 4]
    mov ecx, [cpu_owner]
    add [cpu_acc + ecx * 8], eax
    adc [cpu_acc + ecx * 8 + 4], edx
    mov [cpu_last], esi
    mov [cpu_last + 4], edi
    pop edi
    pop esi
    pop ecx
    ret

; cpu_switch: EAX = owner -> from now on its time (the main loop's level;
; nothing is kept to go back to). Keeps all registers and flags.
cpu_switch:
    pushfd
    push eax
    push edx
    call cpu_charge
    mov eax, [esp + 4]
    mov [cpu_owner], eax
    pop edx
    pop eax
    popfd
    ret

; cpu_enter: EAX = owner -> its time until the matching cpu_leave. Keeps
; all registers and flags.
cpu_enter:
    pushfd
    push eax
    push edx
    call cpu_charge
    mov edx, [cpu_sp]
    cmp edx, CPU_DEPTH
    jae .deep                       ; (too deep: just switch)
    mov eax, [cpu_owner]
    mov [cpu_stack + edx * 4], eax
.deep:
    inc dword [cpu_sp]
    mov eax, [esp + 4]
    mov [cpu_owner], eax
    pop edx
    pop eax
    popfd
    ret

; cpu_leave: back to the owner before the last cpu_enter. Keeps all
; registers and flags.
cpu_leave:
    pushfd
    push eax
    push edx
    call cpu_charge
    mov edx, [cpu_sp]
    test edx, edx
    jz .done                        ; (unbalanced: ignore)
    dec edx
    mov [cpu_sp], edx
    cmp edx, CPU_DEPTH
    jae .done
    mov eax, [cpu_stack + edx * 4]
    mov [cpu_owner], eax
.done:
    pop edx
    pop eax
    popfd
    ret

; cpu_leave_idle: like cpu_leave, but the time since cpu_enter was only
; polling: it is charged to idle
cpu_leave_idle:
    pushfd
    mov dword [cpu_owner], CPU_IDLE
    popfd
    jmp cpu_leave

; cpu_sample_check: called every round of the main loop; samples once a
; second
cpu_sample_check:
    push eax
    mov eax, [ticks]
    sub eax, [cpu_tick0]
    cmp eax, PIT_HZ
    jb .r
    call cpu_sample
.r: pop eax
    ret

; cpu_sample: EAX = ticks since the last sample -> cpu_pm, cpu_busy,
; cpu_mhz, gui_fps, net rates and one history point per second
cpu_sample:
    pushad
    mov ebx, eax                    ; EBX = ticks in this sample
    call cpu_charge                 ; (bring the counts up to now)
    mov eax, [ticks]
    mov [cpu_tick0], eax
    mov eax, [cpu_last]             ; EDX:EAX = cycles in the sample
    mov edx, [cpu_last + 4]
    mov ecx, eax
    mov esi, edx
    xchg eax, [cpu_t0]              ; (this second starts now)
    xchg edx, [cpu_t0 + 4]
    sub ecx, eax
    sbb esi, edx                    ; ESI:ECX = total
    ; the TSC's rate: cycles / (ticks * 10000) = MHz
    push ebx
    mov eax, ebx
    imul eax, eax, 1000000 / PIT_HZ
    mov ebx, eax
    mov eax, ecx
    mov edx, esi
    cmp edx, ebx
    jae .no_mhz
    div ebx
    mov [cpu_mhz], eax
.no_mhz:
    pop ebx
    ; shift the total (and later each count) below 2^32
    xor eax, eax
.shift:
    test esi, esi
    jz .shifted
    shrd ecx, esi, 1
    shr esi, 1
    inc eax
    jmp .shift
.shifted:
    mov [cpu_shift], eax
    test ecx, ecx
    jnz .total_ok
    inc ecx
.total_ok:
    ; thousandths for each owner (ECX = total)
    xor edi, edi
.owner:
    mov eax, [cpu_acc + edi * 8]
    mov edx, [cpu_acc + edi * 8 + 4]
    push ecx
    mov ecx, [cpu_shift]
    jecxz .noshift
.sh:
    shrd eax, edx, 1
    shr edx, 1
    loop .sh
.noshift:
    pop ecx
    test edx, edx                   ; (cannot be more than the total)
    jnz .all
    cmp eax, ecx
    jbe .part
.all:
    mov eax, ecx
.part:
    mov edx, 1000
    mul edx
    div ecx
    mov [cpu_pm + edi * 4], eax
    mov dword [cpu_acc + edi * 8], 0
    mov dword [cpu_acc + edi * 8 + 4], 0
    inc edi
    cmp edi, CPU_N
    jb .owner
    mov eax, 1000
    sub eax, [cpu_pm + CPU_IDLE * 4]
    jns .busy
    xor eax, eax
.busy:
    mov [cpu_busy], eax
    ; frames per second, rounded (EBX = ticks in this sample)
    mov eax, [gui_frames]
    mov ecx, PIT_HZ
    mul ecx
    mov ecx, ebx
    shr ecx, 1
    add eax, ecx
    adc edx, 0
    div ebx
    mov [gui_fps], eax
    mov dword [gui_frames], 0
    ; network: bytes per second since the last sample
    mov esi, net_rx_bytes
    mov edi, net_rx_last
    call .rate
    mov [net_rx_rate], eax
    mov esi, net_tx_bytes
    mov edi, net_tx_last
    call .rate
    mov [net_tx_rate], eax
    ; whole seconds in this sample (at least 1)
    mov eax, ebx
    add eax, PIT_HZ / 2
    xor edx, edx
    mov ecx, PIT_HZ
    div ecx
    test eax, eax
    jnz .secs
    inc eax
.secs:
    mov ebx, eax                    ; EBX = seconds
    ; one history point per second (at most a full history)
    cmp ebx, CPU_HIST
    jbe .points
    mov ebx, CPU_HIST
.points:
    mov ecx, [cpuh_head]
    mov eax, [cpu_busy]
    mov [cpuh_cpu + ecx * 4], eax
    mov eax, [net_rx_rate]
    mov [cpuh_rx + ecx * 4], eax
    mov eax, [net_tx_rate]
    mov [cpuh_tx + ecx * 4], eax
    inc ecx
    cmp ecx, CPU_HIST
    jb .head
    xor ecx, ecx
.head:
    mov [cpuh_head], ecx
    cmp dword [cpuh_n], CPU_HIST
    jae .full
    inc dword [cpuh_n]
.full:
    dec ebx
    jnz .points
    inc dword [cpu_samples]
    popad
    ret
; .rate: ESI = a 64-bit byte counter, EDI = its value at the last sample
; (updated), EBX = ticks since -> EAX = bytes per second
.rate:
    mov eax, [esi]
    mov edx, [esi + 4]
    mov ecx, eax
    sub ecx, [edi]
    mov [edi], eax
    mov [edi + 4], edx
    mov eax, ecx
    mov ecx, PIT_HZ
    mul ecx
    cmp edx, ebx
    jae .huge
    div ebx
    ret
.huge:
    mov eax, -1
    ret

; gui_app_ticks: every open app's tick (a chance to work in the background,
; e.g. a player feeding the sound card), charged to the app when it did
; something (CF=1) and to idle when it only looked
gui_app_ticks:
    pushad
    mov eax, 1
.l: test dword [wn_f + eax * 4], WF_OPEN
    jz .n
    call cpu_enter
    push eax
    call app_tick
    pop eax                         ; (keeps CF)
    jc .worked
    call cpu_leave_idle
    jmp .n
.worked:
    call cpu_leave
.n: inc eax
    cmp eax, NAPPS
    jbe .l
    popad
    ret

; ============================================================ the window
; tasks_init: the window opens
tasks_init:
    mov dword [tk_sel], 0
    mov dword [tk_rows], 0
    mov dword [tk_scroll], 0
    mov dword [tk_content_h], 0
    mov dword [tk_mem_h], 300       ; (a guess until it is drawn)
    jmp tasks_refresh

; tasks_tick: after each new sample: read the memory map again and redraw
; (if the window can be seen) -> CF=1 if it did that
tasks_tick:
    push eax
    mov eax, [cpu_samples]
    cmp eax, [tk_seen]
    je .idle
    mov [tk_seen], eax
    call tasks_refresh
    mov eax, APP_TASKS              ; (just its content, if it is on top;
    call gui_content_dirty          ; nothing if it is minimized)
    pop eax
    stc
    ret
.idle:
    pop eax
    clc
    ret

; tasks_refresh: the RAM installed and free, from the firmware's map now
tasks_refresh:
    pushad
    call efi_memmap
    test eax, eax
    jnz .map
    mov eax, [bootinfo + BI.ram_kb] ; (no map: what the loader counted)
    mov edx, -1
.map:
    mov [tk_ram_kb], eax
    mov [tk_free_kb], edx
    popad
    ret

; tasks_app_mem: EAX = app -> EAX = bytes it uses: its part of the
; kernel's memory and its big blocks
tasks_app_mem:
    push edx
    mov edx, eax
    call big_owned
    cmp edx, NAPPS
    ja .r
    add eax, [tk_fixed + edx * 4]
.r: pop edx
    ret

; tasks_end: EAX = app -> End task: the app lets go of what it holds
; (app_end), its window closes, and the big blocks it still owns go back
; to the firmware
tasks_end:
    pushad
    test dword [wn_f + eax * 4], WF_OPEN
    jz .done
    push eax
    call cpu_enter
    call app_end
    call cpu_leave
    pop eax
    call gui_close
    mov edx, eax
    call big_free_owner
    or byte [gui_dirty], 1
.done:
    popad
    ret

; tasks_click: a click in the window: pick a row; on its button, end it
tasks_click:
    pushad
    mov eax, [mouse_y]
    sub eax, [cb_y]
    sub eax, [tk_rows_top]
    js .done
    xor edx, edx
    mov ecx, TK_ROW_H
    div ecx                         ; EAX = row, EDX = y inside it
    cmp eax, [tk_rows]
    jae .done
    mov [tk_sel], eax
    push eax
    mov eax, APP_TASKS
    call gui_content_dirty
    pop eax
    mov ecx, [mouse_x]
    sub ecx, [cb_x]
    cmp ecx, [tk_btn_x]
    jl .done
    mov ebx, [tk_btn_x]
    add ebx, [tk_btn_w]
    cmp ecx, ebx
    jge .done
    cmp edx, 1                      ; (the button is 1 .. 19 in the row)
    jb .done
    cmp edx, TK_ROW_H - 3
    ja .done
    mov eax, [tk_row_app + eax * 4]
    test eax, eax
    jz .done
    call tasks_end
.done:
    popad
    ret

; tasks_key: EAX = key. Up / Down pick a row, Enter brings its window to
; the front, Delete or E ends it; Page Up / Page Down / Home / End scroll.
tasks_key:
    pushad
    mov ecx, [tk_sel]
    cmp eax, KEY_UP
    je .up
    cmp eax, KEY_DOWN
    je .down
    mov edx, [wn_h + APP_TASKS * 4] ; a page: the content's height, less
    sub edx, TITLE_H + 2 + 40       ; a little to keep the place
    cmp edx, TK_LINE
    jge .page
    mov edx, TK_LINE
.page:
    cmp eax, KEY_PGUP
    je .pgup
    cmp eax, KEY_PGDN
    je .pgdn
    cmp eax, KEY_HOME
    je .home
    cmp eax, KEY_END
    je .end_key
    cmp ecx, [tk_rows]
    jae .done
    mov ebx, [tk_row_app + ecx * 4]
    test ebx, ebx
    jz .done                        ; (the Desktop row)
    cmp eax, 10
    je .front
    cmp eax, KEY_DEL
    je .end
    or eax, 0x20
    cmp eax, 'e'
    jne .done
.end:
    mov eax, ebx
    call tasks_end
    jmp .done
.front:
    mov eax, ebx
    call gui_raise
    jmp .done
.up:
    test ecx, ecx
    jz .done
    dec dword [tk_sel]
    jmp .done
.down:
    inc ecx
    cmp ecx, [tk_rows]
    jae .done
    mov [tk_sel], ecx
    jmp .done
.pgup:
    neg edx
.pgdn:
    mov eax, edx
    call tk_scroll_by
    jmp .done
.home:
    mov dword [tk_scroll], 0
    jmp .done
.end_key:
    mov dword [tk_scroll], 0x7FFFFFF ; (drawing stops it at the end)
.done:
    mov eax, APP_TASKS
    call gui_content_dirty
    popad
    ret

; tasks_wheel: EAX = wheel notches (+ = away from you: up) -> scroll three
; lines a notch
tasks_wheel:
    push eax
    imul eax, eax, -3 * TK_LINE
    call tk_scroll_by
    mov eax, APP_TASKS
    call gui_content_dirty
    pop eax
    ret

; tk_scroll_by: EAX = pixels (+ = down) -> tk_scroll, not above the top
; (tasks_draw keeps it from going past the end)
tk_scroll_by:
    push eax
    add eax, [tk_scroll]
    jns .s
    xor eax, eax
.s: mov [tk_scroll], eax
    pop eax
    ret

; -------------------------------------------------------- drawing helpers
; tk_text: ESI = text at ECX = x, EDX = y in colour EAX (0xRRGGBB)
tk_text:
    pushad
    call gfx_rgb
    mov ebx, eax
    mov ebp, -1
    call gfx_text
    popad
    ret

; tk_text_r: the same, ending at x = ECX (right-aligned)
tk_text_r:
    push ecx
    push ecx
    call str_len
    shl ecx, 3
    neg ecx
    add ecx, [esp]
    add esp, 4
    call tk_text
    pop ecx
    ret

; tk_rect: ECX = x, EDX = y, ESI = width, EDI = height, EAX = 0xRRGGBB
tk_rect:
    pushad
    call gfx_rgb
    call gfx_fillrect
    popad
    ret

; tk_bstart: EDI = tk_b, empty
tk_bstart:
    mov edi, tk_b
    mov byte [edi], 0
    ret

; tk_kv: ESI = label at (tk_cx, tk_y), tk_b right-aligned at the column's
; right edge; then the next line
tk_kv:
    pushad
    mov ecx, [tk_cx]
    mov edx, [tk_y]
    mov eax, TK_C_TEXT
    call tk_text
    mov ecx, [tk_cx]
    add ecx, [tk_cw]
    mov esi, tk_b
    mov eax, TK_C_VALUE
    call tk_text_r
    add dword [tk_y], TK_LINE
    popad
    ret

; tk_kv_bytes: ESI = label, EAX = bytes -> one line of tk_kv
tk_kv_bytes:
    push edi
    call tk_bstart
    call sb_bytes
    pop edi
    jmp tk_kv

; tk_graph_box: the graph's background, frame and lines at 1/4, 1/2, 3/4
; (tk_gx, tk_gy, tk_gw, tk_gh)
tk_graph_box:
    pushad
    mov ecx, [tk_gx]
    mov edx, [tk_gy]
    mov esi, [tk_gw]
    mov edi, [tk_gh]
    mov eax, TK_C_GRAPH
    call tk_rect
    mov ebx, 1
.grid:
    mov eax, [tk_gh]
    imul eax, ebx
    shr eax, 2
    mov edx, [tk_gy]
    add edx, eax
    mov ecx, [tk_gx]
    mov esi, [tk_gw]
    mov edi, 1
    mov eax, TK_C_GRID
    call tk_rect
    inc ebx
    cmp ebx, 4
    jb .grid
    mov eax, TK_C_FRAME
    call gfx_rgb
    mov ecx, [tk_gx]
    mov edx, [tk_gy]
    mov esi, [tk_gw]
    mov edi, [tk_gh]
    call gfx_frame
    popad
    ret

; tk_graph: bars for the history EBX (CPU_HIST values, oldest at the left,
; the newest at the right edge) in colour EAX, scaled so that tk_gscale is
; the top; tk_ginset = 1 draws thinner bars (a second series over the
; first)
tk_graph:
    pushad
    mov [tk_gcol], eax
    mov dword [tk_gi], 0
.bar:
    mov eax, CPU_HIST - 1             ; the point's age in seconds
    sub eax, [tk_gi]
    cmp eax, [cpuh_n]
    jae .next                       ; (no point that old yet)
    mov ecx, [cpuh_head]            ; its slot: head - 1 - age
    dec ecx
    sub ecx, eax
    jns .slot
    add ecx, CPU_HIST
.slot:
    mov eax, [ebx + ecx * 4]        ; the value -> bar height
    test eax, eax
    jz .next
    mov ecx, [tk_gh]
    sub ecx, 2
    mul ecx
    mov ecx, [tk_gscale]
    cmp edx, ecx
    jae .top
    div ecx
    mov ecx, [tk_gh]
    sub ecx, 2
    cmp eax, ecx
    jbe .h
.top:
    mov eax, [tk_gh]                ; (off the scale: the full height)
    sub eax, 2
.h: test eax, eax
    jnz .h1
    inc eax                         ; (anything at all: one pixel)
.h1:
    mov edi, eax                    ; EDI = height
    mov eax, [tk_gi]                ; x from i * width / CPU_HIST
    mov ecx, [tk_gw]
    sub ecx, 2
    mul ecx
    mov ecx, CPU_HIST
    div ecx
    mov esi, eax
    mov eax, [tk_gi]
    inc eax
    mov ecx, [tk_gw]
    sub ecx, 2
    mul ecx
    mov ecx, CPU_HIST
    div ecx
    sub eax, esi                    ; EAX = this bar's width
    mov ecx, esi
    add ecx, [tk_gx]
    inc ecx                         ; ECX = x
    cmp eax, 3
    jb .w
    dec eax                         ; (a gap between wide bars)
.w: cmp dword [tk_ginset], 0
    je .full
    mov esi, eax                    ; thinner, in the middle
    shr esi, 2
    add ecx, esi
    shr eax, 1
    jnz .full
    inc eax
.full:
    mov esi, eax
    mov edx, [tk_gy]
    add edx, [tk_gh]
    dec edx
    sub edx, edi
    mov eax, [tk_gcol]
    call tk_rect
.next:
    inc dword [tk_gi]
    cmp dword [tk_gi], CPU_HIST
    jb .bar
    popad
    ret

; tk_hist_max: EBX = a history -> EAX = its largest value
tk_hist_max:
    push ecx
    xor eax, eax
    xor ecx, ecx
.l: cmp [ebx + ecx * 4], eax
    jbe .n
    mov eax, [ebx + ecx * 4]
.n: inc ecx
    cmp ecx, CPU_HIST
    jb .l
    pop ecx
    ret

; --------------------------------------------------------------- drawing
tasks_draw:
    pushad
    mov dword [gfx_scale], 1
    mov eax, [tk_content_h]         ; never scrolled past the end (as tall
    sub eax, [cb_h]                 ; as it was last time)
    jns .maxok
    xor eax, eax
.maxok:
    cmp [tk_scroll], eax
    jle .scrollok
    mov [tk_scroll], eax
.scrollok:
    mov eax, [cb_x]
    add eax, 10
    mov [tk_x], eax
    mov eax, [cb_y]
    add eax, 8
    sub eax, [tk_scroll]
    mov [tk_y], eax
    mov [tk_y0], eax
    mov eax, [cb_w]
    sub eax, 20
    mov [tk_w], eax
    xor ebx, ebx
    cmp eax, TK_WIDE
    jl .w
    inc ebx
.w: mov [tk_wide], ebx
    xor ebx, ebx
    cmp eax, TK_COLS_W
    jl .f
    inc ebx
.f: mov [tk_full], ebx
    call tk_draw_table
    ; below the table: CPU and network on the left, memory on the right
    ; (or all in one column when the window is narrow)
    mov eax, [tk_x]
    mov [tk_cx], eax
    mov eax, [tk_w]
    cmp dword [tk_wide], 0
    je .one
    imul eax, eax, 56
    xor edx, edx
    mov ecx, 100
    div ecx
.one:
    mov [tk_cw], eax
    mov eax, [tk_y]
    mov [tk_ytop], eax
    call tk_graph_sizes
    call tk_draw_cpu
    call tk_draw_net
    cmp dword [tk_wide], 0
    je .stack
    mov eax, [tk_y]                 ; right column, from the same top
    mov [tk_yleft], eax
    mov eax, [tk_ytop]
    mov [tk_y], eax
    mov eax, [tk_cw]
    add eax, 24
    add [tk_cx], eax
    mov eax, [tk_w]
    sub eax, [tk_cw]
    sub eax, 24
    mov [tk_cw], eax
.stack:
    mov ebx, [tk_y]                 ; (measure the memory list)
    call tk_draw_mem
    call tk_draw_footer
    mov eax, [tk_y]
    sub eax, ebx
    mov [tk_mem_h], eax
    ; the content's height: down to the lower column, and a margin
    mov eax, [tk_y]
    cmp dword [tk_wide], 0
    je .lower
    cmp eax, [tk_yleft]
    jge .lower
    mov eax, [tk_yleft]
.lower:
    sub eax, [tk_y0]
    add eax, 16
    mov [tk_content_h], eax
    call tk_scrollbar
    popad
    ret

; tk_graph_sizes: tk_gh_cpu / tk_gh_net = the graphs' heights for this
; window: the usual ones, plus a share of the room left at the bottom (60%
; to the CPU graph), up to TK_GH_MAX each. tk_y = where the CPU part starts.
tk_graph_sizes:
    pushad
    mov eax, TK_GH_CPU
    mov ebx, TK_GH_NET
    mov ecx, TK_LEFT_FIX            ; ECX = the rest of the (left) column
    cmp dword [tk_wide], 0
    jne .room
    mov eax, TK_GH_CPU1             ; one column: the memory list is
    mov ebx, TK_GH_NET1             ; below the graphs too
    add ecx, [tk_mem_h]
.room:
    mov edx, [cb_y]                 ; EDX = the room left over: from here
    add edx, [cb_h]                 ; (unscrolled) to the bottom margin,
    sub edx, 8                      ; less everything in the column
    sub edx, [tk_y]
    sub edx, [tk_scroll]
    sub edx, ecx
    sub edx, eax
    sub edx, ebx
    jle .set
    mov esi, edx                    ; 60% to the CPU graph, the rest to
    imul esi, esi, 6                ; the network graph
    push eax
    push edx
    mov eax, esi
    xor edx, edx
    mov esi, 10
    div esi
    mov esi, eax
    pop edx
    pop eax
    sub edx, esi
    add eax, esi
    add ebx, edx
    cmp eax, TK_GH_MAX
    jbe .cpu_ok
    mov eax, TK_GH_MAX
.cpu_ok:
    cmp ebx, TK_GH_MAX
    jbe .set
    mov ebx, TK_GH_MAX
.set:
    mov [tk_gh_cpu], eax
    mov [tk_gh_net], ebx
    popad
    ret

; tk_scrollbar: when the content is taller than the window, a thin bar at
; the right edge shows which part of it is in view
tk_scrollbar:
    pushad
    mov ebx, [tk_content_h]         ; EBX = content height
    mov ebp, [cb_h]                 ; EBP = window height
    cmp ebx, ebp
    jle .done
    mov ecx, [cb_x]                 ; the track
    add ecx, [cb_w]
    sub ecx, 6
    mov edx, [cb_y]
    add edx, 2
    mov esi, 4
    lea edi, [ebp - 4]
    mov eax, TK_C_GRID
    call tk_rect
    mov eax, edi                    ; the thumb: as tall as the part in
    mul ebp                         ; view, at least 16
    div ebx
    cmp eax, 16
    jge .th
    mov eax, 16
.th:
    push eax
    sub edi, eax                    ; EDI = the track's free length
    mov eax, edi
    mul dword [tk_scroll]
    mov ecx, ebx
    sub ecx, ebp                    ; / the most it can scroll
    div ecx
    cmp eax, edi
    jbe .ty
    mov eax, edi
.ty:
    mov edx, [cb_y]
    add edx, 2
    add edx, eax
    pop edi
    mov ecx, [cb_x]
    add ecx, [cb_w]
    sub ecx, 6
    mov esi, 4
    mov eax, TK_C_DIM
    call tk_rect
.done:
    popad
    ret

; tk_draw_table: the open windows, one row each, and the desktop
tk_draw_table:
    pushad
    ; columns for this width
    mov dword [tk_col_st], 150
    mov dword [tk_col_cpu], 262
    mov dword [tk_col_mem], 330
    mov dword [tk_btn_w], 84
    cmp dword [tk_full], 0
    jne .cols
    mov dword [tk_col_st], -1       ; narrow: no State column
    mov dword [tk_col_cpu], 118
    mov dword [tk_col_mem], 176
    mov dword [tk_btn_w], 44
.cols:
    mov eax, [tk_w]                 ; the buttons, at the right
    add eax, 10
    sub eax, [tk_btn_w]
    mov [tk_btn_x], eax
    ; the headings
    mov ecx, [tk_x]
    mov edx, [tk_y]
    mov eax, TK_C_HEAD
    mov esi, tk_h_win
    call tk_text
    mov ebx, [tk_col_st]
    test ebx, ebx
    js .nost
    lea ecx, [ecx + ebx]
    mov esi, tk_h_state
    call tk_text
.nost:
    mov ecx, [tk_x]
    add ecx, [tk_col_cpu]
    mov esi, tk_h_cpu
    call tk_text
    mov ecx, [tk_x]
    add ecx, [tk_col_mem]
    mov esi, tk_h_mem
    call tk_text
    add dword [tk_y], 20
    mov eax, [tk_y]
    sub eax, [cb_y]
    mov [tk_rows_top], eax
    ; the rows: every open window, in app order
    xor ebx, ebx                    ; EBX = rows so far
    mov ebp, 1                      ; EBP = app
.app:
    test dword [wn_f + ebp * 4], WF_OPEN
    jz .next
    mov [tk_row_app + ebx * 4], ebp
    call tk_draw_row
    inc ebx
.next:
    inc ebp
    cmp ebp, NAPPS
    jbe .app
    mov dword [tk_row_app + ebx * 4], 0
    xor ebp, ebp                    ; the desktop's own row
    call tk_draw_row
    inc ebx
    mov [tk_rows], ebx
    mov eax, [tk_sel]               ; (rows may have gone)
    cmp eax, ebx
    jb .sel
    lea eax, [ebx - 1]
    mov [tk_sel], eax
.sel:
    add dword [tk_y], 8             ; a line under the table
    mov ecx, [tk_x]
    mov edx, [tk_y]
    mov esi, [tk_w]
    mov edi, 1
    mov eax, TK_C_FRAME
    call tk_rect
    add dword [tk_y], 10
    popad
    ret

; tk_draw_row: EBX = row, EBP = app (0 = the desktop) -> its row at tk_y
tk_draw_row:
    pushad
    cmp ebx, [tk_sel]
    jne .bg
    mov ecx, [tk_x]                 ; the selected row
    sub ecx, 4
    mov edx, [tk_y]
    mov esi, [tk_w]
    add esi, 8
    mov edi, TK_ROW_H
    mov eax, TK_C_SEL
    call tk_rect
.bg:
    mov edx, [tk_y]
    add edx, 3
    test ebp, ebp
    jz .desk
    ; name, in a colour by state
    mov esi, [tk_names + ebp * 4]
    mov edi, tk_s_run
    mov eax, TK_C_TEXT
    test dword [wn_f + ebp * 4], WF_MIN
    jz .notmin
    mov edi, tk_s_min
    mov eax, TK_C_DIM
.notmin:
    cmp ebp, [cur_app]
    jne .named
    mov edi, tk_s_focus
    mov eax, TK_C_VALUE
.named:
    mov ecx, [tk_x]
    call tk_text
    mov esi, edi                    ; state
    jmp .state
.desk:
    mov ecx, [tk_x]
    mov esi, tk_s_desk
    mov eax, TK_C_HEAD
    call tk_text
    mov esi, tk_s_dwork
.state:
    mov ecx, [tk_col_st]
    test ecx, ecx
    js .cpu
    add ecx, [tk_x]
    call tk_text
.cpu:
    call tk_bstart                  ; CPU %
    mov eax, CPU_DESK
    test ebp, ebp
    jz .pm
    mov eax, ebp
.pm:
    mov eax, [cpu_pm + eax * 4]
    call sb_permille
    mov ecx, [tk_x]
    add ecx, [tk_col_cpu]
    add ecx, 6 * 8                  ; (right-aligned: "100.0%")
    mov esi, tk_b
    mov eax, TK_C_VALUE
    call tk_text_r
    call tk_bstart                  ; memory
    test ebp, ebp
    jz .deskmem
    mov eax, ebp
    call tasks_app_mem
    jmp .mem
.deskmem:
    mov eax, [gfx_w]                ; the desktop: its screen copy
    imul eax, [gfx_h]
    shl eax, 2
.mem:
    call sb_bytes
    mov ecx, [tk_x]
    add ecx, [tk_col_mem]
    mov esi, tk_b
    mov eax, TK_C_VALUE
    call tk_text
    ; the End-task button
    test ebp, ebp
    jz .done
    mov ecx, [cb_x]
    add ecx, [tk_btn_x]
    mov edx, [tk_y]
    inc edx
    mov esi, [tk_btn_w]
    mov edi, TK_ROW_H - 4
    mov eax, TK_C_BTN
    call tk_rect
    mov esi, tk_end_l
    cmp dword [tk_full], 0
    jne .lbl
    mov esi, tk_end_s
.lbl:
    push ecx
    call str_len                    ; centred
    shl ecx, 3
    mov eax, [tk_btn_w]
    sub eax, ecx
    shr eax, 1
    pop ecx
    add ecx, eax
    add edx, 1
    mov eax, TK_C_VALUE
    call tk_text
.done:
    add dword [tk_y], TK_ROW_H
    popad
    ret

; tk_draw_cpu: "CPU 12.3%  idle 87.7%", the graph, the TSC rate and fps
tk_draw_cpu:
    pushad
    mov ecx, [tk_cx]
    mov edx, [tk_y]
    mov esi, tk_t_cpu
    mov eax, TK_C_VALUE
    call tk_text
    call tk_bstart
    mov eax, [cpu_busy]
    call sb_permille
    add ecx, 5 * 8
    mov esi, tk_b
    mov eax, TK_C_CPU
    call tk_text
    call tk_bstart
    mov esi, tk_t_idle
    call sb_str
    mov eax, [cpu_pm + CPU_IDLE * 4]
    call sb_permille
    add ecx, 6 * 8
    mov esi, tk_b
    mov eax, TK_C_DIM
    call tk_text
    add dword [tk_y], 20
    ; the graph: 0 - 100 %
    mov eax, [tk_cx]
    mov [tk_gx], eax
    mov eax, [tk_y]
    mov [tk_gy], eax
    mov eax, [tk_cw]
    mov [tk_gw], eax
    mov eax, [tk_gh_cpu]
    mov [tk_gh], eax
    call tk_graph_box
    mov dword [tk_gscale], 1000
    mov dword [tk_ginset], 0
    mov ebx, cpuh_cpu
    mov eax, TK_C_CPU
    call tk_graph
    mov eax, [tk_gh]
    add eax, 4
    add [tk_y], eax
    ; "last 60 s   TSC 2904 MHz   12 frames/s"
    call tk_bstart
    mov esi, tk_t_60
    call sb_str
    mov eax, [cpu_mhz]
    call sb_uint
    mov esi, tk_t_mhz
    call sb_str
    mov eax, [gui_fps]
    call sb_uint
    mov esi, tk_t_fps
    call sb_str
    mov ecx, [tk_cx]
    mov edx, [tk_y]
    mov esi, tk_b
    mov eax, TK_C_HEAD
    call tk_text
    add dword [tk_y], TK_LINE + 8
    popad
    ret

; tk_draw_net: "Network  in 1.2 KB/s  out 300 B/s", the graph (in = green
; bars, out = thinner orange bars), the totals and the address
tk_draw_net:
    pushad
    mov ecx, [tk_cx]
    mov edx, [tk_y]
    mov esi, tk_t_net
    mov eax, TK_C_VALUE
    call tk_text
    add ecx, 7 * 8
    call tk_bstart
    mov esi, tk_t_in
    call sb_str
    mov eax, [net_rx_rate]
    call sb_bytes
    mov esi, tk_t_ps
    call sb_str
    mov esi, tk_b
    mov eax, TK_C_RX
    call tk_text
    call str_len
    shl ecx, 3
    add ecx, [tk_cx]
    add ecx, 7 * 8
    call tk_bstart
    mov esi, tk_t_out
    call sb_str
    mov eax, [net_tx_rate]
    call sb_bytes
    mov esi, tk_t_ps
    call sb_str
    mov esi, tk_b
    mov eax, TK_C_TX
    call tk_text
    add dword [tk_y], 20
    ; the graph, scaled to the busiest second (at least 1 KB/s)
    mov eax, [tk_cx]
    mov [tk_gx], eax
    mov eax, [tk_y]
    mov [tk_gy], eax
    mov eax, [tk_cw]
    mov [tk_gw], eax
    mov eax, [tk_gh_net]
    mov [tk_gh], eax
    call tk_graph_box
    mov ebx, cpuh_rx
    call tk_hist_max
    mov edx, eax
    mov ebx, cpuh_tx
    call tk_hist_max
    cmp eax, edx
    jae .max
    mov eax, edx
.max:
    cmp eax, 1024
    jae .scale
    mov eax, 1024
.scale:
    mov [tk_gscale], eax
    mov dword [tk_ginset], 0
    mov ebx, cpuh_rx
    mov eax, TK_C_RX
    call tk_graph
    mov dword [tk_ginset], 1
    mov ebx, cpuh_tx
    mov eax, TK_C_TX
    call tk_graph
    call tk_bstart                  ; the scale, inside the top left
    mov esi, tk_t_scale
    call sb_str
    mov eax, [tk_gscale]
    call sb_bytes
    mov esi, tk_t_ps
    call sb_str
    mov ecx, [tk_gx]
    add ecx, 4
    mov edx, [tk_gy]
    add edx, 2
    mov esi, tk_b
    mov eax, TK_C_DIM
    call tk_text
    mov eax, [tk_gh]
    add eax, 4
    add [tk_y], eax
    ; "total in 1.5 MB, out 200 KB"
    call tk_bstart
    mov esi, tk_t_tot
    call sb_str
    mov eax, [net_rx_bytes]
    mov edx, [net_rx_bytes + 4]
    xor ecx, ecx
    call sb_size
    mov esi, tk_t_tot2
    call sb_str
    mov eax, [net_tx_bytes]
    mov edx, [net_tx_bytes + 4]
    xor ecx, ecx
    call sb_size
    mov ecx, [tk_cx]
    mov edx, [tk_y]
    mov esi, tk_b
    mov eax, TK_C_HEAD
    call tk_text
    add dword [tk_y], TK_LINE
    ; the address and the card
    call tk_bstart
    cmp byte [net_up], 0
    je .down
    mov eax, [my_ip]
    call sb_ip
    jmp .card
.down:
    mov esi, tk_t_nonet
    call sb_str
.card:
    cmp byte [net_present], 0
    je .shown
    mov al, ' '
    call sb_char
    mov al, '('
    call sb_char
    mov esi, [nic_name]
    call sb_str
    mov al, ')'
    call sb_char
.shown:
    mov ecx, [tk_cx]
    mov edx, [tk_y]
    mov esi, tk_b
    mov eax, TK_C_HEAD
    call tk_text
    add dword [tk_y], TK_LINE + 8
    popad
    ret

; tk_draw_mem: where the memory goes
tk_draw_mem:
    pushad
    mov ecx, [tk_cx]
    mov edx, [tk_y]
    mov esi, tk_t_mem
    mov eax, TK_C_VALUE
    call tk_text
    add dword [tk_y], 20
    mov eax, kernel_image_end       ; the kernel
    sub eax, kbase
    mov esi, tk_m_kcode
    call tk_kv_bytes
    mov eax, bss_end
    sub eax, bss_start
    mov esi, tk_m_kvar
    call tk_kv_bytes
    mov eax, bss_end                ; everything else MOOS reserved at start
    sub eax, kbase
    neg eax
    add eax, KMEM_SIZE
    mov esi, tk_m_fixed
    call tk_kv_bytes
    mov ebx, eax                    ; EBX = what the lines below leave over
    mov eax, 0x500000
    sub ebx, eax
    mov esi, tk_m_screen
    call tk_kv_bytes
    mov eax, PKG_BUF_SIZE
    sub ebx, eax
    mov esi, tk_m_down
    call tk_kv_bytes
    mov eax, 0x200000
    sub ebx, eax
    mov esi, tk_m_web
    call tk_kv_bytes
    mov eax, bss_end                ; from the variables' end to the top
    sub eax, kbase                  ; of the stack
    neg eax
    add eax, STACK_OFF - 0x10000
    sub ebx, eax
    mov esi, tk_m_stack
    call tk_kv_bytes
    mov eax, ebx
    mov esi, tk_m_other
    call tk_kv_bytes
    ; big blocks from the firmware, and whose they are
    mov eax, [big_total]
    mov esi, tk_m_big
    call tk_kv_bytes
    xor ebp, ebp                    ; EBP = owner
.owner:
    mov edx, ebp
    call big_owned
    test eax, eax
    jz .next
    mov ebx, eax
    call tk_bstart                  ; its name
    mov esi, tk_own_sys
    test ebp, ebp
    jz .name
    cmp ebp, NAPPS
    ja .known
    mov esi, tk_own_pre             ; a desktop app
    call sb_str
    mov esi, [tk_names + ebp * 4]
    jmp .name
.known:
    mov esi, tk_own_snd
    cmp ebp, OWN_SOUND
    je .name
    mov esi, tk_own_net
    cmp ebp, OWN_NET
    je .name
    mov esi, tk_own_med
    cmp ebp, OWN_MEDIA
    je .name
    mov esi, tk_own_img
    cmp ebp, OWN_IMAGES
    je .name
    mov esi, tk_own_app             ; (an owner MOOS has no name for yet)
    call sb_str
    mov eax, ebp
    call sb_uint
    jmp .named
.name:
    call sb_str
.named:
    mov esi, tk_b                   ; (the name moves to a second buffer
    mov edi, tk_b + 64              ; so tk_b can take the size)
    call str_copy
    mov eax, ebx
    call tk_bstart
    call sb_bytes
    mov esi, tk_b + 64
    call tk_kv
.next:
    inc ebp
    cmp ebp, 32
    jb .owner
    ; MOOS in total, the RAM, what is free
    mov eax, KMEM_SIZE
    add eax, [big_total]
    mov esi, tk_m_moos
    call tk_kv_bytes
    call tk_bstart
    mov eax, [tk_ram_kb]
    call sb_kb
    mov esi, tk_m_ram
    call tk_kv
    call tk_bstart
    mov eax, [tk_free_kb]
    cmp eax, -1
    je .unknown
    call sb_kb
    jmp .free
.unknown:
    mov esi, tk_m_unk
    call sb_str
.free:
    mov esi, tk_m_free
    call tk_kv
    add dword [tk_y], 8
    popad
    ret

; tk_draw_footer: "Uptime 1d 2:03:04"
tk_draw_footer:
    pushad
    call tk_bstart
    mov esi, tk_t_up
    call sb_str
    mov eax, [ticks]
    xor edx, edx
    mov ecx, PIT_HZ
    div ecx                         ; seconds
    xor edx, edx
    mov ecx, 86400
    div ecx                         ; EAX = days, EDX = the rest
    test eax, eax
    jz .hms
    call sb_uint
    mov esi, tk_t_days
    call sb_str
.hms:
    mov eax, edx
    xor edx, edx
    mov ecx, 3600
    div ecx
    call sb_uint                    ; hours
    mov eax, edx
    xor edx, edx
    mov ecx, 60
    div ecx
    call .two                       ; minutes
    mov eax, edx
    call .two                       ; seconds
    mov ecx, [tk_cx]
    mov edx, [tk_y]
    mov esi, tk_b
    mov eax, TK_C_TEXT
    call tk_text
    add dword [tk_y], TK_LINE
    popad
    ret
.two:                               ; ":07"
    push eax
    mov al, ':'
    call sb_char
    pop eax
    cmp eax, 10
    jae .t
    push eax
    mov al, '0'
    call sb_char
    pop eax
.t: jmp sb_uint
