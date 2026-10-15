; =============================================================================
;  jpeg.asm - JPEG picture decoder (baseline and progressive, Huffman coded)
;
;  int jpeg_info(data, len, &w, &h, &worksize)
;  int jpeg_decode(data, len, out, stride_px, bg, work, worksize)
;      out = 0x00RRGGBB pixels, stride_px pixels per row; bg is unused (a
;      JPEG has no transparency). 0 ok, -1 bad / unsupported, -2 work too
;      small.
;
;  Supported: 8-bit frames SOF0 (baseline), SOF1 (extended, Huffman) and
;  SOF2 (progressive, Huffman); 1 component (grey) or 3 (YCbCr, or RGB when
;  an Adobe marker or the component ids say so); any sampling factors 1-4
;  whose ratios to the largest are whole numbers (4:4:4, 4:2:2, 4:2:0,
;  4:4:0, 4:1:1 ...); restart intervals. Not supported: arithmetic coding,
;  12-bit and lossless frames, CMYK.
;
;  How it works. The marker segments are walked in order: DQT and DHT
;  define quantisation and Huffman tables (a Huffman table becomes a 512
;  entry lookup for codes of up to 9 bits plus the canonical maxcode list
;  for longer ones), SOF sets the geometry and lays the work buffer out,
;  and each SOS is followed by its entropy-coded data, decoded right there.
;  Every component has a plane of 8-bit samples padded to whole MCUs.
;    Baseline: each 8x8 block is decoded, then inverse transformed straight
;      into its plane.
;    Progressive: the scans refine a coefficient array per component (64
;      int16 per block); after the last scan every block is transformed.
;  Then each output row is made: the chroma planes are upsampled and the
;  samples converted to RGB. The arithmetic follows libjpeg (which Pillow
;  and most browsers use) exactly: its "islow" integer IDCT, its "fancy"
;  triangle-filter upsampling (box replication where libjpeg uses that
;  too) and its fixed-point YCbCr to RGB, so the pixels are the ones
;  libjpeg gives.
;
;  Robustness: all reads are checked against the end of the data (the bit
;  reader feeds zero bits at a marker or at the end, as libjpeg does), all
;  writes go to blocks inside the planes laid out by SOF, and every loop is
;  bounded by the block counts (at most JPEG_MAXSCANS scans are decoded).
; =============================================================================
%include "src/module.inc"

JPEG_MAXDIM     equ 16384               ; bigger frames are refused
JPEG_MAXSCANS   equ 1000                ; later scans are ignored

; one component (dwords)
JC_ID       equ 0                       ; component id from SOF
JC_H        equ 4                       ; sampling factors
JC_V        equ 8
JC_TQ       equ 12                      ; quantisation table number
JC_BW       equ 16                      ; blocks per row, padded to whole MCUs
JC_BH       equ 20                      ; block rows, padded
JC_DW       equ 24                      ; samples per row really used
JC_DH       equ 28                      ; sample rows really used
JC_NBW      equ 32                      ; blocks per row in a scan of this alone
JC_NBH      equ 36
JC_PLANE    equ 40                      ; samples, JC_BW * 8 bytes per row
JC_COEF     equ 44                      ; progressive: 64 int16 per block
JC_DCT      equ 48                      ; DC Huffman table pointer
JC_ACT      equ 52                      ; AC Huffman table pointer
JC_PRED     equ 56                      ; DC prediction
JC_SX       equ 60                      ; upsampling: Hmax / H
JC_SY       equ 64                      ;             Vmax / V
JC_ROW      equ 68                      ; buffer for one upsampled row
JC_QOK      equ 72                      ; quantisation table latched
JC_QT       equ 76                      ; pointer to its latched table
JC_SIZE     equ 80

; one Huffman table
JH_LUT      equ 0                       ; 512 dwords: (len << 8) | symbol, 0 = longer code
JH_MAX      equ 2048                    ; 17 dwords: maxcode[len], -1 = none
JH_OFF      equ 2048 + 68               ; 17 dwords: index of symbol - code, per len
JH_VALS     equ 2048 + 136              ; 256 bytes of symbols
JH_SIZE     equ 2048 + 136 + 256

section .data
; zigzag position k -> natural (row-major) position, padded for k up to 79
jpeg_nat:
    db  0,  1,  8, 16,  9,  2,  3, 10, 17, 24, 32, 25, 18, 11,  4,  5
    db 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13,  6,  7, 14, 21, 28
    db 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51
    db 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63
    times 16 db 63

section .bss
alignb 16
jpeg_huf    resb 8 * JH_SIZE            ; DC tables 0-3, AC tables 4-7
jpeg_qt     resd 4 * 64                 ; quantisation tables, natural order
jpeg_cq     resd 4 * 64                 ; per component, latched at its first scan
jpeg_blk    resw 64                     ; baseline: the block being decoded
jpeg_ws     resd 64                     ; IDCT: the columns pass
; --- reset to 0 by jpeg_reset from here ---
jpeg_z0:
jpeg_comp   resb 4 * JC_SIZE
jpeg_hok    resd 8                      ; Huffman table defined
jpeg_qok    resd 4                      ; quantisation table defined
jpeg_mode   resd 1                      ; 0 = stop after SOF (info), 1 = decode
jpeg_sof    resd 1                      ; SOF seen
jpeg_nscan  resd 1                      ; scans decoded
jpeg_ncomp  resd 1
jpeg_w      resd 1
jpeg_h      resd 1
jpeg_hmax   resd 1
jpeg_vmax   resd 1
jpeg_mcux   resd 1                      ; MCUs per row / column (interleaved)
jpeg_mcuy   resd 1
jpeg_prog   resd 1                      ; SOF2
jpeg_rgb    resd 1                      ; 3 components are R G B, not YCbCr
jpeg_jfif   resd 1
jpeg_adobe  resd 1                      ; Adobe marker seen: 1 + its transform
jpeg_rsti   resd 1                      ; restart interval (MCUs)
jpeg_need   resd 1                      ; bytes of work needed
jpeg_work   resd 1
jpeg_wsize  resd 1
jpeg_z1:
; --- scan ---
jpeg_ns     resd 1                      ; components in the scan
jpeg_sc     resd 4                      ; their records
jpeg_ss     resd 1                      ; spectral selection start / end
jpeg_se     resd 1
jpeg_ah     resd 1                      ; successive approximation
jpeg_al     resd 1
jpeg_eobrun resd 1
jpeg_rstleft resd 1
jpeg_mx     resd 1
jpeg_my     resd 1
jpeg_nmx    resd 1
jpeg_nmy    resd 1
jpeg_blkfn  resd 1                      ; routine decoding one block
; --- bit reader ---
jpeg_ptr    resd 1                      ; next byte
jpeg_end    resd 1                      ; end of the data
jpeg_bbuf   resd 1                      ; bits, the next one at bit 31
jpeg_bcnt   resd 1                      ; how many are valid
jpeg_mark   resd 1                      ; a marker (or the end) was reached
; --- IDCT temporaries ---
jpeg_t0     resd 1
jpeg_t1     resd 1
jpeg_t2     resd 1
jpeg_t3     resd 1
jpeg_t10    resd 1
jpeg_t11    resd 1
jpeg_t12    resd 1
jpeg_t13    resd 1
jpeg_z1v    resd 1
jpeg_z2v    resd 1
jpeg_z3v    resd 1
jpeg_z4v    resd 1
jpeg_cnt    resd 1
jpeg_ostr   resd 1
jpeg_odst   resd 1
; --- output ---
jpeg_out    resd 1
jpeg_ostride resd 1
jpeg_y      resd 1
jpeg_rows   resd 4                      ; upsampled row of each component

section .text

