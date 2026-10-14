VID_MAX     equ 8
VR_SRC      equ 0
VR_POSTER   equ 4
VR_AUTO     equ 8
VR_AUDIO    equ 12
VR_X        equ 16
VR_Y        equ 20
VR_W        equ 24
VR_H        equ 28
VR_SIZE     equ 32

PS_IDLE     equ 0
PS_LOADING  equ 1
PS_BUFFER   equ 2
PS_PLAY     equ 3
PS_PAUSE    equ 4
PS_END      equ 5
PS_ERROR    equ 6

PL_CHUNK    equ 65536
PL_PIECE    equ 8 * 1024 * 1024
PL_MAXFILE  equ 768 * 1024 * 1024
PL_BITMAP   equ PL_MAXFILE / PL_CHUNK / 8
PL_READ     equ 1024 * 1024
PL_NEAR     equ 2 * 1024 * 1024
PL_AHEAD    equ 1500
PL_QUEUE    equ 400
PL_MAXMOOV  equ 64 * 1024 * 1024
PL_MAXW     equ 1920
PL_MAXH     equ 1088
PL_PTSQ     equ 32
PL_LATE     equ 100
PL_BEHIND   equ 1500

PL_SLICE    equ 3
PL_BARTIME  equ 250
CB_H        equ 34
C_PLAYED    equ 0xE53935

section .bss
alignb 4
vid_tab     resb VID_MAX * VR_SIZE
vid_n       resd 1
pl_autostart resd 1
pl_rec      resd 1
pl_state    resd 1
pl_msg      resd 1
pl_full     resd 1
pl_pause_req resd 1
pl_lastmove resd 1
pl_mx       resd 1
pl_my       resd 1
pl_bar_up   resd 1
pl_newpic   resd 1
pl_ui       resd 1
pl_lastsec  resd 1
pl_dl_t     resd 1
pl_dl_new   resd 1
pl_redraw_t resd 1
pl_volume   resd 1
pl_vol_set  resd 1
pl_muted    resd 1
pl_url      resb 4096

pl_file     resd 1
pl_fsize    resd 1
pl_bits     resb PL_BITMAP
pl_st_open  resd 1
pl_st_piece0 resd 1
pl_st_pos   resd 1
pl_st_end   resd 1
pl_norange  resd 1
pl_fails    resd 1
pl_retry_t  resd 1

pl_want     resd 1
pl_scan     resd 1
pl_moov_off resd 1
pl_moov_len resd 1
pl_moov_ok  resd 1
pl_info     resd 1
pl_work     resd 1
pl_worklen  resd 1
pl_hasv     resd 1
pl_hasa     resd 1
pl_vsamp    resd 1
pl_vcount   resd 1
pl_vnext    resd 1
pl_vscale   resd 1
pl_vend     resd 1
pl_flushed  resd 1
pl_asamp    resd 1
pl_acount   resd 1
pl_anext    resd 1
pl_ascale   resd 1
pl_dur_ms   resd 1

pl_h264     resd 1
pl_h264mem  resd 1
pl_h264len  resd 1
pl_nalsize  resd 1
pl_aac      resd 1
pl_rate     resd 1
pl_chans    resd 1
pl_card     resd 1
pl_sound    resd 1
pl_snd_paused resd 1
pl_awritten resd 1
pl_snd_lost resd 1
pl_maxw     resd 1
pl_maxh     resd 1
pl_vw       resd 1
pl_vh       resd 1
pl_nw       resd 1
pl_nh       resd 1
pl_pic      resd 1
pl_next     resd 1
pl_pic_ok   resd 1
pl_next_ok  resd 1
pl_next_ms  resd 1
pl_dropped  resd 1
pl_vbusy    resd 1
pl_shown_t  resd 1
pl_ptsq     resd PL_PTSQ
pl_ptsn     resd 1
pl_lastpts  resd 1

pl_held     resd 1
pl_hold_ms  resd 1
pl_base_ms  resd 1
pl_t0       resd 1
pl_frame    resb 64
alignb 16
pl_pcm      resw 1024 * 8

pl_tabs_ok  resd 1
pl_ty       resd 256
pl_trv      resd 256
pl_tgu      resd 256
pl_tgv      resd 256
pl_tbu      resd 256
pl_clamp    resb 1024
cv_row      resd 1
cv_u        resd 1
cv_v        resd 1
cv_n        resd 1
cv_tmp      resd 1
cv_guv      resd 1

vd_rec      resd 1
vd_x        resd 1
vd_y        resd 1
vd_w        resd 1
vd_h        resd 1
vd_st       resd 1
vd_by       resd 1
vd_tx       resd 1
vd_gx0      resd 1
vd_gx1      resd 1
vd_vx0      resd 1
vd_vx1      resd 1
vd_fx0      resd 1
vd_cx       resd 1
vd_cy       resd 1
vd_run      resd 1
vd_time     resb 48
section .text

vid_reset:
    call pl_stop
    mov dword [vid_n], 0
    mov dword [pl_autostart], 0
    cmp dword [pl_vol_set], 0
    jne .r
    mov dword [pl_volume], 80
    mov dword [pl_vol_set], 1
.r: ret

vid_get:
    push ecx
    push edi
    push ebp
    mov ebp, ecx
    xor ecx, ecx
    mov edi, vid_tab
.l: cmp ecx, [vid_n]
    jae .new
    cmp [edi + VR_SRC], esi
    je .found
    add edi, VR_SIZE
    inc ecx
    jmp .l
.new:
    cmp ecx, VID_MAX
    jae .full
    inc dword [vid_n]
    mov [edi + VR_SRC], esi
    mov [edi + VR_POSTER], ebx
    mov [edi + VR_AUTO], ebp
    mov [edi + VR_AUDIO], edx
    xor eax, eax
    mov [edi + VR_W], eax
    test ebp, ebp
    jz .found
    cmp dword [pl_rec], 0
    jne .found
    cmp dword [pl_autostart], 0
    jne .found
    mov [pl_autostart], edi
.found:
    mov eax, edi
    pop ebp
    pop edi
    pop ecx
    ret
.full:
    xor eax, eax
    pop ebp
    pop edi
    pop ecx
    ret

vid_unseen:
    push ecx
    push edi
    xor ecx, ecx
    mov edi, vid_tab
.l: cmp ecx, [vid_n]
    jae .e
    mov dword [edi + VR_W], 0
    add edi, VR_SIZE
    inc ecx
    jmp .l
.e: pop edi
    pop ecx
    ret

vid_at:
    push eax
    push ecx
    xor ecx, ecx
    mov edi, vid_tab
.l: cmp ecx, [vid_n]
    jae .no
    cmp dword [edi + VR_W], 0
    je .n
    mov eax, [mouse_x]
    sub eax, [edi + VR_X]
    jl .n
    cmp eax, [edi + VR_W]
    jge .n
    mov eax, [mouse_y]
    sub eax, [edi + VR_Y]
    jl .n
    cmp eax, [edi + VR_H]
    jl .yes
.n: add edi, VR_SIZE
    inc ecx
    jmp .l
.yes:
    pop ecx
    pop eax
    clc
    ret
.no:
    pop ecx
    pop eax
    stc
    ret

pl_stop:
    pushad
    call pl_close_stream
    cmp dword [pl_sound], 0
    je .nsnd
    call snd_close
.nsnd:
    mov edx, OWN_MEDIA
    call big_free_owner
    cmp dword [pl_full], 0
    je .nf
    or byte [gui_dirty], 1
.nf:
    xor eax, eax
    mov edi, pl_rec
    mov ecx, (pl_volume - pl_rec) / 4
    rep stosd
    mov edi, pl_file
    mov ecx, (pl_frame - pl_file) / 4
    rep stosd
    popad
    ret

pl_start:
    pushad
    push edi
    call pl_stop
    pop edi
    mov [pl_rec], edi
    mov dword [pl_held], 1
    mov eax, [ticks]
    mov [pl_lastmove], eax
    mov esi, [edi + VR_SRC]
    mov edi, pl_url
    call brow_resolve
    jc .badurl
    mov dword [pl_state], PS_LOADING
    mov dword [pl_msg], pl_s_conn
    or byte [gui_dirty], 1
    call gui_redraw
    xor eax, eax
    call pl_open_at
    jc .fail
    mov ecx, [pl_fsize]
    test ecx, ecx
    jz .nosize
    cmp ecx, PL_MAXFILE
    ja .toobig
    mov edx, OWN_MEDIA
    call big_alloc
    test eax, eax
    jz .nomem
    mov [pl_file], eax
    mov edi, pl_bits
    mov ecx, PL_BITMAP / 4
    xor eax, eax
    rep stosd
    mov dword [pl_msg], pl_s_load
    mov dword [pl_ui], 1
    popad
    ret
.badurl:
    mov eax, pl_e_url
    jmp .err
.fail:
    mov eax, pl_e_conn
    jmp .err
