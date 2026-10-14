%include "src/module.inc"

JSON_TYPE       equ 0
JSON_START      equ 4
JSON_END        equ 8
JSON_NEXT       equ 12
JSON_TOK        equ 16
JSON_T_OBJECT   equ 1
JSON_T_ARRAY    equ 2
JSON_T_STRING   equ 3
JSON_T_PRIM     equ 4

JSON_EINVAL     equ -1
JSON_ENOTOK     equ -2

JSON_EPART      equ -3
JSON_EDEEP      equ -4
JSON_MAXDEPTH   equ 1000

JSON_F_KIND     equ 0
JSON_F_TOK      equ 4
JSON_F_KEY      equ 8

section .data

json_class:
%assign json_c 0
%rep 256
  %if json_c == ' ' || json_c == 9 || json_c == 10 || json_c == 13
    db 1
  %elif json_c == '"'
    db 2
  %elif json_c == '{'
    db 3
  %elif json_c == '['
    db 4
  %elif json_c == 't' || json_c == 'f' || json_c == 'n'
    db 5
  %elif json_c == '-' || (json_c >= '0' && json_c <= '9')
    db 6
  %else
    db 0
  %endif
  %assign json_c json_c + 1
%endrep

json_hexval:
%assign json_c 0
%rep 256
  %if json_c >= '0' && json_c <= '9'
    db json_c - '0'
  %elif json_c >= 'a' && json_c <= 'f'
    db json_c - 'a' + 10
  %elif json_c >= 'A' && json_c <= 'F'
    db json_c - 'A' + 10
  %else
    db 0xFF
  %endif
  %assign json_c json_c + 1
%endrep

json_escval:
%assign json_c 0
%rep 256
  %if json_c == '"' || json_c == '\' || json_c == '/'
    db json_c
  %elif json_c == 'b'
    db 8
  %elif json_c == 'f'
    db 12
  %elif json_c == 'n'
    db 10
  %elif json_c == 'r'
    db 13
  %elif json_c == 't'
    db 9
  %else
    db 0
  %endif
  %assign json_c json_c + 1
%endrep
json_words:     db "true", "null", "false"
align 4
json_vjump:     dd json_parse.inval, json_parse.inval, json_parse.string
                dd json_parse.object, json_parse.array, json_parse.literal
                dd json_parse.number

section .bss
alignb 16
json_dummy      resb JSON_TOK
json_stack      resb (JSON_MAXDEPTH + 1) * 16
json_base       resd 1
json_max        resd 1
json_stride     resd 1

section .text

%macro JSON_SKIPWS 1
%%look:
    cmp esi, ebx
    jae %1
    movzx eax, byte [esi]
    cmp al, ' '
    ja %%done
    je %%skip
    mov ecx, (1 << 9) | (1 << 10) | (1 << 13)
    bt ecx, eax
    jnc %%done
%%skip:
    inc esi
    jmp %%look
%%done:
%endmacro

EXPORT(json_parse)
json_parse:
    CENTER
    mov esi, ARG(0)
    mov ebx, ARG(1)
    add ebx, esi
    jc .inval
    mov [json_base], esi
    mov edi, ARG(2)
    mov eax, ARG(3)
    mov ecx, JSON_TOK
    test edi, edi
    jnz .store
    mov edi, json_dummy
    mov eax, -1
    xor ecx, ecx
.store:
    mov [json_max], eax
    mov [json_stride], ecx
    mov eax, 0x22222222
    movd xmm5, eax
    pshufd xmm5, xmm5, 0
    mov eax, 0x5C5C5C5C
    movd xmm6, eax
    pshufd xmm6, xmm6, 0
    mov eax, 0x1F1F1F1F
    movd xmm7, eax
    pshufd xmm7, xmm7, 0
    xor edx, edx
    mov ebp, json_stack
    mov dword [ebp + JSON_F_KIND], 0

.value:
    JSON_SKIPWS .part
    movzx ecx, byte [json_class + eax]
    jmp [json_vjump + ecx * 4]

