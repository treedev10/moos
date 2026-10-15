%include "src/module.inc"

IH_LUT      equ 0
IH_CNT      equ 2048
IH_SYM      equ 2048 + 64
IH_SIZE     equ 2048 + 64 + 1280

section .data
infl_lbase: dw 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31
            dw 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258
infl_lext:  db 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2
            db 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0
infl_dbase: dw 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193
            dw 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145
            dw 8193, 12289, 16385, 24577
infl_dext:  db 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6
            db 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13
infl_clord: db 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15

section .bss
alignb 16
infl_lit    resb IH_SIZE
infl_dist   resb IH_SIZE
infl_clen   resb IH_SIZE
infl_lens   resb 320
infl_crct   resd 256
infl_offs   resd 16
infl_next   resd 16
infl_pos    resd 1
infl_end    resd 1
infl_bb     resd 1
infl_bc     resd 1
infl_dst    resd 1
infl_out    resd 1
infl_lim    resd 1
infl_sp     resd 1
infl_fmt    resd 1
infl_last   resd 1
infl_ncode  resd 1

section .text

EXPORT(inflate_buf)
inflate_buf:
    CENTER
    mov [infl_sp], esp
    mov esi, ARG(0)
    mov ecx, ARG(1)
    lea eax, [esi + ecx]
    mov [infl_end], eax
    mov eax, ARG(2)
    mov [infl_dst], eax
    mov [infl_out], eax
    add eax, ARG(3)
    mov [infl_lim], eax
    xor eax, eax
    mov [infl_bb], eax
    mov [infl_bc], eax
    mov edx, ARG(5)
    cmp edx, 3
    ja .bad
    jne .fmt
    xor edx, edx
    cmp ecx, 2
    jb .fmt
    cmp word [esi], 0x8B1F
    jne .az
    mov edx, 2
    jmp .fmt
.az:
    call infl_zhdr
    jc .fmt
    mov edx, 1
.fmt:
    mov [infl_fmt], edx
    cmp edx, 1
    jne .gz
    mov eax, -3
    cmp ecx, 2
    jb .out
    call infl_zhdr
    mov eax, -1
    jc .out
    add esi, 2
    jmp .go
.gz:
    cmp edx, 2
    jne .go
    call infl_ghdr
.go:
    mov [infl_pos], esi
    call infl_blocks
    mov eax, [infl_fmt]
    cmp eax, 1
    jne .ngz
    call infl_align
    call infl_byte4
    bswap eax
    push eax
    call infl_adler
    pop edx
    cmp eax, edx
    mov eax, -4
    jne .out
    jmp .ok
.ngz:
    cmp eax, 2
    jne .ok
    call infl_align
    call infl_byte4
    push eax
    call infl_crc
    pop edx
    cmp eax, edx
    mov eax, -4
    jne .out
    call infl_byte4
    mov edx, [infl_out]
    sub edx, [infl_dst]
    cmp eax, edx
    mov eax, -4
    jne .out
.ok:
    xor eax, eax
    jmp .out
.bad:
    mov eax, -1
.out:
    mov ecx, ARG(4)
    test ecx, ecx
    jz .r
    mov edx, [infl_out]
    sub edx, [infl_dst]
    mov [ecx], edx
.r:
    CLEAVE

infl_fail:
    mov esp, [infl_sp]
    lea ebp, [esp + 12]
    jmp inflate_buf.out
infl_fail1:
    mov eax, -1
    jmp infl_fail
infl_fail2:
    mov eax, -2
    jmp infl_fail
infl_fail3:
    mov eax, -3
    jmp infl_fail

infl_zhdr:
    push eax
    push edx
    movzx eax, byte [esi]
    mov edx, eax
    and edx, 0x0F
    cmp edx, 8
    jne .no
    cmp eax, 0x7F
    ja .no
    test byte [esi + 1], 0x20
    jnz .no
    shl eax, 8
    mov al, [esi + 1]
    xor edx, edx
    push ecx
    mov ecx, 31
    div ecx
    pop ecx
    test edx, edx
    jnz .no
    clc
    jmp .r
.no:
    stc
.r:
    pop edx
    pop eax
    ret

infl_ghdr:
    mov edx, [infl_end]
    lea eax, [esi + 10]
    cmp eax, edx
    ja infl_fail3
    cmp word [esi], 0x8B1F
    jne infl_fail1
    cmp byte [esi + 2], 8
    jne infl_fail1
    movzx ecx, byte [esi + 3]
    test ecx, 0xE0
    jnz infl_fail1
    add esi, 10
    test ecx, 4
    jz .name
    lea eax, [esi + 2]
    cmp eax, edx
    ja infl_fail3
    movzx eax, word [esi]
    lea esi, [esi + eax + 2]
    cmp esi, edx
    ja infl_fail3