.nosize:
    mov eax, pl_e_size
    jmp .err
.toobig:
    mov eax, pl_e_big
    jmp .err
.nomem:
    mov eax, pl_e_mem
.err:
    call pl_error
    popad
    ret

pl_error:
    pushad
    mov [pl_msg], eax
    call pl_close_stream
    cmp dword [pl_sound], 0
    je .ns
    call snd_close
    mov dword [pl_sound], 0
.ns:
    mov dword [pl_state], PS_ERROR
    mov dword [pl_ui], 1
    popad
    ret

pl_open_at:
    pushad
    call pl_close_stream
    and eax, ~(PL_CHUNK - 1)
    cmp dword [pl_norange], 0
    je .r0
    xor eax, eax
.r0:
    mov [pl_st_piece0], eax
    mov [pl_st_pos], eax
    lea ecx, [eax + PL_PIECE]
    cmp dword [pl_fsize], 0
    je .r
    push eax
    call pl_next_here
    cmp ecx, eax
    jbe .r1
    mov ecx, eax
.r1:
    pop eax
.r: mov [pl_st_end], ecx
    dec ecx
    mov [url_range_start], eax
    mov [url_range_end], ecx
    cmp dword [pl_norange], 0
    je .ask
    mov dword [url_range_start], -1
.ask:
    mov esi, pl_url
    mov byte [url_insecure], 0
    mov byte [gui_capture], 2
    call hs_open
    mov byte [gui_capture], 0
    mov dword [url_range_start], -1
    jc .fail
    mov eax, [hs_status]
    cmp eax, 206
    je .part
    cmp eax, 200
    jne .bad
    mov dword [pl_norange], 1
    cmp dword [pl_st_pos], 0
    jne .bad
    mov eax, [hs_clen]
    test eax, eax
    jz .bad
    mov [pl_st_end], eax
    jmp .size
.part:
    mov eax, [hs_total]
.size:
    cmp dword [pl_fsize], 0
    jne .known
    mov [pl_fsize], eax
.known:
    mov eax, [pl_fsize]
    cmp [pl_st_end], eax
    jbe .ok
    mov [pl_st_end], eax
.ok:
    mov dword [pl_st_open], 1
    popad
    clc
    ret
.bad:
    call hs_close
.fail:
    popad
    stc
    ret

pl_close_stream:
    cmp dword [pl_st_open], 0
    je .r
    call hs_close
    mov dword [pl_st_open], 0
.r: ret

pl_mark:
    pushad
    shr eax, 16
    mov edx, ecx
    cmp edx, [pl_fsize]
    jne .notend
    add edx, PL_CHUNK - 1
.notend:
    shr edx, 16
.l: cmp eax, edx
    jae .done
    bts [pl_bits], eax
    inc eax
    jmp .l
.done:
    popad
    ret

pl_present:
    pushad
    cmp dword [pl_file], 0
    je .no
    test ecx, ecx
    jz .yes
    mov edx, eax
    add edx, ecx
    jc .no
    cmp edx, [pl_fsize]
    ja .no
    shr eax, 16
    dec edx
    shr edx, 16
.l: bt [pl_bits], eax
    jnc .no
    inc eax
    cmp eax, edx
    jbe .l
.yes:
    popad
    clc
    ret
.no:
    popad
    stc
    ret

pl_missing:
    push edx
    mov edx, [pl_fsize]
    add edx, PL_CHUNK - 1
    shr edx, 16
    shr eax, 16
.l: cmp eax, edx
    jae .none
    bt [pl_bits], eax
    jnc .found
    inc eax
    jmp .l
.found:
    shl eax, 16
    pop edx
    ret
.none:
    mov eax, [pl_fsize]
    pop edx
    ret

pl_next_here:
    push edx
    mov edx, [pl_fsize]
    add edx, PL_CHUNK - 1
    shr edx, 16
    shr eax, 16
.l: cmp eax, edx
    jae .none
    bt [pl_bits], eax
    jc .found
    inc eax
    jmp .l
.found:
    shl eax, 16
    pop edx
    ret
.none:
    mov eax, [pl_fsize]
    pop edx
    ret

pl_all_here:
    push eax
    xor eax, eax
    call pl_missing
    cmp eax, [pl_fsize]
    pop eax
    jb .no
    clc
    ret
.no:
    stc
    ret

pl_need:
    cmp dword [pl_moov_ok], 0
    jne .samples
    mov eax, [pl_want]
    ret
.samples:
    push ebx
    mov eax, [pl_fsize]
    mov ebx, [pl_vnext]
    cmp ebx, [pl_vcount]
    jae .a
    shl ebx, 4
    add ebx, [pl_vsamp]
    mov eax, [ebx + MP4S_OFF]
.a: mov ebx, [pl_anext]
    cmp ebx, [pl_acount]
    jae .r
    shl ebx, 4
    add ebx, [pl_asamp]
    mov ebx, [ebx + MP4S_OFF]
    cmp ebx, eax
    jae .r
    mov eax, ebx
.r: pop ebx
    ret

pl_download:
    pushad
    cmp dword [pl_file], 0
    je .done
    cmp dword [pl_st_open], 0
    je .open_needed
    call pl_need
    mov ebx, eax
    cmp ebx, [pl_fsize]
    jae .read
    mov ecx, 1
    call pl_present
    jnc .read
    cmp dword [pl_norange], 0
    jne .read
    cmp ebx, [pl_st_piece0]
    jb .move
    mov eax, [pl_st_pos]
    add eax, PL_NEAR
    cmp ebx, eax
    jb .read
.move:
    call pl_close_stream
    jmp .open_needed
.read:
    xor ebp, ebp
.rl:
    mov edi, [pl_st_pos]
    mov ecx, [pl_st_end]
    sub ecx, edi
    jbe .piece_done
    cmp ecx, 65536
    jbe .n
    mov ecx, 65536
.n: add edi, [pl_file]
    call hs_read
    test eax, eax
    jz .done
    js .ended
    mov ecx, [pl_st_pos]
    add [pl_st_pos], eax
    add ebp, eax
    mov dword [pl_fails], 0
    mov dword [pl_dl_new], 1
    mov eax, ecx
    and eax, ~(PL_CHUNK - 1)
    mov ecx, [pl_st_pos]
    call pl_mark
    cmp ebp, PL_READ
    jb .rl
    jmp .done
.ended:
    mov eax, [pl_st_pos]
    cmp eax, [pl_st_end]
    jae .piece_done
    call pl_close_stream
    call pl_failed
    jmp .done
.piece_done:
    call pl_close_stream
.open_needed:
    mov eax, [ticks]
    cmp eax, [pl_retry_t]
    js .done
    call pl_need
    call pl_missing
    cmp eax, [pl_fsize]
    jb .open
    xor eax, eax
    call pl_missing
    cmp eax, [pl_fsize]
    jae .done
.open:
    call pl_open_at
    jnc .done
    call pl_failed
.done:
    popad
    ret

pl_failed:
    inc dword [pl_fails]
    push eax
    mov eax, [pl_fails]
    imul eax, 50
    add eax, [ticks]
    mov [pl_retry_t], eax
    pop eax
    cmp dword [pl_fails], 8
    jb .r
    mov eax, pl_e_net
    call pl_error
.r: ret

pl_find_index:
    pushad
    cmp dword [pl_moov_len], 0
    jne .have
    mov ebp, 64
.scan:
    mov eax, [pl_scan]
    mov [pl_want], eax
    mov ecx, 16
    lea edx, [eax + 16]
    cmp edx, [pl_fsize]
    jbe .chk
    mov ecx, 8
    lea edx, [eax + 8]
    cmp edx, [pl_fsize]
    ja .noindex
.chk:
    call pl_present
    jc .wait
    mov esi, [pl_file]
    add esi, eax
    mov edx, [esi]
    bswap edx
    mov ebx, [esi + 4]
    cmp edx, 1
    jne .s0
    cmp ecx, 16
    jb .noindex
    cmp dword [esi + 8], 0
    jne .noindex
    mov edx, [esi + 12]
    bswap edx
    jmp .sz
.s0:
    test edx, edx
    jnz .sz
    mov edx, [pl_fsize]
    sub edx, eax
.sz:
    cmp edx, 8
    jb .noindex
    cmp ebx, 'moov'
    je .found
    add eax, edx
    jc .noindex
    cmp eax, [pl_fsize]
    jae .noindex
    mov [pl_scan], eax
    dec ebp
    jnz .scan
    jmp .wait
.found:
    cmp edx, PL_MAXMOOV
    ja .noindex
    mov ecx, eax
    add ecx, edx
    jc .noindex
    cmp ecx, [pl_fsize]
    ja .noindex
    mov [pl_moov_off], eax
    mov [pl_moov_len], edx
.have:
    mov eax, [pl_moov_off]
    mov [pl_want], eax
    mov ecx, [pl_moov_len]
    call pl_present
    jc .wait
    call pl_setup
