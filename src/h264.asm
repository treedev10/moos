; =============================================================================
;  h264.asm - H.264 / MPEG-4 AVC video decoder
;
;  Decodes the H.264 that web video uses: the Baseline profile (CAVLC
;  entropy coding, I and P slices, any number of slices per picture, up to
;  16 reference frames, long-term references and every memory management
;  operation, reference list reordering, all three picture order count
;  types), 4:2:0 8-bit progressive frames. Written from ITU-T Rec. H.264.
;
;  How it is put together (the clause numbers are those of the standard):
;    h264_decode_nal   one NAL unit: emulation prevention bytes are removed
;                      into the RBSP buffer (7.4.1), then by nal_unit_type:
;                      sequence / picture parameter sets (7.3.2) are kept in
;                      tables, slices are decoded, everything else ignored.
;    slices            the slice header (7.3.3) is read; the first slice of
;                      a picture starts it (picture order count 8.2.1, gaps
;                      in frame_num 8.2.5.2, a free frame buffer); the
;                      reference list is built (8.2.4); then the slice data
;                      (h264_mb.inc): every macroblock is parsed (CAVLC,
;                      9.2) and reconstructed straight into the frame:
;                      intra prediction (8.3), motion compensation (8.4),
;                      inverse transform (8.5) (h264_dsp.inc).
;    end of picture    when every macroblock is there (or the next picture
;                      starts): missing macroblocks are concealed (copied
;                      from the last reference frame), the deblocking filter
;                      runs over the whole picture (8.7), the borders are
;                      extended for motion compensation, the reference
;                      marking is applied (8.2.5) and the frame joins the
;                      ones waiting for output.
;    output            frames leave in display order (smallest picture
;                      order count first) once more than num_reorder_frames
;                      wait (from the stream's VUI; 0 for POC type 2,
;                      otherwise the DPB size), or when the buffer is full,
;                      at an IDR / MMCO 5, and at h264_flush.
;
;  Memory: the caller gives a context (h264_ctx_size bytes: the decoder's
;  state) and working memory (h264_mem_size(max_w, max_h) bytes): the
;  parameter set tables, the RBSP buffer, per-macroblock data, and 18 frame
;  buffers (16 references + the frame being decoded + one being output),
;  each with a 32 pixel border (16 for chroma) around the picture so that
;  motion vectors pointing outside need only a clamp of the block position.
;  The state lives in this module's .bss while a function runs (fixed
;  addresses keep the code simple); every entry point copies it in from the
;  context and back out, so several decoders can exist side by side.
;
;  Robustness: the input comes from the internet. Every syntax element is
;  range checked before it is used as an index, the bit reader runs over a
;  zero padded copy so reading past the end is harmless and is checked at
;  every macroblock, loops are bounded by the picture size, and a damaged
;  slice is abandoned: its missing macroblocks are concealed and decoding
;  goes on with the next slice. Streams that do not start with an IDR
;  picture are skipped up to the first one.
;
;  Not supported (the slices are skipped): CABAC / Main profile features,
;  B and SP/SI slices, interlaced video (field pictures, MBAFF), slice
;  groups (FMO), data partitioning, 4:2:2 / 4:4:4, more than 8 bits, the
;  High profile's 8x8 transform and scaling matrices.
;
;  Entry points (C calling convention, see tests/native/README.md):
;    h264_ctx_size, h264_mem_size, h264_init, h264_decode_nal,
;    h264_get_frame, h264_flush, h264_decode_avcc
; =============================================================================
%include "src/module.inc"

; DBG tag, a, b, c, d: a trace line through the C test's h264_dbg_print
; (only when assembled with -DH264DEBUG for debugging; nothing otherwise)
%ifdef H264DEBUG
extern h264_dbg_print
%macro DBG 5
    pushad
    pushfd
    push dword %5
    push dword %4
    push dword %3
    push dword %2
    push dword %1
    call h264_dbg_print
    add esp, 20
    popfd
    popad
%endmacro
%else
%macro DBG 5
%endmacro
%endif

; ---- the frame given out by h264_get_frame (H264FRAME) ----------------------
H264F_Y         equ 0               ; luma of the top-left visible pixel
H264F_U         equ 4               ; Cb
H264F_V         equ 8               ; Cr
H264F_YSTRIDE   equ 12              ; bytes per luma row
H264F_CSTRIDE   equ 16              ; bytes per chroma row
H264F_W         equ 20              ; visible size (after cropping)
H264F_H         equ 24
H264F_POC       equ 28              ; picture order count (signed)
H264F_FLAGS     equ 32              ; bit 0: concealed (damaged), bit 1: IDR
H264F_SARW      equ 36              ; sample aspect ratio (0:0 = unknown)
H264F_SARH      equ 40
H264F_SIZE      equ 44

; ---- limits ---------------------------------------------------------------
H264_NSLOT      equ 18              ; frame buffers
H264_MAXMBW     equ 256             ; 4096 pixels
H264_MAXMBH     equ 256
H264_MAXNMB     equ 36864           ; level 5.1's largest frame (4096x2304)
H264_PADY       equ 32              ; border around each luma plane
H264_PADC       equ 16              ; and each chroma plane
H264_MAXMMCO    equ 40              ; memory management operations kept
H264_MAXRPLM    equ 34              ; reference list modifications kept
H264_RBSPPAD    equ 512             ; zero bytes after the RBSP

; ---- sequence parameter set (table in the working memory) ------------------
SPS_VALID       equ 0               ; byte: 1 = received
SPS_PROFILE     equ 1
SPS_LEVEL       equ 2
SPS_CHROMA      equ 3               ; chroma_format_idc
SPS_LOG2FN      equ 4               ; log2(MaxFrameNum)
SPS_POCTYPE     equ 5
SPS_LOG2POC     equ 6               ; log2(MaxPicOrderCntLsb)
SPS_DPOCZ       equ 7               ; delta_pic_order_always_zero_flag
SPS_NREF        equ 8               ; max_num_ref_frames
SPS_GAPS        equ 9               ; gaps_in_frame_num_value_allowed_flag
SPS_UNSUP       equ 10              ; non-zero: uses something not supported
SPS_SCALING     equ 11              ; scaling matrices present (ignored)
SPS_NCYCLE      equ 12              ; num_ref_frames_in_pic_order_cnt_cycle
SPS_OFFNR       equ 16              ; offset_for_non_ref_pic
SPS_OFFTB       equ 20              ; offset_for_top_to_bottom_field
SPS_MBW         equ 24              ; width in macroblocks
SPS_MBH         equ 28              ; height in macroblocks
SPS_CROPL       equ 32              ; cropping, in luma samples
SPS_CROPR       equ 36
SPS_CROPT       equ 40
SPS_CROPB       equ 44
SPS_REORDER     equ 48              ; max_num_reorder_frames, -1 = not given
SPS_MAXDEC      equ 52              ; max_dec_frame_buffering, -1 = not given
SPS_SARW        equ 56
SPS_SARH        equ 60
SPS_EXPDELTA    equ 64              ; ExpectedDeltaPerPicOrderCntCycle
SPS_ID          equ 68
SPS_OFFREF      equ 72              ; offset_for_ref_frame[256]
SPS_D8I         equ 72 + 1024       ; byte: direct_8x8_inference_flag
SPS_SZ          equ 72 + 1024 + 4

; ---- picture parameter set ------------------------------------------------
PPS_VALID       equ 0
PPS_SPS         equ 1               ; seq_parameter_set_id
PPS_CABAC       equ 2               ; entropy_coding_mode_flag
PPS_BFPOC       equ 3               ; bottom_field_pic_order_in_frame_present
PPS_NSG         equ 4               ; num_slice_groups (1 = no FMO)
PPS_NREF0       equ 5               ; num_ref_idx_l0_default_active
PPS_NREF1       equ 6
PPS_WP          equ 7               ; weighted_pred_flag
PPS_WBI         equ 8               ; weighted_bipred_idc
PPS_QP          equ 9               ; pic_init_qp (0..51)
PPS_CQP         equ 10              ; chroma_qp_index_offset (signed)
PPS_CQP2        equ 11              ; second_chroma_qp_index_offset
PPS_DBK         equ 12              ; deblocking_filter_control_present_flag
PPS_CIP         equ 13              ; constrained_intra_pred_flag
PPS_RPC         equ 14              ; redundant_pic_cnt_present_flag
PPS_T8          equ 15              ; transform_8x8_mode_flag
PPS_SGTYPE      equ 16              ; slice_group_map_type
PPS_SGRATE      equ 20              ; SliceGroupChangeRate
PPS_SZ          equ 24

