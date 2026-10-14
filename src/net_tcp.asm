; =============================================================================
;  net_tcp.asm - TCP (RFC 9293), one connection at a time
;
;  MOOS is a TCP client: it opens one connection, sends a request, reads the
;  reply and closes. What keeps that working on real networks, where
;  segments are lost, duplicated and arrive out of order:
;
;  Receiving  Data goes into a 256 KB ring (TCP_RBUF). The window we
;             advertise is the real free space in that ring - more than
;             64 KB when the server agrees to window scaling (RFC 7323) - and
;             a window update is sent when the reader frees a good amount. A
;             segment that arrives after a gap is put straight into its place
;             in the ring and remembered as a range (up to 8 ranges); a
;             duplicate ACK goes back at once, so the sender soon resends the
;             missing part; when the server takes SACK (RFC 2018), the ACK
;             also lists the ranges we hold, so it resends only what is
;             missing. When the gap is filled, the ranges join on.
;             Data is acknowledged every second full segment, and at the end
;             of each batch of frames.
;  Sending    Our bytes wait in a 64 KB ring (TCP_SBUF) until they are
;             acknowledged. Segments are at most the server's MSS and never
;             go past its window. If no ACK comes within the retransmission
;             timeout (RFC 6298: smoothed round-trip time + 4 x its variation,
;             kept between 0.2 and 6 s), the unacknowledged bytes are sent
;             again and the timeout doubles; after 8 tries the connection has
;             failed. Our FIN is retransmitted the same way, and a zero window
;             is probed with one byte.
;  Opening    SYN with our MSS (1460), a window scale and SACK-permitted,
;             sent up to 4 times (waiting 1, 2, 4, 4 s).
;  Closing    The server's FIN ends its data; tcp_close queues ours.
;             tcp_abort sends a RST (when we stop reading early).
;  Checking   IP and TCP checksums, addresses and ports of every segment. A
;             RST counts only inside the window. Fragments are dropped.
;             Segments for a port we are not using are answered with a RST,
;             so a server that missed our last ACK gives up on it.
;
;  It is polled: tcp_poll handles every frame waiting in the network card
;  (ARP too) and returns at once. The blocking helpers loop over it.
;
;  Sequence numbers wrap at 2^32, so "a before b" is always tested as
;  (a - b) < 0 in signed 32-bit arithmetic.
; =============================================================================
TCP_FIN     equ 0x01
TCP_SYN     equ 0x02
TCP_RST     equ 0x04
TCP_PSH     equ 0x08
TCP_ACK     equ 0x10

TCP_RBUF    equ NET_STREAM + 0x00000    ; receive ring (256 KB)
RB_SIZE     equ 0x40000
TCP_SBUF    equ NET_STREAM + 0x40000    ; send ring (64 KB)
SB_SIZE     equ 0x10000
TCP_TXTMP   equ NET_STREAM + 0x78000    ; one outgoing segment's data (2 KB)

OOO_MAX     equ 8                       ; out-of-order ranges remembered
RCV_WSHIFT  equ 2                       ; our window scale: 65535 << 2 ~ 256 KB
TCP_MSS     equ 1460                    ; the most we take per segment
RTO_INIT    equ 100                     ; ticks (1/100 s): 1 s
RTO_MIN     equ 20
RTO_MAX     equ 600
SYN_RTO_MAX equ 400
RTX_TRIES   equ 8                       ; data/FIN retransmissions before giving up
SYN_TRIES   equ 4
TCP_BATCH   equ 64                      ; frames handled per tcp_poll

; reasons a connection ended badly (tcp_err)
TE_NONE     equ 0
TE_REFUSED  equ 1                       ; RST answering our SYN
TE_RESET    equ 2                       ; RST later on
TE_TIMEOUT  equ 3                       ; no answer to retransmissions

section .bss
alignb 4
tcp_dst_ip      resd 1                  ; the server (network byte order)
tcp_dst_port    resw 1                  ; ports in host byte order
tcp_src_port    resw 1
tcp_port_seq    resd 1                  ; picks the next local port
tcp_err         resd 1                  ; TE_*
; --- sending
snd_iss         resd 1                  ; our first sequence number (the SYN)
snd_una         resd 1                  ; oldest byte not yet acknowledged
snd_nxt         resd 1                  ; next byte to send
snd_max         resd 1                  ; highest sequence sent so far
snd_end         resd 1                  ; end of the queued data (our FIN goes here)
snd_wnd         resd 1                  ; the server's window, in bytes
snd_wl1         resd 1                  ; segment that last updated it (RFC 9293)
snd_wl2         resd 1
snd_mss         resd 1                  ; largest segment the server takes
; --- receiving
rcv_irs         resd 1                  ; the server's first sequence number
rcv_nxt         resd 1                  ; next byte expected in order
rcv_rd          resd 1                  ; next byte the reader takes from the ring
rcv_adv         resd 1                  ; window last advertised, in bytes
fin_seq         resd 1                  ; where the server's FIN is (fin_known)
ack_owed        resd 1                  ; bytes taken but not yet acknowledged
ooo_n           resd 1                  ; out-of-order ranges [start, end)
ooo_recent      resd 1                  ; start of the segment that came last
ooo_s           resd OOO_MAX + 1
ooo_e           resd OOO_MAX + 1
; --- timers
tcp_rto         resd 1                  ; retransmission timeout (ticks)
tcp_srtt8       resd 1                  ; smoothed round trip x 8
tcp_rttvar4     resd 1                  ; its variation x 4
rtt_seq         resd 1                  ; the byte being timed
rtt_t0          resd 1                  ; ... and when it was sent
rtx_at          resd 1                  ; retransmission deadline (0 = none)
rtx_n           resd 1                  ; retransmissions in a row
tcp_last_rx     resd 1                  ; when a segment last arrived (ticks)
net_idle_tick   resd 1
; --- the segment being handled
seg_seq         resd 1
seg_ack         resd 1
seg_len         resd 1                  ; payload bytes
seg_data        resd 1
seg_win         resd 1
seg_hdr         resd 1                  ; TCP header
seg_hlen        resd 1
seg_sip         resd 1
seg_sport       resd 1
seg_dport       resd 1
; --- what tcp_emit puts in the header
tx_dip          resd 1
tx_ack          resd 1
tx_win          resd 1
tx_sport        resw 1
tx_dport        resw 1
; --- flags
tcp_on          resb 1                  ; a connection is in use
tcp_estab       resb 1                  ; the handshake is done
tcp_fin_in      resb 1                  ; the server's FIN has arrived (in order)
tcp_reset       resb 1                  ; reset, refused or given up (tcp_err)
tcp_fin_q       resb 1                  ; our FIN is queued
tcp_fin_acked   resb 1                  ; ... and acknowledged
fin_known       resb 1
rtt_on          resb 1
rtt_have        resb 1                  ; tcp_srtt8 holds a measurement
snd_shift       resb 1                  ; the server's window scale
rcv_shift       resb 1                  ; ours (0 unless the server agreed)
sack_ok         resb 1                  ; the server takes SACK blocks
ack_now         resb 1                  ; send an ACK before returning
tcp_force       resb 1                  ; tcp_output may probe a zero window
tcp_opt_len     resb 1                  ; options for the next segment sent
tcp_loss        resb 1                  ; "net loss": percent of segments lost
tcp_opts        resb 40
alignb 4
tcp_lrand       resd 1                  ; its random numbers

