bits 64
default rel
%include "src/bootinfo.inc"

IMAGE_BASE  equ 0x400000
TEXT_RVA    equ 0x1000
TEXT_FILE   equ 0x200

mz:
    db "MZ"
    times 0x3C - ($ - mz) db 0
    dd pe - mz
pe:
    db "PE", 0, 0
    dw 0x8664
    dw 2
    dd 0, 0, 0
    dw opt_end - opt
    dw 0x0022
opt:
    dw 0x020B
    db 0, 0
    dd TEXT_RAW
    dd 0, 0
    dd efi_main - text + TEXT_RVA
    dd TEXT_RVA
    dq IMAGE_BASE
    dd 0x1000
    dd 0x200
    dw 0, 0, 0, 0, 0, 0
    dd 0
    dd IMAGE_SIZE
    dd TEXT_FILE
    dd 0
    dw 10
    dw 0
    dq 0x100000, 0x1000, 0x100000, 0x1000
    dd 0
    dd 16
    dq 0, 0, 0, 0, 0
    dd RELOC_RVA, 8
    times 10 dq 0
opt_end:
    db ".text", 0, 0, 0
    dd TEXT_SIZE, TEXT_RVA, TEXT_RAW, TEXT_FILE
    dd 0, 0
    dw 0, 0
    dd 0xE0000020
    db ".reloc", 0, 0
    dd 8, RELOC_RVA, 0x200, TEXT_FILE + TEXT_RAW
    dd 0, 0
    dw 0, 0
    dd 0x42000040
    times TEXT_FILE - ($ - mz) db 0

text:
efi_main:
    push rbx
    push rbp
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    mov [image_handle], rcx
    mov [systab], rdx
    mov [saved_rsp], rsp
    and rsp, -16
    sub rsp, 96
    mov rax, [rdx + 96]
    mov [bs], rax
    mov rax, [rdx + 88]
    mov [rs], rax
    mov rax, [rdx + 64]
    mov [conout], rax
    lea rdx, [msg_hello]
    call print

    mov rax, [bs]
    xor ecx, ecx
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    call [rax + 256]

    lea rsi, [kernel]
    mov rax, "MOOSKRNL"
    cmp [rsi + 8 + KH.magic], rax
    lea rdx, [msg_bad_kernel]
    jne fail

    mov eax, [rsi + 8 + KH.memsize]
    add eax, 0xFFF
    shr eax, 12
    mov [pages], rax
    mov qword [kaddr], 0x7FFFFFFF
    mov rax, [bs]
    mov ecx, 1
    mov edx, 1

    mov r8, [pages]
    lea r9, [kaddr]
    call [rax + 40]
    test rax, rax
    lea rdx, [msg_no_memory]
    jnz fail

    mov rdi, [kaddr]
    mov rcx, [pages]
    shl rcx, 12
    xor eax, eax
    rep stosb
    lea rsi, [kernel]
    mov rdi, [kaddr]
    mov ecx, kernel_end - kernel
    rep movsb

    lea rsi, [relocs]
    lodsd
    mov ecx, eax
    mov edx, [kaddr]
    sub edx, KERNEL_ORG
    mov rdi, [kaddr]
.reloc:
    jecxz .relocated
    lodsd
    add [rdi + rax], edx
    dec ecx
    jmp .reloc
.relocated:

    mov eax, [kernel + 8 + KH.bootinfo]
    mov rbx, [kaddr]
    add rbx, rax
    mov dword [rbx + BI.platform], PLATFORM_UEFI
    mov eax, [kaddr]
    mov [rbx + BI.kbase], eax
    mov ax, cs
    movzx eax, ax
    mov [rbx + BI.cs64], eax
    mov rax, [systab]
    mov [rbx + BI.systab], rax
    mov rcx, [rax + 24]
    mov [rbx + BI.fw_vendor], rcx
    mov ecx, [rax + 32]
    mov [rbx + BI.fw_rev], ecx
    mov rcx, [rax + 48]
    mov [rbx + BI.conin], rcx
    mov rcx, [rcx + 16]
    mov [rbx + BI.wait_key], rcx
    mov rax, [bs]
    mov [rbx + BI.bs], rax
    mov rax, [rs]
    mov [rbx + BI.rs], rax
    mov rax, [image_handle]
    mov [rbx + BI.image], rax

    mov rax, [bs]
    mov rcx, [image_handle]
    lea rdx, [guid_loaded_image]
    lea r8, [tmp]
    call [rax + 152]
    test rax, rax
    jnz .no_disk
    mov rax, [tmp]
    mov rcx, [rax + 24]
    mov [device], rcx
    mov rax, [bs]
    lea rdx, [guid_block_io]
    lea r8, [tmp]
    call [rax + 152]
    test rax, rax
    jnz .no_disk
    mov rax, [tmp]
    mov [rbx + BI.blockio], rax
    mov rax, [bs]
    mov rcx, [device]
    lea rdx, [guid_device_path]
    lea r8, [tmp]
    call [rax + 152]
    test rax, rax
    jnz .no_disk
    mov rax, [tmp]
    mov [rbx + BI.esp_path], rax
