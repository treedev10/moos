; =============================================================================
;  mp4.asm - MP4 demuxer: find the moov box, read its tracks, list the samples
;
;  An MP4 file (ISO/IEC 14496-12 "ISO base media file format", with the
;  MP4 / AVC additions of 14496-14 and -15) is a sequence of boxes. Each box
;  is a 32-bit big-endian size, a four-letter type and a payload; size 1
;  means a 64-bit size follows the type, size 0 means "to the end of the
;  file". Some boxes only contain other boxes. A progressive file such as
;  YouTube's 360p MP4 (itag 18) looks like this:
;
;    ftyp                         brand
;    moov                         everything about the tracks:
;      mvhd                         movie time scale and length
;      trak                         one per track (video, sound)
;        tkhd                         track number
;        edts / elst                  edit list: which part of the media plays
;        mdia
;          mdhd                       the track's time scale and length
;          hdlr                       'vide' or 'soun'
;          minf / stbl                the sample tables:
;            stsd                       codec + its setup (avc1+avcC, mp4a+esds)
;            stts                       decode time of each sample (run lengths)
;            ctts                       composition (display) offsets (B-frames)
;            stss                       which samples are sync (key) frames
;            stsc                       how many samples are in each chunk
;            stsz / stz2                each sample's size
;            stco / co64                each chunk's file offset
;      udta                         titles etc. (ignored)
;    mdat                         the coded frames themselves
;
;  The moov box may come before or after mdat ("faststart" or not), so a
;  player first calls mp4_find_moov on the start of the file, fetches the
;  moov box, and hands it to mp4_parse_moov. That picks the first H.264
;  video track and the first AAC audio track and turns their tables into
;  flat arrays of MP4SAMPLE records (file offset, size, presentation time,
;  sync flag) in the caller's work buffer, which the player can index
;  directly to read and decode frames in order, or to seek.
;
;  Presentation time (pts) = decode time (stts) + composition offset (ctts)
;  - the edit list's start, in the track's time scale, never below 0;
;  samples the edit list hides (they end by time 0) are flagged MP4S_F_PRE,
;  so a player can decode them without showing or playing them. Only
;  the usual edit lists are followed: leading empty edits (the track starts
;  later) and the first real edit's start (skipping encoder delay, e.g. the
;  1024 priming samples of AAC, or the B-frame delay of H.264). Later edits,
;  edit rates other than 1 and fragmented files (moof) are not supported.
;
;  Everything read from the file is checked against the box it is in, so a
;  damaged or hostile file can only make the parse fail, never make it read
;  or write outside the given buffers. Module rules: tests/native/README.md.
; =============================================================================
%include "src/module.inc"