.after:
    cmp dword [ebp + JSON_F_KIND], JSON_T_OBJECT
    jne .after2
    mov ecx, [ebp + JSON_F_KEY]
    mov [ecx + JSON_NEXT], edx
.after2:
    JSON_SKIPWS .afterend
    cmp al, ','
    je .comma
    cmp al, '}'
    je .closeobj
    cmp al, ']'
    je .closearr
    jmp .inval
.afterend:
    cmp dword [ebp + JSON_F_KIND], 0
    jne .part
    mov eax, edx
    CLEAVE
.comma:
    mov ecx, [ebp + JSON_F_KIND]
    inc esi
    cmp ecx, JSON_T_ARRAY
    je .value
    cmp ecx, JSON_T_OBJECT
    jne .inval
    JSON_SKIPWS .part
    cmp al, '"'
    je .key
    jmp .inval
.closeobj:
    cmp dword [ebp + JSON_F_KIND], JSON_T_OBJECT
    je .close
    jmp .inval
.closearr:
    cmp dword [ebp + JSON_F_KIND], JSON_T_ARRAY
    jne .inval
.close:
    mov ecx, [ebp + JSON_F_TOK]
    inc esi
    mov eax, esi
    sub eax, [json_base]
    mov [ecx + JSON_END], eax
    mov [ecx + JSON_NEXT], edx
    sub ebp, 16
    jmp .after

.object:
    mov ecx, JSON_T_OBJECT
    jmp .open
.array:
    mov ecx, JSON_T_ARRAY
.open:
    cmp edx, [json_max]
    jae .notok
    cmp ebp, json_stack + JSON_MAXDEPTH * 16
    jae .deep
    add ebp, 16
    mov [ebp + JSON_F_KIND], ecx
    mov [ebp + JSON_F_TOK], edi
    mov [edi + JSON_TYPE], ecx
    mov eax, esi
    sub eax, [json_base]
    mov [edi + JSON_START], eax
    add edi, [json_stride]
    inc edx
    inc esi
    push ecx
    JSON_SKIPWS .partpop
    pop ecx
    cmp ecx, JSON_T_OBJECT
    je .objfirst
    cmp al, ']'
    je .close
    jmp .value
.objfirst:
    cmp al, '}'
    je .close
    cmp al, '"'
    jne .inval
.key:
    cmp edx, [json_max]
    jae .notok
    mov [ebp + JSON_F_KEY], edi
    call .str
    jc .ret
    JSON_SKIPWS .part
    cmp al, ':'
    jne .inval
    inc esi
    jmp .value
.partpop:
    pop ecx
    jmp .part

.string:
    cmp edx, [json_max]
    jae .notok
    call .str
    jc .ret
    jmp .after

.literal:
    cmp edx, [json_max]
    jae .notok
    mov ecx, ebx
    sub ecx, esi
    cmp al, 'f'
    je .lfalse
    cmp ecx, 4
    jb .lshort
    mov eax, [esi]
    cmp eax, 'true'
    je .l4
    cmp eax, 'null'
    jne .inval
.l4:
    mov ecx, 4
    jmp .lok
.lfalse:
    cmp ecx, 5
    jb .lshort
    cmp dword [esi + 1], 'alse'
    jne .inval
    mov ecx, 5
.lok:
    mov dword [edi + JSON_TYPE], JSON_T_PRIM
    mov eax, esi
    sub eax, [json_base]
    mov [edi + JSON_START], eax
    add eax, ecx
    mov [edi + JSON_END], eax
    add esi, ecx
    inc edx
    mov [edi + JSON_NEXT], edx
    add edi, [json_stride]
    jmp .after
.lshort:
    push edi
    mov edi, json_words
    cmp al, 'n'
    jne .lsh2
    add edi, 4
.lsh2:
    cmp al, 'f'
    jne .lsh3
    add edi, 8
.lsh3:
    mov al, [esi]
    cmp al, [edi]
    jne .lshbad
    inc esi
    inc edi
    dec ecx
    jnz .lsh3
    pop edi
    jmp .part
