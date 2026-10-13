; =============================================================================
;  nic_snp.asm - use the PC firmware's own network driver (UEFI only)
;
;  UEFI firmware that can network-boot (PXE / HTTP boot) carries a driver
;  for the board's Ethernet chip and offers it to programs through the
;  Simple Network Protocol (SNP): raw Ethernet frames in and out. MOOS keeps
;  the firmware running, so it can use that driver for any card the firmware
;  supports - Realtek, Intel, Broadcom, and some USB Ethernet adapters.
;  Most firmware only loads it when "Network Stack" (or PXE / LAN option
;  ROM) is enabled in its setup screens.
;
;  The 64-bit routines run through efi64 (see efi.asm); the 32-bit side keeps
;  the same driver interface as the others (snp_tx / snp_rx / snp_link).
; =============================================================================
SNP_TXBUF   equ NET_RING + 0xD000       ; the frame being sent (2 KB)

section .data
guid_snp    dd 0xA19832B9
            dw 0xAC25, 0x11D3
            db 0x9A, 0x2D, 0x00, 0x90, 0x27, 0x3F, 0xC1, 0x4D

section .bss
alignb 8
snp_if      resq 1                  ; EFI_SIMPLE_NETWORK_PROTOCOL *
snp_count   resq 1
snp_handles resq 1
snp_tmp     resq 1
snp_rxlen   resq 1
snp_txret   resq 1
snp_istat   resq 1
snp_txlen   resd 1

section .text
bits 32

; snp_start: find and start a firmware network driver. CF=1 if there is none.
snp_start:
    pushad
    mov eax, efi_snp_start64
    call efi64
    test eax, eax
    jz .none
    mov byte [nic_kind], NIC_SNP
    mov dword [nic_name], nm_fw
    mov dword [nic_pci], 0
    mov dword [nic_vendev], 0
    popad
    clc
    ret
.none:
    popad
    stc
    ret

; snp_tx: ESI = frame, ECX = length. Registers kept.
snp_tx:
    pushad
    mov edi, SNP_TXBUF
    rep movsb
    mov ecx, [esp + 24]             ; (length, from the pushad frame)
    call nic_pad60
    mov [snp_txlen], ecx
    mov eax, efi_snp_tx64
    call efi64
    popad
    ret

; snp_rx: next received frame -> NET_RXP (rx_frame / rx_len), CF=0;
; CF=1 when none is waiting
snp_rx:
    pushad
    mov eax, efi_snp_rx64
    call efi64
    test eax, eax
    jz .none
    mov [rx_len], eax
    mov dword [rx_frame], NET_RXP
    popad
    clc
    ret
.none:
    popad
    stc
    ret

; snp_link -> CF=0 if the cable is in (or the firmware cannot tell)
snp_link:
    push eax
    mov eax, efi_snp_link64
    call efi64
    test eax, eax
    pop eax
    jz .down
    clc
    ret
.down:
    stc
    ret

bits 64

; connect_all64: ask the firmware to start drivers for every device, so the
; network card's driver binds even if the firmware did not need it to boot.
; Called from a 64-bit routine (stack 16-byte aligned before the call).
connect_all64:
    push r12
    push r13
    push r14
    sub rsp, 48
    mov rax, [rel bootinfo + BI.bs]
    xor ecx, ecx                        ; AllHandles
    xor edx, edx
    xor r8d, r8d
    lea r9, [rel snp_count]
    lea r10, [rel snp_handles]
    mov [rsp + 32], r10
    call [rax + 312]                    ; LocateHandleBuffer
    test rax, rax
    jnz .done
    mov r12, [rel snp_handles]
    mov r13, [rel snp_count]
    xor r14d, r14d
.l: cmp r14, r13
    jae .free
    mov rax, [rel bootinfo + BI.bs]
    mov rcx, [r12 + r14 * 8]
    xor edx, edx
    xor r8d, r8d
    mov r9d, 1                          ; recursively
    call [rax + 264]                    ; ConnectController
    inc r14
    jmp .l
.free:
    mov rax, [rel bootinfo + BI.bs]
    mov rcx, r12
    call [rax + 72]                     ; FreePool
.done:
    add rsp, 48
    pop r14
    pop r13
    pop r12
    ret

; efi_snp_start64 -> EAX = 1 with snp_if ready and nic_mac set, 0 if none
efi_snp_start64:
    ENTER64
    call connect_all64
    mov rax, [rel bootinfo + BI.bs]
    mov ecx, 2                          ; ByProtocol
    lea rdx, [rel guid_snp]
    xor r8d, r8d
    lea r9, [rel snp_count]
    lea r10, [rel snp_handles]
    mov [rsp + 32], r10
    call [rax + 312]                    ; LocateHandleBuffer
    test rax, rax
    jnz .none
    mov r12, [rel snp_handles]
    mov r13, [rel snp_count]
    xor r14d, r14d
    xor r15d, r15d                      ; the chosen interface
.h: cmp r14, r13
    jae .picked
    mov rax, [rel bootinfo + BI.bs]
    mov rcx, [r12 + r14 * 8]
    lea rdx, [rel guid_snp]
    lea r8, [rel snp_tmp]
    call [rax + 152]                    ; HandleProtocol
    test rax, rax
    jnz .next
    mov rsi, [rel snp_tmp]
    mov rdi, [rsi + 120]                ; Mode
    cmp dword [rdi + 4], 6              ; Ethernet-style 6-byte addresses
    jne .next
    test r15, r15                       ; remember the first one ...
    jnz .first_set
    mov r15, rsi
