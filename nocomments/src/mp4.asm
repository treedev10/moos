%include "src/module.inc"

MP4S_OFF        equ 0
MP4S_SIZE       equ 4
MP4S_PTS        equ 8
MP4S_FLAGS      equ 12
MP4S_LEN        equ 16
MP4S_F_SYNC     equ 1
MP4S_F_PRE      equ 2

MP4T_OK         equ 0
MP4T_CODEC      equ 4
MP4T_P1         equ 8
MP4T_P2         equ 12
MP4T_SCALE      equ 16
MP4T_DUR        equ 20
MP4T_CFG        equ 24
MP4T_CFGLEN     equ 28
MP4T_P3         equ 32
MP4T_P4         equ 36
MP4T_P5         equ 40
MP4T_P6         equ 44
MP4T_P7         equ 48
MP4T_N          equ 52
MP4T_SAMP       equ 56
MP4T_EDIT       equ 60
MP4T_ID         equ 64
MP4T_MDUR       equ 68
MP4T_NSYNC      equ 72
MP4T_RES        equ 76
MP4T_LEN        equ 80

MP4I_V          equ 0
MP4I_A          equ MP4T_LEN
MP4I_V_OK       equ MP4I_V + MP4T_OK
MP4I_V_CODEC    equ MP4I_V + MP4T_CODEC
MP4I_V_W        equ MP4I_V + MP4T_P1
MP4I_V_H        equ MP4I_V + MP4T_P2
MP4I_V_SCALE    equ MP4I_V + MP4T_SCALE
MP4I_V_DUR      equ MP4I_V + MP4T_DUR
MP4I_V_AVCC     equ MP4I_V + MP4T_CFG
MP4I_V_AVCCLEN  equ MP4I_V + MP4T_CFGLEN
MP4I_V_NALSZ    equ MP4I_V + MP4T_P3
MP4I_V_SPS      equ MP4I_V + MP4T_P4
MP4I_V_SPSLEN   equ MP4I_V + MP4T_P5
MP4I_V_PPS      equ MP4I_V + MP4T_P6
MP4I_V_PPSLEN   equ MP4I_V + MP4T_P7
MP4I_V_N        equ MP4I_V + MP4T_N
MP4I_V_SAMP     equ MP4I_V + MP4T_SAMP
MP4I_V_EDIT     equ MP4I_V + MP4T_EDIT
MP4I_V_ID       equ MP4I_V + MP4T_ID
MP4I_V_MDUR     equ MP4I_V + MP4T_MDUR
MP4I_V_NSYNC    equ MP4I_V + MP4T_NSYNC
MP4I_A_OK       equ MP4I_A + MP4T_OK
MP4I_A_CODEC    equ MP4I_A + MP4T_CODEC
MP4I_A_RATE     equ MP4I_A + MP4T_P1
MP4I_A_CH       equ MP4I_A + MP4T_P2
MP4I_A_SCALE    equ MP4I_A + MP4T_SCALE
MP4I_A_DUR      equ MP4I_A + MP4T_DUR
MP4I_A_ASC      equ MP4I_A + MP4T_CFG
MP4I_A_ASCLEN   equ MP4I_A + MP4T_CFGLEN
MP4I_A_OTI      equ MP4I_A + MP4T_P3
MP4I_A_AOT      equ MP4I_A + MP4T_P4
MP4I_A_N        equ MP4I_A + MP4T_N
MP4I_A_SAMP     equ MP4I_A + MP4T_SAMP
MP4I_A_EDIT     equ MP4I_A + MP4T_EDIT
MP4I_A_ID       equ MP4I_A + MP4T_ID
MP4I_A_MDUR     equ MP4I_A + MP4T_MDUR
MP4I_A_NSYNC    equ MP4I_A + MP4T_NSYNC
MP4I_M_SCALE    equ 2 * MP4T_LEN + 0
MP4I_M_DUR      equ 2 * MP4T_LEN + 4
MP4I_NEED       equ 2 * MP4T_LEN + 8
MP4I_NTRAK      equ 2 * MP4T_LEN + 12
MP4I_SIZE       equ 2 * MP4T_LEN + 16

MP4_OK          equ 0
MP4_EBAD        equ -1
MP4_EWORK       equ -2
MP4_EFRAG       equ -3
MP4_ECODEC      equ -4

MP4TK_USE       equ MP4T_LEN + 0
MP4TK_HDLR      equ MP4T_LEN + 4
MP4TK_CODECOK   equ MP4T_LEN + 8
MP4TK_CFGSRC    equ MP4T_LEN + 12
MP4TK_SPSOFF    equ MP4T_LEN + 16
MP4TK_PPSOFF    equ MP4T_LEN + 20
MP4TK_STTS      equ MP4T_LEN + 24
MP4TK_STTSN     equ MP4T_LEN + 28
MP4TK_CTTS      equ MP4T_LEN + 32
MP4TK_CTTSN     equ MP4T_LEN + 36
MP4TK_STSS      equ MP4T_LEN + 40
MP4TK_STSSN     equ MP4T_LEN + 44
MP4TK_STSC      equ MP4T_LEN + 48
MP4TK_STSCN     equ MP4T_LEN + 52
MP4TK_SZ        equ MP4T_LEN + 56
MP4TK_SZKIND    equ MP4T_LEN + 60
MP4TK_SZCONST   equ MP4T_LEN + 64
MP4TK_CO        equ MP4T_LEN + 68
MP4TK_CON       equ MP4T_LEN + 72
MP4TK_CO64      equ MP4T_LEN + 76
MP4TK_LEN       equ MP4T_LEN + 80

MP4SL_TKHD      equ 0
MP4SL_ELST      equ 1
MP4SL_MDHD      equ 2
MP4SL_HDLR      equ 3
MP4SL_STSD      equ 4
MP4SL_STTS      equ 5
MP4SL_CTTS      equ 6
MP4SL_STSS      equ 7
MP4SL_STSC      equ 8
MP4SL_STSZ      equ 9
MP4SL_STZ2      equ 10
MP4SL_STCO      equ 11
MP4SL_CO64      equ 12
MP4SL_COUNT     equ 13
MP4_MAXDEPTH    equ 6

