section .bss
alignb 4
calc_ptr    resd 1
calc_start  resd 1
calc_esp    resd 1
calc_msg    resd 1
calc_res    resd 1
calc_ans    resd 1
id_buf      resb 32

section .data
calc_prompt     db "calc> ", 0
str_ans         db "ans", 0
ce_unexpected   db "unexpected character", 0
ce_divzero      db "division by zero is not allowed", 0
ce_overflow     db "number too big (limit: -2147483648 .. 2147483647)", 0
ce_paren        db "missing closing ')'", 0
ce_expected     db "expected a number or '('", 0
ce_incomplete   db "the expression ends too early", 0
ce_negexp       db "negative powers are not supported (whole numbers only)", 0
ce_digits       db "expected digits after 0x / 0b", 0
ce_unknown_var  db "unknown name (variable not set)", 0

section .text

cmd_calc:
    mov esi, [rest_ptr]
    cmp byte [esi], 0
    je .interactive
    jmp calc_show
.interactive:
    PRINTF `Calculator mode. Type a sum like \x01w(2+3)*4\x01n and press Enter.\n`
    PRINTF `\x01dans = previous result. Empty line, q or Ctrl+C returns to the shell.\x01n\n`
.l: mov esi, calc_prompt
    mov bl, 0x0B
    xor bh, bh
    call readline
    test eax, eax
    jnz .exit
    mov esi, line_buf
    call skip_spaces
    mov al, [esi]
    test al, al
    jz .exit
    call to_lower
    cmp al, 'q'
    je .exit
    call calc_show
    jmp .l
.exit:
    ret

calc_show:
    call calc_eval
    jc .err
    mov [calc_ans], eax
    PRINTF `= \x01w%i\x01n   \x01d(hex %x)\x01n\n`, eax, eax
    ret
.err:
    inc ecx
    PRINTF `\x01rerror:\x01n %s (at character %d)\n`, esi, ecx
    ret

calc_eval:
    pushad
    mov [calc_esp], esp
    mov [calc_ptr], esi
    mov [calc_start], esi
    call c_compare
    call c_peek
    test bl, bl
    jz .ok
    mov esi, ce_unexpected
    jmp calc_fail
.ok:
    mov [calc_res], eax
    popad
    mov eax, [calc_res]
    clc
    ret

calc_fail:
    mov esp, [calc_esp]
    mov [calc_msg], esi
    popad
    mov esi, [calc_msg]
    mov ecx, [calc_ptr]
    sub ecx, [calc_start]
    stc
    ret

c_overflow:
    mov esi, ce_overflow
    jmp calc_fail

c_peek:
    push esi
    mov esi, [calc_ptr]
    call skip_spaces
    mov [calc_ptr], esi
    mov bl, [esi]
    pop esi
    ret

c_compare:
    call c_expr
    call c_peek
    mov dl, bl
    cmp bl, '<'
    je .op
    cmp bl, '>'
    je .op
    cmp bl, '='
    je .op
    cmp bl, '!'
    je .op
    ret
.op:
    inc dword [calc_ptr]
    mov dh, 0
    call c_peek
    cmp bl, '='
    jne .right
    inc dword [calc_ptr]
    mov dh, '='
.right:
    push eax
    call c_expr
    mov ecx, eax
    pop eax

    cmp dl, '<'
    je .lt
    cmp dl, '>'
    je .gt
    cmp dl, '='
    je .eq
    cmp eax, ecx
    setne al
    jmp .done
.lt:
    cmp dh, '='
    je .le
    cmp eax, ecx
    setl al
    jmp .done
.le:
    cmp eax, ecx
    setle al
    jmp .done
.gt:
    cmp dh, '='
    je .ge
    cmp eax, ecx
    setg al
    jmp .done
.ge:
    cmp eax, ecx
    setge al
    jmp .done
.eq:
    cmp eax, ecx
    sete al
.done:
    movzx eax, al
    ret

c_expr:
    call c_term
.l: call c_peek
    cmp bl, '+'
    je .add
    cmp bl, '-'
    je .sub
    ret
.add:
    inc dword [calc_ptr]
    push eax
    call c_term
    pop edx
    add edx, eax
    jo c_overflow
    mov eax, edx
    jmp .l
.sub:
    inc dword [calc_ptr]
    push eax
    call c_term
    pop edx
    sub edx, eax
    jo c_overflow
    mov eax, edx
    jmp .l

c_term:
    call c_unary
.l: call c_peek
    cmp bl, '*'
    je .mul
    cmp bl, '/'
    je .div
    cmp bl, '%'
    je .mod
    ret
.mul:
    inc dword [calc_ptr]
    push eax
    call c_unary
    pop edx
    imul edx, eax
    jo c_overflow
    mov eax, edx
    jmp .l
.div:
    inc dword [calc_ptr]
    push eax
    call c_unary
    mov ecx, eax
    pop eax
    call c_divide
    jmp .l
