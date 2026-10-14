; =============================================================================
;  player.asm - the browser's video and audio player
;
;  A <video> or <audio> on a page becomes a "video record" (vid_get, from the
;  layout); clicking it (or autoplay) starts the one player MOOS has. The
;  player:
;
;    downloads  the file with the streaming HTTP(S) client (hs_open/hs_read
;               in url.asm) in pieces of PL_PIECE bytes asked for with Range
;               (CDNs such as YouTube's slow down one long download), into a
;               buffer as big as the file, keeping a bitmap of which 64 KB
;               chunks have arrived - so seeking back costs nothing and
;               seeking ahead just starts the next piece there;
;    demuxes    it with mp4.asm (MP4: H.264 video + AAC audio, as YouTube's
;               itag 18 and most web video): first it walks the file's
;               top-level boxes to find the index ("moov"), which may be at
;               the start or the end, then reads the sample tables from it;
;    decodes    the video with h264.asm and the sound with aac.asm;
;    plays      the sound through sound.asm, and shows each picture when the
;               sound card's position (snd_played) reaches its time - the
;               sound is the clock. Without a sound card, the timer is.
;
;  It runs in small steps from the desktop's main loop (pl_tick, through
;  brow_tick), so the desktop stays usable while a video plays. A new picture
;  is drawn straight into the video's box when the browser window is in
;  front (cheap); else the desktop is redrawn a few times a second.
;
;  The player's box: the video (kept in proportion, black bars), or the
;  poster before it starts, a play button over it when it is not playing,
;  and a control bar at the bottom when the mouse moves over it: play/pause,
;  the time, a progress bar (light grey: downloaded; click to jump), the
;  volume (click the speaker to mute) and full screen.
;  Keys while a video is on the page: K pause, J / L 10 s back / ahead,
;  F full screen, M mute; in full screen also Space, the arrows and Esc.
; =============================================================================
VID_MAX     equ 8                   ; video/audio elements per page
VR_SRC      equ 0                   ; its src (page nodes)
VR_POSTER   equ 4                   ; poster picture (imgcache record) or 0
VR_AUTO     equ 8                   ; autoplay
VR_AUDIO    equ 12                  ; 1 = <audio>
VR_X        equ 16                  ; where it was last drawn (screen;
VR_Y        equ 20                  ; VR_W = 0: not on screen)
VR_W        equ 24
VR_H        equ 28
VR_SIZE     equ 32

PS_IDLE     equ 0                   ; player states
PS_LOADING  equ 1                   ; connecting, finding the file's index
PS_BUFFER   equ 2                   ; waiting for data
PS_PLAY     equ 3
PS_PAUSE    equ 4
PS_END      equ 5
PS_ERROR    equ 6

PL_CHUNK    equ 65536               ; bitmap granule
PL_PIECE    equ 8 * 1024 * 1024     ; one Range request
PL_MAXFILE  equ 768 * 1024 * 1024   ; longest file played
PL_BITMAP   equ PL_MAXFILE / PL_CHUNK / 8
PL_READ     equ 1024 * 1024         ; most bytes read per step
PL_NEAR     equ 2 * 1024 * 1024     ; data this far ahead of the stream: wait
PL_AHEAD    equ 1500                ; ms of data wanted before playing
PL_QUEUE    equ 400                 ; ms of sound kept in the sound card
PL_MAXMOOV  equ 64 * 1024 * 1024    ; biggest index
PL_MAXW     equ 1920                ; biggest picture
PL_MAXH     equ 1088
PL_PTSQ     equ 32                  ; pictures inside the decoder
PL_LATE     equ 100                 ; a picture this late (ms) is skipped
PL_BEHIND   equ 1500                ; this far behind: on to the next key
                                    ; picture (a slow computer)
PL_SLICE    equ 3                   ; ticks of work per step at most
PL_BARTIME  equ 250                 ; ticks the control bar stays up
CB_H        equ 34                  ; control bar height
C_PLAYED    equ 0xE53935            ; the progress bar's played part