section .data
align 4

mp4_boxtab:
    dd 'edts', -1, 'mdia', -1, 'minf', -1, 'stbl', -1
    dd 'tkhd', MP4SL_TKHD, 'elst', MP4SL_ELST, 'mdhd', MP4SL_MDHD, 'hdlr', MP4SL_HDLR
    dd 'stsd', MP4SL_STSD, 'stts', MP4SL_STTS, 'ctts', MP4SL_CTTS, 'stss', MP4SL_STSS
    dd 'stsc', MP4SL_STSC, 'stsz', MP4SL_STSZ, 'stz2', MP4SL_STZ2, 'stco', MP4SL_STCO
    dd 'co64', MP4SL_CO64, 0, 0

mp4_firsttab:
    dd 'ftyp', 'styp', 'moov', 'mdat', 'free', 'skip', 'wide', 'pdin', 'uuid'
    dd 'sidx', 'ssix', 'junk', 'pnot', 'meta', 'meco', 'udta', 'moof', 'mfra'
    dd 'prft', 'emsg', 0

mp4_aacrate:
    dd 96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050
    dd 16000, 12000, 11025, 8000, 7350, 0, 0, 0

mp4_aacch:
    db 0, 1, 2, 3, 4, 5, 6, 8, 0, 0, 0, 7, 8, 24, 8, 0

section .bss
alignb 4
mp4_bss:
mp4_slot_ptr    resd MP4SL_COUNT
mp4_slot_len    resd MP4SL_COUNT
mp4_ct          resb MP4TK_LEN
mp4_vt          resb MP4TK_LEN
mp4_at          resb MP4TK_LEN
mp4_mscale      resd 1
mp4_mdur        resd 1
mp4_frag        resd 1
mp4_ntrak       resd 1
mp4_depth       resd 1
mp4_mbeg        resd 1
mp4_mend        resd 1
mp4_bitpos      resd 1
mp4_ascbuf      resb 16
mp4_send        resd 1
mp4_scend       resd 1
mp4_trem        resd 1
mp4_tend        resd 1
mp4_cp          resd 1
mp4_crem        resd 1
mp4_cend        resd 1
mp4_dtslo       resd 1
mp4_dtshi       resd 1
mp4_tmp         resd 1
mp4_wp          resd 1
mp4_info        resd 1
mp4_work        resd 1
mp4_wlen        resd 1
mp4_bss_end:

section .text

mp4_box_next:
    mov ecx, edx
    sub ecx, esi
    jb .none
    cmp ecx, 8
    jb .none
    mov ebx, [esi]
    bswap ebx
    cmp ebx, 1
    je .large
    test ebx, ebx
    jz .tail
    cmp ebx, 8
    jb .none
    cmp ebx, ecx
    ja .none
    lea ecx, [esi + ebx]
    lea ebx, [esi + 8]
    mov eax, [esi + 4]
    clc
    ret
.tail:
    mov ecx, edx
    lea ebx, [esi + 8]
    mov eax, [esi + 4]
    clc
    ret
.large:
    cmp ecx, 16
    jb .none
    cmp dword [esi + 8], 0
    jne .none
    mov ebx, [esi + 12]
    bswap ebx
    cmp ebx, 16
    jb .none
    cmp ebx, ecx
    ja .none
    lea ecx, [esi + ebx]
    lea ebx, [esi + 16]
    mov eax, [esi + 4]
    clc
    ret
.none:
    stc
    ret

EXPORT(mp4_find_moov)
mp4_find_moov:
    CENTER
    mov esi, ARG(0)
    xor edi, edi
.box:
    mov ecx, ARG(1)
    sub ecx, edi
    jb .more
    cmp ecx, 8
    jb .more
    mov eax, [esi + edi + 4]
    mov edx, 4
.chr:
    cmp al, 0x20
    jb .bad
    cmp al, 0x7E
    ja .bad
    ror eax, 8
    dec edx
    jnz .chr
    test edi, edi
    jnz .known
    mov ebx, mp4_firsttab
.first:
    mov edx, [ebx]
    test edx, edx
    jz .bad
    add ebx, 4
    cmp eax, edx
    jne .first
.known:
    mov ebx, [esi + edi]
    bswap ebx
    mov edx, 8
    cmp ebx, 1
    jne .small
    cmp ecx, 16
    jb .more
    cmp dword [esi + edi + 8], 0
    jne .bad
    mov ebx, [esi + edi + 12]
    bswap ebx
    mov edx, 16
    jmp .sized
.small:
    test ebx, ebx
    jnz .sized
    cmp eax, 'moov'
    jne .bad
    mov ebx, ecx
    jmp .found
.sized:
    cmp ebx, edx
    jb .bad
    cmp eax, 'moov'
    je .found
    add edi, ebx
    jc .bad
    jmp .box
.found:
    mov eax, ARG(2)
    mov [eax], edi
    mov eax, ARG(3)
    mov [eax], ebx
    xor eax, eax
    CLEAVE
.more:
    mov eax, ARG(2)
    mov [eax], edi
    mov eax, ARG(3)
    mov dword [eax], 0
    mov eax, 1
    CLEAVE
.bad:
    mov eax, -1
    CLEAVE

mp4_walk:
    push esi
    push edi
    push ebp
    inc dword [mp4_depth]
    cmp dword [mp4_depth], MP4_MAXDEPTH
    ja .done
.next:
    call mp4_box_next
    jc .done
    mov ebp, ecx
    mov edi, mp4_boxtab
.look:
    mov ecx, [edi]
    test ecx, ecx
    jz .skip
    cmp eax, ecx
    je .found
    add edi, 8
    jmp .look
.found:
    mov ecx, [edi + 4]
    cmp ecx, -1
    je .container
    cmp dword [mp4_slot_ptr + ecx * 4], 0
    jne .skip
    mov [mp4_slot_ptr + ecx * 4], ebx
    mov eax, ebp
    sub eax, ebx
    mov [mp4_slot_len + ecx * 4], eax
    jmp .skip