.wait:
    popad
    ret
.noindex:
    mov eax, pl_e_fmt
    call pl_error
    popad
    ret

pl_setup:
    pushad
    mov ecx, MP4I_SIZE
    mov edx, OWN_MEDIA
    call big_alloc
    test eax, eax
    jz .nomem
    mov [pl_info], eax
    mov ecx, [pl_moov_len]
    imul ecx, ecx, 6
    add ecx, 1024 * 1024
    mov [pl_worklen], ecx
    mov edx, OWN_MEDIA
    call big_alloc
    test eax, eax
    jz .nomem
    mov [pl_work], eax
    mov esi, [pl_file]
    add esi, [pl_moov_off]
    CCALL mp4_parse_moov, esi, dword [pl_moov_len], dword [pl_info], dword [pl_work], dword [pl_worklen]
    cmp eax, MP4_EWORK
    jne .parsed
    mov eax, [pl_work]
    call big_free
    mov ebx, [pl_info]
    mov ecx, [ebx + MP4I_NEED]
    cmp ecx, 512 * 1024 * 1024
    ja .nomem
    mov [pl_worklen], ecx
    mov edx, OWN_MEDIA
    call big_alloc
    test eax, eax
    jz .nomem
    mov [pl_work], eax
    mov esi, [pl_file]
    add esi, [pl_moov_off]
    CCALL mp4_parse_moov, esi, dword [pl_moov_len], dword [pl_info], dword [pl_work], dword [pl_worklen]
.parsed:
    test eax, eax
    js .badfile
    mov dword [pl_moov_ok], 1
    mov ebx, [pl_info]
    cmp dword [ebx + MP4I_V_OK], 0
    je .nov
    call pl_video_init
.nov:
    cmp dword [ebx + MP4I_A_OK], 0
    je .noa
    call pl_audio_init
.noa:
    mov eax, [pl_hasv]
    or eax, [pl_hasa]
    jz .codec
    xor eax, eax
    cmp dword [pl_hasv], 0
    je .ad
    mov eax, [ebx + MP4I_V_DUR]
    mov ecx, [pl_vscale]
    call pl_ms
.ad:
    cmp dword [pl_hasa], 0
    je .dur
    push eax
    mov eax, [ebx + MP4I_A_DUR]
    mov ecx, [pl_ascale]
    call pl_ms
    pop ecx
    cmp eax, ecx
    jae .dur
    mov eax, ecx
.dur:
    mov [pl_dur_ms], eax
    mov dword [pl_msg], pl_s_buf
    xor eax, eax
    call pl_seek
    popad
    ret
.nomem:
    mov eax, pl_e_mem
    jmp .err
.badfile:
    mov eax, pl_e_fmt
    jmp .err
.codec:
    mov eax, pl_e_codec
.err:
    call pl_error
    popad
    ret

pl_video_init:
    pushad
    mov eax, [ebx + MP4I_V_W]
    mov ecx, [ebx + MP4I_V_H]
    cmp eax, 16
    jb .no
    cmp eax, PL_MAXW
    ja .no
    cmp ecx, 16
    jb .no
    cmp ecx, PL_MAXH
    ja .no
    cmp dword [ebx + MP4I_V_SCALE], 0
    je .no
    add eax, 15
    and eax, ~15
    add ecx, 15
    and ecx, ~15
    mov [pl_maxw], eax
    mov [pl_maxh], ecx
    CCALL h264_ctx_size
    mov ecx, eax
    mov edx, OWN_MEDIA
    call big_alloc
    test eax, eax
    jz .no
    mov [pl_h264], eax
    CCALL h264_mem_size, dword [pl_maxw], dword [pl_maxh]
    mov [pl_h264len], eax
    mov ecx, eax
    mov edx, OWN_MEDIA
    call big_alloc
    test eax, eax
    jz .no
    mov [pl_h264mem], eax
    CCALL h264_init, dword [pl_h264], dword [pl_h264mem], dword [pl_h264len], dword [pl_maxw], dword [pl_maxh]
    test eax, eax
    js .no
    CCALL h264_decode_avcc, dword [pl_h264], dword [ebx + MP4I_V_AVCC], dword [ebx + MP4I_V_AVCCLEN]
    cmp eax, 1
    je .ns
    cmp eax, 2
    je .ns
    cmp eax, 4
    jne .no
.ns:
    mov [pl_nalsize], eax
    mov ecx, [pl_maxw]
    imul ecx, [pl_maxh]
    shl ecx, 2
    mov edx, OWN_MEDIA
    call big_alloc
    test eax, eax
    jz .no
    mov [pl_pic], eax
    call big_alloc
    test eax, eax
    jz .no
    mov [pl_next], eax
    mov eax, [ebx + MP4I_V_SAMP]
    mov [pl_vsamp], eax
    mov eax, [ebx + MP4I_V_N]
    mov [pl_vcount], eax
    mov eax, [ebx + MP4I_V_SCALE]
    mov [pl_vscale], eax
    mov dword [pl_hasv], 1
.no:
    popad
    ret

pl_audio_init:
    pushad
    CCALL aac_ctx_size
    mov ecx, eax
    mov edx, OWN_MEDIA
    call big_alloc
    test eax, eax
    jz .no
    mov [pl_aac], eax
    CCALL aac_init, dword [pl_aac], dword [ebx + MP4I_A_ASC], dword [ebx + MP4I_A_ASCLEN]
    test eax, eax
    js .no
    CCALL aac_info, dword [pl_aac], pl_rate, pl_chans
    test eax, eax
    js .no
    mov eax, [pl_rate]
    cmp eax, 8000
    jb .no
    cmp eax, 96000
    ja .no
    mov eax, [pl_chans]
    cmp eax, 1
    jb .no
    cmp eax, 2
    ja .no
    mov eax, [ebx + MP4I_A_SAMP]
    mov [pl_asamp], eax
    mov eax, [ebx + MP4I_A_N]
    mov [pl_acount], eax
    mov eax, [ebx + MP4I_A_SCALE]
    test eax, eax
    jnz .sc
    mov eax, [pl_rate]
.sc:
    mov [pl_ascale], eax
    mov dword [pl_hasa], 1
    mov dword [pl_card], 0
    call snd_init
    jc .no
    mov dword [pl_card], 1
.no:
    popad
    ret

pl_ms:
    push ecx
    push edx
    test ecx, ecx
    jz .zero
    mov edx, 1000
    mul edx
    cmp edx, ecx
    jae .big
    div ecx
    pop edx
    pop ecx
    ret
.big:
    mov eax, -1
    pop edx
    pop ecx
    ret
.zero:
    xor eax, eax
    pop edx
    pop ecx
    ret

pl_units:
    push ecx
    push edx
    mul ecx
    mov ecx, 1000
    cmp edx, ecx
    jae .big
    div ecx
    pop edx
    pop ecx
    ret
.big:
    mov eax, -1
    pop edx
    pop ecx
    ret

pl_snd_ms:
    push ecx
    push edx
    call snd_played
    sub eax, [pl_snd_lost]
    cmp eax, [pl_awritten]
    jbe .ok
    mov edx, eax
    sub edx, [pl_awritten]
    add [pl_snd_lost], edx
    mov eax, [pl_awritten]
.ok:
    mov ecx, [pl_rate]
    call pl_ms
    pop edx
    pop ecx
    ret

pl_clock:
    cmp dword [pl_held], 0
    je .run
    mov eax, [pl_hold_ms]
    ret
.run:
    cmp dword [pl_sound], 0
    je .timer
    call pl_snd_ms
    add eax, [pl_base_ms]
    ret
.timer:
    mov eax, [ticks]
    sub eax, [pl_t0]
    imul eax, 10
    add eax, [pl_base_ms]
    ret

pl_hold:
    push eax
    cmp dword [pl_held], 0
    jne .r
    call pl_clock
    mov [pl_hold_ms], eax
    mov dword [pl_held], 1
    cmp dword [pl_sound], 0
    je .r
    call snd_pause
    mov dword [pl_snd_paused], 1
.r: pop eax
    ret

pl_unhold:
    pushad
    cmp dword [pl_held], 0
    je .done
    mov dword [pl_held], 0
    cmp dword [pl_sound], 0
    jne .resume
    mov eax, [pl_hold_ms]
    mov [pl_base_ms], eax
    mov eax, [ticks]
    mov [pl_t0], eax
    cmp dword [pl_hasa], 0
    je .done
    cmp dword [pl_card], 0
    je .done
    mov eax, [pl_rate]
    mov ecx, [pl_chans]
    call snd_open
    jc .nocard
    mov dword [pl_sound], 1
    mov dword [pl_snd_paused], 0
    mov dword [pl_awritten], 0
    mov dword [pl_snd_lost], 0
    call pl_apply_volume
    call pl_audio
    jmp .done
.nocard:
    mov dword [pl_card], 0
    jmp .done
