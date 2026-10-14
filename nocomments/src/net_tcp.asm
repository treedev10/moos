TCP_FIN     equ 0x01
TCP_SYN     equ 0x02
TCP_RST     equ 0x04
TCP_PSH     equ 0x08
TCP_ACK     equ 0x10

TCP_RBUF    equ NET_STREAM + 0x00000
RB_SIZE     equ 0x40000
TCP_SBUF    equ NET_STREAM + 0x40000
SB_SIZE     equ 0x10000
TCP_TXTMP   equ NET_STREAM + 0x78000

OOO_MAX     equ 8
RCV_WSHIFT  equ 2
TCP_MSS     equ 1460
RTO_INIT    equ 100
RTO_MIN     equ 20
RTO_MAX     equ 600
SYN_RTO_MAX equ 400
RTX_TRIES   equ 8
SYN_TRIES   equ 4
TCP_BATCH   equ 64

TE_NONE     equ 0
TE_REFUSED  equ 1
TE_RESET    equ 2
TE_TIMEOUT  equ 3

section .bss
alignb 4
tcp_dst_ip      resd 1
tcp_dst_port    resw 1
tcp_src_port    resw 1
tcp_port_seq    resd 1
tcp_err         resd 1

snd_iss         resd 1
snd_una         resd 1
snd_nxt         resd 1
snd_max         resd 1
snd_end         resd 1
snd_wnd         resd 1
snd_wl1         resd 1
snd_wl2         resd 1
snd_mss         resd 1

rcv_irs         resd 1
rcv_nxt         resd 1
rcv_rd          resd 1
rcv_adv         resd 1
fin_seq         resd 1
ack_owed        resd 1
ooo_n           resd 1
ooo_recent      resd 1
ooo_s           resd OOO_MAX + 1
ooo_e           resd OOO_MAX + 1

tcp_rto         resd 1
tcp_srtt8       resd 1
tcp_rttvar4     resd 1
rtt_seq         resd 1
rtt_t0          resd 1
rtx_at          resd 1
rtx_n           resd 1
tcp_last_rx     resd 1
net_idle_tick   resd 1

seg_seq         resd 1
seg_ack         resd 1
seg_len         resd 1
seg_data        resd 1
seg_win         resd 1
seg_hdr         resd 1
seg_hlen        resd 1
seg_sip         resd 1
seg_sport       resd 1
seg_dport       resd 1

tx_dip          resd 1
tx_ack          resd 1
tx_win          resd 1
tx_sport        resw 1
tx_dport        resw 1

tcp_on          resb 1
tcp_estab       resb 1
tcp_fin_in      resb 1
tcp_reset       resb 1
tcp_fin_q       resb 1
tcp_fin_acked   resb 1
fin_known       resb 1
rtt_on          resb 1
rtt_have        resb 1
snd_shift       resb 1
rcv_shift       resb 1
sack_ok         resb 1
ack_now         resb 1
ack_dup         resb 1
tcp_force       resb 1
tcp_opt_len     resb 1
tcp_loss        resb 1
tcp_opts        resb 40
alignb 4
tcp_lrand       resd 1

section .text

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

csum_add:
    push eax
    push ebx
    mov ebx, ecx
    shr ecx, 2
    clc
    jecxz .rest
.l: adc edx, [esi]
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

tcp_pseudo_sum:
    push eax
    xor edx, edx
    add edx, eax
    adc edx, ebx
    adc edx, 0
    mov eax, ecx
    xchg al, ah
    and eax, 0xFFFF
    add edx, eax
    adc edx, 0x0600
    adc edx, 0
    pop eax
    ret

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

ring_in:
    pushad
    lea ebp, [edx - 1]
    and ebx, ebp
    mov ebp, edx
    sub ebp, ebx
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

tcp_emit:
    call tcp_lose
    jnc .send
    mov byte [tcp_opt_len], 0
    ret