; ---- frame buffer slot (in the state) --------------------------------------
SL_Y            equ 0               ; top-left of the picture in each plane
SL_U            equ 4
SL_V            equ 8
SL_MOT          equ 12              ; motion data, MO_SZ per macroblock
SL_FLAGS        equ 16
SL_FN           equ 20              ; frame_num
SL_FNW          equ 24              ; FrameNumWrap
SL_LT           equ 28              ; LongTermFrameIdx
SL_POC          equ 32
SL_W            equ 36              ; visible size and where it starts
SL_H            equ 40
SL_CX           equ 44
SL_CY           equ 48
SL_ID           equ 52              ; decoding order number
SL_SARW         equ 56
SL_SARH         equ 60
SL_SZ           equ 64
; SL_FLAGS bits
F_SHORT         equ 1               ; used for short-term reference
F_LONG          equ 2               ; used for long-term reference
F_WAIT          equ 4               ; decoded, waiting for output
F_FIFO          equ 8               ; output, waiting for h264_get_frame
F_LENT          equ 16              ; given to the caller until the next call
F_CUR           equ 32              ; being decoded
F_NONEX         equ 64              ; "non-existing" frame (frame_num gap)
F_BAD           equ 128             ; parts were concealed
F_IDR           equ 256
F_BUSY          equ F_SHORT | F_LONG | F_WAIT | F_FIFO | F_LENT | F_CUR
F_REF           equ F_SHORT | F_LONG

; ---- motion data of a macroblock (in each frame buffer) --------------------
MO_MV0          equ 0               ; 16 motion vectors (x low word, y high
MO_MV1          equ 64              ;   word), raster order of 4x4 blocks
MO_REF0         equ 128             ; reference index per 8x8 (-1 = none)
MO_REF1         equ 132
MO_RS0          equ 136             ; frame buffer referenced per 8x8 (255 =
MO_RS1          equ 140             ;   none): which picture, for deblocking
MO_INTRA        equ 144             ; 1 = intra macroblock
MO_SZ           equ 160

; ---- per-macroblock data of the picture being decoded ----------------------
MI_SLICE        equ 0               ; slice number (decoded in this picture
                                    ;   if >= h264_pic_slice0)
MI_TYPE         equ 4               ; MT_* bits
MI_QP           equ 5               ; QPY (0 for I_PCM, for deblocking)
MI_QPC          equ 6               ; QPc of Cb and Cr
MI_QPC2         equ 7
MI_NNZ          equ 8               ; total_coeff: 16 luma (raster), 4 Cb, 4 Cr
MI_I4M          equ 32              ; Intra4x4 modes (raster)
MI_DBIDC        equ 48              ; disable_deblocking_filter_idc
MI_DBA          equ 49              ; FilterOffsetA (signed)
MI_DBB          equ 50              ; FilterOffsetB
MI_SZ           equ 128
MI_SHIFT        equ 7               ; log2(MI_SZ)
; MI_TYPE bits
MT_INTRA        equ 1
MT_PCM          equ 2
MT_I4           equ 4               ; Intra_4x4
MT_I16          equ 8
MT_SKIP         equ 16
MT_DIRECT       equ 32              ; B_Skip / B_Direct_16x16

; weights of one reference index (h264_wt)
WT_SZ           equ 24

; slice types (slice_type % 5)
ST_P            equ 0
ST_B            equ 1
ST_I            equ 2

%include "src/h264_tab.inc"

; =============================================================================
;  State: copied in from the context at every entry point, out at the exit
; =============================================================================
section .bss
alignb 16
h264_S_begin:
h264_mem        resd 1              ; the working memory and its layout
h264_memlen     resd 1
h264_maxmbw     resd 1
h264_maxmbh     resd 1
h264_maxnmb     resd 1
h264_ystride    resd 1
h264_cstride    resd 1
h264_ysize      resd 1              ; bytes of one luma plane (with border)
h264_csize      resd 1
h264_slotbytes  resd 1
h264_spstab     resd 1
h264_ppstab     resd 1
h264_asps       resd 1              ; copy of the active SPS
h264_rbsp       resd 1
h264_rbspcap    resd 1
h264_mbi        resd 1              ; MI_SZ per macroblock
h264_slotmem    resd 1
h264_total      resd 1
; the active sequence
h264_act        resd 1              ; 1 = an SPS is active
h264_mbw        resd 1
h264_mbh        resd 1
h264_nmb        resd 1
h264_dpbsize    resd 1
h264_reorder    resd 1
h264_maxfn      resd 1              ; MaxFrameNum
; frame buffers and output
h264_slots      resb H264_NSLOT * SL_SZ
h264_fifo       resd H264_NSLOT     ; slots in output order
h264_fifo_n     resd 1
; the picture being decoded
h264_cur        resd 1              ; its slot (-1: none)
h264_pic_on     resd 1              ; 1 = started, not finished
h264_pic_done   resd 1              ; macroblocks decoded
h264_pic_slice0 resd 1              ; number of its first slice
h264_pic_idr    resd 1
h264_pic_refidc resd 1              ; nal_ref_idc
h264_pic_fn     resd 1              ; frame_num
h264_pic_poclsb resd 1
h264_pic_dpb    resd 1              ; delta_pic_order_cnt_bottom
h264_pic_dpoc0  resd 1              ; delta_pic_order_cnt[0], [1]
h264_pic_dpoc1  resd 1
h264_pic_idrid  resd 1
h264_pic_ppsid  resd 1
h264_pic_noout  resd 1              ; no_output_of_prior_pics_flag
h264_pic_ltref  resd 1              ; long_term_reference_flag
h264_pic_adapt  resd 1              ; adaptive_ref_pic_marking_mode_flag
h264_pic_nmmco  resd 1
h264_pic_mmco   resd 3 * H264_MAXMMCO   ; op, value 1, value 2
h264_pic_err    resd 1              ; some macroblocks went wrong
h264_pic_poc    resd 1              ; PicOrderCnt (frame) and its two fields
h264_pic_top    resd 1
h264_pic_bot    resd 1
h264_pic_pocmsb resd 1
h264_pic_fno    resd 1              ; FrameNumOffset
h264_pic_conceal resd 1             ; slot to conceal from (-1: grey)
; history for the picture order count and frame_num
h264_prev_pocmsb resd 1
h264_prev_poclsb resd 1
h264_prev_fno   resd 1              ; prevFrameNumOffset
h264_prev_fn    resd 1              ; frame_num of the previous picture
h264_prev_reffn resd 1              ; PrevRefFrameNum
h264_have_ref   resd 1              ; PrevRefFrameNum is meaningful
h264_maxltidx   resd 1              ; MaxLongTermFrameIdx (-1: none)
h264_slicectr   resd 1              ; slices seen (numbers them)
h264_need_idr   resd 1              ; skip pictures until an IDR
h264_picid      resd 1              ; pictures started
h264_lastref    resd 1              ; slot of the latest reference (-1)
alignb 4
h264_S_end:
H264_STATE_SZ   equ h264_S_end - h264_S_begin

; ---- scratch (only meaningful during one call) ------------------------------
alignb 4
h264_ctxp       resd 1              ; the caller's context
h264_bp         resd 1              ; bit reader: position (bits)
h264_bbuf       resd 1              ;   start of the RBSP
h264_bend       resd 1              ;   bit position of rbsp_stop_one_bit
h264_berr       resd 1              ;   1 = an invalid code was read
h264_nalref     resd 1              ; nal_ref_idc of the NAL unit
h264_naltype    resd 1
; slice header
h264_sh_firstmb resd 1
h264_sh_type    resd 1              ; ST_*
h264_sh_pps     resd 1              ; -> PPS
h264_sh_ppsid   resd 1
h264_sh_sps     resd 1              ; -> SPS (table entry)
h264_sh_fn      resd 1
h264_sh_idr     resd 1
h264_sh_idrid   resd 1
h264_sh_poclsb  resd 1
h264_sh_dpb     resd 1
h264_sh_dpoc0   resd 1
h264_sh_dpoc1   resd 1
h264_sh_rpc     resd 1              ; redundant_pic_cnt
h264_sh_dspat   resd 1              ; direct_spatial_mv_pred_flag
h264_sh_nref0   resd 1              ; num_ref_idx_l0_active
h264_sh_nref1   resd 1
h264_sh_qp      resd 1              ; SliceQPY
h264_sh_dbidc   resd 1
h264_sh_dba     resd 1              ; FilterOffsetA = alpha_c0_offset_div2 * 2
h264_sh_dbb     resd 1
h264_sh_cabinit resd 1              ; cabac_init_idc
h264_sh_wmode   resd 1              ; weighted prediction: 0 none, 1
                                    ;   explicit, 2 implicit
h264_sh_lwd     resd 1              ; luma_log2_weight_denom
h264_sh_cwd     resd 1              ; chroma_log2_weight_denom
h264_wt         resb 64 * WT_SZ     ; explicit weights (list * 32 + index)
h264_wtf        resb 64             ;   which of them are not the default
h264_sh_noout   resd 1
h264_sh_ltref   resd 1
h264_sh_adapt   resd 1
h264_sh_nmmco   resd 1
h264_sh_mmco    resd 3 * H264_MAXMMCO
h264_sh_nrplm0  resd 1              ; reference list modifications, list 0
h264_sh_rplm0   resd 2 * H264_MAXRPLM   ; idc, value
h264_sh_nrplm1  resd 1
h264_sh_rplm1   resd 2 * H264_MAXRPLM
h264_sh_cqp     resd 1              ; chroma_qp_index_offset (both, signed)
h264_sh_cqp2    resd 1
h264_sh_cip     resd 1              ; constrained_intra_pred_flag
h264_slicenum   resd 1              ; number of this slice
; reference lists: frame buffer slots (255 = no picture), 33 entries
h264_list0      resb 36
h264_list1      resb 36
h264_lt_tmp     resb 36             ; scratch for list building
alignb 4
h264_tmpi       resd 40             ; scratch (sorting)

