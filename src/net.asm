; =============================================================================
;  net.asm - networking: network card drivers + IPv4 / UDP / ARP / DHCP / DNS
;
;  MOOS drives the network card itself (polling - no interrupts). Drivers:
;    firmware  on UEFI PCs, the PC's own network driver through the UEFI
;              Simple Network Protocol (nic_snp.asm). It works with whatever
;              card the firmware supports (Realtek, Intel, Broadcom, some USB
;              Ethernet adapters...), so on UEFI it is tried first.
;    rtl8168   RealTek RTL8111/8168/8169/810x - the usual onboard Ethernet on
;              consumer motherboards (nic_rtl8168.asm)
;    e1000     Intel PRO/1000: 82540/82545 (VirtualBox, QEMU), 8257x, and the
;              I217/I218/I219 built into Intel-chipset boards (nic_e1000.asm)
;    rtl8139   RealTek RTL8139 (QEMU's default card, old PCs) - below
;  Every PCI bus is searched; "net cards" lists what is there.
;  Wi-Fi is not supported (it would need a USB stack, the chip's firmware,
;  802.11 and WPA2).
;
;  Layers, each built on the one below:
;    Ethernet   framing, with a small ARP cache for finding MAC addresses
;    IPv4       one network, a gateway for everything off it
;    UDP        used by DHCP (get an address), DNS (names) and NTP (time)
;    TCP        a small client (net_tcp.asm) for HTTP and HTTPS
;
;  DMA note: MOOS uses flat, identity-mapped memory, so a buffer's address is
;  also its physical address - cards DMA straight to/from NET_BUF/NET_RING.
;
;  All multi-byte network fields are big-endian; x86 is little-endian, so the
;  code byte-swaps with bswap / xchg where it crosses that boundary.
; =============================================================================

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
NET_RX      equ NET_RING             ; RTL8139 receive ring: 32K + wrap room
NET_TX      equ NET_BUF + 0x2800     ; 4 transmit buffers of 2 KB
NET_PKT     equ NET_BUF + 0x4800     ; build one outgoing packet here
NET_RXP     equ NET_BUF + 0x5800     ; a received packet, copied out of the ring

; descriptor-ring cards (e1000, rtl8168) share this layout in NET_RING
NIC_RXN     equ 16                   ; receive descriptors / 2 KB buffers
NIC_TXN     equ 8                    ; transmit descriptors / 2 KB buffers
NIC_RXBUF   equ NET_RING + 0x0000    ; 16 x 2 KB
NIC_RXDESC  equ NET_RING + 0x8000    ; 16 x 16 bytes (256-byte aligned)
NIC_TXDESC  equ NET_RING + 0x8100    ; 8 x 16 bytes
NIC_TXBUF   equ NET_RING + 0x9000    ; 8 x 2 KB

NIC_NONE    equ 0                    ; nic_kind values (also table drivers)
NIC_RTL8139 equ 1
NIC_E1000   equ 2
NIC_RTL8168 equ 3
NIC_SNP     equ 4

NET_AUTO     equ 0                   ; nic_prefer: which drivers "net up" tries
NET_NATIVE   equ 1
NET_FIRMWARE equ 2

E1K_PCH     equ 1                    ; card table flags for e1000
E1K_EERD2   equ 2

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
nic_kind        resb 1
nic_prefer      resb 1
net_link        resb 1              ; 1 once the cable link is up
alignb 4
nic_io          resd 1              ; I/O port base (0 if memory-mapped)
nic_mmio        resd 1              ; memory-mapped register base
nic_pci         resd 1              ; PCI address of the card
nic_vendev      resd 1              ; device << 16 | vendor
nic_name        resd 1
nic_flags       resd 1
nic_mac         resb 6
alignb 4
tx_slot         resd 1
rx_offset       resd 1
rx_cur          resd 1
my_ip           resd 1              ; all IPs stored in network byte order
my_mask         resd 1
gw_ip           resd 1
dns_ip          resd 1
dhcp_server     resd 1
dhcp_xid        resd 1
arp_ip          resd 1              ; one-entry ARP cache
arp_mac         resb 6
alignb 4
ip_ident        resd 1
rx_frame        resd 1              ; last received frame (in NET_RXP)
rx_len          resd 1
net_err         resd 1
udp_src_port    resd 1
net_scratch     resd 1
nic_wait        resd 1

section .data
mac_bcast       db 0xFF,0xFF,0xFF,0xFF,0xFF,0xFF
err_no_nic      db "no supported network card found - type 'net cards' to see what MOOS found", 0
err_no_fw       db "the PC's firmware offers no network driver (see 'man net')", 0
err_nic_init    db "the network card did not start", 0
err_no_link     db "no link - is a network cable plugged in?", 0
err_no_dhcp     db "no reply from DHCP - is the network connected?", 0
err_timeout     db "the network did not reply in time", 0
err_dns         db "could not look up that name", 0
err_not_up      db "the network is not connected - run 'net up' first", 0
err_bar         db "the card's registers are above 4 GB (not reachable)", 0

; ---------------------------------------------------------- known cards
; NICID vendor, device, driver, flags, name
%macro NICID 5
    dw %1, %2
    db %3, %4, 0, 0
    dd %5
%endmacro
NT_VENDOR   equ 0
NT_DEVICE   equ 2
NT_DRIVER   equ 4
NT_FLAGS    equ 5
NT_NAME     equ 8
NT_SIZE     equ 12

nm_rtl8139  db "RealTek RTL8139", 0
nm_rtl8168  db "RealTek RTL8111/8168 Gigabit", 0
nm_rtl8169  db "RealTek RTL8169 Gigabit", 0
nm_rtl810x  db "RealTek RTL810x Fast Ethernet", 0
nm_rtl8125  db "RealTek RTL8125 2.5G (UEFI driver only)", 0
nm_e1000    db "Intel PRO/1000 (e1000)", 0
nm_e1000e   db "Intel 8257x Gigabit (e1000e)", 0
nm_ich      db "Intel ICH8-10 LAN (e1000e)", 0
nm_pch      db "Intel I217/I218/I219 / 8257x (e1000e)", 0
nm_igb      db "Intel I210/I211/I350 (UEFI driver only)", 0
nm_igc      db "Intel I225/I226 2.5G (UEFI driver only)", 0
nm_virtio   db "virtio network (UEFI driver only)", 0
nm_wireless db "a Wi-Fi / wireless card (not supported)", 0
nm_other    db "an Ethernet card MOOS has no driver for", 0
nm_fw       db "UEFI firmware network driver", 0

nic_table:
    ; --- RealTek
    NICID 0x10EC, 0x8139, NIC_RTL8139, 0, nm_rtl8139
    NICID 0x1113, 0x1211, NIC_RTL8139, 0, nm_rtl8139
    NICID 0x10EC, 0x8168, NIC_RTL8168, 0, nm_rtl8168
    NICID 0x10EC, 0x8161, NIC_RTL8168, 0, nm_rtl8168
    NICID 0x10EC, 0x8162, NIC_RTL8168, 0, nm_rtl8168
    NICID 0x10EC, 0x8167, NIC_RTL8168, 0, nm_rtl8169
    NICID 0x10EC, 0x8169, NIC_RTL8168, 0, nm_rtl8169
    NICID 0x10EC, 0x8136, NIC_RTL8168, 0, nm_rtl810x
    NICID 0x1186, 0x4300, NIC_RTL8168, 0, nm_rtl8169
    NICID 0x1186, 0x4302, NIC_RTL8168, 0, nm_rtl8169
    NICID 0x10EC, 0x8125, NIC_NONE, 0, nm_rtl8125
    NICID 0x10EC, 0x3000, NIC_NONE, 0, nm_rtl8125
    ; --- Intel PRO/1000 (classic e1000)
%macro E1K 1-*
  %rep %0
    NICID 0x8086, %1, NIC_E1000, 0, nm_e1000
    %rotate 1
  %endrep
%endmacro
%macro E1KE 1-*
  %rep %0
    NICID 0x8086, %1, NIC_E1000, E1K_EERD2, nm_e1000e
    %rotate 1
  %endrep
%endmacro
%macro E1KICH 1-*
  %rep %0
    NICID 0x8086, %1, NIC_E1000, E1K_PCH, nm_ich
    %rotate 1
  %endrep
%endmacro
%macro E1KPCH 1-*
  %rep %0
    NICID 0x8086, %1, NIC_E1000, E1K_PCH, nm_pch
    %rotate 1
  %endrep
%endmacro
%macro IGB 1-*
  %rep %0
    NICID 0x8086, %1, NIC_NONE, 0, nm_igb
    %rotate 1
  %endrep
%endmacro
%macro IGC 1-*
  %rep %0
    NICID 0x8086, %1, NIC_NONE, 0, nm_igc
    %rotate 1
  %endrep
%endmacro
    E1K 0x1000, 0x1001, 0x1004, 0x1008, 0x1009, 0x100C, 0x100D, 0x100E
    E1K 0x100F, 0x1010, 0x1011, 0x1012, 0x1013, 0x1014, 0x1015, 0x1016
    E1K 0x1017, 0x1018, 0x1019, 0x101A, 0x101D, 0x101E, 0x1026, 0x1027
    E1K 0x1028, 0x1075, 0x1076, 0x1077, 0x1078, 0x1079, 0x107A, 0x107B
    E1K 0x107C, 0x108A, 0x1099, 0x10B5, 0x1107, 0x1112
    E1KE 0x105E, 0x105F, 0x10A4, 0x10BC, 0x10D5, 0x10D9, 0x10DA, 0x107D
    E1KE 0x107E, 0x107F, 0x10B9, 0x108B, 0x108C, 0x109A, 0x10D3, 0x10F6
    E1KE 0x150C, 0x1096, 0x1098, 0x10BA, 0x10BB
    E1KICH 0x1049, 0x104A, 0x104B, 0x104C, 0x104D, 0x10BD, 0x10BF, 0x10C0
    E1KICH 0x10C2, 0x10C3, 0x10C4, 0x10C5, 0x10CB, 0x10CC, 0x10CD, 0x10CE
    E1KICH 0x10DE, 0x10DF, 0x10E5, 0x10F5, 0x294C
    E1KPCH 0x10EA, 0x10EB, 0x10EF, 0x10F0, 0x1502, 0x1503, 0x153A, 0x153B
    E1KPCH 0x155A, 0x1559, 0x15A0, 0x15A1, 0x15A2, 0x15A3, 0x156F, 0x1570
    E1KPCH 0x15B7, 0x15B8, 0x15B9, 0x15D7, 0x15D8, 0x15E3, 0x15D6, 0x15BD
    E1KPCH 0x15BE, 0x15BB, 0x15BC, 0x15DF, 0x15E0, 0x15E1, 0x15E2, 0x0D4E
    E1KPCH 0x0D4F, 0x0D4C, 0x0D4D, 0x0D53, 0x0D55, 0x15FB, 0x15FC, 0x15F9
    E1KPCH 0x15FA, 0x15F4, 0x15F5, 0x0DC5, 0x0DC6, 0x1A1E, 0x1A1F, 0x1A1C
    E1KPCH 0x1A1D, 0x0DC7, 0x0DC8, 0x550A, 0x550B, 0x550C, 0x550D, 0x550E
    E1KPCH 0x550F, 0x5510, 0x5511, 0x57A0, 0x57A1, 0x57B3, 0x57B4, 0x57B5
    E1KPCH 0x57B6, 0x57B7, 0x57B8, 0x57B9, 0x57BA
    IGB 0x10A7, 0x10A9, 0x10C9, 0x10E6, 0x10E7, 0x10E8, 0x1526
    IGB 0x150A, 0x1518, 0x150D, 0x10D6, 0x1521, 0x1522, 0x1523
    IGB 0x1524, 0x1533, 0x1536, 0x1537, 0x1538, 0x1539, 0x157B
    IGB 0x157C, 0x15F6, 0x1F40, 0x1F41, 0x1F45
    IGC 0x15F2, 0x15F3, 0x125B, 0x125C, 0x125D, 0x125F, 0x3100
    IGC 0x3101, 0x0D9F, 0x5502, 0x5503
    NICID 0x1AF4, 0x1000, NIC_NONE, 0, nm_virtio
    NICID 0x1AF4, 0x1041, NIC_NONE, 0, nm_virtio
    dd 0, 0, 0                          ; end

section .text

; ================================================================ PCI access
; pci_read32: EBX = bus<<16|dev<<11|fn<<8, AL = register offset -> EAX
pci_read32:
    push ebx
    push edx
    movzx eax, al
    and al, 0xFC                    ; offset (dword aligned)
    and ebx, 0xFFFFFF00             ; address without the offset byte
    or ebx, eax
    or ebx, 0x80000000              ; enable bit
    mov eax, ebx
    mov dx, 0xCF8
    out dx, eax
    mov dx, 0xCFC
    in eax, dx
    pop edx
    pop ebx
    ret

; pci_write32: EBX = address, AL = register offset, ECX = value
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

; pci_next: EBX = the last function found (-1 to start) -> EBX = the next
; function that exists on any bus, EAX = its device << 16 | vendor.
; CF=1 when the scan is finished.
pci_next:
    cmp ebx, -1
    jne .advance
    xor ebx, ebx
    jmp .probe
.advance:
    test ebx, 0x700                 ; on function 0: is it multi-function?
    jnz .next_fn
    mov al, 0x0C
    call pci_read32
    test eax, 0x00800000            ; header type bit 7
    jnz .next_fn
.next_dev:
    and ebx, 0xFFFFF800
    add ebx, 0x800
    jmp .check
.next_fn:
    add ebx, 0x100
.check:
    cmp ebx, 0x01000000             ; past bus 255
    jae .end
.probe:
    mov al, 0
    call pci_read32
    cmp ax, 0xFFFF
    jne .found
    test ebx, 0x700                 ; no function 0: skip the whole device
    jz .next_dev
    jmp .next_fn
.found:
    clc
    ret
.end:
    stc
    ret

; nic_lookup: EAX = device << 16 | vendor -> ESI = card table entry, CF=1 if
; the card is not in the table
nic_lookup:
    push ecx
    mov esi, nic_table
.l: mov ecx, [esi]
    test ecx, ecx
    jz .no
    cmp ecx, eax
    je .yes
    add esi, NT_SIZE
    jmp .l
.yes:
    pop ecx
    clc
    ret
.no:
    pop ecx
    stc
    ret

; pci_enable: EBX = card -> turn on its I/O and memory decoding and let it
; DMA (bus mastering)
pci_enable:
    pushad
    mov al, 0x04
    call pci_read32
    or eax, 0x07
    mov ecx, eax
    mov al, 0x04
    call pci_write32
    popad
    ret

; pci_mmio_bar: EBX = card, AL = BAR offset (0x10, 0x18 ...) -> EAX = memory
; base, CF=1 if it is not a memory BAR or lies above 4 GB
pci_mmio_bar:
    push ecx
    mov cl, al
    call pci_read32
    test al, 1                      ; I/O BAR, not memory
    jnz .bad
    mov ch, al
    and ch, 0x06
    cmp ch, 0x04                    ; 64-bit BAR: the high half must be 0
    jne .low
    push eax
    mov al, cl
    add al, 4
    call pci_read32
    test eax, eax
    pop eax
    jnz .bad
.low:
    and eax, 0xFFFFFFF0
    jz .bad
    pop ecx
    clc
    ret
.bad:
    pop ecx
    stc
    ret

; net_detect: find and start a network card. CF=1 (ESI = message) if none.
; On UEFI the firmware's own driver is tried first (unless nic_prefer says
; otherwise), then MOOS's drivers for the cards in nic_table.
net_detect:
    pushad
    mov byte [net_present], 0
    mov byte [net_up], 0
    mov byte [nic_kind], NIC_NONE
    mov byte [net_link], 0
    cmp dword [bootinfo + BI.platform], PLATFORM_UEFI
    jne .native
    cmp byte [nic_prefer], NET_NATIVE
    je .native
    call snp_start
    jnc .found
    mov dword [net_err], err_no_fw
    cmp byte [nic_prefer], NET_FIRMWARE
    je .fail
