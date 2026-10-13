RTL_IDR0    equ 0x00
RTL_TSD0    equ 0x10
RTL_TSAD0   equ 0x20
RTL_RBSTART equ 0x30
RTL_CR      equ 0x37
RTL_CAPR    equ 0x38
RTL_IMR     equ 0x3C
RTL_ISR     equ 0x3E
RTL_TCR     equ 0x40
RTL_RCR     equ 0x44
RTL_CONFIG1 equ 0x52

RX_BUF_LEN  equ 32768
NET_RX      equ NET_RING
NET_TX      equ NET_BUF + 0x2800
NET_PKT     equ NET_BUF + 0x4800
NET_RXP     equ NET_BUF + 0x5800

ETH_HLEN      equ 14
ET_IP         equ 0x0800
ET_ARP        equ 0x0806
IPPROTO_ICMP  equ 1
IPPROTO_TCP   equ 6
IPPROTO_UDP   equ 17

section .bss
alignb 4
net_present     resb 1
net_up          resb 1
nic_io          resd 1
nic_mac         resb 6
alignb 4
tx_slot         resd 1
rx_offset       resd 1
my_ip           resd 1
my_mask         resd 1
gw_ip           resd 1
dns_ip          resd 1
dhcp_server     resd 1
dhcp_xid        resd 1
arp_ip          resd 1
arp_mac         resb 6
alignb 4
ip_ident        resd 1
rx_frame        resd 1
rx_len          resd 1
net_err         resd 1
udp_src_port    resd 1
net_scratch     resd 1

section .data
mac_bcast       db 0xFF,0xFF,0xFF,0xFF,0xFF,0xFF
err_no_nic      db "no supported network card found (MOOS drives the RTL8139)", 0
err_no_dhcp     db "no reply from DHCP - is the network connected?", 0
err_timeout     db "the network did not reply in time", 0
err_dns         db "could not look up that name", 0
err_not_up      db "the network is not connected - run 'net up' first", 0
rtl_ids         dd 0x813910EC, 0x12111113, 0

section .text

pci_read32:
    push ebx
    push edx
    movzx eax, al
    and al, 0xFC
    and ebx, 0xFFFFFF00
    or ebx, eax
    or ebx, 0x80000000
    mov eax, ebx
    mov dx, 0xCF8
    out dx, eax
    mov dx, 0xCFC
    in eax, dx
    pop edx
    pop ebx
    ret

pci_write32:
    push eax
    push ebx
    push edx
    movzx eax, al
    and al, 0xFC
    and ebx, 0xFFFFFF00
    or ebx, eax
    or ebx, 0x80000000
    mov eax, ebx
    mov dx, 0xCF8
    out dx, eax
    mov dx, 0xCFC
    mov eax, ecx
    out dx, eax
    pop edx
    pop ebx
    pop eax
    ret

pci_find_rtl:
    push ecx
    push edx
    xor ebx, ebx
.next:
    mov al, 0
    call pci_read32
    cmp eax, 0xFFFFFFFF
    je .advance
    mov edx, eax
    mov ecx, rtl_ids
.match:
    mov eax, [ecx]
    test eax, eax
    jz .advance
    cmp eax, edx
    je .found
    add ecx, 4
    jmp .match
.advance:
    add ebx, 0x100
    cmp ebx, 0x10000
    jb .next
    pop edx
    pop ecx
    stc
    ret
.found:
    pop edx
    pop ecx
    clc
    ret

nic_out8:
    push edx
    movzx edx, cl
    add edx, [nic_io]
    out dx, al
    pop edx
    ret
nic_out16:
    push edx
    movzx edx, cl
    add edx, [nic_io]
    out dx, ax
    pop edx
    ret
nic_out32:
    push edx
    movzx edx, cl
    add edx, [nic_io]
    out dx, eax
    pop edx
    ret
nic_in8:
    push edx
    movzx edx, cl
    add edx, [nic_io]
    in al, dx
    pop edx
    ret
nic_in16:
    push edx
    movzx edx, cl
    add edx, [nic_io]
    in ax, dx
    pop edx
    ret
nic_in32:
    push edx
    movzx edx, cl
    add edx, [nic_io]
    in eax, dx
    pop edx
    ret

net_detect:
    pushad
    mov byte [net_present], 0
    mov byte [net_up], 0
    call pci_find_rtl
    jc .none
    mov al, 0x04
    call pci_read32
    or eax, 0x05
    mov ecx, eax
    mov al, 0x04
    call pci_write32
    mov al, 0x10
    call pci_read32
    and eax, 0xFFFFFFFC
    mov [nic_io], eax
    call nic_reset
    mov byte [net_present], 1
    popad
    clc
    ret
.none:
    mov dword [net_err], err_no_nic
    popad
    mov esi, err_no_nic
    stc
    ret

nic_reset:
    mov cl, RTL_CONFIG1
    mov al, 0
    call nic_out8
    mov cl, RTL_CR
    mov al, 0x10
    call nic_out8
    mov ebx, 0x400000
