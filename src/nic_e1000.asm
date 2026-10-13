; =============================================================================
;  nic_e1000.asm - Intel PRO/1000 driver (e1000 / e1000e family)
;
;  Covers the classic 82540/82545 (what VirtualBox and QEMU emulate), the
;  8257x cards (82574L etc.), and the I217/I218/I219 built into Intel-chipset
;  motherboards. All share the same basic registers and "legacy" descriptors:
;  a ring of receive descriptors the card fills, a ring of transmit
;  descriptors it sends from. Registers are memory-mapped (BAR0). Polled.
;
;  The chipset-attached parts (flag E1K_PCH) are not given a full chip reset:
;  after one, their PHY needs a long, model-specific bring-up. Their MAC
;  address is always loaded into RAL0/RAH0 by the hardware.
; =============================================================================
E_CTRL      equ 0x0000
E_STATUS    equ 0x0008
E_EERD      equ 0x0014
E_ICR       equ 0x00C0
E_IMC       equ 0x00D8
E_RCTL      equ 0x0100
E_TCTL      equ 0x0400
E_TIPG      equ 0x0410
E_RDBAL     equ 0x2800
E_RDBAH     equ 0x2804
E_RDLEN     equ 0x2808
E_RDH       equ 0x2810
E_RDT       equ 0x2818
E_TDBAL     equ 0x3800
E_TDBAH     equ 0x3804
E_TDLEN     equ 0x3808
E_TDH       equ 0x3810
E_TDT       equ 0x3818
E_MTA       equ 0x5200
E_RAL0      equ 0x5400
E_RAH0      equ 0x5404

CTRL_LRST    equ 1 << 3
CTRL_ASDE    equ 1 << 5
CTRL_SLU     equ 1 << 6
CTRL_ILOS    equ 1 << 7
CTRL_RST     equ 1 << 26
CTRL_VME     equ 1 << 30
CTRL_PHY_RST equ 1 << 31
RAH_AV       equ 1 << 31
RCTL_VALUE   equ (1 << 1) | (1 << 15) | (1 << 26)   ; EN, broadcast, strip CRC; 2K buffers
TCTL_VALUE   equ (1 << 1) | (1 << 3) | (15 << 4) | (63 << 12) | (1 << 24)
TIPG_VALUE   equ 0x0060200A

; E1R reg -> EAX ; E1W reg, value (uses EDX)
%macro E1R 1
    mov eax, [nic_mmio]
    mov eax, [eax + %1]
%endmacro
%macro E1W 2
    mov edx, [nic_mmio]
    mov dword [edx + %1], %2
%endmacro

section .text

; e1000_init: EBX = card -> CF=1 (net_err set) if it cannot be used
e1000_init:
    pushad
    mov al, 0x10                    ; BAR0: the registers
    call pci_mmio_bar
    jc .bar
    mov [nic_mmio], eax
    E1W E_IMC, 0xFFFFFFFF           ; no interrupts; stop receive/transmit
    E1W E_RCTL, 0
    E1W E_TCTL, 0
    test dword [nic_flags], E1K_PCH
    jnz .no_reset
    E1R E_CTRL                      ; full reset (classic / 8257x)
    or eax, CTRL_RST
    E1W E_CTRL, eax
    mov eax, [ticks]                ; let it start (>= 10 ms)
    add eax, 2
.settle:
    cmp [ticks], eax
    jb .settle
    mov ecx, 0x100000
.rst:
    E1R E_CTRL
    test eax, CTRL_RST
    jz .reset_done
    dec ecx
    jnz .rst
.reset_done:
    E1W E_IMC, 0xFFFFFFFF
.no_reset:
    E1R E_ICR                       ; clear anything pending
    E1R E_CTRL                      ; link up, auto speed, no resets
    or eax, CTRL_SLU | CTRL_ASDE
    and eax, ~(CTRL_LRST | CTRL_PHY_RST | CTRL_ILOS | CTRL_VME)
    E1W E_CTRL, eax
    mov edi, [nic_mmio]             ; empty multicast table
    add edi, E_MTA
    mov ecx, 128
    xor eax, eax
    rep stosd
    ; --- MAC address: RAL0/RAH0, or the EEPROM if they are not set
    E1R E_RAL0
    mov [nic_mac], eax
    E1R E_RAH0
    mov [nic_mac + 4], ax
    test eax, RAH_AV
    jz .eeprom
    call e1k_mac_sane
    jnc .mac_ok
.eeprom:
    test dword [nic_flags], E1K_PCH
    jnz .bad                        ; (no EEPROM interface there)
    xor ecx, ecx
    call e1k_eerd
    jc .bad
    mov [nic_mac], ax
    mov ecx, 1
    call e1k_eerd
    jc .bad
    mov [nic_mac + 2], ax
    mov ecx, 2
    call e1k_eerd
    jc .bad
    mov [nic_mac + 4], ax
    call e1k_mac_sane
    jc .bad
.mac_ok:
    mov eax, [nic_mac]              ; (re)write the filter, marked valid
    E1W E_RAL0, eax
    movzx eax, word [nic_mac + 4]
    or eax, RAH_AV
    E1W E_RAH0, eax
    ; --- receive ring: every descriptor points at its own 2 KB buffer
    mov edi, NIC_RXDESC
    mov ecx, NIC_RXN * 4
    xor eax, eax
    rep stosd
    xor ecx, ecx