; -----------------------------------------------------------------------------
; int jpeg_info(data, len, &w, &h, &worksize): read the headers up to SOF.
; -----------------------------------------------------------------------------
EXPORT(jpeg_info)
jpeg_info:
    CENTER
    mov esi, ARG(0)
    mov ecx, ARG(1)
    call jpeg_reset
    test eax, eax
    js .out
    mov dword [jpeg_mode], 0
    call jpeg_markers
    test eax, eax
    js .out
    mov eax, -1
    cmp dword [jpeg_sof], 0
    je .out
    mov edx, ARG(2)
    mov ecx, [jpeg_w]
    mov [edx], ecx
    mov edx, ARG(3)
    mov ecx, [jpeg_h]
    mov [edx], ecx
    mov edx, ARG(4)
    mov ecx, [jpeg_need]
    mov [edx], ecx
    xor eax, eax
.out:
    CLEAVE

; -----------------------------------------------------------------------------
; int jpeg_decode(data, len, out, stride_px, bg, work, worksize)
; -----------------------------------------------------------------------------
EXPORT(jpeg_decode)
jpeg_decode:
    CENTER
    mov esi, ARG(0)
    mov ecx, ARG(1)
    call jpeg_reset
    test eax, eax
    js .out
    mov dword [jpeg_mode], 1
    mov eax, ARG(5)
    mov [jpeg_work], eax
    mov eax, ARG(6)
    mov [jpeg_wsize], eax
    call jpeg_markers                       ; decodes every scan
    test eax, eax
    js .out
    mov eax, -1
    cmp dword [jpeg_sof], 0
    je .out
    cmp dword [jpeg_nscan], 0
    je .out
    mov ecx, ARG(3)
    cmp ecx, [jpeg_w]
    jb .out
    shl ecx, 2
    mov [jpeg_ostride], ecx
    mov eax, ARG(2)
    mov [jpeg_out], eax
    cmp dword [jpeg_prog], 0
    je .conv
    call jpeg_idct_all
.conv:
    call jpeg_output
    xor eax, eax
.out:
    CLEAVE

; jpeg_reset: ESI = data, ECX = length -> state cleared, bit reader set at
; the byte after SOI. EAX = 0, or -1 if it does not start with FF D8.
jpeg_reset:
    push edi
    push ecx
    mov edi, jpeg_z0
    mov ecx, (jpeg_z1 - jpeg_z0) / 4
    xor eax, eax
    rep stosd
    pop ecx
    pop edi
    lea eax, [esi + ecx]
    mov [jpeg_end], eax
    lea eax, [esi + 2]
    mov [jpeg_ptr], eax
    mov eax, -1
    cmp ecx, 4
    jb .r
    cmp word [esi], 0xD8FF
    jne .r
    xor eax, eax
.r:
    ret

; -----------------------------------------------------------------------------
; jpeg_markers: walk the marker segments from [jpeg_ptr]. In mode 0 it stops
; after SOF; in mode 1 it runs to EOI (or the end of the data), decoding each
; scan. EAX = 0 or -1 (bad). Keeps EBX ESI EDI EBP.
; -----------------------------------------------------------------------------
jpeg_markers:
    push ebx
    push esi
    push edi
    push ebp
.next:
    mov esi, [jpeg_ptr]
    mov edi, [jpeg_end]
.find:                                      ; look for FF xx, xx not 00
    cmp esi, edi
    jae .end
    mov al, [esi]
    inc esi
    cmp al, 0xFF
    jne .find
.ff:
    cmp esi, edi
    jae .end
    mov al, [esi]
    inc esi
    cmp al, 0xFF                            ; fill bytes
    je .ff
    test al, al
    jz .find
    cmp al, 0xD9                            ; EOI
    je .end
    cmp al, 0xD8
    je .find
    cmp al, 0x01
    je .find
    mov ah, al
    and ah, 0xF8
    cmp ah, 0xD0                            ; RSTn: no segment
    je .find
    lea edx, [esi + 2]                      ; the length must be there
    cmp edx, edi
    ja .bad
    movzx ecx, word [esi]
    xchg cl, ch
    cmp ecx, 2
    jb .bad
    mov edx, edi
    sub edx, esi
    cmp ecx, edx                            ; the whole segment must be there
    ja .bad
    lea edx, [esi + ecx]
    mov [jpeg_ptr], edx                     ; carry on after it
    add esi, 2                              ; ESI = payload, ECX = its length
    sub ecx, 2
    movzx eax, al
    cmp eax, 0xC4
    je .dht
    cmp eax, 0xDB
    je .dqt
    cmp eax, 0xDD
    je .dri
    cmp eax, 0xDA
    je .sos
    cmp eax, 0xE0
    je .app0
    cmp eax, 0xEE
    je .app14
    cmp eax, 0xC0
    je .sof
    cmp eax, 0xC1
    je .sof
    cmp eax, 0xC2
    je .sof
    cmp eax, 0xC8                           ; JPG (reserved): skip
    je .next
    cmp eax, 0xCC                           ; DAC: skip
    je .next
    mov edx, eax
    and edx, 0xF0
    cmp edx, 0xC0                           ; other SOFn: not supported
    je .bad
    jmp .next                               ; APPn, COM, ...: skip
.dht:
    call jpeg_dht
    jmp .chk
.dqt:
    call jpeg_dqt
    jmp .chk
.dri:
    cmp ecx, 2
    jb .bad
    movzx eax, word [esi]
    xchg al, ah
    mov [jpeg_rsti], eax
    jmp .next
.app0:
    cmp ecx, 5
    jb .next
    cmp dword [esi], 'JFIF'
    jne .next
    cmp byte [esi + 4], 0
    jne .next
    mov dword [jpeg_jfif], 1
    jmp .next
.app14:
    cmp ecx, 12
    jb .next
    cmp dword [esi], 'Adob'
    jne .next
    cmp byte [esi + 4], 'e'
    jne .next
    movzx eax, byte [esi + 11]
    inc eax
    mov [jpeg_adobe], eax
    jmp .next
.sof:
    cmp eax, 0xC2
    sete dl
    movzx edx, dl
    mov [jpeg_prog], edx
    call jpeg_sofseg
    test eax, eax
    js .r
    cmp dword [jpeg_mode], 0
    je .ok
    jmp .next
.sos:
    cmp dword [jpeg_mode], 0                ; (info: SOS before SOF is bad)
    je .bad
    cmp dword [jpeg_nscan], JPEG_MAXSCANS
    jae .end
    call jpeg_sos
    jmp .chk
.chk:
    test eax, eax
    jns .next
.bad:
    mov eax, -1
    jmp .r
.end:
    cmp dword [jpeg_mode], 0                ; info: no SOF found
    je .bad
.ok:
    xor eax, eax
.r:
    pop ebp
    pop edi
    pop esi
    pop ebx
    ret

; jpeg_dht: ESI = DHT payload, ECX = its length -> tables built. EAX = 0 / -1.
jpeg_dht:
.tab:
    test ecx, ecx
    jz .ok
    cmp ecx, 17
    jb .bad
    movzx eax, byte [esi]
    mov edx, eax
    shr edx, 4                              ; class: 0 DC, 1 AC
    and eax, 15
    cmp edx, 1
    ja .bad
    cmp eax, 3
    ja .bad
    lea eax, [eax + edx * 4]                ; table 0-7
    xor edx, edx                            ; EDX = number of symbols
    push ecx
    mov ecx, 16
.sum:
    movzx ebx, byte [esi + ecx]
    add edx, ebx
    dec ecx
    jnz .sum
    pop ecx
    sub ecx, 17
    cmp edx, 256
    ja .bad
    cmp edx, ecx
    ja .bad
    sub ecx, edx
    push ecx
    push edx
    push esi
    mov dword [jpeg_hok + eax * 4], 1
    imul eax, eax, JH_SIZE
    lea ebx, [jpeg_huf + eax]
    inc esi                                 ; ESI = the 16 counts
    call jpeg_build
    pop esi
    pop edx
    pop ecx
    test eax, eax
    js .bad
    lea esi, [esi + edx + 17]
    jmp .tab
.ok:
    xor eax, eax
    ret
.bad:
    mov eax, -1
    ret