.resume:
    cmp dword [pl_snd_paused], 0
    je .done
    call snd_resume
    mov dword [pl_snd_paused], 0
.done:
    popad
    ret

pl_apply_volume:
    push eax
    cmp dword [pl_sound], 0
    je .r
    mov eax, [pl_volume]
    cmp dword [pl_muted], 0
    je .v
    xor eax, eax
.v: call snd_volume
.r: pop eax
    ret

pl_seek:
    pushad
    cmp dword [pl_moov_ok], 0
    je .done
    mov ebp, eax
    cmp dword [pl_hasv], 0
    je .audio
    mov ecx, [pl_vscale]
    call pl_units
    CCALL mp4_find_sync, dword [pl_vsamp], dword [pl_vcount], eax
    test eax, eax
    jns .i
    xor eax, eax
.i: cmp eax, [pl_vcount]
    jb .i2
    xor eax, eax
.i2:
    mov [pl_vnext], eax
    cmp eax, [pl_vcount]
    jae .flush
    shl eax, 4
    add eax, [pl_vsamp]
    mov eax, [eax + MP4S_PTS]
    mov ecx, [pl_vscale]
    call pl_ms
    mov ebp, eax
.flush:
    CCALL h264_flush, dword [pl_h264]
    mov ebx, 64
.drain:
    CCALL h264_get_frame, dword [pl_h264], pl_frame
    cmp eax, 1
    jne .drained
    dec ebx
    jnz .drain
.drained:
    xor eax, eax
    mov [pl_vend], eax
    mov [pl_flushed], eax
    mov [pl_ptsn], eax
    mov [pl_next_ok], eax
    mov [pl_lastpts], ebp
.audio:
    cmp dword [pl_hasa], 0
    je .clock
    mov eax, ebp
    mov ecx, [pl_ascale]
    call pl_units
    mov edx, eax
    xor ebx, ebx
    mov ecx, [pl_acount]
.bs:
    cmp ebx, ecx
    jae .bsd
    lea eax, [ebx + ecx]
    shr eax, 1
    mov esi, eax
    shl esi, 4
    add esi, [pl_asamp]
    cmp [esi + MP4S_PTS], edx
    jae .hi
    lea ebx, [eax + 1]
    jmp .bs
.hi:
    mov ecx, eax
    jmp .bs
.bsd:
    mov [pl_anext], ebx
    mov eax, [pl_info]
    CCALL aac_init, dword [pl_aac], dword [eax + MP4I_A_ASC], dword [eax + MP4I_A_ASCLEN]
    cmp dword [pl_sound], 0
    je .clock
    call snd_close
    mov dword [pl_sound], 0
.clock:
    mov dword [pl_held], 1
    mov [pl_hold_ms], ebp
    mov [pl_base_ms], ebp
    mov dword [pl_state], PS_BUFFER
    mov dword [pl_msg], pl_s_buf
    mov dword [pl_ui], 1
.done:
    popad
    ret

pl_seek_by:
    pushad
    cmp dword [pl_moov_ok], 0
    je .done
    mov ebx, eax
    call pl_clock
    add eax, ebx
    jns .lo
    xor eax, eax
.lo:
    mov ecx, [pl_dur_ms]
    sub ecx, 500
    jns .h
    xor ecx, ecx
.h: cmp eax, ecx
    jbe .go
    mov eax, ecx
.go:
    call pl_seek
.done:
    popad
    ret

pl_buffered:
    pushad
    call pl_all_here
    jnc .yes
    mov ebp, [pl_hold_ms]
    add ebp, PL_AHEAD
    cmp dword [pl_hasv], 0
    je .audio
    mov ebx, [pl_vnext]
    mov edi, 300
.v: cmp ebx, [pl_vcount]
    jae .audio
    mov esi, ebx
    shl esi, 4
    add esi, [pl_vsamp]
    mov eax, [esi + MP4S_PTS]
    mov ecx, [pl_vscale]
    call pl_ms
    cmp eax, ebp
    ja .audio
    mov eax, [esi + MP4S_OFF]
    mov ecx, [esi + MP4S_SIZE]
    call pl_present
    jc .no
    inc ebx
    dec edi
    jnz .v
.audio:
    cmp dword [pl_hasa], 0
    je .yes
    mov ebx, [pl_anext]
    mov edi, 300
.a: cmp ebx, [pl_acount]
    jae .yes
    mov esi, ebx
    shl esi, 4
    add esi, [pl_asamp]
    mov eax, [esi + MP4S_PTS]
    mov ecx, [pl_ascale]
    call pl_ms
    cmp eax, ebp
    ja .yes
    mov eax, [esi + MP4S_OFF]
    mov ecx, [esi + MP4S_SIZE]
    call pl_present
    jc .no
    inc ebx
    dec edi
    jnz .a
.yes:
    popad
    clc
    ret
.no:
    popad
    stc
    ret

pl_starve:
    call pl_hold
    mov dword [pl_state], PS_BUFFER
    mov dword [pl_msg], pl_s_buf
    mov dword [pl_ui], 1
    ret

pl_queued:
    push edx
    call snd_played
    sub eax, [pl_snd_lost]
    mov edx, [pl_awritten]
    sub edx, eax
    jns .r
    xor edx, edx
.r: mov eax, edx
    pop edx
    ret

pl_audio:
    pushad
    cmp dword [pl_sound], 0
    je .done
    mov ebp, 16
.l: mov eax, [pl_rate]
    imul eax, PL_QUEUE
    xor edx, edx
    mov ecx, 1000
    div ecx
    mov ebx, eax
    call pl_queued
    cmp eax, ebx
    jae .done
    call snd_space
    cmp eax, 1024
    jb .done
    mov ebx, [pl_anext]
    cmp ebx, [pl_acount]
    jae .done
    shl ebx, 4
    add ebx, [pl_asamp]
    mov eax, [ebx + MP4S_OFF]
    mov ecx, [ebx + MP4S_SIZE]
    call pl_present
    jc .missing
    mov esi, [pl_file]
    add esi, eax
    CCALL aac_decode, dword [pl_aac], esi, ecx, pl_pcm
    test eax, eax
    jg .got
    mov edi, pl_pcm
    mov ecx, 1024
    imul ecx, [pl_chans]
    shr ecx, 1
    xor eax, eax
    rep stosd
    mov eax, 1024
.got:
    cmp eax, 1024 * 4
    jbe .w
    mov eax, 1024
.w: mov ecx, eax
    mov esi, pl_pcm
    call snd_write
    add [pl_awritten], eax
    inc dword [pl_anext]
    dec ebp
    jnz .l
    jmp .done
.missing:
    call pl_queued
    mov ecx, [pl_rate]
    shr ecx, 3
    cmp eax, ecx
    jae .done
    call pl_starve
.done:
    popad
    ret

pl_video:
    pushad
    mov dword [pl_vbusy], 0
    cmp dword [pl_hasv], 0
    je .done
    call pl_clock
    mov ebp, eax
    cmp dword [pl_next_ok], 0
    je .decode
    mov eax, [pl_next_ms]
    cmp eax, ebp
    jg .done
    mov eax, [pl_pic]
    xchg eax, [pl_next]
    mov [pl_pic], eax
    mov eax, [pl_nw]
    mov [pl_vw], eax
    mov eax, [pl_nh]
    mov [pl_vh], eax
    mov dword [pl_pic_ok], 1
    mov dword [pl_next_ok], 0
    mov dword [pl_newpic], 1
    mov eax, [ticks]
    mov [pl_shown_t], eax
.decode:
    cmp dword [pl_state], PS_PLAY
    jne .dec
    mov ebx, [pl_vnext]
    cmp ebx, [pl_vcount]
    jae .dec
    shl ebx, 4
    add ebx, [pl_vsamp]
    mov eax, [ebx + MP4S_PTS]
    mov ecx, [pl_vscale]
    call pl_ms
    add eax, PL_BEHIND
    cmp eax, ebp
    jge .dec
    call pl_skip_to_key
.dec:
    call pl_decode_pic
.done:
    popad
    ret

pl_skip_to_key:
    pushad
    mov ebx, [pl_vnext]
.l: inc ebx
    cmp ebx, [pl_vcount]
    jae .done
    mov esi, ebx
    shl esi, 4
    add esi, [pl_vsamp]
    test dword [esi + MP4S_FLAGS], 1
    jz .l
    mov eax, [esi + MP4S_PTS]
    mov ecx, [pl_vscale]
    call pl_ms
    cmp eax, ebp
    jl .l
    mov [pl_vnext], ebx
    mov [pl_lastpts], eax
    CCALL h264_flush, dword [pl_h264]
    mov ebx, 64
.drain:
    CCALL h264_get_frame, dword [pl_h264], pl_frame
    cmp eax, 1
    jne .drained
    dec ebx
    jnz .drain
.drained:
    mov dword [pl_ptsn], 0
    mov dword [pl_flushed], 0
.done:
    popad
    ret