.rxd:
    mov eax, ecx
    shl eax, 11
    add eax, NIC_RXBUF
    mov edi, ecx
    shl edi, 4
    mov [NIC_RXDESC + edi], eax
    inc ecx
    cmp ecx, NIC_RXN
    jb .rxd
    E1W E_RDBAL, NIC_RXDESC
    E1W E_RDBAH, 0
    E1W E_RDLEN, NIC_RXN * 16
    E1W E_RDH, 0
    E1W E_RDT, NIC_RXN - 1
    mov dword [rx_cur], 0
    E1W E_RCTL, RCTL_VALUE
    ; --- transmit ring
    mov edi, NIC_TXDESC
    mov ecx, NIC_TXN * 4
    xor eax, eax
    rep stosd
    E1W E_TDBAL, NIC_TXDESC
    E1W E_TDBAH, 0
    E1W E_TDLEN, NIC_TXN * 16
    E1W E_TDH, 0
    E1W E_TDT, 0
    mov dword [tx_slot], 0
    E1W E_TIPG, TIPG_VALUE
    E1W E_TCTL, TCTL_VALUE
    popad
    clc
    ret
.bar:
    mov dword [net_err], err_bar
    popad
    stc
    ret
.bad:
    mov dword [net_err], err_nic_init
    popad
    stc
    ret

; e1k_mac_sane: CF=1 if nic_mac is all zeros, all ones, or multicast
e1k_mac_sane:
    push eax
    test byte [nic_mac], 1          ; multicast bit set: not a real address
    jnz .bad
    mov eax, [nic_mac]
    or ax, [nic_mac + 4]            ; (low word only: enough to spot zeros)
    test eax, eax
    jz .bad
    cmp dword [nic_mac], 0xFFFFFFFF
    je .bad
    pop eax
    clc
    ret
.bad:
    pop eax
    stc
    ret

; e1k_eerd: ECX = EEPROM word number -> AX = the word, CF=1 on timeout.
; Two layouts: classic (start bit 0, done bit 4, address << 8) and 8257x
; (done bit 1, address << 2).
e1k_eerd:
    push ebx
    push ecx
    push edx
    test dword [nic_flags], E1K_EERD2
    jnz .new
    shl ecx, 8
    or ecx, 1
    mov ebx, 1 << 4
    jmp .go
.new:
    shl ecx, 2
    or ecx, 1
    mov ebx, 1 << 1
.go:
    E1W E_EERD, ecx
    mov ecx, 0x100000
.wait:
    E1R E_EERD
    test eax, ebx
    jnz .got
    dec ecx
    jnz .wait
    pop edx
    pop ecx
    pop ebx
    stc
    ret
.got:
    shr eax, 16
    pop edx
    pop ecx
    pop ebx
    clc
    ret

; e1000_link -> CF=0 if STATUS.LU (link up)
e1000_link:
    push eax
    E1R E_STATUS
    test al, 2
    pop eax
    jz .down
    clc
    ret
.down:
    stc
    ret

; e1000_tx: ESI = frame, ECX = length. Registers kept.
e1000_tx:
    pushad
    mov ebx, [tx_slot]
    mov edi, ebx
    shl edi, 11
    add edi, NIC_TXBUF              ; this slot's buffer
    push edi
    rep movsb
    pop edi
    mov ecx, [esp + 24]             ; (length, from the pushad frame)
    push edi
    add edi, ecx
    call nic_pad60
    pop edi
    mov esi, ebx                    ; ESI = descriptor
    shl esi, 4
    add esi, NIC_TXDESC
    mov [esi], edi                  ; buffer address
    mov dword [esi + 4], 0
    mov [esi + 8], cx               ; length
    mov byte [esi + 10], 0
    mov byte [esi + 11], 0x0B       ; end of packet, insert CRC, report status
    mov dword [esi + 12], 0         ; status / css / special
    inc ebx
    and ebx, NIC_TXN - 1
    mov [tx_slot], ebx
    E1W E_TDT, ebx                  ; hand it to the card
    mov ecx, 0x200000
.wait:
    test byte [esi + 12], 1         ; DD: done
    jnz .sent
    dec ecx
    jnz .wait
.sent:
    popad
    ret

; e1000_rx: next received frame -> NET_RXP (rx_frame / rx_len), CF=0;
; CF=1 when none is waiting
e1000_rx:
    pushad
.next:
    mov ebx, [rx_cur]
    mov esi, ebx
    shl esi, 4
    add esi, NIC_RXDESC
    test byte [esi + 12], 1         ; DD: the card filled it
    jz .empty
    movzx ecx, word [esi + 8]       ; length
    test byte [esi + 12], 2         ; EOP: the whole frame in one buffer
    jz .drop
    test byte [esi + 13], 0x97      ; frame errors (CE SE SEQ CXE RXE)
    jnz .drop
    cmp ecx, 14
    jb .drop
    cmp ecx, 1600
    ja .drop
    push esi
    mov esi, ebx
    shl esi, 11
    add esi, NIC_RXBUF
    mov edi, NET_RXP
    mov [rx_len], ecx
    mov [rx_frame], edi
    rep movsb
    pop esi
    call .give_back
    popad
    clc
    ret
.drop:
    call .give_back
    jmp .next
.empty:
    popad
    stc
    ret
.give_back:                         ; descriptor EBX back to the card
    mov byte [esi + 12], 0
    E1W E_RDT, ebx
    inc ebx
    and ebx, NIC_RXN - 1
    mov [rx_cur], ebx
    ret