; jpeg_build: EBX = Huffman table, ESI = 16 code counts followed by the
; symbols -> the table filled. EAX = 0, or -1 if the counts overflow the
; code space. Keeps EBX ESI.
jpeg_build:
    push esi
    push edi
    push ebp
    mov edi, ebx                            ; clear the lookup
    mov ecx, 512
    xor eax, eax
    rep stosd
    xor edx, edx                            ; EDX = total symbols
    xor ecx, ecx
.tot:
    movzx eax, byte [esi + ecx]
    add edx, eax
    inc ecx
    cmp ecx, 16
    jb .tot
    xor ecx, ecx
.cpy:
    cmp ecx, edx
    jae .cpz
    mov al, [esi + 16 + ecx]
    mov [ebx + JH_VALS + ecx], al
    inc ecx
    jmp .cpy
.cpz:
    xor edx, edx                            ; EDX = next code
    xor edi, edi                            ; EDI = next symbol index
    mov ecx, 1                              ; ECX = code length
.len:
    mov eax, edi
    sub eax, edx
    mov [ebx + JH_OFF + ecx * 4], eax
    movzx ebp, byte [esi + ecx - 1]         ; EBP = codes of this length
    mov dword [ebx + JH_MAX + ecx * 4], -1
    test ebp, ebp
    jz .shift
.code:
    mov eax, 1
    shl eax, cl
    cmp edx, eax                            ; code space used up?
    jae .bad
    cmp ecx, 9
    ja .long
    push ecx                                ; LUT[code << (9 - len) ...] = entry
    push edx
    neg ecx
    add ecx, 9
    shl edx, cl
    mov eax, 1
    shl eax, cl                             ; EAX = entries
    mov ecx, [esp + 4]
    shl ecx, 8
    push ebx
    movzx ebx, byte [ebx + JH_VALS + edi]
    or ecx, ebx
    pop ebx
.fill:
    mov [ebx + JH_LUT + edx * 4], ecx
    inc edx
    dec eax
    jnz .fill
    pop edx
    pop ecx
.long:
    inc edx
    inc edi
    dec ebp
    jnz .code
    lea eax, [edx - 1]
    mov [ebx + JH_MAX + ecx * 4], eax
.shift:
    shl edx, 1
    inc ecx
    cmp ecx, 16
    jbe .len
    xor eax, eax
    jmp .r
.bad:
    mov eax, -1
.r:
    pop ebp
    pop edi
    pop esi
    ret

; jpeg_dqt: ESI = DQT payload, ECX = its length -> tables stored. EAX = 0 / -1.
jpeg_dqt:
.tab:
    test ecx, ecx
    jz .ok
    movzx eax, byte [esi]
    mov edx, eax
    shr edx, 4                              ; 0: 8-bit values, 1: 16-bit
    and eax, 15
    cmp eax, 3
    ja .bad
    cmp edx, 1
    ja .bad
    mov dword [jpeg_qok + eax * 4], 1
    shl eax, 8
    lea edi, [jpeg_qt + eax]
    inc esi
    dec ecx
    push ebx
    xor ebx, ebx                            ; EBX = k (zigzag)
    test edx, edx
    jnz .w16
    cmp ecx, 64
    jb .badp
.b8:
    movzx eax, byte [esi + ebx]
    movzx edx, byte [jpeg_nat + ebx]
    mov [edi + edx * 4], eax
    inc ebx
    cmp ebx, 64
    jb .b8
    add esi, 64
    sub ecx, 64
    pop ebx
    jmp .tab
.w16:
    cmp ecx, 128
    jb .badp
.b16:
    movzx eax, word [esi + ebx * 2]
    xchg al, ah
    movzx edx, byte [jpeg_nat + ebx]
    mov [edi + edx * 4], eax
    inc ebx
    cmp ebx, 64
    jb .b16
    add esi, 128
    sub ecx, 128
    pop ebx
    jmp .tab
.badp:
    pop ebx
.bad:
    mov eax, -1
    ret
.ok:
    xor eax, eax
    ret

; jpeg_sofseg: ESI = SOF payload, ECX = its length -> geometry, components,
; work layout. EAX = 0, -1 bad, -2 work too small (decode).
jpeg_sofseg:
    push ebx
    push esi
    push edi
    push ebp
    cmp dword [jpeg_sof], 0                 ; only one frame
    jne .bad
    cmp ecx, 6
    jb .bad
    cmp byte [esi], 8                       ; 8-bit samples only
    jne .bad
    movzx eax, word [esi + 1]
    xchg al, ah
    mov [jpeg_h], eax
    test eax, eax
    jz .bad
    cmp eax, JPEG_MAXDIM
    ja .bad
    movzx eax, word [esi + 3]
    xchg al, ah
    mov [jpeg_w], eax
    test eax, eax
    jz .bad
    cmp eax, JPEG_MAXDIM
    ja .bad
    movzx eax, byte [esi + 5]
    mov [jpeg_ncomp], eax
    cmp eax, 1
    je .nc
    cmp eax, 3
    jne .bad
.nc:
    lea edx, [eax + eax * 2 + 6]
    cmp ecx, edx
    jb .bad
    add esi, 6
    mov ebx, jpeg_comp
    xor edi, edi                            ; EDI = component number
.comp:
    movzx eax, byte [esi]
    mov [ebx + JC_ID], eax
    movzx eax, byte [esi + 1]
    mov edx, eax
    shr eax, 4
    and edx, 15
    cmp eax, 1
    jb .bad
    cmp eax, 4
    ja .bad
    cmp edx, 1
    jb .bad
    cmp edx, 4
    ja .bad
    mov [ebx + JC_H], eax
    mov [ebx + JC_V], edx
    cmp eax, [jpeg_hmax]
    jbe .h1
    mov [jpeg_hmax], eax
.h1:
    cmp edx, [jpeg_vmax]
    jbe .v1
    mov [jpeg_vmax], edx
.v1:
    movzx eax, byte [esi + 2]
    cmp eax, 3
    ja .bad
    mov [ebx + JC_TQ], eax
    mov eax, edi                            ; its latched table
    shl eax, 8
    add eax, jpeg_cq
    mov [ebx + JC_QT], eax
    add esi, 3
    add ebx, JC_SIZE
    inc edi
    cmp edi, [jpeg_ncomp]
    jb .comp
    ; MCUs: 8 * Hmax by 8 * Vmax samples
    mov eax, [jpeg_hmax]
    shl eax, 3
    mov ecx, eax
    mov eax, [jpeg_w]
    add eax, ecx
    dec eax
    xor edx, edx
    div ecx
    mov [jpeg_mcux], eax
    mov eax, [jpeg_vmax]
    shl eax, 3
    mov ecx, eax
    mov eax, [jpeg_h]
    add eax, ecx
    dec eax
    xor edx, edx
    div ecx
    mov [jpeg_mcuy], eax
    ; per component sizes; EBP = bytes of work
    xor ebp, ebp
    mov ebx, jpeg_comp
    xor edi, edi
.csz:
    mov eax, [jpeg_hmax]                    ; SX = Hmax / H, whole
    xor edx, edx
    div dword [ebx + JC_H]
    test edx, edx
    jnz .bad
    mov [ebx + JC_SX], eax
    mov eax, [jpeg_vmax]
    xor edx, edx
    div dword [ebx + JC_V]
    test edx, edx
    jnz .bad
    mov [ebx + JC_SY], eax
    mov eax, [jpeg_mcux]
    imul eax, [ebx + JC_H]
    mov [ebx + JC_BW], eax
    mov eax, [jpeg_mcuy]
    imul eax, [ebx + JC_V]
    mov [ebx + JC_BH], eax
    mov eax, [jpeg_w]                       ; DW = ceil(W / SX)
    add eax, [ebx + JC_SX]
    dec eax
    xor edx, edx
    div dword [ebx + JC_SX]
    mov [ebx + JC_DW], eax
    add eax, 7
    shr eax, 3
    mov [ebx + JC_NBW], eax
    mov eax, [jpeg_h]
    add eax, [ebx + JC_SY]
    dec eax
    xor edx, edx
    div dword [ebx + JC_SY]
    mov [ebx + JC_DH], eax
    add eax, 7
    shr eax, 3
    mov [ebx + JC_NBH], eax
    mov eax, [ebx + JC_BW]                  ; plane
    imul eax, [ebx + JC_BH]
    shl eax, 6
    add ebp, eax
    cmp dword [jpeg_prog], 0                ; coefficients
    je .np
    add ebp, eax
    add ebp, eax