.wait:
    mov cl, RTL_CR
    call nic_in8
    test al, 0x10
    jz .reset_done
    dec ebx
    jnz .wait
.reset_done:
    mov cl, RTL_RBSTART
    mov eax, NET_RX
    call nic_out32
    mov cl, RTL_IMR
    xor ax, ax
    call nic_out16
    mov cl, RTL_ISR
    mov ax, 0xFFFF
    call nic_out16
    mov cl, RTL_RCR
    mov eax, 0x0000178A
    call nic_out32
    mov cl, RTL_TCR
    mov eax, 0x03000600
    call nic_out32
    mov cl, RTL_CR
    mov al, 0x0C
    call nic_out8
    mov dword [tx_slot], 0
    mov dword [rx_offset], 0
    mov cl, RTL_IDR0
    call nic_in32
    mov [nic_mac], eax
    mov cl, RTL_IDR0 + 4
    call nic_in16
    mov [nic_mac + 4], ax
    ret

net_tx_frame:
    pushad
    cmp ecx, 1792
    ja .done
    mov ebx, [tx_slot]
    mov edi, ebx
    shl edi, 11
    add edi, NET_TX
    push ecx
    rep movsb
    pop ecx
    cmp ecx, 60
    jae .padded
.pad_loop:
    mov byte [edi], 0
    inc edi
    inc ecx
    cmp ecx, 60
    jb .pad_loop
.padded:
    mov eax, ebx
    shl eax, 2
    mov edx, eax
    add edx, RTL_TSAD0
    add edx, [nic_io]
    mov eax, ebx
    shl eax, 11
    add eax, NET_TX
    out dx, eax
    mov eax, ebx
    shl eax, 2
    mov edx, eax
    add edx, RTL_TSD0
    add edx, [nic_io]
    mov eax, ecx
    or eax, 0x00300000
    out dx, eax
    mov ecx, 0x200000
.wait:
    in eax, dx
    test eax, 0x2000
    jnz .sent
    dec ecx
    jnz .wait
.sent:
    inc ebx
    and ebx, 3
    mov [tx_slot], ebx
.done:
    popad
    ret

section .bss
net_scratch_deadline resd 1
section .text

net_rx_poll:
    push eax
    push ebx
    push ecx
    push esi
    push edi
    mov cl, RTL_CR
    call nic_in8
    test al, 0x01
    jnz .empty
    mov esi, [rx_offset]
    add esi, NET_RX
    movzx eax, word [esi]
    test al, 0x01
    jz .bad
    movzx ecx, word [esi + 2]
    cmp ecx, 4
    jbe .bad
    sub ecx, 4
    cmp ecx, 1600
    ja .bad
    mov [rx_len], ecx
    lea esi, [esi + 4]
    mov edi, NET_RXP
    mov [rx_frame], edi
    push ecx
    rep movsb
    pop ecx
    add ecx, 4 + 4
    add ecx, [rx_offset]
    add ecx, 3
    and ecx, ~3
    and ecx, RX_BUF_LEN - 1
    mov [rx_offset], ecx
    lea eax, [ecx - 16]
    mov cl, RTL_CAPR
    call nic_out16
    pop edi
    pop esi
    pop ecx
    pop ebx
    pop eax
    clc
    ret
.bad:
    call nic_reset
.empty:
    pop edi
    pop esi
    pop ecx
    pop ebx
    pop eax
    stc
    ret

eth_build:
    push eax
    push ecx
    push esi
    mov ecx, 6
    rep movsb
    mov esi, nic_mac
    mov ecx, 6
    rep movsb
    xchg ah, al
    stosw
    pop esi
    pop ecx
    pop eax
    ret

ip_checksum:
    push ebx
    push ecx
    push edx
    push esi
    xor edx, edx
.loop:
    cmp ecx, 2
    jb .tail
    movzx eax, word [esi]
    xchg ah, al
    add edx, eax
    add esi, 2
    sub ecx, 2
    jmp .loop
.tail:
    test ecx, ecx
    jz .fold
    movzx eax, byte [esi]
    shl eax, 8
    add edx, eax
.fold:
    mov eax, edx
    shr eax, 16
    and edx, 0xFFFF
    add edx, eax
    mov eax, edx
    shr eax, 16
    add edx, eax
    mov eax, edx
    not eax
    and eax, 0xFFFF
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

%include "src/net_arp.asm"
%include "src/net_ip.asm"
%include "src/net_dhcp.asm"
%include "src/net_dns.asm"
%include "src/net_tcp.asm"

net_up_bring:
    cmp byte [net_present], 0
    jne .have_nic
    call net_detect
    jc .fail
.have_nic:
    call dhcp_configure
    jc .fail
    mov byte [net_up], 1
    clc
    ret
.fail:
    ret

net_poll_until:
    push eax
    mov [net_scratch_deadline], eax
.loop:
    call net_rx_poll
    jnc .got
    call status_tick
    call screen_present
    mov eax, [ticks]
    cmp eax, [net_scratch_deadline]
    jb .loop
    pop eax
    stc
    ret
.got:
    pop eax
    clc
    ret