.send:
    pushad
    mov edi, NET_TXP
    mov [edi + 13], al
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
    mov dword [edi + 16], 0
    movzx edx, byte [tcp_opt_len]
    lea eax, [edx + 20]
    shl eax, 2
    mov [edi + 12], al
    push esi
    push ecx
    lea edi, [NET_TXP + 20]
    mov esi, tcp_opts
    mov ecx, edx
    rep movsb
    pop ecx
    pop esi
    push ecx
    call net_copy
    pop ecx
    mov byte [tcp_opt_len], 0
    lea ecx, [ecx + edx + 20]
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

tcp_lose:
    cmp byte [tcp_loss], 0
    je .keep
    push eax
    push ecx
    push edx
    mov eax, [tcp_lrand]
    imul eax, eax, 1103515245
    add eax, 12345
    mov [tcp_lrand], eax
    shr eax, 8
    and eax, 0xFFFF
    xor edx, edx
    mov ecx, 100
    div ecx
    movzx eax, byte [tcp_loss]
    cmp edx, eax
    pop edx
    pop ecx
    pop eax
    ret
.keep:
    clc
    ret

tcp_window:
    push ecx
    mov eax, [rcv_nxt]
    sub eax, [rcv_rd]
    neg eax
    add eax, RB_SIZE
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

tcp_xmit:
    push eax
    push edx
    mov eax, [tcp_dst_ip]
    mov [tx_dip], eax
    mov ax, [tcp_src_port]
    mov [tx_sport], ax
    mov ax, [tcp_dst_port]
    mov [tx_dport], ax
    mov eax, [rcv_nxt]
    movzx edx, byte [tcp_fin_in]
    add eax, edx
    mov [tx_ack], eax
    call tcp_window
    mov [tx_win], eax
    pop edx
    pop eax
    test al, TCP_ACK
    jnz .go
    mov dword [tx_ack], 0
.go:
    jmp tcp_emit

tcp_send_ack:
    cmp byte [tcp_estab], 0
    je .r
    cmp byte [tcp_reset], 0
    jne .r
    push eax
    push ebx
    push ecx
    call tcp_sack_opts
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

tcp_sack_opts:
    cmp byte [sack_ok], 0
    je .r
    cmp dword [ooo_n], 0
    je .r
    pushad
    mov dword [tcp_opts], 0x00050101
    mov edi, tcp_opts + 4
    xor edx, edx
    mov ebp, -1
    mov eax, [ooo_recent]
    xor ebx, ebx
.find:
    cmp ebx, [ooo_n]
    jae .rest
    mov ecx, eax
    sub ecx, [ooo_s + ebx * 4]
    js .fnext
    mov ecx, eax
    sub ecx, [ooo_e + ebx * 4]
    jns .fnext
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
    mov [tcp_opts + 3], al
    add eax, 2
    mov [tcp_opt_len], al
    popad
.r: ret

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

tcp_send_syn:
    pushad
    mov dword [tcp_opts], 0xB4050402
    mov dword [tcp_opts + 4], RCV_WSHIFT << 24 | 0x030301
    mov dword [tcp_opts + 8], 0x02040101
    mov byte [tcp_opt_len], 12
    mov al, TCP_SYN
    mov ebx, [snd_iss]
    xor ecx, ecx
    call tcp_xmit
    popad
    ret

tcp_arm:
    cmp dword [rtx_at], 0
    jne .r
    push eax
    mov eax, [ticks]
    add eax, [tcp_rto]
    or eax, 1
    mov [rtx_at], eax
    pop eax
.r: ret

tcp_output:
    pushad
    cmp byte [tcp_estab], 0
    je .done
    cmp byte [tcp_reset], 0
    jne .done
.next:
    mov edx, [snd_wnd]
    test edx, edx
    jnz .w
    movzx edx, byte [tcp_force]
.w: add edx, [snd_una]
    mov ebx, [snd_nxt]
    mov ecx, [snd_end]
    sub ecx, ebx
    test ecx, ecx
    jle .fin
    mov eax, edx
    sub eax, ebx
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
    push ebx
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
    mov eax, ebx
    sub eax, [snd_max]
    js .old
    cmp byte [rtt_on], 0
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
    mov ebx, [snd_nxt]
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
    mov eax, [snd_end]
    sub eax, [snd_nxt]
    test eax, eax
    jle .out
    call tcp_arm