section .bss
alignb 4
vid_tab     resb VID_MAX * VR_SIZE
vid_n       resd 1
pl_autostart resd 1                 ; a record to start (autoplay)
pl_rec      resd 1                  ; the video record playing (0 = none)
pl_state    resd 1
pl_msg      resd 1                  ; the message shown (loading, error)
pl_full     resd 1                  ; 1 = full screen
pl_pause_req resd 1                 ; 1 = the user paused (kept over seeks)
pl_lastmove resd 1                  ; ticks: last mouse move over the video
pl_mx       resd 1                  ; the mouse when last seen
pl_my       resd 1
pl_bar_up   resd 1                  ; 1 = the control bar was drawn
pl_newpic   resd 1                  ; 1 = a new picture to show
pl_ui       resd 1                  ; 1 = the box should be drawn again
pl_lastsec  resd 1                  ; the second the bar shows
pl_dl_t     resd 1                  ; ticks: bar redrawn for the download
pl_dl_new   resd 1                  ; 1 = data came since
pl_redraw_t resd 1                  ; ticks of the last desktop redraw
pl_volume   resd 1                  ; 0..100
pl_vol_set  resd 1                  ; (pl_volume has been set)
pl_muted    resd 1
pl_url      resb 4096
; the file
pl_file     resd 1                  ; buffer (whole file)
pl_fsize    resd 1                  ; its size
pl_bits     resb PL_BITMAP          ; chunks present
pl_st_open  resd 1                  ; 1 = a stream is open
pl_st_piece0 resd 1                 ; where it started
pl_st_pos   resd 1                  ; next file offset it delivers
pl_st_end   resd 1                  ; where its piece ends
pl_norange  resd 1                  ; 1 = the server ignores Range
pl_fails    resd 1                  ; stream failures in a row
pl_retry_t  resd 1                  ; ticks: not before this
; the index
pl_want     resd 1                  ; (loading) the offset looked at
pl_scan     resd 1                  ; next top-level box
pl_moov_off resd 1
pl_moov_len resd 1                  ; 0 = not found yet
pl_moov_ok  resd 1                  ; 1 = parsed
pl_info     resd 1                  ; MP4INFO (big block)
pl_work     resd 1                  ; sample tables
pl_worklen  resd 1
pl_hasv     resd 1                  ; tracks being played
pl_hasa     resd 1
pl_vsamp    resd 1                  ; video samples, count, next, timescale
pl_vcount   resd 1
pl_vnext    resd 1
pl_vscale   resd 1
pl_vend     resd 1                  ; 1 = no more pictures
pl_flushed  resd 1
pl_asamp    resd 1                  ; audio samples, count, next, timescale
pl_acount   resd 1
pl_anext    resd 1
pl_ascale   resd 1
pl_dur_ms   resd 1                  ; length of the whole thing
; decoding
pl_h264     resd 1                  ; decoder context
pl_h264mem  resd 1                  ; its memory
pl_h264len  resd 1
pl_nalsize  resd 1                  ; length prefix size of the NAL units
pl_aac      resd 1                  ; sound decoder context
pl_rate     resd 1                  ; sound: rate, channels
pl_chans    resd 1
pl_card     resd 1                  ; 1 = there is a sound card
pl_sound    resd 1                  ; 1 = sound card open
pl_snd_paused resd 1
pl_awritten resd 1                  ; frames given to the card since snd_open
pl_snd_lost resd 1                  ; frames it played while it had none
pl_maxw     resd 1                  ; picture buffers (rows of pl_maxw)
pl_maxh     resd 1
pl_vw       resd 1                  ; the shown picture's size
pl_vh       resd 1
pl_nw       resd 1                  ; the next one's
pl_nh       resd 1
pl_pic      resd 1                  ; shown picture (0x00RRGGBB)
pl_next     resd 1                  ; next picture, converted
pl_pic_ok   resd 1                  ; 1 = pl_pic holds one
pl_next_ok  resd 1                  ; 1 = pl_next holds one
pl_next_ms  resd 1                  ; its time
pl_dropped  resd 1                  ; pictures skipped (too late)
pl_vbusy    resd 1                  ; 1 = the video step got something done
pl_shown_t  resd 1                  ; ticks when a picture was last shown
pl_ptsq     resd PL_PTSQ            ; times of the pictures in the decoder
pl_ptsn     resd 1
pl_lastpts  resd 1
; the clock
pl_held     resd 1                  ; 1 = stopped (paused, buffering)
pl_hold_ms  resd 1                  ; ... at this time
pl_base_ms  resd 1                  ; time at the last start
pl_t0       resd 1                  ; ticks then (when there is no sound)
pl_frame    resb 64                 ; H264FRAME
alignb 16
pl_pcm      resw 1024 * 8           ; one decoded sound frame
; colour conversion
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
; drawing
vd_rec      resd 1                  ; the record and box being drawn
vd_x        resd 1
vd_y        resd 1
vd_w        resd 1
vd_h        resd 1
vd_st       resd 1                  ; its state
vd_by       resd 1                  ; control bar: top
vd_tx       resd 1                  ; time text
vd_gx0      resd 1                  ; progress bar
vd_gx1      resd 1
vd_vx0      resd 1                  ; volume
vd_vx1      resd 1
vd_fx0      resd 1                  ; full screen button
vd_cx       resd 1                  ; the box's middle
vd_cy       resd 1
vd_run      resd 1
vd_time     resb 48
section .text

; ------------------------------------------------------------ records
; vid_reset: a new page: stop the player, forget the video records
vid_reset:
    call pl_stop
    mov dword [vid_n], 0
    mov dword [pl_autostart], 0
    cmp dword [pl_vol_set], 0       ; (the volume, the first time)
    jne .r
    mov dword [pl_volume], 80
    mov dword [pl_vol_set], 1
.r: ret

