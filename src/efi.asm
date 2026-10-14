; =============================================================================
;  efi.asm - using the UEFI firmware from the kernel
;
;  Under UEFI the kernel runs in 32-bit "compatibility mode" inside the
;  firmware's 64-bit environment. To ask the firmware for something, efi64
;  jumps into a small 64-bit routine below (a far call to the firmware's
;  64-bit code segment), which calls the firmware with the Microsoft x64
;  calling convention and jumps back.
;
;  The firmware does all the hardware work: keyboard (USB or PS/2), disks
;  (USB, SATA, NVMe, ...), the clock and power off. MOOS only draws the
;  screen itself, straight into the graphics framebuffer.
;
;  64-bit routines may only use RIP-relative addresses, so they work
;  wherever the loader put the kernel.
; =============================================================================
EFI_CHUNK   equ 128                     ; sectors per disk request (64 KB)
MAX_DISKS   equ 16
MAX_PTRS    equ 8                       ; mice / touch devices we listen to
PTR_ABS     equ 1                       ; Absolute Pointer (tablet, touch screen)
PTR_REL     equ 2                       ; Simple Pointer (an ordinary mouse)
PTR_VIRT    equ 0x80                    ; (flag) the firmware's "all of them"

; disk table entry, filled by efi_list_disks (UEFI) / bios_list_disks (BIOS)
DT_HANDLE   equ 0                       ; Block I/O protocol (UEFI)
DT_DRIVE    equ 0                       ; drive number (BIOS)
DT_SECTORS  equ 8                       ; number of sectors (64-bit)
DT_BSIZE    equ 16                      ; bytes per sector
DT_FLAGS    equ 20                      ; DF_* below
DT_TYPE     equ 24                      ; DTYPE_* below
DT_SIZE     equ 32
DF_REMOVABLE equ 1
DF_READONLY equ 2
DF_BOOT     equ 4                       ; MOOS is running from this disk
DTYPE_DISK  equ 0                       ; kinds of disk (for the installer)
DTYPE_USB   equ 1
DTYPE_NVME  equ 2
DTYPE_SATA  equ 3
DTYPE_ATA   equ 4
DTYPE_SCSI  equ 5
DTYPE_SD    equ 6
DTYPE_EMMC  equ 7

section .bss
alignb 8
efi_far     resd 2                      ; far pointer: 64-bit routine
efi_cur_bio resq 1                      ; Block I/O used by efi_read/write
efi_time    resb 16                     ; EFI_TIME
efi_key     resd 1                      ; EFI_INPUT_KEY
efi_index   resq 1
efi_tmp     resq 2
fw_name     resb 48
disk_tab    resb MAX_DISKS * DT_SIZE
disk_count  resd 1
fb_scale    resd 1                      ; 1 or 2: pixels per font pixel
fb_cellw    resd 1                      ; one character cell in pixels
fb_cellh    resd 1
fb_x0       resd 1                      ; where the 80x25 text area starts
fb_y0       resd 1
fb_palette  resd 16                     ; the 16 colours in screen format
cell_px     resd 1
cell_py     resd 1
drawn_cursor resd 1
alignb 16
cell_buf    resd 16 * 32                ; one cell, for Blt-only screens
alignb 8
ptr_ifs     resq MAX_PTRS       ; pointer devices: Absolute or Simple Pointer
ptr_kinds   resb MAX_PTRS       ; PTR_ABS / PTR_REL for each
ptr_state   resb 40             ; the state GetState fills in
alignb 4
ptr_n       resd 1              ; how many were found
ptr_real    resd 3              ; real devices of each kind (by PTR_ABS/REL)
ptr_accx    resd 1              ; leftover sixteenths of a pixel (relative mice)
ptr_accy    resd 1
mouse_x     resd 1
mouse_y     resd 1
mouse_btn   resd 1
mouse_wheel resd 1              ; wheel turns not yet used (+ = away from you)
mouse_ok    resb 1
alignb 8
ptr_lastz   resq MAX_PTRS       ; last wheel position of each Absolute Pointer

section .data
guid_block_io   dd 0x964E5B21
                dw 0x6459, 0x11D2
                db 0x8E, 0x39, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B
guid_dev_path   dd 0x09576E91
                dw 0x6D3F, 0x11D2
                db 0x8E, 0x39, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B
guid_abs_ptr    dd 0x8D59D32B
                dw 0xC655, 0x4AE9
                db 0x9B, 0x15, 0xF2, 0x59, 0x04, 0x99, 0x2A, 0x43
guid_simple_ptr dd 0x31878C87
                dw 0x0B75, 0x11D5
                db 0x9A, 0x4F, 0x00, 0x90, 0x27, 0x3F, 0xC1, 0x4D
vga_rgb:        ; the classic 16 colours as R, G, B
    db 0x00,0x00,0x00, 0x00,0x00,0xAA, 0x00,0xAA,0x00, 0x00,0xAA,0xAA
    db 0xAA,0x00,0x00, 0xAA,0x00,0xAA, 0xAA,0x55,0x00, 0xAA,0xAA,0xAA
    db 0x55,0x55,0x55, 0x55,0x55,0xFF, 0x55,0xFF,0x55, 0x55,0xFF,0xFF
    db 0xFF,0x55,0x55, 0xFF,0x55,0xFF, 0xFF,0xFF,0x55, 0xFF,0xFF,0xFF