.container:
    push edx
    mov esi, ebx
    mov edx, ebp
    call mp4_walk
    pop edx
.skip:
    mov esi, ebp
    jmp .next
.done:
    dec dword [mp4_depth]
    pop ebp
    pop edi
    pop esi
    ret

mp4_slot:
    mov ebx, [mp4_slot_ptr + ecx * 4]
    mov ecx, [mp4_slot_len + ecx * 4]
    test ebx, ebx
    ret

mp4_rescale:
    test ebx, ebx
    jz .zero
    mul ecx
    push ebx
    shr ebx, 1
    add eax, ebx
    adc edx, 0
    pop ebx
    cmp edx, ebx
    jae .max
    div ebx
    ret
.max:
    mov eax, -1
    ret
.zero:
    xor eax, eax
    ret

mp4_rd64:
    mov eax, [ebx + ecx]
    test eax, eax
    jnz .max
    mov eax, [ebx + ecx + 4]
    bswap eax
    ret
.max:
    mov eax, -1
    ret

mp4_track:
    mov edi, ebp
    mov ecx, MP4TK_LEN / 4
    xor eax, eax
    rep stosd

    mov ecx, MP4SL_TKHD
    call mp4_slot
    jz .hdlr
    cmp ecx, 16
    jb .hdlr
    mov edx, 12
    cmp byte [ebx], 1
    jne .tk0
    mov edx, 20
    cmp ecx, 24
    jb .hdlr
.tk0:
    mov eax, [ebx + edx]
    bswap eax
    mov [ebp + MP4T_ID], eax
.hdlr:
    mov ecx, MP4SL_HDLR
    call mp4_slot
    jz .mdhd
    cmp ecx, 12
    jb .mdhd
    mov eax, [ebx + 8]
    mov [ebp + MP4TK_HDLR], eax
.mdhd:
    mov ecx, MP4SL_MDHD
    call mp4_slot
    jz .stsd
    cmp ecx, 20
    jb .stsd
    cmp byte [ebx], 1
    je .md1
    mov eax, [ebx + 12]
    bswap eax
    mov [ebp + MP4T_SCALE], eax
    mov eax, [ebx + 16]
    bswap eax
    mov [ebp + MP4T_MDUR], eax
    jmp .stsd
.md1:
    cmp ecx, 32
    jb .stsd
    mov eax, [ebx + 20]
    bswap eax
    mov [ebp + MP4T_SCALE], eax
    mov ecx, 24
    call mp4_rd64
    mov [ebp + MP4T_MDUR], eax
.stsd:
    mov ecx, MP4SL_STSD
    call mp4_slot
    jz .tables
    cmp ecx, 16
    jb .tables
    lea esi, [ebx + 8]
    lea edx, [ebx + ecx]
    call mp4_box_next
    jc .tables
    mov [ebp + MP4T_CODEC], eax
    cmp dword [ebp + MP4TK_HDLR], 'vide'
    jne .notvid
    call mp4_vis_entry
    jmp .tables
.notvid:
    cmp dword [ebp + MP4TK_HDLR], 'soun'
    jne .tables
    call mp4_snd_entry
.tables:
    call mp4_tables
    call mp4_edit

    cmp dword [ebp + MP4TK_CODECOK], 0
    je .ret
    cmp dword [ebp + MP4T_SCALE], 0
    je .ret
    cmp dword [ebp + MP4T_N], 0
    je .ret
    cmp dword [ebp + MP4TK_STTSN], 0
    je .ret
    cmp dword [ebp + MP4TK_STSCN], 0
    je .ret
    cmp dword [ebp + MP4TK_CON], 0
    je .ret
    cmp dword [ebp + MP4TK_SZKIND], 0
    je .ret
    mov dword [ebp + MP4TK_USE], 1
.ret:
    ret

mp4_vis_entry:
    mov eax, ecx
    sub eax, ebx
    cmp eax, 78
    jb .ret
    movzx eax, word [ebx + 24]
    xchg al, ah
    mov [ebp + MP4T_P1], eax
    movzx eax, word [ebx + 26]
    xchg al, ah
    mov [ebp + MP4T_P2], eax
    lea esi, [ebx + 78]
    mov edx, ecx
.next:
    call mp4_box_next
    jc .ret
    cmp eax, 'avcC'
    je .avcc
    mov esi, ecx
    jmp .next
.avcc:
    mov [ebp + MP4TK_CFGSRC], ebx
    sub ecx, ebx
    mov [ebp + MP4T_CFGLEN], ecx
    mov eax, [ebp + MP4T_CODEC]
    cmp eax, 'avc1'
    je .h264
    cmp eax, 'avc3'
    jne .ret
.h264:

    cmp ecx, 6
    jb .ret
    cmp byte [ebx], 1
    jne .ret
    movzx eax, byte [ebx + 4]
    and eax, 3
    inc eax
    mov [ebp + MP4T_P3], eax
    movzx edi, byte [ebx + 5]
    and edi, 31
    mov esi, 6
.sps:
    test edi, edi
    jz .ppscount
    lea eax, [esi + 2]
    cmp eax, ecx
    ja .ret
    movzx edx, word [ebx + esi]
    xchg dl, dh
    add eax, edx
    cmp eax, ecx
    ja .ret
    cmp dword [ebp + MP4T_P5], 0
    jne .sps2
    test edx, edx
    jz .sps2
    lea edx, [esi + 2]
    mov [ebp + MP4TK_SPSOFF], edx
    sub eax, edx
    mov [ebp + MP4T_P5], eax
    add eax, edx
.sps2:
    mov esi, eax
    dec edi
    jmp .sps
.ppscount:
    cmp esi, ecx
    jae .ok
    movzx edi, byte [ebx + esi]
    inc esi
