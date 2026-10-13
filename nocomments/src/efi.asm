EFI_CHUNK   equ 128
MAX_DISKS   equ 16
MAX_PTRS    equ 8
PTR_ABS     equ 1
PTR_REL     equ 2
PTR_VIRT    equ 0x80

DT_HANDLE   equ 0
DT_DRIVE    equ 0
DT_SECTORS  equ 8
DT_BSIZE    equ 16
DT_FLAGS    equ 20
DT_TYPE     equ 24
DT_SIZE     equ 32
DF_REMOVABLE equ 1
DF_READONLY equ 2
DF_BOOT     equ 4
DTYPE_DISK  equ 0
DTYPE_USB   equ 1
DTYPE_NVME  equ 2
DTYPE_SATA  equ 3
DTYPE_ATA   equ 4
DTYPE_SCSI  equ 5
DTYPE_SD    equ 6
DTYPE_EMMC  equ 7

section .bss
alignb 8
efi_far     resd 2
efi_cur_bio resq 1
efi_time    resb 16
efi_key     resd 1
efi_index   resq 1
efi_tmp     resq 2
fw_name     resb 48
disk_tab    resb MAX_DISKS * DT_SIZE
disk_count  resd 1
fb_scale    resd 1
fb_cellw    resd 1
fb_cellh    resd 1
fb_x0       resd 1
fb_y0       resd 1
fb_palette  resd 16
cell_px     resd 1
cell_py     resd 1
drawn_cursor resd 1
alignb 16
cell_buf    resd 16 * 32
alignb 8
ptr_ifs     resq MAX_PTRS
ptr_kinds   resb MAX_PTRS
ptr_state   resb 40
alignb 4
ptr_n       resd 1
ptr_real    resd 3
ptr_accx    resd 1
ptr_accy    resd 1
mouse_x     resd 1
mouse_y     resd 1
mouse_btn   resd 1
mouse_wheel resd 1
mouse_ok    resb 1
alignb 8
ptr_lastz   resq MAX_PTRS

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
vga_rgb:
    db 0x00,0x00,0x00, 0x00,0x00,0xAA, 0x00,0xAA,0x00, 0x00,0xAA,0xAA
    db 0xAA,0x00,0x00, 0xAA,0x00,0xAA, 0xAA,0x55,0x00, 0xAA,0xAA,0xAA
    db 0x55,0x55,0x55, 0x55,0x55,0xFF, 0x55,0xFF,0x55, 0x55,0xFF,0xFF
    db 0xFF,0x55,0x55, 0xFF,0x55,0xFF, 0xFF,0xFF,0x55, 0xFF,0xFF,0xFF

section .text
bits 32

efi64:
    pushad
    mov [efi_far], eax
    mov eax, [bootinfo + BI.cs64]
    mov [efi_far + 4], eax
    call far [efi_far]
    mov [esp + 28], eax
    popad
    ret

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
    mov ebx, 2
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

efi_firmware_name:
    push eax
    mov eax, efi_fwname64
    call efi64
    mov esi, fw_name
    pop eax
    ret

efi_list_disks:
    mov eax, efi_listdisks64
    call efi64
    mov [disk_count], eax
    ret

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

efi_mouse_poll:
    cmp byte [mouse_ok], 0
    je .r
    mov eax, efi_ptrget64
    call efi64
.r:
    ret

%macro ENTER64 0
    mov esp, esp
    push rbp
    mov rbp, rsp
    and rsp, -16
    sub rsp, 96
%endmacro
%macro LEAVE64 0
    mov rsp, rbp
    pop rbp
    retf
%endmacro

bits 64

efi_tick:
    inc dword [rel ticks]
    ret

efi_readkey64:
    ENTER64
    call .read
    test eax, eax
    jnz .done
    mov rax, [rel bootinfo + BI.bs]
    mov ecx, 2
    lea rdx, [rel bootinfo + BI.wait_key]
    lea r8, [rel efi_index]
    call [rax + 96]
    call .read
.done:
    LEAVE64
.read:
    sub rsp, 40
    mov rcx, [rel bootinfo + BI.conin]
    lea rdx, [rel efi_key]
    mov dword [rdx], 0
    call [rcx + 8]
    add rsp, 40
    test rax, rax
    jnz .none
    mov eax, [rel efi_key]
    rol eax, 16
    ret
.none:
    xor eax, eax
    ret

efi_keypoll64:
    ENTER64
    mov rcx, [rel bootinfo + BI.conin]
    lea rdx, [rel efi_key]
    mov dword [rdx], 0
    call [rcx + 8]
    test rax, rax
    jnz .none
    mov eax, [rel efi_key]
    rol eax, 16
    LEAVE64
.none:
    xor eax, eax
    LEAVE64