; vid_get: ESI = src (page nodes), EBX = poster record, ECX = autoplay,
; EDX = 1 for <audio> -> EAX = the record (0 if there is no room).
; Autoplay starts the first time it is seen.
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
    test ebp, ebp                   ; autoplay: start it (after this layout)
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

; vid_unseen: before the page is painted: no record is on screen
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

; vid_at: -> EDI = the record under the mouse (as last drawn); CF=1 if none
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

; ------------------------------------------------------------ starting
; pl_stop: stop playing and give back all the player's memory
pl_stop:
    pushad
    call pl_close_stream
    cmp dword [pl_sound], 0
    je .nsnd
    call snd_close
.nsnd:
    mov edx, OWN_MEDIA
    call big_free_owner
    cmp dword [pl_full], 0          ; (out of full screen)
    je .nf
    or byte [gui_dirty], 1
.nf:
    xor eax, eax
    mov edi, pl_rec                 ; everything from pl_rec on, but the
    mov ecx, (pl_volume - pl_rec) / 4   ; volume
    rep stosd
    mov edi, pl_file
    mov ecx, (pl_frame - pl_file) / 4
    rep stosd
    popad
    ret

; pl_start: EDI = a video record -> start playing it
pl_start:
    pushad
    push edi
    call pl_stop
    pop edi
    mov [pl_rec], edi
    mov dword [pl_held], 1          ; (the clock stands at 0 until playing)
    mov eax, [ticks]
    mov [pl_lastmove], eax
    mov esi, [edi + VR_SRC]         ; its full address
    mov edi, pl_url
    call brow_resolve
    jc .badurl
    mov dword [pl_state], PS_LOADING
    mov dword [pl_msg], pl_s_conn
    or byte [gui_dirty], 1          ; (show "Connecting..." meanwhile)
    call gui_redraw
    xor eax, eax                    ; the first piece, which also tells the
    call pl_open_at                 ; file's size
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

; pl_error: EAX = a message -> the player stops with it
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

; pl_open_at: EAX = file offset -> a stream for the piece from there (from
; the start of its chunk, to the next chunk already here or PL_PIECE on).
; Sets pl_fsize from the reply if not known. CF=1 on failure.
pl_open_at:
    pushad
    call pl_close_stream
    and eax, ~(PL_CHUNK - 1)
    cmp dword [pl_norange], 0       ; (a server that ignores Range: always
    je .r0                          ; the whole file)
    xor eax, eax
.r0:
    mov [pl_st_piece0], eax
    mov [pl_st_pos], eax
    lea ecx, [eax + PL_PIECE]
    cmp dword [pl_fsize], 0
    je .r
    push eax
    call pl_next_here               ; up to what is already here
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
    cmp eax, 206                    ; Partial Content
    je .part
    cmp eax, 200                    ; all of it: fine from the start
    jne .bad
    mov dword [pl_norange], 1
    cmp dword [pl_st_pos], 0
    jne .bad
    mov eax, [hs_clen]              ; (the size is the length)
    test eax, eax
    jz .bad
    mov [pl_st_end], eax
    jmp .size
.part:
    mov eax, [hs_total]             ; Content-Range: bytes a-b/TOTAL
.size:
    cmp dword [pl_fsize], 0
    jne .known
    mov [pl_fsize], eax
.known:
    mov eax, [pl_fsize]             ; (never past the end)
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

; pl_close_stream: close the download stream, if one is open
pl_close_stream:
    cmp dword [pl_st_open], 0
    je .r
    call hs_close
    mov dword [pl_st_open], 0
.r: ret