.name:
    test ecx, 8
    jz .comm
    call .str
.comm:
    test ecx, 16
    jz .hcrc
    call .str
.hcrc:
    test ecx, 2
    jz .r
    add esi, 2
    cmp esi, edx
    ja infl_fail3
.r:
    ret
.str:
    cmp esi, edx
    jae infl_fail3
    inc esi
    cmp byte [esi - 1], 0
    jne .str
    ret

infl_need:
    cmp [infl_bc], ecx
    jae .r
    push eax
    push ecx
.l:
    mov eax, [infl_pos]
    cmp eax, [infl_end]
    jae infl_fail3
    movzx eax, byte [eax]
    inc dword [infl_pos]
    mov ecx, [infl_bc]
    shl eax, cl
    or [infl_bb], eax
    add ecx, 8
    mov [infl_bc], ecx
    cmp ecx, [esp]
    jb .l
    pop ecx
    pop eax
.r:
    ret

infl_bits:
    call infl_need
    mov eax, [infl_bb]
    shr dword [infl_bb], cl
    sub [infl_bc], ecx
    push edx
    mov edx, 1
    shl edx, cl
    dec edx
    and eax, edx
    pop edx
    ret

infl_align:
    push ecx
    mov ecx, [infl_bc]
    and ecx, 7
    call infl_bits
    pop ecx
    ret

infl_byte4:
    push ecx
    push edx
    mov ecx, 16
    call infl_bits
    mov edx, eax
    call infl_bits
    shl eax, 16
    or eax, edx
    pop edx
    pop ecx
    ret

infl_decode:
    mov ecx, [infl_bc]
.fill:
    cmp ecx, 24
    ja .look
    mov eax, [infl_pos]
    cmp eax, [infl_end]
    jae .look
    movzx eax, byte [eax]
    inc dword [infl_pos]
    shl eax, cl
    or [infl_bb], eax
    add ecx, 8
    mov [infl_bc], ecx
    jmp .fill
.look:
    cmp ecx, 9
    jb .slow
    mov eax, [infl_bb]
    and eax, 511
    mov eax, [ebx + IH_LUT + eax * 4]
    test eax, eax
    jz .slow
    mov ecx, eax
    shr ecx, 16
    shr dword [infl_bb], cl
    sub [infl_bc], ecx
    and eax, 0xFFFF
    ret
.slow:
    push esi
    push edi
    push ebp
    xor edx, edx
    xor esi, esi
    xor edi, edi
    mov ebp, 1
.bit:
    mov ecx, 1
    call infl_bits
    or edx, eax
    mov eax, [ebx + IH_CNT + ebp * 4]
    mov ecx, edx
    sub ecx, esi
    cmp ecx, eax
    jb .found
    add edi, eax
    add esi, eax
    shl esi, 1
    shl edx, 1
    inc ebp
    cmp ebp, 15
    jbe .bit
    jmp infl_fail1
.found:
    add ecx, edi
    mov eax, [ebx + IH_SYM + ecx * 4]
    pop ebp
    pop edi
    pop esi
    ret

infl_build:
    push edi
    push ebp
    push ecx
    lea edi, [ebx + IH_CNT]
    push ecx
    mov ecx, 16
    xor eax, eax
    rep stosd
    pop ecx
    xor edx, edx
.cnt:
    cmp edx, ecx
    jae .cnd
    movzx eax, byte [esi + edx]
    inc dword [ebx + IH_CNT + eax * 4]
    inc edx
    jmp .cnt
.cnd:
    mov eax, 1
    mov edx, 1
.left:
    shl eax, 1
    sub eax, [ebx + IH_CNT + edx * 4]
    js .over
    inc edx
    cmp edx, 15
    jbe .left
    push eax
    mov dword [infl_offs + 4], 0
    mov edx, 1
.offs:
    mov eax, [infl_offs + edx * 4]
    add eax, [ebx + IH_CNT + edx * 4]
    mov [infl_offs + edx * 4 + 4], eax
    inc edx
    cmp edx, 14
    jbe .offs
    xor edx, edx
.sym:
    cmp edx, ecx
    jae .symd
    movzx eax, byte [esi + edx]
    test eax, eax
    jz .symn
    mov ebp, [infl_offs + eax * 4]
    inc dword [infl_offs + eax * 4]
    mov [ebx + IH_SYM + ebp * 4], edx
