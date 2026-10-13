; =============================================================================
;  nic_rtl8168.asm - RealTek RTL8111/8168 (and 8169, 810x) driver
;
;  The "RealTek PCIe GbE Family Controller" found on most consumer
;  motherboards. Descriptor rings: each descriptor has an OWN bit - set means
;  the card owns it. We hand receive descriptors to the card (OWN=1); it
;  clears OWN when a frame is in. For sending we fill a descriptor, set OWN
;  and poke TxPoll; the card clears OWN when it has sent it.
;
;  The chip has many generations. The bring-up below follows what the Linux
;  r8169 driver does that matters for plain send/receive:
;    - newer chips (8168G and later, including the very common 8111H) gate
;      receive during reset ("RXDV gate", MISC bit 19), need the PLL powered
;      up (PMCH) and use OCP registers to reach the PHY
;    - the PHY is powered up and auto-negotiation restarted if there is no link
;  Registers through I/O ports (BAR0) when the firmware gave the card any,
;  otherwise memory-mapped (BAR2/BAR1).
;
;  This driver could not be tested in an emulator (none emulates this chip);
;  on UEFI PCs the firmware's own driver (nic_snp.asm) is used first.
; =============================================================================
R8_MAC0     equ 0x00
R8_MAR0     equ 0x08
R8_TXDESC   equ 0x20                ; TxDescStartAddr low / high (+4)
R8_CMD      equ 0x37
R8_TXPOLL   equ 0x38
R8_IMR      equ 0x3C
R8_ISR      equ 0x3E
R8_TXCFG    equ 0x40
R8_RXCFG    equ 0x44
R8_9346     equ 0x50
R8_PHYAR    equ 0x60
R8_PHYSTAT  equ 0x6C
R8_PMCH     equ 0x6F
R8_ERIDR    equ 0x70
R8_ERIAR    equ 0x74
R8_GPHY_OCP equ 0xB8
R8_RXMAX    equ 0xDA
R8_RXDESC   equ 0xE4                ; RxDescAddr low / high (+4)
R8_MISC     equ 0xF0

R8_OWN      equ 0x80000000
R8_EOR      equ 0x40000000
R8_FS       equ 0x20000000
R8_LS       equ 0x10000000
R8_RES      equ 0x00200000          ; receive error summary
R8_RXDV_GATE equ 1 << 19

section .bss
alignb 4
r8_xid      resd 1                  ; chip generation ID (TxConfig bits 30..20)
r8_newgen   resb 1                  ; 1 = 8168G or later

section .text

; ---------------------------------------------------- register access
; ECX = register offset; value in AL / AX / EAX
r8_in8:
    cmp dword [nic_mmio], 0
    jne .m
    push edx
    mov edx, [nic_io]
    add edx, ecx
    in al, dx
    pop edx
    ret
.m: push edx
    mov edx, [nic_mmio]
    mov al, [edx + ecx]
    pop edx
    ret
r8_in16:
    cmp dword [nic_mmio], 0
    jne .m
    push edx
    mov edx, [nic_io]
    add edx, ecx
    in ax, dx
    pop edx
    ret
.m: push edx
    mov edx, [nic_mmio]
    mov ax, [edx + ecx]
    pop edx
    ret
r8_in32:
    cmp dword [nic_mmio], 0
    jne .m
    push edx
    mov edx, [nic_io]
    add edx, ecx
    in eax, dx
    pop edx
    ret
.m: push edx
    mov edx, [nic_mmio]
    mov eax, [edx + ecx]
    pop edx
    ret
r8_out8:
    cmp dword [nic_mmio], 0
    jne .m
    push edx
    mov edx, [nic_io]
    add edx, ecx
    out dx, al
    pop edx
    ret
.m: push edx
    mov edx, [nic_mmio]
    mov [edx + ecx], al
    pop edx
    ret
r8_out16:
    cmp dword [nic_mmio], 0
    jne .m
    push edx
    mov edx, [nic_io]
    add edx, ecx
    out dx, ax
    pop edx
    ret
.m: push edx
    mov edx, [nic_mmio]
    mov [edx + ecx], ax
    pop edx
    ret