.np:
    mov eax, [jpeg_mcux]                    ; upsampled row
    imul eax, [jpeg_hmax]
    lea ebp, [ebp + eax * 8 + 16]
    add ebx, JC_SIZE
    inc edi
    cmp edi, [jpeg_ncomp]
    jb .csz
    add ebp, 64
    mov [jpeg_need], ebp
    ; colour space: 3 components are YCbCr unless the file says RGB
    cmp dword [jpeg_ncomp], 3
    jne .cs
    cmp dword [jpeg_jfif], 0
    jne .cs
    mov eax, [jpeg_adobe]
    test eax, eax
    jz .ids
    cmp eax, 1                              ; Adobe transform 0: RGB
    jne .cs
    mov dword [jpeg_rgb], 1
    jmp .cs
.ids:
    cmp dword [jpeg_comp + JC_ID], 'R'
    jne .cs
    cmp dword [jpeg_comp + JC_SIZE + JC_ID], 'G'
    jne .cs
    cmp dword [jpeg_comp + 2 * JC_SIZE + JC_ID], 'B'
    jne .cs
    mov dword [jpeg_rgb], 1
.cs:
    mov dword [jpeg_sof], 1
    cmp dword [jpeg_mode], 0
    je .ok
    ; decode: lay the work buffer out
    mov eax, -2
    cmp ebp, [jpeg_wsize]
    ja .r
    mov ebp, [jpeg_work]
    add ebp, 15
    and ebp, -16
    mov ebx, jpeg_comp
    xor edi, edi
.lay:
    mov [ebx + JC_PLANE], ebp
    mov ecx, [ebx + JC_BW]
    imul ecx, [ebx + JC_BH]
    shl ecx, 4                              ; dwords
    push edi
    mov edi, ebp
    mov eax, 0x80808080                     ; mid grey until decoded
    rep stosd
    mov ebp, edi
    pop edi
    cmp dword [jpeg_prog], 0
    je .lay2
    mov [ebx + JC_COEF], ebp
    mov ecx, [ebx + JC_BW]
    imul ecx, [ebx + JC_BH]
    shl ecx, 5                              ; dwords
    push edi
    mov edi, ebp
    xor eax, eax
    rep stosd
    mov ebp, edi
    pop edi
.lay2:
    mov [ebx + JC_ROW], ebp
    mov eax, [jpeg_mcux]
    imul eax, [jpeg_hmax]
    lea ebp, [ebp + eax * 8 + 16]
    add ebx, JC_SIZE
    inc edi
    cmp edi, [jpeg_ncomp]
    jb .lay
.ok:
    xor eax, eax
    jmp .r
.bad:
    mov eax, -1
.r:
    pop ebp
    pop edi
    pop esi
    pop ebx
    ret

; jpeg_sos: ESI = SOS payload, ECX = its length; [jpeg_ptr] = the entropy-
; coded data after it -> the scan decoded, [jpeg_ptr] where it stopped.
; EAX = 0 / -1.
jpeg_sos:
    push ebx
    push esi
    push edi
    push ebp
    cmp dword [jpeg_sof], 0
    je .bad
    cmp ecx, 1
    jb .bad
    movzx eax, byte [esi]
    test eax, eax
    jz .bad
    cmp eax, [jpeg_ncomp]
    ja .bad
    mov [jpeg_ns], eax
    lea edx, [eax * 2 + 4]
    cmp ecx, edx
    jb .bad
    inc esi
    xor edi, edi                            ; EDI = scan component number
.sc:
    movzx eax, byte [esi]                   ; find the component by id
    mov ebx, jpeg_comp
    xor ecx, ecx
.fid:
    cmp [ebx + JC_ID], eax
    je .fnd
    add ebx, JC_SIZE
    inc ecx
    cmp ecx, [jpeg_ncomp]
    jb .fid
    jmp .bad
.fnd:
    xor ecx, ecx                            ; not twice in one scan
.dup:
    cmp ecx, edi
    jae .new
    cmp [jpeg_sc + ecx * 4], ebx
    je .bad
    inc ecx
    jmp .dup
.new:
    mov [jpeg_sc + edi * 4], ebx
    movzx eax, byte [esi + 1]
    mov edx, eax
    shr edx, 4                              ; DC table
    and eax, 15                             ; AC table
    cmp edx, 3
    ja .bad
    cmp eax, 3
    ja .bad
    mov [ebx + JC_DCT], edx                 ; (numbers for now)
    add eax, 4
    mov [ebx + JC_ACT], eax
    add esi, 2
    inc edi
    cmp edi, [jpeg_ns]
    jb .sc
    movzx eax, byte [esi]
    mov [jpeg_ss], eax
    movzx eax, byte [esi + 1]
    mov [jpeg_se], eax
    movzx eax, byte [esi + 2]
    mov edx, eax
    shr edx, 4
    and eax, 15
    mov [jpeg_ah], edx
    mov [jpeg_al], eax
    ; which kind of scan, and its checks
    cmp dword [jpeg_prog], 0
    jne .prog
    mov dword [jpeg_ss], 0                  ; baseline: always the whole block
    mov dword [jpeg_se], 63
    mov dword [jpeg_blkfn], jpeg_blk_base
    mov ebp, 3                              ; EBP bit 0: DC table, bit 1: AC table
    jmp .tabs
.prog:
    mov eax, [jpeg_ss]
    mov edx, [jpeg_se]
    cmp edx, 63
    ja .bad
    cmp eax, edx
    ja .bad
    cmp dword [jpeg_ah], 13
    ja .bad
    cmp dword [jpeg_al], 13
    ja .bad
    test eax, eax
    jnz .pac
    test edx, edx                           ; DC scans have Se = 0
    jnz .bad
    xor ebp, ebp
    mov dword [jpeg_blkfn], jpeg_blk_dcref
    cmp dword [jpeg_ah], 0
    jne .tabs
    mov ebp, 1
    mov dword [jpeg_blkfn], jpeg_blk_dc
    jmp .tabs
.pac:
    cmp dword [jpeg_ns], 1                  ; AC scans have one component
    jne .bad
    mov ebp, 2
    mov dword [jpeg_blkfn], jpeg_blk_ac
    cmp dword [jpeg_ah], 0
    je .tabs
    mov dword [jpeg_blkfn], jpeg_blk_acref
.tabs:
    ; table numbers -> pointers (the needed ones must be defined); latch
    ; quantisation tables; at most 10 blocks per interleaved MCU
    xor edi, edi
    xor esi, esi                            ; ESI = blocks per MCU
.tb:
    mov ebx, [jpeg_sc + edi * 4]
    mov eax, [ebx + JC_DCT]
    test ebp, 1
    jz .tb1
    cmp dword [jpeg_hok + eax * 4], 0
    je .bad
.tb1:
    imul eax, eax, JH_SIZE
    add eax, jpeg_huf
    mov [ebx + JC_DCT], eax
    mov eax, [ebx + JC_ACT]
    test ebp, 2
    jz .tb2
    cmp dword [jpeg_hok + eax * 4], 0
    je .bad
.tb2:
    imul eax, eax, JH_SIZE
    add eax, jpeg_huf
    mov [ebx + JC_ACT], eax
    cmp dword [ebx + JC_QOK], 0
    jne .tb3
    mov eax, [ebx + JC_TQ]
    cmp dword [jpeg_qok + eax * 4], 0
    je .bad
    push esi
    push edi
    mov esi, eax
    shl esi, 8
    add esi, jpeg_qt
    mov edi, [ebx + JC_QT]
    mov ecx, 64
    rep movsd
    pop edi
    pop esi
    mov dword [ebx + JC_QOK], 1