.out:
    popad
    ret

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
    js .done
    mov byte [rtt_on], 0
    inc dword [rtx_n]
    mov eax, [tcp_rto]
    add eax, eax
    cmp byte [tcp_estab], 0
    jne .est
    cmp eax, SYN_RTO_MAX
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

    mov eax, [snd_end]
    sub eax, [snd_nxt]
    test eax, eax
    jle .stop
    mov dword [rtx_n], 0
    mov byte [tcp_force], 1
    mov dword [rtx_at], 0
    call tcp_output
    mov byte [tcp_force], 0
    jmp .rearm
.resend:
    cmp dword [rtx_n], RTX_TRIES
    ja .give_up
    mov [snd_nxt], eax
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
    sub eax, edx
    add [tcp_srtt8], eax
    test eax, eax
    jns .pos
    neg eax
.pos:
    mov edx, [tcp_rttvar4]
    shr edx, 2
    sub eax, edx
    add [tcp_rttvar4], eax
.rto:
    mov eax, [tcp_srtt8]
    shr eax, 3
    add eax, [tcp_rttvar4]
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

tcp_connect:
    pushad
    call tcp_forget
    mov [tcp_dst_ip], eax
    mov [tcp_dst_port], bx
    mov eax, [tcp_port_seq]
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
    xor eax, eax
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
    mov byte [ack_dup], 0
    mov byte [tcp_force], 0
    mov byte [tcp_estab], 0
    mov dword [tcp_err], TE_NONE
    mov dword [snd_mss], 536
    mov dword [tcp_rto], RTO_INIT
    rdtsc
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
    call tcp_poll
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

tcp_forget:
    mov byte [tcp_on], 0
    mov byte [tcp_estab], 0
    ret

tcp_close:
    cmp byte [tcp_on], 0
    je .r
    cmp byte [tcp_fin_q], 0
    jne .r
    mov byte [tcp_fin_q], 1
    call tcp_output
.r: ret

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
    mov eax, [rcv_nxt]
    mov [rcv_rd], eax
    call net_idle
    jmp .l
.done:
    call tcp_forget
    popad
    ret

tcp_avail:
    mov eax, [rcv_nxt]
    sub eax, [rcv_rd]
    ret

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

    cmp byte [tcp_estab], 0
    je .ret
    cmp byte [tcp_fin_in], 0
    jne .ret
    push edx
    push ecx
    mov eax, [rcv_nxt]
    sub eax, [rcv_rd]
    neg eax
    add eax, RB_SIZE
    mov cl, [rcv_shift]
    shr eax, cl
    cmp eax, 0xFFFF
    jbe .w
    mov eax, 0xFFFF
.w: shl eax, cl
    mov edx, eax
    sub edx, [rcv_adv]
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

tcp_wait_avail:
    push ebx
    push ecx
    push esi
    mov ebx, eax
    mov esi, edx
    mov ecx, [ticks]
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
    mov eax, [ticks]
    mov edx, [tcp_last_rx]
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

tcp_send:
    pushad
    mov ebp, [ticks]
.l: test ecx, ecx
    jz .ok
    cmp byte [tcp_reset], 0
    jne .fail
    cmp byte [tcp_on], 0
    je .fail
    mov eax, [snd_end]
    sub eax, [snd_una]
    neg eax
    add eax, SB_SIZE
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

tcp_rx_frame:
    pushad
    cmp ecx, ETH_HLEN + 20
    jb .done
    mov ax, [esi + 12]
    cmp ax, 0x0608
    jne .not_arp
    call arp_handle
    jmp .done
.not_arp:
    cmp ax, 0x0008
    jne .done
    lea ebx, [esi + ETH_HLEN]
    sub ecx, ETH_HLEN
    movzx eax, byte [ebx]
    mov dl, al
    and dl, 0xF0
    cmp dl, 0x40
    jne .done
    and eax, 0x0F
    shl eax, 2
    cmp eax, 20
    jb .done
    movzx edx, word [ebx + 2]
    xchg dl, dh
    cmp edx, ecx
    ja .done
    cmp edx, eax
    jb .done
    test word [ebx + 6], 0xFF3F
    jnz .done
    cmp byte [ebx + 9], IPPROTO_TCP
    jne .done
    mov edi, [ebx + 16]
    cmp edi, [my_ip]
    jne .done
    push edx
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