section .text
bits 32

; efi64: run the 64-bit routine at address EAX. EBX, ECX, EDX, ESI and EDI
; are handed over unchanged; returns the routine's EAX. Keeps the rest.
efi64:
    pushad
    mov [efi_far], eax
    mov eax, [bootinfo + BI.cs64]
    mov [efi_far + 4], eax
    call far [efi_far]
    mov [esp + 28], eax                 ; becomes EAX after popad
    popad
    ret

; efi_read / efi_write: EAX = LBA, ECX = count, EDI (read) / ESI (write)
; = buffer. Uses the Block I/O protocol in efi_cur_bio. CF=1 on error.
efi_read:
    pushad
    mov esi, edi
    xor ebx, ebx
    jmp efi_rw
efi_write:
    pushad
    mov ebx, 1
efi_rw:
.next:
    test ecx, ecx
    jz .done
    mov ebp, ecx
    cmp ebp, EFI_CHUNK
    jbe .chunk
    mov ebp, EFI_CHUNK
.chunk:
    push eax
    push ecx
    mov edx, eax
    mov ecx, ebp
    mov eax, efi_disk64
    call efi64
    mov edi, eax
    pop ecx
    pop eax
    test edi, edi
    jnz .fail
    add eax, ebp
    sub ecx, ebp
    mov edx, ebp
    shl edx, 9
    add esi, edx
    jmp .next
.done:
    test ebx, ebx
    jz .ok
    mov ebx, 2                          ; after writing: flush caches
    mov eax, efi_disk64
    call efi64
    test eax, eax
    jnz .fail
.ok:
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

; efi_firmware_name: ESI = the firmware vendor's name as plain text
efi_firmware_name:
    push eax
    mov eax, efi_fwname64
    call efi64
    mov esi, fw_name
    pop eax
    ret

; efi_list_disks: fill disk_tab with every whole disk the firmware knows
; -> EAX = number of disks
efi_list_disks:
    mov eax, efi_listdisks64
    call efi64
    mov [disk_count], eax
    ret

; efi_mouse_init: find the pointer devices. mouse_ok = 1 if there is one.
efi_mouse_init:
    mov eax, efi_ptrinit64
    call efi64
    test eax, eax
    setnz byte [mouse_ok]
    mov dword [ptr_accx], 0
    mov dword [ptr_accy], 0
    mov dword [mouse_wheel], 0
    mov eax, [gfx_w]
    shr eax, 1
    mov [mouse_x], eax
    mov eax, [gfx_h]
    shr eax, 1
    mov [mouse_y], eax
    ret

; ------------------------------------------------------- big memory
; Video, pictures and sound need far more memory than the kernel's fixed
; map has. On UEFI PCs it is asked from the firmware while MOOS runs: any
; size, in whole 4 KB pages, below 4 GB (MOOS is 32-bit), cleared. Each
; block is noted with its owner (an app number or OWN_*) so the Task
; Manager can show who uses what.
BIG_MAX     equ 512                     ; blocks at the same time
OWN_SYSTEM  equ 0                       ; owners: 1-15 are desktop apps,
OWN_SOUND   equ 16                      ; these the rest of the system
OWN_NET     equ 17
OWN_MEDIA   equ 18
OWN_IMAGES  equ 19
OWN_SHELL   equ 20                      ; "mem take" on the text console

section .bss
alignb 4
big_addr    resd BIG_MAX                ; the blocks: where, how big, whose
big_size    resd BIG_MAX
big_owner   resd BIG_MAX
big_total   resd 1                      ; bytes in use
section .text

; big_alloc: ECX = bytes, EDX = owner -> EAX = the block (4 KB aligned,
; cleared), 0 if there is no such memory (or this is not a UEFI PC)
big_alloc:
    pushad
    cmp dword [bootinfo + BI.platform], PLATFORM_UEFI
    jne .fail
    test ecx, ecx
    jz .fail
    xor esi, esi                        ; a free slot in the table
.slot:
    cmp dword [big_addr + esi * 4], 0
    je .have_slot
    inc esi
    cmp esi, BIG_MAX
    jb .slot
    jmp .fail
.have_slot:
    lea ebx, [ecx + 4095]
    shr ebx, 12                         ; EBX = pages
    mov eax, efi_allocpages64
    call efi64
    test eax, eax
    jz .fail
    mov [big_addr + esi * 4], eax
    mov ecx, ebx
    shl ecx, 12
    mov [big_size + esi * 4], ecx
    mov [big_owner + esi * 4], edx
    add [big_total], ecx
    mov edi, eax                        ; clear it
    shr ecx, 2
    push eax
    xor eax, eax
    rep stosd
    pop eax
    mov [esp + 28], eax                 ; (EAX after popad)
    popad
    ret
.fail:
    popad
    xor eax, eax
    ret

; big_free: EAX = a block from big_alloc -> given back to the firmware
big_free:
    pushad
    test eax, eax
    jz .done
    xor esi, esi
.find:
    cmp [big_addr + esi * 4], eax
    je .found
    inc esi
    cmp esi, BIG_MAX
    jb .find
    jmp .done
.found:
    mov ebx, eax                        ; EBX = address, ECX = pages
    mov ecx, [big_size + esi * 4]
    sub [big_total], ecx
    shr ecx, 12
    mov dword [big_addr + esi * 4], 0
    mov eax, efi_freepages64
    call efi64