section .text

; ------------------------------------------------------------- helpers
; net_copy: copy ECX bytes from ESI to EDI (four at a time, then the rest).
; ESI and EDI end past the bytes; ECX = 0.
net_copy:
    push eax
    mov eax, ecx
    shr ecx, 2
    rep movsd
    mov ecx, eax
    and ecx, 3
    rep movsb
    pop eax
    ret

; csum_add: EDX = running ones-complement sum, ESI = data, ECX = length ->
; EDX updated (ESI, ECX changed). The data is added as little-endian dwords:
; the Internet checksum does not depend on byte order (RFC 1071), so the
; folded result, stored as a little-endian word, is already in network order.
csum_add:
    push eax
    push ebx
    mov ebx, ecx
    shr ecx, 2
    clc
    jecxz .rest
.l: adc edx, [esi]                      ; (lea and dec leave CF alone)
    lea esi, [esi + 4]
    dec ecx
    jnz .l
.rest:
    adc edx, 0
    test ebx, 2
    jz .byte
    movzx eax, word [esi]
    add edx, eax
    adc edx, 0
    add esi, 2
.byte:
    test ebx, 1
    jz .done
    movzx eax, byte [esi]
    add edx, eax
    adc edx, 0
.done:
    pop ebx
    pop eax
    ret

; csum_fold: EDX = sum -> AX = the 16-bit ones-complement sum (not yet
; inverted). EDX changed.
csum_fold:
    mov eax, edx
    shr eax, 16
    and edx, 0xFFFF
    add eax, edx
    mov edx, eax
    shr edx, 16
    add eax, edx
    and eax, 0xFFFF
    ret

; tcp_pseudo_sum: EAX = source IP, EBX = destination IP, ECX = TCP length ->
; EDX = the sum of the pseudo-header (protocol 6, length)
tcp_pseudo_sum:
    push eax
    xor edx, edx
    add edx, eax
    adc edx, ebx
    adc edx, 0
    mov eax, ecx                        ; length, as the big-endian word it is
    xchg al, ah
    and eax, 0xFFFF
    add edx, eax
    adc edx, 0x0600                     ; zero byte + protocol 6
    adc edx, 0
    pop eax
    ret

; net_idle: keep the status-bar clock and the screen alive while waiting for
; the network - at most once per timer tick, so wait loops stay fast
net_idle:
    push eax
    mov eax, [ticks]
    cmp eax, [net_idle_tick]
    je .r
    mov [net_idle_tick], eax
    call status_tick
    call screen_present
.r: pop eax
    ret

; ring_in: EAX = ring, EDX = its size (a power of two), EBX = offset in it,
; ESI = data, ECX = length (<= size). Copies the data in, wrapping at the
; end. Registers kept.
ring_in:
    pushad
    lea ebp, [edx - 1]                  ; (size - 1 as a mask)
    and ebx, ebp
    mov ebp, edx
    sub ebp, ebx                        ; EBP = room before the end
    lea edi, [eax + ebx]
    cmp ecx, ebp
    jbe .one
    push ecx
    mov ecx, ebp
    call net_copy
    pop ecx
    sub ecx, ebp
    mov edi, eax
.one:
    call net_copy
    popad
    ret

; ring_out: EAX = ring, EDX = size, EBX = offset, EDI = destination,
; ECX = length. Copies out of the ring. Registers kept.
ring_out:
    pushad
    lea ebp, [edx - 1]
    and ebx, ebp
    mov ebp, edx
    sub ebp, ebx
    lea esi, [eax + ebx]
    cmp ecx, ebp
    jbe .one
    push ecx
    mov ecx, ebp
    call net_copy
    pop ecx
    sub ecx, ebp
    mov esi, eax
.one:
    call net_copy
    popad
    ret

; ----------------------------------------------------------- sending
; tcp_emit: build a segment and send it. AL = flags, EBX = sequence number,
; ESI = data, ECX = data length; tx_dip / tx_sport / tx_dport / tx_ack /
; tx_win say where it goes; tcp_opt_len bytes of tcp_opts become TCP options
; (and are used up). Registers kept.
tcp_emit:
    call tcp_lose                       ; ("net loss": thrown away instead)
    jnc .send
    mov byte [tcp_opt_len], 0
    ret
.send:
    pushad
    mov edi, NET_TXP
    mov [edi + 13], al                  ; flags
    mov ax, [tx_sport]
    xchg al, ah
    mov [edi], ax
    mov ax, [tx_dport]
    xchg al, ah
    mov [edi + 2], ax
    bswap ebx
    mov [edi + 4], ebx
    mov eax, [tx_ack]
    bswap eax
    mov [edi + 8], eax
    mov eax, [tx_win]
    xchg al, ah
    mov [edi + 14], ax
    mov dword [edi + 16], 0             ; checksum, urgent pointer
    movzx edx, byte [tcp_opt_len]
    lea eax, [edx + 20]                 ; header length / 4, in the top nibble
    shl eax, 2
    mov [edi + 12], al
    push esi
    push ecx
    lea edi, [NET_TXP + 20]
    mov esi, tcp_opts
    mov ecx, edx
    rep movsb                           ; options
    pop ecx
    pop esi
    push ecx
    call net_copy                       ; data
    pop ecx
    mov byte [tcp_opt_len], 0
    lea ecx, [ecx + edx + 20]           ; segment length
    mov ebp, ecx
    mov eax, [my_ip]
    mov ebx, [tx_dip]
    call tcp_pseudo_sum
    mov esi, NET_TXP
    call csum_add
    call csum_fold
    not eax
    mov [NET_TXP + 16], ax
    mov eax, [tx_dip]
    mov bl, IPPROTO_TCP
    mov esi, NET_TXP
    mov ecx, ebp
    call ip_send
    popad
    ret

; tcp_lose -> CF=1 if this segment is to be thrown away: the "net loss"
; test drops tcp_loss percent of the segments sent and received, picked at
; random, so that retransmission and reordering can be tried on a network
; that loses nothing. CF=0 when the test is off. Registers kept.
tcp_lose:
    cmp byte [tcp_loss], 0
    je .keep
    push eax
    push ecx
    push edx
    mov eax, [tcp_lrand]                ; the next pseudo-random number
    imul eax, eax, 1103515245
    add eax, 12345
    mov [tcp_lrand], eax
    shr eax, 8
    and eax, 0xFFFF
    xor edx, edx
    mov ecx, 100
    div ecx                             ; EDX = 0..99
    movzx eax, byte [tcp_loss]
    cmp edx, eax                        ; CF=1 if below the percentage
    pop edx
    pop ecx
    pop eax
    ret