.lshbad:
    pop edi
    jmp .inval

.number:
    cmp edx, [json_max]
    jae .notok
    mov ecx, esi
    cmp al, '-'
    jne .nint
    inc esi
    cmp esi, ebx
    jae .part
    movzx eax, byte [esi]
.nint:
    cmp al, '0'
    je .nzero
    sub eax, '1'
    cmp eax, 8
    ja .inval
.ndig:
    inc esi
    cmp esi, ebx
    jae .ndone
    movzx eax, byte [esi]
    sub eax, '0'
    cmp eax, 9
    jbe .ndig
    jmp .nfrac
.nzero:
    inc esi
    cmp esi, ebx
    jae .ndone
.nfrac:
    movzx eax, byte [esi]
    cmp al, '.'
    jne .nexp
    inc esi
    cmp esi, ebx
    jae .part
    movzx eax, byte [esi]
    sub eax, '0'
    cmp eax, 9
    ja .inval
.nfdig:
    inc esi
    cmp esi, ebx
    jae .ndone
    movzx eax, byte [esi]
    sub eax, '0'
    cmp eax, 9
    jbe .nfdig
    movzx eax, byte [esi]
.nexp:
    or al, 0x20
    cmp al, 'e'
    jne .ndone
    inc esi
    cmp esi, ebx
    jae .part
    movzx eax, byte [esi]
    cmp al, '+'
    je .nsign
    cmp al, '-'
    jne .nedig1
.nsign:
    inc esi
    cmp esi, ebx
    jae .part
    movzx eax, byte [esi]
.nedig1:
    sub eax, '0'
    cmp eax, 9
    ja .inval
.nedig:
    inc esi
    cmp esi, ebx
    jae .ndone
    movzx eax, byte [esi]
    sub eax, '0'
    cmp eax, 9
    jbe .nedig
.ndone:
    mov dword [edi + JSON_TYPE], JSON_T_PRIM
    mov eax, ecx
    sub eax, [json_base]
    mov [edi + JSON_START], eax
    mov eax, esi
    sub eax, [json_base]
    mov [edi + JSON_END], eax
    inc edx
    mov [edi + JSON_NEXT], edx
    add edi, [json_stride]
    jmp .after

.inval:
    mov eax, JSON_EINVAL
    jmp .ret
.notok:
    mov eax, JSON_ENOTOK
    jmp .ret
.part:
    mov eax, JSON_EPART
    jmp .ret
.deep:
    mov eax, JSON_EDEEP
.ret:
    CLEAVE

.str:
    mov dword [edi + JSON_TYPE], JSON_T_STRING
    inc esi
    mov eax, esi
    sub eax, [json_base]
    mov [edi + JSON_START], eax
.sblock:
    mov eax, ebx
    sub eax, esi
    cmp eax, 16
    jb .stail
    movdqu xmm0, [esi]
    movdqa xmm1, xmm0
    pcmpeqb xmm1, xmm5
    movdqa xmm2, xmm0
    pcmpeqb xmm2, xmm6
    por xmm1, xmm2
    movdqa xmm2, xmm0
    pminub xmm2, xmm7
    pcmpeqb xmm2, xmm0
    por xmm1, xmm2
    pmovmskb eax, xmm1
    test eax, eax
    jnz .shit
    add esi, 16
    jmp .sblock
.shit:
    bsf eax, eax
    add esi, eax
    movzx eax, byte [esi]
    cmp al, '"'
    je .send
    cmp al, '\'
    je .sesc
    jmp .sbad
.stail:
    cmp esi, ebx
    jae .spart
    movzx eax, byte [esi]
    cmp al, '"'
    je .send
    cmp al, '\'
    je .sesc
    cmp al, 0x20
    jb .sbad
    inc esi
    jmp .stail
.sesc:
    inc esi
    cmp esi, ebx
    jae .spart
    movzx eax, byte [esi]
    cmp al, 'u'
    je .su
    cmp byte [json_escval + eax], 0
    je .sbad
    inc esi
    jmp .sblock