.pps:
    test edi, edi
    jz .ok
    lea eax, [esi + 2]
    cmp eax, ecx
    ja .ret
    movzx edx, word [ebx + esi]
    xchg dl, dh
    add eax, edx
    cmp eax, ecx
    ja .ret
    cmp dword [ebp + MP4T_P7], 0
    jne .pps2
    test edx, edx
    jz .pps2
    lea edx, [esi + 2]
    mov [ebp + MP4TK_PPSOFF], edx
    sub eax, edx
    mov [ebp + MP4T_P7], eax
    add eax, edx
.pps2:
    mov esi, eax
    dec edi
    jmp .pps
.ok:
    mov dword [ebp + MP4TK_CODECOK], 1
.ret:
    ret

mp4_snd_entry:
    mov eax, ecx
    sub eax, ebx
    cmp eax, 28
    jb .ret
    movzx edx, word [ebx + 16]
    xchg dl, dh
    mov [ebp + MP4T_P2], edx
    movzx edx, word [ebx + 24]
    xchg dl, dh
    mov [ebp + MP4T_P1], edx
    movzx edx, word [ebx + 8]
    xchg dl, dh
    mov esi, 28
    test edx, edx
    jz .kids
    mov esi, 44
    cmp edx, 1
    je .kids
    mov esi, 64
    cmp edx, 2
    jne .ret
.kids:
    cmp esi, eax
    ja .ret
    add esi, ebx
    mov edx, ecx
.next:
    call mp4_box_next
    jc .done
    cmp eax, 'esds'
    je .esds
    cmp eax, 'wave'
    jne .skip
    push esi
    push edx
    mov esi, ebx
    mov edx, ecx
.wnext:
    call mp4_box_next
    jc .wdone
    cmp eax, 'esds'
    je .wesds
    mov esi, ecx
    jmp .wnext
.wesds:
    call mp4_esds
.wdone:
    pop edx
    pop esi
    jmp .done
.esds:
    call mp4_esds
    jmp .done
.skip:
    mov esi, ecx
    jmp .next
.done:
    cmp dword [ebp + MP4T_CODEC], 'mp4a'
    jne .ret
    cmp dword [ebp + MP4T_CFGLEN], 2
    jb .ret
    mov eax, [ebp + MP4T_P3]
    cmp eax, 0x40
    je .aac
    cmp eax, 0x66
    jb .ret
    cmp eax, 0x68
    ja .ret
.aac:
    call mp4_asc
    mov dword [ebp + MP4TK_CODECOK], 1
.ret:
    ret

mp4_desc:
    cmp esi, edx
    jae .bad
    movzx eax, byte [esi]
    shl eax, 8
    inc esi
    xor ecx, ecx
    push edx
    mov dl, 4
.len:
    cmp esi, [esp]
    jae .badpop
    shl ecx, 7
    mov al, [esi]
    inc esi
    and al, 0x7F
    or cl, al
    test byte [esi - 1], 0x80
    jz .gotlen
    dec dl
    jnz .len
.badpop:
    pop edx
.bad:
    stc
    ret
.gotlen:
    pop edx
    mov al, ah
    push eax
    mov eax, edx
    sub eax, esi
    cmp ecx, eax
    pop eax
    ja .bad
    clc
    ret

mp4_esds:
    push esi
    push edx
    lea esi, [ebx + 4]
    mov edx, ecx
    call mp4_desc
    jc .ret
    cmp al, 4
    je .dcd
    cmp al, 3
    jne .ret
    lea edx, [esi + ecx]
    lea eax, [esi + 3]
    cmp eax, edx
    ja .ret
    mov bl, [esi + 2]
    mov esi, eax
    test bl, 0x80
    jz .nodep
    add esi, 2
.nodep:
    test bl, 0x40
    jz .nourl
    cmp esi, edx
    jae .ret
    movzx eax, byte [esi]
    lea esi, [esi + eax + 1]
.nourl:
    test bl, 0x20
    jz .find4
    add esi, 2
.find4:
    cmp esi, edx
    ja .ret
    call mp4_desc
    jc .ret
    cmp al, 4
    je .dcd
    add esi, ecx
    jmp .find4
.dcd:
    lea edx, [esi + ecx]
    cmp ecx, 13
    jb .ret
    movzx eax, byte [esi]
    mov [ebp + MP4T_P3], eax
    add esi, 13
.find5:
    call mp4_desc
    jc .ret
    cmp al, 5
    je .dsi
    add esi, ecx
    jmp .find5
.dsi:
    mov [ebp + MP4TK_CFGSRC], esi
    mov [ebp + MP4T_CFGLEN], ecx
.ret:
    pop edx
    pop esi
    ret

mp4_bits:
    mov ecx, [mp4_bitpos]
    add [mp4_bitpos], edx
    mov eax, ecx
    shr eax, 3
    cmp eax, 12
    jae .zero
    mov eax, [mp4_ascbuf + eax]
    bswap eax
    and ecx, 7
    shl eax, cl
    mov ecx, 32
    sub ecx, edx
    shr eax, cl
    ret
.zero:
    xor eax, eax
    ret

mp4_asc:
    xor eax, eax
    mov [mp4_bitpos], eax
    mov edi, mp4_ascbuf
    mov ecx, 4
    rep stosd
    mov esi, [ebp + MP4TK_CFGSRC]
    mov ecx, [ebp + MP4T_CFGLEN]
    cmp ecx, 12
    jbe .copy
    mov ecx, 12
.copy:
    mov edi, mp4_ascbuf
    rep movsb
    mov edx, 5
    call mp4_bits
    cmp eax, 31
    jne .aot
    mov edx, 6
    call mp4_bits
    add eax, 32
.aot:
    mov [ebp + MP4T_P4], eax
    call .freq
    mov edx, 4
    call mp4_bits
    movzx eax, byte [mp4_aacch + eax]
    test eax, eax
    jz .sbr
    mov [ebp + MP4T_P2], eax
.sbr:
    mov eax, [ebp + MP4T_P4]
    cmp eax, 5
    je .ext
    cmp eax, 29
    jne .ret
.ext:
    call .freq
.ret:
    ret