.keep:
    clc
    ret

; tcp_window -> EAX = the window field to send: the ring's free space,
; scaled down by our window scale, at most 65535. rcv_adv = that in bytes.
tcp_window:
    push ecx
    mov eax, [rcv_nxt]
    sub eax, [rcv_rd]                   ; bytes waiting for the reader
    neg eax
    add eax, RB_SIZE                    ; free
    mov cl, [rcv_shift]
    shr eax, cl
    cmp eax, 0xFFFF
    jbe .ok
    mov eax, 0xFFFF
.ok:
    push eax
    shl eax, cl
    mov [rcv_adv], eax
    pop eax
    pop ecx
    ret

; tcp_xmit: send a segment of our connection. AL = flags, EBX = sequence
; number, ESI = data, ECX = length. Registers kept.
tcp_xmit:
    push eax
    push edx
    mov eax, [tcp_dst_ip]
    mov [tx_dip], eax
    mov ax, [tcp_src_port]
    mov [tx_sport], ax
    mov ax, [tcp_dst_port]
    mov [tx_dport], ax
    mov eax, [rcv_nxt]                  ; (+1 for the server's FIN, which
    movzx edx, byte [tcp_fin_in]        ; takes a sequence number but is
    add eax, edx                        ; not data in the ring)
    mov [tx_ack], eax
    call tcp_window
    mov [tx_win], eax
    pop edx
    pop eax
    test al, TCP_ACK                    ; (the SYN acknowledges nothing)
    jnz .go
    mov dword [tx_ack], 0
.go:
    jmp tcp_emit

; tcp_send_ack: acknowledge everything received so far (with our window)
tcp_send_ack:
    cmp byte [tcp_estab], 0
    je .r
    cmp byte [tcp_reset], 0
    jne .r
    push eax
    push ebx
    push ecx
    call tcp_sack_opts                  ; (what came after a gap)
    mov al, TCP_ACK
    mov ebx, [snd_nxt]
    xor ecx, ecx
    call tcp_xmit
    mov dword [ack_owed], 0
    mov byte [ack_now], 0
    pop ecx
    pop ebx
    pop eax
.r: ret

; tcp_sack_opts: if the server takes SACK and data is waiting after a gap,
; tcp_opts = SACK blocks for the next segment (RFC 2018): up to 4 ranges we
; hold, the one the latest segment went into first, then the others in
; order of position
tcp_sack_opts:
    cmp byte [sack_ok], 0
    je .r
    cmp dword [ooo_n], 0
    je .r
    pushad
    mov dword [tcp_opts], 0x00050101    ; NOP, NOP, kind 5 (length below)
    mov edi, tcp_opts + 4
    xor edx, edx                        ; EDX = blocks written
    mov ebp, -1                         ; EBP = the range written first
    mov eax, [ooo_recent]
    xor ebx, ebx
.find:                                  ; the range holding the latest data
    cmp ebx, [ooo_n]
    jae .rest
    mov ecx, eax
    sub ecx, [ooo_s + ebx * 4]
    js .fnext                           ; (it starts after that)
    mov ecx, eax
    sub ecx, [ooo_e + ebx * 4]
    jns .fnext                          ; (it ends before that)
    call .block
    mov ebp, ebx
    jmp .rest
.fnext:
    inc ebx
    jmp .find
.rest:
    xor ebx, ebx
.l: cmp ebx, [ooo_n]
    jae .done
    cmp edx, 4
    jae .done
    cmp ebx, ebp
    je .n
    call .block
.n: inc ebx
    jmp .l
.done:
    lea eax, [edx * 8 + 2]
    mov [tcp_opts + 3], al              ; the option's length
    add eax, 2
    mov [tcp_opt_len], al
    popad
.r: ret
; .block: range EBX as a block (two big-endian sequence numbers) at EDI
.block:
    mov ecx, [ooo_s + ebx * 4]
    bswap ecx
    mov [edi], ecx
    mov ecx, [ooo_e + ebx * 4]
    bswap ecx
    mov [edi + 4], ecx
    add edi, 8
    inc edx
    ret

; tcp_send_syn: (re)send our SYN with the MSS, window-scale and
; SACK-permitted options
tcp_send_syn:
    pushad
    mov dword [tcp_opts], 0xB4050402    ; MSS = 1460 (02 04 05 B4)
    mov dword [tcp_opts + 4], RCV_WSHIFT << 24 | 0x030301   ; NOP, window scale
    mov dword [tcp_opts + 8], 0x02040101    ; NOP, NOP, SACK-permitted (4, 2)
    mov byte [tcp_opt_len], 12
    mov al, TCP_SYN
    mov ebx, [snd_iss]
    xor ecx, ecx
    call tcp_xmit
    popad
    ret

; tcp_arm: start the retransmission timer if it is not running
tcp_arm:
    cmp dword [rtx_at], 0
    jne .r
    push eax
    mov eax, [ticks]
    add eax, [tcp_rto]
    or eax, 1                           ; (0 means "off")
    mov [rtx_at], eax
    pop eax
.r: ret

; tcp_output: send whatever the server's window allows: queued data from
; snd_nxt in segments of up to snd_mss, then our FIN once everything before
; it has gone. Starts the retransmission timer and the round-trip timing.
tcp_output:
    pushad
    cmp byte [tcp_estab], 0
    je .done
    cmp byte [tcp_reset], 0
    jne .done
.next:
    mov edx, [snd_wnd]                  ; EDX = right edge of the window
    test edx, edx
    jnz .w
    movzx edx, byte [tcp_force]         ; (1 when probing a zero window)
.w: add edx, [snd_una]
    mov ebx, [snd_nxt]
    mov ecx, [snd_end]
    sub ecx, ebx                        ; queued but not yet sent
    test ecx, ecx                       ; (the sign of the difference counts,
    jle .fin                            ; not a signed compare: see the top)
    mov eax, edx
    sub eax, ebx                        ; room in the window
    test eax, eax
    jle .done
    cmp ecx, eax
    jbe .c1
    mov ecx, eax
.c1:
    cmp ecx, [snd_mss]
    jbe .c2
    mov ecx, [snd_mss]