r8_out32:
    cmp dword [nic_mmio], 0
    jne .m
    push edx
    mov edx, [nic_io]
    add edx, ecx
    out dx, eax
    pop edx
    ret
.m: push edx
    mov edx, [nic_mmio]
    mov [edx + ecx], eax
    pop edx
    ret

; R8W8/16/32 reg, value  -  R8R8/16/32 reg -> AL/AX/EAX
%macro R8W8 2
    mov ecx, %1
    mov al, %2
    call r8_out8
%endmacro
%macro R8W16 2
    mov ecx, %1
    mov ax, %2
    call r8_out16
%endmacro
%macro R8W32 2
    mov ecx, %1
    mov eax, %2
    call r8_out32
%endmacro
%macro R8R 2                        ; R8R width, reg
    mov ecx, %2
    call r8_in%1
%endmacro

; r8_wait32: ECX = register, EDX = bit mask, BL = 0 wait for clear / 1 for
; set. Bounded. CF=1 on timeout.
r8_wait32:
    push eax
    push esi
    mov esi, 0x40000
.l: call r8_in32
    test eax, edx
    setnz al
    cmp al, bl
    je .ok
    dec esi
    jnz .l
    pop esi
    pop eax
    stc
    ret
.ok:
    pop esi
    pop eax
    clc
    ret

; ------------------------------------------------- PHY / ERI helpers
; r8_phy_write: ESI = MII register, DI = value (older chips: PHYAR)
r8_phy_write:
    pushad
    mov eax, esi
    and eax, 0x1F
    shl eax, 16
    movzx edi, di
    or eax, edi
    or eax, 0x80000000
    mov ecx, R8_PHYAR
    call r8_out32
    mov edx, 0x80000000             ; wait for the write to finish
    xor bl, bl
    call r8_wait32
    popad
    ret

; r8_ocp_phy_write: ESI = OCP address, DI = value (8168G and later)
r8_ocp_phy_write:
    pushad
    mov eax, esi
    shl eax, 15
    movzx edi, di
    or eax, edi
    or eax, 0x80000000
    mov ecx, R8_GPHY_OCP
    call r8_out32
    mov edx, 0x80000000
    xor bl, bl
    call r8_wait32
    popad
    ret

; r8_eri_setbits: ESI = ERI address, EDI = bits to set (32-bit, ERI_EXGMAC)
r8_eri_setbits:
    pushad
    mov eax, esi                    ; read
    or eax, 0xF << 12
    mov ecx, R8_ERIAR
    call r8_out32
    mov edx, 0x80000000
    mov bl, 1
    call r8_wait32
    jc .done
    mov ecx, R8_ERIDR
    call r8_in32
    or eax, edi                     ; write back with the bits set
    call r8_out32
    mov eax, esi
    or eax, (0xF << 12) | 0x80000000
    mov ecx, R8_ERIAR
    call r8_out32
    mov edx, 0x80000000
    xor bl, bl
    call r8_wait32
.done:
    popad
    ret

; pci_power_d0: EBX = card -> make sure it is in power state D0 (fully on)
pci_power_d0:
    pushad
    mov al, 0x04
    call pci_read32
    test eax, 0x00100000            ; status: has a capability list?
    jz .done
    mov al, 0x34
    call pci_read32
    and eax, 0xFC
    mov ecx, 48                     ; (guard against loops)
.cap:
    test eax, eax
    jz .done
    mov edx, eax
    call pci_read32                 ; AL = this capability's offset
    cmp al, 0x01                    ; power management
    je .pm
    shr eax, 8
    and eax, 0xFC
    dec ecx
    jnz .cap
    jmp .done
.pm:
    lea eax, [edx + 4]              ; PMCSR
    push eax
    call pci_read32
    mov ecx, eax
    pop eax
    test cl, 3
    jz .done                        ; already D0
    and ecx, ~3
    call pci_write32
    mov eax, [ticks]                ; a device leaving D3 needs ~10 ms
    add eax, 2
.w: cmp [ticks], eax
    jb .w
.done:
    popad
    ret

; ------------------------------------------------------------- bring-up
; r8168_init: EBX = card -> CF=1 (net_err set) if it cannot be used
r8168_init:
    pushad
    call pci_power_d0
    mov al, 0x10                    ; I/O ports if the card has them
    call pci_read32
    test al, 1
    jz .mem
    and eax, 0xFFFFFFFC
    jz .mem
    mov [nic_io], eax
    jmp .regs
