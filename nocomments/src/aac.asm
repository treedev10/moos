%include "src/module.inc"
%include "src/aac_tables.inc"

AAC_C_MAGIC     equ 0
AAC_C_SFI       equ 4
AAC_C_RATE      equ 8
AAC_C_CHCFG     equ 12
AAC_C_OUTCH     equ 16
AAC_C_PCE       equ 20
AAC_C_RND       equ 24
AAC_C_SCE       equ 32
AAC_C_CPE       equ 48
AAC_C_LFE       equ 64
AAC_C_WL        equ 80
AAC_C_WR        equ 120
AAC_C_SHAPE     equ 160
AAC_C_OVL       equ 256
AAC_SLOTS       equ 8
AAC_SCRATCH     equ 8
AAC_CTX_SIZE    equ AAC_C_OVL + 10 * 4096
AAC_MAGIC       equ 0x64434141
AAC_SEED        equ 0x2545F491

AAC_I_SEQ       equ 0
AAC_I_SHAPE     equ 4
AAC_I_MAXSFB    equ 8
AAC_I_NWIN      equ 12
AAC_I_NGRP      equ 16
AAC_I_GLEN      equ 20
AAC_I_NSWB      equ 52
AAC_I_SWB       equ 56
AAC_I_INFO      equ 60
AAC_I_PULSE     equ 60
AAC_I_NP        equ 64
AAC_I_PPOS      equ 68
AAC_I_PAMP      equ 84
AAC_I_TNS       equ 100
AAC_I_NFILT     equ 104
AAC_I_CRES      equ 136
AAC_I_TLEN      equ 168
AAC_I_TORD      equ 296
AAC_I_TDIR      equ 424
AAC_I_TCOEF     equ 552
AAC_I_BT        equ 1064
AAC_I_SF        equ 1192
AAC_I_Q         equ 1712
AAC_I_SPEC      equ 5808
AAC_I_SIZE      equ 9904

AAC_ONLY_LONG   equ 0
AAC_LONG_START  equ 1
AAC_EIGHT_SHORT equ 2
AAC_LONG_STOP   equ 3

AAC_E_CTX       equ 1
AAC_E_TOOLONG   equ 2
AAC_E_NOEND     equ 3
AAC_E_OVERRUN   equ 4
AAC_E_RATE      equ 5
AAC_E_OBJTYPE   equ 6
AAC_E_FRAMELEN  equ 7
AAC_E_CONFIG    equ 8
AAC_E_RESERVED  equ 10
AAC_E_PREDICT   equ 11
AAC_E_MAXSFB    equ 12
AAC_E_BOOK      equ 13
AAC_E_DATA      equ 14
AAC_E_SECTION   equ 15
AAC_E_SCALE     equ 16
AAC_E_PULSE     equ 17
AAC_E_TNS       equ 20
AAC_E_GAIN      equ 21
AAC_E_ESCAPE    equ 22
AAC_E_MS        equ 31

%macro AAC_GET 1
    push ecx
    mov ecx, %1
    call aac_getbits
    pop ecx
%endmacro

%macro AAC_FAIL 1
    mov eax, -(%1)
    jmp aac_abort
%endmacro

AAC_S_FRAMES    equ 0
AAC_S_ELEMENT   equ 1
AAC_S_SEQ       equ 8
AAC_S_KBD       equ 12
AAC_S_GROUPED   equ 13
AAC_S_COMMON    equ 14
AAC_S_SEPARATE  equ 15
AAC_S_MS1       equ 16
AAC_S_MS2       equ 17
AAC_S_PULSE     equ 18
AAC_S_TNS_LONG  equ 19
AAC_S_TNS_SHORT equ 20
AAC_S_TNS_COMPR equ 21
AAC_S_TNS_DOWN  equ 22
AAC_S_TNS_HIGH  equ 23
AAC_S_ESCAPE    equ 24
AAC_S_IS_BANDS  equ 25
AAC_S_IS_INV    equ 26
AAC_S_PNS       equ 27
AAC_S_PNS_PAIR  equ 28
AAC_S_MS_BANDS  equ 29
AAC_S_BIG       equ 30
AAC_S_SBR       equ 31
AAC_S_BOOK      equ 32
AAC_S_DSE_ALIGN equ 48
AAC_S_EXPLICIT  equ 49
AAC_S_PCE_CFG   equ 50
AAC_S_SBR_CFG   equ 51
AAC_S_ONEGROUP  equ 52
AAC_S_SPLIT     equ 53
AAC_S_COUNT     equ 64
%ifdef NATIVE
%macro AAC_STAT 1
    inc dword [aac_stats + (%1) * 4]
%endmacro
%macro AAC_STATR 2
    inc dword [aac_stats + (%1) * 4 + %2 * 4]
%endmacro
%else
%macro AAC_STAT 1
%endmacro
%macro AAC_STATR 2
%endmacro
%endif

%macro AAC_CHECK 1
    push eax
    mov eax, [aac_bitpos]
    cmp eax, [aac_bitend]
    pop eax
    jbe %%ok
    AAC_FAIL %1
%%ok:
%endmacro

%macro AAC_ENTER 0
    CENTER
    mov [aac_esp], esp
    stmxcsr [aac_mxcsr]
    mov dword [aac_mxnew], 0x9F80
    ldmxcsr [aac_mxnew]
%endmacro

%macro AAC_LEAVE 0
    ldmxcsr [aac_mxcsr]
    CLEAVE
%endmacro

section .bss
alignb 16
aac_buf         resb 8192 + 128
aac_ics0        resb AAC_I_SIZE
aac_ics1        resb AAC_I_SIZE
aac_mix         resd 2048
aac_cbuf        resd 1024
aac_ubuf        resd 1024
aac_tbuf        resd 2048
aac_wleft       resd 1024
aac_wright      resd 1024
aac_wright_s    resd 128
aac_lpc         resd 16
aac_lpcb        resd 16
aac_lpct        resd 16
aac_ms_used     resb 128
aac_bitpos      resd 1
aac_bitend      resd 1
aac_ctx         resd 1
aac_out         resd 1
aac_esp         resd 1
aac_mxcsr       resd 1
aac_mxnew       resd 1
aac_common      resd 1
aac_ms_present  resd 1
aac_gain        resd 1
aac_nsce        resd 1
aac_ncpe        resd 1
aac_nlfe        resd 1
aac_slot        resd 1
aac_aot         resd 1
aac_g           resd 1
aac_w0          resd 1
aac_w           resd 1
aac_wcnt        resd 1
aac_cb          resd 1
aac_tab         resd 1
aac_start       resd 1
aac_width       resd 1
aac_sbits       resd 1
aac_sesc        resd 1
aac_osf         resd 1
aac_ois         resd 1
aac_onz         resd 1
aac_nfirst      resd 1
aac_vy          resd 1
aac_vz          resd 1
aac_sy          resd 1
aac_sz          resd 1
aac_tw          resd 1
aac_tf          resd 1
aac_ttop        resd 1
aac_tbot        resd 1
aac_tmaxb       resd 1
aac_tord        resd 1
aac_fb_slot     resd 1
aac_fb_prev     resd 1
aac_fb_left     resd 1
aac_fb_w        resd 1
aac_lists       resd 1
aac_ind         resd 1
aac_tmp         resd 4
%ifdef NATIVE
EXPORT(aac_stats)
aac_stats       resd AAC_S_COUNT
%endif

section .data
align 16
aac_signs       dd 0x80000000, 0x80000000, 0x80000000, 0x80000000
aac_neg_hi      dd 0, 0, 0x80000000, 0x80000000
aac_max16       dd 32767.0, 32767.0, 32767.0, 32767.0
aac_min16       dd -32768.0, -32768.0, -32768.0, -32768.0
aac_four_thirds dq 1.3333333333333333
aac_one         dd 1.0
aac_half        dd 0.5

aac_rate_limits dd 92017, 75132, 55426, 46009, 37566, 27713, 23004, 18783
                dd 13856, 11502, 9391, 0

aac_role_l      dd 0.0, 0.70710678, 1.0, 0.0, 0.70710678, 0.0, 0.5, 1.0
aac_role_r      dd 0.0, 0.70710678, 0.0, 1.0, 0.0, 0.70710678, 0.5, 1.0

%macro AAC_SEQ 1
%%s: db %1
    times 8 - ($ - %%s) db 0
%endmacro
aac_cfg_seq:
    AAC_SEQ 0
    AAC_SEQ 'S'
    AAC_SEQ 'C'
    AAC_SEQ 'SC'
    AAC_SEQ 'SCS'
    AAC_SEQ 'SCC'
    AAC_SEQ 'SCCL'
    AAC_SEQ 'SCCCL'
    AAC_SEQ 0
    AAC_SEQ 0
    AAC_SEQ 0
    AAC_SEQ 'SCCSL'
    AAC_SEQ 'SCCCL'
    AAC_SEQ 0
    AAC_SEQ 'SCCLC'
    AAC_SEQ 0

aac_elements    dd aac_el_sce, aac_el_cpe, aac_el_cce, aac_el_lfe
                dd aac_el_dse, aac_el_pce, aac_el_fil

section .text

EXPORT(aac_ctx_size)
aac_ctx_size:
    mov eax, AAC_CTX_SIZE
    ret