.native:
    mov dword [net_err], err_no_nic
    mov ebx, -1
.scan:
    call pci_next
    jc .fail
    call nic_lookup
    jc .scan
    movzx ecx, byte [esi + NT_DRIVER]
    test ecx, ecx
    jz .scan                        ; known, but no MOOS driver
    mov [nic_pci], ebx
    mov [nic_vendev], eax
    mov [nic_wait], ecx             ; (driver kind)
    mov eax, [esi + NT_NAME]
    mov [nic_name], eax
    movzx eax, byte [esi + NT_FLAGS]
    mov [nic_flags], eax
    mov dword [nic_io], 0
    mov dword [nic_mmio], 0
    call pci_enable
    cmp ecx, NIC_RTL8139
    je .r39
    cmp ecx, NIC_E1000
    je .e1k
    call r8168_init
    jmp .inited
.r39:
    call rtl39_init
    jmp .inited
.e1k:
    call e1000_init
.inited:
    mov ebx, [nic_pci]
    jc .scan                        ; that card would not start: keep looking
    mov eax, [nic_wait]
    mov [nic_kind], al
.found:
    mov byte [net_present], 1
    call nic_link_wait
    popad
    clc
    ret
.fail:
    popad
    mov esi, [net_err]
    stc
    ret

; nic_link_up -> CF=0 if the card reports a cable link
nic_link_up:
    cmp byte [nic_kind], NIC_E1000
    je e1000_link
    cmp byte [nic_kind], NIC_RTL8168
    je r8168_link
    cmp byte [nic_kind], NIC_SNP
    je snp_link
    clc                             ; RTL8139: assume the link is there
    ret