.freq:
    mov edx, 4
    call mp4_bits
    cmp eax, 15
    jne .table
    mov edx, 24
    call mp4_bits
    jmp .setf
.table:
    mov eax, [mp4_aacrate + eax * 4]
.setf:
    test eax, eax
    jz .nof
    mov [ebp + MP4T_P1], eax
.nof:
    ret

mp4_tables:
    mov ecx, MP4SL_STTS
    call mp4_slot
    jz .ctts
    mov edx, 3
    call .count
    mov [ebp + MP4TK_STTS], ebx
    mov [ebp + MP4TK_STTSN], eax
.ctts:
    mov ecx, MP4SL_CTTS
    call mp4_slot
    jz .stss
    mov edx, 3
    call .count
    mov [ebp + MP4TK_CTTS], ebx
    mov [ebp + MP4TK_CTTSN], eax
.stss:
    mov ecx, MP4SL_STSS
    call mp4_slot
    jz .stsc
    mov edx, 2
    call .count
    mov [ebp + MP4TK_STSS], ebx
    mov [ebp + MP4TK_STSSN], eax
.stsc:
    mov ecx, MP4SL_STSC
    call mp4_slot
    jz .stco
    cmp ecx, 8
    jb .stco
    sub ecx, 8
    mov eax, ecx
    xor edx, edx
    mov ecx, 12
    div ecx
    mov ecx, [ebx + 4]
    bswap ecx
    cmp ecx, eax
    jae .scfit
    mov eax, ecx
.scfit:
    add ebx, 8
    mov [ebp + MP4TK_STSC], ebx
    mov [ebp + MP4TK_STSCN], eax
.stco:
    mov ecx, MP4SL_STCO
    call mp4_slot
    jz .co64
    mov edx, 2
    call .count
    jmp .setco
.co64:
    mov ecx, MP4SL_CO64
    call mp4_slot
    jz .sizes
    mov edx, 3
    call .count
    mov dword [ebp + MP4TK_CO64], 1
.setco:
    mov [ebp + MP4TK_CO], ebx
    mov [ebp + MP4TK_CON], eax
.sizes:
    mov ecx, MP4SL_STSZ
    call mp4_slot
    jz .stz2
    cmp ecx, 12
    jb .stz2
    mov eax, [ebx + 8]
    bswap eax
    mov edx, [ebx + 4]
    bswap edx
    test edx, edx
    jz .stsz32
    mov [ebp + MP4TK_SZCONST], edx
    mov dword [ebp + MP4TK_SZKIND], 1
    jmp .setn
.stsz32:
    sub ecx, 12
    shr ecx, 2
    cmp eax, ecx
    jbe .s32fit
    mov eax, ecx
.s32fit:
    mov dword [ebp + MP4TK_SZKIND], 32
    jmp .setsz
.stz2:
    mov ecx, MP4SL_STZ2
    call mp4_slot
    jz .ret
    cmp ecx, 12
    jb .ret
    sub ecx, 12
    cmp ecx, 0x40000000
    jae .ret
    movzx edx, byte [ebx + 7]
    mov eax, [ebx + 8]
    bswap eax
    cmp edx, 4
    jne .z8
    shl ecx, 1
    jmp .zfit
.z8:
    cmp edx, 8
    je .zfit
    cmp edx, 16
    jne .ret
    shr ecx, 1
.zfit:
    cmp eax, ecx
    jbe .zok
    mov eax, ecx
.zok:
    mov [ebp + MP4TK_SZKIND], edx
.setsz:
    add ebx, 12
    mov [ebp + MP4TK_SZ], ebx
.setn:
    mov [ebp + MP4T_N], eax
.ret:
    ret

.count:
    xor eax, eax
    cmp ecx, 8
    jb .cret
    sub ecx, 8
    xchg ecx, edx
    shr edx, cl
    mov eax, [ebx + 4]
    bswap eax
    cmp eax, edx
    jbe .cret
    mov eax, edx
.cret:
    add ebx, 8
    ret

mp4_edit:
    mov eax, [ebp + MP4T_MDUR]
    mov [ebp + MP4T_DUR], eax
    mov ecx, MP4SL_ELST
    call mp4_slot
    jz .ret
    cmp ecx, 8
    jb .ret
    mov edx, 12
    cmp byte [ebx], 1
    jne .v0
    mov edx, 20
.v0:
    sub ecx, 8
    mov eax, ecx
    mov ecx, edx
    xor edx, edx
    div ecx
    mov edx, [ebx + 4]
    bswap edx
    cmp edx, eax
    jbe .nfit
    mov edx, eax
.nfit:
    lea esi, [ebx + 8]
    xor edi, edi
.entry:
    test edx, edx
    jz .noreal
    cmp ecx, 20
    je .e1
    mov eax, [esi]
    bswap eax
    mov ebx, [esi + 4]
    bswap ebx
    cmp ebx, -1
    je .empty
    test ebx, ebx
    js .ret
    jmp .real
.e1:
    mov ebx, esi
    push ecx
    xor ecx, ecx
    call mp4_rd64
    pop ecx
    mov ebx, [esi + 8]
    and ebx, [esi + 12]
    cmp ebx, -1
    je .empty
    cmp dword [esi + 8], 0
    jne .ret
    mov ebx, [esi + 12]
    bswap ebx
    test ebx, ebx
    js .ret
    jmp .real
.empty:
    add edi, eax
    jnc .enext
    mov edi, -1
.enext:
    add esi, ecx
    dec edx
    jmp .entry
.noreal:
    xor ebx, ebx
    xor eax, eax
.real:
    mov [mp4_tmp], eax
    mov esi, ebx
    mov eax, edi
    mov ecx, [ebp + MP4T_SCALE]
    mov ebx, [mp4_mscale]
    call mp4_rescale
    mov edx, esi
    sub edx, eax
    jnc .shift
    test edx, edx
    js .shift
    mov edx, 0x80000000