EXPORT(aac_info)
aac_info:
    CENTER
    mov esi, ARG(0)
    mov eax, -AAC_E_CTX
    cmp dword [esi + AAC_C_MAGIC], AAC_MAGIC
    jne .done
    mov edi, ARG(1)
    mov eax, [esi + AAC_C_RATE]
    mov [edi], eax
    mov edi, ARG(2)
    mov eax, [esi + AAC_C_OUTCH]
    mov [edi], eax
    xor eax, eax
.done:
    CLEAVE

aac_abort:
    mov esp, [aac_esp]
    ldmxcsr [aac_mxcsr]
    CLEAVE

EXPORT(aac_init)
aac_init:
    AAC_ENTER
    mov edi, ARG(0)
    mov [aac_ctx], edi
    mov ecx, AAC_CTX_SIZE / 4
    xor eax, eax
    rep stosd
    mov esi, ARG(1)
    mov ecx, ARG(2)
    call aac_load
    mov ebx, [aac_ctx]
    call aac_get_aot
    mov [aac_aot], eax
    AAC_GET 4
    cmp eax, 15
    jne .table_rate
    AAC_GET 24
    cmp eax, 7000
    jb .bad_rate
    cmp eax, 96000
    ja .bad_rate
    mov [ebx + AAC_C_RATE], eax
    AAC_STAT AAC_S_EXPLICIT
    xor ecx, ecx
.limit:
    cmp eax, [aac_rate_limits + ecx * 4]
    jae .have_index
    inc ecx
    jmp .limit
.have_index:
    mov [ebx + AAC_C_SFI], ecx
    jmp .rate_done
.table_rate:
    cmp eax, 12
    ja .bad_rate
    mov [ebx + AAC_C_SFI], eax
    mov eax, [aac_rates + eax * 4]
    mov [ebx + AAC_C_RATE], eax
.rate_done:
    AAC_GET 4
    mov [ebx + AAC_C_CHCFG], eax
    mov eax, [aac_aot]
    cmp eax, 5
    je .sbr
    cmp eax, 29
    jne .core
.sbr:
    AAC_STAT AAC_S_SBR_CFG
    AAC_GET 4
    cmp eax, 15
    jne .sbr_rate
    AAC_GET 24
.sbr_rate:
    call aac_get_aot
.core:
    cmp eax, 2
    jne .bad_aot

    AAC_GET 1
    test eax, eax
    jnz .bad_len
    AAC_GET 1
    test eax, eax
    jz .no_core
    AAC_GET 14
.no_core:
    AAC_GET 1

    lea edi, [ebx + AAC_C_SCE]
    mov ecx, 48
    mov al, -1
    rep stosb
    cmp dword [ebx + AAC_C_CHCFG], 0
    jne .default
    AAC_STAT AAC_S_PCE_CFG
    call aac_pce_map
    jmp .mapped
.default:
    call aac_default_map
.mapped:
    AAC_CHECK AAC_E_CONFIG
    call aac_normalise
    mov dword [ebx + AAC_C_RND], AAC_SEED
    mov dword [ebx + AAC_C_MAGIC], AAC_MAGIC
    xor eax, eax
    AAC_LEAVE
.bad_rate:
    AAC_FAIL AAC_E_RATE
.bad_aot:
    AAC_FAIL AAC_E_OBJTYPE
.bad_len:
    AAC_FAIL AAC_E_FRAMELEN

aac_get_aot:
    AAC_GET 5
    cmp eax, 31
    jne .done
    AAC_GET 6
    add eax, 32
.done:
    ret

aac_set_role:
    push eax
    mov eax, [aac_role_l + eax * 4]
    mov [ebx + AAC_C_WL + edx * 4], eax
    pop eax
    push eax
    mov eax, [aac_role_r + eax * 4]
    mov [ebx + AAC_C_WR + edx * 4], eax
    pop eax
    ret

aac_default_map:
    mov eax, [ebx + AAC_C_CHCFG]
    lea esi, [aac_cfg_seq + eax * 8]
    cmp byte [esi], 0
    je .bad
    xor edx, edx
    mov dword [aac_nsce], 0
    mov dword [aac_ncpe], 0
    mov dword [aac_nlfe], 0
.next:
    lodsb
    test al, al
    jz .done
    cmp al, 'S'
    je .sce
    cmp al, 'C'
    je .cpe
    mov ecx, [aac_nlfe]
    mov [ebx + AAC_C_LFE + ecx], dl
    inc dword [aac_nlfe]
    inc edx
    jmp .next
.sce:
    mov ecx, [aac_nsce]
    mov [ebx + AAC_C_SCE + ecx], dl
    mov eax, 7
    cmp dword [ebx + AAC_C_CHCFG], 1
    je .sce_role
    mov eax, 1
    test ecx, ecx
    jz .sce_role
    mov eax, 6
.sce_role:
    call aac_set_role
    inc dword [aac_nsce]
    inc edx
    jmp .next
.cpe:
    mov ecx, [aac_ncpe]
    mov [ebx + AAC_C_CPE + ecx], dl
    mov eax, 2
    test ecx, ecx
    jz .cpe_role
    mov eax, 4
.cpe_role:
    call aac_set_role
    inc edx
    inc eax
    call aac_set_role
    inc edx
    inc dword [aac_ncpe]
    jmp .next
.done:
    mov eax, [ebx + AAC_C_CHCFG]
    mov dword [ebx + AAC_C_OUTCH], 2
    cmp eax, 2
    jne .not_stereo
    mov byte [ebx + AAC_C_SCE], 2
    mov edx, 2
    mov eax, 7
    call aac_set_role
    ret
.not_stereo:
    cmp eax, 1
    jne .ret
    mov dword [ebx + AAC_C_OUTCH], 1
    mov byte [ebx + AAC_C_CPE], 1
    mov eax, [aac_half]
    mov [ebx + AAC_C_WL + 4], eax
    mov [ebx + AAC_C_WL + 8], eax
.ret:
    ret
.bad:
    AAC_FAIL AAC_E_CONFIG

aac_pce_map:
    mov dword [ebx + AAC_C_PCE], 1
    AAC_GET 10
    AAC_GET 4
    mov [aac_tmp], eax
    AAC_GET 4
    mov [aac_tmp + 4], eax
    AAC_GET 4
    mov [aac_tmp + 8], eax
    AAC_GET 2
    mov [aac_nlfe], eax
    AAC_GET 3
    mov [aac_lists], eax
    AAC_GET 4
    mov [aac_ind], eax
    call aac_pce_mixdowns
    xor edx, edx
    xor edi, edi
    xor esi, esi
.part:
    mov ecx, [aac_tmp + esi * 4]
.element:
    test ecx, ecx
    jz .next_part
    dec ecx
    AAC_GET 1
    push eax
    AAC_GET 4
    mov [aac_tmp + 12], eax
    pop eax
    test eax, eax
    jnz .cpe
    inc edi
    cmp edx, AAC_SLOTS
    jae .element
    mov eax, [aac_tmp + 12]
    cmp byte [ebx + AAC_C_SCE + eax], 0
    jge .element
    mov [ebx + AAC_C_SCE + eax], dl
    mov eax, 1
    test esi, esi
    jz .sce_role
    mov eax, 6
.sce_role:
    call aac_set_role
    inc edx
    jmp .element
.cpe:
    add edi, 2
    lea eax, [edx + 2]
    cmp eax, AAC_SLOTS
    ja .element
    mov eax, [aac_tmp + 12]
    cmp byte [ebx + AAC_C_CPE + eax], 0
    jge .element
    mov [ebx + AAC_C_CPE + eax], dl
    mov eax, 4
    test esi, esi
    jnz .cpe_role
    mov eax, 2
.cpe_role:
    call aac_set_role
    inc edx
    inc eax
    call aac_set_role
    inc edx
    jmp .element
.next_part:
    inc esi
    cmp esi, 3
    jb .part
    mov ecx, [aac_nlfe]
.lfe:
    test ecx, ecx
    jz .lfe_done
    dec ecx
    AAC_GET 4
    inc edi
    cmp edx, AAC_SLOTS
    jae .lfe
    cmp byte [ebx + AAC_C_LFE + eax], 0
    jge .lfe
    mov [ebx + AAC_C_LFE + eax], dl
    inc edx
    jmp .lfe
.lfe_done:
    mov ecx, [aac_lists]
    shl ecx, 2
    mov eax, [aac_ind]
    lea eax, [eax + eax * 4]
    add ecx, eax
    call aac_skip
    call aac_align
    AAC_GET 8
    lea ecx, [eax * 8]
    call aac_skip
    test edi, edi
    jz .bad
    mov dword [ebx + AAC_C_OUTCH], 2
    cmp edi, 1
    jne .ret
    mov dword [ebx + AAC_C_OUTCH], 1
    mov eax, [aac_one]
    mov [ebx + AAC_C_WL], eax
.ret:
    ret
.bad:
    AAC_FAIL AAC_E_CONFIG

aac_pce_mixdowns:
    AAC_GET 1
    test eax, eax
    jz .stereo
    AAC_GET 4
.stereo:
    AAC_GET 1
    test eax, eax
    jz .matrix
    AAC_GET 4
.matrix:
    AAC_GET 1
    test eax, eax
    jz .done
    AAC_GET 3
.done:
    ret