efi_disk64:
    ENTER64
    mov r12, [rel efi_cur_bio]
    mov r13d, ecx
    shl r13, 9
    mov r14d, edx
    mov eax, [rel disk_lba_hi]
    shl rax, 32
    or r14, rax
    mov r15d, esi
    test r12, r12
    jz .error
    cmp ebx, 2
    je .flush
    lea rdi, [rel kbase + 0x90000]
    cmp ebx, 1
    jne .read
    mov rsi, r15
    mov rcx, r13
    rep movsb
    mov rcx, r12
    mov rax, [r12 + 8]
    mov edx, [rax]
    mov r8, r14
    mov r9, r13
    lea rax, [rel kbase + 0x90000]
    mov [rsp + 32], rax
    call [r12 + 32]
    test rax, rax
    jnz .error
    jmp .ok
.read:
    mov rcx, r12
    mov rax, [r12 + 8]
    mov edx, [rax]
    mov r8, r14
    mov r9, r13
    lea rax, [rel kbase + 0x90000]
    mov [rsp + 32], rax
    call [r12 + 24]
    test rax, rax
    jnz .error
    lea rsi, [rel kbase + 0x90000]
    mov rdi, r15
    mov rcx, r13
    rep movsb
    jmp .ok
.flush:
    mov rcx, r12
    call [r12 + 40]
    test rax, rax
    jnz .error
.ok:
    xor eax, eax
    LEAVE64
.error:
    mov eax, 1
    LEAVE64

efi_gettime64:
    ENTER64
    mov rax, [rel bootinfo + BI.rs]
    lea rcx, [rel efi_time]
    xor edx, edx
    call [rax + 24]
    LEAVE64

efi_reset64:
    ENTER64
    mov rax, [rel bootinfo + BI.rs]
    mov ecx, ebx
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    call [rax + 104]
    LEAVE64

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
    lea rdx, [rel efi_tmp]
    mov qword [rdx], 0
    xor r8d, r8d
    xor r9d, r9d
    mov qword [rsp + 32], 0
    mov qword [rsp + 40], 0
    mov qword [rsp + 48], 0
    mov eax, [rel bootinfo + BI.fb_width]
    mov [rsp + 56], rax
    mov eax, [rel bootinfo + BI.fb_height]
    mov [rsp + 64], rax
    mov qword [rsp + 72], 0
    call [rcx + 16]
    LEAVE64

efi_present64:
    ENTER64
    mov r15d, -1
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
    xor r13d, r13d
    cmp r12d, r15d
    jne .not_cursor
    inc r13d
.not_cursor:
    xor edx, edx
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

draw_cell64:
    push rbx
    push rsi
    push rdi
    push r14
    push r15
    sub rsp, 80
    movzx r8d, al
    mov r9d, eax
    shr r9d, 8
    and r9d, 0xFF
    lea rbx, [rel fb_palette]
    mov r10d, r9d
    and r10d, 15
    mov r10d, [rbx + r10 * 4]
    shr r9d, 4
    mov r11d, [rbx + r9 * 4]
    mov eax, r12d
    xor edx, edx
    mov ecx, SCR_COLS
    div ecx
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
    mov rdi, rax
    mov r14d, [rel bootinfo + BI.fb_pitch]
    shl r14, 2
    jmp .render
.to_buffer:
    lea rdi, [rel cell_buf]
    mov r14d, [rel fb_cellw]
    shl r14, 2
.render:
    lea rsi, [rel font_8x16]
    shl r8d, 4
    add rsi, r8
    xor r15d, r15d
.glyph_row:
    movzx eax, byte [rsi + r15]
    test r13d, r13d
    jz .bits
    cmp r15d, 14
    jb .bits
    mov eax, 0xFF
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
    mov rcx, [rel bootinfo + BI.gop]
    lea rdx, [rel cell_buf]
    mov r8d, 2
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
    call [rcx + 16]
.done:
    add rsp, 80
    pop r15
    pop r14
    pop rdi
    pop rsi
    pop rbx
    ret

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

.collect:
    sub rsp, 56
    mov rax, [rel bootinfo + BI.bs]
    mov ecx, 2
    mov rdx, r15
    xor r8d, r8d
    lea r9, [rel efi_tmp]
    lea r10, [rel efi_tmp + 8]
    mov [rsp + 32], r10
    call [rax + 312]
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
    lea r8, [r8 + rax * 8]
    mov qword [r8], 0
    mov rax, [rel bootinfo + BI.bs]
    mov rcx, [r12]
    mov rdx, r15
    call [rax + 152]
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
    mov rdx, [rdx + 40]
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
    call [rax + 72]
.c_done:
    add rsp, 56
    ret

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
    call [rsi + 8]
    test rax, rax
    jnz .skip
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