.done:
    popad
    ret

; big_free_owner: EDX = owner -> every block of that owner is given back
big_free_owner:
    pushad
    xor esi, esi
.l: mov eax, [big_addr + esi * 4]
    test eax, eax
    jz .n
    cmp [big_owner + esi * 4], edx
    jne .n
    call big_free
.n: inc esi
    cmp esi, BIG_MAX
    jb .l
    popad
    ret

; big_owned: EDX = owner -> EAX = bytes that owner has
big_owned:
    push ecx
    push esi
    xor eax, eax
    xor esi, esi
.l: cmp dword [big_addr + esi * 4], 0
    je .n
    cmp [big_owner + esi * 4], edx
    jne .n
    add eax, [big_size + esi * 4]
.n: inc esi
    cmp esi, BIG_MAX
    jb .l
    pop esi
    pop ecx
    ret

%ifdef FULL
; ------------------------------------------------------- memory map
; The firmware keeps a map of all memory: what is free, what it uses
; itself, what is loaded programs (MOOS), what is not RAM at all. Asking
; for it while MOOS runs shows how much is really in use right now (the
; Task Manager and fetch show it).
MM_BUF_SIZE equ 16384                   ; room for ~340 map entries

section .bss
alignb 8
mm_buf      resb MM_BUF_SIZE            ; the map (EFI_MEMORY_DESCRIPTORs)
mm_size     resq 1
mm_key      resq 1
mm_dsize    resq 1
mm_dver     resq 1
mm_free_kb  resd 1
section .text

; efi_memmap: add up the firmware's memory map now -> EAX = installed RAM
; in KB, EDX = KB of it nobody uses (free). EAX = 0 if the firmware did
; not give a map (or this is not a UEFI PC).
efi_memmap:
    xor eax, eax
    xor edx, edx
    cmp dword [bootinfo + BI.platform], PLATFORM_UEFI
    jne .r
    mov eax, efi_memmap64
    call efi64
    mov edx, [mm_free_kb]
.r: ret
%endif

; efi_mouse_poll: refresh mouse_x / mouse_y / mouse_btn from the device
efi_mouse_poll:
    cmp byte [mouse_ok], 0
    je .r
    mov eax, efi_ptrget64
    call efi64
.r:
    ret

; ============================================================================
;  64-bit routines (entered by efi64, left with a 32-bit far return)
; ============================================================================
%macro ENTER64 0
    mov esp, esp                        ; clear the undefined upper half
    push rbp
    mov rbp, rsp
    and rsp, -16
    sub rsp, 96                         ; shadow space + stack arguments
%endmacro
%macro LEAVE64 0
    mov rsp, rbp
    pop rbp
    retf                                ; back to 32-bit compatibility mode
%endmacro

bits 64

; efi_tick: timer callback, called by the firmware 100 times a second
efi_tick:
    inc dword [rel ticks]
    ret

; efi_allocpages64: EBX = pages -> EAX = their address (below 4 GB), 0 if
; the firmware has none
efi_allocpages64:
    ENTER64
    mov eax, 0xFFFFFFFF                 ; the highest address allowed
    mov [rel efi_tmp], rax
    mov rax, [rel bootinfo + BI.bs]
    mov ecx, 1                          ; AllocateMaxAddress
    mov edx, 2                          ; EfiLoaderData
    mov r8d, ebx
    lea r9, [rel efi_tmp]
    call [rax + 40]                     ; AllocatePages
    test rax, rax
    jnz .no
    mov rax, [rel efi_tmp]
    LEAVE64
.no:
    xor eax, eax
    LEAVE64

; efi_freepages64: EBX = address, ECX = pages -> given back
efi_freepages64:
    ENTER64
    mov edx, ecx
    mov ecx, ebx
    mov rax, [rel bootinfo + BI.bs]
    call [rax + 48]                     ; FreePages
    xor eax, eax
    LEAVE64

%ifdef FULL
; efi_memmap64: GetMemoryMap into mm_buf, then count the pages -> EAX = KB
; of RAM (0 if it failed), mm_free_kb = KB free. RAM is every kind of
; memory except "reserved" (0), "unusable" (8) and the non-RAM kinds above
; ACPI NVS (10): memory-mapped I/O, firmware ROM, persistent memory.
; Free is "conventional memory" (7) that nobody has taken.
efi_memmap64:
    ENTER64
    mov qword [rel mm_size], MM_BUF_SIZE
    mov rax, [rel bootinfo + BI.bs]
    lea rcx, [rel mm_size]
    lea rdx, [rel mm_buf]
    lea r8, [rel mm_key]
    lea r9, [rel mm_dsize]
    lea r10, [rel mm_dver]
    mov [rsp + 32], r10
    call [rax + 56]                     ; GetMemoryMap
    test rax, rax
    jnz .fail                           ; (also when the buffer is too small)
    mov r9, [rel mm_dsize]
    cmp r9, 40                          ; a descriptor is at least 40 bytes
    jb .fail
    lea rsi, [rel mm_buf]
    mov rcx, rsi
    add rcx, [rel mm_size]
    xor edx, edx                        ; RDX = pages of RAM
    xor r8d, r8d                        ; R8 = free pages