.mem:
    mov al, 0x18                    ; BAR2 (8168), else BAR1 (8169)
    call pci_mmio_bar
    jnc .mem_ok
    mov al, 0x14
    call pci_mmio_bar
    jc .bar
.mem_ok:
    mov [nic_mmio], eax
.regs:
    R8R 32, R8_TXCFG                ; which generation is it?
    cmp eax, 0xFFFFFFFF             ; (all ones: the card is not answering)
    je .bad
    shr eax, 20
    and eax, 0x7CF
    mov [r8_xid], eax
    mov byte [r8_newgen], 0
    and eax, 0x7C0
    cmp eax, 0x4C0                  ; 8168G (0x4c0) and later
    jb .gen
    cmp eax, 0x600                  ; (0x6xx = 8125 family: different chip)
    jae .gen
    mov byte [r8_newgen], 1
.gen:
    R8W16 R8_IMR, 0                 ; no interrupts (we poll)
    R8W16 R8_ISR, 0xFFFF
    cmp byte [r8_newgen], 0         ; gate receive while resetting
    je .reset
    R8R 32, R8_MISC
    or eax, R8_RXDV_GATE
    call r8_out32
.reset:
    R8W8 R8_CMD, 0x10               ; software reset
    mov esi, 0x40000
.rwait:
    R8R 8, R8_CMD                   ; (8-bit register: poll it as a byte)
    test al, 0x10
    jz .rdone
    dec esi
    jnz .rwait
.rdone:
    cmp byte [r8_newgen], 0         ; power the PLL up
    je .mac
    R8R 8, R8_PMCH
    or al, 0xC0
    call r8_out8
    mov eax, [r8_xid]
    and eax, 0x7CE
    cmp eax, 0x540                  ; 8168H also needs ERI 0x1A8 bits 26-31
    jne .mac
    mov esi, 0x1A8
    mov edi, 0xFC000000
    call r8_eri_setbits
.mac:
    xor esi, esi                    ; MAC address from IDR0..5
.macl:
    mov ecx, esi
    call r8_in8
    mov [nic_mac + esi], al
    inc esi
    cmp esi, 6
    jb .macl
    call e1k_mac_sane
    jc .bad
    R8W8 R8_9346, 0xC0              ; unlock the configuration registers
    cmp byte [r8_newgen], 0
    je .unlocked
    R8R 32, R8_MISC                 ; let receive through again
    and eax, ~R8_RXDV_GATE
    call r8_out32
.unlocked:
    R8W16 R8_RXMAX, 0x0800          ; frames up to 2 KB
    ; --- receive ring: all descriptors owned by the card
    xor ecx, ecx
.rxd:
    mov edi, ecx
    shl edi, 4
    add edi, NIC_RXDESC
    mov eax, R8_OWN | 2048
    cmp ecx, NIC_RXN - 1
    jne .rx_noeor
    or eax, R8_EOR
.rx_noeor:
    mov [edi], eax
    mov dword [edi + 4], 0
    mov eax, ecx
    shl eax, 11
    add eax, NIC_RXBUF
    mov [edi + 8], eax
    mov dword [edi + 12], 0
    inc ecx
    cmp ecx, NIC_RXN
    jb .rxd
    ; --- transmit ring: all ours (OWN clear), end-of-ring on the last
    mov edi, NIC_TXDESC
    mov ecx, NIC_TXN * 4
    xor eax, eax
    rep stosd
    mov dword [NIC_TXDESC + (NIC_TXN - 1) * 16], R8_EOR
    R8W32 R8_TXDESC, NIC_TXDESC
    R8W32 R8_TXDESC + 4, 0
    R8W32 R8_RXDESC, NIC_RXDESC
    R8W32 R8_RXDESC + 4, 0
    R8W8 R8_9346, 0x00              ; lock the configuration again
    R8W8 R8_CMD, 0x0C               ; receive + transmit on
    mov eax, 0x0000870E             ; RxConfig: broadcast + our MAC, DMA burst
    cmp byte [r8_newgen], 0
    je .rx_old
    mov eax, 0x0000CF0E
    jmp .rx_set