.symn:
    inc edx
    jmp .sym
.symd:
    mov edi, ebx
    push ecx
    mov ecx, 512
    xor eax, eax
    rep stosd
    xor eax, eax
    mov edx, 1
.nc:
    cmp edx, 1
    je .nc1
    add eax, [ebx + IH_CNT + edx * 4 - 4]
.nc1:
    shl eax, 1
    mov [infl_next + edx * 4], eax
    inc edx
    cmp edx, 15
    jbe .nc
    pop ecx
    xor edx, edx
.lut:
    cmp edx, ecx
    jae .done
    movzx ebp, byte [esi + edx]
    test ebp, ebp
    jz .lnext
    mov eax, [infl_next + ebp * 4]
    inc dword [infl_next + ebp * 4]
    cmp ebp, 9
    ja .lnext
    push ecx
    push edx
    xor edi, edi
    mov ecx, ebp
.rev:
    shr eax, 1
    rcl edi, 1
    dec ecx
    jnz .rev
    mov eax, ebp
    shl eax, 16
    or eax, edx
    mov ecx, ebp
    mov edx, 1
    shl edx, cl
.fl:
    mov [ebx + IH_LUT + edi * 4], eax
    add edi, edx
    cmp edi, 512
    jb .fl
    pop edx
    pop ecx
.lnext:
    inc edx
    jmp .lut
.done:
    pop eax
    jmp .r
.over:
    mov eax, -1
.r:
    pop ecx
    pop ebp
    pop edi
    ret

infl_blocks:
    push ebp
.block:
    mov ecx, 1
    call infl_bits
    mov [infl_last], eax
    mov ecx, 2
    call infl_bits
    cmp eax, 1
    je .fixed
    cmp eax, 2
    je .dyn
    test eax, eax
    jnz infl_fail1
    call infl_stored
    jmp .next
.fixed:
    call infl_fixed
    call infl_codes
    jmp .next
.dyn:
    call infl_dynamic
    call infl_codes
.next:
    cmp dword [infl_last], 0
    je .block
    pop ebp
    ret

infl_stored:
    call infl_align
    mov ecx, 16
    call infl_bits
    mov edx, eax
    call infl_bits
    not eax
    and eax, 0xFFFF
    cmp eax, edx
    jne infl_fail1
    mov edi, [infl_out]
.buf:
    test edx, edx
    jz .done
    cmp dword [infl_bc], 8
    jb .mem
    mov ecx, 8
    call infl_bits
    cmp edi, [infl_lim]
    jae .full
    mov [edi], al
    inc edi
    dec edx
    jmp .buf
.mem:
    mov esi, [infl_pos]
.cp:
    test edx, edx
    jz .md
    cmp esi, [infl_end]
    jae .eod
    cmp edi, [infl_lim]
    jae .full
    mov al, [esi]
    mov [edi], al
    inc esi
    inc edi
    dec edx
    jmp .cp
.md:
    mov [infl_pos], esi
.done:
    mov [infl_out], edi
    ret
.eod:
    mov [infl_out], edi
    jmp infl_fail3
.full:
    mov [infl_out], edi
    jmp infl_fail2

infl_fixed:
    mov edi, infl_lens
    mov ecx, 144
    mov al, 8
    rep stosb
    mov ecx, 112
    mov al, 9
    rep stosb
    mov ecx, 24
    mov al, 7
    rep stosb
    mov ecx, 8
    mov al, 8
    rep stosb
    mov ebx, infl_lit
    mov esi, infl_lens
    mov ecx, 288
    call infl_build
    mov edi, infl_lens
    mov ecx, 30
    mov al, 5
    rep stosb
    mov ebx, infl_dist
    mov ecx, 30
    call infl_build
    ret

infl_dynamic:
    mov ecx, 5
    call infl_bits
    lea edi, [eax + 257]
    call infl_bits
    lea ebp, [eax + 1]
    mov ecx, 4
    call infl_bits
    lea edx, [eax + 4]
    cmp edi, 286
    ja infl_fail1
    cmp ebp, 30
    ja infl_fail1
    push edi
    mov edi, infl_lens
    mov ecx, 19
    xor eax, eax
    rep stosb
    pop edi
    xor esi, esi
.cl:
    mov ecx, 3
    call infl_bits
    movzx ecx, byte [infl_clord + esi]
    mov [infl_lens + ecx], al
    inc esi
    cmp esi, edx
    jb .cl
    mov ebx, infl_clen
    mov esi, infl_lens
    mov ecx, 19
    call infl_build
    test eax, eax
    jnz infl_fail1
    lea eax, [edi + ebp]
    mov [infl_ncode], eax
    xor esi, esi