.entry:
    lea rax, [rsi + 32]
    cmp rax, rcx
    ja .total
    mov eax, [rsi]                      ; Type
    cmp eax, 7                          ; EfiConventionalMemory
    jne .used
    add r8, [rsi + 24]                  ; NumberOfPages
.used:
    test eax, eax
    jz .skip
    cmp eax, 8
    je .skip
    cmp eax, 10
    ja .skip
    add rdx, [rsi + 24]
.skip:
    add rsi, r9
    jmp .entry
.total:
    shl r8, 2                           ; pages -> KB
    mov [rel mm_free_kb], r8d
    shl rdx, 2
    mov eax, edx
    LEAVE64
.fail:
    xor eax, eax
    mov [rel mm_free_kb], eax
    LEAVE64
%endif

; efi_readkey64: -> EAX = scan code << 16 | character, 0 if no key arrived
; within about half a second
efi_readkey64:
    ENTER64
    call .read
    test eax, eax
    jnz .done
    mov rax, [rel bootinfo + BI.bs]
    mov ecx, 2
    lea rdx, [rel bootinfo + BI.wait_key]
    lea r8, [rel efi_index]
    call [rax + 96]                     ; WaitForEvent(key, timer)
    call .read
.done:
    LEAVE64
.read:
    sub rsp, 40
    mov rcx, [rel bootinfo + BI.conin]
    lea rdx, [rel efi_key]
    mov dword [rdx], 0
    call [rcx + 8]                      ; ReadKeyStroke
    add rsp, 40
    test rax, rax
    jnz .none
    mov eax, [rel efi_key]
    rol eax, 16
    ret
.none:
    xor eax, eax
    ret

; efi_keypoll64: non-blocking key read -> EAX = scan<<16 | char, 0 if none
efi_keypoll64:
    ENTER64
    mov rcx, [rel bootinfo + BI.conin]
    lea rdx, [rel efi_key]
    mov dword [rdx], 0
    call [rcx + 8]                      ; ReadKeyStroke
    test rax, rax
    jnz .none
    mov eax, [rel efi_key]
    rol eax, 16
    LEAVE64
.none:
    xor eax, eax
    LEAVE64

; efi_disk64: EBX = 0 read / 1 write / 2 flush, ECX = sectors, EDX = LBA
; (high half in disk_lba_hi), ESI = buffer -> EAX = 0 if it worked
efi_disk64:
    ENTER64
    mov r12, [rel efi_cur_bio]
    mov r13d, ecx
    shl r13, 9                          ; bytes
    mov r14d, edx
    mov eax, [rel disk_lba_hi]
    shl rax, 32
    or r14, rax                         ; LBA
    mov r15d, esi                       ; kernel buffer
    test r12, r12
    jz .error
    cmp ebx, 2
    je .flush
    lea rdi, [rel kbase + BOUNCE_OFF - 0x10000]      ; UEFI_BOUNCE
    cmp ebx, 1
    jne .read
    mov rsi, r15                        ; write: copy into the bounce buffer
    mov rcx, r13
    rep movsb
    mov rcx, r12
    mov rax, [r12 + 8]
    mov edx, [rax]                      ; MediaId
    mov r8, r14
    mov r9, r13
    lea rax, [rel kbase + BOUNCE_OFF - 0x10000]
    mov [rsp + 32], rax
    call [r12 + 32]                     ; WriteBlocks
    test rax, rax
    jnz .error
    jmp .ok
.read:
    mov rcx, r12
    mov rax, [r12 + 8]
    mov edx, [rax]
    mov r8, r14
    mov r9, r13
    lea rax, [rel kbase + BOUNCE_OFF - 0x10000]
    mov [rsp + 32], rax
    call [r12 + 24]                     ; ReadBlocks
    test rax, rax
    jnz .error
    lea rsi, [rel kbase + BOUNCE_OFF - 0x10000]
    mov rdi, r15
    mov rcx, r13
    rep movsb
    jmp .ok
.flush:
    mov rcx, r12
    call [r12 + 40]                     ; FlushBlocks
    test rax, rax
    jnz .error
.ok:
    xor eax, eax
    LEAVE64
.error:
    mov eax, 1
    LEAVE64

; efi_gettime64: firmware clock -> efi_time. EAX = 0 if it worked.
efi_gettime64:
    ENTER64
    mov rax, [rel bootinfo + BI.rs]
    lea rcx, [rel efi_time]
    xor edx, edx
    call [rax + 24]                     ; GetTime
    LEAVE64

; efi_reset64: EBX = 0 restart / 2 power off (does not return)
efi_reset64:
    ENTER64
    mov rax, [rel bootinfo + BI.rs]
    mov ecx, ebx
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    call [rax + 104]                    ; ResetSystem
    LEAVE64

; efi_fwname64: firmware vendor (UTF-16) -> fw_name (ASCII)
efi_fwname64:
    ENTER64
    lea rdi, [rel fw_name]
    mov rsi, [rel bootinfo + BI.fw_vendor]
    mov ecx, 40
    test rsi, rsi
    jz .end
.l: lodsw
    test ax, ax
    jz .end
    cmp ax, 126
    jbe .put
    mov al, '?'
.put:
    stosb
    loop .l
.end:
    mov byte [rdi], 0
    LEAVE64

