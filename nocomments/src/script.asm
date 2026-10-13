MAX_VARS    equ 32
VAR_NAMELEN equ 16
MAX_LINES   equ 512
MAX_NEST    equ 32

section .bss
alignb 4
var_names   resb MAX_VARS * VAR_NAMELEN
var_vals    resd MAX_VARS
var_count   resd 1
alignb 4
sc_lines    resd MAX_LINES
sc_match    resd MAX_LINES
sc_else     resd MAX_LINES
sc_back     resd MAX_LINES
sc_nline    resd 1
sc_pc       resd 1
sc_tmp      resb 128
sc_name     resb 32
sc_err      resb 1
st_line     resd MAX_NEST
st_kind     resb MAX_NEST
st_else     resd MAX_NEST
alignb 4
st_sp       resd 1

section .data
kw_set      db "set", 0
kw_let      db "let", 0
kw_print    db "print", 0
kw_if       db "if", 0
kw_else     db "else", 0
kw_end      db "end", 0
kw_while    db "while", 0
sc_e_stmt   db "unknown statement", 0
sc_e_assign db "expected  name = value", 0
sc_e_nest   db "if/while without a matching end", 0
u_run       db "run <file>", 0

section .text

var_lookup:
    push ebx
    push ecx
    push edi
    xor ebx, ebx
.l: cmp ebx, [var_count]
    jae .no
    mov eax, ebx
    imul eax, VAR_NAMELEN
    lea edi, [var_names + eax]
    push esi
    call str_icmp
    pop esi
    je .hit
    inc ebx
    jmp .l
.hit:
    mov eax, [var_vals + ebx * 4]
    pop edi
    pop ecx
    pop ebx
    clc
    ret
.no:
    pop edi
    pop ecx
    pop ebx
    stc
    ret

var_set:
    pushad
    mov ebp, eax
    xor ebx, ebx
.l: cmp ebx, [var_count]
    jae .new
    mov eax, ebx
    imul eax, VAR_NAMELEN
    lea edi, [var_names + eax]
    push esi
    call str_icmp
    pop esi
    je .store
    inc ebx
    jmp .l
.new:
    cmp ebx, MAX_VARS
    jae .done
    mov eax, ebx
    imul eax, VAR_NAMELEN
    lea edi, [var_names + eax]
    push ebx
    mov ecx, VAR_NAMELEN - 1
.cp: mov al, [esi]
    test al, al
    jz .cpend
    mov [edi], al
    inc edi
    inc esi
    dec ecx
    jnz .cp
.cpend:
    mov byte [edi], 0
    pop ebx
    inc dword [var_count]
.store:
    mov [var_vals + ebx * 4], ebp
.done:
    popad
    ret

var_clear:
    mov dword [var_count], 0
    ret

script_run:
    pushad
    call var_clear
    mov byte [sc_err], 0
    mov dword [sc_nline], 0

    mov edi, esi
.split:
    mov eax, [sc_nline]
    cmp eax, MAX_LINES
    jae .scan
    mov [sc_lines + eax * 4], edi
    inc dword [sc_nline]
.eol:
    mov al, [edi]
    test al, al
    jz .scan
    cmp al, 10
    je .cut
    cmp al, 13
    je .cutcr
    inc edi
    jmp .eol
.cutcr:
    mov byte [edi], 0
    inc edi
    cmp byte [edi], 10
    jne .split
    inc edi
    jmp .split
.cut:
    mov byte [edi], 0
    inc edi
    jmp .split
.scan:
    call sc_prescan
    jc .nest_err

    mov dword [sc_pc], 0
.exec:
    mov eax, [sc_pc]
    cmp eax, [sc_nline]
    jae .finish
    call sc_exec_line
    cmp byte [sc_err], 0
    jne .finish
    jmp .exec
.finish:
    popad
    ret
.nest_err:
    PRINTF `\x01rscript error:\x01n %s\n`, sc_e_nest
    popad
    ret

sc_line_word:
    call skip_spaces
    push esi
    mov edi, sc_tmp