ptr_abs_apply:
    mov rcx, [rsi + 24]
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
    mov eax, [rel ptr_state + 24]
    and eax, 1
    mov [rel mouse_btn], eax
    mov rax, [rcx + 16]
    cmp rax, [rcx + 40]
    jge .no_z
    mov rax, [rel ptr_state + 16]
    lea rdx, [rel ptr_lastz]
    mov r8, rax
    sub rax, [rdx + r12 * 8]
    mov [rdx + r12 * 8], r8
    add [rel mouse_wheel], eax
.no_z:
    ret

.map:
    sub r9, r8
    jbe .m0
    sub rax, r8
    jb .m0
    cmp rax, r9
    jbe .m1
    mov rax, r9
.m1:
    mul r10
    div r9
    cmp rax, r10
    jb .m2
    lea rax, [r10 - 1]
.m2:
    ret
.m0:
    xor eax, eax
    ret

ptr_rel_apply:
    mov rcx, [rsi + 24]
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
    movzx eax, byte [rel ptr_state + 12]
    and eax, 1
    mov [rel mouse_btn], eax
    mov eax, [rel ptr_state + 8]
    add [rel mouse_wheel], eax
    ret

.axis:
    shl rax, 7
    test r8, r8
    jz .unscaled
    cqo
    idiv r8
    jmp .add
.unscaled:
    sar rax, 3
.add:
    add eax, [r9]
    cdq
    mov r10d, 16
    idiv r10d
    mov [r9], edx
    mov edx, eax
    sar edx, 31
    mov r10d, eax
    xor r10d, edx
    sub r10d, edx
    sub r10d, 4
    jle .slow
    xor r10d, edx
    sub r10d, edx
    add eax, r10d
.slow:
    ret

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

efi_listdisks64:
    ENTER64

    mov rax, [rel bootinfo + BI.bs]
    xor ecx, ecx
    xor edx, edx
    xor r8d, r8d
    lea r9, [rel efi_tmp]
    lea r10, [rel efi_tmp + 8]
    mov [rsp + 32], r10
    call [rax + 312]
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
    mov r9d, 1
    call [rax + 264]
    inc r14
    jmp .connect
.connected:
    mov rax, [rel bootinfo + BI.bs]
    mov rcx, r12
    call [rax + 72]
.listed:
    mov rax, [rel bootinfo + BI.bs]
    mov ecx, 2
    lea rdx, [rel guid_block_io]
    xor r8d, r8d
    lea r9, [rel efi_tmp]
    lea r10, [rel efi_tmp + 8]
    mov [rsp + 32], r10
    call [rax + 312]
    xor r15d, r15d
    test rax, rax
    jnz .finish
    mov r12, [rel efi_tmp + 8]
    mov r13, [rel efi_tmp]
    xor r14d, r14d
.handle:
    cmp r14, r13
    jae .free
    cmp r15d, MAX_DISKS
    jae .free
    mov rbx, [r12 + r14 * 8]
    mov rax, [rel bootinfo + BI.bs]
    mov rcx, rbx
    lea rdx, [rel guid_block_io]
    lea r8, [rel efi_tmp]
    call [rax + 152]
    test rax, rax
    jnz .skip
    mov rsi, [rel efi_tmp]
    mov rdi, [rsi + 8]
    cmp byte [rdi + 6], 0
    jne .skip
    cmp byte [rdi + 5], 0
    je .skip
    mov eax, r15d
    shl eax, 5
    lea r8, [rel disk_tab]
    add r8, rax
    mov [r8 + DT_HANDLE], rsi
    mov rax, [rdi + 24]
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
    push r8
    mov rax, [rel bootinfo + BI.bs]
    mov rcx, rbx
    lea rdx, [rel guid_dev_path]
    lea r8, [rel efi_tmp]
    call [rax + 152]
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
    call [rax + 72]
.finish:
    mov eax, r15d
    LEAVE64

classify_path64:
    push rsi
    mov eax, DTYPE_DISK
.node:
    movzx ecx, byte [rsi]
    movzx edx, byte [rsi + 1]
    cmp ecx, 0x7F
    je .end
    cmp ecx, 3
    jne .next
    cmp edx, 5
    je .usb
    cmp eax, DTYPE_DISK
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
    movzx ecx, word [rsi + 2]
    cmp ecx, 4
    jb .end
    add rsi, rcx
    jmp .node
.end:
    pop rsi
    ret

is_boot_disk64:
    push rsi
    push rdi
    push rcx
    mov rdi, [rel bootinfo + BI.esp_path]
    test rdi, rdi
    jz .no
    push rsi
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
    or ecx, 1
.out:
    pop rcx
    pop rdi
    pop rsi
    ret

bits 32