; efi_clear64: paint the whole graphics screen black
efi_clear64:
    ENTER64
    cmp dword [rel bootinfo + BI.fb_format], 3
    je .blt
    mov rdi, [rel bootinfo + BI.fb_base]
    mov r8d, [rel bootinfo + BI.fb_height]
    mov r9d, [rel bootinfo + BI.fb_pitch]
    shl r9, 2
.row:
    push rdi
    mov ecx, [rel bootinfo + BI.fb_width]
    xor eax, eax
    rep stosd
    pop rdi
    add rdi, r9
    dec r8d
    jnz .row
    LEAVE64
.blt:
    mov rcx, [rel bootinfo + BI.gop]
    lea rdx, [rel efi_tmp]              ; one black pixel
    mov qword [rdx], 0
    xor r8d, r8d                        ; EfiBltVideoFill
    xor r9d, r9d
    mov qword [rsp + 32], 0
    mov qword [rsp + 40], 0
    mov qword [rsp + 48], 0
    mov eax, [rel bootinfo + BI.fb_width]
    mov [rsp + 56], rax
    mov eax, [rel bootinfo + BI.fb_height]
    mov [rsp + 64], rax
    mov qword [rsp + 72], 0
    call [rcx + 16]                     ; Blt
    LEAVE64

; efi_present64: draw every character cell that changed since last time
efi_present64:
    ENTER64
    mov r15d, -1                        ; R15 = cursor cell (or -1)
    mov eax, [rel cur_y]
    cmp eax, SCR_ROWS
    jae .cursor_done
    mov edx, [rel cur_x]
    cmp edx, SCR_COLS
    jae .cursor_done
    imul eax, SCR_COLS
    add eax, edx
    mov r15d, eax
.cursor_done:
    lea rbx, [rel screen_buf]
    lea rsi, [rel screen_drawn]
    xor r12d, r12d
.cell:
    movzx eax, word [rbx + r12 * 2]
    xor r13d, r13d                      ; R13 = 1 if the cursor is here now
    cmp r12d, r15d
    jne .not_cursor
    inc r13d
.not_cursor:
    xor edx, edx                        ; EDX = 1 if it was here before
    cmp r12d, [rel drawn_cursor]
    jne .was_not
    inc edx
.was_not:
    cmp edx, r13d
    jne .draw
    cmp ax, [rsi + r12 * 2]
    je .next
.draw:
    mov [rsi + r12 * 2], ax
    call draw_cell64
.next:
    inc r12d
    cmp r12d, SCR_COLS * SCR_ROWS
    jb .cell
    mov [rel drawn_cursor], r15d
    xor eax, eax
    LEAVE64

; draw_cell64: R12D = cell index, EAX = character | attribute << 8,
; R13D = 1 to draw the cursor (an underline) in this cell
draw_cell64:
    push rbx
    push rsi
    push rdi
    push r14
    push r15
    sub rsp, 80
    movzx r8d, al                       ; character
    mov r9d, eax
    shr r9d, 8
    and r9d, 0xFF                       ; attribute
    lea rbx, [rel fb_palette]
    mov r10d, r9d
    and r10d, 15
    mov r10d, [rbx + r10 * 4]           ; R10 = foreground colour
    shr r9d, 4
    mov r11d, [rbx + r9 * 4]            ; R11 = background colour
    mov eax, r12d
    xor edx, edx
    mov ecx, SCR_COLS
    div ecx                             ; EAX = row, EDX = column
    imul edx, [rel fb_cellw]
    add edx, [rel fb_x0]
    imul eax, [rel fb_cellh]
    add eax, [rel fb_y0]
    mov [rel cell_px], edx
    mov [rel cell_py], eax
    cmp dword [rel bootinfo + BI.fb_format], 3
    je .to_buffer
    imul eax, [rel bootinfo + BI.fb_pitch]
    add eax, edx
    shl rax, 2
    add rax, [rel bootinfo + BI.fb_base]
    mov rdi, rax                        ; RDI = top-left pixel
    mov r14d, [rel bootinfo + BI.fb_pitch]
    shl r14, 2                          ; R14 = bytes per pixel row
    jmp .render
.to_buffer:
    lea rdi, [rel cell_buf]
    mov r14d, [rel fb_cellw]
    shl r14, 2
.render:
    lea rsi, [rel font_8x16]
    shl r8d, 4
    add rsi, r8                         ; RSI = the character's 16 rows
    xor r15d, r15d
.glyph_row:
    movzx eax, byte [rsi + r15]
    test r13d, r13d
    jz .bits
    cmp r15d, 14
    jb .bits
    mov eax, 0xFF                       ; cursor: solid bottom two rows
.bits:
    mov ebx, [rel fb_scale]
.repeat_row:
    mov rdx, rdi
    mov ecx, 0x80
.pixel:
    mov r9d, r11d
    test eax, ecx
    jz .colour
    mov r9d, r10d
.colour:
    mov r8d, [rel fb_scale]
.repeat_pixel:
    mov [rdx], r9d
    add rdx, 4
    dec r8d
    jnz .repeat_pixel
    shr ecx, 1
    jnz .pixel
    add rdi, r14
    dec ebx
    jnz .repeat_row
    inc r15d
    cmp r15d, 16
    jb .glyph_row
    cmp dword [rel bootinfo + BI.fb_format], 3
    jne .done
    mov rcx, [rel bootinfo + BI.gop]    ; Blt-only: let the firmware copy it
    lea rdx, [rel cell_buf]
    mov r8d, 2                          ; EfiBltBufferToVideo
    xor r9d, r9d
    mov qword [rsp + 32], 0
    mov eax, [rel cell_px]
    mov [rsp + 40], rax
    mov eax, [rel cell_py]
    mov [rsp + 48], rax
    mov eax, [rel fb_cellw]
    mov [rsp + 56], rax
    mov eax, [rel fb_cellh]
    mov [rsp + 64], rax
    mov qword [rsp + 72], 0
    call [rcx + 16]                     ; Blt
