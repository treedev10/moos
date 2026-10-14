IMG_MAX     equ 128
IR_SRC      equ 0
IR_STATE    equ 4
IR_W        equ 8
IR_H        equ 12
IR_PIX      equ 16
IR_SIZE     equ 32
IS_WAIT     equ 0
IS_OK       equ 1
IS_FAIL     equ 2
IMG_MAXDIM  equ 4096
IMG_BUDGET  equ 192 * 1024 * 1024

section .bss
alignb 4
imgc_tab    resb IMG_MAX * IR_SIZE
imgc_n      resd 1
imgc_bytes  resd 1
imgc_w      resd 1
imgc_h      resd 1
imgc_work   resd 1
imgc_wsize  resd 1
imgc_url    resb 4096
section .text

imgc_reset:
    pushad
    mov edx, OWN_IMAGES
    call big_free_owner
    mov dword [imgc_n], 0
    mov dword [imgc_bytes], 0
    popad
    ret

imgc_get:
    push ecx
    push edi
    xor ecx, ecx
    mov edi, imgc_tab
.l: cmp ecx, [imgc_n]
    jae .new
    cmp [edi + IR_SRC], esi
    je .found
    add edi, IR_SIZE
    inc ecx
    jmp .l
.new:
    cmp ecx, IMG_MAX
    jae .full
    inc dword [imgc_n]
    mov [edi + IR_SRC], esi
    xor eax, eax
    mov [edi + IR_STATE], eax
    mov [edi + IR_W], eax
    mov [edi + IR_H], eax
    mov [edi + IR_PIX], eax
.found:
    mov eax, edi
    pop edi
    pop ecx
    ret
.full:
    xor eax, eax
    pop edi
    pop ecx
    ret

imgc_waiting:
    push ecx
    push edi
    xor eax, eax
    xor ecx, ecx
    mov edi, imgc_tab
.l: cmp ecx, [imgc_n]
    jae .e
    cmp dword [edi + IR_STATE], IS_WAIT
    jne .n
    inc eax
.n: add edi, IR_SIZE
    inc ecx
    jmp .l
.e: pop edi
    pop ecx
    ret

imgc_tick:
    pushad
    xor ecx, ecx
    mov edi, imgc_tab
.find:
    cmp ecx, [imgc_n]
    jae .none
    cmp dword [edi + IR_STATE], IS_WAIT
    je .load
    add edi, IR_SIZE
    inc ecx
    jmp .find
.none:
    popad
    clc
    ret
.load:
    mov dword [edi + IR_STATE], IS_FAIL
    mov ebp, edi
    mov esi, [ebp + IR_SRC]
    mov edi, imgc_data_pfx
    xchg esi, edi
    call str_iprefix
    xchg esi, edi
    je .data
    mov edi, imgc_url
    call brow_resolve
    jc .done
    mov esi, imgc_url
    mov byte [url_insecure], 0
    mov byte [gui_capture], 2
    call url_fetch
    mov byte [gui_capture], 0
    jc .done
    cmp dword [http_status], 200
    jne .done
    mov esi, PKG_BUF
    mov ecx, [pkg_len]
    jmp .decode
.data:
    call imgc_data_uri
    jc .done
.decode:
    call imgc_decode
.done:
    popad
    stc
    ret

imgc_data_uri:
    push eax
    push ebx
    push edx
    push edi
.comma:
    lodsb
    test al, al
    jz .bad
    cmp al, ','
    jne .comma
    sub esi, 8
    mov edi, imgc_b64
    xchg esi, edi
    call str_iprefix
    xchg esi, edi
    jne .bad
    add esi, 8
    mov edi, PKG_BUF
    xor ebx, ebx
    xor edx, edx
.c: lodsb
    test al, al
    jz .end
    call imgc_b64val
    jc .c
    shl ebx, 6
    or bl, al
    add edx, 6
    cmp edx, 8
    jb .c
    sub edx, 8
    mov eax, ebx
    mov cl, dl
    shr eax, cl
    stosb
    mov eax, edi
    sub eax, PKG_BUF
    cmp eax, PKG_BUF_SIZE - 4
    jae .end
    jmp .c