.rx_old:
    mov edx, [nic_vendev]
    shr edx, 16
    cmp edx, 0x8169                 ; the PCI 8169 generation
    je .rx_8169
    cmp edx, 0x8167
    je .rx_8169
    cmp edx, 0x4300
    jb .rx_set
    cmp edx, 0x4302
    ja .rx_set
.rx_8169:
    mov eax, 0x0000E70E
.rx_set:
    mov ecx, R8_RXCFG
    call r8_out32
    mov eax, 0x03000700             ; TxConfig: normal gap, DMA burst
    cmp byte [r8_newgen], 0
    je .tx_set
    or eax, 0x80                    ; (auto FIFO on newer chips)
.tx_set:
    mov ecx, R8_TXCFG
    call r8_out32
    R8W32 R8_MAR0, 0                ; no multicast
    R8W32 R8_MAR0 + 4, 0
    mov dword [rx_cur], 0
    mov dword [tx_slot], 0
    call r8168_link                 ; no link yet: wake the PHY up
    jnc .done
    call r8168_phy_kick
.done:
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

; r8168_phy_kick: power the PHY up and restart auto-negotiation
; (MII BMCR = auto-negotiate + restart, power-down bit clear)
r8168_phy_kick:
    pushad
    cmp byte [r8_newgen], 0
    je .old
    mov esi, 0xA400                 ; standard PHY registers at OCP 0xA400
    mov di, 0x1200
    call r8_ocp_phy_write
    popad
    ret
.old:
    mov esi, 0x1F                   ; page 0
    xor edi, edi
    call r8_phy_write
    xor esi, esi                    ; BMCR
    mov di, 0x1200
    call r8_phy_write
    popad
    ret

; r8168_link -> CF=0 if PHYstatus says the link is up
r8168_link:
    push eax
    push ecx
    R8R 8, R8_PHYSTAT
    test al, 2
    pop ecx
    pop eax
    jz .down
    clc
    ret
.down:
    stc
    ret

; r8168_tx: ESI = frame, ECX = length. Registers kept.
r8168_tx:
    pushad
    mov ebx, [tx_slot]
    mov edi, ebx
    shl edi, 11
    add edi, NIC_TXBUF
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
    mov [esi + 8], edi              ; buffer address
    mov dword [esi + 12], 0
    mov dword [esi + 4], 0
    mov eax, ecx                    ; length + flags; OWN last
    or eax, R8_OWN | R8_FS | R8_LS
    cmp ebx, NIC_TXN - 1
    jne .noeor
    or eax, R8_EOR
.noeor:
    mov [esi], eax
    inc ebx
    and ebx, NIC_TXN - 1
    mov [tx_slot], ebx
    R8W8 R8_TXPOLL, 0x40            ; "normal priority queue has work"
    mov ecx, 0x200000
.wait:
    test dword [esi], R8_OWN        ; the card clears OWN once sent
    jz .sent
    dec ecx
    jnz .wait
.sent:
    popad
    ret

; r8168_rx: next received frame -> NET_RXP (rx_frame / rx_len), CF=0;
; CF=1 when none is waiting
r8168_rx:
    pushad
.next:
    mov ebx, [rx_cur]
    mov esi, ebx
    shl esi, 4
    add esi, NIC_RXDESC
    mov eax, [esi]
    test eax, R8_OWN                ; still the card's: nothing new
    jnz .empty
    mov edx, eax
    and edx, R8_FS | R8_LS
    cmp edx, R8_FS | R8_LS          ; whole frame in one buffer?
    jne .drop
    test eax, R8_RES                ; receive error
    jnz .drop
    mov ecx, eax
    and ecx, 0x3FFF
    sub ecx, 4                      ; (the length includes the CRC)
    cmp ecx, 14
    jl .drop
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
    mov dword [esi + 4], 0
    mov eax, R8_OWN | 2048
    cmp ebx, NIC_RXN - 1
    jne .gb
    or eax, R8_EOR
.gb:
    mov [esi], eax
    inc ebx
    and ebx, NIC_RXN - 1
    mov [rx_cur], ebx
    ret