.tb3:
    mov eax, [ebx + JC_H]
    imul eax, [ebx + JC_V]
    add esi, eax
    inc edi
    cmp edi, [jpeg_ns]
    jb .tb
    cmp dword [jpeg_ns], 1
    je .go
    cmp esi, 10
    ja .bad
.go:
    inc dword [jpeg_nscan]
    call jpeg_scan
    xor eax, eax
    jmp .r
.bad:
    mov eax, -1
.r:
    pop ebp
    pop edi
    pop esi
    pop ebx
    ret

; jpeg_scan: decode the entropy-coded data of the scan set up by jpeg_sos.
jpeg_scan:
    push ebx
    push esi
    push edi
    push ebp
    xor eax, eax
    mov [jpeg_bbuf], eax
    mov [jpeg_bcnt], eax
    mov [jpeg_mark], eax
    mov [jpeg_eobrun], eax
    call jpeg_preds0
    mov eax, [jpeg_rsti]
    mov [jpeg_rstleft], eax
    cmp dword [jpeg_ns], 1
    jne .il
    mov ebx, [jpeg_sc]                      ; one component: one block per MCU
    mov eax, [ebx + JC_NBW]
    mov [jpeg_nmx], eax
    mov eax, [ebx + JC_NBH]
    mov [jpeg_nmy], eax
    jmp .rows
.il:
    mov eax, [jpeg_mcux]
    mov [jpeg_nmx], eax
    mov eax, [jpeg_mcuy]
    mov [jpeg_nmy], eax
.rows:
    mov dword [jpeg_my], 0
.my:
    mov dword [jpeg_mx], 0
.mx:
    cmp dword [jpeg_rsti], 0
    je .mcu
    cmp dword [jpeg_rstleft], 0
    jne .rs1
    call jpeg_restart
    mov eax, [jpeg_rsti]
    mov [jpeg_rstleft], eax
.rs1:
    dec dword [jpeg_rstleft]
.mcu:
    cmp dword [jpeg_ns], 1
    jne .mcu_il
    mov ebx, [jpeg_sc]
    mov ecx, [jpeg_mx]
    mov edx, [jpeg_my]
    call [jpeg_blkfn]
    jmp .mnext
.mcu_il:
    xor edi, edi                            ; EDI = scan component
.mc:
    mov ebx, [jpeg_sc + edi * 4]
    xor esi, esi                            ; ESI = v
.mv:
    xor ebp, ebp                            ; EBP = h
.mh:
    mov ecx, [jpeg_mx]
    imul ecx, [ebx + JC_H]
    add ecx, ebp
    mov edx, [jpeg_my]
    imul edx, [ebx + JC_V]
    add edx, esi
    call [jpeg_blkfn]
    inc ebp
    cmp ebp, [ebx + JC_H]
    jb .mh
    inc esi
    cmp esi, [ebx + JC_V]
    jb .mv
    inc edi
    cmp edi, [jpeg_ns]
    jb .mc
.mnext:
    inc dword [jpeg_mx]
    mov eax, [jpeg_mx]
    cmp eax, [jpeg_nmx]
    jb .mx
    inc dword [jpeg_my]
    mov eax, [jpeg_my]
    cmp eax, [jpeg_nmy]
    jb .my
    pop ebp
    pop edi
    pop esi
    pop ebx
    ret

; jpeg_preds0: DC predictions of all components = 0.
jpeg_preds0:
    mov dword [jpeg_comp + JC_PRED], 0
    mov dword [jpeg_comp + JC_SIZE + JC_PRED], 0
    mov dword [jpeg_comp + 2 * JC_SIZE + JC_PRED], 0
    mov dword [jpeg_comp + 3 * JC_SIZE + JC_PRED], 0
    ret

; jpeg_restart: at a restart interval: bit reader, predictions and EOB run
; reset, and the RSTn marker skipped (if the next marker is another one, it
; is left for the marker walk; the rest of the scan then reads zeros).
jpeg_restart:
    push esi
    xor eax, eax
    mov [jpeg_bbuf], eax
    mov [jpeg_bcnt], eax
    mov [jpeg_mark], eax
    mov [jpeg_eobrun], eax
    call jpeg_preds0
    mov esi, [jpeg_ptr]
.f:
    lea eax, [esi + 1]
    cmp eax, [jpeg_end]
    jae .eod
    cmp byte [esi], 0xFF
    jne .n
    mov al, [esi + 1]
    test al, al
    jz .n
    cmp al, 0xFF
    je .n
    and al, 0xF8
    cmp al, 0xD0
    jne .other
    add esi, 2
    jmp .set
.n:
    inc esi
    jmp .f
.other:
    mov dword [jpeg_mark], 1
    jmp .set
.eod:
    mov esi, [jpeg_end]
    mov dword [jpeg_mark], 1
.set:
    mov [jpeg_ptr], esi
    pop esi
    ret

; -----------------------------------------------------------------------------
; Bit reader. jpeg_fill: at least 25 valid bits in jpeg_bbuf (zeros once a
; marker or the end is reached; FF 00 is a data byte FF). Keeps registers.
; -----------------------------------------------------------------------------
jpeg_fill:
    cmp dword [jpeg_bcnt], 24
    ja .q
    push eax
    push ecx
    push esi
    mov ecx, [jpeg_bcnt]
    mov esi, [jpeg_ptr]
.byte:
    xor eax, eax
    cmp dword [jpeg_mark], 0
    jne .put
    cmp esi, [jpeg_end]
    jae .stop
    mov al, [esi]
    inc esi
    cmp al, 0xFF
    jne .put
    cmp esi, [jpeg_end]
    jae .stopff
    cmp byte [esi], 0
    jne .stopff
    inc esi
    jmp .put
.stopff:
    dec esi                                 ; leave the marker's FF
.stop:
    mov dword [jpeg_mark], 1
    xor eax, eax
.put:
    push ecx
    neg ecx
    add ecx, 24
    shl eax, cl
    pop ecx
    or [jpeg_bbuf], eax
    add ecx, 8
    cmp ecx, 24
    jbe .byte
    mov [jpeg_bcnt], ecx
    mov [jpeg_ptr], esi
    pop esi
    pop ecx
    pop eax
.q:
    ret

; jpeg_bits: ECX = n (0-16) -> EAX = the next n bits. Keeps other registers.
jpeg_bits:
    xor eax, eax
    test ecx, ecx
    jz .r
    call jpeg_fill
    mov eax, [jpeg_bbuf]
    shl dword [jpeg_bbuf], cl
    sub [jpeg_bcnt], ecx
    push ecx
    neg ecx
    add ecx, 32
    shr eax, cl
    pop ecx
.r:
    ret