tcp_input:
    lea esi, [ebx + eax]
    sub edx, eax
    cmp edx, 20
    jb .r
    movzx ecx, byte [esi + 12]
    shr ecx, 4
    shl ecx, 2
    cmp ecx, 20
    jb .r
    cmp ecx, edx
    ja .r
    push esi
    push ecx
    push edx
    push ebx
    mov eax, [ebx + 12]
    mov ebx, [ebx + 16]
    mov ecx, edx
    call tcp_pseudo_sum
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
    call tcp_lose
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
    test byte [esi + 13], TCP_RST
    jnz .r
    call tcp_rst_reply
.r: ret

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
    mov ebx, [seg_ack]
    mov dword [tx_ack], 0
    mov al, TCP_RST
    jmp .send
.noack:
    mov eax, [seg_seq]
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

tcp_in_synsent:
    mov esi, [seg_hdr]
    mov dl, [esi + 13]
    test dl, TCP_ACK
    jz .noack
    mov eax, [seg_ack]
    cmp eax, [snd_nxt]
    jne .badack
.noack:
    test dl, TCP_RST
    jz .norst
    test dl, TCP_ACK
    jz .r
    mov byte [tcp_reset], 1
    mov dword [tcp_err], TE_REFUSED
    ret
.norst:
    test dl, TCP_SYN
    jz .r
    test dl, TCP_ACK
    jz .r
    mov eax, [seg_seq]
    mov [rcv_irs], eax
    inc eax
    mov [rcv_nxt], eax
    mov [rcv_rd], eax
    mov eax, [seg_ack]
    mov [snd_una], eax
    mov eax, [seg_win]
    mov [snd_wnd], eax
    mov eax, [seg_seq]
    mov [snd_wl1], eax
    mov eax, [seg_ack]
    mov [snd_wl2], eax
    call tcp_parse_opts
    mov byte [tcp_estab], 1
    cmp dword [rtx_n], 0
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

tcp_parse_opts:
    pushad
    mov esi, [seg_hdr]
    mov ecx, [seg_hlen]
    lea edx, [esi + ecx]
    add esi, 20
    mov dword [snd_mss], 536
    xor ebx, ebx
.l: cmp esi, edx
    jae .end
    mov al, [esi]
    cmp al, 0
    je .end
    cmp al, 1
    jne .long
    inc esi
    jmp .l
.long:
    lea edi, [esi + 1]
    cmp edi, edx
    jae .end
    movzx ecx, byte [esi + 1]
    cmp ecx, 2
    jb .end
    lea edi, [esi + ecx]
    cmp edi, edx
    ja .end
    cmp al, 2
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
    cmp al, 4
    jne .not_sack
    mov byte [sack_ok], 1
    jmp .next
.not_sack:
    cmp al, 3
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
.m: test bl, bl
    jz .noscale
    mov byte [rcv_shift], RCV_WSHIFT
    jmp .done
.noscale:
    mov byte [snd_shift], 0
    mov byte [rcv_shift], 0
.done:
    popad
    ret

tcp_in_estab:
    mov esi, [seg_hdr]
    movzx edx, byte [esi + 13]
    test dl, TCP_RST
    jz .not_rst
    mov eax, [seg_seq]
    sub eax, [rcv_nxt]
    mov ecx, [rcv_adv]
    cmp ecx, 1
    adc ecx, 0
    cmp eax, ecx
    jae .r
    mov byte [tcp_reset], 1
    mov dword [tcp_err], TE_RESET
    ret
.not_rst:
    test dl, TCP_SYN
    jz .not_syn
    mov byte [ack_now], 1
    jmp .finish
.not_syn:
    test dl, TCP_ACK
    jz .r

    mov eax, [seg_ack]
    mov ecx, eax
    sub ecx, [snd_max]
    test ecx, ecx
    jle .ack_ok
    mov byte [ack_now], 1
    jmp .finish