aac_normalise:
    cmp dword [ebx + AAC_C_OUTCH], 2
    jne .done
    cmp dword [ebx + AAC_C_CHCFG], 2
    je .done
    xorps xmm0, xmm0
    xor ecx, ecx
.sum:
    addss xmm0, [ebx + AAC_C_WL + ecx * 4]
    inc ecx
    cmp ecx, AAC_SLOTS
    jb .sum
    xorps xmm1, xmm1
    comiss xmm0, xmm1
    jbe .done
    xor ecx, ecx
.scale:
    movss xmm1, [ebx + AAC_C_WL + ecx * 4]
    divss xmm1, xmm0
    movss [ebx + AAC_C_WL + ecx * 4], xmm1
    movss xmm1, [ebx + AAC_C_WR + ecx * 4]
    divss xmm1, xmm0
    movss [ebx + AAC_C_WR + ecx * 4], xmm1
    inc ecx
    cmp ecx, AAC_SLOTS
    jb .scale
.done:
    ret

EXPORT(aac_decode)
aac_decode:
    AAC_ENTER
    mov ebx, ARG(0)
    cmp dword [ebx + AAC_C_MAGIC], AAC_MAGIC
    jne .no_ctx
    mov [aac_ctx], ebx
    mov eax, ARG(3)
    mov [aac_out], eax
    mov esi, ARG(1)
    mov ecx, ARG(2)
    call aac_load
    mov edi, aac_mix
    mov ecx, 2048
    xor eax, eax
    rep stosd
    mov dword [aac_nsce], 0
    mov dword [aac_ncpe], 0
    mov dword [aac_nlfe], 0
.element:
    mov eax, [aac_bitpos]
    add eax, 3
    cmp eax, [aac_bitend]
    ja .no_end
    AAC_GET 3
    cmp eax, 7
    je .end
    AAC_STATR AAC_S_ELEMENT, eax
    call [aac_elements + eax * 4]
    AAC_CHECK AAC_E_OVERRUN
    jmp .element
.end:
    call aac_output
    AAC_STAT AAC_S_FRAMES
    mov eax, 1024
    AAC_LEAVE
.no_ctx:
    AAC_FAIL AAC_E_CTX
.no_end:
    AAC_FAIL AAC_E_NOEND

aac_load:
    cmp ecx, 8192
    ja .too_long
    mov edi, aac_buf
    mov edx, ecx
    rep movsb
    xor eax, eax
    mov ecx, 128 / 4
    rep stosd
    mov dword [aac_bitpos], 0
    shl edx, 3
    mov [aac_bitend], edx
    ret
.too_long:
    AAC_FAIL AAC_E_TOOLONG

aac_getbits:
    push edx
    mov edx, [aac_bitpos]
    add [aac_bitpos], ecx
    cmp edx, [aac_bitend]
    jae .past
    push ecx
    mov ecx, edx
    shr edx, 3
    mov eax, [aac_buf + edx]
    bswap eax
    and ecx, 7
    shl eax, cl
    pop ecx
    neg cl
    shr eax, cl
    neg cl
    pop edx
    ret
.past:
    xor eax, eax
    pop edx
    ret

aac_peek32:
    push ecx
    push edx
    mov edx, [aac_bitpos]
    cmp edx, [aac_bitend]
    jae .past
    mov ecx, edx
    shr edx, 3
    mov eax, [aac_buf + edx]
    mov edx, [aac_buf + edx + 4]
    bswap eax
    bswap edx
    and ecx, 7
    shld eax, edx, cl
    pop edx
    pop ecx
    ret
.past:
    xor eax, eax
    pop edx
    pop ecx
    ret

aac_skip:
    add [aac_bitpos], ecx
    ret

aac_align:
    add dword [aac_bitpos], 7
    and dword [aac_bitpos], ~7
    ret

aac_huff:
    push ebx
    push ecx
    push edx
    push edi
    call aac_peek32
    xor edi, edi
    mov ecx, 8
    xor ebx, ebx
.level:
    mov edx, eax
    neg cl
    shr edx, cl
    neg cl
    add edx, edi
    movzx edx, word [esi + edx * 2]
    test edx, 0x8000
    jz .leaf
    add ebx, ecx
    shl eax, cl
    mov edi, edx
    and edi, 0x7FF
    shr edx, 11
    and edx, 15
    mov ecx, edx
    jmp .level
.leaf:
    mov ecx, edx
    shr ecx, 10
    and ecx, 31
    add ebx, ecx
    add [aac_bitpos], ebx
    mov eax, edx
    and eax, 0x3FF
    pop edi
    pop edx
    pop ecx
    pop ebx
    ret

aac_huff_sf:
    push esi
    mov esi, aac_hcb
    call aac_huff
    pop esi
    ret

aac_find_slot:
    mov ebx, [aac_ctx]
    cmp dword [ebx + AAC_C_PCE], 0
    je .by_order
    mov ecx, eax
.by_order:
    cmp ecx, 16
    jae .none
    add edx, ecx
    movsx eax, byte [ebx + edx]
    test eax, eax
    js .none
    ret
.none:
    mov eax, AAC_SCRATCH
    ret

aac_el_sce:
    AAC_GET 4
    mov ecx, [aac_nsce]
    inc dword [aac_nsce]
    mov edx, AAC_C_SCE
    jmp aac_one_channel

aac_el_lfe:
    AAC_GET 4
    mov ecx, [aac_nlfe]
    inc dword [aac_nlfe]
    mov edx, AAC_C_LFE

aac_one_channel:
    call aac_find_slot
    mov [aac_slot], eax
    mov ebp, aac_ics0
    mov dword [aac_common], 0
    call aac_ics
    call aac_dequant
    call aac_tns
    mov ebx, [aac_slot]
    call aac_filterbank
    ret

aac_el_cpe:
    AAC_GET 4
    mov ecx, [aac_ncpe]
    inc dword [aac_ncpe]
    mov edx, AAC_C_CPE
    call aac_find_slot
    mov [aac_slot], eax
    AAC_GET 1
    mov [aac_common], eax
%ifdef NATIVE
    mov ecx, AAC_S_SEPARATE
    sub ecx, eax
    inc dword [aac_stats + ecx * 4]
%endif
    mov dword [aac_ms_present], 0
    test eax, eax
    jz .channels
    mov ebp, aac_ics0
    call aac_ics_info
    mov esi, aac_ics0
    mov edi, aac_ics1
    mov ecx, AAC_I_INFO / 4
    rep movsd
    AAC_GET 2
    cmp eax, 3
    je .bad_ms
    mov [aac_ms_present], eax
%ifdef NATIVE
    test eax, eax
    jz .ms_counted
    AAC_STATR AAC_S_MS1 - 1, eax
.ms_counted:
%endif
    mov edi, aac_ms_used
    mov ecx, 128 / 4
    cmp eax, 2
    sete al
    movzx eax, al
    imul eax, eax, 0x01010101
    rep stosd
    cmp dword [aac_ms_present], 1
    jne .channels
    xor edx, edx
.ms_group:
    cmp edx, [aac_ics0 + AAC_I_NGRP]
    jae .ms_done
    xor ecx, ecx
.ms_band:
    cmp ecx, [aac_ics0 + AAC_I_MAXSFB]
    jae .ms_next
    AAC_GET 1
    mov edi, edx
    shl edi, 4
    mov [aac_ms_used + edi + ecx], al
    inc ecx
    jmp .ms_band
.ms_next:
    inc edx
    jmp .ms_group
.ms_done:
    AAC_CHECK AAC_E_DATA
.channels:
    mov ebp, aac_ics0
    call aac_ics
    mov ebp, aac_ics1
    call aac_ics
    mov ebp, aac_ics0
    call aac_dequant
    mov ebp, aac_ics1
    call aac_dequant
    cmp dword [aac_common], 0
    je .no_corr
    call aac_pns_pair
.no_corr:
    call aac_stereo
    mov ebp, aac_ics0
    call aac_tns
    mov ebp, aac_ics1
    call aac_tns
    mov ebp, aac_ics0
    mov ebx, [aac_slot]
    call aac_filterbank
    mov ebp, aac_ics1
    mov ebx, [aac_slot]
    inc ebx
    call aac_filterbank
    ret
.bad_ms:
    AAC_FAIL AAC_E_MS

aac_el_cce:
    AAC_GET 4
    AAC_GET 1
    mov [aac_ind], eax
    AAC_GET 3
    lea ecx, [eax + 1]
    mov dword [aac_lists], 0
.target:
    inc dword [aac_lists]
    AAC_GET 1
    push eax
    AAC_GET 4
    pop eax
    test eax, eax
    jz .next_target
    AAC_GET 1
    mov edx, eax
    AAC_GET 1
    and eax, edx
    add [aac_lists], eax
.next_target:
    dec ecx
    jnz .target
    AAC_GET 4
    mov ebp, aac_ics0
    mov dword [aac_common], 0
    call aac_ics
    mov ecx, 1
.list:
    cmp ecx, [aac_lists]
    jae .done
    mov eax, 1
    cmp dword [aac_ind], 0
    jne .have_cge
    AAC_GET 1
.have_cge:
    test eax, eax
    jz .per_band
    call aac_huff_sf
    jmp .next_list
.per_band:
    xor edx, edx
.g:
    cmp edx, [ebp + AAC_I_NGRP]
    jae .next_list
    xor ebx, ebx