.shift:
    mov [ebp + MP4T_EDIT], edx
    mov edx, eax
    mov eax, [mp4_tmp]
    test eax, eax
    jz .tomedia
    add eax, edi
    jnc .resc
    mov eax, -1
.resc:
    mov ecx, [ebp + MP4T_SCALE]
    call mp4_rescale
    jmp .setdur
.tomedia:
    mov eax, [ebp + MP4T_MDUR]
    sub eax, esi
    jae .tm2
    xor eax, eax
.tm2:
    add eax, edx
    jnc .setdur
    mov eax, -1
.setdur:
    test eax, eax
    jz .ret
    mov [ebp + MP4T_DUR], eax
.ret:
    ret

mp4_build:
    mov [ebp + MP4T_SAMP], edi
    mov eax, [ebp + MP4T_N]
    shl eax, 4
    add eax, edi
    mov [mp4_send], eax

    xor edx, edx
    cmp dword [ebp + MP4TK_STSS], 0
    jne .flag
    inc edx
.flag:
    mov esi, [ebp + MP4TK_SZ]
    mov ecx, [ebp + MP4T_N]
    test ecx, ecx
    jz .ret
    xor ebx, ebx
.size:
    mov eax, [ebp + MP4TK_SZKIND]
    cmp eax, 32
    je .sz32
    cmp eax, 16
    je .sz16
    cmp eax, 8
    je .sz8
    cmp eax, 4
    je .sz4
    mov eax, [ebp + MP4TK_SZCONST]
    jmp .szset
.sz32:
    mov eax, [esi + ebx * 4]
    bswap eax
    jmp .szset
.sz16:
    movzx eax, word [esi + ebx * 2]
    xchg al, ah
    jmp .szset
.sz8:
    movzx eax, byte [esi + ebx]
    jmp .szset
.sz4:
    mov eax, ebx
    shr eax, 1
    movzx eax, byte [esi + eax]
    test ebx, 1
    jnz .lo4
    shr eax, 4
.lo4:
    and eax, 15
.szset:
    mov dword [edi + MP4S_OFF], 0
    mov [edi + MP4S_SIZE], eax
    mov dword [edi + MP4S_PTS], 0
    mov [edi + MP4S_FLAGS], edx
    add edi, MP4S_LEN
    inc ebx
    dec ecx
    jnz .size
    call mp4_offsets
    call mp4_times
    call mp4_sync
.ret:
    ret

mp4_offsets:
    mov edi, [ebp + MP4T_SAMP]
    mov esi, [ebp + MP4TK_STSC]
    mov eax, [ebp + MP4TK_STSCN]
    lea eax, [eax + eax * 2]
    lea eax, [esi + eax * 4]
    mov [mp4_scend], eax
    mov ebx, 1
.chunk:
    cmp ebx, [ebp + MP4TK_CON]
    ja .done
    cmp edi, [mp4_send]
    jae .done
.adv:
    lea eax, [esi + 12]
    cmp eax, [mp4_scend]
    jae .advdone
    mov eax, [esi + 12]
    bswap eax
    cmp eax, ebx
    ja .advdone
    add esi, 12
    jmp .adv
.advdone:
    xor ecx, ecx
    mov eax, [esi]
    bswap eax
    cmp eax, ebx
    ja .gotn
    mov ecx, [esi + 4]
    bswap ecx
.gotn:
    mov eax, [ebp + MP4TK_CO]
    cmp dword [ebp + MP4TK_CO64], 0
    jne .c64
    mov edx, [eax + ebx * 4 - 4]
    bswap edx
    jmp .place
.c64:
    cmp dword [eax + ebx * 8 - 8], 0
    jne .done
    mov edx, [eax + ebx * 8 - 4]
    bswap edx
.place:
    test ecx, ecx
    jz .nextchunk
    cmp edi, [mp4_send]
    jae .done
    mov [edi + MP4S_OFF], edx
    add edx, [edi + MP4S_SIZE]
    jc .done
    add edi, MP4S_LEN
    dec ecx
    jmp .place
.nextchunk:
    inc ebx
    jmp .chunk
.done:
    sub edi, [ebp + MP4T_SAMP]
    shr edi, 4
    mov [ebp + MP4T_N], edi
    ret

mp4_times:
    cmp dword [ebp + MP4T_N], 0
    je .ret
    mov esi, [ebp + MP4TK_STTS]
    mov eax, [ebp + MP4TK_STTSN]
    lea eax, [esi + eax * 8]
    mov [mp4_tend], eax
    mov eax, [esi]
    bswap eax
    mov [mp4_trem], eax
    mov eax, [ebp + MP4TK_CTTS]
    mov [mp4_cp], eax
    mov ecx, [ebp + MP4TK_CTTSN]
    lea ecx, [eax + ecx * 8]
    mov [mp4_cend], ecx
    xor ecx, ecx
    cmp eax, ecx
    je .noctts
    cmp [mp4_cend], eax
    je .noctts
    mov ecx, [eax]
    bswap ecx
.noctts:
    mov [mp4_crem], ecx
    xor eax, eax
    mov [mp4_dtslo], eax
    mov [mp4_dtshi], eax
    mov edi, [ebp + MP4T_SAMP]
    mov ecx, [ebp + MP4T_N]
.sample:

.tskip:
    cmp dword [mp4_trem], 0
    jne .tgot
    lea eax, [esi + 8]
    cmp eax, [mp4_tend]
    jae .tgot
    mov esi, eax
    mov eax, [esi]
    bswap eax
    mov [mp4_trem], eax
    jmp .tskip
.tgot:

    xor ebx, ebx
.cskip:
    mov eax, [mp4_cp]
    cmp eax, [mp4_cend]
    jae .cgot
    cmp dword [mp4_crem], 0
    jne .cval
    add eax, 8
    mov [mp4_cp], eax
    cmp eax, [mp4_cend]
    jae .cgot
    mov eax, [eax]
    bswap eax
    mov [mp4_crem], eax
    jmp .cskip
.cval:
    mov ebx, [eax + 4]
    bswap ebx
    dec dword [mp4_crem]