; ------------------------------------------------------------ the bitmap
; pl_mark: EAX = start (at a chunk's start), ECX = end (file offsets) ->
; the chunks wholly inside are marked present (and the file's last, partial
; chunk when the end is the end of the file)
pl_mark:
    pushad
    shr eax, 16
    mov edx, ecx
    cmp edx, [pl_fsize]
    jne .notend
    add edx, PL_CHUNK - 1
.notend:
    shr edx, 16                     ; end chunk (exclusive)
.l: cmp eax, edx
    jae .done
    bts [pl_bits], eax
    inc eax
    jmp .l
.done:
    popad
    ret

; pl_present: EAX = offset, ECX = length -> CF=0 if those bytes are here
pl_present:
    pushad
    cmp dword [pl_file], 0
    je .no
    test ecx, ecx
    jz .yes
    lea edx, [eax + ecx]
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

; pl_missing: EAX = file offset -> EAX = the first chunk at or after it
; that is not here (as an offset), or the file size if none
pl_missing:
    push edx
    mov edx, [pl_fsize]
    add edx, PL_CHUNK - 1
    shr edx, 16                     ; chunks in the file
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

; pl_next_here: EAX = file offset -> EAX = the first chunk at or after it
; that is here (as an offset), or the file size if none
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

; pl_all_here: -> CF=0 if the whole file has arrived
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

; ------------------------------------------------------------ downloading
; pl_need: -> EAX = the file offset the player needs next
pl_need:
    cmp dword [pl_moov_ok], 0
    jne .samples
    mov eax, [pl_want]              ; (still finding the index)
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

; pl_download: one step: read what has arrived (up to PL_READ bytes); when
; a piece is done, or the player needs data far from where the stream is,
; start a piece at the first missing chunk from where it is needed
pl_download:
    pushad
    cmp dword [pl_file], 0
    je .done
    cmp dword [pl_st_open], 0
    je .open_needed
    call pl_need                    ; is the stream where it is needed?
    mov ebx, eax
    cmp ebx, [pl_fsize]
    jae .read
    mov ecx, 1
    call pl_present
    jnc .read                       ; (that is here: read on ahead)
    cmp dword [pl_norange], 0
    jne .read
    cmp ebx, [pl_st_piece0]
    jb .move
    mov eax, [pl_st_pos]
    add eax, PL_NEAR
    cmp ebx, eax
    jb .read                        ; it will get there soon
.move:
    call pl_close_stream
    jmp .open_needed
.read:
    xor ebp, ebp                    ; bytes this step
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
    jz .done                        ; nothing more yet
    js .ended
    mov ecx, [pl_st_pos]
    add [pl_st_pos], eax
    add ebp, eax
    mov dword [pl_fails], 0
    mov dword [pl_dl_new], 1
    mov eax, ecx                    ; mark from the start of the chunk the
    and eax, ~(PL_CHUNK - 1)        ; old position was in (this stream
    mov ecx, [pl_st_pos]            ; filled it from its start)
    call pl_mark
    cmp ebp, PL_READ
    jb .rl
    jmp .done
.ended:                             ; -1 finished, -2 broken
    mov eax, [pl_st_pos]
    cmp eax, [pl_st_end]
    jae .piece_done
    call pl_close_stream            ; broken off: again from where it got to
    call pl_failed
    jmp .done
.piece_done:
    call pl_close_stream
.open_needed:
    mov eax, [ticks]                ; (after a failure: wait a little)
    cmp eax, [pl_retry_t]
    js .done
    call pl_need
    call pl_missing                 ; the first missing chunk from there,
    cmp eax, [pl_fsize]
    jb .open
    xor eax, eax                    ; else anything still missing
    call pl_missing
    cmp eax, [pl_fsize]
    jae .done                       ; the whole file is here
.open:
    call pl_open_at
    jnc .done
    call pl_failed
.done:
    popad
    ret

; pl_failed: the stream failed: try again after a while, give up after 8
pl_failed:
    inc dword [pl_fails]
    push eax
    mov eax, [pl_fails]
    imul eax, 50                    ; (half a second more each time)
    add eax, [ticks]
    mov [pl_retry_t], eax
    pop eax
    cmp dword [pl_fails], 8
    jb .r
    mov eax, pl_e_net
    call pl_error
.r: ret

; ------------------------------------------------------------ the index
; pl_find_index: (PS_LOADING) walk the file's top-level boxes to the
; "moov" box; once all of it is here, read it (pl_setup)
pl_find_index:
    pushad
    cmp dword [pl_moov_len], 0
    jne .have
    mov ebp, 64                     ; boxes looked at per step
.scan:
    mov eax, [pl_scan]
    mov [pl_want], eax
    mov ecx, 16                     ; its header: size, type (, 64-bit size)
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
    bswap edx                       ; EDX = size
    mov ebx, [esi + 4]              ; EBX = type
    cmp edx, 1
    jne .s0
    cmp ecx, 16                     ; size 1: a 64-bit size follows
    jb .noindex
    cmp dword [esi + 8], 0
    jne .noindex                    ; (4 GB or more)
    mov edx, [esi + 12]
    bswap edx
    jmp .sz
.s0:
    test edx, edx                   ; size 0: to the end of the file
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
    lea ecx, [eax + edx]
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

; pl_setup: the index is here: read it, start the decoders, go to the start
pl_setup:
    pushad
    mov ecx, MP4I_SIZE
    mov edx, OWN_MEDIA
    call big_alloc
    test eax, eax
    jz .nomem
    mov [pl_info], eax
    mov ecx, [pl_moov_len]          ; sample tables: up to 16 bytes per
    imul ecx, ecx, 6                ; 4-byte size entry, and room to spare
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
    xor eax, eax                    ; its length: the longer track
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

; pl_video_init: EBX = MP4INFO with a video track -> the H.264 decoder and
; picture buffers (pl_hasv = 1), or nothing if it cannot be played
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
    add eax, 15                     ; whole macroblocks
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
    cmp eax, 1                      ; the NAL length size: 1, 2 or 4
    je .ns
    cmp eax, 2
    je .ns
    cmp eax, 4
    jne .no
.ns:
    mov [pl_nalsize], eax
    mov ecx, [pl_maxw]              ; two pictures: shown, next
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

; pl_audio_init: EBX = MP4INFO with a sound track -> the AAC decoder
; (pl_hasa = 1) and the sound card (pl_card), or nothing
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

; ------------------------------------------------------------ time
; pl_ms: EAX = time in units of ECX per second -> EAX = milliseconds
pl_ms:
    push ecx
    push edx
    test ecx, ecx
    jz .zero
    mov edx, 1000
    mul edx
    cmp edx, ecx                    ; (would not fit)
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

; pl_units: EAX = milliseconds -> EAX = time in units of ECX per second
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

; pl_snd_ms: -> EAX = ms of sound the card has played (of what it was given;
; silence it played while it had nothing is not counted)
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

; pl_clock: -> EAX = where the playing is, in ms
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

; pl_hold: stop the clock (pausing, waiting for data)
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

; pl_unhold: start the clock again where it stopped (opening the sound card
; after a seek)
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
    cmp dword [pl_hasa], 0          ; sound to play, and a card?
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
    call pl_audio                   ; (fill it before the clock runs)
    jmp .done
.nocard:
    mov dword [pl_card], 0          ; (then the timer is the clock)
    jmp .done
.resume:
    cmp dword [pl_snd_paused], 0
    je .done
    call snd_resume
    mov dword [pl_snd_paused], 0
.done:
    popad
    ret

; pl_apply_volume: the volume (or mute) to the sound card
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

; pl_seek: EAX = ms -> play from there (from the picture that can be
; decoded on its own at or before it)
pl_seek:
    pushad
    cmp dword [pl_moov_ok], 0
    je .done
    mov ebp, eax                    ; EBP = the time
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
    cmp eax, [pl_vcount]            ; its time is where playing starts
    jae .flush
    shl eax, 4
    add eax, [pl_vsamp]
    mov eax, [eax + MP4S_PTS]
    mov ecx, [pl_vscale]
    call pl_ms
    mov ebp, eax
.flush:
    CCALL h264_flush, dword [pl_h264]   ; (drop what the decoder holds)
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
    mov eax, ebp                    ; the first sound frame at or after it
    mov ecx, [pl_ascale]
    call pl_units
    mov edx, eax
    xor ebx, ebx                    ; (binary search: EBX = low, ECX = high)
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
    mov eax, [pl_info]              ; a fresh decoder (no old overlap)
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

; pl_seek_by: EAX = ms (+ ahead, - back) from where playing is
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

; ------------------------------------------------------------ playing
; pl_buffered: -> CF=0 if the data for the next PL_AHEAD ms (or to the
; end) is here
pl_buffered:
    pushad
    call pl_all_here
    jnc .yes
    mov ebp, [pl_hold_ms]
    add ebp, PL_AHEAD               ; EBP = wanted up to this time
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

; pl_starve: the next data is not here yet: wait for it
pl_starve:
    call pl_hold
    mov dword [pl_state], PS_BUFFER
    mov dword [pl_msg], pl_s_buf
    mov dword [pl_ui], 1
    ret

; pl_queued: -> EAX = sound frames given to the card and not played yet
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

; pl_audio: decode sound frames into the card while it has room and holds
; less than PL_QUEUE ms
pl_audio:
    pushad
    cmp dword [pl_sound], 0
    je .done
    mov ebp, 16                     ; frames per step at most
.l: mov eax, [pl_rate]
    imul eax, PL_QUEUE
    xor edx, edx
    mov ecx, 1000
    div ecx
    mov ebx, eax                    ; EBX = frames wanted in the card
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
    mov edi, pl_pcm                 ; a bad frame: silence instead (keeps
    mov ecx, 1024                   ; the time right)
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
    call pl_queued                  ; about to run dry: wait for the data
    mov ecx, [pl_rate]
    shr ecx, 3                      ; (an eighth of a second left)
    cmp eax, ecx
    jae .done
    call pl_starve
.done:
    popad
    ret

; pl_video: show the next picture when its time has come, and decode the
; one after it
pl_video:
    pushad
    mov dword [pl_vbusy], 0
    cmp dword [pl_hasv], 0
    je .done
    call pl_clock
    mov ebp, eax                    ; EBP = now
    cmp dword [pl_next_ok], 0
    je .decode
    mov eax, [pl_next_ms]
    cmp eax, ebp
    jg .done                        ; not yet
    mov eax, [pl_pic]               ; it is: the next becomes the shown
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
    cmp dword [pl_state], PS_PLAY   ; far behind (a slow computer)?
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

; pl_skip_to_key: EBP = now -> the video goes on from the first key picture
; (sync sample) at or after now, if there is one; the pictures before it
; are not decoded at all
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
    CCALL h264_flush, dword [pl_h264]   ; (what the decoder holds: dropped)
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

; pl_decode_pic: EBP = now -> decode until a picture comes out (into
; pl_next, converted), feeding at most a few samples per step. Pictures
; already too late are decoded but not converted (skipped).
pl_decode_pic:
    pushad
    mov edi, 1                      ; samples this step at most
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
    mov eax, [ebx + MP4S_PTS]       ; its time, for the picture it makes
    mov ecx, [pl_vscale]
    call pl_ms
    call pl_pts_push
    inc dword [pl_vnext]
    mov dword [pl_vbusy], 1
    dec edi
    jnz .try
    jmp .done
.eos:
    cmp dword [pl_flushed], 0       ; the end: the decoder's last pictures
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
    call pl_pts_pop                 ; EAX = its time
    lea ecx, [eax + PL_LATE]
    cmp ecx, ebp
    jge .conv
    cmp dword [pl_pic_ok], 0        ; (the first is always shown)
    je .conv
    cmp dword [pl_state], PS_PLAY
    jne .conv
    mov ecx, [ticks]                ; (but one now and then all the same)
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

; pl_feed: EAX = offset, ECX = size of a video sample (here) -> its NAL
; units (each after a big-endian length of pl_nalsize bytes) to the decoder
pl_feed:
    pushad
    mov esi, [pl_file]
    add esi, eax
    lea edi, [esi + ecx]            ; EDI = its end
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
    ja .done                        ; (longer than the sample: broken)
    test ebx, ebx
    jz .n
    CCALL h264_decode_nal, dword [pl_h264], esi, ebx
    add esi, ebx
    jmp .n
.done:
    popad
    ret

; pl_pts_push: EAX = a decoded sample's time -> kept until its picture
pl_pts_push:
    push ecx
    mov ecx, [pl_ptsn]
    cmp ecx, PL_PTSQ
    jb .put
    push esi                        ; full (broken stream): drop the oldest
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

; pl_pts_pop: -> EAX = the time of the picture that came out: the smallest
; time waiting (pictures come out in display order)
pl_pts_pop:
    push ebx
    push ecx
    push edx
    mov ecx, [pl_ptsn]
    test ecx, ecx
    jz .none
    xor ebx, ebx                    ; EBX = where the smallest is
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
    dec ecx                         ; take it out
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
    mov eax, [pl_lastpts]           ; (no time known: a frame after the last)
    add eax, 33
    mov [pl_lastpts], eax
    pop edx
    pop ecx
    pop ebx
    ret

; pl_tables: the colour conversion tables (BT.601, video range): each
; value times 1024
pl_tables:
    pushad
    cmp dword [pl_tabs_ok], 0
    jne .done
    xor ecx, ecx
.t: lea eax, [ecx - 16]             ; 1.164 (Y - 16)
    imul eax, 1192
    add eax, 512                    ; (rounding)
    mov [pl_ty + ecx * 4], eax
    lea eax, [ecx - 128]
    imul edx, eax, 1634             ; 1.596 (V - 128) for red
    mov [pl_trv + ecx * 4], edx
    imul edx, eax, 401              ; 0.391 (U - 128) for green
    mov [pl_tgu + ecx * 4], edx
    imul edx, eax, 833              ; 0.813 (V - 128) for green
    mov [pl_tgv + ecx * 4], edx
    imul edx, eax, 2066             ; 2.018 (U - 128) for blue
    mov [pl_tbu + ecx * 4], edx
    inc ecx
    cmp ecx, 256
    jb .t
    xor ecx, ecx                    ; clamp[i] = i - 384 kept within 0-255
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

; pl_convert: the picture in pl_frame (YUV 4:2:0) -> pl_next (0x00RRGGBB,
; rows of pl_maxw pixels), its size in pl_nw / pl_nh
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
    mov esi, eax                    ; ESI = the Y row
    imul esi, [pl_frame + H264F_YS]
    add esi, [pl_frame + H264F_Y]
    mov ebx, eax                    ; the U and V rows
    shr ebx, 1
    imul ebx, [pl_frame + H264F_CS]
    mov ecx, ebx
    add ebx, [pl_frame + H264F_U]
    add ecx, [pl_frame + H264F_V]
    mov [cv_u], ebx
    mov [cv_v], ecx
    mov edi, eax                    ; EDI = the output row
    imul edi, [pl_maxw]
    shl edi, 2
    add edi, [pl_next]
    mov eax, [pl_nw]                ; pixel pairs (one U, V each)
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
    mov edx, [pl_tgu + eax * 4]     ; ECX = red, CV_GUV = green, EDX = blue
    add edx, [pl_tgv + ecx * 4]     ; parts from the colour
    mov [cv_guv], edx
    mov edx, [pl_tbu + eax * 4]
    mov ecx, [pl_trv + ecx * 4]
%rep 2
    movzx ebx, byte [esi]
    mov ebx, [pl_ty + ebx * 4]      ; EBX = the brightness part
    mov [cv_tmp], ebx
    lea ebp, [ebx + ecx]            ; red
    sar ebp, 10
    movzx ebp, byte [pl_clamp + 384 + ebp]
    shl ebp, 16
    sub ebx, [cv_guv]               ; green
    sar ebx, 10
    movzx ebx, byte [pl_clamp + 384 + ebx]
    shl ebx, 8
    or ebp, ebx
    mov ebx, [cv_tmp]               ; blue
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

; pl_ended: -> CF=0 if everything has been played
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
    cmp dword [pl_hasv], 0          ; (no sound card: with a video, it ends
    jne .yes                        ; with the video, else by the clock)
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

; ------------------------------------------------------------ the step
; pl_tick: from the desktop's main loop: one step of the player
pl_tick:
    pushad
    mov edi, [pl_autostart]         ; autoplay, once the page's pictures
    test edi, edi                   ; have come
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
    mov dword [pl_state], PS_PAUSE  ; enough: play (or stay paused)
    mov dword [pl_ui], 1
    cmp dword [pl_pause_req], 0
    jne .show
    mov dword [pl_state], PS_PLAY
    call pl_unhold
    jmp .show
.playing:
    cmp eax, PS_PAUSE
    jne .play
    call pl_video                   ; (after a seek: its first picture)
    jmp .show
.play:
    cmp eax, PS_PLAY
    jne .show
    mov ebx, [ticks]                ; sound first, then a picture, in turn,
.work:                              ; for up to PL_SLICE ticks
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
    call pl_hold                    ; the end
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

; pl_mouse: the mouse moved over the playing video (or in full screen):
; the control bar comes up
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

; pl_bar_check: the control bar shows the time and the download: draw it
; again when the second changes, now and then while downloading, and when
; it should hide
pl_bar_check:
    pushad
    cmp dword [pl_bar_up], 0
    je .done
    call pl_bar_wanted
    jc .redraw                      ; (it should go away)
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

; pl_bar_wanted: -> CF=0 if the playing video's control bar should show
pl_bar_wanted:
    push eax
    mov eax, [pl_rec]
    test eax, eax
    jz .no
    cmp dword [eax + VR_AUDIO], 0   ; (always, for <audio>)
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

; pl_show: if there is something new to show, draw the player's box -
; straight onto the screen when the browser is the window in front, else by
; redrawing the desktop (at most five times a second)
pl_show:
    pushad
    mov eax, [pl_newpic]
    or eax, [pl_ui]
    jz .done
    cmp byte [gui_dirty], 0         ; (all is drawn soon anyway)
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
    je .clear                       ; (not on screen)
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

; pl_draw_in_page: draw the playing video's box (where the page last put
; it) into the back buffer and onto the screen
pl_draw_in_page:
    pushad
    call cur_rect                   ; the mouse cursor off the picture
    mov ebx, cur_under
    mov eax, 1
    call gfx_copy_rect
    mov ecx, [br_vx]                ; within the page's part of the window
    mov edx, [br_vy]
    mov esi, [br_vw]
    mov edi, [br_vh]
    call gfx_clip_set
    mov edi, [pl_rec]
    call vd_from_rec
    call vid_draw
    mov ecx, [gfx_cx0]              ; what of it was drawn: to the screen
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