section .data
; MaxDpbMbs by level_idc (Table A-1): pairs level, MaxDpbMbs; 0 ends
h264_dpbmbs     dd 9, 396, 10, 396, 11, 900, 12, 2376, 13, 2376, 20, 2376
                dd 21, 4752, 22, 8100, 30, 8100, 31, 18000, 32, 20480
                dd 40, 32768, 41, 32768, 42, 34816, 50, 110400, 51, 184320
                dd 52, 184320, 0, 0
; sample aspect ratios for aspect_ratio_idc 1..16 (Table E-1)
h264_sar        dw 1, 1, 12, 11, 10, 11, 16, 11, 40, 33, 24, 11, 20, 11, 32, 11
                dw 80, 33, 18, 11, 15, 11, 64, 33, 160, 99, 4, 3, 3, 2, 2, 1

section .text

; =============================================================================
;  Entry points
; =============================================================================

; uint32_t h264_ctx_size(void): bytes of context the caller provides
EXPORT(h264_ctx_size)
h264_ctx_size:
    mov eax, H264_STATE_SZ
    ret

; uint32_t h264_mem_size(max_w, max_h): bytes of working memory for pictures
; up to max_w x max_h (0 if the size is not supported)
EXPORT(h264_mem_size)
h264_mem_size:
    CENTER
    mov eax, ARG(0)
    mov edx, ARG(1)
    call h264_layout
    CLEAVE

; h264_layout: EAX = max width, EDX = max height (pixels) -> the layout
; variables (h264_maxmbw ... h264_total) set, EAX = total bytes (0 if the
; size is not supported). EBX ESI EDI EBP kept.
h264_layout:
    add eax, 15
    shr eax, 4
    add edx, 15
    shr edx, 4
    test eax, eax
    jz .bad
    test edx, edx
    jz .bad
    cmp eax, H264_MAXMBW
    ja .bad
    cmp edx, H264_MAXMBH
    ja .bad
    mov [h264_maxmbw], eax
    mov [h264_maxmbh], edx
    imul eax, edx
    cmp eax, H264_MAXNMB
    ja .bad
    mov [h264_maxnmb], eax
    mov eax, [h264_maxmbw]          ; luma plane: (16 w + 64) x (16 h + 64)
    shl eax, 4
    add eax, 2 * H264_PADY
    mov [h264_ystride], eax
    mov ecx, [h264_maxmbh]
    shl ecx, 4
    add ecx, 2 * H264_PADY
    imul eax, ecx
    add eax, 63
    and eax, ~63
    mov [h264_ysize], eax
    mov eax, [h264_maxmbw]          ; chroma: (8 w + 32) x (8 h + 32)
    shl eax, 3
    add eax, 2 * H264_PADC
    mov [h264_cstride], eax
    mov ecx, [h264_maxmbh]
    shl ecx, 3
    add ecx, 2 * H264_PADC
    imul eax, ecx
    add eax, 63
    and eax, ~63
    mov [h264_csize], eax
    shl eax, 1
    add eax, [h264_ysize]
    mov ecx, [h264_maxnmb]
    imul ecx, MO_SZ
    add eax, ecx
    add eax, 63
    and eax, ~63
    mov [h264_slotbytes], eax
    ; the regions, one after the other (offsets for now)
    xor eax, eax
    mov [h264_spstab], eax
    add eax, 32 * SPS_SZ
    mov [h264_ppstab], eax
    add eax, 256 * PPS_SZ
    mov [h264_asps], eax
    add eax, SPS_SZ + 63
    and eax, ~63
    mov [h264_rbsp], eax
    mov ecx, [h264_maxnmb]          ; a slice is at most ~400 bytes per
    shl ecx, 9                      ; macroblock (A.3.1): 512 + 64 KB
    add ecx, 65536
    mov [h264_rbspcap], ecx
    add eax, ecx
    add eax, H264_RBSPPAD + 63
    and eax, ~63
    mov [h264_mbi], eax
    mov ecx, [h264_maxnmb]
    shl ecx, MI_SHIFT
    add eax, ecx
    mov [h264_slotmem], eax
    mov ecx, [h264_slotbytes]
    imul ecx, H264_NSLOT
    add eax, ecx
    add eax, 64                     ; room to align the start to 64
    mov [h264_total], eax
    ret
.bad:
    xor eax, eax
    ret

; int h264_init(ctx, mem, memlen, max_w, max_h): 0, or -1 if the memory is
; too small or the size not supported
EXPORT(h264_init)
h264_init:
    CENTER
    mov edi, h264_S_begin           ; a clean state
    mov ecx, H264_STATE_SZ / 4
    xor eax, eax
    rep stosd
    mov eax, ARG(3)
    mov edx, ARG(4)
    call h264_layout
    test eax, eax
    jz .fail
    cmp eax, ARG(2)
    ja .fail
    mov eax, ARG(1)                 ; align the memory start to 64
    add eax, 63
    and eax, ~63
    mov [h264_mem], eax
    mov ecx, ARG(2)
    mov [h264_memlen], ecx
    add [h264_spstab], eax          ; offsets -> addresses
    add [h264_ppstab], eax
    add [h264_asps], eax
    add [h264_rbsp], eax
    add [h264_mbi], eax
    add [h264_slotmem], eax
    ; parameter set tables: nothing received
    mov edi, [h264_spstab]
    mov ecx, (32 * SPS_SZ + 256 * PPS_SZ) / 4
    xor eax, eax
    rep stosd
    ; macroblock data: slice number 0 = never decoded
    mov edi, [h264_mbi]
    mov ecx, [h264_maxnmb]
    shl ecx, MI_SHIFT - 2           ; (dwords)
    rep stosd
    ; frame buffers
    xor ebx, ebx
    mov esi, h264_slots
.slot:
    mov eax, [h264_slotbytes]
    imul eax, ebx
    add eax, [h264_slotmem]
    mov ecx, [h264_ystride]         ; luma picture starts PAD rows + PAD in
    imul ecx, H264_PADY
    add ecx, H264_PADY
    add ecx, eax
    mov [esi + SL_Y], ecx
    add eax, [h264_ysize]
    mov ecx, [h264_cstride]
    imul ecx, H264_PADC
    add ecx, H264_PADC
    add ecx, eax
    mov [esi + SL_U], ecx
    add eax, [h264_csize]
    mov ecx, [h264_cstride]
    imul ecx, H264_PADC
    add ecx, H264_PADC
    add ecx, eax
    mov [esi + SL_V], ecx
    add eax, [h264_csize]
    mov [esi + SL_MOT], eax
    add esi, SL_SZ
    inc ebx
    cmp ebx, H264_NSLOT
    jb .slot
    mov dword [h264_cur], -1
    mov dword [h264_lastref], -1
    mov dword [h264_maxltidx], -1
    mov dword [h264_slicectr], 1
    mov dword [h264_need_idr], 1
    mov eax, ARG(0)
    mov [h264_ctxp], eax
    call h264_save
    xor eax, eax
    CLEAVE
.fail:
    or eax, -1
    CLEAVE

; h264_load / h264_save: copy the state in from / out to the context at
; [h264_ctxp]. EAX kept; ECX changed.
h264_load:
    push esi
    push edi
    mov esi, [h264_ctxp]
    mov edi, h264_S_begin
    mov ecx, H264_STATE_SZ / 4
    rep movsd
    pop edi
    pop esi
    ret
h264_save:
    push esi
    push edi
    mov esi, h264_S_begin
    mov edi, [h264_ctxp]
    mov ecx, H264_STATE_SZ / 4
    rep movsd
    pop edi
    pop esi
    ret

; h264_enter: start of an entry point that decodes: the state is loaded and
; the frame lent by the previous h264_get_frame is taken back.
; EAX = the context.
h264_enter:
    mov [h264_ctxp], eax
    call h264_load
    xor ecx, ecx
.l: and dword [h264_slots + ecx + SL_FLAGS], ~F_LENT
    add ecx, SL_SZ
    cmp ecx, H264_NSLOT * SL_SZ
    jb .l
    ret

; int h264_decode_nal(ctx, nal, len): one NAL unit (header byte first, no
; start code). 1 = a frame is ready for h264_get_frame, 0 = none, < 0 =
; the NAL unit was damaged or not supported (decoding goes on).
EXPORT(h264_decode_nal)
h264_decode_nal:
    CENTER
    mov eax, ARG(0)
    call h264_enter
    mov esi, ARG(1)
    mov ecx, ARG(2)
    call h264_nal
    call h264_result
    call h264_save
    CLEAVE

; h264_result: EAX = a NAL unit's result -> EAX = 1 if frames wait for
; h264_get_frame (they must be fetched whatever else happened), else EAX.
h264_result:
    cmp dword [h264_fifo_n], 0
    je .r
    mov eax, 1
.r: ret

; int h264_decode_avcc(ctx, avcc, len): the parameter sets of an MP4 'avcC'
; box (AVCDecoderConfigurationRecord, ISO/IEC 14496-15; with or without the
; 8-byte box header). Returns the size of the NAL length fields (1, 2 or 4)
; or -1 if the record is damaged.
EXPORT(h264_decode_avcc)
h264_decode_avcc:
    CENTER
    sub esp, 8
    mov eax, ARG(0)
    call h264_enter
    mov esi, ARG(1)
    mov ebx, ARG(2)                 ; EBX = bytes left
    cmp ebx, 8
    jb .bad
    cmp dword [esi + 4], 'avcC'     ; skip a box header
    jne .rec
    add esi, 8
    sub ebx, 8