; jpeg_getext: ECX = s (0-15) -> EAX = the next s bits as a signed
; coefficient (JPEG's "receive and extend"). Keeps other registers.
jpeg_getext:
    test ecx, ecx
    jz .zero
    call jpeg_bits
    push edx
    mov edx, 1
    dec ecx
    shl edx, cl
    inc ecx
    cmp eax, edx
    jae .pos
    inc eax                                 ; v - 2^s + 1
    sub eax, edx
    sub eax, edx
.pos:
    pop edx
    ret
.zero:
    xor eax, eax
    ret

; jpeg_huff: EAX = Huffman table -> EAX = next symbol (0 for a bad code).
; Keeps other registers.
jpeg_huff:
    call jpeg_fill
    push ecx
    push edx
    push esi
    mov esi, eax
    mov edx, [jpeg_bbuf]
    mov eax, edx
    shr eax, 23
    mov eax, [esi + JH_LUT + eax * 4]
    test eax, eax
    jz .slow
    mov ecx, eax
    shr ecx, 8
    shl edx, cl
    mov [jpeg_bbuf], edx
    sub [jpeg_bcnt], ecx
    and eax, 0xFF
    jmp .r
.slow:
    mov ecx, 10
.l:
    mov eax, edx
    push ecx
    neg ecx
    add ecx, 32
    shr eax, cl
    pop ecx
    cmp eax, [esi + JH_MAX + ecx * 4]
    jle .found
    inc ecx
    cmp ecx, 16
    jbe .l
    xor eax, eax
    jmp .r
.found:
    add eax, [esi + JH_OFF + ecx * 4]
    and eax, 0xFF
    movzx eax, byte [esi + JH_VALS + eax]
    shl edx, cl
    mov [jpeg_bbuf], edx
    sub [jpeg_bcnt], ecx
.r:
    pop esi
    pop edx
    pop ecx
    ret

; -----------------------------------------------------------------------------
; Block decoders: EBX = component, ECX = block column, EDX = block row.
; They may change EAX ECX EDX; keep EBX ESI EDI EBP.
; -----------------------------------------------------------------------------

; jpeg_blk_base: baseline block, decoded and transformed into the plane.
jpeg_blk_base:
    push esi
    push edi
    push ecx
    push edx
    mov edi, jpeg_blk
    mov ecx, 32
    xor eax, eax
    rep stosd
    mov eax, [ebx + JC_DCT]
    call jpeg_huff
    mov ecx, eax
    and ecx, 15
    call jpeg_getext
    add eax, [ebx + JC_PRED]
    mov [ebx + JC_PRED], eax
    mov [jpeg_blk], ax
    mov esi, 1                              ; ESI = k
.ac:
    mov eax, [ebx + JC_ACT]
    call jpeg_huff
    mov ecx, eax
    shr eax, 4                              ; run
    and ecx, 15                             ; size
    jz .zs
    add esi, eax
    call jpeg_getext
    movzx edx, byte [jpeg_nat + esi]
    mov [jpeg_blk + edx * 2], ax
    inc esi
    cmp esi, 64
    jb .ac
    jmp .idct
.zs:
    cmp eax, 15                             ; ZRL: 16 zeros
    jne .idct                               ; EOB
    add esi, 16
    cmp esi, 64
    jb .ac
.idct:
    pop edx
    pop ecx
    mov edi, [ebx + JC_BW]                  ; EDI = plane + (row * BW * 8 + col) * 8
    shl edi, 3
    imul edx, edi                           ; EDX = row * stride (rows of 8)
    shl edx, 3
    lea edi, [edx + ecx * 8]
    add edi, [ebx + JC_PLANE]
    mov edx, [ebx + JC_BW]
    shl edx, 3
    mov esi, jpeg_blk
    push ebx
    mov ebx, [ebx + JC_QT]
    call jpeg_idct
    pop ebx
    pop edi
    pop esi
    ret

; jpeg_coefp: EBX = component, ECX = column, EDX = row -> EDI = its
; coefficients. Changes EDX.
jpeg_coefp:
    imul edx, [ebx + JC_BW]
    add edx, ecx
    shl edx, 7
    mov edi, [ebx + JC_COEF]
    add edi, edx
    ret

; jpeg_blk_dc: progressive, first DC scan of a block.
jpeg_blk_dc:
    push edi
    call jpeg_coefp
    mov eax, [ebx + JC_DCT]
    call jpeg_huff
    mov ecx, eax
    and ecx, 15
    call jpeg_getext
    add eax, [ebx + JC_PRED]
    mov [ebx + JC_PRED], eax
    mov ecx, [jpeg_al]
    shl eax, cl
    mov [edi], ax
    pop edi
    ret

; jpeg_blk_dcref: progressive, DC refinement: one more bit.
jpeg_blk_dcref:
    push edi
    call jpeg_coefp
    mov ecx, 1
    call jpeg_bits
    test eax, eax
    jz .r
    mov ecx, [jpeg_al]
    mov eax, 1
    shl eax, cl
    or [edi], ax
.r:
    pop edi
    ret

; jpeg_blk_ac: progressive, first AC scan (band Ss..Se) of a block.
jpeg_blk_ac:
    push esi
    push edi
    call jpeg_coefp
    cmp dword [jpeg_eobrun], 0
    je .go
    dec dword [jpeg_eobrun]
    jmp .r
.go:
    mov esi, [jpeg_ss]                      ; ESI = k
.k:
    cmp esi, [jpeg_se]
    ja .r
    mov eax, [ebx + JC_ACT]
    call jpeg_huff
    mov ecx, eax
    shr eax, 4                              ; r
    and ecx, 15                             ; s
    jz .zs
    add esi, eax
    call jpeg_getext
    mov ecx, [jpeg_al]
    shl eax, cl
    movzx edx, byte [jpeg_nat + esi]
    mov [edi + edx * 2], ax
    inc esi
    jmp .k
.zs:
    cmp eax, 15
    jne .eob
    add esi, 16
    jmp .k
.eob:
    mov ecx, eax                            ; EOB run = 2^r + r bits - 1
    mov edx, 1
    shl edx, cl
    call jpeg_bits
    add eax, edx
    dec eax
    mov [jpeg_eobrun], eax
.r:
    pop edi
    pop esi
    ret

; jpeg_blk_acref: progressive, AC refinement scan of a block (G.1.2.3).
jpeg_blk_acref:
    push esi
    push edi
    push ebp
    call jpeg_coefp
    mov ecx, [jpeg_al]
    mov ebp, 1
    shl ebp, cl                             ; EBP = p1 (m1 = -p1)
    mov esi, [jpeg_ss]                      ; ESI = k
    cmp dword [jpeg_eobrun], 0
    jne .eobpart
.k:
    cmp esi, [jpeg_se]
    ja .done
    mov eax, [ebx + JC_ACT]
    call jpeg_huff
    mov ecx, eax
    shr eax, 4                              ; EAX = r
    and ecx, 15
    jz .zs
    push eax                                ; s != 0: new coefficient +-p1
    mov ecx, 1
    call jpeg_bits
    mov edx, ebp
    test eax, eax
    jnz .sgn
    neg edx
.sgn:
    pop eax
    jmp .adv
.zs:
    xor edx, edx                            ; EDX = new value (0: none)
    cmp eax, 15
    je .adv                                 ; ZRL
    mov ecx, eax                            ; EOB run
    push edx
    mov edx, 1
    shl edx, cl
    call jpeg_bits
    add eax, edx
    pop edx
    mov [jpeg_eobrun], eax
    jmp .eobpart
.adv:
    ; skip r zero coefficients (correcting the nonzero ones passed on the
    ; way), stop at the next zero one
    mov ecx, eax                            ; ECX = r
.adl:
    movzx eax, byte [jpeg_nat + esi]
    cmp word [edi + eax * 2], 0
    je .zero
    call jpeg_corr
    jmp .adn
.zero:
    dec ecx
    js .adx
.adn:
    inc esi
    cmp esi, [jpeg_se]
    jbe .adl
.adx:
    test edx, edx
    jz .nx
    movzx eax, byte [jpeg_nat + esi]
    mov [edi + eax * 2], dx
.nx:
    inc esi
    jmp .k
.eobpart:
    ; in an EOB run: correction bits for the nonzero coefficients left
.el:
    cmp esi, [jpeg_se]
    ja .eobd
    movzx eax, byte [jpeg_nat + esi]
    cmp word [edi + eax * 2], 0
    je .en
    call jpeg_corr
.en:
    inc esi
    jmp .el
.eobd:
    dec dword [jpeg_eobrun]
.done:
    pop ebp
    pop edi
    pop esi
    ret

; jpeg_corr: EDI + EAX * 2 = a nonzero coefficient, EBP = p1 -> one
; correction bit read; if set (and the bit is not set yet) the size grows
; by p1. Keeps ECX EDX.
jpeg_corr:
    push ecx
    push edx
    lea edx, [edi + eax * 2]
    mov ecx, 1
    call jpeg_bits
    test eax, eax
    jz .r
    movsx eax, word [edx]
    test eax, ebp
    jnz .r
    test eax, eax
    js .neg
    add eax, ebp
    jmp .st
.neg:
    sub eax, ebp
.st:
    mov [edx], ax
.r:
    pop edx
    pop ecx
    ret

; jpeg_idct_all: progressive: transform every block of every component.
jpeg_idct_all:
    push ebx
    push esi
    push edi
    push ebp
    mov ebx, jpeg_comp
    mov ebp, [jpeg_ncomp]
.c:
    mov esi, [ebx + JC_COEF]
    mov edx, [ebx + JC_BW]
    shl edx, 3                              ; EDX = plane stride
    xor eax, eax                            ; EAX = block row
.r:
    push eax
    mov edi, eax
    imul edi, edx
    shl edi, 3
    add edi, [ebx + JC_PLANE]
    mov ecx, [ebx + JC_BW]
.b:
    push ebx
    push ecx
    mov ebx, [ebx + JC_QT]
    call jpeg_idct
    pop ecx
    pop ebx
    add esi, 128
    add edi, 8
    dec ecx
    jnz .b
    pop eax
    inc eax
    cmp eax, [ebx + JC_BH]
    jb .r
    add ebx, JC_SIZE
    dec ebp
    jnz .c
    pop ebp
    pop edi
    pop esi
    pop ebx
    ret

; -----------------------------------------------------------------------------
; jpeg_idct: ESI = 64 coefficients (int16, natural order), EBX = their
; quantisation table (64 dwords), EDI = top-left sample, EDX = bytes per
; row -> 8x8 samples. libjpeg's jpeg_idct_islow (Loeffler, Ligtenberg and
; Moschytz, 13-bit constants, 2 extra bits between the passes). Keeps all
; registers.
; -----------------------------------------------------------------------------
%macro JLD 3                                ; reg, index, pass
%if %3 == 1
    movsx %1, word [esi + %2 * 16]
    imul %1, [ebx + %2 * 32]