; vd_from_rec: EDI = a record -> its last box into vd_*
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

; ------------------------------------------------------------ drawing
; vid_paint: (from html_paint) ESI = a player's item, ECX / EDX = where on
; the screen -> its box
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

; pl_full_draw: (full screen) the playing video over the whole screen
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

; vid_draw: the box vd_* of the record vd_rec: picture (or poster), the
; play button or a message over it, and the control bar
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
    mov eax, [pl_pic]               ; the picture
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
    cmp dword [edi + VR_AUDIO], 0   ; idle, paused, ended: the play button
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
    cmp dword [edi + VR_AUDIO], 0   ; (<audio>: the bar even when idle)
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

; vd_picture: EAX = pixels, EBX / ECX = width / height, EDX = pixels per
; row -> drawn as big as fits in the box, in proportion, in the middle
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
    mov eax, ebx                    ; width-limited if w * boxh >= h * boxw
    mul dword [vd_h]
    mov esi, eax
    mov eax, ecx
    mul dword [vd_w]
    cmp esi, eax
    jb .tall
    mov eax, [vd_w]                 ; full width, height = h * boxw / w
    mov [gb_w], eax
    mov eax, ecx
    mul dword [vd_w]
    div ebx
    mov [gb_h], eax
    jmp .place
.tall:
    mov eax, [vd_h]                 ; full height, width = w * boxh / h
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