.rec:
    cmp ebx, 7
    jb .bad
    cmp byte [esi], 1               ; configurationVersion
    jne .bad
    movzx eax, byte [esi + 4]
    and eax, 3
    inc eax                         ; lengthSizeMinusOne + 1
    cmp eax, 3
    je .bad
    mov [ebp - 16], eax
    movzx edi, byte [esi + 5]
    and edi, 31                     ; numOfSequenceParameterSets
    add esi, 6
    sub ebx, 6
    mov dword [ebp - 20], 0          ; 0 = SPS, 1 = PPS
.sets:
    test edi, edi
    jz .next_kind
.one:
    cmp ebx, 2
    jb .bad
    movzx ecx, word [esi]
    xchg cl, ch                     ; big-endian length
    add esi, 2
    sub ebx, 2
    cmp ecx, ebx
    ja .bad
    push ecx
    push esi
    push edi
    push ebx
    test ecx, ecx
    jz .skip
    call h264_nal
.skip:
    pop ebx
    pop edi
    pop esi
    pop ecx
    add esi, ecx
    sub ebx, ecx
    dec edi
    jnz .one
.next_kind:
    cmp dword [ebp - 20], 0
    jne .done
    mov dword [ebp - 20], 1
    test ebx, ebx
    jz .done
    movzx edi, byte [esi]           ; numOfPictureParameterSets
    inc esi
    dec ebx
    jmp .sets
.done:
    mov eax, [ebp - 16]
    jmp .out
.bad:
    or eax, -1
.out:
    call h264_save
    add esp, 8
    CLEAVE

; int h264_get_frame(ctx, H264FRAME *f): 1 = the next frame in display order
; was written to *f (its pixels stay valid until the next call of
; h264_decode_nal / h264_flush), 0 = no frame waiting
EXPORT(h264_get_frame)
h264_get_frame:
    CENTER
    mov eax, ARG(0)
    mov [h264_ctxp], eax
    call h264_load
    xor eax, eax
    cmp dword [h264_fifo_n], 0
    je .out
    mov ebx, [h264_fifo]            ; take the first one off the list
    mov esi, h264_fifo + 4
    mov edi, h264_fifo
    mov ecx, H264_NSLOT - 1
    rep movsd
    dec dword [h264_fifo_n]
    imul ebx, SL_SZ
    add ebx, h264_slots
%ifdef NATIVE
    mov eax, [ebx + SL_MOT]         ; (for h264_dbg_motion)
    mov [h264_dbg_mot], eax
%endif
    mov eax, [ebx + SL_FLAGS]
    and eax, ~F_FIFO
    or eax, F_LENT
    mov [ebx + SL_FLAGS], eax
    mov edi, ARG(1)
    mov eax, [ebx + SL_CY]          ; visible top-left
    imul eax, [h264_ystride]
    add eax, [ebx + SL_CX]
    add eax, [ebx + SL_Y]
    mov [edi + H264F_Y], eax
    mov eax, [ebx + SL_CY]
    shr eax, 1
    imul eax, [h264_cstride]
    mov edx, [ebx + SL_CX]
    shr edx, 1
    add eax, edx
    mov edx, eax
    add eax, [ebx + SL_U]
    mov [edi + H264F_U], eax
    add edx, [ebx + SL_V]
    mov [edi + H264F_V], edx
    mov eax, [h264_ystride]
    mov [edi + H264F_YSTRIDE], eax
    mov eax, [h264_cstride]
    mov [edi + H264F_CSTRIDE], eax
    mov eax, [ebx + SL_W]
    mov [edi + H264F_W], eax
    mov eax, [ebx + SL_H]
    mov [edi + H264F_H], eax
    mov eax, [ebx + SL_POC]
    mov [edi + H264F_POC], eax
    mov eax, [ebx + SL_FLAGS]
    xor edx, edx
    test eax, F_BAD
    jz .f1
    or edx, 1
.f1:
    test eax, F_IDR
    jz .f2
    or edx, 2
.f2:
    mov [edi + H264F_FLAGS], edx
    movzx eax, word [ebx + SL_SARW]
    mov [edi + H264F_SARW], eax
    movzx eax, word [ebx + SL_SARH]
    mov [edi + H264F_SARH], eax
    call h264_save
    mov eax, 1
.out:
    CLEAVE

%ifdef NATIVE
; void *h264_dbg_motion(void): (native tests only) the motion data (MO_SZ
; bytes per macroblock) of the frame h264_get_frame gave out last
EXPORT(h264_dbg_motion)
h264_dbg_motion:
    mov eax, [h264_dbg_mot]
    ret
section .bss
h264_dbg_mot    resd 1
section .text
%endif

; int h264_flush(ctx): end of the stream (or before a seek): the picture
; being decoded is finished and every frame still held is released for
; h264_get_frame. The references are dropped: decoding starts again at the
; next IDR picture. Returns 1 if frames wait, else 0.
EXPORT(h264_flush)
h264_flush:
    CENTER
    mov eax, ARG(0)
    call h264_enter
    call h264_finish_pic
    call h264_output_all
    call h264_unmark_all
    mov dword [h264_need_idr], 1
    mov dword [h264_have_ref], 0
    xor eax, eax
    call h264_result
    call h264_save
    CLEAVE

; =============================================================================
;  NAL units
; =============================================================================

; h264_nal: ESI = NAL unit, ECX = its length -> EAX = 0 ok / < 0 error.
; Any register may change except EBP.
h264_nal:
    test ecx, ecx
    jz .bad
    movzx eax, byte [esi]
    test al, 0x80                   ; forbidden_zero_bit
    jnz .bad
    mov edx, eax
    shr edx, 5
    mov [h264_nalref], edx
    and eax, 31
    mov [h264_naltype], eax
    cmp eax, 1                      ; only these are decoded
    je .rbsp
    cmp eax, 5
    je .rbsp
    cmp eax, 7
    je .rbsp
    cmp eax, 8
    je .rbsp
    xor eax, eax                    ; SEI, AUD, end of sequence, filler ...
    ret
.rbsp:
    inc esi                         ; skip the header byte
    dec ecx
    call h264_unescape
    mov eax, [h264_naltype]
    cmp eax, 7
    je h264_parse_sps
    cmp eax, 8
    je h264_parse_pps
    jmp h264_slice
.bad:
    or eax, -1
    ret

; h264_unescape: ESI = NAL payload, ECX = length -> the RBSP (emulation
; prevention bytes 0x03 after two zero bytes removed) in the RBSP buffer,
; at most h264_rbspcap bytes, then H264_RBSPPAD zero bytes; the bit reader
; is set up at its start, h264_bend = position of rbsp_stop_one_bit.
h264_unescape:
    push ebx
    mov edi, [h264_rbsp]
    mov [h264_bbuf], edi
    cmp ecx, [h264_rbspcap]
    jbe .lenok
    mov ecx, [h264_rbspcap]
.lenok:
    xor edx, edx                    ; EDX = zero bytes just copied
    jecxz .end
.l: mov al, [esi]
    inc esi
    cmp edx, 2
    jb .copy
    cmp al, 3
    jne .copy
    xor edx, edx                    ; 00 00 03: drop the 03
    dec ecx
    jnz .l
    jmp .end
.copy:
    mov [edi], al
    inc edi
    inc edx
    test al, al
    jz .z
    xor edx, edx
.z: dec ecx
    jnz .l
.end:
    mov ebx, edi                    ; EBX = end of the RBSP
    mov ecx, H264_RBSPPAD / 4
    xor eax, eax
    push edi
    rep stosd
    pop edi
    ; find the stop bit: the last one bit of the last non-zero byte
    mov esi, [h264_bbuf]
.back:
    cmp edi, esi
    jbe .empty
    dec edi
    movzx eax, byte [edi]
    test eax, eax
    jz .back
    bsf ecx, eax                    ; trailing zero bits
    sub edi, esi
    shl edi, 3
    add edi, 7
    sub edi, ecx
    mov [h264_bend], edi
    jmp .done
.empty:
    mov dword [h264_bend], 0
.done:
    mov dword [h264_bp], 0
    mov dword [h264_berr], 0
    pop ebx
    ret

; =============================================================================
;  Bit reader. The RBSP is followed by zero bytes, so reads beyond its end
;  return zeros; h264_bad_pos says whether that happened.
; =============================================================================

; h264_peek: EAX = the next 32 bits (first bit in bit 31). ECX EDX changed.
h264_peek:
    mov ecx, [h264_bp]
    mov edx, ecx
    shr edx, 3
    add edx, [h264_bbuf]
    mov eax, [edx]
    mov edx, [edx + 4]
    bswap eax
    bswap edx
    and ecx, 7
    shld eax, edx, cl
    ret

; h264_u: ECX = n (0..32) -> EAX = the next n bits. EDX changed.
h264_u:
    test ecx, ecx
    jz .zero
    push ecx
    call h264_peek
    pop ecx
    add [h264_bp], ecx
    neg ecx
    add ecx, 32
    shr eax, cl
    ret