.b:
    cmp ebx, [ebp + AAC_I_MAXSFB]
    jae .next_g
    mov edi, edx
    shl edi, 4
    add edi, ebx
    cmp byte [ebp + AAC_I_BT + edi], 0
    je .next_b
    call aac_huff_sf
.next_b:
    inc ebx
    jmp .b
.next_g:
    inc edx
    jmp .g
.next_list:
    AAC_CHECK AAC_E_DATA
    inc ecx
    jmp .list
.done:
    ret

aac_el_dse:
    AAC_GET 4
    AAC_GET 1
    mov edx, eax
    AAC_GET 8
    cmp eax, 255
    jne .count
    mov ecx, eax
    AAC_GET 8
    add eax, ecx
.count:
    test edx, edx
    jz .skip
    AAC_STAT AAC_S_DSE_ALIGN
    call aac_align
.skip:
    lea ecx, [eax * 8]
    call aac_skip
    ret

aac_el_pce:
    AAC_GET 10
    xor edx, edx
    AAC_GET 4
    lea edx, [edx + eax * 4]
    add edx, eax
    AAC_GET 4
    lea edx, [edx + eax * 4]
    add edx, eax
    AAC_GET 4
    lea edx, [edx + eax * 4]
    add edx, eax
    AAC_GET 2
    lea edx, [edx + eax * 4]
    AAC_GET 3
    lea edx, [edx + eax * 4]
    AAC_GET 4
    lea edx, [edx + eax * 4]
    add edx, eax
    call aac_pce_mixdowns
    mov ecx, edx
    call aac_skip
    call aac_align
    AAC_GET 8
    lea ecx, [eax * 8]
    call aac_skip
    ret

aac_el_fil:
    AAC_GET 4
    cmp eax, 15
    jne .skip
    AAC_GET 8
    add eax, 14
.skip:
%ifdef NATIVE
    test eax, eax
    jz .counted
    push eax
    call aac_peek32
    shr eax, 28
    cmp eax, 13
    je .sbr
    cmp eax, 14
    jne .not_sbr
.sbr:
    AAC_STAT AAC_S_SBR
.not_sbr:
    pop eax
.counted:
%endif
    lea ecx, [eax * 8]
    call aac_skip
    ret

aac_ics_info:
    AAC_GET 1
    test eax, eax
    jnz .reserved
    AAC_GET 2
    mov [ebp + AAC_I_SEQ], eax
    AAC_GET 1
    mov [ebp + AAC_I_SHAPE], eax
    mov ebx, [aac_ctx]
    mov ebx, [ebx + AAC_C_SFI]
    cmp dword [ebp + AAC_I_SEQ], AAC_EIGHT_SHORT
    jne .long
    AAC_GET 4
    mov [ebp + AAC_I_MAXSFB], eax
    AAC_GET 7
    mov edx, eax
    mov dword [ebp + AAC_I_NWIN], 8
    mov dword [ebp + AAC_I_GLEN], 1
    mov ecx, 1
    mov esi, 6
.group:
    bt edx, esi
    jnc .new_group
    inc dword [ebp + AAC_I_GLEN + ecx * 4 - 4]
    jmp .group_next
.new_group:
    mov dword [ebp + AAC_I_GLEN + ecx * 4], 1
    inc ecx
.group_next:
    dec esi
    jns .group
    mov [ebp + AAC_I_NGRP], ecx
    movzx eax, byte [aac_rate_info + ebx * 4 + 1]
    mov [ebp + AAC_I_NSWB], eax
    shl ebx, 5
    add ebx, aac_swb_short
    mov [ebp + AAC_I_SWB], ebx
    jmp .check
.long:
    AAC_GET 6
    mov [ebp + AAC_I_MAXSFB], eax
    AAC_GET 1
    test eax, eax
    jnz .predict
    mov dword [ebp + AAC_I_NWIN], 1
    mov dword [ebp + AAC_I_NGRP], 1
    mov dword [ebp + AAC_I_GLEN], 1
    movzx eax, byte [aac_rate_info + ebx * 4]
    mov [ebp + AAC_I_NSWB], eax
    imul ebx, ebx, 104
    add ebx, aac_swb_long
    mov [ebp + AAC_I_SWB], ebx
.check:
    mov eax, [ebp + AAC_I_MAXSFB]
    cmp eax, [ebp + AAC_I_NSWB]
    ja .too_many
%ifdef NATIVE
    mov eax, [ebp + AAC_I_SEQ]
    AAC_STATR AAC_S_SEQ, eax
    cmp dword [ebp + AAC_I_SHAPE], 0
    je .counted_shape
    AAC_STAT AAC_S_KBD
.counted_shape:
    cmp dword [ebp + AAC_I_NWIN], 8
    jne .counted
    mov eax, [ebp + AAC_I_NGRP]
    cmp eax, 1
    je .one_group
    cmp eax, 8
    je .split
    AAC_STAT AAC_S_GROUPED
    jmp .counted
.one_group:
    AAC_STAT AAC_S_ONEGROUP
    jmp .counted
.split:
    AAC_STAT AAC_S_SPLIT
.counted:
%endif
    ret
.reserved:
    AAC_FAIL AAC_E_RESERVED
.predict:
    AAC_FAIL AAC_E_PREDICT
.too_many:
    AAC_FAIL AAC_E_MAXSFB

aac_ics:
    AAC_GET 8
    mov [aac_gain], eax
    cmp dword [aac_common], 0
    jne .info_done
    call aac_ics_info
.info_done:
    call aac_sections
    call aac_scalefactors
    call aac_side_data
    call aac_spectral
    call aac_pulses
    ret

aac_sections:
    lea edi, [ebp + AAC_I_BT]
    mov ecx, 128 / 4
    xor eax, eax
    rep stosd
    mov dword [aac_sbits], 5
    mov dword [aac_sesc], 31
    cmp dword [ebp + AAC_I_SEQ], AAC_EIGHT_SHORT
    jne .bits
    mov dword [aac_sbits], 3
    mov dword [aac_sesc], 7
.bits:
    mov dword [aac_g], 0
.group:
    mov eax, [aac_g]
    cmp eax, [ebp + AAC_I_NGRP]
    jae .done
    xor ebx, ebx
.section:
    cmp ebx, [ebp + AAC_I_MAXSFB]
    jae .next_group
    AAC_GET 4
    cmp eax, 12
    je .bad_book
    mov esi, eax
    xor edi, edi
.length:
    AAC_GET [aac_sbits]
    add edi, eax
    AAC_CHECK AAC_E_DATA
    cmp eax, [aac_sesc]
    je .length
    lea eax, [ebx + edi]
    cmp eax, [ebp + AAC_I_MAXSFB]
    ja .bad_section
    mov edx, [aac_g]
    shl edx, 4
    add edx, ebx
    lea edx, [ebp + AAC_I_BT + edx]
    mov ecx, edi
    mov eax, esi
.fill:
    test ecx, ecx
    jz .filled
    mov [edx], al
    inc edx
    dec ecx
    jmp .fill
.filled:
%ifdef NATIVE
    add [aac_stats + AAC_S_BOOK * 4 + esi * 4], edi
%endif
    add ebx, edi
    jmp .section
.next_group:
    inc dword [aac_g]
    jmp .group
.done:
    ret
.bad_book:
    AAC_FAIL AAC_E_BOOK
.bad_section:
    AAC_FAIL AAC_E_SECTION

aac_scalefactors:
    mov eax, [aac_gain]
    mov [aac_osf], eax
    mov dword [aac_ois], 0
    sub eax, 90
    mov [aac_onz], eax
    mov dword [aac_nfirst], 1
    mov dword [aac_g], 0
.group:
    mov eax, [aac_g]
    cmp eax, [ebp + AAC_I_NGRP]
    jae .done
    xor ebx, ebx
.band:
    cmp ebx, [ebp + AAC_I_MAXSFB]
    jae .next_group
    mov edx, [aac_g]
    shl edx, 4
    add edx, ebx
    movzx eax, byte [ebp + AAC_I_BT + edx]
    test eax, eax
    jz .store
    cmp eax, 13
    je .noise
    jb .spectral
    call aac_huff_sf
    sub eax, 60
    add eax, [aac_ois]
    mov [aac_ois], eax
    mov ecx, -155
    mov esi, 100
    call aac_clamp
    jmp .store
.noise:
    cmp dword [aac_nfirst], 0
    je .noise_delta
    mov dword [aac_nfirst], 0
    AAC_GET 9
    sub eax, 256
    jmp .noise_add
.noise_delta:
    call aac_huff_sf
    sub eax, 60
.noise_add:
    add eax, [aac_onz]
    mov [aac_onz], eax
    mov ecx, -100
    mov esi, 155
    call aac_clamp
    jmp .store
.spectral:
    call aac_huff_sf
    sub eax, 60
    add eax, [aac_osf]
    mov [aac_osf], eax
    cmp eax, 255
    ja .bad_scale
.store:
    mov [ebp + AAC_I_SF + edx * 4], eax
    AAC_CHECK AAC_E_DATA
    inc ebx
    jmp .band
.next_group:
    inc dword [aac_g]
    jmp .group
.done:
    ret
.bad_scale:
    AAC_FAIL AAC_E_SCALE

aac_clamp:
    cmp eax, ecx
    jge .low_ok
    mov eax, ecx