; vd_play_button: a big play button in the middle of the box
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
    add ecx, 2                      ; (a box with its corners cut)
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
    mov eax, [vd_cx]                ; a white triangle
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

; vd_message: ESI = a message -> shown in the middle of the box
vd_message:
    pushad
    test esi, esi
    jz .done
    call str_len
    shl ecx, 3                      ; ECX = its width
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

; vd_geom: the control bar's parts for the box vd_*
vd_geom:
    pushad
    mov eax, [vd_y]
    add eax, [vd_h]
    sub eax, CB_H
    mov [vd_by], eax
    mov eax, [vd_x]
    add eax, 40
    mov [vd_tx], eax
    mov eax, [vd_x]                 ; full screen button (not for <audio>)
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
    call pl_time_text               ; ECX = its length
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
    mov eax, [vd_fx0]               ; narrow: no volume
    mov [vd_vx0], eax
    mov [vd_vx1], eax
    sub eax, 12
    mov [vd_gx1], eax
    sub eax, ecx
    cmp eax, 40
    jge .done
    mov eax, [vd_tx]                ; still narrow: no time either
    mov [vd_gx0], eax
.done:
    popad
    ret

; pl_time_text: -> vd_time = "m:ss / m:ss" (where / length), ECX = its length
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

; pl_time_fmt: EAX = ms -> "m:ss" or "h:mm:ss" at EDI (EDI moves on)
pl_time_fmt:
    push eax
    push ebx
    push edx
    xor edx, edx
    mov ebx, 1000
    div ebx                         ; EAX = seconds
    xor edx, edx
    mov ebx, 3600
    div ebx                         ; EAX = hours, EDX = the rest
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