.end:
    mov ecx, edi
    sub ecx, PKG_BUF
    mov esi, PKG_BUF
    pop edi
    pop edx
    pop ebx
    pop eax
    clc
    ret
.bad:
    pop edi
    pop edx
    pop ebx
    pop eax
    stc
    ret

imgc_b64val:
    cmp al, 'A'
    jb .notcap
    cmp al, 'Z'
    ja .notcap
    sub al, 'A'
    clc
    ret
.notcap:
    cmp al, 'a'
    jb .notsmall
    cmp al, 'z'
    ja .notsmall
    sub al, 'a' - 26
    clc
    ret
.notsmall:
    cmp al, '0'
    jb .other
    cmp al, '9'
    ja .other
    add al, 52 - '0'
    clc
    ret
.other:
    cmp al, '+'
    je .plus
    cmp al, '-'
    je .plus
    cmp al, '/'
    je .slash
    cmp al, '_'
    je .slash
    stc
    ret
.plus:
    mov al, 62
    clc
    ret
.slash:
    mov al, 63
    clc
    ret

imgc_decode:
    pushad
    cmp ecx, 8
    jb .done
    cmp dword [esi], 0x474E5089
    je .png
    cmp dword [esi], 0x38464947
    je .gif
    cmp word [esi], 0xD8FF
    je .jpeg
    jmp .done
.png:
    mov dword [imgc_info], png_info
    mov dword [imgc_dec], png_decode
    jmp .go
.gif:
    mov dword [imgc_info], gif_info
    mov dword [imgc_dec], gif_decode
    jmp .go
.jpeg:
    mov dword [imgc_info], jpeg_info
    mov dword [imgc_dec], jpeg_decode
.go:
    mov [imgc_file], esi
    mov [imgc_flen], ecx
    push imgc_wsize
    push imgc_h
    push imgc_w
    push ecx
    push esi
    call [imgc_info]
    add esp, 20
    test eax, eax
    js .done
    mov eax, [imgc_w]
    mov ecx, [imgc_h]
    test eax, eax
    jz .done
    test ecx, ecx
    jz .done
    cmp eax, IMG_MAXDIM
    ja .done
    cmp ecx, IMG_MAXDIM
    ja .done
    imul ecx, eax
    shl ecx, 2
    mov eax, [imgc_bytes]
    add eax, ecx
    add eax, [imgc_wsize]
    cmp eax, IMG_BUDGET
    ja .done
    mov edx, OWN_IMAGES
    call big_alloc
    test eax, eax
    jz .done
    mov [ebp + IR_PIX], eax
    add [imgc_bytes], ecx
    mov ecx, [imgc_wsize]
    mov dword [imgc_work], 0
    test ecx, ecx
    jz .dec
    mov edx, OWN_IMAGES
    call big_alloc
    test eax, eax
    jz .nomem
    mov [imgc_work], eax
.dec:
    push dword [imgc_wsize]
    push dword [imgc_work]
    push 0xFFFFFF
    push dword [imgc_w]
    push dword [ebp + IR_PIX]
    push dword [imgc_flen]
    push dword [imgc_file]
    call [imgc_dec]
    add esp, 28
    push eax
    mov eax, [imgc_work]
    call big_free
    pop eax
    test eax, eax
    js .nomem
    mov eax, [imgc_w]
    mov [ebp + IR_W], eax
    mov eax, [imgc_h]
    mov [ebp + IR_H], eax
    mov dword [ebp + IR_STATE], IS_OK
    jmp .done
.nomem:
    mov eax, [ebp + IR_PIX]
    call big_free
    mov dword [ebp + IR_PIX], 0
.done:
    popad
    ret

imgc_paint:
    pushad
    mov eax, [edi + IR_PIX]
    mov [gb_src], eax
    mov eax, [edi + IR_W]
    mov [gb_sw], eax
    mov eax, [edi + IR_H]
    mov [gb_sh], eax
    mov [gb_x], ecx
    mov [gb_y], edx
    mov [gb_w], esi
    mov [gb_h], ebx
    call gfx_blit
    popad
    ret

section .data
imgc_data_pfx db "data:", 0
imgc_b64      db ";base64,", 0
section .bss
alignb 4
imgc_info   resd 1
imgc_dec    resd 1
imgc_file   resd 1
imgc_flen   resd 1
section .text