.low_ok:
    cmp eax, esi
    jle .ok
    mov eax, esi
.ok:
    ret

aac_side_data:
    AAC_GET 1
    mov [ebp + AAC_I_PULSE], eax
    test eax, eax
    jz .tns
    cmp dword [ebp + AAC_I_SEQ], AAC_EIGHT_SHORT
    je .bad_pulse
    AAC_STAT AAC_S_PULSE
    AAC_GET 2
    inc eax
    mov [ebp + AAC_I_NP], eax
    AAC_GET 6
    cmp eax, [ebp + AAC_I_NSWB]
    jae .bad_pulse
    mov esi, [ebp + AAC_I_SWB]
    movzx edx, word [esi + eax * 2]
    xor ebx, ebx
.pulse:
    AAC_GET 5
    add edx, eax
    cmp edx, 1023
    ja .bad_pulse
    mov [ebp + AAC_I_PPOS + ebx * 4], edx
    AAC_GET 4
    mov [ebp + AAC_I_PAMP + ebx * 4], eax
    inc ebx
    cmp ebx, [ebp + AAC_I_NP]
    jb .pulse
.tns:
    AAC_GET 1
    mov [ebp + AAC_I_TNS], eax
    test eax, eax
    jz .gain
    call aac_tns_data
.gain:
    AAC_GET 1
    test eax, eax
    jnz .bad_gain
    AAC_CHECK AAC_E_DATA
    ret
.bad_pulse:
    AAC_FAIL AAC_E_PULSE
.bad_gain:
    AAC_FAIL AAC_E_GAIN

aac_tns_data:
    mov ebx, 0
.window:
    cmp ebx, [ebp + AAC_I_NWIN]
    jae .done
    cmp dword [ebp + AAC_I_SEQ], AAC_EIGHT_SHORT
    je .short_nfilt
    AAC_GET 2
    jmp .have_nfilt
.short_nfilt:
    AAC_GET 1
.have_nfilt:
    mov [ebp + AAC_I_NFILT + ebx * 4], eax
    test eax, eax
    jz .next_window
    AAC_GET 1
    mov [ebp + AAC_I_CRES + ebx * 4], eax
    xor esi, esi
.filter:
    cmp esi, [ebp + AAC_I_NFILT + ebx * 4]
    jae .next_window
    lea edi, [ebx * 4 + esi]
    cmp dword [ebp + AAC_I_SEQ], AAC_EIGHT_SHORT
    je .short_len
    AAC_GET 6
    mov [ebp + AAC_I_TLEN + edi * 4], eax
    AAC_GET 5
    cmp eax, 12
    ja .bad_order
    jmp .have_order
.short_len:
    AAC_GET 4
    mov [ebp + AAC_I_TLEN + edi * 4], eax
    AAC_GET 3
.have_order:
    mov [ebp + AAC_I_TORD + edi * 4], eax
    test eax, eax
    jz .next_filter
    mov ecx, eax
%ifdef NATIVE
    cmp eax, 8
    jbe .not_high
    AAC_STAT AAC_S_TNS_HIGH
.not_high:
    cmp dword [ebp + AAC_I_SEQ], AAC_EIGHT_SHORT
    je .short_filter
    AAC_STAT AAC_S_TNS_LONG
    jmp .counted
.short_filter:
    AAC_STAT AAC_S_TNS_SHORT
.counted:
%endif
    AAC_GET 1
    mov [ebp + AAC_I_TDIR + edi * 4], eax
%ifdef NATIVE
    test eax, eax
    jz .up
    AAC_STAT AAC_S_TNS_DOWN
.up:
%endif
    AAC_GET 1
%ifdef NATIVE
    test eax, eax
    jz .uncompressed
    AAC_STAT AAC_S_TNS_COMPR
.uncompressed:
%endif
    mov edx, [ebp + AAC_I_CRES + ebx * 4]
    add edx, 3
    sub edx, eax
    shl edi, 4
    lea edi, [ebp + AAC_I_TCOEF + edi]
.coef:
    push ecx
    mov ecx, edx
    call aac_getbits
    neg cl
    add cl, 32
    shl eax, cl
    sar eax, cl
    pop ecx
    mov [edi], al
    inc edi
    dec ecx
    jnz .coef
.next_filter:
    inc esi
    jmp .filter
.next_window:
    AAC_CHECK AAC_E_DATA
    inc ebx
    jmp .window
.done:
    ret
.bad_order:
    AAC_FAIL AAC_E_TNS

aac_spectral:
    lea edi, [ebp + AAC_I_Q]
    mov ecx, 1024
    xor eax, eax
    rep stosd
    mov dword [aac_w0], 0
    mov dword [aac_g], 0
.group:
    mov eax, [aac_g]
    cmp eax, [ebp + AAC_I_NGRP]
    jae .done
    xor ebx, ebx
.band:
    cmp ebx, [ebp + AAC_I_MAXSFB]
    jae .next_group
    mov edx, [aac_g]
    shl edx, 4
    add edx, ebx
    movzx eax, byte [ebp + AAC_I_BT + edx]
    test eax, eax
    jz .next_band
    cmp eax, 11
    ja .next_band
    mov [aac_cb], eax
    mov esi, [aac_hcb_start + eax * 4]
    lea esi, [aac_hcb + esi * 2]
    mov [aac_tab], esi
    mov esi, [ebp + AAC_I_SWB]
    movzx ecx, word [esi + ebx * 2]
    movzx eax, word [esi + ebx * 2 + 2]
    sub eax, ecx
    mov [aac_start], ecx
    mov [aac_width], eax
    mov eax, [aac_w0]
    mov [aac_w], eax
    mov eax, [aac_g]
    mov eax, [ebp + AAC_I_GLEN + eax * 4]
    mov [aac_wcnt], eax
.window:
    mov edi, [aac_w]
    shl edi, 7
    add edi, [aac_start]
    lea edi, [ebp + AAC_I_Q + edi * 4]
    mov ecx, [aac_width]
    mov esi, [aac_tab]
    mov eax, [aac_cb]
    call aac_values
    inc dword [aac_w]
    dec dword [aac_wcnt]
    jnz .window
.next_band:
    inc ebx
    jmp .band
.next_group:
    mov eax, [aac_g]
    mov eax, [ebp + AAC_I_GLEN + eax * 4]
    add [aac_w0], eax
    inc dword [aac_g]
    jmp .group
.done:
    ret

%macro AAC_SIGNED 1
    test edx, edx
    jz %%store
    AAC_GET 1
    test eax, eax
    jz %%store
    neg edx
%%store:
    mov [edi + %1], edx
%endmacro

aac_values:
    push ebx
    cmp eax, 2
    jbe .signed_quads
    cmp eax, 4
    jbe .unsigned_quads
    cmp eax, 6
    jbe .signed_pairs
    cmp eax, 11
    je .escape_pairs
    jmp .unsigned_pairs

.signed_quads:
    call aac_huff
    mov edx, eax
    shr edx, 6
    dec edx
    mov [edi], edx
    mov edx, eax
    shr edx, 4
    and edx, 3
    dec edx
    mov [edi + 4], edx
    mov edx, eax
    shr edx, 2
    and edx, 3
    dec edx
    mov [edi + 8], edx
    and eax, 3
    dec eax
    mov [edi + 12], eax
    AAC_CHECK AAC_E_DATA
    add edi, 16
    sub ecx, 4
    ja .signed_quads
    pop ebx
    ret

.unsigned_quads:
    call aac_huff
    mov ebx, eax
    mov edx, ebx
    shr edx, 6
    AAC_SIGNED 0
    mov edx, ebx
    shr edx, 4
    and edx, 3
    AAC_SIGNED 4
    mov edx, ebx
    shr edx, 2
    and edx, 3
    AAC_SIGNED 8
    mov edx, ebx
    and edx, 3
    AAC_SIGNED 12
    AAC_CHECK AAC_E_DATA
    add edi, 16
    sub ecx, 4
    ja .unsigned_quads
    pop ebx
    ret

.signed_pairs:
    call aac_huff
    mov edx, eax
    shr edx, 5
    sub edx, 4
    mov [edi], edx
    and eax, 31
    sub eax, 4
    mov [edi + 4], eax
    AAC_CHECK AAC_E_DATA
    add edi, 8
    sub ecx, 2
    ja .signed_pairs
    pop ebx
    ret

.unsigned_pairs:
    call aac_huff
    mov ebx, eax
    mov edx, ebx
    shr edx, 5
    AAC_SIGNED 0
    mov edx, ebx
    and edx, 31
    AAC_SIGNED 4
    AAC_CHECK AAC_E_DATA
    add edi, 8
    sub ecx, 2
    ja .unsigned_pairs
    pop ebx
    ret

.escape_pairs:
    call aac_huff
    mov edx, eax
    shr edx, 5
    mov [aac_vy], edx
    and eax, 31
    mov [aac_vz], eax
    xor eax, eax
    cmp dword [aac_vy], 0
    je .sign_y
    AAC_GET 1
.sign_y:
    mov [aac_sy], eax
    xor eax, eax
    cmp dword [aac_vz], 0
    je .sign_z
    AAC_GET 1
.sign_z:
    mov [aac_sz], eax
    cmp dword [aac_vy], 16
    jne .esc_z
    call aac_escape
    mov [aac_vy], eax