.done:
    add rsp, 80
    pop r15
    pop r14
    pop rdi
    pop rsi
    pop rbx
    ret

; efi_ptrinit64: find every pointer device -> EAX = how many.
; Two kinds: Absolute Pointer devices (touch screens, QEMU's tablet) report
; a position; Simple Pointer devices (ordinary USB and PS/2 mice) report how
; far they moved. Firmware often starts the mouse driver only when something
; needs it, so every device is connected first.
efi_ptrinit64:
    ENTER64
    call connect_all64
    xor eax, eax
    mov [rel ptr_n], eax
    mov [rel ptr_real + PTR_ABS * 4], eax
    mov [rel ptr_real + PTR_REL * 4], eax
    lea r15, [rel guid_abs_ptr]
    mov r14d, PTR_ABS
    call .collect
    lea r15, [rel guid_simple_ptr]
    mov r14d, PTR_REL
    call .collect
    mov eax, [rel ptr_real + PTR_ABS * 4]
    add eax, [rel ptr_real + PTR_REL * 4]
    LEAVE64
; .collect: add every handle carrying protocol R15, as kind R14. The console
; handle carries the firmware's virtual device that merges all the others:
; it is listened to as well (harmless - reading it drains the real ones) but
; not counted, since it exists even when there is no mouse at all.
.collect:
    sub rsp, 56                         ; (keeps the stack 16-byte aligned)
    mov rax, [rel bootinfo + BI.bs]
    mov ecx, 2                          ; ByProtocol
    mov rdx, r15
    xor r8d, r8d
    lea r9, [rel efi_tmp]               ; -> number of handles
    lea r10, [rel efi_tmp + 8]          ; -> the handle buffer
    mov [rsp + 32], r10
    call [rax + 312]                    ; LocateHandleBuffer
    test rax, rax
    jnz .c_done
    mov r12, [rel efi_tmp + 8]
    mov rbx, r12
    mov r13, [rel efi_tmp]
.c_next:
    test r13, r13
    jz .c_free
    mov eax, [rel ptr_n]
    cmp eax, MAX_PTRS
    jae .c_free
    lea r8, [rel ptr_ifs]
    lea r8, [r8 + rax * 8]              ; where the interface goes
    mov qword [r8], 0
    mov rax, [rel bootinfo + BI.bs]
    mov rcx, [r12]
    mov rdx, r15
    call [rax + 152]                    ; HandleProtocol
    test rax, rax
    jnz .c_skip
    mov eax, [rel ptr_n]
    lea rcx, [rel ptr_ifs]
    cmp qword [rcx + rax * 8], 0
    je .c_skip
    lea rcx, [rel ptr_kinds]
    mov [rcx + rax], r14b
    inc dword [rel ptr_n]
    mov rdx, [rel bootinfo + BI.systab]
    mov rdx, [rdx + 40]                 ; ConsoleInHandle
    cmp rdx, [r12]
    je .c_virtual
    lea rdx, [rel ptr_real]
    inc dword [rdx + r14 * 4]
    jmp .c_skip
.c_virtual:
    or byte [rcx + rax], PTR_VIRT
.c_skip:
    add r12, 8
    dec r13
    jmp .c_next
.c_free:
    mov rax, [rel bootinfo + BI.bs]
    mov rcx, rbx
    call [rax + 72]                     ; FreePool
.c_done:
    add rsp, 56
    ret

; efi_ptrget64: read every pointer device; update mouse_x / mouse_y / mouse_btn
efi_ptrget64:
    ENTER64
    xor r12d, r12d
.next:
    cmp r12d, [rel ptr_n]
    jae .done
    lea rax, [rel ptr_ifs]
    mov rsi, [rax + r12 * 8]
    lea rax, [rel ptr_kinds]
    movzx r13d, byte [rax + r12]
    and r13d, ~PTR_VIRT
    mov rcx, rsi
    lea rdx, [rel ptr_state]
    call [rsi + 8]                      ; GetState (same place in both kinds)
    test rax, rax
    jnz .skip                           ; EFI_NOT_READY: nothing new from it
    cmp r13d, PTR_ABS
    jne .rel
    call ptr_abs_apply
    jmp .skip
.rel:
    call ptr_rel_apply
.skip:
    inc r12d
    jmp .next
.done:
    xor eax, eax
    LEAVE64

; ptr_abs_apply: RSI = Absolute Pointer, ptr_state = its state (CurrentX,
; CurrentY, CurrentZ as 64-bit numbers, then ActiveButtons). Maps the
; position from the device's range onto the screen.
ptr_abs_apply:
    mov rcx, [rsi + 24]                 ; Mode: MinX, MinY, MinZ, MaxX, MaxY ...
    mov rax, [rel ptr_state + 0]
    mov r8, [rcx + 0]
    mov r9, [rcx + 24]
    mov r10d, [rel gfx_w]
    call .map
    mov [rel mouse_x], eax
    mov rax, [rel ptr_state + 8]
    mov r8, [rcx + 8]
    mov r9, [rcx + 32]
    mov r10d, [rel gfx_h]
    call .map
    mov [rel mouse_y], eax
    mov eax, [rel ptr_state + 24]       ; ActiveButtons (bit 0 = touch / left)
    and eax, 1
    mov [rel mouse_btn], eax
    mov rax, [rcx + 16]                 ; a wheel: MinZ < MaxZ
    cmp rax, [rcx + 40]
    jge .no_z
    mov rax, [rel ptr_state + 16]       ; CurrentZ: count how far it turned
    lea rdx, [rel ptr_lastz]
    mov r8, rax
    sub rax, [rdx + r12 * 8]
    mov [rdx + r12 * 8], r8
    add [rel mouse_wheel], eax
.no_z:
    ret
; .map: RAX = value, R8 = min, R9 = max, R10 = screen size -> EAX = pixel
.map:
    sub r9, r8
    jbe .m0                             ; (no usable range)
    sub rax, r8
    jb .m0                              ; below the minimum
    cmp rax, r9
    jbe .m1
    mov rax, r9
.m1:
    mul r10                             ; RDX:RAX = offset * size
    div r9
    cmp rax, r10
    jb .m2
    lea rax, [r10 - 1]
.m2:
    ret
.m0:
    xor eax, eax
    ret

; ptr_rel_apply: RSI = Simple Pointer, ptr_state = its state (movement X, Y,
; Z as signed 32-bit counts, then the left and right buttons). Z is the
; wheel. The device's
; Mode says how many counts make a millimetre; MOOS moves the cursor 8
; pixels per millimetre, which is one pixel per count with the usual USB
; mouse driver (it reports 8 counts per mm). Fractions carry over.
ptr_rel_apply:
    mov rcx, [rsi + 24]                 ; Mode: ResolutionX, ResolutionY, ...
    movsxd rax, dword [rel ptr_state + 0]
    mov r8, [rcx + 0]
    lea r9, [rel ptr_accx]
    call .axis
    add eax, [rel mouse_x]
    mov r10d, [rel gfx_w]
    call .clamp
    mov [rel mouse_x], eax
    movsxd rax, dword [rel ptr_state + 4]
    mov r8, [rcx + 8]
    lea r9, [rel ptr_accy]
    call .axis
    add eax, [rel mouse_y]
    mov r10d, [rel gfx_h]
    call .clamp
    mov [rel mouse_y], eax
    movzx eax, byte [rel ptr_state + 12] ; LeftButton
    and eax, 1
    mov [rel mouse_btn], eax
    mov eax, [rel ptr_state + 8]        ; the wheel (RelativeMovementZ)
    add [rel mouse_wheel], eax
    ret
; .axis: RAX = counts, R8 = counts per mm (0 = not given), R9 -> leftover
; sixteenths -> EAX = whole pixels to move
.axis:
    shl rax, 7                          ; counts * 8 px * 16 sixteenths
    test r8, r8
    jz .unscaled
    cqo
    idiv r8
    jmp .add
.unscaled:
    sar rax, 3                          ; one count = one pixel
.add:
    add eax, [r9]
    cdq
    mov r10d, 16
    idiv r10d                           ; EAX = pixels, EDX = sixteenths left
    mov [r9], edx
    mov edx, eax                        ; faster when moved fast: past 4
    sar edx, 31                         ; pixels at a time, count double
    mov r10d, eax
    xor r10d, edx
    sub r10d, edx                       ; |pixels|
    sub r10d, 4
    jle .slow
    xor r10d, edx
    sub r10d, edx                       ; the extra, signed again
    add eax, r10d
.slow:
    ret
; .clamp: EAX = position, R10 = size -> EAX within 0 .. size-1
.clamp:
    test eax, eax
    jns .c1
    xor eax, eax
.c1:
    cmp eax, r10d
    jb .c2
    lea eax, [r10 - 1]
.c2:
    ret

; efi_listdisks64: every whole disk with Block I/O -> disk_tab, EAX = count
efi_listdisks64:
    ENTER64
    ; Firmware often starts drivers only for the devices it needs to boot.
    ; Ask it to connect every device first, so all disks show up.
    mov rax, [rel bootinfo + BI.bs]
    xor ecx, ecx                        ; AllHandles
    xor edx, edx
    xor r8d, r8d
    lea r9, [rel efi_tmp]
    lea r10, [rel efi_tmp + 8]
    mov [rsp + 32], r10
    call [rax + 312]                    ; LocateHandleBuffer
    test rax, rax
    jnz .listed
    mov r12, [rel efi_tmp + 8]
    mov r13, [rel efi_tmp]
    xor r14d, r14d
.connect:
    cmp r14, r13
    jae .connected
    mov rax, [rel bootinfo + BI.bs]
    mov rcx, [r12 + r14 * 8]
    xor edx, edx
    xor r8d, r8d
    mov r9d, 1                          ; recursively
    call [rax + 264]                    ; ConnectController
    inc r14
    jmp .connect
.connected:
    mov rax, [rel bootinfo + BI.bs]
    mov rcx, r12
    call [rax + 72]                     ; FreePool
.listed:
    mov rax, [rel bootinfo + BI.bs]
    mov ecx, 2                          ; ByProtocol
    lea rdx, [rel guid_block_io]
    xor r8d, r8d
    lea r9, [rel efi_tmp]               ; number of handles
    lea r10, [rel efi_tmp + 8]          ; handle buffer
    mov [rsp + 32], r10
    call [rax + 312]                    ; LocateHandleBuffer
    xor r15d, r15d                      ; R15 = disks found
    test rax, rax
    jnz .finish
    mov r12, [rel efi_tmp + 8]          ; R12 = handles
    mov r13, [rel efi_tmp]              ; R13 = how many
    xor r14d, r14d                      ; R14 = index
.handle:
    cmp r14, r13
    jae .free
    cmp r15d, MAX_DISKS
    jae .free
    mov rbx, [r12 + r14 * 8]            ; RBX = handle
    mov rax, [rel bootinfo + BI.bs]
    mov rcx, rbx
    lea rdx, [rel guid_block_io]
    lea r8, [rel efi_tmp]
    call [rax + 152]                    ; HandleProtocol(Block I/O)
    test rax, rax
    jnz .skip
    mov rsi, [rel efi_tmp]              ; RSI = Block I/O
    mov rdi, [rsi + 8]                  ; RDI = media
    cmp byte [rdi + 6], 0               ; a partition, not a whole disk
    jne .skip
    cmp byte [rdi + 5], 0               ; no medium inserted
    je .skip
    mov eax, r15d                       ; fill the table entry
    shl eax, 5
    lea r8, [rel disk_tab]
    add r8, rax
    mov [r8 + DT_HANDLE], rsi
    mov rax, [rdi + 24]                 ; LastBlock
    inc rax
    mov [r8 + DT_SECTORS], rax
    mov eax, [rdi + 12]
    mov [r8 + DT_BSIZE], eax
    xor eax, eax
    cmp byte [rdi + 4], 0
    je .fixed
    or eax, DF_REMOVABLE
.fixed:
    cmp byte [rdi + 7], 0
    je .writable
    or eax, DF_READONLY
.writable:
    mov [r8 + DT_FLAGS], eax
    mov dword [r8 + DT_TYPE], DTYPE_DISK
    push r8
    push r8                             ; (keeps the stack aligned)
    mov rax, [rel bootinfo + BI.bs]
    mov rcx, rbx
    lea rdx, [rel guid_dev_path]
    lea r8, [rel efi_tmp]
    call [rax + 152]                    ; HandleProtocol(device path)
    pop r8
    pop r8
    test rax, rax
    jnz .counted
    mov rsi, [rel efi_tmp]
    call classify_path64
    mov [r8 + DT_TYPE], eax
    call is_boot_disk64
    jne .counted
    or dword [r8 + DT_FLAGS], DF_BOOT
.counted:
    inc r15d
.skip:
    inc r14
    jmp .handle
.free:
    mov rax, [rel bootinfo + BI.bs]
    mov rcx, r12
    call [rax + 72]                     ; FreePool
.finish:
    mov eax, r15d
    LEAVE64

; classify_path64: RSI = device path -> EAX = DTYPE_* from its nodes
classify_path64:
    push rsi
    mov eax, DTYPE_DISK
.node:
    movzx ecx, byte [rsi]               ; type
    movzx edx, byte [rsi + 1]           ; subtype
    cmp ecx, 0x7F
    je .end
    cmp ecx, 3                          ; messaging device path
    jne .next
    cmp edx, 5
    je .usb
    cmp eax, DTYPE_DISK                 ; first match wins (USB always)
    jne .next
    cmp edx, 23
    je .nvme
    cmp edx, 18
    je .sata
    cmp edx, 1
    je .ata
    cmp edx, 2
    je .scsi
    cmp edx, 26
    je .sd
    cmp edx, 29
    je .emmc
    jmp .next
.usb:   mov eax, DTYPE_USB
        jmp .end
.nvme:  mov eax, DTYPE_NVME
        jmp .next
.sata:  mov eax, DTYPE_SATA
        jmp .next
.ata:   mov eax, DTYPE_ATA
        jmp .next
.scsi:  mov eax, DTYPE_SCSI
        jmp .next
.sd:    mov eax, DTYPE_SD
        jmp .next
.emmc:  mov eax, DTYPE_EMMC
.next:
    movzx ecx, word [rsi + 2]           ; node length
    cmp ecx, 4
    jb .end
    add rsi, rcx
    jmp .node
.end:
    pop rsi
    ret

; is_boot_disk64: RSI = a disk's device path -> ZF=1 if the partition MOOS
; started from is on that disk (the disk's path is the start of its path)
is_boot_disk64:
    push rsi
    push rdi
    push rcx
    mov rdi, [rel bootinfo + BI.esp_path]
    test rdi, rdi
    jz .no
    push rsi                            ; length of the disk's path
    xor ecx, ecx
.len:
    cmp byte [rsi], 0x7F
    je .have_len
    movzx eax, word [rsi + 2]
    cmp eax, 4
    jb .bad_len
    add rcx, rax
    add rsi, rax
    jmp .len
.bad_len:
    pop rsi
    jmp .no
.have_len:
    pop rsi
    test rcx, rcx
    jz .no
    repe cmpsb
    jmp .out
.no:
    or ecx, 1                           ; ZF=0
.out:
    pop rcx
    pop rdi
    pop rsi
    ret

bits 32