.ack_ok:
    mov ecx, eax
    sub ecx, [snd_una]
    test ecx, ecx
    jle .wnd
    mov [snd_una], eax
    mov ecx, [snd_nxt]
    sub ecx, eax
    jns .nx
    mov [snd_nxt], eax
.nx:
    cmp byte [tcp_fin_q], 0
    je .nofin
    mov ecx, [snd_end]
    inc ecx
    cmp eax, ecx
    jne .nofin
    mov byte [tcp_fin_acked], 1
.nofin:
    cmp byte [rtt_on], 0
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
    call tcp_arm
.wnd:

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

    mov ebx, [seg_seq]
    mov ecx, [seg_len]
    mov esi, [seg_data]
    test dl, TCP_FIN
    jz .nofinflag
    lea eax, [ebx + ecx]
    mov [fin_seq], eax
    mov byte [fin_known], 1
    cmp byte [tcp_fin_in], 0
    je .nofinflag
    mov byte [ack_now], 1
.nofinflag:
    test ecx, ecx
    jz .data_done
    cmp byte [tcp_fin_in], 0
    jne .data_done
    mov eax, ebx
    sub eax, [rcv_nxt]
    jns .not_old
    add eax, ecx
    test eax, eax
    jle .dup
    sub ecx, eax
    add esi, ecx
    add ebx, ecx
    mov ecx, eax
    xor eax, eax
.not_old:
    mov edi, [rcv_nxt]
    sub edi, [rcv_rd]
    neg edi
    add edi, RB_SIZE
    cmp eax, edi
    jae .dup
    push eax
    add eax, ecx
    cmp eax, edi
    pop eax
    jbe .fits
    mov ecx, edi
    sub ecx, eax
.fits:
    push eax
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
    add [rcv_nxt], ecx
    add [ack_owed], ecx
    cmp dword [ooo_n], 0
    je .ackcount
    call ooo_merge
    mov byte [ack_now], 1
    cmp dword [ooo_n], 0
    je .ackcount
    mov byte [ack_dup], 1
.ackcount:
    cmp dword [ack_owed], 2 * TCP_MSS
    jb .data_done
    mov byte [ack_now], 1
    jmp .data_done
.early:
    cmp dword [ooo_n], 0
    jne .more
    mov byte [ack_dup], 1
.more:
    lea eax, [ebx + ecx]
    call ooo_add
    mov byte [ack_now], 1
    jmp .data_done
.dup:
    mov byte [ack_now], 1
.data_done:
    cmp byte [fin_known], 0
    je .finish
    cmp byte [tcp_fin_in], 0
    jne .finish
    mov eax, [rcv_nxt]
    cmp eax, [fin_seq]
    jne .finish
    mov byte [tcp_fin_in], 1

    mov dword [ooo_n], 0
    mov byte [ack_now], 1
.finish:
    cmp byte [ack_now], 0
    je .out
    call tcp_send_ack
    cmp byte [ack_dup], 0
    je .out
    mov byte [ack_dup], 0
    call tcp_send_ack
    call tcp_send_ack
    call tcp_send_ack
.out:
    call tcp_output
.r: ret

ooo_add:
    pushad
    mov [ooo_recent], ebx
    mov ebp, [rcv_nxt]
    sub ebx, ebp
    sub eax, ebp
    mov ecx, [ooo_n]
    xor edi, edi
.find:
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
    ja .insert

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
    mov edx, [ooo_e + esi * 4]
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
    mov esi, ecx
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

ooo_merge:
    pushad
.l: cmp dword [ooo_n], 0
    je .done
    mov eax, [ooo_s]
    sub eax, [rcv_nxt]
    test eax, eax
    jg .done
    mov eax, [ooo_e]
    mov ecx, eax
    sub ecx, [rcv_nxt]
    test ecx, ecx
    jle .drop
    add [ack_owed], ecx
    mov [rcv_nxt], eax
.drop:
    xor eax, eax
    call ooo_remove
    jmp .l
.done:
    popad
    ret