; nic_link_wait: give the link up to ~6 s to come up; sets net_link
nic_link_wait:
    pushad
    mov eax, [ticks]
    add eax, 600
    mov [nic_wait], eax
.l: call nic_link_up
    jnc .up
    call status_tick
    call screen_present
    mov eax, [ticks]
    cmp eax, [nic_wait]
    jb .l
    mov byte [net_link], 0
    popad
    ret
.up:
    mov byte [net_link], 1
    popad
    ret

; net_tx_frame: ESI = frame, ECX = length (14..1792). Sends it on whichever
; card is in use. Registers kept.
net_tx_frame:
    cmp ecx, 1792
    ja .r
    cmp byte [nic_kind], NIC_E1000
    je e1000_tx
    cmp byte [nic_kind], NIC_RTL8168
    je r8168_tx
    cmp byte [nic_kind], NIC_SNP
    je snp_tx
    cmp byte [nic_kind], NIC_RTL8139
    je rtl39_tx
.r: ret

; net_rx_poll: if a frame has arrived, copy it to NET_RXP and set rx_frame /
; rx_len, CF=0. CF=1 when nothing is waiting.
net_rx_poll:
    cmp byte [nic_kind], NIC_E1000
    je e1000_rx
    cmp byte [nic_kind], NIC_RTL8168
    je r8168_rx
    cmp byte [nic_kind], NIC_SNP
    je snp_rx
    cmp byte [nic_kind], NIC_RTL8139
    je rtl39_rx
    stc
    ret