.zero:
    xor eax, eax
    ret

; h264_u1: EAX = the next bit. EDX changed.
h264_u1:
    push ecx
    mov edx, [h264_bp]
    mov eax, edx
    shr eax, 3
    add eax, [h264_bbuf]
    movzx eax, byte [eax]
    mov ecx, edx
    and ecx, 7
    xor ecx, 7
    shr eax, cl
    and eax, 1
    inc edx
    mov [h264_bp], edx
    pop ecx
    ret

; h264_ue: EAX = ue(v) (Exp-Golomb, 9.1). 32 zero bits set h264_berr and
; return 0xFFFFFFFF. ECX EDX changed.
h264_ue:
    call h264_peek
    bsr ecx, eax
    jz .bad
    cmp ecx, 16
    jb .long
    mov edx, ecx                    ; k = position of the first one bit
    lea ecx, [edx * 2 - 31]         ; leading zeros lz = 31 - k; the code
    shr eax, cl                     ; is the top 2 lz + 1 bits
    dec eax
    neg edx
    lea edx, [edx * 2 + 63]         ; 2 lz + 1
    add [h264_bp], edx
    ret
.long:                              ; 16 or more leading zeros
    mov edx, 31
    sub edx, ecx                    ; lz
    push edx
    inc edx
    add [h264_bp], edx
    mov ecx, [esp]
    call h264_u                     ; the lz bits after the one bit
    pop ecx
    mov edx, 1
    shl edx, cl
    lea eax, [eax + edx - 1]
    ret
.bad:
    mov dword [h264_berr], 1
    add dword [h264_bp], 32
    or eax, -1
    ret

; h264_se: EAX = se(v). ECX EDX changed.
h264_se:
    call h264_ue
    test al, 1
    jnz .pos
    shr eax, 1                      ; even codeNum k -> -(k / 2)
    neg eax
    ret
.pos:
    shr eax, 1                      ; odd k -> (k + 1) / 2
    inc eax
    ret

; h264_bad_pos: ZF = 0 (jnz taken) if the reader went past the end of the
; RBSP or met an invalid code. EAX changed.
h264_bad_pos:
    mov eax, [h264_bp]
    cmp eax, [h264_bend]
    ja .bad
    cmp dword [h264_berr], 0
    ret
.bad:
    or eax, 1                       ; (clears ZF)
    ret

; h264_more_data: CF = 1 (jc taken) if slice data remains before the stop
; bit (more_rbsp_data). EAX changed.
h264_more_data:
    mov eax, [h264_bp]
    cmp eax, [h264_bend]
    ret

; =============================================================================
;  Parameter sets
; =============================================================================

; h264_parse_sps: the RBSP of a sequence parameter set (7.3.2.1) -> stored
; in the table under its id. EAX = 0 / -1. EBX ESI EDI changed.
h264_parse_sps:
    mov ecx, 24
    call h264_u
    mov ebx, eax                    ; profile_idc, constraint flags, level
    call h264_ue
    cmp eax, 31
    ja .bad
    ; parse into the spare entry (the active-SPS copy is not touched): use
    ; the scratch area at the end of the table entry of this id only once
    ; the whole SPS is known to be good
    mov edi, h264_spsbuf
    push eax
    push edi
    mov ecx, SPS_SZ / 4
    xor eax, eax
    rep stosd
    pop edi
    pop eax
    mov [edi + SPS_ID], eax
    mov eax, ebx
    shr eax, 16
    mov [edi + SPS_PROFILE], al
    mov [edi + SPS_LEVEL], bl
    mov byte [edi + SPS_CHROMA], 1
    mov dword [edi + SPS_REORDER], -1
    mov dword [edi + SPS_MAXDEC], -1
    shr ebx, 16                     ; profiles with the chroma / bit depth part
    cmp bl, 100
    je .hi
    cmp bl, 110
    je .hi
    cmp bl, 122
    je .hi
    cmp bl, 244
    je .hi
    cmp bl, 44
    je .hi
    cmp bl, 83
    je .hi
    cmp bl, 86
    je .hi
    cmp bl, 118
    je .hi
    cmp bl, 128
    je .hi
    cmp bl, 138
    je .hi
    cmp bl, 139
    je .hi
    cmp bl, 134
    je .hi
    cmp bl, 135
    je .hi
    jmp .common
.hi:
    call h264_ue                    ; chroma_format_idc
    cmp eax, 3
    ja .bad
    mov [edi + SPS_CHROMA], al
    cmp eax, 1
    je .chok
    mov byte [edi + SPS_UNSUP], 1
.chok:
    cmp eax, 3
    jne .nosep
    call h264_u1                    ; separate_colour_plane_flag
.nosep:
    call h264_ue                    ; bit_depth_luma_minus8
    mov ebx, eax
    call h264_ue                    ; bit_depth_chroma_minus8
    or ebx, eax
    jz .d8
    mov byte [edi + SPS_UNSUP], 2
.d8:
    call h264_u1                    ; qpprime_y_zero_transform_bypass_flag
    test eax, eax
    jz .nobyp
    mov byte [edi + SPS_UNSUP], 3
.nobyp:
    call h264_u1                    ; seq_scaling_matrix_present_flag
    test eax, eax
    jz .common
    mov byte [edi + SPS_SCALING], 1
    mov ebx, 8                      ; 8 lists (12 for 4:4:4)
    cmp byte [edi + SPS_CHROMA], 3
    jne .sl0
    mov ebx, 12
.sl0:
    mov dword [h264_tmpi], 0        ; list number
.sl:
    call h264_u1                    ; seq_scaling_list_present_flag[i]
    test eax, eax
    jz .slnext
    mov eax, 16                     ; lists 0..5 are 4x4, the rest 8x8
    cmp dword [h264_tmpi], 6
    jb .sl4
    mov eax, 64
.sl4:
    call h264_skip_scaling
.slnext:
    inc dword [h264_tmpi]
    cmp [h264_tmpi], ebx
    jb .sl
.common:
    call h264_ue                    ; log2_max_frame_num_minus4
    cmp eax, 12
    ja .bad
    add eax, 4
    mov [edi + SPS_LOG2FN], al
    call h264_ue                    ; pic_order_cnt_type
    cmp eax, 2
    ja .bad
    mov [edi + SPS_POCTYPE], al
    test eax, eax
    jnz .poc1
    call h264_ue                    ; log2_max_pic_order_cnt_lsb_minus4
    cmp eax, 12
    ja .bad
    add eax, 4
    mov [edi + SPS_LOG2POC], al
    jmp .pocdone
.poc1:
    cmp eax, 1
    jne .pocdone
    call h264_u1
    mov [edi + SPS_DPOCZ], al
    call h264_se
    mov [edi + SPS_OFFNR], eax
    call h264_se
    mov [edi + SPS_OFFTB], eax
    call h264_ue
    cmp eax, 255
    ja .bad
    mov [edi + SPS_NCYCLE], eax
    mov ebx, eax
    xor esi, esi                    ; ESI = sum of the offsets
    lea edx, [edi + SPS_OFFREF]
.cyc:
    test ebx, ebx
    jz .cycdone
    push edx
    call h264_se
    pop edx
    mov [edx], eax
    add esi, eax
    add edx, 4
    dec ebx
    jmp .cyc
.cycdone:
    mov [edi + SPS_EXPDELTA], esi
.pocdone:
    call h264_ue                    ; max_num_ref_frames
    cmp eax, 16
    ja .bad
    mov [edi + SPS_NREF], al
    call h264_u1
    mov [edi + SPS_GAPS], al
    call h264_ue                    ; pic_width_in_mbs_minus1
    cmp eax, H264_MAXMBW - 1
    ja .bad
    inc eax
    mov [edi + SPS_MBW], eax
    call h264_ue                    ; pic_height_in_map_units_minus1
    cmp eax, H264_MAXMBH - 1
    ja .bad
    inc eax
    mov [edi + SPS_MBH], eax
    call h264_u1                    ; frame_mbs_only_flag
    test eax, eax
    jnz .frames
    mov byte [edi + SPS_UNSUP], 4   ; interlaced
    shl dword [edi + SPS_MBH], 1
    call h264_u1                    ; mb_adaptive_frame_field_flag
.frames:
    call h264_u1                    ; direct_8x8_inference_flag
    mov [edi + SPS_D8I], al
    call h264_u1                    ; frame_cropping_flag
    test eax, eax
    jz .nocrop
    mov ebx, SPS_CROPL
.crop:
    call h264_ue
    cmp eax, 8192
    ja .bad
    shl eax, 1                      ; CropUnitX = CropUnitY = 2 (4:2:0 frames)
    mov [edi + ebx], eax
    add ebx, 4
    cmp ebx, SPS_CROPB
    jbe .crop
    mov eax, [edi + SPS_CROPL]      ; at least one pixel must remain
    add eax, [edi + SPS_CROPR]
    mov edx, [edi + SPS_MBW]
    shl edx, 4
    cmp eax, edx
    jae .badcrop
    mov eax, [edi + SPS_CROPT]
    add eax, [edi + SPS_CROPB]
    mov edx, [edi + SPS_MBH]
    shl edx, 4
    cmp eax, edx
    jb .nocrop