.len:
    cmp esi, [infl_ncode]
    jae .lend
    mov ebx, infl_clen
    call infl_decode
    cmp eax, 16
    jae .rep
    mov [infl_lens + esi], al
    inc esi
    jmp .len
.rep:
    jne .zero
    test esi, esi
    jz infl_fail1
    movzx edx, byte [infl_lens + esi - 1]
    mov ecx, 2
    call infl_bits
    add eax, 3
    jmp .fill
.zero:
    xor edx, edx
    cmp eax, 17
    jne .z18
    mov ecx, 3
    call infl_bits
    add eax, 3
    jmp .fill
.z18:
    mov ecx, 7
    call infl_bits
    add eax, 11
.fill:
    lea ecx, [esi + eax]
    cmp ecx, [infl_ncode]
    ja infl_fail1
.f:
    mov [infl_lens + esi], dl
    inc esi
    dec eax
    jnz .f
    jmp .len
.lend:
    cmp byte [infl_lens + 256], 0
    je infl_fail1
    mov ebx, infl_lit
    mov esi, infl_lens
    mov ecx, edi
    call infl_build
    test eax, eax
    js infl_fail1
    mov ebx, infl_dist
    lea esi, [infl_lens + edi]
    mov ecx, ebp
    call infl_build
    test eax, eax
    js infl_fail1
    ret

infl_codes:
    mov edi, [infl_out]
.sym:
    mov ebx, infl_lit
    call infl_decode
    cmp eax, 256
    jb .lit
    je .eob
    sub eax, 257
    cmp eax, 28
    ja .bad
    movzx esi, word [infl_lbase + eax * 2]
    movzx ecx, byte [infl_lext + eax]
    call infl_bits
    add esi, eax
    mov ebx, infl_dist
    call infl_decode
    cmp eax, 29
    ja .bad
    movzx edx, word [infl_dbase + eax * 2]
    movzx ecx, byte [infl_dext + eax]
    call infl_bits
    add edx, eax
    mov eax, edi
    sub eax, [infl_dst]
    cmp edx, eax
    ja .bad
    mov ecx, [infl_lim]
    sub ecx, edi
    cmp esi, ecx
    ja .part
    mov ecx, esi
    mov eax, esi
    mov esi, edi
    sub esi, edx
    rep movsb
    jmp .sym
.part:
    mov esi, edi
    sub esi, edx
    rep movsb
    jmp .full
.lit:
    cmp edi, [infl_lim]
    jae .full
    mov [edi], al
    inc edi
    jmp .sym
.eob:
    mov [infl_out], edi
    ret
.bad:
    mov [infl_out], edi
    jmp infl_fail1
.full:
    mov [infl_out], edi
    jmp infl_fail2

infl_adler:
    push ebx
    push esi
    push edi
    mov esi, [infl_dst]
    mov edi, [infl_out]
    mov ebx, 1
    xor ecx, ecx
.chunk:
    cmp esi, edi
    jae .done
    mov edx, edi
    sub edx, esi
    cmp edx, 5552
    jbe .c1
    mov edx, 5552
.c1:
    movzx eax, byte [esi]
    add ebx, eax
    add ecx, ebx
    inc esi
    dec edx
    jnz .c1
    mov eax, ebx
    xor edx, edx
    push ecx
    mov ecx, 65521
    div ecx
    pop ecx
    mov ebx, edx
    mov eax, ecx
    xor edx, edx
    push ebx
    mov ebx, 65521
    div ebx
    pop ebx
    mov ecx, edx
    jmp .chunk
.done:
    mov eax, ecx
    shl eax, 16
    or eax, ebx
    pop edi
    pop esi
    pop ebx
    ret

infl_crc:
    push ebx
    push esi
    push edi
    xor ecx, ecx
.t:
    mov eax, ecx
    mov edx, 8
.tb:
    shr eax, 1
    jnc .t0
    xor eax, 0xEDB88320
.t0:
    dec edx
    jnz .tb
    mov [infl_crct + ecx * 4], eax
    inc ecx
    cmp ecx, 256
    jb .t
    mov esi, [infl_dst]
    mov edi, [infl_out]
    mov eax, -1
.b:
    cmp esi, edi
    jae .done
    movzx ebx, byte [esi]
    xor bl, al
    shr eax, 8
    xor eax, [infl_crct + ebx * 4]
    inc esi
    jmp .b
.done:
    not eax
    pop edi
    pop esi
    pop ebx
    ret