.cgot:

    mov eax, ebx
    cdq
    add eax, [mp4_dtslo]
    adc edx, [mp4_dtshi]
    mov ebx, [ebp + MP4T_EDIT]
    push ecx
    mov ecx, ebx
    sar ecx, 31
    sub eax, ebx
    sbb edx, ecx
    mov ebx, [esi + 4]
    bswap ebx
    push edx
    push eax
    add eax, ebx
    adc edx, 0
    test edx, edx
    js .pre
    jnz .shown
    test eax, eax
    jnz .shown
.pre:
    or dword [edi + MP4S_FLAGS], MP4S_F_PRE
.shown:
    pop eax
    pop edx
    pop ecx
    test edx, edx
    jz .ptsok
    js .ptszero
    mov eax, -1
    jmp .ptsok
.ptszero:
    xor eax, eax
.ptsok:
    mov [edi + MP4S_PTS], eax

    mov eax, [esi + 4]
    bswap eax
    add [mp4_dtslo], eax
    adc dword [mp4_dtshi], 0
    cmp dword [mp4_trem], 0
    je .tnext
    dec dword [mp4_trem]
.tnext:
    add edi, MP4S_LEN
    dec ecx
    jnz .sample
    cmp dword [ebp + MP4T_DUR], 0
    jne .ret
    mov eax, [mp4_dtslo]
    cmp dword [mp4_dtshi], 0
    je .dur
    mov eax, -1
.dur:
    mov [ebp + MP4T_DUR], eax
.ret:
    ret

mp4_sync:
    mov esi, [ebp + MP4TK_STSS]
    mov ecx, [ebp + MP4TK_STSSN]
    mov ebx, [ebp + MP4T_SAMP]
    test esi, esi
    jz .count
.mark:
    test ecx, ecx
    jz .count
    mov eax, [esi]
    bswap eax
    add esi, 4
    dec ecx
    dec eax
    cmp eax, [ebp + MP4T_N]
    jae .mark
    shl eax, 4
    or dword [ebx + eax + MP4S_FLAGS], MP4S_F_SYNC
    jmp .mark
.count:
    xor edx, edx
    mov ecx, [ebp + MP4T_N]
    test ecx, ecx
    jz .done
.cnt:
    mov eax, [ebx + MP4S_FLAGS]
    and eax, MP4S_F_SYNC
    add edx, eax
    add ebx, MP4S_LEN
    dec ecx
    jnz .cnt
.done:
    mov [ebp + MP4T_NSYNC], edx
    ret

mp4_need:
    cmp dword [ebp + MP4TK_USE], 0
    je .ret
    mov edx, [ebp + MP4T_CFGLEN]
    add edx, 15
    jc .max
    and edx, -16
    add eax, edx
    jc .max
    mov edx, [ebp + MP4T_N]
    cmp edx, 0x10000000
    jae .max
    shl edx, 4
    add eax, edx
    jc .max
.ret:
    ret
.max:
    mov eax, -1
    ret

mp4_cfg:
    mov edi, [mp4_wp]
    mov [ebp + MP4T_CFG], edi
    mov esi, [ebp + MP4TK_CFGSRC]
    mov ecx, [ebp + MP4T_CFGLEN]
    rep movsb
    mov eax, [ebp + MP4T_CFGLEN]
    add eax, 15
    and eax, -16
    add [mp4_wp], eax
    cmp dword [ebp + MP4TK_HDLR], 'vide'
    jne .ret
    mov eax, [ebp + MP4T_CFG]
    cmp dword [ebp + MP4T_P5], 0
    je .pps
    add eax, [ebp + MP4TK_SPSOFF]
    mov [ebp + MP4T_P4], eax
.pps:
    mov eax, [ebp + MP4T_CFG]
    cmp dword [ebp + MP4T_P7], 0
    je .ret
    add eax, [ebp + MP4TK_PPSOFF]
    mov [ebp + MP4T_P6], eax
.ret:
    ret

mp4_out:
    cmp dword [ebp + MP4TK_HDLR], 0
    je .ret
    mov esi, ebp
    mov ecx, MP4T_LEN / 4
    rep movsd
    sub edi, MP4T_LEN
    cmp dword [ebp + MP4T_OK], 0
    jne .ret
    xor eax, eax
    mov [edi + MP4T_N], eax
    mov [edi + MP4T_SAMP], eax
    mov [edi + MP4T_CFG], eax
    mov [edi + MP4T_CFGLEN], eax
    mov [edi + MP4T_NSYNC], eax
    cmp dword [ebp + MP4TK_HDLR], 'vide'
    jne .ret
    mov [edi + MP4T_P4], eax
    mov [edi + MP4T_P5], eax
    mov [edi + MP4T_P6], eax
    mov [edi + MP4T_P7], eax
.ret:
    ret

EXPORT(mp4_parse_moov)
mp4_parse_moov:
    CENTER
    mov edi, ARG(2)
    mov ecx, MP4I_SIZE / 4
    xor eax, eax
    rep stosd
    mov edi, mp4_bss
    mov ecx, (mp4_bss_end - mp4_bss) / 4
    rep stosd
    mov eax, ARG(2)
    mov [mp4_info], eax
    mov eax, ARG(3)
    mov [mp4_work], eax
    mov eax, ARG(4)
    mov [mp4_wlen], eax
    mov esi, ARG(0)
    mov ecx, ARG(1)
    lea edx, [esi + ecx]
    cmp edx, esi
    jb .bad
    cmp ecx, 8
    jb .payload
    cmp dword [esi + 4], 'moov'
    jne .payload
    mov eax, [esi]
    bswap eax
    mov ebx, 8
    cmp eax, 1
    jne .hsize
    cmp ecx, 16
    jb .bad
    mov ebx, 16
    cmp dword [esi + 8], 0
    jne .hdone
    mov eax, [esi + 12]
    bswap eax
.hsize:
    cmp eax, ebx
    jb .hdone
    cmp eax, ecx
    jae .hdone
    lea edx, [esi + eax]
.hdone:
    add esi, ebx