%else
    mov %1, [esi + %2 * 4]
%endif
%endmacro

%macro JCORE 1                              ; one 8-point transform -> t0-t3, t10-t13
    JLD eax, 2, %1                          ; even part
    JLD edx, 6, %1
    lea ecx, [eax + edx]
    imul ecx, ecx, 4433                     ; z1 = (z2 + z3) * 0.541196100
    imul edx, edx, -15137
    add edx, ecx                            ; tmp2 = z1 - z3 * 1.847759065
    imul eax, eax, 6270
    add eax, ecx                            ; tmp3 = z1 + z2 * 0.765366865
    mov [jpeg_t2], edx
    mov [jpeg_t3], eax
    JLD eax, 0, %1
    JLD edx, 4, %1
    lea ecx, [eax + edx]
    shl ecx, 13                             ; tmp0
    sub eax, edx
    shl eax, 13                             ; tmp1
    mov edx, ecx
    add ecx, [jpeg_t3]
    sub edx, [jpeg_t3]
    mov [jpeg_t10], ecx
    mov [jpeg_t13], edx
    mov ecx, eax
    add eax, [jpeg_t2]
    sub ecx, [jpeg_t2]
    mov [jpeg_t11], eax
    mov [jpeg_t12], ecx
    JLD eax, 7, %1                          ; odd part: tmp0..tmp3
    JLD ecx, 5, %1
    JLD edx, 3, %1
    JLD ebp, 1, %1
    mov [jpeg_z1v], eax
    add [jpeg_z1v], ebp                     ; z1 = tmp0 + tmp3
    mov [jpeg_z2v], ecx
    add [jpeg_z2v], edx                     ; z2 = tmp1 + tmp2
    mov [jpeg_z3v], eax
    add [jpeg_z3v], edx                     ; z3 = tmp0 + tmp2
    mov [jpeg_z4v], ecx
    add [jpeg_z4v], ebp                     ; z4 = tmp1 + tmp3
    imul eax, eax, 2446
    imul ecx, ecx, 16819
    imul edx, edx, 25172
    imul ebp, ebp, 12299
    mov [jpeg_t0], eax
    mov [jpeg_t1], ecx
    mov [jpeg_t2], edx
    mov [jpeg_t3], ebp
    mov eax, [jpeg_z3v]
    add eax, [jpeg_z4v]
    imul eax, eax, 9633                     ; z5
    imul ecx, [jpeg_z3v], -16069
    add ecx, eax                            ; z3
    imul edx, [jpeg_z4v], -3196
    add edx, eax                            ; z4
    imul eax, [jpeg_z1v], -7373             ; z1
    imul ebp, [jpeg_z2v], -20995            ; z2
    add [jpeg_t0], eax
    add [jpeg_t0], ecx
    add [jpeg_t1], ebp
    add [jpeg_t1], edx
    add [jpeg_t2], ebp
    add [jpeg_t2], ecx
    add [jpeg_t3], eax
    add [jpeg_t3], edx
%endmacro

%macro JOUT1 4                              ; tA, tB, row of A + B, row of A - B
    mov eax, [%1]
    mov edx, eax
    add eax, [%2]
    sub edx, [%2]
    add eax, 1 << 10
    sar eax, 11
    add edx, 1 << 10
    sar edx, 11
    mov [edi + %3 * 32], eax
    mov [edi + %4 * 32], edx
%endmacro

%macro JLIM 1                               ; libjpeg's range limit: 10-bit wrap, +128, clamp
    shl %1, 22
    sar %1, 22
    add %1, 128
    cmp %1, 255
    jbe %%ok
    sar %1, 31
    not %1
    and %1, 255
%%ok:
%endmacro

%macro JOUT2 4                              ; tA, tB, column of A + B, column of A - B
    mov eax, [%1]
    mov edx, eax
    add eax, [%2]
    sub edx, [%2]
    add eax, 1 << 17
    sar eax, 18
    add edx, 1 << 17
    sar edx, 18
    JLIM eax
    JLIM edx
    mov [edi + %3], al
    mov [edi + %4], dl
%endmacro

jpeg_idct:
    pushad
    mov [jpeg_ostr], edx
    mov [jpeg_odst], edi
    mov edi, jpeg_ws
    mov dword [jpeg_cnt], 8
.p1:                                        ; columns
    mov ax, [esi + 16]
    or ax, [esi + 32]
    or ax, [esi + 48]
    or ax, [esi + 64]
    or ax, [esi + 80]
    or ax, [esi + 96]
    or ax, [esi + 112]
    jnz .p1full
    movsx eax, word [esi]                   ; only DC: the column is flat
    imul eax, [ebx]
    shl eax, 2
    mov [edi], eax
    mov [edi + 32], eax
    mov [edi + 64], eax
    mov [edi + 96], eax
    mov [edi + 128], eax
    mov [edi + 160], eax
    mov [edi + 192], eax
    mov [edi + 224], eax
    jmp .p1next
.p1full:
    JCORE 1
    JOUT1 jpeg_t10, jpeg_t3, 0, 7
    JOUT1 jpeg_t11, jpeg_t2, 1, 6
    JOUT1 jpeg_t12, jpeg_t1, 2, 5
    JOUT1 jpeg_t13, jpeg_t0, 3, 4
.p1next:
    add esi, 2
    add ebx, 4
    add edi, 4
    dec dword [jpeg_cnt]
    jnz .p1
    mov esi, jpeg_ws                        ; rows
    mov edi, [jpeg_odst]
    mov dword [jpeg_cnt], 8
.p2:
    JCORE 2
    JOUT2 jpeg_t10, jpeg_t3, 0, 7
    JOUT2 jpeg_t11, jpeg_t2, 1, 6
    JOUT2 jpeg_t12, jpeg_t1, 2, 5
    JOUT2 jpeg_t13, jpeg_t0, 3, 4
    add esi, 32
    add edi, [jpeg_ostr]
    dec dword [jpeg_cnt]
    jnz .p2
    popad
    ret

%macro JCLAMP 1
    cmp %1, 255
    jbe %%ok
    sar %1, 31
    not %1
    and %1, 255
%%ok:
%endmacro

; -----------------------------------------------------------------------------
; jpeg_output: upsample and convert every row into [jpeg_out].
; -----------------------------------------------------------------------------
jpeg_output:
    push ebx
    push esi
    push edi
    push ebp
    mov dword [jpeg_y], 0
.row:
    mov ebx, jpeg_comp                      ; each component's row
    xor edi, edi