pl_decode_pic:
    pushad
    mov edi, 1
.try:
    CCALL h264_get_frame, dword [pl_h264], pl_frame
    cmp eax, 1
    je .frame
    mov ebx, [pl_vnext]
    cmp ebx, [pl_vcount]
    jae .eos
    shl ebx, 4
    add ebx, [pl_vsamp]
    mov eax, [ebx + MP4S_OFF]
    mov ecx, [ebx + MP4S_SIZE]
    call pl_present
    jc .missing
    call pl_feed
    mov eax, [ebx + MP4S_PTS]
    mov ecx, [pl_vscale]
    call pl_ms
    call pl_pts_push
    inc dword [pl_vnext]
    mov dword [pl_vbusy], 1
    dec edi
    jnz .try
    jmp .done
.eos:
    cmp dword [pl_flushed], 0
    jne .ended
    mov dword [pl_flushed], 1
    CCALL h264_flush, dword [pl_h264]
    jmp .try
.ended:
    mov dword [pl_vend], 1
    jmp .done
.missing:
    cmp dword [pl_state], PS_PLAY
    jne .done
    call pl_starve
    jmp .done
.frame:
    call pl_pts_pop
    lea ecx, [eax + PL_LATE]
    cmp ecx, ebp
    jge .conv
    cmp dword [pl_pic_ok], 0
    je .conv
    cmp dword [pl_state], PS_PLAY
    jne .conv
    mov ecx, [ticks]
    sub ecx, [pl_shown_t]
    cmp ecx, 50
    jae .conv
    inc dword [pl_dropped]
    mov dword [pl_vbusy], 1
    dec edi
    jnz .try
    jmp .done
.conv:
    mov [pl_next_ms], eax
    call pl_convert
    mov dword [pl_next_ok], 1
    mov dword [pl_vbusy], 1
.done:
    popad
    ret

pl_feed:
    pushad
    mov esi, [pl_file]
    add esi, eax
    lea edi, [esi + ecx]
.n: mov ecx, [pl_nalsize]
    mov eax, edi
    sub eax, esi
    cmp eax, ecx
    jb .done
    xor ebx, ebx
.b: shl ebx, 8
    mov bl, [esi]
    inc esi
    loop .b
    mov eax, edi
    sub eax, esi
    cmp ebx, eax
    ja .done
    test ebx, ebx
    jz .n
    CCALL h264_decode_nal, dword [pl_h264], esi, ebx
    add esi, ebx
    jmp .n
.done:
    popad
    ret

pl_pts_push:
    push ecx
    mov ecx, [pl_ptsn]
    cmp ecx, PL_PTSQ
    jb .put
    push esi
    push edi
    mov esi, pl_ptsq + 4
    mov edi, pl_ptsq
    mov ecx, PL_PTSQ - 1
    rep movsd
    pop edi
    pop esi
    mov ecx, PL_PTSQ - 1
    mov [pl_ptsn], ecx
.put:
    mov [pl_ptsq + ecx * 4], eax
    inc dword [pl_ptsn]
    pop ecx
    ret

pl_pts_pop:
    push ebx
    push ecx
    push edx
    mov ecx, [pl_ptsn]
    test ecx, ecx
    jz .none
    xor ebx, ebx
    xor eax, eax
.l: inc eax
    cmp eax, ecx
    jae .got
    mov edx, [pl_ptsq + eax * 4]
    cmp edx, [pl_ptsq + ebx * 4]
    jae .l
    mov ebx, eax
    jmp .l
.got:
    mov eax, [pl_ptsq + ebx * 4]
    push eax
    dec ecx
    mov [pl_ptsn], ecx
.sh:
    cmp ebx, ecx
    jae .shd
    mov eax, [pl_ptsq + ebx * 4 + 4]
    mov [pl_ptsq + ebx * 4], eax
    inc ebx
    jmp .sh
.shd:
    pop eax
    mov [pl_lastpts], eax
    pop edx
    pop ecx
    pop ebx
    ret
.none:
    mov eax, [pl_lastpts]
    add eax, 33
    mov [pl_lastpts], eax
    pop edx
    pop ecx
    pop ebx
    ret

pl_tables:
    pushad
    cmp dword [pl_tabs_ok], 0
    jne .done
    xor ecx, ecx
.t: lea eax, [ecx - 16]
    imul eax, 1192
    add eax, 512
    mov [pl_ty + ecx * 4], eax
    lea eax, [ecx - 128]
    imul edx, eax, 1634
    mov [pl_trv + ecx * 4], edx
    imul edx, eax, 401
    mov [pl_tgu + ecx * 4], edx
    imul edx, eax, 833
    mov [pl_tgv + ecx * 4], edx
    imul edx, eax, 2066
    mov [pl_tbu + ecx * 4], edx
    inc ecx
    cmp ecx, 256
    jb .t
    xor ecx, ecx
.c: lea eax, [ecx - 384]
    test eax, eax
    jns .c1
    xor eax, eax
.c1:
    cmp eax, 255
    jbe .c2
    mov eax, 255
.c2:
    mov [pl_clamp + ecx], al
    inc ecx
    cmp ecx, 1024
    jb .c
    mov dword [pl_tabs_ok], 1
.done:
    popad
    ret

pl_convert:
    pushad
    call pl_tables
    mov eax, [pl_frame + H264F_W]
    cmp eax, [pl_maxw]
    jbe .w
    mov eax, [pl_maxw]
.w: mov [pl_nw], eax
    mov eax, [pl_frame + H264F_H]
    cmp eax, [pl_maxh]
    jbe .h
    mov eax, [pl_maxh]
.h: mov [pl_nh], eax
    mov dword [cv_row], 0
.row:
    mov eax, [cv_row]
    cmp eax, [pl_nh]
    jae .done
    mov esi, eax
    imul esi, [pl_frame + H264F_YS]
    add esi, [pl_frame + H264F_Y]
    mov ebx, eax
    shr ebx, 1
    imul ebx, [pl_frame + H264F_CS]
    mov ecx, ebx
    add ebx, [pl_frame + H264F_U]
    add ecx, [pl_frame + H264F_V]
    mov [cv_u], ebx
    mov [cv_v], ecx
    mov edi, eax
    imul edi, [pl_maxw]
    shl edi, 2
    add edi, [pl_next]
    mov eax, [pl_nw]
    inc eax
    shr eax, 1
    mov [cv_n], eax
.pair:
    mov ebx, [cv_u]
    movzx eax, byte [ebx]
    inc dword [cv_u]
    mov ebx, [cv_v]
    movzx ecx, byte [ebx]
    inc dword [cv_v]
    mov edx, [pl_tgu + eax * 4]
    add edx, [pl_tgv + ecx * 4]
    mov [cv_guv], edx
    mov edx, [pl_tbu + eax * 4]
    mov ecx, [pl_trv + ecx * 4]
%rep 2
    movzx ebx, byte [esi]
    mov ebx, [pl_ty + ebx * 4]
    mov [cv_tmp], ebx
    lea ebp, [ebx + ecx]
    sar ebp, 10
    movzx ebp, byte [pl_clamp + 384 + ebp]
    shl ebp, 16
    sub ebx, [cv_guv]
    sar ebx, 10
    movzx ebx, byte [pl_clamp + 384 + ebx]
    shl ebx, 8
    or ebp, ebx
    mov ebx, [cv_tmp]
    add ebx, edx
    sar ebx, 10
    movzx ebx, byte [pl_clamp + 384 + ebx]
    or ebp, ebx
    mov [edi], ebp
    inc esi
    add edi, 4
%endrep
    dec dword [cv_n]
    jnz .pair
    inc dword [cv_row]
    jmp .row
.done:
    popad
    ret

pl_ended:
    push eax
    cmp dword [pl_hasv], 0
    je .a
    cmp dword [pl_vend], 0
    je .no
    cmp dword [pl_next_ok], 0
    jne .no
.a: cmp dword [pl_hasa], 0
    je .yes
    cmp dword [pl_sound], 0
    jne .snd
    cmp dword [pl_hasv], 0
    jne .yes
    call pl_clock
    cmp eax, [pl_dur_ms]
    jb .no
    jmp .yes
.snd:
    mov eax, [pl_anext]
    cmp eax, [pl_acount]
    jb .no
    call pl_queued
    test eax, eax
    jnz .no
.yes:
    pop eax
    clc
    ret
.no:
    pop eax
    stc
    ret

pl_tick:
    pushad
    mov edi, [pl_autostart]
    test edi, edi
    jz .noauto
    call imgc_waiting
    test eax, eax
    jnz .noauto
    mov dword [pl_autostart], 0
    call pl_start
.noauto:
    cmp dword [pl_rec], 0
    je .done
    call pl_mouse
    mov eax, [pl_state]
    cmp eax, PS_ERROR
    je .show
    cmp eax, PS_IDLE
    je .show
    call pl_download
    mov eax, [pl_state]
    cmp eax, PS_LOADING
    jne .loaded
    call pl_find_index
    jmp .show