.l: mov al, [esi]
    test al, al
    jz .e
    cmp al, ' '
    je .e
    mov [edi], al
    inc edi
    inc esi
    jmp .l
.e: mov byte [edi], 0
    pop esi
    ret

sc_prescan:
    pushad
    mov dword [st_sp], 0
    xor ebx, ebx
.l: cmp ebx, [sc_nline]
    jae .done
    mov dword [sc_else + ebx * 4], -1
    mov dword [sc_back + ebx * 4], -1
    mov esi, [sc_lines + ebx * 4]
    call skip_spaces
    mov edi, kw_if
    call sc_word_is
    je .push_if
    mov edi, kw_while
    call sc_word_is
    je .push_while
    mov edi, kw_else
    call sc_word_is
    je .is_else
    mov edi, kw_end
    call sc_word_is
    je .is_end
.next:
    inc ebx
    jmp .l
.push_if:
    call .push
    mov byte [st_kind + eax], 1
    jmp .next
.push_while:
    call .push
    mov byte [st_kind + eax], 2
    jmp .next
.is_else:
    mov eax, [st_sp]
    test eax, eax
    jz .bad
    dec eax
    mov edx, [st_line + eax * 4]
    mov [sc_else + edx * 4], ebx
    mov [st_else + eax * 4], ebx
    jmp .next
.is_end:
    mov eax, [st_sp]
    test eax, eax
    jz .bad
    dec eax
    mov [st_sp], eax
    mov edx, [st_line + eax * 4]
    mov [sc_match + edx * 4], ebx
    movzx ecx, byte [st_kind + eax]
    cmp ecx, 2
    jne .end_if
    mov [sc_back + ebx * 4], edx
    jmp .next
.end_if:
    mov edx, [st_else + eax * 4]
    cmp edx, -1
    je .next
    mov ecx, ebx
    mov [sc_match + edx * 4], ecx
    jmp .next
.done:
    cmp dword [st_sp], 0
    jne .bad
    popad
    clc
    ret
.bad:
    popad
    stc
    ret

.push:
    mov eax, [st_sp]
    cmp eax, MAX_NEST
    jae .bad
    mov [st_line + eax * 4], ebx
    mov dword [st_else + eax * 4], -1
    inc dword [st_sp]
    ret

sc_word_is:
    push esi
    push edi
.l: mov al, [edi]
    test al, al
    jz .end_kw
    mov ah, [esi]
    cmp al, ah
    jne .no
    inc esi
    inc edi
    jmp .l
.end_kw:
    mov al, [esi]
    test al, al
    jz .yes
    cmp al, ' '
    je .yes
.no:
    pop edi
    pop esi
    or al, 1
    ret
.yes:
    pop edi
    pop esi
    cmp al, al
    ret

sc_exec_line:
    mov eax, [sc_pc]
    mov esi, [sc_lines + eax * 4]
    call skip_spaces
    mov al, [esi]
    test al, al
    jz .nextline
    cmp al, '#'
    je .nextline
    mov edi, kw_print
    call sc_word_is
    je .print
    mov edi, kw_if
    call sc_word_is
    je .if
    mov edi, kw_while
    call sc_word_is
    je .while
    mov edi, kw_else
    call sc_word_is
    je .else
    mov edi, kw_end
    call sc_word_is
    je .end
    mov edi, kw_set
    call sc_word_is
    je .set
    mov edi, kw_let
    call sc_word_is
    je .set

    call sc_try_assign
    jnc .nextline
    mov esi, sc_e_stmt
    jmp .error
.nextline:
    inc dword [sc_pc]
    ret
.print:
    add esi, 5
    call sc_do_print
    jmp .nextline
.set:
    add esi, 3
    call skip_spaces
    call sc_do_assign
    jc .err_esi
    jmp .nextline
.if:
    add esi, 2
    call sc_eval
    jc .err_esi
    test eax, eax
    jnz .nextline
    mov eax, [sc_pc]
    mov edx, [sc_else + eax * 4]
    cmp edx, -1
    jne .goto_else
    mov edx, [sc_match + eax * 4]
    inc edx
    mov [sc_pc], edx
    ret
.goto_else:
    inc edx
    mov [sc_pc], edx
    ret