.no_disk:

    call setup_graphics
    lea rdx, [msg_no_graphics]
    jc fail
    call count_memory

    mov rax, [bs]
    mov ecx, 0x80000200
    mov edx, 8
    mov r8d, [kernel + 8 + KH.tick]
    add r8, [kaddr]
    xor r9d, r9d
    lea r10, [rbx + BI.tick_event]
    mov [rsp + 32], r10
    call [rax + 80]
    test rax, rax
    lea rdx, [msg_no_timer]
    jnz fail
    mov rax, [bs]
    mov rcx, [rbx + BI.tick_event]
    mov edx, 1
    mov r8d, 100000
    call [rax + 88]
    mov rax, [bs]
    mov ecx, 0x80000000
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    lea r10, [rbx + BI.wait_tick]
    mov [rsp + 32], r10
    call [rax + 80]
    test rax, rax
    lea rdx, [msg_no_timer]
    jnz fail
    mov rax, [bs]
    mov rcx, [rbx + BI.wait_tick]
    mov edx, 1
    mov r8d, 5000000
    call [rax + 88]

    sgdt [gdtr]
    movzx ecx, word [gdtr]
    inc ecx
    add ecx, 7
    and ecx, -8
    mov eax, [kernel + 8 + KH.gdtmax]
    sub eax, 16
    cmp ecx, eax
    lea rdx, [msg_gdt]
    ja fail
    mov eax, [kernel + 8 + KH.gdt]
    mov rdi, [kaddr]
    add rdi, rax
    mov [new_gdtr + 2], rdi
    mov rsi, [gdtr + 2]
    push rcx
    push rdi
    rep movsb
    pop rdi
    pop rcx
    mov rax, 0x00CF9A000000FFFF
    mov [rdi + rcx], rax
    mov rax, 0x00CF92000000FFFF
    mov [rdi + rcx + 8], rax
    mov [sel_code32], ecx
    lea eax, [ecx + 8]
    mov [sel_data32], eax
    lea eax, [ecx + 15]
    mov [new_gdtr], ax
    mov eax, [kernel + 8 + KH.entry]
    add rax, [kaddr]
    mov [entry], rax
    mov eax, [kernel + 8 + KH.stack]
    add rax, [kaddr]
    mov [stack], rax

    cli
    lgdt [new_gdtr]
    mov eax, [sel_data32]
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov rsp, [stack]
    mov eax, [sel_code32]
    push rax
    push qword [entry]
    o64 retf

fail:
    call print
    lea rdx, [msg_key]
    call print
    mov rax, [systab]
    mov rcx, [rax + 48]
    add rcx, 16
    mov rdx, rcx
    mov ecx, 1
    lea r8, [tmp]
    mov rax, [bs]
    call [rax + 96]
    mov eax, 1
    bts rax, 63
    mov rsp, [saved_rsp]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret

print:
    sub rsp, 40
    mov rcx, [conout]
    call [rcx + 8]
    add rsp, 40
    ret

setup_graphics:
    sub rsp, 56
    mov rax, [bs]
    lea rcx, [guid_gop]
    xor edx, edx
    lea r8, [gop]
    call [rax + 320]
    test rax, rax
    jnz .none
    mov rax, [gop]
    mov [rbx + BI.gop], rax
    mov r12d, 1280
    mov r13d, 800
    call .current_fits
    jnc .use
    call find_mode
    jnc .set
    mov r12d, 640
    mov r13d, 400
    call .current_fits
    jnc .use
    call find_mode
    jc .use
.set:
    mov rcx, [gop]
    call [rcx + 8]
.use:
    mov rax, [gop]
    mov rax, [rax + 24]
    mov rdx, [rax + 24]
    mov [rbx + BI.fb_base], rdx
    mov rcx, [rax + 8]
    mov eax, [rcx + 4]
    mov [rbx + BI.fb_width], eax
    mov eax, [rcx + 8]
    mov [rbx + BI.fb_height], eax
    mov eax, [rcx + 12]
    mov [rbx + BI.fb_format], eax
    mov eax, [rcx + 16]
    mov [rbx + BI.fb_rmask], eax
    mov eax, [rcx + 20]
    mov [rbx + BI.fb_gmask], eax
    mov eax, [rcx + 24]
    mov [rbx + BI.fb_bmask], eax
    mov eax, [rcx + 32]
    mov [rbx + BI.fb_pitch], eax
    cmp dword [rbx + BI.fb_width], 640
    jb .none
    cmp dword [rbx + BI.fb_height], 400
    jb .none
    add rsp, 56
    clc
    ret
.none:
    add rsp, 56
    stc
    ret
.current_fits:
    mov rax, [gop]
    mov rax, [rax + 24]
    mov rcx, [rax + 8]
    mov eax, [rcx + 4]
    mov edx, [rcx + 8]
    jmp mode_fits

find_mode:
    sub rsp, 40
    mov dword [best_mode], -1
    mov qword [best_area], 0
    mov dword [mode_no], 0
