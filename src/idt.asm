; =============================================================================
;  idt.asm - interrupt descriptor table, CPU exceptions, PIC, PIT timer
; =============================================================================
PIT_HZ      equ 100
PIT_DIVISOR equ 1193182 / PIT_HZ

section .bss
alignb 8
idt         resb 256 * 8
ticks       resd 1                  ; timer ticks since boot (100 per second)
bios_pic_mask resw 1                ; interrupt masks the BIOS used

section .data
idt_desc    dw 256 * 8 - 1
            dd idt

; MOOS's own segment table: the two flat 32-bit segments the boot sector
; also uses, plus 16-bit ones for calling the BIOS (see bios.asm)
align 8
kernel_gdt:
    dq 0
    dq 0x00CF9A000000FFFF           ; 0x08 code, 32-bit, base 0, 4 GB
    dq 0x00CF92000000FFFF           ; 0x10 data, 32-bit, base 0, 4 GB
    dq 0x00009A010000FFFF           ; 0x18 code, 16-bit, base 0x10000, 64 KB
    dq 0x000092010000FFFF           ; 0x20 data, 16-bit, base 0x10000, 64 KB
kernel_gdt_desc:
    dw $ - kernel_gdt - 1
    dd kernel_gdt

exc_names:
    dd e0, e1, e2, e3, e4, e5, e6, e7, e8, e9, e10, e11, e12, e13, e14, e15
    dd e16, e17, e18, e19
e0  db "Division by zero", 0
e1  db "Debug", 0
e2  db "Non-maskable interrupt", 0
e3  db "Breakpoint", 0
e4  db "Overflow", 0
e5  db "Bound range exceeded", 0
e6  db "Invalid opcode", 0
e7  db "Device not available", 0
e8  db "Double fault", 0
e9  db "Coprocessor segment overrun", 0
e10 db "Invalid TSS", 0
e11 db "Segment not present", 0
e12 db "Stack-segment fault", 0
e13 db "General protection fault", 0
e14 db "Page fault", 0
e15 db "Reserved", 0
e16 db "x87 floating-point error", 0
e17 db "Alignment check", 0
e18 db "Machine check", 0
e19 db "SIMD floating-point error", 0
e_other db "CPU exception", 0

section .text

; Exception stubs: push a dummy error code when the CPU does not, then the
; vector number, so exc_common always sees the same stack layout.
%macro EXC_NOERR 1
exc%1:
    push dword 0
    push dword %1
    jmp exc_common
%endmacro
%macro EXC_ERR 1
exc%1:
    push dword %1
    jmp exc_common
%endmacro

EXC_NOERR 0
EXC_NOERR 1
EXC_NOERR 2
EXC_NOERR 3
EXC_NOERR 4
EXC_NOERR 5
EXC_NOERR 6
EXC_NOERR 7
EXC_ERR   8
EXC_NOERR 9
EXC_ERR   10
EXC_ERR   11
EXC_ERR   12
EXC_ERR   13
EXC_ERR   14
EXC_NOERR 15
EXC_NOERR 16
EXC_ERR   17
EXC_NOERR 18
EXC_NOERR 19
EXC_NOERR 20
EXC_ERR   21
EXC_NOERR 22
EXC_NOERR 23
EXC_NOERR 24
EXC_NOERR 25
EXC_NOERR 26
EXC_NOERR 27
EXC_NOERR 28
EXC_ERR   29
EXC_ERR   30
EXC_NOERR 31

exc_table:
    dd exc0, exc1, exc2, exc3, exc4, exc5, exc6, exc7
    dd exc8, exc9, exc10, exc11, exc12, exc13, exc14, exc15
    dd exc16, exc17, exc18, exc19, exc20, exc21, exc22, exc23
    dd exc24, exc25, exc26, exc27, exc28, exc29, exc30, exc31

; exc_common: stack = vector, error code, EIP, CS, EFLAGS. Never returns.
exc_common:
    cli
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    pop ebx                         ; vector
    pop ecx                         ; error code
    pop edx                         ; faulting EIP
    mov byte [out_mode], 0
    mov byte [text_attr], C_PANIC
    call vga_fresh_line
    mov esi, e_other
    cmp ebx, 19
    ja .named
    mov esi, [exc_names + ebx * 4]
.named:
    PRINTF ` *** KERNEL PANIC ***  %s (exception %d)  EIP=%08x  error=%x \n`, esi, ebx, edx, ecx
    PRINTF ` The system was stopped to protect your data. Press any key to restart. \n`
    call screen_present