.esc_z:
    cmp dword [aac_vz], 16
    jne .esc_done
    call aac_escape
    mov [aac_vz], eax
.esc_done:
    mov eax, [aac_vy]
    cmp dword [aac_sy], 0
    je .y_pos
    neg eax
.y_pos:
    mov [edi], eax
    mov eax, [aac_vz]
    cmp dword [aac_sz], 0
    je .z_pos
    neg eax
.z_pos:
    mov [edi + 4], eax
    AAC_CHECK AAC_E_DATA
    add edi, 8
    sub ecx, 2
    ja .escape_pairs
    pop ebx
    ret

aac_escape:
    push ecx
    mov ecx, 4
.prefix:
    AAC_GET 1
    test eax, eax
    jz .word
    inc ecx
    cmp ecx, 12
    ja .too_long
    jmp .prefix
.word:
    AAC_STAT AAC_S_ESCAPE
    call aac_getbits
    bts eax, ecx
    pop ecx
    ret
.too_long:
    AAC_FAIL AAC_E_ESCAPE

aac_pulses:
    cmp dword [ebp + AAC_I_PULSE], 0
    je .done
    xor ecx, ecx
.pulse:
    mov edx, [ebp + AAC_I_PPOS + ecx * 4]
    mov eax, [ebp + AAC_I_PAMP + ecx * 4]
    cmp dword [ebp + AAC_I_Q + edx * 4], 0
    jg .add
    neg eax
.add:
    add [ebp + AAC_I_Q + edx * 4], eax
    inc ecx
    cmp ecx, [ebp + AAC_I_NP]
    jb .pulse
.done:
    ret

aac_exp2q:
    push ecx
    mov ecx, eax
    and ecx, 3
    sar eax, 2
    add eax, 127
    shl eax, 23
    movd xmm0, eax
    mulss xmm0, [aac_pow2q + ecx * 4]
    pop ecx
    ret

aac_pow43_big:
    push eax
    fld qword [aac_four_thirds]
    fild dword [esp]
    fyl2x
    fld st0
    frndint
    fsub st1, st0
    fxch st1
    f2xm1
    fld1
    faddp st1, st0
    fscale
    fstp st1
    fstp dword [esp]
    movss xmm0, [esp]
    pop eax
    ret

aac_dequant:
    lea edi, [ebp + AAC_I_SPEC]
    mov ecx, 1024
    xor eax, eax
    rep stosd
    mov dword [aac_w0], 0
    mov dword [aac_g], 0
.group:
    mov eax, [aac_g]
    cmp eax, [ebp + AAC_I_NGRP]
    jae .done
    xor ebx, ebx
.band:
    cmp ebx, [ebp + AAC_I_MAXSFB]
    jae .next_group
    mov edx, [aac_g]
    shl edx, 4
    add edx, ebx
    movzx eax, byte [ebp + AAC_I_BT + edx]
    mov [aac_cb], eax
    test eax, eax
    jz .next_band
    cmp eax, 13
    ja .next_band
    mov eax, [ebp + AAC_I_SF + edx * 4]
    je .noise_gain
    sub eax, 100
.noise_gain:
    call aac_exp2q
    movss [aac_tmp], xmm0
    mov esi, [ebp + AAC_I_SWB]
    movzx ecx, word [esi + ebx * 2]
    movzx eax, word [esi + ebx * 2 + 2]
    sub eax, ecx
    mov [aac_start], ecx
    mov [aac_width], eax
    mov eax, [aac_w0]
    mov [aac_w], eax
    mov eax, [aac_g]
    mov eax, [ebp + AAC_I_GLEN + eax * 4]
    mov [aac_wcnt], eax
.window:
    mov eax, [aac_w]
    shl eax, 7
    add eax, [aac_start]
    lea esi, [ebp + AAC_I_Q + eax * 4]
    lea edi, [ebp + AAC_I_SPEC + eax * 4]
    mov ecx, [aac_width]
    cmp dword [aac_cb], 13
    je .noise
    movss xmm7, [aac_tmp]
.value:
    mov eax, [esi]
    cdq
    xor eax, edx
    sub eax, edx
    cmp eax, 1024
    jae .big
    movss xmm0, [aac_pow43 + eax * 4]
.scaled:
    mulss xmm0, xmm7
    movd eax, xmm0
    and edx, 0x80000000
    or eax, edx
    mov [edi], eax
    add esi, 4
    add edi, 4
    dec ecx
    jnz .value
    jmp .next_window
.big:
    AAC_STAT AAC_S_BIG
    call aac_pow43_big
    jmp .scaled
.noise:
    AAC_STAT AAC_S_PNS
    call aac_noise
.next_window:
    inc dword [aac_w]
    dec dword [aac_wcnt]
    jnz .window
.next_band:
    inc ebx
    jmp .band
.next_group:
    mov eax, [aac_g]
    mov eax, [ebp + AAC_I_GLEN + eax * 4]
    add [aac_w0], eax
    inc dword [aac_g]
    jmp .group
.done:
    ret

aac_noise:
    push ebx
    mov ebx, [aac_ctx]
    mov eax, [ebx + AAC_C_RND]
    push ecx
    push edi
    xorps xmm1, xmm1
.random:
    imul eax, eax, 1664525
    add eax, 1013904223
    cvtsi2ss xmm0, eax
    movss [edi], xmm0
    mulss xmm0, xmm0
    addss xmm1, xmm0
    add edi, 4
    dec ecx
    jnz .random
    mov [ebx + AAC_C_RND], eax
    pop edi
    pop ecx
    xorps xmm0, xmm0
    comiss xmm1, xmm0
    jbe .done
    sqrtss xmm1, xmm1
    movss xmm0, [aac_tmp]
    divss xmm0, xmm1
.scale:
    movss xmm1, [edi]
    mulss xmm1, xmm0
    movss [edi], xmm1
    add edi, 4
    dec ecx
    jnz .scale
.done:
    pop ebx
    ret

aac_band_ptrs:
    mov esi, [aac_ics1 + AAC_I_SWB]
    movzx eax, word [esi + ebx * 2]
    movzx ecx, word [esi + ebx * 2 + 2]
    sub ecx, eax
    mov esi, [aac_w]
    shl esi, 7
    add eax, esi
    lea esi, [aac_ics0 + AAC_I_SPEC + eax * 4]
    lea edi, [aac_ics1 + AAC_I_SPEC + eax * 4]
    ret

aac_stereo:
    mov dword [aac_w0], 0
    mov dword [aac_g], 0
.group:
    mov eax, [aac_g]
    cmp eax, [aac_ics1 + AAC_I_NGRP]
    jae .done
    xor ebx, ebx
.band:
    cmp ebx, [aac_ics1 + AAC_I_MAXSFB]
    jae .next_group
    mov edx, [aac_g]
    shl edx, 4
    add edx, ebx
    movzx eax, byte [aac_ics1 + AAC_I_BT + edx]
    cmp eax, 14
    jb .ms

    mov ecx, eax
    mov eax, [aac_ics1 + AAC_I_SF + edx * 4]
    neg eax
    call aac_exp2q
    movss xmm1, [aac_signs]
    cmp ecx, 15
    je .is_pos
    xorps xmm0, xmm1
.is_pos:
    cmp dword [aac_ms_present], 0
    je .is_go
    cmp byte [aac_ms_used + edx], 0
    je .is_go
    movss xmm1, [aac_signs]
    xorps xmm0, xmm1
    AAC_STAT AAC_S_IS_INV
.is_go:
    AAC_STAT AAC_S_IS_BANDS
    call .windows_start
.is_window:
    call aac_band_ptrs
.is_value:
    movss xmm1, [esi]
    mulss xmm1, xmm0
    movss [edi], xmm1
    add esi, 4
    add edi, 4
    dec ecx
    jnz .is_value
    call .windows_next
    jnz .is_window
    jmp .next_band
.ms:
    cmp dword [aac_ms_present], 0
    je .next_band
    cmp byte [aac_ms_used + edx], 0
    je .next_band
    cmp eax, 13
    jae .next_band
    cmp byte [aac_ics0 + AAC_I_BT + edx], 13
    jae .next_band
    AAC_STAT AAC_S_MS_BANDS
    call .windows_start
.ms_window:
    call aac_band_ptrs
.ms_value:
    movss xmm0, [esi]
    movss xmm1, [edi]
    movaps xmm2, xmm0
    addss xmm0, xmm1
    subss xmm2, xmm1
    movss [esi], xmm0
    movss [edi], xmm2
    add esi, 4
    add edi, 4
    dec ecx
    jnz .ms_value
    call .windows_next
    jnz .ms_window
.next_band:
    inc ebx
    jmp .band
.next_group:
    mov eax, [aac_g]
    mov eax, [aac_ics1 + AAC_I_GLEN + eax * 4]
    add [aac_w0], eax
    inc dword [aac_g]
    jmp .group
.done:
    ret

.windows_start:
    mov eax, [aac_w0]
    mov [aac_w], eax
    mov eax, [aac_g]
    mov eax, [aac_ics1 + AAC_I_GLEN + eax * 4]
    mov [aac_wcnt], eax
    ret

.windows_next:
    inc dword [aac_w]
    dec dword [aac_wcnt]
    ret

aac_pns_pair:
    cmp dword [aac_ms_present], 0
    je .done
    mov dword [aac_w0], 0
    mov dword [aac_g], 0
