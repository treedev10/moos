%define OS_NAME    "MOOS"
%define OS_VERSION "1.2"
%define OS_LONGNAME "Mightily Optimized Operating System"

C_DEFAULT   equ 0x07
C_STATUS    equ 0x1F
C_PROMPT    equ 0x0A
C_HEADING   equ 0x0E
C_MORE      equ 0x70
C_PANIC     equ 0x4F

KEY_UP      equ 0x101
KEY_DOWN    equ 0x102
KEY_LEFT    equ 0x103
KEY_RIGHT   equ 0x104
KEY_HOME    equ 0x105
KEY_END     equ 0x106
KEY_DEL     equ 0x107
KEY_PGUP    equ 0x108
KEY_PGDN    equ 0x109
KEY_F1      equ 0x111

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

%macro COMMAND 4
    [section .data]
    %%n: db %1, 0
    %%d: db %3, 0
    __SECT__
    dd %%n, %2, %%d, %4
%endmacro

%macro ALIAS 3
    [section .data]
    %%n: db %1, 0
    __SECT__
    dd %%n, %2, 0, %3
%endmacro

%macro TOPIC 2
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