.drain:                             ; poll the keyboard directly (IRQs are off)
    in al, 0x64
    test al, 1
    jz .wait
    in al, 0x60
    jmp .drain
.wait:
    in al, 0x64
    test al, 1
    jz .wait
    in al, 0x60
    test al, 0x80                   ; ignore key releases
    jnz .wait
    jmp system_reboot

; idt_set_gate: EBX = vector, EAX = handler address
idt_set_gate:
    push eax
    push edi
    lea edi, [idt + ebx * 8]
    mov [edi], ax
    mov word [edi + 2], 0x08
    mov byte [edi + 4], 0
    mov byte [edi + 5], 0x8E        ; present, ring 0, 32-bit interrupt gate
    shr eax, 16
    mov [edi + 6], ax
    pop edi
    pop eax
    ret

idt_init:
    pushad
    lgdt [kernel_gdt_desc]
    xor ebx, ebx
.exc:
    mov eax, [exc_table + ebx * 4]
    call idt_set_gate
    inc ebx
    cmp ebx, 32
    jb .exc
.irq:                               ; vectors 32-47 = IRQ 0-15
    mov eax, irq_master_eoi
    cmp ebx, 40
    jb .set
    mov eax, irq_slave_eoi
.set:
    call idt_set_gate
    inc ebx
    cmp ebx, 48
    jb .irq
    mov ebx, 32
    mov eax, irq0_timer
    call idt_set_gate
    mov ebx, 33
    mov eax, irq1_keyboard
    call idt_set_gate
    lidt [idt_desc]
    call pic_remap
    call pit_init
    popad
    ret

%macro IO_WAIT 0
    out 0x80, al
%endmacro

; pic_remap: remember the BIOS's interrupt masks, then move IRQ 0-15 to
; vectors 32-47 and unmask only the timer and the keyboard
pic_remap:
    in al, 0x21
    mov [bios_pic_mask], al
    in al, 0xA1
    mov [bios_pic_mask + 1], al
    jmp pic_moos_mode.pic

; pic_program: BL/BH = master/slave vector base, CL/CH = master/slave mask
pic_program:
    mov al, 0x11
    out 0x20, al
    IO_WAIT
    out 0xA0, al
    IO_WAIT
    mov al, bl
    out 0x21, al
    IO_WAIT
    mov al, bh
    out 0xA1, al
    IO_WAIT
    mov al, 4
    out 0x21, al
    IO_WAIT
    mov al, 2
    out 0xA1, al
    IO_WAIT
    mov al, 1
    out 0x21, al
    IO_WAIT
    out 0xA1, al
    IO_WAIT
    mov al, cl
    out 0x21, al
    mov al, ch
    out 0xA1, al
    ret

; pic_moos_mode: the interrupt setup MOOS uses (also restores the timer)
pic_moos_mode:
    push eax
    mov ax, PIT_DIVISOR
    call pit_set
    pop eax
.pic:
    push ebx
    push ecx
    mov bx, 0x2820
    mov cx, 0xFFFC
    call pic_program
    pop ecx
    pop ebx
    ret

; pic_bios_mode: the setup the BIOS expects (vectors 8 and 0x70, its masks,
; the standard 18.2 Hz timer) - used while calling the BIOS
pic_bios_mode:
    push eax
    push ebx
    push ecx
    xor ax, ax
    call pit_set
    mov bx, 0x7008
    mov cx, [bios_pic_mask]
    or cl, 2                        ; keep keys for MOOS (see kbd_collect)
    call pic_program
    pop ecx
    pop ebx
    pop eax
    ret

; pit_init: channel 0, rate generator, PIT_HZ interrupts per second
pit_init:
    mov ax, PIT_DIVISOR

; pit_set: AX = PIT divisor (0 = 65536, the BIOS default)
pit_set:
    push eax
    mov al, 0x36
    out 0x43, al
    pop eax
    out 0x40, al
    mov al, ah
    out 0x40, al
    ret

irq0_timer:
    push eax
    inc dword [ticks]
    mov al, 0x20
    out 0x20, al
    pop eax
    iretd

irq_master_eoi:
    push eax
    mov al, 0x20
    out 0x20, al
    pop eax
    iretd

irq_slave_eoi:
    push eax
    mov al, 0x20
    out 0xA0, al
    out 0x20, al
    pop eax
    iretd

; sleep_ticks: ECX = number of 1/100 s ticks to wait (CPU halts meanwhile)
sleep_ticks:
    push eax
    call screen_present
    mov eax, [ticks]
    add eax, ecx
.w: hlt
    cmp [ticks], eax
    jb .w
    pop eax
    ret