.c2:
    push ebx                            ; the bytes, out of the send ring
    sub ebx, [snd_iss]
    dec ebx
    mov eax, TCP_SBUF
    mov edx, SB_SIZE
    mov edi, TCP_TXTMP
    call ring_out
    pop ebx
    mov al, TCP_ACK | TCP_PSH
    mov esi, TCP_TXTMP
    call tcp_xmit
    mov eax, ebx                        ; new data (not a retransmission)?
    sub eax, [snd_max]
    js .old
    cmp byte [rtt_on], 0                ; time it, if nothing else is timed
    jne .old
    mov byte [rtt_on], 1
    mov [rtt_seq], ebx
    mov eax, [ticks]
    mov [rtt_t0], eax
.old:
    add ebx, ecx
    mov [snd_nxt], ebx
    mov eax, ebx
    sub eax, [snd_max]
    test eax, eax
    jle .nomax
    mov [snd_max], ebx
.nomax:
    call tcp_arm
    jmp .next
.fin:
    cmp byte [tcp_fin_q], 0
    je .done
    mov ebx, [snd_nxt]                  ; FIN not sent yet from here?
    cmp ebx, [snd_end]
    jne .done
    mov al, TCP_ACK | TCP_FIN
    xor ecx, ecx
    call tcp_xmit
    inc ebx
    mov [snd_nxt], ebx
    mov eax, ebx
    sub eax, [snd_max]
    test eax, eax
    jle .finmax
    mov [snd_max], ebx
.finmax:
    call tcp_arm
.done:
    mov eax, [snd_end]                  ; data the window holds back: the timer
    sub eax, [snd_nxt]                  ; also probes a window that stays shut
    test eax, eax
    jle .out
    call tcp_arm
.out:
    popad
    ret

; tcp_timer: retransmit when the timer has run out (called by tcp_poll)
tcp_timer:
    pushad
    cmp byte [tcp_on], 0
    je .done
    cmp byte [tcp_reset], 0
    jne .done
    mov eax, [rtx_at]
    test eax, eax
    jz .done
    mov edx, [ticks]
    sub edx, eax
    js .done                            ; not yet
    mov byte [rtt_on], 0                ; (Karn: never time a resent byte)
    inc dword [rtx_n]
    mov eax, [tcp_rto]                  ; back off: double the timeout
    add eax, eax
    cmp byte [tcp_estab], 0
    jne .est
    cmp eax, SYN_RTO_MAX                ; --- the SYN
    jbe .s1
    mov eax, SYN_RTO_MAX
.s1:
    mov [tcp_rto], eax
    cmp dword [rtx_n], SYN_TRIES
    jae .give_up
    call tcp_send_syn
    jmp .rearm
.est:
    cmp eax, RTO_MAX
    jbe .e1
    mov eax, RTO_MAX
.e1:
    mov [tcp_rto], eax
    mov eax, [snd_una]
    cmp eax, [snd_max]
    jne .resend
    ; nothing unacknowledged: the timer was probing a zero window
    mov eax, [snd_end]
    sub eax, [snd_nxt]
    test eax, eax
    jle .stop                           ; (and nothing waits to be sent)
    mov dword [rtx_n], 0                ; probes never give up by themselves
    mov byte [tcp_force], 1
    mov dword [rtx_at], 0
    call tcp_output
    mov byte [tcp_force], 0
    jmp .rearm
.resend:
    cmp dword [rtx_n], RTX_TRIES
    ja .give_up
    mov [snd_nxt], eax                  ; go back to the oldest unacked byte
    mov dword [rtx_at], 0
    mov byte [tcp_force], 1
    call tcp_output
    mov byte [tcp_force], 0
.rearm:
    mov eax, [ticks]
    add eax, [tcp_rto]
    or eax, 1
    mov [rtx_at], eax
    jmp .done
.stop:
    mov dword [rtx_at], 0
    jmp .done
.give_up:
    mov byte [tcp_reset], 1
    mov dword [tcp_err], TE_TIMEOUT
.done:
    popad
    ret

; tcp_rtt_sample: EAX = a measured round trip (ticks) -> new tcp_rto
; (RFC 6298, in fixed point: srtt x 8, rttvar x 4)
tcp_rtt_sample:
    pushad
    cmp byte [rtt_have], 0
    jne .update
    mov byte [rtt_have], 1
    lea edx, [eax * 8]
    mov [tcp_srtt8], edx
    lea edx, [eax * 2]
    mov [tcp_rttvar4], edx
    jmp .rto
.update:
    mov edx, [tcp_srtt8]
    shr edx, 3
    sub eax, edx                        ; delta = sample - srtt
    add [tcp_srtt8], eax                ; srtt += delta / 8
    test eax, eax
    jns .pos
    neg eax
.pos:
    mov edx, [tcp_rttvar4]
    shr edx, 2
    sub eax, edx
    add [tcp_rttvar4], eax              ; rttvar += (|delta| - rttvar) / 4
.rto:
    mov eax, [tcp_srtt8]
    shr eax, 3
    add eax, [tcp_rttvar4]              ; srtt + 4 x rttvar
    cmp eax, RTO_MIN
    jge .lo
    mov eax, RTO_MIN
.lo:
    cmp eax, RTO_MAX
    jle .hi
    mov eax, RTO_MAX
.hi:
    mov [tcp_rto], eax
    popad
    ret

; ------------------------------------------------------- the connection
; tcp_connect: EAX = server IP, BX = port -> CF=0 when connected; CF=1 if
; the server refused or never answered (tcp_err says which)
tcp_connect:
    pushad
    call tcp_forget
    mov [tcp_dst_ip], eax
    mov [tcp_dst_port], bx
    mov eax, [tcp_port_seq]             ; a new local port for every connection
    test eax, eax
    jnz .port
    rdtsc
.port:
    inc eax
    and eax, 0x3FFF
    jnz .p1
    inc eax
.p1:
    mov [tcp_port_seq], eax
    add eax, 49152
    mov [tcp_src_port], ax
    xor eax, eax                        ; a fresh state
    mov edi, snd_iss
    mov ecx, (rtx_n + 4 - snd_iss) / 4
    rep stosd
    mov dword [ooo_n], 0
    mov byte [tcp_fin_in], 0
    mov byte [tcp_reset], 0
    mov byte [tcp_fin_q], 0
    mov byte [tcp_fin_acked], 0
    mov byte [fin_known], 0
    mov byte [rtt_have], 0
    mov byte [snd_shift], 0
    mov byte [rcv_shift], 0
    mov byte [sack_ok], 0
    mov byte [ack_now], 0
    mov byte [tcp_force], 0
    mov byte [tcp_estab], 0
    mov dword [tcp_err], TE_NONE
    mov dword [snd_mss], 536
    mov dword [tcp_rto], RTO_INIT
    rdtsc                               ; our initial sequence number
    mov [snd_iss], eax
    mov [snd_una], eax
    mov [rtt_seq], eax
    inc eax
    mov [snd_nxt], eax
    mov [snd_max], eax
    mov [snd_end], eax
    mov eax, [ticks]
    mov [rtt_t0], eax
    mov [tcp_last_rx], eax
    mov byte [rtt_on], 1
    mov byte [tcp_on], 1
    call tcp_send_syn
    call tcp_arm