.su:
    mov ecx, 4
.suhex:
    inc esi
    cmp esi, ebx
    jae .spart
    movzx eax, byte [esi]
    cmp byte [json_hexval + eax], 0xFF
    je .sbad
    dec ecx
    jnz .suhex
    inc esi
    jmp .sblock
.send:
    mov eax, esi
    sub eax, [json_base]
    mov [edi + JSON_END], eax
    inc edx
    mov [edi + JSON_NEXT], edx
    add edi, [json_stride]
    inc esi
    clc
    ret
.spart:
    mov eax, JSON_EPART
    stc
    ret
.sbad:
    mov eax, JSON_EINVAL
    stc
    ret

json_hex4:
    lea ecx, [esi + 4]
    cmp ecx, edx
    ja .bad
    push ebx
    xor eax, eax
    mov ecx, 4
.dig:
    movzx ebx, byte [esi]
    movzx ebx, byte [json_hexval + ebx]
    cmp bl, 0xFF
    je .badpop
    shl eax, 4
    or eax, ebx
    inc esi
    dec ecx
    jnz .dig
    pop ebx
    clc
    ret
.badpop:
    sub esi, 4
    add esi, ecx
    pop ebx
.bad:
    stc
    ret

json_unesc:
    cmp esi, edx
    jae .bad
    movzx eax, byte [esi]
    inc esi
    cmp al, 'u'
    je .u
    movzx eax, byte [json_escval + eax]
    test eax, eax
    jz .bad
    clc
    ret
.u:
    call json_hex4
    jc .bad
    mov ecx, eax
    and ecx, 0xFC00
    cmp ecx, 0xDC00
    je .lone
    cmp ecx, 0xD800
    jne .ok
    lea ecx, [esi + 6]
    cmp ecx, edx
    ja .lone
    cmp word [esi], '\u'
    jne .lone
    push eax
    add esi, 2
    call json_hex4
    jc .nolow
    mov ecx, eax
    and ecx, 0xFC00
    cmp ecx, 0xDC00
    jne .nolow4
    pop ecx
    sub ecx, 0xD800
    shl ecx, 10
    sub eax, 0xDC00
    add eax, ecx
    add eax, 0x10000
.ok:
    clc
    ret
.nolow4:
    sub esi, 4
.nolow:
    sub esi, 2
    pop eax
.lone:
    mov eax, 0xFFFD
    clc
    ret
.bad:
    stc
    ret

json_utf8:
    cmp eax, 0x80
    jae .two
    mov ecx, 1
    ret
.two:
    push edx
    cmp eax, 0x800
    jae .three
    mov edx, eax
    shr edx, 6
    or edx, 0xC0
    and eax, 0x3F
    or eax, 0x80
    shl eax, 8
    or eax, edx
    mov ecx, 2
    pop edx
    ret
.three:
    cmp eax, 0x10000
    jae .four
    mov edx, eax
    and edx, 0x3F
    or edx, 0x80
    shl edx, 16
    mov ecx, eax
    shr ecx, 6
    and ecx, 0x3F
    or ecx, 0x80
    shl ecx, 8
    or edx, ecx
    shr eax, 12
    or eax, 0xE0
    or eax, edx
    mov ecx, 3
    pop edx
    ret
.four:
    mov edx, eax
    and edx, 0x3F
    or edx, 0x80
    shl edx, 24
    mov ecx, eax
    shr ecx, 6
    and ecx, 0x3F
    or ecx, 0x80
    shl ecx, 16
    or edx, ecx
    mov ecx, eax
    shr ecx, 12
    and ecx, 0x3F
    or ecx, 0x80
    shl ecx, 8
    or edx, ecx
    shr eax, 18
    and eax, 7
    or eax, 0xF0
    or eax, edx
    mov ecx, 4
    pop edx
    ret

json_text:
    mov edx, esi
    add esi, [ebx + JSON_START]
    add edx, [ebx + JSON_END]
    cmp edx, esi
    ret