; vd_bar: the control bar along the bottom of the box
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
    ; play / pause
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
    je .prog                        ; (no room for it)
    mov edx, [vd_by]
    add edx, 9
    TEXT [vd_tx], edx, vd_time, 0xFFFFFF, -1
.prog:
    mov esi, [vd_gx1]               ; the progress bar
    sub esi, [vd_gx0]
    jle .vol
    mov edx, [vd_by]
    add edx, 15
    RECT [vd_gx0], edx, esi, 4, 0x4A4A4A
    call vd_downloaded
    mov edi, [vd_rec]
    cmp edi, [pl_rec]
    jne .vol
    mov ecx, [pl_dur_ms]            ; played: clock / length of the bar
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
    mov ebx, eax                    ; EBX = played pixels
    mov edx, [vd_by]
    add edx, 15
    RECT [vd_gx0], edx, ebx, 4, C_PLAYED
    mov ecx, [vd_gx0]               ; the knob
    add ecx, ebx
    sub ecx, 5
    mov edx, [vd_by]
    add edx, 11
    RECT ecx, edx, 10, 12, C_PLAYED
.vol:
    mov ecx, [vd_vx0]
    cmp ecx, [vd_vx1]
    je .full
    mov edx, [vd_by]                ; a speaker
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
    mov ecx, [vd_vx0]               ; and its level
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
    mov ecx, [vd_vx0]               ; muted: a red line through it
    mov edx, [vd_by]
    add edx, 16
    RECT ecx, edx, 14, 2, 0xFF5252