.wait:
    call tcp_poll                       ; the SYN-ACK, or a retransmission
    cmp byte [tcp_estab], 0
    jne .ok
    cmp byte [tcp_reset], 0
    jne .fail
    call net_idle
    jmp .wait
.ok:
    popad
    clc
    ret
.fail:
    mov byte [tcp_on], 0
    popad
    stc
    ret

; tcp_forget: drop the connection without telling the server
tcp_forget:
    mov byte [tcp_on], 0
    mov byte [tcp_estab], 0
    ret

; tcp_close: queue our FIN (after any data still queued) and send it
tcp_close:
    cmp byte [tcp_on], 0
    je .r
    cmp byte [tcp_fin_q], 0
    jne .r
    mov byte [tcp_fin_q], 1
    call tcp_output
.r: ret

; tcp_abort: reset the connection (we will read no more) and forget it
tcp_abort:
    cmp byte [tcp_on], 0
    je .r
    cmp byte [tcp_estab], 0
    je .forget
    cmp byte [tcp_reset], 0
    jne .forget
    pushad
    mov al, TCP_RST | TCP_ACK
    mov ebx, [snd_max]
    xor ecx, ecx
    call tcp_xmit
    popad
.forget:
    call tcp_forget
.r: ret

; tcp_linger: EAX = ticks to wait at most. After tcp_close: keep answering
; until our FIN is acknowledged and the server's FIN is in (or the time is
; up, or the connection was reset). Then the connection is forgotten.
tcp_linger:
    pushad
    add eax, [ticks]
    mov ebp, eax
.l: cmp byte [tcp_on], 0
    je .done
    cmp byte [tcp_reset], 0
    jne .done
    cmp byte [tcp_fin_acked], 0
    je .wait
    cmp byte [tcp_fin_in], 0
    jne .done
.wait:
    mov eax, [ticks]
    sub eax, ebp
    jns .done
    call tcp_poll
    mov eax, [rcv_nxt]                  ; (throw away data nobody will read)
    mov [rcv_rd], eax
    call net_idle
    jmp .l
.done:
    call tcp_forget
    popad
    ret

; tcp_avail -> EAX = bytes in order, waiting for the reader
tcp_avail:
    mov eax, [rcv_nxt]
    sub eax, [rcv_rd]
    ret

; tcp_peek: EDI = destination, ECX = length (<= tcp_avail) -> the next bytes
; copied without taking them. Registers kept.
tcp_peek:
    pushad
    mov ebx, [rcv_rd]
    sub ebx, [rcv_irs]
    dec ebx
    mov eax, TCP_RBUF
    mov edx, RB_SIZE
    call ring_out
    popad
    ret

; tcp_read: EDI = destination, ECX = most bytes wanted -> EAX = bytes taken
; out of the receive ring (0 if none). Sends a window update when this
; frees a good amount of room. Other registers kept.
tcp_read:
    push ecx
    push edx
    mov eax, [rcv_nxt]
    sub eax, [rcv_rd]
    cmp ecx, eax
    jbe .n
    mov ecx, eax
.n: jecxz .none
    call tcp_peek
    add [rcv_rd], ecx
    mov edx, ecx
    ; window update: when the window has grown by a quarter of the ring, or
    ; the server was nearly stopped and now has room for 2 segments
    cmp byte [tcp_estab], 0
    je .ret
    cmp byte [tcp_fin_in], 0
    jne .ret
    push edx
    push ecx
    mov eax, [rcv_nxt]
    sub eax, [rcv_rd]
    neg eax
    add eax, RB_SIZE                    ; free now
    mov cl, [rcv_shift]
    shr eax, cl
    cmp eax, 0xFFFF
    jbe .w
    mov eax, 0xFFFF
.w: shl eax, cl                         ; the window we would advertise
    mov edx, eax
    sub edx, [rcv_adv]                  ; growth since the last one
    cmp edx, RB_SIZE / 4
    jge .update
    cmp dword [rcv_adv], 2 * TCP_MSS
    jae .no
    cmp eax, 2 * TCP_MSS
    jb .no
.update:
    call tcp_send_ack
.no:
    pop ecx
    pop edx
.ret:
    mov eax, edx
    pop edx
    pop ecx
    ret
.none:
    xor eax, eax
    pop edx
    pop ecx
    ret