.group:
    mov eax, [aac_g]
    cmp eax, [aac_ics1 + AAC_I_NGRP]
    jae .done
    xor ebx, ebx
.band:
    cmp ebx, [aac_ics1 + AAC_I_MAXSFB]
    jae .next_group
    mov edx, [aac_g]
    shl edx, 4
    add edx, ebx
    cmp byte [aac_ms_used + edx], 0
    je .next_band
    cmp byte [aac_ics0 + AAC_I_BT + edx], 13
    jne .next_band
    cmp byte [aac_ics1 + AAC_I_BT + edx], 13
    jne .next_band
    mov eax, [aac_ics1 + AAC_I_SF + edx * 4]
    sub eax, [aac_ics0 + AAC_I_SF + edx * 4]
    call aac_exp2q
    AAC_STAT AAC_S_PNS_PAIR
    call aac_stereo.windows_start
.window:
    call aac_band_ptrs
.value:
    movss xmm1, [esi]
    mulss xmm1, xmm0
    movss [edi], xmm1
    add esi, 4
    add edi, 4
    dec ecx
    jnz .value
    call aac_stereo.windows_next
    jnz .window
.next_band:
    inc ebx
    jmp .band
.next_group:
    mov eax, [aac_g]
    mov eax, [aac_ics1 + AAC_I_GLEN + eax * 4]
    add [aac_w0], eax
    inc dword [aac_g]
    jmp .group
.done:
    ret

aac_tns:
    cmp dword [ebp + AAC_I_TNS], 0
    je .ret
    mov ebx, [aac_ctx]
    mov ebx, [ebx + AAC_C_SFI]
    movzx eax, byte [aac_rate_info + ebx * 4 + 2]
    cmp dword [ebp + AAC_I_SEQ], AAC_EIGHT_SHORT
    jne .maxb
    movzx eax, byte [aac_rate_info + ebx * 4 + 3]
.maxb:
    cmp eax, [ebp + AAC_I_MAXSFB]
    jbe .have_max
    mov eax, [ebp + AAC_I_MAXSFB]
.have_max:
    mov [aac_tmaxb], eax
    mov dword [aac_tw], 0
.window:
    mov eax, [aac_tw]
    cmp eax, [ebp + AAC_I_NWIN]
    jae .ret
    mov eax, [ebp + AAC_I_NSWB]
    mov [aac_tbot], eax
    mov dword [aac_tf], 0
.filter:
    mov ebx, [aac_tw]
    mov eax, [aac_tf]
    cmp eax, [ebp + AAC_I_NFILT + ebx * 4]
    jae .next_window
    lea edi, [ebx * 4 + eax]
    mov eax, [aac_tbot]
    mov [aac_ttop], eax
    sub eax, [ebp + AAC_I_TLEN + edi * 4]
    jge .bottom
    xor eax, eax
.bottom:
    mov [aac_tbot], eax
    mov eax, [ebp + AAC_I_TORD + edi * 4]
    test eax, eax
    jz .next_filter
    mov [aac_tord], eax

    mov esi, aac_tns_coef3
    cmp dword [ebp + AAC_I_CRES + ebx * 4], 0
    je .table
    mov esi, aac_tns_coef4
.table:
    push edi
    shl edi, 4
    lea edi, [ebp + AAC_I_TCOEF + edi]
    xor ecx, ecx
.coef:
    movsx edx, byte [edi + ecx]
    mov edx, [esi + edx * 4 + 32]
    mov [aac_lpct + ecx * 4], edx
    inc ecx
    cmp ecx, eax
    jb .coef
    pop edi
    call aac_tns_lpc

    mov esi, [ebp + AAC_I_SWB]
    mov eax, [aac_tbot]
    cmp eax, [aac_tmaxb]
    jbe .lo
    mov eax, [aac_tmaxb]
.lo:
    movzx ecx, word [esi + eax * 2]
    mov eax, [aac_ttop]
    cmp eax, [aac_tmaxb]
    jbe .hi
    mov eax, [aac_tmaxb]
.hi:
    movzx eax, word [esi + eax * 2]
    sub eax, ecx
    jle .next_filter
    mov edx, [aac_tw]
    shl edx, 7
    add ecx, edx
    lea esi, [ebp + AAC_I_SPEC + ecx * 4]
    mov ecx, eax
    mov edx, 4
    cmp dword [ebp + AAC_I_TDIR + edi * 4], 0
    je .run
    lea esi, [esi + eax * 4 - 4]
    mov edx, -4
.run:
    mov ebx, [aac_tord]
    call aac_tns_filter
.next_filter:
    inc dword [aac_tf]
    jmp .filter
.next_window:
    inc dword [aac_tw]
    jmp .window
.ret:
    ret

aac_tns_lpc:
    mov ecx, 1
.m:
    cmp ecx, [aac_tord]
    ja .done
    movss xmm0, [aac_lpct + ecx * 4 - 4]
    mov edx, 1
.b:
    cmp edx, ecx
    jae .copy
    mov eax, ecx
    sub eax, edx
    movss xmm1, [aac_lpc + eax * 4]
    mulss xmm1, xmm0
    addss xmm1, [aac_lpc + edx * 4]
    movss [aac_lpcb + edx * 4], xmm1
    inc edx
    jmp .b
.copy:
    mov edx, 1
.c:
    cmp edx, ecx
    jae .last
    mov eax, [aac_lpcb + edx * 4]
    mov [aac_lpc + edx * 4], eax
    inc edx
    jmp .c
.last:
    movss [aac_lpc + ecx * 4], xmm0
    inc ecx
    jmp .m
.done:
    ret

aac_tns_filter:
    xor edi, edi
.sample:
    movss xmm0, [esi]
    mov eax, edi
    cmp eax, ebx
    jbe .terms
    mov eax, ebx
.terms:
    test eax, eax
    jz .store
    push esi
    push ecx
    mov ecx, 1
.term:
    sub esi, edx
    movss xmm1, [aac_lpc + ecx * 4]
    mulss xmm1, [esi]
    subss xmm0, xmm1
    inc ecx
    cmp ecx, eax
    jbe .term
    pop ecx
    pop esi
.store:
    movss [esi], xmm0
    add esi, edx
    inc edi
    dec ecx
    jnz .sample
    ret

aac_dct4:
    push ebp
    mov eax, aac_pre_long
    mov ebx, aac_post_long
    mov edx, aac_brev_long
    cmp ecx, 1024
    je .tables
    mov eax, aac_pre_short
    mov ebx, aac_post_short
    mov edx, aac_brev_short
.tables:
    mov [aac_tmp], ebx
    mov [aac_tmp + 4], ecx
    mov ebx, eax
    lea edi, [esi + ecx * 4 - 4]
    shr ecx, 1
    mov [aac_tmp + 8], ecx
.pre:
    movss xmm0, [esi]
    movss xmm1, [edi]
    movss xmm2, [ebx]
    movss xmm3, [ebx + 4]
    movaps xmm4, xmm0
    mulss xmm4, xmm2
    movaps xmm5, xmm1
    mulss xmm5, xmm3
    addss xmm4, xmm5
    mulss xmm1, xmm2
    mulss xmm0, xmm3
    subss xmm1, xmm0
    movzx eax, word [edx]
    movss [aac_cbuf + eax * 8], xmm4
    movss [aac_cbuf + eax * 8 + 4], xmm1
    add esi, 8
    sub edi, 8
    add ebx, 8
    add edx, 2
    dec ecx
    jnz .pre
    mov ecx, [aac_tmp + 8]
    call aac_fft
    mov ebx, [aac_tmp]
    mov ecx, [aac_tmp + 8]
    mov esi, aac_cbuf
    mov edi, aac_ubuf
    mov edx, [aac_tmp + 4]
    lea edx, [aac_ubuf + edx * 4 - 4]
.post:
    movss xmm0, [esi]
    movss xmm1, [esi + 4]
    movss xmm2, [ebx]
    movss xmm3, [ebx + 4]
    movaps xmm4, xmm0
    mulss xmm4, xmm2
    movaps xmm5, xmm1
    mulss xmm5, xmm3
    addss xmm4, xmm5
    mulss xmm0, xmm3
    mulss xmm1, xmm2
    subss xmm0, xmm1
    movss [edi], xmm4
    movss [edx], xmm0
    add esi, 8
    add ebx, 8
    add edi, 8
    sub edx, 8
    dec ecx
    jnz .post
    pop ebp
    ret

aac_fft:
    mov esi, aac_cbuf
    mov edx, ecx
    shr edx, 1
    movups xmm7, [aac_neg_hi]
.two:
    movups xmm0, [esi]
    movaps xmm1, xmm0
    movlhps xmm1, xmm1
    movhlps xmm0, xmm0
    xorps xmm0, xmm7
    addps xmm1, xmm0
    movups [esi], xmm1
    add esi, 16
    dec edx
    jnz .two
    lea ebp, [aac_cbuf + ecx * 8]
    mov ebx, aac_fft_tw
    mov edx, 4
.stage:
    cmp edx, ecx
    ja .done
    lea edi, [edx * 4]
    xor eax, eax
.pair:
    movups xmm6, [ebx]
    movups xmm7, [ebx + 16]
    add ebx, 32
    lea esi, [aac_cbuf + eax * 8]