.badcrop:
    xor eax, eax
    mov [edi + SPS_CROPL], eax
    mov [edi + SPS_CROPR], eax
    mov [edi + SPS_CROPT], eax
    mov [edi + SPS_CROPB], eax
.nocrop:
    call h264_bad_pos
    jnz .bad
    call h264_u1                    ; vui_parameters_present_flag
    test eax, eax
    jz .store
    call h264_parse_vui
.store:
    mov esi, h264_spsbuf
    mov byte [esi + SPS_VALID], 1
    mov edi, [esi + SPS_ID]
    imul edi, SPS_SZ
    add edi, [h264_spstab]
    mov ecx, SPS_SZ / 4
    rep movsd
    xor eax, eax
    ret
.bad:
    or eax, -1
    ret

; h264_skip_scaling: EAX = list size (16 / 64): read a scaling_list()
; (7.3.2.1.1.1) and drop it. EBX EDI kept; ESI changed.
h264_skip_scaling:
    push ebx
    mov ebx, eax                    ; entries
    mov esi, 8                      ; lastScale, nextScale = 8
.l: test esi, esi
    jz .next
    call h264_se                    ; delta_scale
    add eax, esi                    ; nextScale = (last + delta + 256) % 256
    add eax, 256
    and eax, 255
    mov esi, eax
.next:
    dec ebx
    jnz .l
    pop ebx
    ret

; h264_parse_vui: the VUI (E.1.1) of the SPS being read at EDI: aspect
; ratio, num_reorder_frames and max_dec_frame_buffering. A damaged VUI is
; ignored. EBX ESI changed.
h264_parse_vui:
    call h264_u1                    ; aspect_ratio_info_present_flag
    test eax, eax
    jz .noar
    mov ecx, 8
    call h264_u
    cmp eax, 255
    jne .aridc
    mov ecx, 16
    call h264_u
    mov [edi + SPS_SARW], eax
    mov ecx, 16
    call h264_u
    mov [edi + SPS_SARH], eax
    jmp .noar
.aridc:
    dec eax
    cmp eax, 15
    ja .noar
    movzx edx, word [h264_sar + eax * 4]
    mov [edi + SPS_SARW], edx
    movzx edx, word [h264_sar + eax * 4 + 2]
    mov [edi + SPS_SARH], edx
.noar:
    call h264_u1                    ; overscan_info_present_flag
    test eax, eax
    jz .noov
    call h264_u1
.noov:
    call h264_u1                    ; video_signal_type_present_flag
    test eax, eax
    jz .novs
    mov ecx, 4                      ; video_format, video_full_range_flag
    call h264_u
    call h264_u1                    ; colour_description_present_flag
    test eax, eax
    jz .novs
    mov ecx, 24
    call h264_u
.novs:
    call h264_u1                    ; chroma_loc_info_present_flag
    test eax, eax
    jz .nocl
    call h264_ue
    call h264_ue
.nocl:
    call h264_u1                    ; timing_info_present_flag
    test eax, eax
    jz .notime
    mov ecx, 32
    call h264_u
    mov ecx, 32
    call h264_u
    call h264_u1
.notime:
    call h264_u1                    ; nal_hrd_parameters_present_flag
    mov ebx, eax
    test eax, eax
    jz .nonal
    call h264_skip_hrd
.nonal:
    call h264_u1                    ; vcl_hrd_parameters_present_flag
    or ebx, eax
    test eax, eax
    jz .novcl
    call h264_skip_hrd
.novcl:
    test ebx, ebx
    jz .nolow
    call h264_u1                    ; low_delay_hrd_flag
.nolow:
    call h264_u1                    ; pic_struct_present_flag
    call h264_u1                    ; bitstream_restriction_flag
    test eax, eax
    jz .check
    call h264_u1                    ; motion_vectors_over_pic_boundaries
    call h264_ue                    ; max_bytes_per_pic_denom
    call h264_ue                    ; max_bits_per_mb_denom
    call h264_ue                    ; log2_max_mv_length_horizontal
    call h264_ue                    ; log2_max_mv_length_vertical
    call h264_ue                    ; max_num_reorder_frames
    mov ebx, eax
    call h264_ue                    ; max_dec_frame_buffering
    mov esi, eax
    call h264_bad_pos
    jnz .drop
    mov eax, esi
    cmp ebx, 16
    ja .drop
    cmp eax, 16
    ja .drop
    mov [edi + SPS_REORDER], ebx
    mov [edi + SPS_MAXDEC], eax
.check:
    ret
.drop:
    mov dword [edi + SPS_REORDER], -1
    mov dword [edi + SPS_MAXDEC], -1
    ret

; h264_skip_hrd: read hrd_parameters() (E.1.2) and drop them. ESI changed.
h264_skip_hrd:
    call h264_ue                    ; cpb_cnt_minus1
    cmp eax, 31
    ja .bad
    lea esi, [eax + 1]
    mov ecx, 8                      ; bit_rate_scale, cpb_size_scale
    call h264_u
.l: call h264_ue                    ; bit_rate_value_minus1
    call h264_ue                    ; cpb_size_value_minus1
    call h264_u1                    ; cbr_flag
    dec esi
    jnz .l
    mov ecx, 20                     ; four 5-bit lengths
    call h264_u
.bad:
    ret

; h264_parse_pps: the RBSP of a picture parameter set (7.3.2.2) -> stored
; under its id. EAX = 0 / -1. EBX ESI EDI changed.
h264_parse_pps:
    call h264_ue                    ; pic_parameter_set_id
    cmp eax, 255
    ja .bad
    mov [h264_ppsid_tmp], eax
    mov edi, h264_ppsbuf
    xor eax, eax
    mov ecx, PPS_SZ / 4
    push edi
    rep stosd
    pop edi
    call h264_ue                    ; seq_parameter_set_id
    cmp eax, 31
    ja .bad
    mov [edi + PPS_SPS], al
    call h264_u1                    ; entropy_coding_mode_flag
    mov [edi + PPS_CABAC], al
    call h264_u1                    ; bottom_field_pic_order_in_frame_present
    mov [edi + PPS_BFPOC], al
    call h264_ue                    ; num_slice_groups_minus1
    cmp eax, 7
    ja .bad
    inc eax
    mov [edi + PPS_NSG], al
    cmp eax, 1
    je .nofmo
    ; slice groups: read the map description (FMO is not decoded)
    lea esi, [eax - 1]              ; ESI = num_slice_groups_minus1
    call h264_ue                    ; slice_group_map_type
    cmp eax, 6
    ja .bad
    mov [edi + PPS_SGTYPE], eax
    test eax, eax
    jnz .sg2
    inc esi                         ; run_length_minus1 for every group
.rl:
    call h264_ue
    dec esi
    jnz .rl
    jmp .nofmo
.sg2:
    cmp eax, 2
    jne .sg3
.tlbr:
    call h264_ue                    ; top_left, bottom_right
    call h264_ue
    dec esi
    jnz .tlbr
    jmp .nofmo
.sg3:
    cmp eax, 6
    je .sg6
    cmp eax, 3
    jb .nofmo
    call h264_u1                    ; slice_group_change_direction_flag
    call h264_ue                    ; slice_group_change_rate_minus1
    inc eax
    mov [edi + PPS_SGRATE], eax
    jmp .nofmo
.sg6:
    call h264_ue                    ; pic_size_in_map_units_minus1
    cmp eax, H264_MAXNMB
    jae .bad
    lea edx, [eax + 1]              ; EDX = map units
    lea eax, [esi + 1]              ; bits per slice_group_id:
    xor ecx, ecx                    ;   Ceil(Log2(num_slice_groups))
.lg:
    push edx
    mov edx, 1
    shl edx, cl
    cmp edx, eax
    pop edx
    jae .lgd
    inc ecx
    jmp .lg
.lgd:
    imul ecx, edx
    add [h264_bp], ecx
.nofmo:
    call h264_ue                    ; num_ref_idx_l0_default_active_minus1
    cmp eax, 31
    ja .bad
    inc eax
    mov [edi + PPS_NREF0], al
    call h264_ue
    cmp eax, 31
    ja .bad
    inc eax
    mov [edi + PPS_NREF1], al
    call h264_u1                    ; weighted_pred_flag
    mov [edi + PPS_WP], al
    mov ecx, 2
    call h264_u                     ; weighted_bipred_idc
    mov [edi + PPS_WBI], al
    call h264_se                    ; pic_init_qp_minus26
    add eax, 26
    cmp eax, 51
    ja .bad
    mov [edi + PPS_QP], al
    call h264_se                    ; pic_init_qs_minus26
    call h264_se                    ; chroma_qp_index_offset
    add eax, 12
    cmp eax, 24
    ja .bad
    sub eax, 12
    mov [edi + PPS_CQP], al
    mov [edi + PPS_CQP2], al
    call h264_u1
    mov [edi + PPS_DBK], al
    call h264_u1
    mov [edi + PPS_CIP], al
    call h264_u1
    mov [edi + PPS_RPC], al
    call h264_bad_pos
    jnz .bad
    call h264_more_data
    jnc .store
    call h264_u1                    ; transform_8x8_mode_flag
    mov [edi + PPS_T8], al
    call h264_u1                    ; pic_scaling_matrix_present_flag
    test eax, eax
    jz .noscale
    movzx esi, byte [edi + PPS_T8]  ; 6 + 2 * transform_8x8_mode_flag lists
    lea esi, [esi * 2 + 6]
    xor ebx, ebx