.full:
    mov edi, [vd_rec]
    cmp dword [edi + VR_AUDIO], 0
    jne .done
    mov ecx, [vd_fx0]               ; full screen: four corners
    add ecx, 7
    mov edx, [vd_by]
    add edx, 9
    call .corners
.done:
    popad
    ret
.corners:                           ; ECX, EDX = top left of a 20 x 16 frame
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

; vd_downloaded: the parts of the progress bar whose data has arrived, in
; light grey (each column stands for its share of the file)
vd_downloaded:
    pushad
    mov edi, [vd_rec]
    cmp edi, [pl_rec]
    jne .done
    cmp dword [pl_file], 0
    je .done
    mov ebp, [vd_gx1]
    sub ebp, [vd_gx0]               ; EBP = columns
    jle .done
    xor ebx, ebx                    ; EBX = column
    mov dword [vd_run], -1          ; start of a run of present columns
.col:
    cmp ebx, ebp
    jae .flush
    mov eax, ebx                    ; its file offset
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
.draw:                              ; the run from vd_run to EBX
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

; ------------------------------------------------------------ input
; vid_click: EDI = a record, the box vd_* set (the mouse is in it)
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
    je .start                       ; (try again)
    cmp eax, PS_LOADING
    je .done
    call pl_bar_wanted              ; the control bar?
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

; pl_toggle_pause: pause or play the video playing
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
    xor dword [pl_pause_req], 1     ; (taken when the data is here)
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
.again:                             ; ended: from the start
    mov dword [pl_pause_req], 0
    xor eax, eax
    call pl_seek
.done:
    popad
    ret

; pl_toggle_full: full screen on / off
pl_toggle_full:
    xor dword [pl_full], 1
    or byte [gui_dirty], 1
    push eax
    mov eax, [ticks]
    mov [pl_lastmove], eax
    pop eax
    ret

; pl_full_click: a click in full screen
pl_full_click:
    pushad
    call pl_full_box
    mov edi, [pl_rec]
    call vid_click
    or byte [gui_dirty], 1
    popad
    ret

; pl_full_box: vd_* = the whole screen, for the playing record
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

; pl_page_key: EAX = a key for the page (the browser, not typing) ->
; CF=0 if the player took it (K, J, L, F, M while a video is playing)
pl_page_key:
    cmp dword [pl_rec], 0
    je .no
    push eax
    or eax, 0x20                    ; (either case)
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

; pl_full_key: EAX = a key in full screen (all keys go to the player)
pl_full_key:
    pushad
    mov dword [pl_ui], 1
    mov ebx, [ticks]
    mov [pl_lastmove], ebx
    cmp eax, 27                     ; Esc: back to the page
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
    call pl_page_key                ; K J L F M
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