.payload:
    mov [mp4_mbeg], esi
    mov [mp4_mend], edx

.p1:
    call mp4_box_next
    jc .p1done
    cmp eax, 'mvex'
    jne .p1hd
    mov dword [mp4_frag], 1
.p1hd:
    cmp eax, 'mvhd'
    jne .p1next
    mov eax, ecx
    sub eax, ebx
    cmp eax, 20
    jb .p1next
    cmp byte [ebx], 1
    je .mv1
    mov eax, [ebx + 12]
    bswap eax
    mov [mp4_mscale], eax
    mov eax, [ebx + 16]
    bswap eax
    mov [mp4_mdur], eax
    jmp .p1next
.mv1:
    cmp eax, 32
    jb .p1next
    mov eax, [ebx + 20]
    bswap eax
    mov [mp4_mscale], eax
    push ecx
    mov ecx, 24
    call mp4_rd64
    pop ecx
    mov [mp4_mdur], eax
.p1next:
    mov esi, ecx
    jmp .p1
.p1done:

    mov esi, [mp4_mbeg]
    mov edx, [mp4_mend]
.p2:
    call mp4_box_next
    jc .p2done
    cmp eax, 'trak'
    jne .p2next
    inc dword [mp4_ntrak]
    push ecx
    push edx
    push esi
    mov edi, mp4_slot_ptr
    mov ecx, MP4SL_COUNT * 2
    xor eax, eax
    rep stosd
    mov [mp4_depth], eax
    mov esi, ebx
    mov edx, [esp + 8]
    call mp4_walk
    mov ebp, mp4_ct
    call mp4_track

    mov edi, mp4_vt
    mov eax, [ebp + MP4TK_HDLR]
    cmp eax, 'vide'
    je .pick
    mov edi, mp4_at
    cmp eax, 'soun'
    jne .p2pop
.pick:
    cmp dword [edi + MP4TK_HDLR], 0
    je .keep
    cmp dword [edi + MP4TK_USE], 0
    jne .p2pop
    cmp dword [ebp + MP4TK_USE], 0
    je .p2pop
.keep:
    mov esi, ebp
    mov ecx, MP4TK_LEN / 4
    rep movsd
.p2pop:
    pop esi
    pop edx
    pop ecx
.p2next:
    mov esi, ecx
    jmp .p2
.p2done:
    mov ebp, [mp4_info]
    mov eax, [mp4_mscale]
    mov [ebp + MP4I_M_SCALE], eax
    mov eax, [mp4_mdur]
    mov [ebp + MP4I_M_DUR], eax
    mov eax, [mp4_ntrak]
    mov [ebp + MP4I_NTRAK], eax

    mov eax, 15
    mov ebp, mp4_vt
    call mp4_need
    mov ebp, mp4_at
    call mp4_need
    mov ebx, [mp4_info]
    mov [ebx + MP4I_NEED], eax
    cmp eax, [mp4_wlen]
    ja .small

    mov eax, [mp4_work]
    add eax, 15
    and eax, -16
    mov [mp4_wp], eax
    mov ebp, mp4_vt
    cmp dword [ebp + MP4TK_USE], 0
    je .bcfga
    call mp4_cfg
.bcfga:
    mov ebp, mp4_at
    cmp dword [ebp + MP4TK_USE], 0
    je .bsampv
    call mp4_cfg
.bsampv:
    mov ebp, mp4_vt
    cmp dword [ebp + MP4TK_USE], 0
    je .bsampa
    mov edi, [mp4_wp]
    mov eax, [ebp + MP4T_N]
    shl eax, 4
    add [mp4_wp], eax
    call mp4_build
.bsampa:
    mov ebp, mp4_at
    cmp dword [ebp + MP4TK_USE], 0
    je .report
    mov edi, [mp4_wp]
    mov eax, [ebp + MP4T_N]
    shl eax, 4
    add [mp4_wp], eax
    call mp4_build
.report:

    mov ebp, mp4_vt
    call .setok
    mov edi, [mp4_info]
    add edi, MP4I_V
    call mp4_out
    mov ebp, mp4_at
    call .setok
    mov edi, [mp4_info]
    add edi, MP4I_A
    call mp4_out
    mov ebx, [mp4_info]
    mov eax, [ebx + MP4I_V_OK]
    or eax, [ebx + MP4I_A_OK]
    jz .none
    xor eax, eax
    CLEAVE
.none:
    mov eax, MP4_EFRAG
    cmp dword [mp4_frag], 0
    jne .ret
    mov eax, MP4_ECODEC
    mov ecx, [mp4_vt + MP4TK_HDLR]
    or ecx, [mp4_at + MP4TK_HDLR]
    jnz .ret
.bad:
    mov eax, MP4_EBAD
.ret:
    CLEAVE
.small:
    mov eax, MP4_EWORK
    CLEAVE
.setok:
    xor eax, eax
    cmp dword [ebp + MP4TK_USE], 0
    je .so
    cmp dword [ebp + MP4T_N], 0
    je .so
    inc eax
.so:
    mov [ebp + MP4T_OK], eax
    ret

EXPORT(mp4_find_sync)
mp4_find_sync:
    CENTER
    mov esi, ARG(0)
    mov ecx, ARG(1)
    mov edx, ARG(2)
    test ecx, ecx
    jz .zero
    mov eax, ecx
    shl eax, 4
    add eax, esi
.back:
    sub eax, MP4S_LEN
    dec ecx
    test byte [eax + MP4S_FLAGS], MP4S_F_SYNC
    jz .bnext
    cmp [eax + MP4S_PTS], edx
    jbe .found
.bnext:
    test ecx, ecx
    jnz .back

    mov ebx, ARG(1)
    xor ecx, ecx
.fwd:
    test byte [esi + MP4S_FLAGS], MP4S_F_SYNC
    jnz .found
    add esi, MP4S_LEN
    inc ecx
    cmp ecx, ebx
    jb .fwd
.zero:
    xor ecx, ecx
.found:
    mov eax, ecx
    CLEAVE

section .text