.psl:
    call h264_u1
    test eax, eax
    jz .pslnext
    mov eax, 16
    cmp ebx, 6
    jb .psl4
    mov eax, 64
.psl4:
    push esi
    call h264_skip_scaling
    pop esi
.pslnext:
    inc ebx
    cmp ebx, esi
    jb .psl
.noscale:
    call h264_se                    ; second_chroma_qp_index_offset
    add eax, 12
    cmp eax, 24
    ja .bad
    sub eax, 12
    mov [edi + PPS_CQP2], al
    call h264_bad_pos
    jnz .bad
.store:
    mov byte [edi + PPS_VALID], 1
    mov esi, edi
    imul edi, [h264_ppsid_tmp], PPS_SZ
    add edi, [h264_ppstab]
    mov ecx, PPS_SZ / 4
    rep movsd
    xor eax, eax
    ret
.bad:
    or eax, -1
    ret

section .bss
alignb 4
h264_spsbuf     resb SPS_SZ         ; a parameter set being read
h264_ppsbuf     resb PPS_SZ
h264_ppsid_tmp  resd 1
section .text

; =============================================================================
;  Slices
; =============================================================================

; h264_slice: the RBSP of a slice (nal_unit_type 1 or 5) -> EAX = 0 / < 0.
; Any register may change except EBP.
h264_slice:
    call h264_slice_header
    test eax, eax
    jnz .ret                        ; skipped (> 0 -> 0) or damaged
    ; is this the first slice of a new picture?
    cmp dword [h264_pic_on], 0
    je .newpic
    call h264_same_pic
    jnz .other
    mov eax, [h264_pic_done]        ; another slice of the current picture
    cmp eax, [h264_nmb]
    jb .slice
    xor eax, eax                    ; (all there already: a duplicate)
    ret
.other:
    call h264_finish_pic            ; the previous one ends (incomplete)
.newpic:
    call h264_start_pic
    test eax, eax
    jnz .ret
.slice:
    mov eax, [h264_slicectr]
    mov [h264_slicenum], eax
    inc dword [h264_slicectr]
    cmp dword [h264_sh_type], ST_I
    je .data
    call h264_build_lists           ; (a missing reference is replaced:
    test eax, eax                   ;  decode the slice anyway)
    jz .lists
    mov dword [h264_pic_err], 1
.lists:
    cmp dword [h264_sh_type], ST_B
    jne .data
    call h264_slice_bsetup          ; co-located picture, direct scaling,
.data:                              ;   implicit weights
    call h264_slice_data
    test eax, eax
    jz .complete
    mov dword [h264_pic_err], 1
.complete:
    push eax
    mov eax, [h264_pic_done]
    cmp eax, [h264_nmb]
    jb .notyet
    call h264_finish_pic
.notyet:
    pop eax
    ret
.ret:
    cmp eax, 0
    jle .r
    xor eax, eax
.r: ret

; h264_slice_header: read slice_header() (7.3.3) into h264_sh_*.
; EAX = 0 decode it, 1 skip it (no IDR yet, redundant slice, a feature
; that is not supported), -1 damaged. EBX ESI EDI changed.
h264_slice_header:
    call h264_ue                    ; first_mb_in_slice
    mov [h264_sh_firstmb], eax
    call h264_ue                    ; slice_type
    cmp eax, 9
    ja .bad
    cmp eax, 5
    jb .st
    sub eax, 5
.st:
    mov [h264_sh_type], eax
    call h264_ue                    ; pic_parameter_set_id
    cmp eax, 255
    ja .bad
    mov [h264_sh_ppsid], eax
    imul esi, eax, PPS_SZ
    add esi, [h264_ppstab]
    mov [h264_sh_pps], esi
    cmp byte [esi + PPS_VALID], 0
    je .bad
    movzx edi, byte [esi + PPS_SPS]
    imul edi, SPS_SZ
    add edi, [h264_spstab]
    cmp byte [edi + SPS_VALID], 0
    je .bad
    xor eax, eax
    cmp dword [h264_naltype], 5
    sete al
    mov [h264_sh_idr], eax
    ; not an IDR picture: the active SPS must be the one this PPS names
    test eax, eax
    jnz .spsok
    cmp dword [h264_need_idr], 0
    jne .skip
    cmp dword [h264_act], 0
    je .skip
    mov edi, [h264_asps]
    movzx eax, byte [esi + PPS_SPS]
    cmp eax, [edi + SPS_ID]
    jne .bad
.spsok:
    mov [h264_sh_sps], edi          ; (for an IDR: the table entry; it is
                                    ;  activated when the picture starts)
    cmp byte [edi + SPS_UNSUP], 0
    jne .skip
    cmp byte [esi + PPS_CABAC], 0   ; CABAC: not supported
    jne .skip
    cmp byte [esi + PPS_NSG], 1     ; slice groups: not supported
    jne .skip
    cmp dword [h264_sh_type], ST_I  ; I, P and B slices (not SP / SI)
    ja .skip
    movzx ecx, byte [edi + SPS_LOG2FN]
    call h264_u                     ; frame_num
    mov [h264_sh_fn], eax
    xor eax, eax
    mov [h264_sh_idrid], eax
    mov [h264_sh_poclsb], eax
    mov [h264_sh_dpb], eax
    mov [h264_sh_dpoc0], eax
    mov [h264_sh_dpoc1], eax
    mov [h264_sh_rpc], eax
    cmp dword [h264_sh_idr], 0
    je .noidr
    call h264_ue                    ; idr_pic_id
    mov [h264_sh_idrid], eax
.noidr:
    mov al, [edi + SPS_POCTYPE]
    test al, al
    jnz .poct1
    movzx ecx, byte [edi + SPS_LOG2POC]
    call h264_u                     ; pic_order_cnt_lsb
    mov [h264_sh_poclsb], eax
    cmp byte [esi + PPS_BFPOC], 0
    je .pocd
    call h264_se                    ; delta_pic_order_cnt_bottom
    mov [h264_sh_dpb], eax
    jmp .pocd
.poct1:
    cmp al, 1
    jne .pocd
    cmp byte [edi + SPS_DPOCZ], 0
    jne .pocd
    call h264_se                    ; delta_pic_order_cnt[0]
    mov [h264_sh_dpoc0], eax
    cmp byte [esi + PPS_BFPOC], 0
    je .pocd
    call h264_se                    ; delta_pic_order_cnt[1]
    mov [h264_sh_dpoc1], eax
.pocd:
    cmp byte [esi + PPS_RPC], 0
    je .norpc
    call h264_ue                    ; redundant_pic_cnt
    mov [h264_sh_rpc], eax
.norpc:
    mov dword [h264_sh_dspat], 1
    cmp dword [h264_sh_type], ST_B
    jne .nodsp
    call h264_u1                    ; direct_spatial_mv_pred_flag
    mov [h264_sh_dspat], eax
.nodsp:
    movzx eax, byte [esi + PPS_NREF0]
    mov [h264_sh_nref0], eax
    movzx eax, byte [esi + PPS_NREF1]
    mov [h264_sh_nref1], eax
    mov dword [h264_sh_nrplm0], 0
    mov dword [h264_sh_nrplm1], 0
    cmp dword [h264_sh_type], ST_I
    je .noref
    call h264_u1                    ; num_ref_idx_active_override_flag
    test eax, eax
    jz .noovr
    call h264_ue                    ; num_ref_idx_l0_active_minus1
    cmp eax, 15                     ; (32 only for fields)
    ja .bad
    inc eax
    mov [h264_sh_nref0], eax
    cmp dword [h264_sh_type], ST_B
    jne .noovr
    call h264_ue                    ; num_ref_idx_l1_active_minus1
    cmp eax, 15
    ja .bad
    inc eax
    mov [h264_sh_nref1], eax
.noovr:
    cmp dword [h264_sh_nref0], 16
    ja .bad
    ; ref_pic_list_modification() for list 0 (and list 1 in B slices)
    mov edi, h264_sh_rplm0
    call h264_read_rplm
    test eax, eax
    js .bad
    mov [h264_sh_nrplm0], eax
    cmp dword [h264_sh_type], ST_B
    jne .noref
    cmp dword [h264_sh_nref1], 16
    ja .bad
    mov edi, h264_sh_rplm1
    call h264_read_rplm
    test eax, eax
    js .bad
    mov [h264_sh_nrplm1], eax
.noref:
    ; weighted prediction: explicit (a pred_weight_table) or implicit
    mov dword [h264_sh_wmode], 0
    mov eax, [h264_sh_type]
    cmp eax, ST_P
    jne .wpb
    cmp byte [esi + PPS_WP], 0
    je .nowp
    jmp .wpt
.wpb:
    cmp eax, ST_B
    jne .nowp
    movzx eax, byte [esi + PPS_WBI]
    cmp eax, 2
    ja .bad
    jb .wpb1
    mov dword [h264_sh_wmode], 2    ; implicit (computed with the lists)
    jmp .nowp
.wpb1:
    test eax, eax
    jz .nowp