.first_set:
    cmp byte [rdi + 651], 0             ; ... but prefer one with a cable in
    je .next
    cmp byte [rdi + 652], 0
    je .next
    mov r15, rsi
    jmp .picked
.next:
    inc r14
    jmp .h
.picked:
    mov rax, [rel bootinfo + BI.bs]
    mov rcx, r12
    call [rax + 72]                     ; FreePool
    test r15, r15
    jz .none
    mov [rel snp_if], r15
    mov rdi, [r15 + 120]
    cmp dword [rdi], 0                  ; Stopped -> Start
    jne .started
    mov rcx, r15
    call [r15 + 8]
.started:
    mov rdi, [r15 + 120]
    cmp dword [rdi], 1                  ; Started -> Initialize
    jne .initialized
    mov rcx, r15
    xor edx, edx
    xor r8d, r8d
    call [r15 + 24]
.initialized:
    mov rdi, [r15 + 120]
    cmp dword [rdi], 2                  ; must be Initialized now
    jne .none
    mov edx, [rdi + 24]                 ; receive: our address + broadcast
    and edx, 0x05
    mov rcx, r15
    xor r8d, r8d
    xor r9d, r9d
    mov qword [rsp + 32], 0
    mov qword [rsp + 40], 0
    call [r15 + 48]                     ; ReceiveFilters
    mov rdi, [r15 + 120]
    mov eax, [rdi + 552]                ; CurrentAddress
    mov [rel nic_mac], eax
    mov ax, [rdi + 556]
    mov [rel nic_mac + 4], ax
    mov eax, 1
    LEAVE64
.none:
    xor eax, eax
    LEAVE64

; efi_snp_probe64 -> EAX = how many firmware network interfaces there are
efi_snp_probe64:
    ENTER64
    call connect_all64
    mov rax, [rel bootinfo + BI.bs]
    mov ecx, 2                          ; ByProtocol
    lea rdx, [rel guid_snp]
    xor r8d, r8d
    lea r9, [rel snp_count]
    lea r10, [rel snp_handles]
    mov [rsp + 32], r10
    call [rax + 312]                    ; LocateHandleBuffer
    test rax, rax
    jnz .none
    mov rax, [rel bootinfo + BI.bs]
    mov rcx, [rel snp_handles]
    call [rax + 72]                     ; FreePool
    mov eax, [rel snp_count]
    LEAVE64
.none:
    xor eax, eax
    LEAVE64

; efi_snp_tx64: send snp_txlen bytes from SNP_TXBUF and wait until the
; firmware hands the buffer back
efi_snp_tx64:
    ENTER64
    mov rsi, [rel snp_if]
    mov ebx, 8                          ; tries while its queue is full
.try:
    mov rcx, rsi
    xor edx, edx                        ; HeaderSize 0: the frame is complete
    mov r8d, [rel snp_txlen]
    mov r9d, SNP_TXBUF
    mov qword [rsp + 32], 0
    mov qword [rsp + 40], 0
    mov qword [rsp + 48], 0
    call [rsi + 96]                     ; Transmit
    test rax, rax
    jz .sent
    mov rcx, rsi                        ; not ready: recycle, try again
    xor edx, edx
    lea r8, [rel snp_txret]
    call [rsi + 88]                     ; GetStatus
    dec ebx
    jnz .try
    jmp .done
.sent:
    mov ebx, 20000
.recycle:
    mov qword [rel snp_txret], 0
    mov rcx, rsi
    xor edx, edx
    lea r8, [rel snp_txret]
    call [rsi + 88]                     ; GetStatus
    cmp qword [rel snp_txret], 0
    jne .done                           ; our buffer came back
    dec ebx
    jnz .recycle
.done:
    xor eax, eax
    LEAVE64

; efi_snp_rx64 -> EAX = length of a frame now in NET_RXP, 0 if none
efi_snp_rx64:
    ENTER64
    mov rsi, [rel snp_if]
    mov qword [rel snp_rxlen], 2048
    mov rcx, rsi
    xor edx, edx                        ; HeaderSize: not needed
    lea r8, [rel snp_rxlen]
    mov r9d, NET_RXP
    mov qword [rsp + 32], 0
    mov qword [rsp + 40], 0
    mov qword [rsp + 48], 0
    call [rsi + 104]                    ; Receive
    test rax, rax
    jnz .none
    mov eax, [rel snp_rxlen]
    LEAVE64
.none:
    xor eax, eax
    LEAVE64

; efi_snp_link64 -> EAX = 1 if the cable is in (or the firmware cannot tell)
efi_snp_link64:
    ENTER64
    mov rsi, [rel snp_if]
    mov rdi, [rsi + 120]
    mov eax, 1
    cmp byte [rdi + 651], 0             ; MediaPresentSupported?
    je .done
    mov rcx, rsi                        ; GetStatus refreshes MediaPresent
    lea rdx, [rel snp_istat]
    xor r8d, r8d
    call [rsi + 88]
    mov rdi, [rsi + 120]
    movzx eax, byte [rdi + 652]
.done:
    LEAVE64

bits 32