; nic_pad60: EDI = end of a frame copied into a transmit buffer, ECX = its
; length -> zero-pads to 60 bytes (Ethernet's minimum). ECX updated.
nic_pad60:
.l: cmp ecx, 60
    jae .r
    mov byte [edi], 0
    inc edi
    inc ecx
    jmp .l
.r: ret

; ======================================================= RealTek RTL8139
; rtl39_init: EBX = card -> CF=1 if it cannot be used
rtl39_init:
    pushad
    mov al, 0x10                    ; BAR0 = I/O ports
    call pci_read32
    test al, 1
    jz .bad
    and eax, 0xFFFFFFFC
    jz .bad
    mov [nic_io], eax
    call rtl39_reset
    popad
    clc
    ret
.bad:
    mov dword [net_err], err_nic_init
    popad
    stc
    ret

; ================================================================ NIC driver
; register helpers: CL = offset, value in AL/AX/EAX
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

rtl39_reset:
    mov cl, RTL_CONFIG1             ; power on
    mov al, 0
    call nic_out8
    mov cl, RTL_CR                  ; software reset
    mov al, 0x10
    call nic_out8
    mov ebx, 0x400000               ; bounded wait for reset to finish
.wait:
    mov cl, RTL_CR
    call nic_in8
    test al, 0x10
    jz .reset_done
    dec ebx
    jnz .wait
.reset_done:
    mov cl, RTL_RBSTART             ; receive ring buffer address
    mov eax, NET_RX
    call nic_out32
    mov cl, RTL_IMR                 ; mask every interrupt (we poll)
    xor ax, ax
    call nic_out16
    mov cl, RTL_ISR
    mov ax, 0xFFFF
    call nic_out16
    mov cl, RTL_RCR                 ; broadcast + our MAC, unlimited DMA,
    mov eax, 0x0000178A            ; 32K ring, WRAP (packets stay contiguous)
    call nic_out32
    mov cl, RTL_TCR
    mov eax, 0x03000600
    call nic_out32
    mov cl, RTL_CR                  ; enable receive and transmit
    mov al, 0x0C
    call nic_out8
    mov dword [tx_slot], 0
    mov dword [rx_offset], 0
    mov cl, RTL_IDR0                ; our MAC address
    call nic_in32
    mov [nic_mac], eax
    mov cl, RTL_IDR0 + 4
    call nic_in16
    mov [nic_mac + 4], ax
    ret

; rtl39_tx: ESI = frame, ECX = length. Blocks until sent or a short
; timeout. Pads to 60 bytes.
rtl39_tx:
    pushad
    cmp ecx, 1792
    ja .done
    mov ebx, [tx_slot]
    mov edi, ebx
    shl edi, 11
    add edi, NET_TX                 ; EDI = this slot's buffer
    push ecx
    rep movsb
    pop ecx
    cmp ecx, 60
    jae .padded
.pad_loop:                          ; pad short frames up to 60 bytes
    mov byte [edi], 0
    inc edi
    inc ecx
    cmp ecx, 60
    jb .pad_loop
.padded:
    mov eax, ebx                    ; TSAD[slot] = buffer physical address
    shl eax, 2
    mov edx, eax
    add edx, RTL_TSAD0
    add edx, [nic_io]
    mov eax, ebx
    shl eax, 11
    add eax, NET_TX
    out dx, eax
    mov eax, ebx                    ; TSD[slot] = length (starts the send)
    shl eax, 2
    mov edx, eax
    add edx, RTL_TSD0
    add edx, [nic_io]
    mov eax, ecx
    or eax, 0x00300000              ; early-TX threshold (avoid FIFO underrun)
    out dx, eax
    mov ecx, 0x200000               ; wait for completion (OWN, bit 13)
.wait:
    in eax, dx
    test eax, 0x2000
    jnz .sent
    dec ecx
    jnz .wait
.sent:
    inc ebx                         ; next descriptor
    and ebx, 3
    mov [tx_slot], ebx
.done:
    popad
    ret

section .bss
net_scratch_deadline resd 1
section .text

; rtl39_rx: if a packet is waiting, copy it to NET_RXP and set rx_frame /
; rx_len, CF=0. CF=1 when nothing is waiting.
rtl39_rx:
    push eax
    push ebx
    push ecx
    push esi
    push edi
    mov cl, RTL_CR
    call nic_in8
    test al, 0x01                   ; BUFE: receive buffer empty?
    jnz .empty
    mov esi, [rx_offset]
    add esi, NET_RX
    movzx eax, word [esi]           ; receive status
    test al, 0x01                   ; ROK?
    jz .bad
    movzx ecx, word [esi + 2]       ; length (includes 4-byte CRC)
    cmp ecx, 4
    jbe .bad
    sub ecx, 4
    cmp ecx, 1600
    ja .bad
    mov [rx_len], ecx
    lea esi, [esi + 4]              ; packet data
    mov edi, NET_RXP
    mov [rx_frame], edi
    push ecx
    rep movsb
    pop ecx
    add ecx, 4 + 4                  ; status + length + CRC
    add ecx, [rx_offset]
    add ecx, 3                      ; round up to 4 (dword align)
    and ecx, ~3
    and ecx, RX_BUF_LEN - 1         ; wrap in the 32K ring
    mov [rx_offset], ecx
    lea eax, [ecx - 16]            ; tell the card where we are (CAPR)
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
    call rtl39_reset                  ; ring confused: reset and drop
.empty:
    pop edi
    pop esi
    pop ecx
    pop ebx
    pop eax
    stc
    ret

; ================================================================= Ethernet
; eth_build: EDI = frame buffer, ESI = dest MAC, AX = ethertype.
; Returns EDI advanced past the 14-byte header.
eth_build:
    push eax
    push ecx
    push esi
    mov ecx, 6                      ; destination MAC
    rep movsb
    mov esi, nic_mac                ; source MAC
    mov ecx, 6
    rep movsb
    xchg ah, al                     ; ethertype, big-endian
    stosw
    pop esi
    pop ecx
    pop eax
    ret

; ================================================================= checksums
; ip_checksum: ESI = data, ECX = byte count -> AX = Internet checksum
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

%include "src/nic_e1000.asm"
%include "src/nic_rtl8168.asm"
%include "src/nic_snp.asm"
%include "src/net_arp.asm"
%include "src/net_ip.asm"
%include "src/net_dhcp.asm"
%include "src/net_dns.asm"
%include "src/net_tcp.asm"

; net_up_bring: start the card (if needed) and get an address by DHCP.
; CF=0 on success; CF=1 with ESI = message otherwise.
net_up_bring:
    cmp byte [net_present], 0
    jne .have_nic
    call net_detect
    jc .fail
.have_nic:
    call dhcp_configure
    jc .dhcp_fail
    mov byte [net_up], 1
    clc
    ret
.dhcp_fail:
    cmp byte [net_link], 0          ; no link: say so, it is the likely cause
    jne .fail
    mov esi, err_no_link
.fail:
    stc
    ret

; net_wait_ticks_rx: poll for a received packet until the deadline in
; net_scratch_deadline (a ticks value). CF=0 if one arrived. Keeps the
; screen/clock alive.
net_poll_until:                     ; EAX = deadline in ticks
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