; ---- MP4SAMPLE: one coded frame, 16 bytes ------------------------------------
MP4S_OFF        equ 0               ; file offset of the sample's bytes
MP4S_SIZE       equ 4               ; its size in bytes
MP4S_PTS        equ 8               ; presentation time (track time scale)
MP4S_FLAGS      equ 12              ; MP4S_F_ bits
MP4S_LEN        equ 16
MP4S_F_SYNC     equ 1               ; sync sample: decoding may start here
MP4S_F_PRE      equ 2               ; ends at or before the presentation start (the
                                    ; edit list hides it: decode it, but do not show
                                    ; or play it; e.g. AAC priming, a cut's lead-in)

; ---- MP4INFO: what mp4_parse_moov found (all dwords) ------------------------
; Two track blocks of the same shape (video at MP4I_V, audio at MP4I_A),
; then a few things about the whole file. Pointers point into the caller's
; work buffer, never into the moov data, so the moov buffer may be freed
; after parsing.
MP4T_OK         equ 0               ; 1 = a track MOOS can play (H.264 / AAC)
MP4T_CODEC      equ 4               ; sample entry type: 'avc1', 'mp4a', ...
MP4T_P1         equ 8               ; video: width     audio: sample rate (Hz)
MP4T_P2         equ 12              ; video: height    audio: channels
MP4T_SCALE      equ 16              ; time scale (units per second)
MP4T_DUR        equ 20              ; length in the time scale (edit list applied)
MP4T_CFG        equ 24              ; video: avcC record   audio: AudioSpecificConfig
MP4T_CFGLEN     equ 28
MP4T_P3         equ 32              ; video: NAL length size (1-4)   audio: esds objectTypeIndication
MP4T_P4         equ 36              ; video: first SPS   audio: audio object type (2 = AAC LC)
MP4T_P5         equ 40              ; video: its length
MP4T_P6         equ 44              ; video: first PPS
MP4T_P7         equ 48              ; video: its length
MP4T_N          equ 52              ; number of samples
MP4T_SAMP       equ 56              ; the MP4SAMPLE array
MP4T_EDIT       equ 60              ; (signed) what was taken off dts + ctts to give pts
MP4T_ID         equ 64              ; track number (tkhd)
MP4T_MDUR       equ 68              ; length from mdhd (no edit list)
MP4T_NSYNC      equ 72              ; number of sync samples
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
MP4I_M_SCALE    equ 2 * MP4T_LEN + 0  ; movie time scale (mvhd)
MP4I_M_DUR      equ 2 * MP4T_LEN + 4  ; movie length (mvhd)
MP4I_NEED       equ 2 * MP4T_LEN + 8  ; bytes of work needed (also set on error -2)
MP4I_NTRAK      equ 2 * MP4T_LEN + 12 ; trak boxes seen
MP4I_SIZE       equ 2 * MP4T_LEN + 16

; mp4_parse_moov results
MP4_OK          equ 0
MP4_EBAD        equ -1              ; not a moov box we can read / no tracks
MP4_EWORK       equ -2              ; work buffer too small (MP4I_NEED says how big)
MP4_EFRAG       equ -3              ; fragmented MP4: the samples are in moof boxes
MP4_ECODEC      equ -4              ; tracks found, none in H.264 or AAC (see MP4T_CODEC)

; ---- a track being read (internal): the public block, then the tables -------
TK_USE          equ MP4T_LEN + 0    ; 1 = MOOS can play it
TK_HDLR         equ MP4T_LEN + 4    ; 'vide' / 'soun' (0 = no track kept yet)
TK_CODECOK      equ MP4T_LEN + 8    ; codec and its setup understood
TK_CFGSRC       equ MP4T_LEN + 12   ; the avcC / ASC bytes inside the moov
TK_SPSOFF       equ MP4T_LEN + 16   ; first SPS / PPS: offset into the avcC
TK_PPSOFF       equ MP4T_LEN + 20
TK_STTS         equ MP4T_LEN + 24   ; first entry, entry count
TK_STTSN        equ MP4T_LEN + 28
TK_CTTS         equ MP4T_LEN + 32
TK_CTTSN        equ MP4T_LEN + 36
TK_STSS         equ MP4T_LEN + 40   ; (0 = no stss box: every sample is a sync sample)
TK_STSSN        equ MP4T_LEN + 44
TK_STSC         equ MP4T_LEN + 48
TK_STSCN        equ MP4T_LEN + 52
TK_SZ           equ MP4T_LEN + 56   ; sample size entries
TK_SZKIND       equ MP4T_LEN + 60   ; 0 none, 1 one size for all, 32 stsz, 4/8/16 stz2
TK_SZCONST      equ MP4T_LEN + 64
TK_CO           equ MP4T_LEN + 68   ; chunk offsets
TK_CON          equ MP4T_LEN + 72
TK_CO64         equ MP4T_LEN + 76   ; 1 = co64 (64-bit entries)
TK_LEN          equ MP4T_LEN + 80

; boxes mp4_walk notes for a track (slot numbers)
SL_TKHD         equ 0
SL_ELST         equ 1
SL_MDHD         equ 2
SL_HDLR         equ 3
SL_STSD         equ 4
SL_STTS         equ 5
SL_CTTS         equ 6
SL_STSS         equ 7
SL_STSC         equ 8
SL_STSZ         equ 9
SL_STZ2         equ 10
SL_STCO         equ 11
SL_CO64         equ 12
SL_COUNT        equ 13
MP4_MAXDEPTH    equ 6               ; containers inside a trak (trak/mdia/minf/stbl is 3)

section .data
align 4
; type, slot (-1 = a container to look inside); ends with 0
mp4_boxtab:
    dd 'edts', -1, 'mdia', -1, 'minf', -1, 'stbl', -1
    dd 'tkhd', SL_TKHD, 'elst', SL_ELST, 'mdhd', SL_MDHD, 'hdlr', SL_HDLR
    dd 'stsd', SL_STSD, 'stts', SL_STTS, 'ctts', SL_CTTS, 'stss', SL_STSS
    dd 'stsc', SL_STSC, 'stsz', SL_STSZ, 'stz2', SL_STZ2, 'stco', SL_STCO
    dd 'co64', SL_CO64, 0, 0
; box types a file may start with (anything else: not an MP4)
mp4_firsttab:
    dd 'ftyp', 'styp', 'moov', 'mdat', 'free', 'skip', 'wide', 'pdin', 'uuid'
    dd 'sidx', 'junk', 'pnot', 0
; AAC sampling frequencies by index (14496-3, Table 1.18)
mp4_aacrate:
    dd 96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050
    dd 16000, 12000, 11025, 8000, 7350, 0, 0, 0
; channels by channelConfiguration (0 = say in the sample entry / a PCE)
mp4_aacch:
    db 0, 1, 2, 3, 4, 5, 6, 8, 0, 0, 0, 7, 8, 24, 8, 0

section .bss
alignb 4
mp4_bss:                            ; (cleared by mp4_parse_moov)
mp4_slot_ptr    resd SL_COUNT       ; payload of each noted box (0 = none)
mp4_slot_len    resd SL_COUNT
mp4_ct          resb TK_LEN         ; the track being read
mp4_vt          resb TK_LEN         ; the video track kept
mp4_at          resb TK_LEN         ; the audio track kept
mp4_mscale      resd 1              ; movie time scale / length (mvhd)
mp4_mdur        resd 1
mp4_frag        resd 1              ; 1 = an mvex box (fragmented file)
mp4_ntrak       resd 1
mp4_depth       resd 1              ; mp4_walk nesting
mp4_mbeg        resd 1              ; moov payload
mp4_mend        resd 1
mp4_bitpos      resd 1              ; AudioSpecificConfig bit reader
mp4_ascbuf      resb 16
mp4_send        resd 1              ; end of the sample array being filled
mp4_scend       resd 1              ; end of the stsc entries
mp4_trem        resd 1              ; stts: samples left in this entry
mp4_tend        resd 1              ;       end of the entries
mp4_cp          resd 1              ; ctts: current entry, samples left, end
mp4_crem        resd 1
mp4_cend        resd 1
mp4_dtslo       resd 1              ; decode time (64-bit)
mp4_dtshi       resd 1
mp4_tmp         resd 1
mp4_wp          resd 1              ; next free byte of work
mp4_info        resd 1              ; mp4_parse_moov's info, work, worklen
mp4_work        resd 1
mp4_wlen        resd 1
mp4_bss_end:

section .text

; -----------------------------------------------------------------------------
; mp4_box_next: read the box header at ESI inside a container ending at EDX.
;   In:  ESI = where the box starts, EDX = end of the container (exclusive)
;   Out: CF clear: EAX = box type (its 4 bytes as a dword), EBX = start of
;        the payload, ECX = end of the box. CF set: no valid box here (less
;        than a header left, or a size that does not fit the container).
;   Keeps EDX ESI EDI EBP.
; -----------------------------------------------------------------------------
mp4_box_next:
    mov ecx, edx
    sub ecx, esi                    ; ECX = bytes left in the container
    jb .none
    cmp ecx, 8
    jb .none
    mov ebx, [esi]
    bswap ebx                       ; size
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
.tail:                              ; size 0: the box fills the rest
    mov ecx, edx
    lea ebx, [esi + 8]
    mov eax, [esi + 4]
    clc
    ret
.large:                             ; size 1: a 64-bit size follows the type
    cmp ecx, 16
    jb .none
    cmp dword [esi + 8], 0          ; (high half: anything there is too big)
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

; -----------------------------------------------------------------------------
; int mp4_find_moov(const uint8_t *data, uint32_t len, uint32_t *moov_off,
;                   uint32_t *moov_len)
;   data = the start of the file (len bytes of it). Walks the top-level
;   boxes. 0: the moov box starts at *moov_off and is *moov_len bytes long
;   (whole in data if moov_off + moov_len <= len; a size-0 moov, which runs
;   to the end of the file, is given as the rest of data). 1: not in this
;   part; *moov_off = where the next top-level box starts (fetch from there
;   and call again on that part, adding the offsets; a value at or past the
;   file's size means the file has no moov). -1: not an MP4 (the first box
;   is not one an MP4 starts with, a box header is damaged, or a box runs
;   to the end of the file or past 4 GB before any moov).
; -----------------------------------------------------------------------------
EXPORT(mp4_find_moov)
mp4_find_moov:
    CENTER
    mov esi, ARG(0)
    xor edi, edi                    ; EDI = offset of the box being looked at
.box:
    mov ecx, ARG(1)
    sub ecx, edi                    ; bytes of data left from here
    jb .more                        ; (the last box ended past the data)
    cmp ecx, 8
    jb .more
    mov eax, [esi + edi + 4]        ; type: four printable characters
    mov edx, 4
.chr:
    cmp al, 0x20
    jb .bad
    cmp al, 0x7E
    ja .bad
    ror eax, 8
    dec edx
    jnz .chr
    test edi, edi                   ; the first box must be one an MP4 starts with
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
    bswap ebx                       ; EBX = size
    mov edx, 8                      ; EDX = header length
    cmp ebx, 1
    jne .small
    cmp ecx, 16                     ; 64-bit size: need its 8 bytes too
    jb .more
    cmp dword [esi + edi + 8], 0
    jne .bad                        ; (a box of 4 GB or more)
    mov ebx, [esi + edi + 12]
    bswap ebx
    mov edx, 16
    jmp .sized
.small:
    test ebx, ebx
    jnz .sized
    cmp eax, 'moov'                 ; size 0: runs to the end of the file
    jne .bad                        ; (so no moov can follow it)
    mov ebx, ecx                    ; a moov: give the rest of the data
    jmp .found
.sized:
    cmp ebx, edx
    jb .bad
    cmp eax, 'moov'
    je .found
    add edi, ebx                    ; on to the next box
    jc .bad                         ; (past 4 GB)
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

; -----------------------------------------------------------------------------
; mp4_walk: note where the boxes of mp4_boxtab are (mp4_slot_ptr/len) among
;   the boxes in ESI..EDX, looking inside the container boxes listed there
;   (at most MP4_MAXDEPTH levels; only the first box of each kind counts).
;   In: ESI = first box, EDX = end. Keeps ESI EDX EDI EBP; uses EAX EBX ECX.
; -----------------------------------------------------------------------------
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
    mov ebp, ecx                    ; EBP = where the next box starts
    mov edi, mp4_boxtab
.look:
    mov ecx, [edi]
    test ecx, ecx
    jz .skip                        ; not a box we need
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

; -----------------------------------------------------------------------------
; mp4_slot: EBX = payload of noted box ECX (a slot number), ECX = its length;
;   ZF set if the box was not there. Uses nothing else.
; -----------------------------------------------------------------------------
mp4_slot:
    mov ebx, [mp4_slot_ptr + ecx * 4]
    mov ecx, [mp4_slot_len + ecx * 4]
    test ebx, ebx
    ret

; -----------------------------------------------------------------------------
; mp4_rescale: EAX = round(EAX * ECX / EBX), at most 0xFFFFFFFF; 0 if EBX is
;   0. Uses EDX.
; -----------------------------------------------------------------------------
mp4_rescale:
    test ebx, ebx
    jz .zero
    mul ecx                         ; EDX:EAX = EAX * ECX
    push ebx
    shr ebx, 1                      ; + half the divisor, to round
    add eax, ebx
    adc edx, 0
    pop ebx
    cmp edx, ebx
    jae .max                        ; the quotient would not fit 32 bits
    div ebx
    ret
.max:
    mov eax, -1
    ret
.zero:
    xor eax, eax
    ret

; -----------------------------------------------------------------------------
; mp4_rd64: EAX = the 64-bit big-endian value at [EBX + ECX], or 0xFFFFFFFF
;   if it does not fit 32 bits. Uses nothing else.
; -----------------------------------------------------------------------------
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

; -----------------------------------------------------------------------------
; mp4_track: read the boxes mp4_walk noted for one trak into the track
;   record at EBP: kind, codec and its setup, time scale, the sample tables,
;   the edit list, and whether MOOS can play it (TK_USE).
;   Uses EAX EBX ECX EDX ESI EDI; keeps EBP.
; -----------------------------------------------------------------------------
mp4_track:
    mov edi, ebp
    mov ecx, TK_LEN / 4
    xor eax, eax
    rep stosd
    ; tkhd: track number (after the times, which are 64-bit in version 1)
    mov ecx, SL_TKHD
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
.hdlr:                              ; hdlr: 'vide' or 'soun'
    mov ecx, SL_HDLR
    call mp4_slot
    jz .mdhd
    cmp ecx, 12
    jb .mdhd
    mov eax, [ebx + 8]
    mov [ebp + TK_HDLR], eax
.mdhd:                              ; mdhd: time scale and length
    mov ecx, SL_MDHD
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
.stsd:                              ; stsd: the first sample entry
    mov ecx, SL_STSD
    call mp4_slot
    jz .tables
    cmp ecx, 16
    jb .tables
    lea esi, [ebx + 8]              ; (after version/flags and the entry count)
    lea edx, [ebx + ecx]
    call mp4_box_next
    jc .tables
    mov [ebp + MP4T_CODEC], eax
    cmp dword [ebp + TK_HDLR], 'vide'
    jne .notvid
    call mp4_vis_entry
    jmp .tables
.notvid:
    cmp dword [ebp + TK_HDLR], 'soun'
    jne .tables
    call mp4_snd_entry
.tables:
    call mp4_tables
    call mp4_edit
    ; can MOOS play it?
    cmp dword [ebp + TK_CODECOK], 0
    je .ret
    cmp dword [ebp + MP4T_SCALE], 0
    je .ret
    cmp dword [ebp + MP4T_N], 0
    je .ret
    cmp dword [ebp + TK_STTSN], 0
    je .ret
    cmp dword [ebp + TK_STSCN], 0
    je .ret
    cmp dword [ebp + TK_CON], 0
    je .ret
    cmp dword [ebp + TK_SZKIND], 0
    je .ret
    mov dword [ebp + TK_USE], 1
.ret:
    ret

; -----------------------------------------------------------------------------
; mp4_vis_entry: read a video sample entry (VisualSampleEntry, 14496-12
;   12.1.3) and its avcC box (14496-15 5.3.3) into the track at EBP.
;   In: EBX = entry payload, ECX = entry end, [EBP + MP4T_CODEC] its type.
;   Uses EAX EBX ECX EDX ESI EDI.
; -----------------------------------------------------------------------------
mp4_vis_entry:
    mov eax, ecx
    sub eax, ebx
    cmp eax, 78                     ; the fixed part is 78 bytes
    jb .ret
    movzx eax, word [ebx + 24]
    xchg al, ah
    mov [ebp + MP4T_P1], eax        ; width
    movzx eax, word [ebx + 26]
    xchg al, ah
    mov [ebp + MP4T_P2], eax        ; height
    lea esi, [ebx + 78]             ; then boxes: avcC, btrt, pasp, colr ...
    mov edx, ecx
.next:
    call mp4_box_next
    jc .ret
    cmp eax, 'avcC'
    je .avcc
    mov esi, ecx
    jmp .next
.avcc:
    mov [ebp + TK_CFGSRC], ebx
    sub ecx, ebx                    ; ECX = record length
    mov [ebp + MP4T_CFGLEN], ecx
    mov eax, [ebp + MP4T_CODEC]
    cmp eax, 'avc1'
    je .h264
    cmp eax, 'avc3'                 ; (parameter sets may be in the stream)
    jne .ret
.h264:
    ; AVCDecoderConfigurationRecord: version 1, profile, compatibility,
    ; level, 6 bits 1 + lengthSizeMinusOne, 3 bits 1 + number of SPS,
    ; (16-bit length, SPS)..., number of PPS, (16-bit length, PPS)...
    cmp ecx, 6
    jb .ret
    cmp byte [ebx], 1
    jne .ret
    movzx eax, byte [ebx + 4]
    and eax, 3
    inc eax
    mov [ebp + MP4T_P3], eax        ; NAL length size
    movzx edi, byte [ebx + 5]
    and edi, 31                     ; EDI = SPS count
    mov esi, 6                      ; ESI = offset in the record
.sps:
    test edi, edi
    jz .ppscount
    lea eax, [esi + 2]
    cmp eax, ecx
    ja .ret
    movzx edx, word [ebx + esi]
    xchg dl, dh                     ; EDX = this SPS's length
    add eax, edx
    cmp eax, ecx
    ja .ret
    cmp dword [ebp + MP4T_P5], 0    ; keep the first
    jne .sps2
    test edx, edx
    jz .sps2
    lea edx, [esi + 2]
    mov [ebp + TK_SPSOFF], edx
    sub eax, edx
    mov [ebp + MP4T_P5], eax
    add eax, edx
.sps2:
    mov esi, eax
    dec edi
    jmp .sps
.ppscount:
    cmp esi, ecx                    ; (the PPS count may be missing)
    jae .ok
    movzx edi, byte [ebx + esi]     ; EDI = PPS count
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
    mov [ebp + TK_PPSOFF], edx
    sub eax, edx
    mov [ebp + MP4T_P7], eax
    add eax, edx
.pps2:
    mov esi, eax
    dec edi
    jmp .pps
.ok:
    mov dword [ebp + TK_CODECOK], 1
.ret:
    ret

; -----------------------------------------------------------------------------
; mp4_snd_entry: read a sound sample entry (AudioSampleEntry; QuickTime
;   sound description versions 1 and 2 too) and its esds box, directly or
;   inside a QuickTime 'wave' box, into the track at EBP.
;   In: EBX = entry payload, ECX = entry end. Uses EAX EBX ECX EDX ESI EDI.
; -----------------------------------------------------------------------------
mp4_snd_entry:
    mov eax, ecx
    sub eax, ebx
    cmp eax, 28
    jb .ret
    movzx edx, word [ebx + 16]
    xchg dl, dh
    mov [ebp + MP4T_P2], edx        ; channels
    movzx edx, word [ebx + 24]
    xchg dl, dh
    mov [ebp + MP4T_P1], edx        ; sample rate (16.16; the integer part)
    movzx edx, word [ebx + 8]       ; (QuickTime) version: 0, 1 or 2
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
    push esi                        ; look inside 'wave' (one level)
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
    mov eax, [ebp + MP4T_P3]        ; objectTypeIndication: MPEG-4 audio, or
    cmp eax, 0x40                   ; MPEG-2 AAC (main, LC, SSR)
    je .aac
    cmp eax, 0x66
    jb .ret
    cmp eax, 0x68
    ja .ret
.aac:
    call mp4_asc
    mov dword [ebp + TK_CODECOK], 1
.ret:
    ret

; -----------------------------------------------------------------------------
; mp4_desc: read an MPEG-4 descriptor header (14496-1: tag byte, then a
;   length in 1-4 bytes of 7 bits, high bit = more).
;   In: ESI = header, EDX = end of the enclosing data.
;   Out: CF clear: AL = tag, ESI = content, ECX = content length (fits
;   before EDX). CF set: damaged. Uses EAX ECX.
; -----------------------------------------------------------------------------
mp4_desc:
    cmp esi, edx
    jae .bad
    movzx eax, byte [esi]
    shl eax, 8                      ; tag kept in AH for now
    inc esi
    xor ecx, ecx
    push edx
    mov dl, 4                       ; at most 4 length bytes
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
    cmp ecx, eax                    ; must fit what is left
    pop eax
    ja .bad
    clc
    ret

; -----------------------------------------------------------------------------
; mp4_esds: find the AudioSpecificConfig in an esds box (14496-14 5.6):
;   ES_Descriptor (tag 3) > DecoderConfigDescriptor (tag 4: objectType...)
;   > DecoderSpecificInfo (tag 5) = the AudioSpecificConfig bytes.
;   In: EBX = esds payload, ECX = its end; EBP = track (TK_CFGSRC,
;   MP4T_CFGLEN, MP4T_P3 set). Keeps ESI EDX; uses EAX EBX ECX EDI.
; -----------------------------------------------------------------------------
mp4_esds:
    push esi
    push edx
    lea esi, [ebx + 4]              ; (after version and flags)
    mov edx, ecx
    call mp4_desc
    jc .ret
    cmp al, 4
    je .dcd                         ; (no ES_Descriptor around it: allowed)
    cmp al, 3
    jne .ret
    lea edx, [esi + ecx]            ; EDX = end of the ES_Descriptor
    lea eax, [esi + 3]
    cmp eax, edx
    ja .ret
    mov bl, [esi + 2]               ; flags: dependsOn, URL, OCR stream
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
.find4:                             ; the DecoderConfigDescriptor
    cmp esi, edx
    ja .ret
    call mp4_desc
    jc .ret
    cmp al, 4
    je .dcd
    add esi, ecx
    jmp .find4
.dcd:
    lea edx, [esi + ecx]            ; EDX = its end
    cmp ecx, 13
    jb .ret
    movzx eax, byte [esi]
    mov [ebp + MP4T_P3], eax        ; objectTypeIndication
    add esi, 13                     ; (stream type, buffer size, bit rates)
.find5:
    call mp4_desc
    jc .ret
    cmp al, 5
    je .dsi
    add esi, ecx
    jmp .find5
.dsi:
    mov [ebp + TK_CFGSRC], esi
    mov [ebp + MP4T_CFGLEN], ecx
.ret:
    pop edx
    pop esi
    ret

; -----------------------------------------------------------------------------
; mp4_bits: EAX = the next EDX bits (1-24) of the AudioSpecificConfig copy
;   in mp4_ascbuf (zeros past its end). Uses ECX.
; -----------------------------------------------------------------------------
mp4_bits:
    mov ecx, [mp4_bitpos]
    add [mp4_bitpos], edx
    mov eax, ecx
    shr eax, 3
    cmp eax, 12                     ; (never past the 16-byte copy)
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

; -----------------------------------------------------------------------------
; mp4_asc: read the start of the AudioSpecificConfig (14496-3 1.6.2.1):
;   audio object type, sampling frequency, channel configuration, and for
;   explicit HE-AAC (SBR, PS) the output sampling frequency.
;   In: EBP = track with TK_CFGSRC / MP4T_CFGLEN. Sets MP4T_P4 (object
;   type), MP4T_P1 (rate) and MP4T_P2 (channels) where the config says.
;   Uses EAX ECX EDX ESI EDI.
; -----------------------------------------------------------------------------
mp4_asc:
    xor eax, eax
    mov [mp4_bitpos], eax
    mov edi, mp4_ascbuf
    mov ecx, 4
    rep stosd
    mov esi, [ebp + TK_CFGSRC]
    mov ecx, [ebp + MP4T_CFGLEN]
    cmp ecx, 12
    jbe .copy
    mov ecx, 12
.copy:
    mov edi, mp4_ascbuf
    rep movsb
    mov edx, 5
    call mp4_bits                   ; audioObjectType
    cmp eax, 31
    jne .aot
    mov edx, 6
    call mp4_bits
    add eax, 32
.aot:
    mov [ebp + MP4T_P4], eax
    call .freq
    mov edx, 4
    call mp4_bits                   ; channelConfiguration
    movzx eax, byte [mp4_aacch + eax]
    test eax, eax
    jz .sbr
    mov [ebp + MP4T_P2], eax
.sbr:
    mov eax, [ebp + MP4T_P4]
    cmp eax, 5                      ; SBR / PS: the extension frequency is
    je .ext                         ; what comes out
    cmp eax, 29
    jne .ret
.ext:
    call .freq
.ret:
    ret
.freq:                              ; samplingFrequencyIndex (15: 24-bit value)
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

; -----------------------------------------------------------------------------
; mp4_tables: find the sample tables noted by mp4_walk and how many entries
;   each really has (never more than fit its box). Sets the TK_ table
;   fields and MP4T_N (from the sample sizes) of the track at EBP.
;   Uses EAX EBX ECX EDX.
; -----------------------------------------------------------------------------
mp4_tables:
    mov ecx, SL_STTS                ; stts: (count, delta) pairs
    call mp4_slot
    jz .ctts
    mov edx, 3                      ; (8-byte entries)
    call .count
    mov [ebp + TK_STTS], ebx
    mov [ebp + TK_STTSN], eax
.ctts:                              ; ctts: (count, offset) pairs
    mov ecx, SL_CTTS
    call mp4_slot
    jz .stss
    mov edx, 3
    call .count
    mov [ebp + TK_CTTS], ebx
    mov [ebp + TK_CTTSN], eax
.stss:                              ; stss: sync sample numbers
    mov ecx, SL_STSS
    call mp4_slot
    jz .stsc
    mov edx, 2
    call .count
    mov [ebp + TK_STSS], ebx
    mov [ebp + TK_STSSN], eax
.stsc:                              ; stsc: (first chunk, samples per chunk, entry) triples
    mov ecx, SL_STSC
    call mp4_slot
    jz .stco
    cmp ecx, 8
    jb .stco
    sub ecx, 8
    mov eax, ecx
    xor edx, edx
    mov ecx, 12
    div ecx                         ; EAX = entries that fit
    mov ecx, [ebx + 4]
    bswap ecx
    cmp ecx, eax
    jae .scfit
    mov eax, ecx
.scfit:
    add ebx, 8
    mov [ebp + TK_STSC], ebx
    mov [ebp + TK_STSCN], eax
.stco:                              ; stco / co64: chunk offsets
    mov ecx, SL_STCO
    call mp4_slot
    jz .co64
    mov edx, 2
    call .count
    jmp .setco
.co64:
    mov ecx, SL_CO64
    call mp4_slot
    jz .sizes
    mov edx, 3
    call .count
    mov dword [ebp + TK_CO64], 1
.setco:
    mov [ebp + TK_CO], ebx
    mov [ebp + TK_CON], eax
.sizes:                             ; stsz: one size for all, or a 32-bit size each
    mov ecx, SL_STSZ
    call mp4_slot
    jz .stz2
    cmp ecx, 12
    jb .stz2
    mov eax, [ebx + 8]
    bswap eax                       ; EAX = sample count
    mov edx, [ebx + 4]
    bswap edx                       ; EDX = the size of every sample, or 0
    test edx, edx
    jz .stsz32
    mov [ebp + TK_SZCONST], edx
    mov dword [ebp + TK_SZKIND], 1
    jmp .setn
.stsz32:
    sub ecx, 12
    shr ecx, 2                      ; entries that fit
    cmp eax, ecx
    jbe .s32fit
    mov eax, ecx
.s32fit:
    mov dword [ebp + TK_SZKIND], 32
    jmp .setsz
.stz2:                              ; stz2: 4, 8 or 16-bit sizes
    mov ecx, SL_STZ2
    call mp4_slot
    jz .ret
    cmp ecx, 12
    jb .ret
    sub ecx, 12                     ; ECX = bytes of entries
    cmp ecx, 0x40000000
    jae .ret
    movzx edx, byte [ebx + 7]       ; field size
    mov eax, [ebx + 8]
    bswap eax
    cmp edx, 4
    jne .z8
    shl ecx, 1                      ; two entries a byte
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
    mov [ebp + TK_SZKIND], edx
.setsz:
    add ebx, 12
    mov [ebp + TK_SZ], ebx
.setn:
    mov [ebp + MP4T_N], eax
.ret:
    ret
; .count: a full box with an entry count, then entries of 1 << EDX bytes.
;   In: EBX = payload, ECX = its length. Out: EBX = first entry, EAX =
;   entries (no more than fit; 0 if the box is too short). Uses ECX.
.count:
    xor eax, eax
    cmp ecx, 8
    jb .cret
    sub ecx, 8
    xchg ecx, edx
    shr edx, cl                     ; EDX = entries that fit
    mov eax, [ebx + 4]
    bswap eax
    cmp eax, edx
    jbe .cret
    mov eax, edx
.cret:
    add ebx, 8
    ret

; -----------------------------------------------------------------------------
; mp4_edit: apply the track's edit list (elst) at EBP: MP4T_EDIT = where
;   the presentation starts in the media (first real edit's media time,
;   less any empty edits before it, in the track's time scale), MP4T_DUR =
;   the presented length. Without an edit list: 0 and the mdhd length.
;   Uses EAX EBX ECX EDX ESI EDI.
; -----------------------------------------------------------------------------
mp4_edit:
    mov eax, [ebp + MP4T_MDUR]
    mov [ebp + MP4T_DUR], eax
    mov ecx, SL_ELST
    call mp4_slot
    jz .ret
    cmp ecx, 8
    jb .ret
    mov edx, 12                     ; entry size: 12 (version 0) or 20
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
.nfit:                              ; EDX = entries, ECX = entry size
    lea esi, [ebx + 8]              ; ESI = entry
    xor edi, edi                    ; EDI = empty time so far (movie scale)
.entry:
    test edx, edx
    jz .noreal
    cmp ecx, 20
    je .e1
    mov eax, [esi]                  ; version 0: 32-bit duration, media time
    bswap eax
    mov ebx, [esi + 4]
    bswap ebx
    cmp ebx, -1
    je .empty
    test ebx, ebx
    js .ret                         ; (a negative time other than -1: ignore the list)
    jmp .real
.e1:                                ; version 1: 64-bit duration, media time
    mov ebx, esi
    push ecx
    xor ecx, ecx
    call mp4_rd64
    pop ecx
    mov ebx, [esi + 8]
    and ebx, [esi + 12]
    cmp ebx, -1                     ; media time -1: an empty edit
    je .empty
    cmp dword [esi + 8], 0
    jne .ret                        ; (too far, or negative: ignore the list)
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
.noreal:                            ; only empty edits
    xor ebx, ebx
    xor eax, eax
.real:                              ; EBX = media time, EAX = its duration (movie scale)
    mov [mp4_tmp], eax
    mov esi, ebx                    ; ESI = media time
    mov eax, edi
    mov ecx, [ebp + MP4T_SCALE]
    mov ebx, [mp4_mscale]
    call mp4_rescale                ; EAX = empty time in the track's scale
    mov edx, esi
    sub edx, eax                    ; shift = media time - empty time
    jnc .shift                      ; (media time >= empty: 0 .. 2^31-1)
    test edx, edx
    js .shift                       ; (negative, and it fits 32 bits)
    mov edx, 0x80000000             ; (below -2^31)
.shift:
    mov [ebp + MP4T_EDIT], edx
    mov edx, eax                    ; EDX = empty time (track scale)
    mov eax, [mp4_tmp]
    test eax, eax
    jz .tomedia
    add eax, edi                    ; length = empty + the edit, rescaled
    jnc .resc
    mov eax, -1
.resc:
    mov ecx, [ebp + MP4T_SCALE]
    call mp4_rescale
    jmp .setdur
.tomedia:                           ; an edit of length 0: to the end of the media
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

; -----------------------------------------------------------------------------
; mp4_build: fill the sample array at EDI for the track at EBP (TK_USE set,
;   MP4T_N entries of room): sizes, file offsets, presentation times, sync
;   flags. MP4T_N may come down if the chunk tables run out early.
;   Uses EAX EBX ECX EDX ESI EDI.
; -----------------------------------------------------------------------------
mp4_build:
    mov [ebp + MP4T_SAMP], edi
    mov eax, [ebp + MP4T_N]
    shl eax, 4
    add eax, edi
    mov [mp4_send], eax
    ; --- sizes, and the sync flag every sample has if there is no stss
    xor edx, edx
    cmp dword [ebp + TK_STSS], 0
    jne .flag
    inc edx
.flag:
    mov esi, [ebp + TK_SZ]
    mov ecx, [ebp + MP4T_N]
    test ecx, ecx
    jz .ret
    xor ebx, ebx                    ; EBX = sample number (for 4-bit sizes)
.size:
    mov eax, [ebp + TK_SZKIND]
    cmp eax, 32
    je .sz32
    cmp eax, 16
    je .sz16
    cmp eax, 8
    je .sz8
    cmp eax, 4
    je .sz4
    mov eax, [ebp + TK_SZCONST]
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
    shr eax, 4                      ; even samples: the high nibble
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

; -----------------------------------------------------------------------------
; mp4_offsets: give each sample of the track at EBP its file offset: chunk
;   by chunk (stco/co64), each chunk holding the number of samples stsc
;   says, one after another. Samples left without a chunk are dropped
;   (MP4T_N lowered); so are any from a chunk past 4 GB.
;   Uses EAX EBX ECX EDX ESI EDI.
; -----------------------------------------------------------------------------
mp4_offsets:
    mov edi, [ebp + MP4T_SAMP]      ; EDI = next sample to place
    mov esi, [ebp + TK_STSC]        ; ESI = current stsc entry
    mov eax, [ebp + TK_STSCN]
    lea eax, [eax + eax * 2]
    lea eax, [esi + eax * 4]
    mov [mp4_scend], eax
    mov ebx, 1                      ; EBX = chunk number (from 1)
.chunk:
    cmp ebx, [ebp + TK_CON]
    ja .done
    cmp edi, [mp4_send]
    jae .done
.adv:                               ; move on while the next entry starts by this chunk
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
    xor ecx, ecx                    ; ECX = samples in this chunk
    mov eax, [esi]
    bswap eax
    cmp eax, ebx
    ja .gotn                        ; (the first entry starts later: none)
    mov ecx, [esi + 4]
    bswap ecx
.gotn:
    mov eax, [ebp + TK_CO]
    cmp dword [ebp + TK_CO64], 0
    jne .c64
    mov edx, [eax + ebx * 4 - 4]
    bswap edx
    jmp .place
.c64:
    cmp dword [eax + ebx * 8 - 8], 0
    jne .done                       ; past 4 GB
    mov edx, [eax + ebx * 8 - 4]
    bswap edx
.place:                             ; EDX = file offset of the next sample
    test ecx, ecx
    jz .nextchunk
    cmp edi, [mp4_send]
    jae .done
    mov [edi + MP4S_OFF], edx
    add edx, [edi + MP4S_SIZE]
    jc .done                        ; (it would end past 4 GB)
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

; -----------------------------------------------------------------------------
; mp4_times: presentation time of each sample of the track at EBP:
;   decode time (stts run lengths, from 0, kept in 64 bits) + composition
;   offset (ctts, signed) - MP4T_EDIT, clamped to 0..0xFFFFFFFF; samples
;   that end by time 0 get MP4S_F_PRE (their stts delta is taken as their
;   length). If stts
;   ends early, its last delta goes on. If mdhd gave no length, MP4T_DUR =
;   the decode time after the last sample.
;   Uses EAX EBX ECX EDX ESI EDI.
; -----------------------------------------------------------------------------
mp4_times:
    cmp dword [ebp + MP4T_N], 0
    je .ret
    mov esi, [ebp + TK_STTS]        ; ESI = current stts entry
    mov eax, [ebp + TK_STTSN]
    lea eax, [esi + eax * 8]
    mov [mp4_tend], eax
    mov eax, [esi]
    bswap eax
    mov [mp4_trem], eax
    mov eax, [ebp + TK_CTTS]
    mov [mp4_cp], eax
    mov ecx, [ebp + TK_CTTSN]
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
    ; stts: skip used-up entries (keep the last one)
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
    ; ctts: skip used-up entries; EBX = this sample's offset (0 if none)
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
    ; pts = dts + offset - edit, as a 64-bit signed number
    mov eax, ebx
    cdq
    add eax, [mp4_dtslo]
    adc edx, [mp4_dtshi]
    mov ebx, [ebp + MP4T_EDIT]
    push ecx
    mov ecx, ebx
    sar ecx, 31
    sub eax, ebx
    sbb edx, ecx                    ; EDX:EAX = pts
    mov ebx, [esi + 4]              ; hidden by the edit list if pts + this
    bswap ebx                       ; sample's duration <= 0
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
    mov eax, -1                     ; (past 32 bits)
    jmp .ptsok
.ptszero:
    xor eax, eax
.ptsok:
    mov [edi + MP4S_PTS], eax
    ; dts += this entry's delta
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

; -----------------------------------------------------------------------------
; mp4_sync: mark the sync samples listed in stss (numbers from 1) and count
;   them (MP4T_NSYNC) for the track at EBP. Uses EAX EBX ECX EDX ESI.
; -----------------------------------------------------------------------------
mp4_sync:
    mov esi, [ebp + TK_STSS]
    mov ecx, [ebp + TK_STSSN]
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
    dec eax                         ; (sample numbers count from 1)
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

; -----------------------------------------------------------------------------
; mp4_need: EAX += the work bytes the kept track at EBP needs (its codec
;   setup and its sample array, each rounded up to 16); 0xFFFFFFFF if that
;   does not fit 32 bits. Nothing for a track MOOS cannot play. Uses EDX.
; -----------------------------------------------------------------------------
mp4_need:
    cmp dword [ebp + TK_USE], 0
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

; -----------------------------------------------------------------------------
; mp4_cfg: copy the codec setup bytes of the kept track at EBP to work
;   ([mp4_wp], advanced and kept 16-aligned) and point MP4T_CFG (and the
;   SPS / PPS of a video track) at the copy. Uses EAX ECX ESI EDI.
; -----------------------------------------------------------------------------
mp4_cfg:
    mov edi, [mp4_wp]
    mov [ebp + MP4T_CFG], edi
    mov esi, [ebp + TK_CFGSRC]
    mov ecx, [ebp + MP4T_CFGLEN]
    rep movsb
    mov eax, [ebp + MP4T_CFGLEN]
    add eax, 15
    and eax, -16
    add [mp4_wp], eax
    cmp dword [ebp + TK_HDLR], 'vide'
    jne .ret
    mov eax, [ebp + MP4T_CFG]
    cmp dword [ebp + MP4T_P5], 0
    je .pps
    add eax, [ebp + TK_SPSOFF]
    mov [ebp + MP4T_P4], eax
.pps:
    mov eax, [ebp + MP4T_CFG]
    cmp dword [ebp + MP4T_P7], 0
    je .ret
    add eax, [ebp + TK_PPSOFF]
    mov [ebp + MP4T_P6], eax
.ret:
    ret

; -----------------------------------------------------------------------------
; mp4_out: copy the public block of the kept track at EBP to the MP4INFO
;   block at EDI. A track MOOS cannot play keeps only what describes it
;   (codec, sizes, rate, time scale, lengths); OK, N and pointers stay 0.
;   Uses EAX ECX ESI EDI.
; -----------------------------------------------------------------------------
mp4_out:
    cmp dword [ebp + TK_HDLR], 0
    je .ret                         ; (no such track)
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
    cmp dword [ebp + TK_HDLR], 'vide'
    jne .ret
    mov [edi + MP4T_P4], eax
    mov [edi + MP4T_P5], eax
    mov [edi + MP4T_P6], eax
    mov [edi + MP4T_P7], eax
.ret:
    ret

; -----------------------------------------------------------------------------
; int mp4_parse_moov(const uint8_t *moov, uint32_t len, MP4INFO *info,
;                    uint8_t *work, uint32_t worklen)
;   moov = the moov box (from its header, as mp4_find_moov found it) or just
;   its payload. Fills info (MP4I_SIZE bytes) for the first H.264 video
;   track and the first AAC audio track (or, if there is none, the first
;   video / sound track of another codec, with OK = 0) and builds their
;   sample arrays in work.
;   work must hold, rounded up to 16 bytes each: the avcC record, the
;   AudioSpecificConfig, and 16 bytes per sample of both tracks, + 15.
;   When each sample's size is listed (stsz with sample size 0 - every
;   ffmpeg / YouTube file), a track's samples are at most a quarter of the
;   moov's size, so moov length * 6 + 1 MB is always enough; a file with one
;   size for all samples may need more (MP4I_NEED tells).
;   Returns 0 ok (MP4I_V_OK and/or MP4I_A_OK set), -1 damaged / no
;   tracks, -2 work too small (MP4I_NEED = bytes needed), -3 fragmented
;   file (samples in moof boxes, not supported), -4 no H.264 or AAC track.
; -----------------------------------------------------------------------------
EXPORT(mp4_parse_moov)
mp4_parse_moov:
    CENTER
    mov edi, ARG(2)                 ; clear info and our state
    mov ecx, MP4I_SIZE / 4
    xor eax, eax
    rep stosd
    mov edi, mp4_bss
    mov ecx, (mp4_bss_end - mp4_bss) / 4
    rep stosd
    mov eax, ARG(2)                 ; (EBP points at tracks from pass 2 on,
    mov [mp4_info], eax             ; so the arguments are kept here)
    mov eax, ARG(3)
    mov [mp4_work], eax
    mov eax, ARG(4)
    mov [mp4_wlen], eax
    mov esi, ARG(0)
    mov ecx, ARG(1)
    lea edx, [esi + ecx]            ; EDX = end of the data
    cmp edx, esi
    jb .bad
    cmp ecx, 8                      ; starts with the moov box header? use its payload
    jb .payload
    cmp dword [esi + 4], 'moov'
    jne .payload
    mov eax, [esi]
    bswap eax
    mov ebx, 8                      ; EBX = header length
    cmp eax, 1
    jne .hsize
    cmp ecx, 16
    jb .bad
    mov ebx, 16
    cmp dword [esi + 8], 0
    jne .hdone                      ; (huge: take all the data)
    mov eax, [esi + 12]
    bswap eax
.hsize:
    cmp eax, ebx
    jb .hdone                       ; (0 = to the end; other small sizes: all the data)
    cmp eax, ecx
    jae .hdone                      ; (more than we were given: what we have)
    lea edx, [esi + eax]
.hdone:
    add esi, ebx
.payload:
    mov [mp4_mbeg], esi
    mov [mp4_mend], edx
    ; pass 1: mvhd (movie time scale, for edit lists) and mvex (fragments)
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
    sub eax, ebx                    ; EAX = payload length
    cmp eax, 20
    jb .p1next
    cmp byte [ebx], 1
    je .mv1
    mov eax, [ebx + 12]             ; version 0: 32-bit times
    bswap eax
    mov [mp4_mscale], eax
    mov eax, [ebx + 16]
    bswap eax
    mov [mp4_mdur], eax
    jmp .p1next
.mv1:                               ; version 1: 64-bit times
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
    ; pass 2: each trak; keep the best video and audio tracks
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
    mov edi, mp4_slot_ptr           ; forget the last track's boxes
    mov ecx, SL_COUNT * 2
    xor eax, eax
    rep stosd
    mov [mp4_depth], eax
    mov esi, ebx
    mov edx, [esp + 8]              ; (the trak's end)
    call mp4_walk
    mov ebp, mp4_ct
    call mp4_track
    ; keep it if it is the first of its kind, or playable where the one
    ; kept is not
    mov edi, mp4_vt
    mov eax, [ebp + TK_HDLR]
    cmp eax, 'vide'
    je .pick
    mov edi, mp4_at
    cmp eax, 'soun'
    jne .p2pop
.pick:
    cmp dword [edi + TK_HDLR], 0
    je .keep
    cmp dword [edi + TK_USE], 0
    jne .p2pop
    cmp dword [ebp + TK_USE], 0
    je .p2pop
.keep:
    mov esi, ebp
    mov ecx, TK_LEN / 4
    rep movsd
.p2pop:
    pop esi
    pop edx
    pop ecx
.p2next:
    mov esi, ecx
    jmp .p2
.p2done:
    mov ebp, [mp4_info]             ; the movie's own numbers
    mov eax, [mp4_mscale]
    mov [ebp + MP4I_M_SCALE], eax
    mov eax, [mp4_mdur]
    mov [ebp + MP4I_M_DUR], eax
    mov eax, [mp4_ntrak]
    mov [ebp + MP4I_NTRAK], eax
    ; work needed
    mov eax, 15
    mov ebp, mp4_vt
    call mp4_need
    mov ebp, mp4_at
    call mp4_need
    mov ebx, [mp4_info]
    mov [ebx + MP4I_NEED], eax
    cmp eax, [mp4_wlen]
    ja .small
    ; build: codec setups first, then the sample arrays
    mov eax, [mp4_work]
    add eax, 15
    and eax, -16
    mov [mp4_wp], eax
    mov ebp, mp4_vt
    cmp dword [ebp + TK_USE], 0
    je .bcfga
    call mp4_cfg
.bcfga:
    mov ebp, mp4_at
    cmp dword [ebp + TK_USE], 0
    je .bsampv
    call mp4_cfg
.bsampv:
    mov ebp, mp4_vt
    cmp dword [ebp + TK_USE], 0
    je .bsampa
    mov edi, [mp4_wp]
    mov eax, [ebp + MP4T_N]
    shl eax, 4
    add [mp4_wp], eax
    call mp4_build
.bsampa:
    mov ebp, mp4_at
    cmp dword [ebp + TK_USE], 0
    je .report
    mov edi, [mp4_wp]
    mov eax, [ebp + MP4T_N]
    shl eax, 4
    add [mp4_wp], eax
    call mp4_build
.report:
    ; OK = playable and still has samples
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
.none:                              ; why nothing can be played
    mov eax, MP4_EFRAG
    cmp dword [mp4_frag], 0
    jne .ret
    mov eax, MP4_ECODEC
    mov ecx, [mp4_vt + TK_HDLR]
    or ecx, [mp4_at + TK_HDLR]
    jnz .ret
.bad:
    mov eax, MP4_EBAD
.ret:
    CLEAVE
.small:
    mov eax, MP4_EWORK
    CLEAVE
.setok:                             ; MP4T_OK = TK_USE and samples left
    xor eax, eax
    cmp dword [ebp + TK_USE], 0
    je .so
    cmp dword [ebp + MP4T_N], 0
    je .so
    inc eax
.so:
    mov [ebp + MP4T_OK], eax
    ret

; -----------------------------------------------------------------------------
; int mp4_find_sync(const MP4SAMPLE *samples, uint32_t count, uint32_t time)
;   For seeking: the index of the last sync sample whose pts is at or
;   before time (in the track's time scale). If none is (time before the
;   first sync sample), the first sync sample; 0 if there are none at all
;   or count is 0.
; -----------------------------------------------------------------------------
EXPORT(mp4_find_sync)
mp4_find_sync:
    CENTER
    mov esi, ARG(0)
    mov ecx, ARG(1)
    mov edx, ARG(2)
    test ecx, ecx
    jz .zero
    mov eax, ecx                    ; from the end back
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
    ; none at or before time: the first sync sample
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