.block:
    movups xmm0, [esi]
    movups xmm1, [esi + edi]
    movaps xmm2, xmm1
    shufps xmm2, xmm2, 0xB1
    mulps xmm1, xmm6
    mulps xmm2, xmm7
    addps xmm1, xmm2
    movaps xmm3, xmm0
    addps xmm0, xmm1
    subps xmm3, xmm1
    movups [esi], xmm0
    movups [esi + edi], xmm3
    lea esi, [esi + edi * 2]
    cmp esi, ebp
    jb .block
    add eax, 2
    mov esi, edx
    shr esi, 1
    cmp eax, esi
    jb .pair
    shl edx, 1
    jmp .stage
.done:
    ret

aac_window:
    push ebp
    movups xmm7, [aac_signs]
    mov ebp, ecx
    shr ebp, 3
    mov [aac_tmp], ebp
    shl ecx, 1
    lea eax, [esi + ecx]
.q1:
    movups xmm0, [eax]
    movups xmm1, [ebx]
    mulps xmm0, xmm1
    movups xmm2, [edi]
    addps xmm2, xmm0
    movups [edi], xmm2
    add eax, 16
    add ebx, 16
    add edi, 16
    dec ebp
    jnz .q1
    lea eax, [esi + ecx * 2 - 16]
    mov ebp, [aac_tmp]
.q2:
    movups xmm0, [eax]
    shufps xmm0, xmm0, 0x1B
    xorps xmm0, xmm7
    movups xmm1, [ebx]
    mulps xmm0, xmm1
    movups xmm2, [edi]
    addps xmm2, xmm0
    movups [edi], xmm2
    sub eax, 16
    add ebx, 16
    add edi, 16
    dec ebp
    jnz .q2
    lea eax, [esi + ecx - 16]
    mov ebp, [aac_tmp]
.q3:
    movups xmm0, [eax]
    shufps xmm0, xmm0, 0x1B
    xorps xmm0, xmm7
    movups xmm1, [edx]
    mulps xmm0, xmm1
    movups xmm2, [edi]
    addps xmm2, xmm0
    movups [edi], xmm2
    sub eax, 16
    add edx, 16
    add edi, 16
    dec ebp
    jnz .q3
    mov eax, esi
    mov ebp, [aac_tmp]
.q4:
    movups xmm0, [eax]
    xorps xmm0, xmm7
    movups xmm1, [edx]
    mulps xmm0, xmm1
    movups xmm2, [edi]
    addps xmm2, xmm0
    movups [edi], xmm2
    add eax, 16
    add edx, 16
    add edi, 16
    dec ebp
    jnz .q4
    pop ebp
    ret

aac_reverse:
    lea esi, [esi + ecx * 4 - 4]
.copy:
    mov eax, [esi]
    mov [edi], eax
    sub esi, 4
    add edi, 4
    dec ecx
    jnz .copy
    ret

aac_filterbank:
    mov [aac_fb_slot], ebx
    mov eax, [aac_ctx]
    mov eax, [eax + AAC_C_SHAPE + ebx * 4]
    mov [aac_fb_prev], eax
    mov edi, aac_tbuf
    mov ecx, 2048
    xor eax, eax
    rep stosd
    cmp dword [ebp + AAC_I_SEQ], AAC_EIGHT_SHORT
    je .short

    mov eax, aac_win_sine_long
    cmp dword [aac_fb_prev], 0
    je .left
    mov eax, aac_win_kbd_long
.left:
    cmp dword [ebp + AAC_I_SEQ], AAC_LONG_STOP
    jne .have_left
    mov edi, aac_wleft
    mov ecx, 448
    xor eax, eax
    rep stosd
    mov esi, aac_win_sine_short
    cmp dword [aac_fb_prev], 0
    je .stop_slope
    mov esi, aac_win_kbd_short
.stop_slope:
    mov ecx, 128
    rep movsd
    mov ecx, 448
    mov eax, [aac_one]
    rep stosd
    mov eax, aac_wleft
.have_left:
    mov [aac_fb_left], eax
    cmp dword [ebp + AAC_I_SEQ], AAC_LONG_START
    jne .right_long
    mov edi, aac_wright
    mov ecx, 448
    mov eax, [aac_one]
    rep stosd
    mov esi, aac_win_sine_short
    cmp dword [ebp + AAC_I_SHAPE], 0
    je .start_slope
    mov esi, aac_win_kbd_short
.start_slope:
    mov ecx, 128
    call aac_reverse
    mov ecx, 448
    xor eax, eax
    rep stosd
    jmp .long_imdct
.right_long:
    mov esi, aac_win_sine_long
    cmp dword [ebp + AAC_I_SHAPE], 0
    je .fall
    mov esi, aac_win_kbd_long
.fall:
    mov edi, aac_wright
    mov ecx, 1024
    call aac_reverse
.long_imdct:
    lea esi, [ebp + AAC_I_SPEC]
    mov ecx, 1024
    call aac_dct4
    mov esi, aac_ubuf
    mov ecx, 1024
    mov ebx, [aac_fb_left]
    mov edx, aac_wright
    mov edi, aac_tbuf
    call aac_window
    jmp .combine

.short:
    mov esi, aac_win_sine_short
    cmp dword [ebp + AAC_I_SHAPE], 0
    je .short_fall
    mov esi, aac_win_kbd_short
.short_fall:
    mov edi, aac_wright_s
    mov ecx, 128
    call aac_reverse
    mov dword [aac_fb_w], 0
.short_window:
    mov eax, [aac_fb_w]
    shl eax, 9
    lea esi, [ebp + AAC_I_SPEC + eax]
    mov ecx, 128
    call aac_dct4
    mov ebx, aac_win_sine_short
    mov eax, [ebp + AAC_I_SHAPE]
    cmp dword [aac_fb_w], 0
    jne .short_shape
    mov eax, [aac_fb_prev]
.short_shape:
    test eax, eax
    jz .short_go
    mov ebx, aac_win_kbd_short
.short_go:
    mov eax, [aac_fb_w]
    shl eax, 9
    lea edi, [aac_tbuf + 448 * 4 + eax]
    mov esi, aac_ubuf
    mov ecx, 128
    mov edx, aac_wright_s
    call aac_window
    inc dword [aac_fb_w]
    cmp dword [aac_fb_w], 8
    jb .short_window

.combine:
    mov ebx, [aac_ctx]
    mov eax, [aac_fb_slot]
    mov ecx, [ebp + AAC_I_SHAPE]
    mov [ebx + AAC_C_SHAPE + eax * 4], ecx
    movss xmm6, [ebx + AAC_C_WL + eax * 4]
    shufps xmm6, xmm6, 0
    movss xmm5, [ebx + AAC_C_WR + eax * 4]
    shufps xmm5, xmm5, 0
    shl eax, 12
    lea edi, [ebx + AAC_C_OVL + eax]
    mov esi, aac_tbuf
    mov edx, aac_mix
    mov ecx, 1024 / 4
.mix:
    movups xmm0, [edi]
    movups xmm1, [esi]
    addps xmm0, xmm1
    movups xmm1, [esi + 4096]
    movups [edi], xmm1
    movaps xmm1, xmm0
    mulps xmm0, xmm6
    mulps xmm1, xmm5
    movups xmm2, [edx]
    addps xmm2, xmm0
    movups [edx], xmm2
    movups xmm2, [edx + 4096]
    addps xmm2, xmm1
    movups [edx + 4096], xmm2
    add esi, 16
    add edi, 16
    add edx, 16
    dec ecx
    jnz .mix
    ret

aac_output:
    mov ebx, [aac_ctx]
    mov edi, [aac_out]
    mov esi, aac_mix
    movups xmm6, [aac_max16]
    movups xmm7, [aac_min16]
    mov ecx, 1024 / 8
    cmp dword [ebx + AAC_C_OUTCH], 2
    je .stereo
.mono:
    movups xmm0, [esi]
    movups xmm1, [esi + 16]
    maxps xmm0, xmm7
    maxps xmm1, xmm7
    minps xmm0, xmm6
    minps xmm1, xmm6
    cvtps2dq xmm0, xmm0
    cvtps2dq xmm1, xmm1
    packssdw xmm0, xmm1
    movdqu [edi], xmm0
    add esi, 32
    add edi, 16
    dec ecx
    jnz .mono
    ret
.stereo:
    movups xmm0, [esi]
    movups xmm1, [esi + 16]
    movups xmm2, [esi + 4096]
    movups xmm3, [esi + 4096 + 16]
    maxps xmm0, xmm7
    maxps xmm1, xmm7
    maxps xmm2, xmm7
    maxps xmm3, xmm7
    minps xmm0, xmm6
    minps xmm1, xmm6
    minps xmm2, xmm6
    minps xmm3, xmm6
    cvtps2dq xmm0, xmm0
    cvtps2dq xmm1, xmm1
    cvtps2dq xmm2, xmm2
    cvtps2dq xmm3, xmm3
    packssdw xmm0, xmm1
    packssdw xmm2, xmm3
    movdqa xmm1, xmm0
    punpcklwd xmm0, xmm2
    punpckhwd xmm1, xmm2
    movdqu [edi], xmm0
    movdqu [edi + 16], xmm1
    add esi, 32
    add edi, 32
    dec ecx
    jnz .stereo
    ret

section .text