.mod:
    inc dword [calc_ptr]
    push eax
    call c_unary
    mov ecx, eax
    pop eax
    call c_divide
    mov eax, edx
    jmp .l

c_divide:
    test ecx, ecx
    jz .zero
    cmp ecx, -1
    jne .ok
    cmp eax, 0x80000000
    je c_overflow
.ok:
    cdq
    idiv ecx
    ret
.zero:
    mov esi, ce_divzero
    jmp calc_fail

c_unary:
    call c_peek
    cmp bl, '-'
    je .neg
    cmp bl, '+'
    je .pos
    jmp c_power
.neg:
    inc dword [calc_ptr]
    call c_unary
    neg eax
    jo c_overflow
    ret
.pos:
    inc dword [calc_ptr]
    jmp c_unary

c_power:
    call c_primary
    call c_peek
    cmp bl, '^'
    jne .r
    inc dword [calc_ptr]
    push eax
    call c_unary
    mov ecx, eax
    pop edx
    test ecx, ecx
    js .negative
    mov eax, 1
    cmp edx, 1
    je .r
    cmp edx, -1
    je .minus_one
    test ecx, ecx
    jz .r
    test edx, edx
    jnz .loop
    xor eax, eax
    ret
.minus_one:
    test ecx, 1
    jz .r
    mov eax, -1
    ret
.loop:
    imul eax, edx
    jo c_overflow
    dec ecx
    jnz .loop
.r: ret
.negative:
    mov esi, ce_negexp
    jmp calc_fail

c_primary:
    call c_peek
    cmp bl, '('
    je .paren
    cmp bl, '0'
    jb .word
    cmp bl, '9'
    jbe c_number
.word:
    mov esi, [calc_ptr]
    mov al, [esi]
    call to_lower
    cmp al, 'a'
    jb .not_ident
    cmp al, 'z'
    jbe .read
    cmp byte [esi], '_'
    je .read
.not_ident:
    mov esi, ce_expected
    test bl, bl
    jnz calc_fail
    mov esi, ce_incomplete
    jmp calc_fail
.read:
    mov edi, id_buf
.rl:
    mov al, [esi]
    call is_ident_char
    jc .id_done
    mov [edi], al
    inc edi
    inc esi
    cmp edi, id_buf + 30
    jb .rl
.id_done:
    mov byte [edi], 0
    mov [calc_ptr], esi
    mov esi, id_buf
    mov edi, str_ans
    call str_icmp
    je .is_ans
    mov esi, id_buf
    call var_lookup
    jc .unknown
    ret
.is_ans:
    mov eax, [calc_ans]
    ret
.unknown:
    mov esi, ce_unknown_var
    jmp calc_fail

.paren:
    inc dword [calc_ptr]
    call c_expr
    call c_peek
    cmp bl, ')'
    jne .no_close
    inc dword [calc_ptr]
    ret
.no_close:
    mov esi, ce_paren
    jmp calc_fail

is_ident_char:
    cmp al, '_'
    je .yes
    cmp al, '0'
    jb .no
    cmp al, '9'
    jbe .yes
    push eax
    call to_lower
    cmp al, 'a'
    jb .no_pop
    cmp al, 'z'
    ja .no_pop
    pop eax
.yes:
    clc
    ret
.no_pop:
    pop eax
.no:
    stc
    ret

c_number:
    mov esi, [calc_ptr]
    xor eax, eax
    cmp byte [esi], '0'
    jne .dec
    mov bl, [esi + 1]
    or bl, 0x20
    cmp bl, 'x'
    je .hex
    cmp bl, 'b'
    je .bin
.dec:
    movzx ebx, byte [esi]
    sub bl, '0'
    cmp bl, 9
    ja .done
    imul eax, eax, 10
    jo c_overflow
    add eax, ebx
    jo c_overflow
    inc esi
    mov [calc_ptr], esi
    jmp .dec
.hex:
    add esi, 2
    mov [calc_ptr], esi
    xor ecx, ecx
.hl:
    movzx ebx, byte [esi]
    sub bl, '0'
    cmp bl, 9
    jbe .hdigit
    movzx ebx, byte [esi]
    or bl, 0x20
    sub bl, 'a'
    cmp bl, 5
    ja .hend
    add bl, 10
.hdigit:
    test eax, 0xF0000000
    jnz c_overflow
    shl eax, 4
    or eax, ebx
    inc esi
    mov [calc_ptr], esi
    inc ecx
    jmp .hl
.hend:
    jecxz .no_digits
    jmp .done
.bin:
    add esi, 2
    mov [calc_ptr], esi
    xor ecx, ecx
.bloop:
    movzx ebx, byte [esi]
    sub bl, '0'
    cmp bl, 1
    ja .bend
    test eax, 0x80000000
    jnz c_overflow
    shl eax, 1
    or eax, ebx
    inc esi
    mov [calc_ptr], esi
    inc ecx
    jmp .bloop
.bend:
    jecxz .no_digits
.done:
    mov [calc_ptr], esi
    ret
.no_digits:
    mov esi, ce_digits
    jmp calc_fail