.loaded:
    cmp eax, PS_BUFFER
    jne .playing
    call pl_buffered
    jc .show
    mov dword [pl_state], PS_PAUSE
    mov dword [pl_ui], 1
    cmp dword [pl_pause_req], 0
    jne .show
    mov dword [pl_state], PS_PLAY
    call pl_unhold
    jmp .show
.playing:
    cmp eax, PS_PAUSE
    jne .play
    call pl_video
    jmp .show
.play:
    cmp eax, PS_PLAY
    jne .show
    mov ebx, [ticks]
.work:
    call pl_audio
    call pl_video
    cmp dword [pl_state], PS_PLAY
    jne .show
    cmp dword [pl_vbusy], 0
    je .idle
    mov eax, [ticks]
    sub eax, ebx
    cmp eax, PL_SLICE
    jb .work
.idle:
    call pl_ended
    jc .show
    call pl_hold
    cmp dword [pl_sound], 0
    je .end
    call snd_close
    mov dword [pl_sound], 0
.end:
    mov dword [pl_state], PS_END
    mov dword [pl_ui], 1
.show:
    call pl_bar_check
    call pl_show
.done:
    popad
    ret

pl_mouse:
    pushad
    mov eax, [mouse_x]
    mov edx, [mouse_y]
    cmp eax, [pl_mx]
    jne .moved
    cmp edx, [pl_my]
    je .done
.moved:
    mov [pl_mx], eax
    mov [pl_my], edx
    cmp dword [pl_full], 0
    jne .over
    mov edi, [pl_rec]
    cmp dword [edi + VR_W], 0
    je .done
    sub eax, [edi + VR_X]
    jl .done
    cmp eax, [edi + VR_W]
    jge .done
    sub edx, [edi + VR_Y]
    jl .done
    cmp edx, [edi + VR_H]
    jge .done
.over:
    mov eax, [ticks]
    mov [pl_lastmove], eax
    cmp dword [pl_bar_up], 0
    jne .done
    mov dword [pl_ui], 1
.done:
    popad
    ret

pl_bar_check:
    pushad
    cmp dword [pl_bar_up], 0
    je .done
    call pl_bar_wanted
    jc .redraw
    call pl_clock
    xor edx, edx
    mov ecx, 1000
    div ecx
    cmp eax, [pl_lastsec]
    jne .redraw
    cmp dword [pl_dl_new], 0
    je .done
    mov eax, [ticks]
    sub eax, [pl_dl_t]
    cmp eax, 50
    jb .done
.redraw:
    mov dword [pl_ui], 1
.done:
    popad
    ret

pl_bar_wanted:
    push eax
    mov eax, [pl_rec]
    test eax, eax
    jz .no
    cmp dword [eax + VR_AUDIO], 0
    jne .yes
    cmp dword [pl_state], PS_PLAY
    jne .yes
    mov eax, [ticks]
    sub eax, [pl_lastmove]
    cmp eax, PL_BARTIME
    jae .no
.yes:
    pop eax
    clc
    ret
.no:
    pop eax
    stc
    ret

pl_show:
    pushad
    mov eax, [pl_newpic]
    or eax, [pl_ui]
    jz .done
    cmp byte [gui_dirty], 0
    jne .clear
    cmp dword [pl_full], 0
    jne .all
    cmp dword [cur_app], APP_BROWSER
    jne .later
    mov ecx, [z_n]
    test ecx, ecx
    jz .later
    cmp dword [z_list + ecx * 4 - 4], APP_BROWSER
    jne .later
    mov edi, [pl_rec]
    cmp dword [edi + VR_W], 0
    je .clear
    call pl_draw_in_page
    jmp .clear
.later:
    mov eax, [ticks]
    sub eax, [pl_redraw_t]
    cmp eax, 20
    jb .done
.all:
    mov eax, [ticks]
    mov [pl_redraw_t], eax
    or byte [gui_dirty], 1
.clear:
    mov dword [pl_newpic], 0
    mov dword [pl_ui], 0
.done:
    popad
    ret

pl_draw_in_page:
    pushad
    call cur_rect
    mov ebx, cur_under
    mov eax, 1
    call gfx_copy_rect
    mov ecx, [br_vx]
    mov edx, [br_vy]
    mov esi, [br_vw]
    mov edi, [br_vh]
    call gfx_clip_set
    mov edi, [pl_rec]
    call vd_from_rec
    call vid_draw
    mov ecx, [gfx_cx0]
    mov edx, [gfx_cy0]
    mov esi, [gfx_cx1]
    mov edi, [gfx_cy1]
    mov eax, [vd_x]
    cmp ecx, eax
    jge .x0
    mov ecx, eax
.x0:
    add eax, [vd_w]
    cmp esi, eax
    jle .x1
    mov esi, eax
.x1:
    mov eax, [vd_y]
    cmp edx, eax
    jge .y0
    mov edx, eax
.y0:
    add eax, [vd_h]
    cmp edi, eax
    jle .y1
    mov edi, eax
.y1:
    sub esi, ecx
    sub edi, edx
    call gfx_clip_full
    call gui_cursor_show
    test esi, esi
    jle .cur
    test edi, edi
    jle .cur
    call gfx_present_rect
.cur:
    call cur_rect
    call gfx_present_rect
    popad
    ret

vd_from_rec:
    push eax
    mov [vd_rec], edi
    mov eax, [edi + VR_X]
    mov [vd_x], eax
    mov eax, [edi + VR_Y]
    mov [vd_y], eax
    mov eax, [edi + VR_W]
    mov [vd_w], eax
    mov eax, [edi + VR_H]
    mov [vd_h], eax
    pop eax
    ret

vid_paint:
    pushad
    mov edi, [esi + DI_TEXT]
    mov [edi + VR_X], ecx
    mov [edi + VR_Y], edx
    movzx eax, word [esi + DI_W]
    mov [edi + VR_W], eax
    movzx eax, word [esi + DI_H]
    mov [edi + VR_H], eax
    call vd_from_rec
    call vid_draw
    popad
    ret

pl_full_draw:
    pushad
    call gfx_clip_full
    mov eax, [pl_rec]
    mov [vd_rec], eax
    xor eax, eax
    mov [vd_x], eax
    mov [vd_y], eax
    mov eax, [gfx_w]
    mov [vd_w], eax
    mov eax, [gfx_h]
    mov [vd_h], eax
    call vid_draw
    popad
    ret

vid_draw:
    pushad
    RECT [vd_x], [vd_y], [vd_w], [vd_h], 0x000000
    mov eax, [vd_w]
    shr eax, 1
    add eax, [vd_x]
    mov [vd_cx], eax
    mov eax, [vd_h]
    shr eax, 1
    add eax, [vd_y]
    mov [vd_cy], eax
    mov edi, [vd_rec]
    mov dword [vd_st], PS_IDLE
    cmp edi, [pl_rec]
    jne .poster
    mov eax, [pl_state]
    mov [vd_st], eax
    cmp dword [pl_pic_ok], 0
    je .poster
    mov eax, [pl_pic]
    mov ebx, [pl_vw]
    mov ecx, [pl_vh]
    mov edx, [pl_maxw]
    call vd_picture
    jmp .over
.poster:
    mov ebx, [edi + VR_POSTER]
    test ebx, ebx
    jz .over
    cmp dword [ebx + IR_STATE], IS_OK
    jne .over
    mov eax, [ebx + IR_PIX]
    mov ecx, [ebx + IR_H]
    mov ebx, [ebx + IR_W]
    mov edx, ebx
    call vd_picture
.over:
    mov eax, [vd_st]
    cmp eax, PS_LOADING
    je .msg
    cmp eax, PS_BUFFER
    je .msg
    cmp eax, PS_ERROR
    je .msg
    cmp eax, PS_PLAY
    je .bar
    cmp dword [edi + VR_AUDIO], 0
    jne .bar
    call vd_play_button
    jmp .bar
.msg:
    mov esi, [pl_msg]
    call vd_message
.bar:
    mov dword [vd_run], 0
    cmp edi, [pl_rec]
    jne .idlebar
    call pl_bar_wanted
    jc .done
    mov dword [pl_bar_up], 1
    call vd_bar
    jmp .done
.idlebar:
    cmp dword [edi + VR_AUDIO], 0
    je .done
    call vd_bar
.done:
    cmp edi, [pl_rec]
    jne .r
    cmp dword [vd_run], 0
    jne .r
    mov dword [pl_bar_up], 0
.r: popad
    ret

vd_picture:
    pushad
    test ebx, ebx
    jz .done
    test ecx, ecx
    jz .done
    mov [gb_src], eax
    mov [gb_sw], ebx
    mov [gb_sh], ecx
    mov [gb_sstride], edx
    mov eax, ebx
    mul dword [vd_h]
    mov esi, eax
    mov eax, ecx
    mul dword [vd_w]
    cmp esi, eax
    jb .tall
    mov eax, [vd_w]
    mov [gb_w], eax
    mov eax, ecx
    mul dword [vd_w]
    div ebx
    mov [gb_h], eax
    jmp .place