json_eqi:
    push esi
    push edi
    call json_text
    jc .no
    cmp byte [ebx + JSON_TYPE], JSON_T_STRING
    jne .raw
.str:
    cmp esi, edx
    jae .end
    movzx eax, byte [esi]
    cmp al, '\'
    je .esc
    cmp al, [edi]
    jne .no
    test al, al
    jz .no
    inc esi
    inc edi
    jmp .str
.esc:
    inc esi
    call json_unesc
    jc .no
    call json_utf8
.escb:
    cmp al, [edi]
    jne .no
    test al, al
    jz .no
    inc edi
    shr eax, 8
    dec ecx
    jnz .escb
    jmp .str
.raw:
    cmp esi, edx
    jae .end
    mov al, [esi]
    cmp al, [edi]
    jne .no
    test al, al
    jz .no
    inc esi
    inc edi
    jmp .raw
.end:
    cmp byte [edi], 0
    jne .no
    mov eax, 1
    pop edi
    pop esi
    ret
.no:
    xor eax, eax
    pop edi
    pop esi
    ret

EXPORT(json_eq)
json_eq:
    CENTER
    mov esi, ARG(0)
    mov ebx, ARG(1)
    mov edi, ARG(2)
    call json_eqi
    CLEAVE

EXPORT(json_key)
json_key:
    CENTER
    sub esp, 8
    mov eax, ARG(3)
    mov ecx, ARG(2)
    cmp eax, ecx
    jae .none
    mov ebx, eax
    shl ebx, 4
    add ebx, ARG(1)
    cmp byte [ebx + JSON_TYPE], JSON_T_OBJECT
    jne .none
    mov edx, [ebx + JSON_NEXT]
    cmp edx, ecx
    jbe .endok
    mov edx, ecx
.endok:
    mov [ebp - 16], edx
    mov dword [ebp - 20], -1
    lea ecx, [eax + 1]
    mov esi, ARG(0)
    mov edi, ARG(4)
.member:
    cmp ecx, [ebp - 16]
    jae .done
    mov ebx, ecx
    shl ebx, 4
    add ebx, ARG(1)
    cmp byte [ebx + JSON_TYPE], JSON_T_STRING
    jne .skip
    push ecx
    call json_eqi
    pop ecx
    test eax, eax
    jz .skip
    lea eax, [ecx + 1]
    cmp eax, [ebp - 16]
    jae .skip
    mov [ebp - 20], eax
.skip:
    mov eax, [ebx + JSON_NEXT]
    cmp eax, ecx
    jbe .done
    mov ecx, eax
    jmp .member
.done:
    mov eax, [ebp - 20]
    add esp, 8
    CLEAVE
.none:
    mov eax, -1
    add esp, 8
    CLEAVE

EXPORT(json_index)
json_index:
    CENTER
    mov eax, ARG(2)
    mov edx, ARG(1)
    cmp eax, edx
    jae .none
    mov esi, ARG(0)
    mov ebx, eax
    shl ebx, 4
    cmp byte [esi + ebx + JSON_TYPE], JSON_T_ARRAY
    jne .none
    mov edi, [esi + ebx + JSON_NEXT]
    cmp edi, edx
    jbe .endok
    mov edi, edx
.endok:
    mov ecx, ARG(3)
    inc eax
.elem:
    cmp eax, edi
    jae .none
    test ecx, ecx
    jz .found
    mov ebx, eax
    shl ebx, 4
    mov ebx, [esi + ebx + JSON_NEXT]
    cmp ebx, eax
    jbe .none
    mov eax, ebx
    dec ecx
    jmp .elem
.found:
    CLEAVE
.none:
    mov eax, -1
    CLEAVE

EXPORT(json_str)
json_str:
    CENTER
    mov esi, ARG(0)
    mov ebx, ARG(1)
    call json_text
    jc .bad
    mov edi, ARG(2)
    mov ecx, ARG(3)
    test ecx, ecx
    jz .full0
    lea ebx, [edi + ecx - 1]
    mov eax, ARG(1)
    cmp byte [eax + JSON_TYPE], JSON_T_STRING
    jne .raw
