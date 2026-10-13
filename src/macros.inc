; =============================================================================
;  MOOS - shared definitions and macros
; =============================================================================

%define OS_NAME    "MOOS"
%define OS_VERSION "1.2"
%define OS_LONGNAME "Mightily Optimized Operating System"

; VGA attributes: (background << 4) | foreground
C_DEFAULT   equ 0x07                ; light grey on black
C_STATUS    equ 0x1F                ; white on blue
C_PROMPT    equ 0x0A                ; light green
C_HEADING   equ 0x0E                ; yellow
C_MORE      equ 0x70                ; black on light grey
C_PANIC     equ 0x4F                ; white on red

; Special key codes returned by kbd_getkey (ASCII keys return their code)
KEY_UP      equ 0x101
KEY_DOWN    equ 0x102
KEY_LEFT    equ 0x103
KEY_RIGHT   equ 0x104
KEY_HOME    equ 0x105
KEY_END     equ 0x106
KEY_DEL     equ 0x107
KEY_PGUP    equ 0x108
KEY_PGDN    equ 0x109

; -----------------------------------------------------------------------------
; PRINTF `format`, arg1, arg2, ...
;   Formatted output through kprintf (see vga.asm). Arguments are pushed as
;   dwords; all registers and the stack are preserved.
;   Directives: %s %d %i %x %c %%, optional width (%5d, %-ish for %s: %12s
;   pads on the right), %02d zero pads. \x01 + letter changes colour:
;   r red, g green, y yellow, c cyan, w white, d dark grey, b blue, n normal.
; -----------------------------------------------------------------------------
%macro PRINTF 1-*
    [section .data]
    %%fmt: db %1, 0
    __SECT__
    %rep %0 - 1
        %rotate -1
        push %1
    %endrep
    push %%fmt
    call kprintf
    add esp, %0 * 4
%endmacro

; -----------------------------------------------------------------------------
; Command / manual tables (each entry: name, handler, description, manual)
; Use these inside "section .text" so the strings can go to .data.
; -----------------------------------------------------------------------------
%macro COMMAND 4                    ; "name", handler, "description", manual
    [section .data]
    %%n: db %1, 0
    %%d: db %3, 0
    __SECT__
    dd %%n, %2, %%d, %4
%endmacro

%macro ALIAS 3                      ; "name", handler, manual (hidden in help)
    [section .data]
    %%n: db %1, 0
    __SECT__
    dd %%n, %2, 0, %3
%endmacro

%macro TOPIC 2                      ; "name", manual  (manual-only pages)
    [section .data]
    %%n: db %1, 0
    __SECT__
    dd %%n, %2
%endmacro

CMD_NAME    equ 0
CMD_FUNC    equ 4
CMD_DESC    equ 8
CMD_MAN     equ 12
CMD_SIZE    equ 16

; -----------------------------------------------------------------------------
; C-style calls, used by the crypto / TLS code (many arguments per call).
;   CCALL fn, a, b, c   pushes c, b, a, calls fn, then drops the arguments.
;   Functions written with CENTER / CLEAVE keep EBX ESI EDI EBP; EAX ECX EDX
;   may change; the result comes back in EAX. ARG(0) is the first argument.
;   Pass memory operands as "dword [x]".
; -----------------------------------------------------------------------------
%macro CCALL 1-*
    %rep %0 - 1
        %rotate -1
        push %1
    %endrep
    %rotate -1
    call %1
    %if %0 > 1
        add esp, 4 * (%0 - 1)
    %endif
%endmacro

%macro CENTER 0
    push ebp
    mov ebp, esp
    push ebx
    push esi
    push edi
%endmacro

%macro CLEAVE 0
    pop edi
    pop esi
    pop ebx
    pop ebp
    ret
%endmacro

%define ARG(n) [ebp + 8 + 4 * (n)]