.tall:
    mov eax, [vd_h]
    mov [gb_h], eax
    mov eax, ebx
    mul dword [vd_h]
    div ecx
    mov [gb_w], eax
.place:
    mov eax, [vd_w]
    sub eax, [gb_w]
    sar eax, 1
    add eax, [vd_x]
    mov [gb_x], eax
    mov eax, [vd_h]
    sub eax, [gb_h]
    sar eax, 1
    add eax, [vd_y]
    mov [gb_y], eax
    call gfx_blit
.done:
    popad
    ret

vd_play_button:
    pushad
    cmp dword [vd_h], 80
    jl .done
    mov ecx, [vd_cx]
    sub ecx, 34
    mov edx, [vd_cy]
    sub edx, 23
    push ecx
    push edx
    add ecx, 2
    RECT ecx, edx, 64, 46, 0x212121
    pop edx
    pop ecx
    inc edx
    push ecx
    push edx
    inc ecx
    RECT ecx, edx, 66, 44, 0x212121
    pop edx
    pop ecx
    add edx, 1
    RECT ecx, edx, 68, 42, 0x212121
    mov eax, [vd_cx]
    sub eax, 8
    mov [tri_px + 0], eax
    mov [tri_px + 4], eax
    add eax, 22
    mov [tri_px + 8], eax
    mov eax, [vd_cy]
    sub eax, 12
    mov [tri_py + 0], eax
    add eax, 24
    mov [tri_py + 4], eax
    sub eax, 12
    mov [tri_py + 8], eax
    mov eax, 0xFFFFFF
    call gfx_rgb
    call gfx_tri
.done:
    popad
    ret

vd_message:
    pushad
    test esi, esi
    jz .done
    call str_len
    shl ecx, 3
    mov ebx, ecx
    mov ecx, [vd_cx]
    mov eax, ebx
    shr eax, 1
    sub ecx, eax
    sub ecx, 10
    mov edx, [vd_cy]
    sub edx, 16
    push esi
    lea esi, [ebx + 20]
    push ecx
    push edx
    RECT ecx, edx, esi, 32, 0x212121
    pop edx
    pop ecx
    pop esi
    add ecx, 10
    add edx, 8
    TEXT ecx, edx, esi, 0xFFFFFF, -1
.done:
    popad
    ret

vd_geom:
    pushad
    mov eax, [vd_y]
    add eax, [vd_h]
    sub eax, CB_H
    mov [vd_by], eax
    mov eax, [vd_x]
    add eax, 40
    mov [vd_tx], eax
    mov eax, [vd_x]
    add eax, [vd_w]
    mov edi, [vd_rec]
    cmp dword [edi + VR_AUDIO], 0
    jne .nf
    sub eax, 34
.nf:
    mov [vd_fx0], eax
    sub eax, 8
    mov [vd_vx1], eax
    sub eax, 72
    mov [vd_vx0], eax
    call pl_time_text
    shl ecx, 3
    add ecx, [vd_tx]
    add ecx, 12
    mov [vd_gx0], ecx
    mov eax, [vd_vx0]
    sub eax, 12
    mov [vd_gx1], eax
    sub eax, ecx
    cmp eax, 40
    jge .done
    mov eax, [vd_fx0]
    mov [vd_vx0], eax
    mov [vd_vx1], eax
    sub eax, 12
    mov [vd_gx1], eax
    sub eax, ecx
    cmp eax, 40
    jge .done
    mov eax, [vd_tx]
    mov [vd_gx0], eax
.done:
    popad
    ret

pl_time_text:
    push eax
    push esi
    push edi
    mov edi, vd_time
    xor eax, eax
    mov ecx, [vd_rec]
    cmp ecx, [pl_rec]
    jne .t
    call pl_clock
.t: call pl_time_fmt
    mov dword [edi], ' / '
    add edi, 3
    mov eax, [pl_dur_ms]
    mov ecx, [vd_rec]
    cmp ecx, [pl_rec]
    je .d
    xor eax, eax
.d: call pl_time_fmt
    mov byte [edi], 0
    mov esi, vd_time
    call str_len
    pop edi
    pop esi
    pop eax
    ret

pl_time_fmt:
    push eax
    push ebx
    push edx
    xor edx, edx
    mov ebx, 1000
    div ebx
    xor edx, edx
    mov ebx, 3600
    div ebx
    test eax, eax
    jz .m
    call ly_pool_num
    mov byte [edi], ':'
    inc edi
    mov eax, edx
    xor edx, edx
    mov ebx, 60
    div ebx
    call .two
    jmp .s
.m: mov eax, edx
    xor edx, edx
    mov ebx, 60
    div ebx
    call ly_pool_num
.s: mov byte [edi], ':'
    inc edi
    mov eax, edx
    call .two
    pop edx
    pop ebx
    pop eax
    ret
.two:
    push edx
    xor edx, edx
    mov ebx, 10
    div ebx
    add al, '0'
    add dl, '0'
    mov [edi], al
    mov [edi + 1], dl
    add edi, 2
    pop edx
    ret

vd_bar:
    pushad
    mov dword [vd_run], 1
    call vd_geom
    call pl_clock
    xor edx, edx
    mov ecx, 1000
    div ecx
    mov [pl_lastsec], eax
    mov eax, [ticks]
    mov [pl_dl_t], eax
    mov dword [pl_dl_new], 0
    RECT [vd_x], [vd_by], [vd_w], CB_H, 0x161616

    cmp dword [vd_st], PS_PLAY
    jne .tri
    mov ecx, [vd_x]
    add ecx, 12
    mov edx, [vd_by]
    add edx, 10
    push ecx
    RECT ecx, edx, 4, 14, 0xFFFFFF
    pop ecx
    add ecx, 8
    mov edx, [vd_by]
    add edx, 10
    RECT ecx, edx, 4, 14, 0xFFFFFF
    jmp .time
.tri:
    mov eax, [vd_x]
    add eax, 12
    mov [tri_px + 0], eax
    mov [tri_px + 4], eax
    add eax, 13
    mov [tri_px + 8], eax
    mov eax, [vd_by]
    add eax, 9
    mov [tri_py + 0], eax
    add eax, 16
    mov [tri_py + 4], eax
    sub eax, 8
    mov [tri_py + 8], eax
    mov eax, 0xFFFFFF
    call gfx_rgb
    call gfx_tri
.time:
    mov eax, [vd_gx0]
    cmp eax, [vd_tx]
    je .prog
    mov edx, [vd_by]
    add edx, 9
    TEXT [vd_tx], edx, vd_time, 0xFFFFFF, -1
.prog:
    mov esi, [vd_gx1]
    sub esi, [vd_gx0]
    jle .vol
    mov edx, [vd_by]
    add edx, 15
    RECT [vd_gx0], edx, esi, 4, 0x4A4A4A
    call vd_downloaded
    mov edi, [vd_rec]
    cmp edi, [pl_rec]
    jne .vol
    mov ecx, [pl_dur_ms]
    test ecx, ecx
    jz .vol
    call pl_clock
    cmp eax, ecx
    jbe .pl
    mov eax, ecx
.pl:
    mov esi, [vd_gx1]
    sub esi, [vd_gx0]
    mul esi
    div ecx
    mov ebx, eax
    mov edx, [vd_by]
    add edx, 15
    RECT [vd_gx0], edx, ebx, 4, C_PLAYED
    mov ecx, [vd_gx0]
    add ecx, ebx
    sub ecx, 5
    mov edx, [vd_by]
    add edx, 11
    RECT ecx, edx, 10, 12, C_PLAYED
.vol:
    mov ecx, [vd_vx0]
    cmp ecx, [vd_vx1]
    je .full
    mov edx, [vd_by]
    add edx, 13
    RECT ecx, edx, 4, 8, 0xFFFFFF
    mov eax, [vd_vx0]
    add eax, 3
    mov [tri_px + 0], eax
    add eax, 8
    mov [tri_px + 4], eax
    mov [tri_px + 8], eax
    mov eax, [vd_by]
    add eax, 17
    mov [tri_py + 0], eax
    sub eax, 8
    mov [tri_py + 4], eax
    add eax, 16
    mov [tri_py + 8], eax
    mov eax, 0xFFFFFF
    call gfx_rgb
    call gfx_tri
    mov ecx, [vd_vx0]
    add ecx, 18
    mov edx, [vd_by]
    add edx, 15
    push ecx
    RECT ecx, edx, 50, 4, 0x4A4A4A
    pop ecx
    mov esi, [pl_volume]
    shr esi, 1
    mov eax, 0xFFFFFF
    cmp dword [pl_muted], 0
    je .lv
    mov eax, 0x777777