; tcp_recv: EDI = destination, ECX = most bytes -> EAX = bytes taken (> 0),
; 0 if none yet, -1 at the end (the server's FIN), -2 if the connection
; broke (reset, timed out)
tcp_recv:
    call tcp_read
    test eax, eax
    jnz .r
    cmp byte [tcp_fin_in], 0
    jne .eof
    cmp byte [tcp_reset], 0
    jne .err
    cmp byte [tcp_on], 0
    je .err
.r: ret
.eof:
    mov eax, -1
    ret
.err:
    mov eax, -2
    ret

; tcp_wait_avail: EAX = bytes wanted, EDX = most ticks to wait while no
; segment arrives -> CF=0 once that many bytes are waiting; CF=1 if the
; connection ended first (EAX = -1 at its end, -2 broken or timed out).
; EDX changed.
tcp_wait_avail:
    push ebx
    push ecx
    push esi
    mov ebx, eax
    mov esi, edx                        ; ESI = the quiet time allowed
    mov ecx, [ticks]                    ; ECX = when the wait began
.l: call tcp_avail
    cmp eax, ebx
    jae .ok
    cmp byte [tcp_fin_in], 0
    jne .eof
    cmp byte [tcp_reset], 0
    jne .err
    cmp byte [tcp_on], 0
    je .err
    call tcp_poll
    mov eax, [ticks]                    ; quiet since the later of the start
    mov edx, [tcp_last_rx]              ; and the last segment
    sub edx, ecx
    js .from_start
    mov ecx, [tcp_last_rx]
.from_start:
    sub eax, ecx
    cmp eax, esi
    jae .err
    call net_idle
    jmp .l
.ok:
    pop esi
    pop ecx
    pop ebx
    clc
    ret
.eof:
    mov eax, -1
    pop esi
    pop ecx
    pop ebx
    stc
    ret
.err:
    mov eax, -2
    pop esi
    pop ecx
    pop ebx
    stc
    ret

; tcp_send: ESI = data, ECX = length. Queues it (waiting for room when the
; send ring is full) and sends what the window allows. CF=1 if the
; connection broke or nothing moved for 30 s.
tcp_send:
    pushad
    mov ebp, [ticks]                    ; EBP = when room was last found
.l: test ecx, ecx
    jz .ok
    cmp byte [tcp_reset], 0
    jne .fail
    cmp byte [tcp_on], 0
    je .fail
    mov eax, [snd_end]
    sub eax, [snd_una]
    neg eax
    add eax, SB_SIZE                    ; room in the send ring
    jnz .room
    call tcp_poll
    call net_idle
    mov eax, [ticks]
    sub eax, ebp
    cmp eax, 3000
    jb .l
    jmp .fail
.room:
    cmp eax, ecx
    jbe .n
    mov eax, ecx
.n: push eax
    push ecx
    mov ecx, eax
    mov ebx, [snd_end]
    sub ebx, [snd_iss]
    dec ebx
    mov eax, TCP_SBUF
    mov edx, SB_SIZE
    call ring_in
    pop ecx
    pop eax
    add [snd_end], eax
    add esi, eax
    sub ecx, eax
    mov ebp, [ticks]
    call tcp_output
    jmp .l
.ok:
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

; --------------------------------------------------------- receiving
; tcp_poll: handle every frame waiting in the network card (up to
; TCP_BATCH), acknowledge what arrived, and run the retransmission timer.
; Never waits. Registers kept.
tcp_poll:
    pushad
    mov ebp, TCP_BATCH
.l: call net_rx_poll
    jc .idle
    mov esi, [rx_frame]
    mov ecx, [rx_len]
    call tcp_rx_frame
    dec ebp
    jnz .l
.idle:
    cmp byte [tcp_on], 0
    je .done
    cmp dword [ack_owed], 0
    je .t
    call tcp_send_ack
.t: call tcp_timer
.done:
    popad
    ret

; tcp_rx_frame: ESI = a received Ethernet frame, ECX = its length. ARP is
; answered; a TCP segment for our address goes on to tcp_input; anything
; else is dropped. Registers kept.
tcp_rx_frame:
    pushad
    cmp ecx, ETH_HLEN + 20
    jb .done
    mov ax, [esi + 12]
    cmp ax, 0x0608                      ; ARP (0x0806 big-endian)
    jne .not_arp
    call arp_handle
    jmp .done
.not_arp:
    cmp ax, 0x0008                      ; IPv4
    jne .done
    lea ebx, [esi + ETH_HLEN]           ; EBX = IP header
    sub ecx, ETH_HLEN
    movzx eax, byte [ebx]
    mov dl, al
    and dl, 0xF0
    cmp dl, 0x40                        ; version 4
    jne .done
    and eax, 0x0F
    shl eax, 2                          ; header length
    cmp eax, 20
    jb .done
    movzx edx, word [ebx + 2]           ; total length
    xchg dl, dh
    cmp edx, ecx
    ja .done                            ; longer than the frame
    cmp edx, eax
    jb .done
    test word [ebx + 6], 0xFF3F         ; a fragment (MF or an offset)
    jnz .done
    cmp byte [ebx + 9], IPPROTO_TCP
    jne .done
    mov edi, [ebx + 16]
    cmp edi, [my_ip]
    jne .done
    push edx                            ; the header checksum
    push eax
    mov esi, ebx
    mov ecx, eax
    xor edx, edx
    call csum_add
    call csum_fold
    cmp ax, 0xFFFF
    pop eax
    pop edx
    jne .done
    call tcp_input
.done:
    popad
    ret

; tcp_input: EBX = IP header, EAX = its length, EDX = IP total length.
; Checks the TCP segment and handles it.
tcp_input:
    lea esi, [ebx + eax]                ; ESI = TCP header
    sub edx, eax                        ; EDX = segment length
    cmp edx, 20
    jb .r
    movzx ecx, byte [esi + 12]
    shr ecx, 4
    shl ecx, 2                          ; ECX = TCP header length
    cmp ecx, 20
    jb .r
    cmp ecx, edx
    ja .r
    push esi                            ; checksum over pseudo-header + segment
    push ecx
    push edx
    push ebx
    mov eax, [ebx + 12]
    mov ebx, [ebx + 16]
    mov ecx, edx
    call tcp_pseudo_sum                 ; EDX = pseudo sum
    call csum_add
    call csum_fold
    pop ebx
    pop edx
    pop ecx
    pop esi
    cmp ax, 0xFFFF
    jne .r
    mov [seg_hdr], esi
    mov [seg_hlen], ecx
    lea eax, [esi + ecx]
    mov [seg_data], eax
    sub edx, ecx
    mov [seg_len], edx
    mov eax, [esi + 4]
    bswap eax
    mov [seg_seq], eax
    mov eax, [esi + 8]
    bswap eax
    mov [seg_ack], eax
    movzx eax, word [esi + 14]
    xchg al, ah
    mov [seg_win], eax
    mov eax, [ebx + 12]
    mov [seg_sip], eax
    movzx eax, word [esi]
    xchg al, ah
    mov [seg_sport], eax
    movzx eax, word [esi + 2]
    xchg al, ah
    mov [seg_dport], eax
    ; ours?
    cmp byte [tcp_on], 0
    je .stray
    mov eax, [seg_sip]
    cmp eax, [tcp_dst_ip]
    jne .stray
    mov eax, [seg_sport]
    cmp ax, [tcp_dst_port]
    jne .stray
    mov eax, [seg_dport]
    cmp ax, [tcp_src_port]
    jne .stray
    call tcp_lose                       ; ("net loss": as if it never came)
    jc .r
    mov eax, [ticks]
    mov [tcp_last_rx], eax
    cmp byte [tcp_reset], 0
    jne .r
    cmp byte [tcp_estab], 0
    je tcp_in_synsent
    jmp tcp_in_estab
.stray:
    mov esi, [seg_hdr]
    test byte [esi + 13], TCP_RST       ; never answer a reset
    jnz .r
    call tcp_rst_reply
.r: ret

; tcp_rst_reply: answer the segment in seg_* (not part of our connection)
; with a reset, as RFC 9293 says for a closed port
tcp_rst_reply:
    pushad
    mov eax, [seg_sip]
    mov [tx_dip], eax
    mov eax, [seg_dport]
    mov [tx_sport], ax
    mov eax, [seg_sport]
    mov [tx_dport], ax
    mov dword [tx_win], 0
    mov esi, [seg_hdr]
    mov dl, [esi + 13]
    test dl, TCP_ACK
    jz .noack
    mov ebx, [seg_ack]                  ; <SEQ=SEG.ACK><CTL=RST>
    mov dword [tx_ack], 0
    mov al, TCP_RST
    jmp .send
.noack:
    mov eax, [seg_seq]                  ; <SEQ=0><ACK=SEG.SEQ+SEG.LEN>
    add eax, [seg_len]
    test dl, TCP_SYN
    jz .s
    inc eax
.s: test dl, TCP_FIN
    jz .f
    inc eax
.f: mov [tx_ack], eax
    xor ebx, ebx
    mov al, TCP_RST | TCP_ACK
.send:
    xor ecx, ecx
    mov byte [tcp_opt_len], 0
    call tcp_emit
    popad
    ret

; tcp_in_synsent: a segment while our SYN waits for its answer
tcp_in_synsent:
    mov esi, [seg_hdr]
    mov dl, [esi + 13]                  ; DL = flags
    test dl, TCP_ACK
    jz .noack
    mov eax, [seg_ack]                  ; it must acknowledge our SYN
    cmp eax, [snd_nxt]
    jne .badack
.noack:
    test dl, TCP_RST
    jz .norst
    test dl, TCP_ACK                    ; a reset that answers our SYN: refused
    jz .r
    mov byte [tcp_reset], 1
    mov dword [tcp_err], TE_REFUSED
    ret
.norst:
    test dl, TCP_SYN
    jz .r
    test dl, TCP_ACK
    jz .r                               ; (simultaneous open: not for a client)
    mov eax, [seg_seq]
    mov [rcv_irs], eax
    inc eax
    mov [rcv_nxt], eax
    mov [rcv_rd], eax
    mov eax, [seg_ack]
    mov [snd_una], eax
    mov eax, [seg_win]                  ; (the window in a SYN is never scaled)
    mov [snd_wnd], eax
    mov eax, [seg_seq]
    mov [snd_wl1], eax
    mov eax, [seg_ack]
    mov [snd_wl2], eax
    call tcp_parse_opts
    mov byte [tcp_estab], 1
    cmp dword [rtx_n], 0                ; round trip of the SYN (if not resent)
    jne .nortt
    mov eax, [ticks]
    sub eax, [rtt_t0]
    call tcp_rtt_sample
.nortt:
    mov byte [rtt_on], 0
    mov dword [rtx_at], 0
    mov dword [rtx_n], 0
    call tcp_send_ack
    ret
.badack:
    test dl, TCP_RST
    jnz .r
    call tcp_rst_reply
.r: ret

; tcp_parse_opts: read the SYN-ACK's options (seg_hdr): MSS, window scale
; and SACK-permitted
tcp_parse_opts:
    pushad
    mov esi, [seg_hdr]
    mov ecx, [seg_hlen]
    lea edx, [esi + ecx]                ; EDX = end of the options
    add esi, 20
    mov dword [snd_mss], 536            ; (the default without the option)
    xor ebx, ebx                        ; BL = 1 if window scaling was offered
.l: cmp esi, edx
    jae .end
    mov al, [esi]
    cmp al, 0                           ; end of options
    je .end
    cmp al, 1                           ; no-op
    jne .long
    inc esi
    jmp .l
.long:
    lea edi, [esi + 1]
    cmp edi, edx
    jae .end
    movzx ecx, byte [esi + 1]           ; option length
    cmp ecx, 2
    jb .end
    lea edi, [esi + ecx]
    cmp edi, edx
    ja .end
    cmp al, 2                           ; MSS
    jne .not_mss
    cmp ecx, 4
    jne .next
    movzx eax, word [esi + 2]
    xchg al, ah
    cmp eax, 64
    jb .next
    mov [snd_mss], eax
    jmp .next
.not_mss:
    cmp al, 4                           ; SACK-permitted
    jne .not_sack
    mov byte [sack_ok], 1
    jmp .next
.not_sack:
    cmp al, 3                           ; window scale
    jne .next
    cmp ecx, 3
    jne .next
    mov al, [esi + 2]
    cmp al, 14
    jbe .ws
    mov al, 14
.ws:
    mov [snd_shift], al
    mov bl, 1
.next:
    add esi, ecx
    jmp .l
.end:
    cmp dword [snd_mss], TCP_MSS
    jbe .m
    mov dword [snd_mss], TCP_MSS
.m: test bl, bl                         ; scaling is on only if both sides
    jz .noscale                         ; asked for it
    mov byte [rcv_shift], RCV_WSHIFT
    jmp .done
.noscale:
    mov byte [snd_shift], 0
    mov byte [rcv_shift], 0
.done:
    popad
    ret

; tcp_in_estab: a segment of the open connection
tcp_in_estab:
    mov esi, [seg_hdr]
    movzx edx, byte [esi + 13]          ; EDX = flags (kept to the end)
    test dl, TCP_RST
    jz .not_rst
    mov eax, [seg_seq]                  ; a reset counts only in the window
    sub eax, [rcv_nxt]
    mov ecx, [rcv_adv]
    cmp ecx, 1
    adc ecx, 0                          ; (at least 1)
    cmp eax, ecx
    jae .r
    mov byte [tcp_reset], 1
    mov dword [tcp_err], TE_RESET
    ret
.not_rst:
    test dl, TCP_SYN                    ; their SYN again: our ACK got lost
    jz .not_syn
    mov byte [ack_now], 1
    jmp .finish
.not_syn:
    test dl, TCP_ACK
    jz .r
    ; ---------------------------------------------------- the ACK field
    mov eax, [seg_ack]
    mov ecx, eax
    sub ecx, [snd_max]
    test ecx, ecx
    jle .ack_ok
    mov byte [ack_now], 1               ; acknowledges what we never sent
    jmp .finish
.ack_ok:
    mov ecx, eax
    sub ecx, [snd_una]
    test ecx, ecx
    jle .wnd                            ; nothing new acknowledged
    mov [snd_una], eax
    mov ecx, [snd_nxt]
    sub ecx, eax
    jns .nx
    mov [snd_nxt], eax
.nx:
    cmp byte [tcp_fin_q], 0             ; our FIN acknowledged?
    je .nofin
    mov ecx, [snd_end]
    inc ecx
    cmp eax, ecx
    jne .nofin
    mov byte [tcp_fin_acked], 1
.nofin:
    cmp byte [rtt_on], 0                ; the timed byte acknowledged?
    je .nortt
    mov ecx, eax
    sub ecx, [rtt_seq]
    test ecx, ecx
    jle .nortt
    mov byte [rtt_on], 0
    push eax
    mov eax, [ticks]
    sub eax, [rtt_t0]
    call tcp_rtt_sample
    pop eax
.nortt:
    mov dword [rtx_n], 0
    mov dword [rtx_at], 0
    cmp eax, [snd_max]
    je .wnd
    call tcp_arm                        ; more is outstanding: time it again
.wnd:
    ; the server's window (only from a segment at least as new as the last)
    mov eax, [seg_seq]
    mov ecx, eax
    sub ecx, [snd_wl1]
    test ecx, ecx
    jg .take_wnd
    jl .data
    mov ecx, [seg_ack]
    sub ecx, [snd_wl2]
    test ecx, ecx
    jl .data
.take_wnd:
    mov [snd_wl1], eax
    mov eax, [seg_ack]
    mov [snd_wl2], eax
    mov eax, [seg_win]
    mov cl, [snd_shift]
    shl eax, cl
    mov [snd_wnd], eax
.data:
    ; ------------------------------------------------- data and FIN
    mov ebx, [seg_seq]                  ; EBX = where the data starts
    mov ecx, [seg_len]                  ; ECX = its length
    mov esi, [seg_data]
    test dl, TCP_FIN
    jz .nofinflag
    lea eax, [ebx + ecx]                ; the FIN comes after the data
    mov [fin_seq], eax
    mov byte [fin_known], 1
    cmp byte [tcp_fin_in], 0            ; their FIN again: our ACK of it
    je .nofinflag                       ; was lost, so say it again
    mov byte [ack_now], 1
.nofinflag:
    test ecx, ecx
    jz .data_done
    cmp byte [tcp_fin_in], 0
    jne .data_done                      ; (data after the FIN: ignored)
    mov eax, ebx
    sub eax, [rcv_nxt]                  ; EAX = offset from what we expect
    jns .not_old
    add eax, ecx                        ; starts before: drop what we have
    test eax, eax
    jle .dup
    sub ecx, eax                        ; ECX = bytes to skip
    add esi, ecx
    add ebx, ecx
    mov ecx, eax
    xor eax, eax
.not_old:
    mov edi, [rcv_nxt]                  ; room in the ring after rcv_nxt
    sub edi, [rcv_rd]
    neg edi
    add edi, RB_SIZE
    cmp eax, edi
    jae .dup                            ; all beyond the window
    push eax
    add eax, ecx
    cmp eax, edi
    pop eax
    jbe .fits
    mov ecx, edi                        ; keep only what fits
    sub ecx, eax
.fits:
    push eax                            ; into its place in the ring
    push ebx
    sub ebx, [rcv_irs]
    dec ebx
    push edx
    mov eax, TCP_RBUF
    mov edx, RB_SIZE
    call ring_in
    pop edx
    pop ebx
    pop eax
    test eax, eax
    jnz .early
    add [rcv_nxt], ecx                  ; in order
    add [ack_owed], ecx
    cmp dword [ooo_n], 0
    je .ackcount
    call ooo_merge                      ; a gap filled: join the ranges on
    mov byte [ack_now], 1
.ackcount:
    cmp dword [ack_owed], 2 * TCP_MSS   ; acknowledge every second segment
    jb .data_done
    mov byte [ack_now], 1
    jmp .data_done
.early:
    lea eax, [ebx + ecx]                ; after a gap: remember the range
    call ooo_add
    mov byte [ack_now], 1               ; and say again what we still need
    jmp .data_done
.dup:
    mov byte [ack_now], 1
.data_done:
    cmp byte [fin_known], 0             ; the FIN, once all before it is in
    je .finish
    cmp byte [tcp_fin_in], 0
    jne .finish
    mov eax, [rcv_nxt]
    cmp eax, [fin_seq]
    jne .finish
    mov byte [tcp_fin_in], 1            ; (rcv_nxt stays at the end of the
                                        ; data; tcp_xmit adds the FIN's 1)
    mov dword [ooo_n], 0
    mov byte [ack_now], 1
.finish:
    cmp byte [ack_now], 0
    je .out
    call tcp_send_ack
.out:
    call tcp_output                     ; the window may have opened
.r: ret

; ooo_add: EBX = start, EAX = end of a range that arrived early. Joins it
; with ranges it touches, or adds it (in order of position); dropped if the
; list is full.
ooo_add:
    pushad
    mov [ooo_recent], ebx               ; (SACK lists its range first)
    mov ebp, [rcv_nxt]
    sub ebx, ebp                        ; work with offsets from rcv_nxt
    sub eax, ebp
    mov ecx, [ooo_n]
    xor edi, edi
.find:                                  ; first range that ends at/after start
    cmp edi, ecx
    jae .insert
    mov edx, [ooo_e + edi * 4]
    sub edx, ebp
    cmp edx, ebx
    jae .found
    inc edi
    jmp .find
.found:
    mov edx, [ooo_s + edi * 4]
    sub edx, ebp
    cmp edx, eax
    ja .insert                          ; begins after our end: insert before
    ; overlaps or touches range EDI: widen it
    cmp ebx, edx
    jae .s_ok
    lea edx, [ebx + ebp]
    mov [ooo_s + edi * 4], edx
.s_ok:
    mov edx, [ooo_e + edi * 4]
    sub edx, ebp
    cmp eax, edx
    jbe .e_ok
    lea edx, [eax + ebp]
    mov [ooo_e + edi * 4], edx
.e_ok:
    ; it may now reach the ranges after it
.absorb:
    lea esi, [edi + 1]
    cmp esi, [ooo_n]
    jae .done
    mov edx, [ooo_s + esi * 4]
    sub edx, ebp
    mov eax, [ooo_e + edi * 4]
    sub eax, ebp
    cmp edx, eax
    ja .done
    mov edx, [ooo_e + esi * 4]          ; join range ESI into EDI
    sub edx, ebp
    cmp edx, eax
    jbe .rm
    lea eax, [edx + ebp]
    mov [ooo_e + edi * 4], eax
.rm:
    mov eax, esi
    call ooo_remove
    jmp .absorb
.insert:
    cmp ecx, OOO_MAX
    jae .done
    mov esi, ecx                        ; move the later ones up one place
.mv:
    cmp esi, edi
    jbe .put
    mov edx, [ooo_s + esi * 4 - 4]
    mov [ooo_s + esi * 4], edx
    mov edx, [ooo_e + esi * 4 - 4]
    mov [ooo_e + esi * 4], edx
    dec esi
    jmp .mv
.put:
    add ebx, ebp
    add eax, ebp
    mov [ooo_s + edi * 4], ebx
    mov [ooo_e + edi * 4], eax
    inc dword [ooo_n]
.done:
    popad
    ret

; ooo_remove: EAX = index of a range to take out of the list
ooo_remove:
    pushad
.l: lea ebx, [eax + 1]
    cmp ebx, [ooo_n]
    jae .done
    mov edx, [ooo_s + ebx * 4]
    mov [ooo_s + eax * 4], edx
    mov edx, [ooo_e + ebx * 4]
    mov [ooo_e + eax * 4], edx
    inc eax
    jmp .l
.done:
    dec dword [ooo_n]
    popad
    ret

; ooo_merge: rcv_nxt moved on: ranges it reached are now in order
ooo_merge:
    pushad
.l: cmp dword [ooo_n], 0
    je .done
    mov eax, [ooo_s]
    sub eax, [rcv_nxt]
    test eax, eax
    jg .done                            ; still a gap before the first range
    mov eax, [ooo_e]
    mov ecx, eax
    sub ecx, [rcv_nxt]
    test ecx, ecx
    jle .drop                           ; (all before rcv_nxt already)
    add [ack_owed], ecx
    mov [rcv_nxt], eax
.drop:
    xor eax, eax
    call ooo_remove
    jmp .l
.done:
    popad
    ret