.cr:
    mov ecx, [jpeg_y]
    call jpeg_uprow
    mov [jpeg_rows + edi * 4], eax
    add ebx, JC_SIZE
    inc edi
    cmp edi, [jpeg_ncomp]
    jb .cr
    mov edi, [jpeg_y]
    imul edi, [jpeg_ostride]
    add edi, [jpeg_out]
    mov esi, [jpeg_rows]
    xor ecx, ecx                            ; ECX = x
    cmp dword [jpeg_ncomp], 1
    jne .three
.grey:
    movzx eax, byte [esi + ecx]
    imul eax, eax, 0x010101
    mov [edi + ecx * 4], eax
    inc ecx
    cmp ecx, [jpeg_w]
    jb .grey
    jmp .next
.three:
    mov ebx, [jpeg_rows + 4]
    mov ebp, [jpeg_rows + 8]
    cmp dword [jpeg_rgb], 0
    je .ycc
.rgb:
    movzx eax, byte [esi + ecx]
    shl eax, 8
    mov al, [ebx + ecx]
    shl eax, 8
    mov al, [ebp + ecx]
    mov [edi + ecx * 4], eax
    inc ecx
    cmp ecx, [jpeg_w]
    jb .rgb
    jmp .next
.ycc:                                       ; libjpeg's ycc_rgb_convert
    push ecx
    movzx eax, byte [ebp + ecx]             ; Cr
    sub eax, 128
    imul edx, eax, 91881                    ; R = Y + (1.40200 Cr + 1/2) >> 16
    add edx, 32768
    sar edx, 16
    imul eax, eax, -46802                   ; G = Y + (-0.34414 Cb - 0.71414 Cr + 1/2) >> 16
    movzx ecx, byte [ebx + ecx]             ; Cb
    sub ecx, 128
    push ecx
    imul ecx, ecx, -22554
    add eax, ecx
    add eax, 32768
    sar eax, 16
    pop ecx
    imul ecx, ecx, 116130                   ; B = Y + (1.77200 Cb + 1/2) >> 16
    add ecx, 32768
    sar ecx, 16
    xchg ecx, [esp]                         ; ECX = x, [esp] = B part
    push ecx
    movzx ecx, byte [esi + ecx]             ; Y
    add edx, ecx
    add eax, ecx
    add ecx, [esp + 4]
    JCLAMP edx
    JCLAMP eax
    JCLAMP ecx
    shl edx, 16
    shl eax, 8
    or eax, edx
    or eax, ecx
    pop ecx
    add esp, 4
    mov [edi + ecx * 4], eax
    inc ecx
    cmp ecx, [jpeg_w]
    jb .ycc
.next:
    inc dword [jpeg_y]
    mov eax, [jpeg_y]
    cmp eax, [jpeg_h]
    jb .row
    pop ebp
    pop edi
    pop esi
    pop ebx
    ret

; jpeg_uprow: EBX = component, ECX = output row -> EAX = that row of the
; component at full resolution (at least jpeg_w samples). Keeps EBX ESI
; EDI EBP.
jpeg_uprow:
    push ebx
    push esi
    push edi
    push ebp
    mov esi, [ebx + JC_PLANE]
    mov ebp, [ebx + JC_BW]
    shl ebp, 3                              ; EBP = plane stride
    mov edi, [ebx + JC_ROW]
    mov eax, [ebx + JC_SX]
    mov edx, [ebx + JC_SY]
    cmp eax, 1
    jne .notcopy
    cmp edx, 1
    jne .notcopy
    imul ecx, ebp                           ; 1:1 - the plane row itself
    lea eax, [esi + ecx]
    jmp .r
.notcopy:
    cmp eax, 2                              ; fancy upsampling where libjpeg uses it
    ja .box
    cmp edx, 2
    ja .box
    cmp eax, 2
    jne .fancy
    cmp dword [ebx + JC_DW], 2
    jbe .box
.fancy:
    cmp edx, 1
    je .h2v1
    ; vertical: near row j = y/2, far row j-1 (even y) or j+1 (odd y)
    mov edx, ecx
    shr edx, 1                              ; EDX = j
    mov eax, edx
    test ecx, 1
    jnz .down
    test eax, eax
    jz .far
    dec eax
    jmp .far
.down:
    inc eax
    cmp eax, [ebx + JC_DH]
    jb .far
    dec eax
.far:
    imul edx, ebp
    add edx, esi                            ; EDX = near row
    imul eax, ebp
    add esi, eax                            ; ESI = far row
    and ecx, 1                              ; ECX = 1 for the lower output row
    cmp dword [ebx + JC_SX], 1
    je .h1v2
    ; h2v2: colsum = 3 near + far; out = (3 cs + cs(-1) + 8) >> 4,
    ; (3 cs + cs(+1) + 7) >> 4, the edges repeated
    mov ebp, [ebx + JC_DW]
    xor ecx, ecx                            ; ECX = i
.h22:
    call .cs                                ; EAX = cs(i)
    push eax
    lea eax, [ecx - 1]
    test ecx, ecx
    jnz .h22a
    xor eax, eax
.h22a:
    push ecx
    mov ecx, eax
    call .cs
    pop ecx
    mov ebx, [esp]
    lea ebx, [ebx + ebx * 2]
    add eax, ebx
    add eax, 8
    shr eax, 4
    mov [edi + ecx * 2], al
    lea eax, [ecx + 1]
    cmp eax, ebp
    jb .h22b
    mov eax, ecx
.h22b:
    push ecx
    mov ecx, eax
    call .cs
    pop ecx
    pop ebx
    lea ebx, [ebx + ebx * 2]
    add eax, ebx
    add eax, 7
    shr eax, 4
    mov [edi + ecx * 2 + 1], al
    inc ecx
    cmp ecx, ebp
    jb .h22
    jmp .done
.cs:                                        ; ECX = i -> EAX = 3 near[i] + far[i]
    movzx eax, byte [edx + ecx]
    lea eax, [eax + eax * 2]
    push ebx
    movzx ebx, byte [esi + ecx]
    add eax, ebx
    pop ebx
    ret
.h1v2:                                      ; out = (3 near + far + 1 + lower) >> 2
    lea ebp, [ecx + 1]                      ; EBP = bias
    mov ecx, [ebx + JC_DW]
    xor ebx, ebx
.h12:
    movzx eax, byte [edx + ebx]
    lea eax, [eax + eax * 2]
    push ecx
    movzx ecx, byte [esi + ebx]
    add eax, ecx
    pop ecx
    add eax, ebp
    shr eax, 2
    mov [edi + ebx], al
    inc ebx
    cmp ebx, ecx
    jb .h12
    jmp .done
.h2v1:                                      ; out = (3 in + left + 1) >> 2, (3 in + right + 2) >> 2
    imul ecx, ebp
    add esi, ecx
    mov ebp, [ebx + JC_DW]
    xor ecx, ecx
.h21:
    movzx eax, byte [esi + ecx]
    lea edx, [eax + eax * 2]
    mov eax, ecx
    test ecx, ecx
    jz .h21a
    dec eax
.h21a:
    movzx eax, byte [esi + eax]
    add eax, edx
    inc eax
    shr eax, 2
    mov [edi + ecx * 2], al
    lea eax, [ecx + 1]
    cmp eax, ebp
    jb .h21b
    mov eax, ecx
.h21b:
    movzx eax, byte [esi + eax]
    add eax, edx
    add eax, 2
    shr eax, 2
    mov [edi + ecx * 2 + 1], al
    inc ecx
    cmp ecx, ebp
    jb .h21
    jmp .done
.box:                                       ; out[x] = plane[y / SY][x / SX]
    mov eax, ecx
    xor edx, edx
    div dword [ebx + JC_SY]
    imul eax, ebp
    add esi, eax
    xor ecx, ecx
.bx:
    mov eax, ecx
    xor edx, edx
    div dword [ebx + JC_SX]
    mov al, [esi + eax]
    mov [edi + ecx], al
    inc ecx
    cmp ecx, [jpeg_w]
    jb .bx
.done:
    mov eax, edi
.r:
    pop ebp
    pop edi
    pop esi
    pop ebx
    ret