.plain:
    cmp esi, edx
    jae .done
    movzx eax, byte [esi]
    cmp al, '\'
    je .esc
    cmp edi, ebx
    jae .full
    mov [edi], al
    inc esi
    inc edi
    jmp .plain
.esc:
    inc esi
    call json_unesc
    jc .bad0
    call json_utf8
    push ecx
    add ecx, edi
    cmp ecx, ebx
    pop ecx
    ja .full
.escb:
    mov [edi], al
    inc edi
    shr eax, 8
    dec ecx
    jnz .escb
    jmp .plain
.raw:
    cmp esi, edx
    jae .done
    cmp edi, ebx
    jae .full
    mov al, [esi]
    mov [edi], al
    inc esi
    inc edi
    jmp .raw
.done:
    mov byte [edi], 0
    mov eax, edi
    sub eax, ARG(2)
    CLEAVE
.full:

    mov ecx, ARG(2)
    mov esi, edi
    xor edx, edx
.fback:
    cmp esi, ecx
    jbe .fend
    dec esi
    movzx eax, byte [esi]
    mov ebx, eax
    and ebx, 0xC0
    cmp ebx, 0x80
    jne .flead
    inc edx
    cmp edx, 3
    jbe .fback
    jmp .fend
.flead:
    cmp eax, 0xC0
    jb .fend
    mov ebx, 2
    cmp eax, 0xE0
    jb .flen
    inc ebx
    cmp eax, 0xF0
    jb .flen
    inc ebx
.flen:
    inc edx
    cmp edx, ebx
    jae .fend
    mov edi, esi
.fend:
    mov byte [edi], 0
.full0:
    mov eax, -2
    CLEAVE
.bad0:
    mov byte [edi], 0
.bad:
    mov eax, JSON_EINVAL
    CLEAVE

EXPORT(json_int)
json_int:
    CENTER
    mov esi, ARG(0)
    mov ebx, ARG(1)
    mov al, [ebx + JSON_TYPE]
    cmp al, JSON_T_STRING
    je .text
    cmp al, JSON_T_PRIM
    jne .bad
.text:
    call json_text
    jc .bad
    xor ebx, ebx
    cmp esi, edx
    jae .bad
    cmp byte [esi], '-'
    jne .digits
    inc ebx
    inc esi
.digits:
    xor eax, eax
    mov edi, esi
.dig:
    cmp esi, edx
    jae .end
    movzx ecx, byte [esi]
    sub ecx, '0'
    cmp ecx, 9
    ja .notdig
    inc esi
    cmp eax, 0x0CCCCCCD
    jae .big
    lea eax, [eax + eax * 4]
    add eax, eax
    add eax, ecx
    cmp eax, 0x80000000
    jbe .dig
.big:
    or ebx, 2
    mov eax, 0x0CCCCCCD
    jmp .dig
.notdig:
    cmp byte [esi], '.'
    jne .bad
    cmp esi, edi
    je .bad
    inc esi
    cmp esi, edx
    jae .bad
.frac:
    movzx ecx, byte [esi]
    sub ecx, '0'
    cmp ecx, 9
    ja .bad
    inc esi
    cmp esi, edx
    jb .frac
.end:
    cmp esi, edi
    je .bad
    mov edx, ARG(2)
    test ebx, 2
    jnz .huge
    test ebx, 1
    jz .pos
    neg eax
    jmp .set
.pos:
    cmp eax, 0x7FFFFFFF
    ja .huge
.set:
    mov [edx], eax
    xor eax, eax
    CLEAVE
.huge:
    mov eax, 0x7FFFFFFF
    test ebx, 1
    jz .hset
    inc eax
.hset:
    mov [edx], eax
    mov eax, -2
    CLEAVE
.bad:
    mov eax, JSON_EINVAL
    CLEAVE