.lv:
    mov edx, [vd_by]
    add edx, 15
    mov edi, 4
    call gfx_rgb
    call gfx_fillrect
    cmp dword [pl_muted], 0
    je .full
    mov ecx, [vd_vx0]
    mov edx, [vd_by]
    add edx, 16
    RECT ecx, edx, 14, 2, 0xFF5252
.full:
    mov edi, [vd_rec]
    cmp dword [edi + VR_AUDIO], 0
    jne .done
    mov ecx, [vd_fx0]
    add ecx, 7
    mov edx, [vd_by]
    add edx, 9
    call .corners
.done:
    popad
    ret
.corners:
    pushad
    mov ebx, ecx
    mov ebp, edx
    RECT ebx, ebp, 6, 2, 0xFFFFFF
    RECT ebx, ebp, 2, 6, 0xFFFFFF
    lea ecx, [ebx + 14]
    RECT ecx, ebp, 6, 2, 0xFFFFFF
    lea ecx, [ebx + 18]
    RECT ecx, ebp, 2, 6, 0xFFFFFF
    lea edx, [ebp + 14]
    RECT ebx, edx, 6, 2, 0xFFFFFF
    lea edx, [ebp + 10]
    RECT ebx, edx, 2, 6, 0xFFFFFF
    lea ecx, [ebx + 14]
    lea edx, [ebp + 14]
    RECT ecx, edx, 6, 2, 0xFFFFFF
    lea ecx, [ebx + 18]
    lea edx, [ebp + 10]
    RECT ecx, edx, 2, 6, 0xFFFFFF
    popad
    ret

vd_downloaded:
    pushad
    mov edi, [vd_rec]
    cmp edi, [pl_rec]
    jne .done
    cmp dword [pl_file], 0
    je .done
    mov ebp, [vd_gx1]
    sub ebp, [vd_gx0]
    jle .done
    xor ebx, ebx
    mov dword [vd_run], -1
.col:
    cmp ebx, ebp
    jae .flush
    mov eax, ebx
    mul dword [pl_fsize]
    div ebp
    shr eax, 16
    bt [pl_bits], eax
    jnc .gap
    cmp dword [vd_run], -1
    jne .n
    mov [vd_run], ebx
    jmp .n
.gap:
    call .draw
.n: inc ebx
    jmp .col
.flush:
    call .draw
.done:
    mov dword [vd_run], 1
    popad
    ret
.draw:
    cmp dword [vd_run], -1
    je .dr
    pushad
    mov ecx, [vd_run]
    mov esi, ebx
    sub esi, ecx
    add ecx, [vd_gx0]
    mov edx, [vd_by]
    add edx, 15
    RECT ecx, edx, esi, 4, 0x9A9A9A
    popad
    mov dword [vd_run], -1
.dr:
    ret

vid_click:
    pushad
    mov eax, [ticks]
    mov [pl_lastmove], eax
    mov dword [pl_ui], 1
    cmp edi, [pl_rec]
    jne .start
    mov eax, [pl_state]
    cmp eax, PS_IDLE
    je .start
    cmp eax, PS_ERROR
    je .start
    cmp eax, PS_LOADING
    je .done
    call pl_bar_wanted
    jc .picture
    call vd_geom
    mov eax, [mouse_y]
    cmp eax, [vd_by]
    jl .picture
    mov eax, [mouse_x]
    cmp eax, [vd_tx]
    jl .toggle
    cmp eax, [vd_gx0]
    jl .done
    cmp eax, [vd_gx1]
    jl .seekbar
    cmp eax, [vd_vx0]
    jl .done
    cmp eax, [vd_vx1]
    jl .volume
    cmp eax, [vd_fx0]
    jl .done
    mov edi, [vd_rec]
    cmp dword [edi + VR_AUDIO], 0
    jne .done
    call pl_toggle_full
    jmp .done
.seekbar:
    sub eax, [vd_gx0]
    mul dword [pl_dur_ms]
    mov ecx, [vd_gx1]
    sub ecx, [vd_gx0]
    div ecx
    call pl_seek
    jmp .done
.volume:
    sub eax, [vd_vx0]
    cmp eax, 16
    jae .level
    xor dword [pl_muted], 1
    call pl_apply_volume
    jmp .done
.level:
    sub eax, 18
    jns .l1
    xor eax, eax
.l1:
    shl eax, 1
    cmp eax, 100
    jbe .l2
    mov eax, 100
.l2:
    mov [pl_volume], eax
    mov dword [pl_muted], 0
    call pl_apply_volume
    jmp .done
.picture:
.toggle:
    call pl_toggle_pause
    jmp .done
.start:
    call pl_start
.done:
    popad
    ret

pl_toggle_pause:
    pushad
    mov dword [pl_ui], 1
    mov eax, [pl_state]
    cmp eax, PS_PLAY
    je .pause
    cmp eax, PS_PAUSE
    je .play
    cmp eax, PS_END
    je .again
    cmp eax, PS_BUFFER
    jne .done
    xor dword [pl_pause_req], 1
    jmp .done
.pause:
    call pl_hold
    mov dword [pl_state], PS_PAUSE
    mov dword [pl_pause_req], 1
    jmp .done
.play:
    mov dword [pl_pause_req], 0
    mov dword [pl_state], PS_PLAY
    call pl_unhold
    jmp .done
.again:
    mov dword [pl_pause_req], 0
    xor eax, eax
    call pl_seek
.done:
    popad
    ret

pl_toggle_full:
    xor dword [pl_full], 1
    or byte [gui_dirty], 1
    push eax
    mov eax, [ticks]
    mov [pl_lastmove], eax
    pop eax
    ret

pl_full_click:
    pushad
    call pl_full_box
    mov edi, [pl_rec]
    call vid_click
    or byte [gui_dirty], 1
    popad
    ret

pl_full_box:
    push eax
    mov eax, [pl_rec]
    mov [vd_rec], eax
    xor eax, eax
    mov [vd_x], eax
    mov [vd_y], eax
    mov eax, [gfx_w]
    mov [vd_w], eax
    mov eax, [gfx_h]
    mov [vd_h], eax
    pop eax
    ret

pl_page_key:
    cmp dword [pl_rec], 0
    je .no
    push eax
    or eax, 0x20
    cmp eax, 'k'
    je .k
    cmp eax, 'j'
    je .j
    cmp eax, 'l'
    je .l
    cmp eax, 'f'
    je .f
    cmp eax, 'm'
    je .m
    pop eax
.no:
    stc
    ret
.k: call pl_toggle_pause
    jmp .yes
.j: mov eax, -10000
    call pl_seek_by
    jmp .yes
.l: mov eax, 10000
    call pl_seek_by
    jmp .yes
.f: mov eax, [pl_rec]
    cmp dword [eax + VR_AUDIO], 0
    jne .yes
    call pl_toggle_full
    jmp .yes
.m: xor dword [pl_muted], 1
    call pl_apply_volume
.yes:
    mov dword [pl_ui], 1
    pop eax
    clc
    ret

pl_full_key:
    pushad
    mov dword [pl_ui], 1
    mov ebx, [ticks]
    mov [pl_lastmove], ebx
    cmp eax, 27
    je .leave
    cmp eax, ' '
    je .pause
    cmp eax, KEY_LEFT
    je .back5
    cmp eax, KEY_RIGHT
    je .fwd5
    cmp eax, KEY_UP
    je .louder
    cmp eax, KEY_DOWN
    je .softer
    call pl_page_key
    jmp .done
.leave:
    mov dword [pl_full], 0
    or byte [gui_dirty], 1
    jmp .done
.pause:
    call pl_toggle_pause
    jmp .done
.back5:
    mov eax, -5000
    call pl_seek_by
    jmp .done
.fwd5:
    mov eax, 5000
    call pl_seek_by
    jmp .done
.louder:
    mov eax, [pl_volume]
    add eax, 10
    cmp eax, 100
    jbe .setv
    mov eax, 100
    jmp .setv
.softer:
    mov eax, [pl_volume]
    sub eax, 10
    jns .setv
    xor eax, eax
.setv:
    mov [pl_volume], eax
    mov dword [pl_muted], 0
    call pl_apply_volume
.done:
    or byte [gui_dirty], 1
    popad
    ret

section .data
pl_s_conn   db "Connecting...", 0
pl_s_load   db "Loading...", 0
pl_s_buf    db "Loading...", 0
pl_e_url    db "MOOS cannot follow this video's address", 0
pl_e_conn   db "Could not reach the video's server", 0
pl_e_size   db "The server did not say how big the video is", 0
pl_e_big    db "This video is too big (MOOS plays files up to 768 MB)", 0
pl_e_mem    db "Not enough memory for this video", 0
pl_e_net    db "The download broke off", 0
pl_e_fmt    db "MOOS plays MP4 files (H.264 video, AAC sound) - not this one", 0
pl_e_codec  db "MOOS cannot decode this video's kind of picture or sound", 0
section .text