.query:
    mov rax, [gop]
    mov rax, [rax + 24]
    mov ecx, [rax]
    cmp [mode_no], ecx
    jae .chosen
    mov rcx, [gop]
    mov edx, [mode_no]
    lea r8, [tmp]
    lea r9, [tmp + 8]
    call [rcx]
    test rax, rax
    jnz .next
    mov rcx, [tmp + 8]
    cmp dword [rcx + 12], 3
    je .next
    mov eax, [rcx + 4]
    mov edx, [rcx + 8]
    call mode_fits
    jc .next
    imul eax, edx
    cmp rax, [best_area]
    jbe .next
    mov [best_area], rax
    mov eax, [mode_no]
    mov [best_mode], eax
.next:
    inc dword [mode_no]
    jmp .query
.chosen:
    add rsp, 40
    mov edx, [best_mode]
    cmp edx, -1
    je .none
    clc
    ret
.none:
    stc
    ret

mode_fits:
    cmp eax, r12d
    jb .bad
    cmp edx, r13d
    jb .bad
    cmp eax, 1280
    ja .bad
    cmp edx, 1024
    ja .bad
    clc
    ret
.bad:
    stc
    ret

count_memory:
    sub rsp, 56
    mov qword [map_size], 0
    mov rax, [bs]
    lea rcx, [map_size]
    xor edx, edx
    lea r8, [map_key]
    lea r9, [desc_size]
    lea r10, [desc_ver]
    mov [rsp + 32], r10
    call [rax + 56]
    add qword [map_size], 4096
    mov rax, [bs]
    mov ecx, 2
    mov rdx, [map_size]
    lea r8, [map_buf]
    call [rax + 64]
    test rax, rax
    jnz .done
    mov rax, [bs]
    lea rcx, [map_size]
    mov rdx, [map_buf]
    lea r8, [map_key]
    lea r9, [desc_size]
    lea r10, [desc_ver]
    mov [rsp + 32], r10
    call [rax + 56]
    test rax, rax
    jnz .free
    mov rsi, [map_buf]
    mov rcx, rsi
    add rcx, [map_size]
    xor edx, edx
.entry:
    cmp rsi, rcx
    jae .total
    mov eax, [rsi]
    cmp eax, 8
    je .skip
    test eax, eax
    jz .skip
    cmp eax, 10
    ja .skip
    add rdx, [rsi + 24]
.skip:
    add rsi, [desc_size]
    jmp .entry
.total:
    shl rdx, 2
    mov [rbx + BI.ram_kb], edx
.free:
    mov rax, [bs]
    mov rcx, [map_buf]
    call [rax + 72]
.done:
    add rsp, 56
    ret

align 8
image_handle    dq 0
saved_rsp       dq 0
systab          dq 0
bs              dq 0
rs              dq 0
conout          dq 0
device          dq 0
gop             dq 0
kaddr           dq 0
pages           dq 0
entry           dq 0
stack           dq 0
tmp             dq 0, 0
best_area       dq 0
map_size        dq 0
map_key         dq 0
desc_size       dq 0
desc_ver        dq 0
map_buf         dq 0
best_mode       dd 0
mode_no         dd 0
sel_code32      dd 0
sel_data32      dd 0
gdtr            dw 0
                dq 0
new_gdtr        dw 0
                dq 0

guid_loaded_image:
    dd 0x5B1B31A1
    dw 0x9562, 0x11D2
    db 0x8E, 0x3F, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B
guid_block_io:
    dd 0x964E5B21
    dw 0x6459, 0x11D2
    db 0x8E, 0x39, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B
guid_device_path:
    dd 0x09576E91
    dw 0x6D3F, 0x11D2
    db 0x8E, 0x39, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B
guid_gop:
    dd 0x9042A9DE
    dw 0x23DC, 0x4A38
    db 0x96, 0xFB, 0x7A, 0xDE, 0xD0, 0x80, 0x51, 0x6A

msg_hello       dw __utf16__("MOOS loader starting..."), 13, 10, 0
msg_bad_kernel  dw __utf16__("MOOS: the kernel inside BOOTX64.EFI is damaged."), 13, 10, 0
msg_no_memory   dw __utf16__("MOOS: not enough free memory below 2 GB."), 13, 10, 0
msg_no_graphics dw __utf16__("MOOS: no graphics mode of at least 640x400 found."), 13, 10, 0
msg_no_timer    dw __utf16__("MOOS: the firmware refused to create a timer."), 13, 10, 0
msg_gdt         dw __utf16__("MOOS: unexpected firmware (GDT too large)."), 13, 10, 0
msg_key         dw __utf16__("Press any key to return to the firmware."), 13, 10, 0

align 16
kernel:
    incbin "build/kernel.bin"
kernel_end:
align 4
relocs:
    incbin "build/kernel.rel"
text_end:

TEXT_SIZE   equ text_end - text
TEXT_RAW    equ (TEXT_SIZE + 0x1FF) & ~0x1FF
RELOC_RVA   equ (TEXT_RVA + TEXT_SIZE + 0xFFF) & ~0xFFF
IMAGE_SIZE  equ RELOC_RVA + 0x1000

    times TEXT_RAW - TEXT_SIZE db 0
reloc_section:
    dd TEXT_RVA, 8
    times 0x200 - 8 db 0