.wpt:
    mov dword [h264_sh_wmode], 1
    call h264_parse_pwt
    test eax, eax
    jnz .bad
.nowp:
    ; dec_ref_pic_marking()
    xor eax, eax
    mov [h264_sh_noout], eax
    mov [h264_sh_ltref], eax
    mov [h264_sh_adapt], eax
    mov [h264_sh_nmmco], eax
    cmp dword [h264_nalref], 0
    je .nomark
    cmp dword [h264_sh_idr], 0
    je .adaptive
    call h264_u1                    ; no_output_of_prior_pics_flag
    mov [h264_sh_noout], eax
    call h264_u1                    ; long_term_reference_flag
    mov [h264_sh_ltref], eax
    jmp .nomark
.adaptive:
    call h264_u1                    ; adaptive_ref_pic_marking_mode_flag
    mov [h264_sh_adapt], eax
    test eax, eax
    jz .nomark
    xor ebx, ebx
.mmco:
    call h264_ue                    ; memory_management_control_operation
    test eax, eax
    jz .mmcod
    cmp eax, 6
    ja .bad
    cmp ebx, H264_MAXMMCO
    jae .bad
    imul edx, ebx, 12
    mov [h264_sh_mmco + edx], eax
    mov dword [h264_sh_mmco + edx + 4], 0
    mov dword [h264_sh_mmco + edx + 8], 0
    cmp eax, 5
    je .mmnext
    push eax
    call h264_ue                    ; the first value of 1, 2, 3, 4, 6
    imul edx, ebx, 12
    mov [h264_sh_mmco + edx + 4], eax
    pop eax
    cmp eax, 3
    jne .mmnext
    call h264_ue                    ; long_term_frame_idx of 3
    imul edx, ebx, 12
    mov [h264_sh_mmco + edx + 8], eax
.mmnext:
    inc ebx
    call h264_bad_pos
    jnz .bad
    jmp .mmco
.mmcod:
    mov [h264_sh_nmmco], ebx
.nomark:
    mov dword [h264_sh_cabinit], 0
    cmp byte [esi + PPS_CABAC], 0
    je .nocab
    cmp dword [h264_sh_type], ST_I
    je .nocab
    call h264_ue                    ; cabac_init_idc
    cmp eax, 2
    ja .bad
    mov [h264_sh_cabinit], eax
.nocab:
    call h264_se                    ; slice_qp_delta
    movsx edx, byte [esi + PPS_QP]
    add eax, edx
    cmp eax, 51
    ja .bad
    mov [h264_sh_qp], eax
    xor eax, eax
    mov [h264_sh_dbidc], eax
    mov [h264_sh_dba], eax
    mov [h264_sh_dbb], eax
    cmp byte [esi + PPS_DBK], 0
    je .nodbk
    call h264_ue                    ; disable_deblocking_filter_idc
    cmp eax, 2
    ja .bad
    mov [h264_sh_dbidc], eax
    cmp eax, 1
    je .nodbk
    call h264_se                    ; slice_alpha_c0_offset_div2
    add eax, 6
    cmp eax, 12
    ja .bad
    sub eax, 6
    shl eax, 1
    mov [h264_sh_dba], eax
    call h264_se                    ; slice_beta_offset_div2
    add eax, 6
    cmp eax, 12
    ja .bad
    sub eax, 6
    shl eax, 1
    mov [h264_sh_dbb], eax
.nodbk:
    call h264_bad_pos
    jnz .bad
    movsx eax, byte [esi + PPS_CQP]
    mov [h264_sh_cqp], eax
    movsx eax, byte [esi + PPS_CQP2]
    mov [h264_sh_cqp2], eax
    movzx eax, byte [esi + PPS_CIP]
    mov [h264_sh_cip], eax
    cmp dword [h264_sh_rpc], 0      ; redundant coded pictures: skipped (the
    jne .skip                       ; primary one is always decoded)
    xor eax, eax
    ret
.skip:
    mov eax, 1
    ret
.bad:
    or eax, -1
    ret

; h264_read_rplm: ref_pic_list_modification() of one list (7.3.3.1) into
; EDI (pairs idc, value) -> EAX = number of modifications, -1 if damaged.
; EBX changed.
h264_read_rplm:
    call h264_u1                    ; ref_pic_list_modification_flag_lX
    test eax, eax
    jz .r
    xor ebx, ebx
.l: call h264_ue                    ; modification_of_pic_nums_idc
    cmp eax, 3
    je .d
    ja .bad
    cmp ebx, H264_MAXRPLM
    jae .bad
    mov [edi + ebx * 8], eax
    call h264_ue                    ; abs_diff_pic_num_minus1 / long_term_pic_num
    mov [edi + ebx * 8 + 4], eax
    inc ebx
    call h264_bad_pos
    jnz .bad
    jmp .l
.d: mov eax, ebx
.r: ret
.bad:
    or eax, -1
    ret

; h264_parse_pwt: pred_weight_table() (7.3.3.2) -> h264_sh_lwd / _cwd
; (log2 of the denominators), the weights and offsets of every reference
; index in h264_wt (WT_SZ bytes each: luma weight, offset, Cb weight,
; offset, Cr weight, offset) and h264_wtf (bit 0: luma weighted, bit 1:
; chroma weighted). EAX = 0, or -1 if damaged. EBX EDI changed.
h264_parse_pwt:
    call h264_ue                    ; luma_log2_weight_denom
    cmp eax, 7
    ja .bad
    mov [h264_sh_lwd], eax
    call h264_ue                    ; chroma_log2_weight_denom
    cmp eax, 7
    ja .bad
    mov [h264_sh_cwd], eax
    xor ebx, ebx                    ; EBX = list * 32 + reference index
.ent:
    mov eax, ebx
    and eax, 31
    mov ecx, [h264_sh_nref0]
    cmp ebx, 32
    jb .n0
    mov ecx, [h264_sh_nref1]
.n0:
    cmp eax, ecx
    jae .nextlist
    imul edi, ebx, WT_SZ
    add edi, h264_wt
    mov ecx, [h264_sh_lwd]          ; defaults: 2^denominator, offset 0
    mov eax, 1
    shl eax, cl
    mov [edi], eax
    mov ecx, [h264_sh_cwd]
    mov eax, 1
    shl eax, cl
    mov [edi + 8], eax
    mov [edi + 16], eax
    xor eax, eax
    mov [edi + 4], eax
    mov [edi + 12], eax
    mov [edi + 20], eax
    mov byte [h264_wtf + ebx], 0
    call h264_u1                    ; luma_weight_lX_flag
    test eax, eax
    jz .noluma
    or byte [h264_wtf + ebx], 1
    call .weight
    jc .bad
    mov [edi], eax
    call .weight
    jc .bad
    mov [edi + 4], eax
.noluma:
    call h264_u1                    ; chroma_weight_lX_flag
    test eax, eax
    jz .nochroma
    or byte [h264_wtf + ebx], 2
    call .weight
    jc .bad
    mov [edi + 8], eax
    call .weight
    jc .bad
    mov [edi + 12], eax
    call .weight
    jc .bad
    mov [edi + 16], eax
    call .weight
    jc .bad
    mov [edi + 20], eax
.nochroma:
    inc ebx
    jmp .ent
.nextlist:
    cmp ebx, 32                     ; list 1 only in B slices
    jae .done
    cmp dword [h264_sh_type], ST_B
    jne .done
    mov ebx, 32
    jmp .ent
.done:
    call h264_bad_pos
    jnz .bad
    xor eax, eax
    ret
.bad:
    or eax, -1
    ret
; a weight or offset: se(v) in -128..127 -> EAX, CF = 1 if out of range
.weight:
    call h264_se
    lea ecx, [eax + 128]
    cmp ecx, 256
    cmc
    ret

; h264_same_pic: does the slice just read belong to the picture being
; decoded (7.4.1.2.4)? ZF = 1 (jz taken) yes. EAX changed.
h264_same_pic:
    mov eax, [h264_sh_fn]
    cmp eax, [h264_pic_fn]
    jne .r
    mov eax, [h264_sh_ppsid]
    cmp eax, [h264_pic_ppsid]
    jne .r
    mov eax, [h264_sh_idr]
    cmp eax, [h264_pic_idr]
    jne .r
    test eax, eax
    jz .noidr
    mov eax, [h264_sh_idrid]
    cmp eax, [h264_pic_idrid]
    jne .r
.noidr:
    mov eax, [h264_nalref]          ; nal_ref_idc differs with one being 0
    test eax, eax
    setz al
    mov ah, 0
    cmp dword [h264_pic_refidc], 0
    setz ah
    cmp al, ah
    jne .r
    mov eax, [h264_sh_poclsb]
    cmp eax, [h264_pic_poclsb]
    jne .r
    mov eax, [h264_sh_dpb]
    cmp eax, [h264_pic_dpb]
    jne .r
    mov eax, [h264_sh_dpoc0]
    cmp eax, [h264_pic_dpoc0]
    jne .r
    mov eax, [h264_sh_dpoc1]
    cmp eax, [h264_pic_dpoc1]
.r: ret

%include "src/h264_pic.inc"
%include "src/h264_mb.inc"
%include "src/h264_inter.inc"
%include "src/h264_dsp.inc"