.while:
    add esi, 5
    call sc_eval
    jc .err_esi
    test eax, eax
    jnz .nextline
    mov eax, [sc_pc]
    mov edx, [sc_match + eax * 4]
    inc edx
    mov [sc_pc], edx
    ret
.else:
    mov eax, [sc_pc]
    mov edx, [sc_match + eax * 4]
    inc edx
    mov [sc_pc], edx
    ret
.end:
    mov eax, [sc_pc]
    mov edx, [sc_back + eax * 4]
    cmp edx, -1
    je .nextline
    mov [sc_pc], edx
    ret
.err_esi:
    jmp .error
.error:
    PRINTF `\x01rscript error\x01n (line %d): %s\n`, dword [sc_pc], esi
    mov byte [sc_err], 1
    ret

sc_try_assign:
    push esi
    mov al, [esi]
    call to_lower
    cmp al, 'a'
    jb .no
    cmp al, 'z'
    ja .no

    push esi
.scan:
    mov al, [esi]
    test al, al
    jz .no_pop
    cmp al, '='
    je .found
    inc esi
    jmp .scan
.found:
    cmp byte [esi + 1], '='
    je .no_pop
    pop esi
    call sc_do_assign
    pop esi
    ret
.no_pop:
    pop esi
.no:
    pop esi
    stc
    ret

sc_do_assign:
    push edi
    call skip_spaces
    mov edi, sc_name
.name:
    mov al, [esi]
    call is_ident_char
    jc .name_done
    mov [edi], al
    inc edi
    inc esi
    jmp .name
.name_done:
    mov byte [edi], 0
    cmp edi, sc_name
    je .bad
    call skip_spaces
    cmp byte [esi], '='
    jne .bad
    inc esi
    call sc_eval
    jc .fail
    push eax
    mov esi, sc_name
    pop eax
    call var_set
    pop edi
    clc
    ret
.bad:
    mov esi, sc_e_assign
.fail:
    pop edi
    stc
    ret

sc_eval:
    call calc_eval
    ret

sc_do_print:
    push ebx
    xor ebx, ebx
.item:
    call skip_spaces
    mov al, [esi]
    test al, al
    jz .done
    test ebx, ebx
    jz .no_space
    push esi
    PRINTF ` `
    pop esi
.no_space:
    mov ebx, 1
    cmp al, '"'
    je .string

    push esi
    mov edi, sc_tmp
.tok:
    mov al, [esi]
    test al, al
    jz .tok_done
    cmp al, ' '
    je .tok_done
    mov [edi], al
    inc edi
    inc esi
    jmp .tok
.tok_done:
    mov byte [edi], 0
    mov [sc_print_rest], esi
    mov esi, sc_tmp
    call calc_eval
    jc .badexpr
    PRINTF `%i`, eax
    mov esi, [sc_print_rest]
    pop ebx
    jmp .item
.badexpr:
    pop esi
    mov esi, sc_tmp
    PRINTF `%s`, esi
    mov esi, [sc_print_rest]
    jmp .item
.string:
    inc esi
.schar:
    mov al, [esi]
    test al, al
    jz .done
    cmp al, '"'
    je .sclose
    push esi
    PRINTF `%c`, eax
    pop esi
    inc esi
    jmp .schar
.sclose:
    inc esi
    jmp .item
.done:
    push esi
    PRINTF `\n`
    pop esi
    pop ebx
    ret

section .bss
alignb 4
sc_print_rest resd 1
section .text

cmd_run:
    mov ecx, 1
    mov esi, u_run
    call need_args
    jc .ret
    mov esi, [argv + 4]
    call fs_find
    jc .nofile
    mov ecx, [edi + DE_SIZE]
    call fs_slot
    mov edi, SCRATCH
    push ecx
    call mem_copy
    pop ecx
    mov byte [SCRATCH + ecx], 0
    mov esi, SCRATCH
    call script_run
.ret:
    ret
.nofile:
    PRINTF `There is no file named '\x01w%s\x01n'. (Scripts are files; see \x01wman script\x01n.)\n`, esi
    ret
