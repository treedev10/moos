; =============================================================================
;  aac.asm - AAC-LC audio decoder (MPEG-4 Audio, ISO/IEC 14496-3 subpart 4)
;
;  Decodes the audio of MP4 files and web videos: "mp4a.40.2" (AAC Low
;  Complexity), as raw access units (one MP4 sample = one frame of 1024
;  samples per channel), set up by the AudioSpecificConfig from the MP4's
;  esds box. Pure computation (see tests/native/README.md):
;
;    uint32_t aac_ctx_size(void);
;    int aac_init(void *ctx, const uint8_t *asc, uint32_t asclen);
;    int aac_info(void *ctx, uint32_t *rate, uint32_t *channels);
;    int aac_decode(void *ctx, const uint8_t *frame, uint32_t len, int16_t *out);
;        out: 1024 frames of interleaved 16-bit PCM (1 or 2 channels);
;        returns 1024, or < 0 if the frame is damaged (out is not touched)
;
;  How a frame is decoded (the numbers are sections of the standard):
;    1. The frame is a list of syntax elements, ended by END. Each SCE
;       (one channel), CPE (two channels) or LFE is decoded in turn; CCE,
;       DSE, PCE and FIL elements are read past (FIL carries HE-AAC's SBR
;       data, which is skipped: only the AAC-LC core is decoded).
;    2. A channel (individual_channel_stream, 4.4.2.7): window information
;       (one long window, or eight short ones in groups), sections (runs of
;       scale factor bands coded with one Huffman codebook), scale factors
;       (Huffman-coded differences), optional pulses and TNS filters, then
;       the spectral values: Huffman codewords of 4 or 2 values, with sign
;       bits and escape sequences (4.6.3). Codebooks 13-15 mean noise (PNS)
;       and intensity stereo bands, which carry no spectral values.
;    3. Inverse quantisation: x = sign(q) |q|^(4/3) 2^((sf - 100)/4) (4.6.1).
;       Noise bands get random values scaled to the coded energy (4.6.13).
;    4. In a channel pair: mid/side (L = M + S, R = M - S) and intensity
;       stereo (R = L scaled) per band (4.6.8).
;    5. TNS: an all-pole filter run along the spectrum of a band range (4.6.9).
;    6. Filter bank (4.6.11): inverse MDCT of 2048 (long) or 8 x 256 (short)
;       points, computed as a DCT-IV through a quarter-size complex FFT;
;       sine or Kaiser-Bessel-derived windows; ONLY_LONG, LONG_START,
;       EIGHT_SHORT and LONG_STOP sequences; overlap-add with the previous
;       frame's second half.
;    7. The channels are mixed into the output: mono, stereo, or for more
;       channels a stereo downmix:
;           left  = FL + a (FC + left surround + back centre)
;           right = FR + a (FC + right surround + back centre)
;       with a = 0.7071, both scaled so the left weights add up to 1, and
;       LFE left out. (This is what ffmpeg does when asked for stereo.)
;       Clipped to 16 bits, rounded to nearest.
;
;  Configurations: channelConfiguration 1-7, 11, 12, 14, or 0 with a
;  program_config_element; sampling rates 7.35 - 96 kHz (also explicit
;  rates). HE-AAC (object types 5 and 29, or SBR signalled with the 0x2B7
;  sync extension, or found in the frames): only the AAC-LC core is decoded,
;  so the output (and aac_info) has the core rate (half the full rate) and
;  PS streams are mono. Not supported (aac_init / aac_decode fail): other
;  object types (Main, SSR, LTP...), 960-sample frames, gain control.
;  CCEs are read past but not applied (encoders do not use them).
;
;  Two details follow ffmpeg's decoder where the standard is easy to read
;  two ways: intensity stereo bands are inverted wherever ms_used is set,
;  also when ms_mask_present = 2 says "every band" (ffmpeg's encoder relies
;  on this); and noise bands of a pair with M/S use one noise vector for
;  both channels (4.6.13.3).
;
;  Robustness: the frame is copied into aac_buf (with zero padding) and the
;  bit reader returns zeros once past its end, so every loop ends; after
;  each element and inside long loops the position is checked and the
;  frame is rejected if it overran. Every table index that comes from the
;  stream is range-checked. Errors unwind through aac_abort.
;
;  Calling convention: C (CENTER/CLEAVE). Inside, EBP points at the
;  channel being decoded (aac_ics0/aac_ics1) and loop state lives in .bss
;  (single-threaded). Floating point: SSE (scalar and packed, unaligned
;  loads only) and x87 for |q|^(4/3) of very large values. MXCSR is set to
;  round-to-nearest, flush-to-zero, all exceptions masked while decoding,
;  and restored on return.
;
;  Tables: src/aac_tables.inc (tools/gen_aac_tables.py).
; =============================================================================
%include "src/module.inc"
%include "src/aac_tables.inc"

; ----------------------------------------------------------------- context
; (the caller's memory, aac_ctx_size bytes; kept between frames)
AAC_C_MAGIC     equ 0
AAC_C_SFI       equ 4               ; sampling frequency index 0-12
AAC_C_RATE      equ 8               ; output sample rate (Hz)
AAC_C_CHCFG     equ 12              ; channelConfiguration
AAC_C_OUTCH     equ 16              ; output channels: 1 or 2
AAC_C_PCE       equ 20              ; 1: elements are matched by tag (PCE)
AAC_C_RND       equ 24              ; noise generator state
AAC_C_SCE       equ 32              ; 16 bytes: slot of each SCE (-1 none),
AAC_C_CPE       equ 48              ;  by order in the frame, or by tag
AAC_C_LFE       equ 64
AAC_C_WL        equ 80              ; 10 floats: weight of each slot in the
AAC_C_WR        equ 120             ;  left (or mono) and right output
AAC_C_SHAPE     equ 160             ; 10 dwords: last window shape per slot
AAC_C_OVL       equ 256             ; 10 x 1024 floats: overlap per slot
AAC_SLOTS       equ 8               ; channels that can be output
AAC_SCRATCH     equ 8               ; slots 8, 9: decoded and dropped
AAC_CTX_SIZE    equ AAC_C_OVL + 10 * 4096
AAC_MAGIC       equ 0x64434141      ; "AACd"
AAC_SEED        equ 0x2545F491

; ----------------------------------------------------------------- one channel
; (individual_channel_stream state, in .bss: aac_ics0 and aac_ics1)
AAC_I_SEQ       equ 0               ; window sequence 0-3
AAC_I_SHAPE     equ 4               ; 0 sine, 1 KBD
AAC_I_MAXSFB    equ 8
AAC_I_NWIN      equ 12              ; 1 or 8
AAC_I_NGRP      equ 16              ; window groups
AAC_I_GLEN      equ 20              ; 8 dwords: windows per group
AAC_I_NSWB      equ 52              ; scale factor bands of this window size
AAC_I_SWB       equ 56              ; -> band start offsets (words)
AAC_I_INFO      equ 60              ; (bytes of ics_info, shared by a pair)
AAC_I_PULSE     equ 60
AAC_I_NP        equ 64
AAC_I_PPOS      equ 68              ; 4 dwords
AAC_I_PAMP      equ 84              ; 4 dwords
AAC_I_TNS       equ 100
AAC_I_NFILT     equ 104             ; 8 dwords (per window)
AAC_I_CRES      equ 136             ; 8 dwords
AAC_I_TLEN      equ 168             ; 8 x 4 dwords (window, filter)
AAC_I_TORD      equ 296
AAC_I_TDIR      equ 424
AAC_I_TCOEF     equ 552             ; 8 x 4 x 16 signed bytes
AAC_I_BT        equ 1064            ; 128 bytes: codebook of band b, group g
AAC_I_SF        equ 1192            ;  at g*16 + b; 128 dwords: its scale
AAC_I_Q         equ 1712            ; 1024 dwords: quantised values
AAC_I_SPEC      equ 5808            ; 1024 floats: the spectrum
AAC_I_SIZE      equ 9904

AAC_ONLY_LONG   equ 0
AAC_LONG_START  equ 1
AAC_EIGHT_SHORT equ 2
AAC_LONG_STOP   equ 3

; error codes (returned negated)
AAC_E_CTX       equ 1               ; context not set up by aac_init
AAC_E_TOOLONG   equ 2               ; frame / config longer than 8192 bytes
AAC_E_NOEND     equ 3               ; frame ended before the END element
AAC_E_OVERRUN   equ 4               ; an element ran past the frame
AAC_E_RATE      equ 5               ; unknown sampling frequency
AAC_E_OBJTYPE   equ 6               ; not AAC-LC
AAC_E_FRAMELEN  equ 7               ; 960-sample frames
AAC_E_CONFIG    equ 8               ; bad channel configuration / PCE
AAC_E_RESERVED  equ 10              ; reserved bit set in ics_info
AAC_E_PREDICT   equ 11              ; prediction (AAC Main / LTP)
AAC_E_MAXSFB    equ 12              ; more bands than the window has
AAC_E_BOOK      equ 13              ; reserved codebook 12
AAC_E_DATA      equ 14              ; channel data ran past the frame
AAC_E_SECTION   equ 15              ; section past max_sfb
AAC_E_SCALE     equ 16              ; scale factor out of 0-255
AAC_E_PULSE     equ 17              ; bad pulse data
AAC_E_TNS       equ 20              ; TNS order too high
AAC_E_GAIN      equ 21              ; gain control (AAC SSR)
AAC_E_ESCAPE    equ 22              ; escape sequence too long
AAC_E_MS        equ 31              ; reserved ms_mask_present

; eax = the next %1 bits (1-25); keeps every other register
%macro AAC_GET 1
    push ecx
    mov ecx, %1
    call aac_getbits
    pop ecx
%endmacro

; return error %1 from the entry point (unwinds the stack)
%macro AAC_FAIL 1
    mov eax, -(%1)
    jmp aac_abort
%endmacro

;  Event counters for the native test (tests/native/aac_test.c), which
;  checks that its test data reaches every part of the decoder. Only in
;  NATIVE builds; in the kernel AAC_STAT is nothing. (inc changes the flags
;  except CF: used only where no flags are pending.)
AAC_S_FRAMES    equ 0               ; frames decoded
AAC_S_ELEMENT   equ 1               ; 1-7: SCE CPE CCE LFE DSE PCE FIL
AAC_S_SEQ       equ 8               ; 8-11: window sequences 0-3
AAC_S_KBD       equ 12              ; ics_info with the KBD shape
AAC_S_GROUPED   equ 13              ; eight short windows in 2-7 groups
AAC_S_COMMON    equ 14              ; CPE with common_window 1
AAC_S_SEPARATE  equ 15              ; CPE with common_window 0
AAC_S_MS1       equ 16              ; ms_mask_present 1
AAC_S_MS2       equ 17              ; ms_mask_present 2
AAC_S_PULSE     equ 18              ; pulse_data_present
AAC_S_TNS_LONG  equ 19              ; TNS filters (order > 0), long windows
AAC_S_TNS_SHORT equ 20              ; ... short windows
AAC_S_TNS_COMPR equ 21              ; ... with coef_compress
AAC_S_TNS_DOWN  equ 22              ; ... running downwards
AAC_S_TNS_HIGH  equ 23              ; ... of order 9-12
AAC_S_ESCAPE    equ 24              ; escape sequences
AAC_S_IS_BANDS  equ 25              ; intensity bands applied
AAC_S_IS_INV    equ 26              ; ... inverted by ms_used
AAC_S_PNS       equ 27              ; noise bands (per window)
AAC_S_PNS_PAIR  equ 28              ; noise bands shared by a pair (M/S)
AAC_S_MS_BANDS  equ 29              ; bands M/S was applied to
AAC_S_BIG       equ 30              ; |q| >= 1024
AAC_S_SBR       equ 31              ; FIL elements carrying SBR data
AAC_S_BOOK      equ 32              ; 32-47: bands coded with codebook 0-15
AAC_S_DSE_ALIGN equ 48              ; DSE with data_byte_align_flag
AAC_S_EXPLICIT  equ 49              ; aac_init: explicit sampling rate
AAC_S_PCE_CFG   equ 50              ; aac_init: channelConfiguration 0 (PCE)
AAC_S_SBR_CFG   equ 51              ; aac_init: HE-AAC object type 5 / 29
AAC_S_ONEGROUP  equ 52              ; eight short windows in one group
AAC_S_SPLIT     equ 53              ; eight short windows in eight groups
AAC_S_COUNT     equ 64
%ifdef NATIVE
%macro AAC_STAT 1
    inc dword [aac_stats + (%1) * 4]
%endmacro
%macro AAC_STATR 2                  ; counter %1 + register %2
    inc dword [aac_stats + (%1) * 4 + %2 * 4]
%endmacro
%else
%macro AAC_STAT 1
%endmacro
%macro AAC_STATR 2
%endmacro
%endif

; fail with error %1 if the reads went past the end of the data
%macro AAC_CHECK 1
    push eax
    mov eax, [aac_bitpos]
    cmp eax, [aac_bitend]
    pop eax
    jbe %%ok
    AAC_FAIL %1
%%ok:
%endmacro

; entry: C frame, remember ESP for aac_abort, our MXCSR
%macro AAC_ENTER 0
    CENTER
    mov [aac_esp], esp
    stmxcsr [aac_mxcsr]
    mov dword [aac_mxnew], 0x9F80   ; flush to zero, round to nearest, masked
    ldmxcsr [aac_mxnew]
%endmacro

%macro AAC_LEAVE 0
    ldmxcsr [aac_mxcsr]
    CLEAVE
%endmacro

section .bss
alignb 16
aac_buf         resb 8192 + 128     ; frame (or config) being read + zeros
aac_ics0        resb AAC_I_SIZE     ; first / only channel of an element
aac_ics1        resb AAC_I_SIZE     ; second channel of a CPE
aac_mix         resd 2048           ; output being mixed: left 1024, right 1024
aac_cbuf        resd 1024           ; FFT: 512 complex values
aac_ubuf        resd 1024           ; DCT-IV result
aac_tbuf        resd 2048           ; windowed IMDCT output of one frame
aac_wleft       resd 1024           ; windows built for LONG_STOP / START
aac_wright      resd 1024
aac_wright_s    resd 128            ; falling short window
aac_lpc         resd 16             ; TNS: filter coefficients 1..order
aac_lpcb        resd 16             ;  (step-up recursion scratch)
aac_lpct        resd 16             ;  (reflection coefficients)
aac_ms_used     resb 128            ; per band of a CPE: M/S on
aac_bitpos      resd 1              ; bit reader: position, end (bits)
aac_bitend      resd 1
aac_ctx         resd 1              ; context of the current call
aac_out         resd 1              ; output buffer of the current call
aac_esp         resd 1              ; ESP after CENTER (for aac_abort)
aac_mxcsr       resd 1              ; caller's MXCSR
aac_mxnew       resd 1
aac_common      resd 1              ; channel shares its pair's ics_info
aac_ms_present  resd 1
aac_gain        resd 1              ; global_gain of the channel
aac_nsce        resd 1              ; elements of each kind seen in a frame
aac_ncpe        resd 1
aac_nlfe        resd 1
aac_slot        resd 1
aac_aot         resd 1
aac_g           resd 1              ; loop state: group, window, band ...
aac_w0          resd 1
aac_w           resd 1
aac_wcnt        resd 1
aac_cb          resd 1
aac_tab         resd 1
aac_start       resd 1
aac_width       resd 1
aac_sbits       resd 1
aac_sesc        resd 1
aac_osf         resd 1              ; scale factor / intensity / noise
aac_ois         resd 1              ;  running values
aac_onz         resd 1
aac_nfirst      resd 1
aac_vy          resd 1              ; escape codebook pair being read
aac_vz          resd 1
aac_sy          resd 1
aac_sz          resd 1
aac_tw          resd 1              ; TNS loop state
aac_tf          resd 1
aac_ttop        resd 1
aac_tbot        resd 1
aac_tmaxb       resd 1
aac_tord        resd 1
aac_fb_slot     resd 1              ; filter bank state
aac_fb_prev     resd 1
aac_fb_left     resd 1
aac_fb_w        resd 1
aac_lists       resd 1              ; CCE
aac_ind         resd 1
aac_tmp         resd 4
%ifdef NATIVE
EXPORT(aac_stats)
aac_stats       resd AAC_S_COUNT    ; (see AAC_STAT)
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
; where an explicit sampling frequency starts to use each rate's tables
aac_rate_limits dd 92017, 75132, 55426, 46009, 37566, 27713, 23004, 18783
                dd 13856, 11502, 9391, 0
; output weights (left, right) of each channel role:
;   0 none/LFE, 1 front centre, 2 front left, 3 front right, 4 left
;   surround, 5 right surround, 6 back centre, 7 both at full level
aac_role_l      dd 0.0, 0.70710678, 1.0, 0.0, 0.70710678, 0.0, 0.70710678, 1.0
aac_role_r      dd 0.0, 0.70710678, 0.0, 1.0, 0.0, 0.70710678, 0.70710678, 1.0
; element order of the channel configurations 0-15: S = SCE, C = CPE,
; L = LFE (Table 1.19); 0 = not supported here (0 itself uses the PCE)
%macro AAC_SEQ 1
%%s: db %1
    times 8 - ($ - %%s) db 0
%endmacro
aac_cfg_seq:
    AAC_SEQ 0
    AAC_SEQ 'S'                     ; 1: mono
    AAC_SEQ 'C'                     ; 2: stereo
    AAC_SEQ 'SC'                    ; 3: 3.0
    AAC_SEQ 'SCS'                   ; 4: 4.0
    AAC_SEQ 'SCC'                   ; 5: 5.0
    AAC_SEQ 'SCCL'                  ; 6: 5.1
    AAC_SEQ 'SCCCL'                 ; 7: 7.1
    AAC_SEQ 0
    AAC_SEQ 0
    AAC_SEQ 0
    AAC_SEQ 'SCCSL'                 ; 11: 6.1
    AAC_SEQ 'SCCCL'                 ; 12: 7.1 (rear)
    AAC_SEQ 0
    AAC_SEQ 'SCCLC'                 ; 14: 7.1 (top front)
    AAC_SEQ 0
; syntax elements, by id_syn_ele
aac_elements    dd aac_el_sce, aac_el_cpe, aac_el_cce, aac_el_lfe
                dd aac_el_dse, aac_el_pce, aac_el_fil

section .text

; =============================================================================
;  Entry points
; =============================================================================

; uint32_t aac_ctx_size(void): bytes of context a stream needs
EXPORT(aac_ctx_size)
aac_ctx_size:
    mov eax, AAC_CTX_SIZE
    ret

; int aac_info(ctx, *rate, *channels): output sample rate and channels
; (1 or 2) of a stream set up by aac_init; -1 if it was not
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

; aac_abort: error exit of aac_init / aac_decode, from any depth.
; In: EAX = negative error code.
aac_abort:
    mov esp, [aac_esp]
    ldmxcsr [aac_mxcsr]
    CLEAVE

; -----------------------------------------------------------------------------
; int aac_init(ctx, asc, asclen): set up a stream from its
; AudioSpecificConfig (1.6.2.1). 0 = ok, < 0 = not supported / bad.
; -----------------------------------------------------------------------------
EXPORT(aac_init)
aac_init:
    AAC_ENTER
    mov edi, ARG(0)
    mov [aac_ctx], edi
    mov ecx, AAC_CTX_SIZE / 4       ; forget everything (magic too)
    xor eax, eax
    rep stosd
    mov esi, ARG(1)
    mov ecx, ARG(2)
    call aac_load
    mov ebx, [aac_ctx]
    call aac_get_aot
    mov [aac_aot], eax
    AAC_GET 4                       ; samplingFrequencyIndex
    cmp eax, 15
    jne .table_rate
    AAC_GET 24                      ; explicit samplingFrequency
    cmp eax, 7000
    jb .bad_rate
    cmp eax, 96000
    ja .bad_rate
    mov [ebx + AAC_C_RATE], eax
    AAC_STAT AAC_S_EXPLICIT
    xor ecx, ecx                    ; the tables of the nearest rate
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
    AAC_GET 4                       ; channelConfiguration
    mov [ebx + AAC_C_CHCFG], eax
    mov eax, [aac_aot]
    cmp eax, 5                      ; HE-AAC (SBR) / HE-AAC v2 (SBR + PS):
    je .sbr                         ; the core's object type follows
    cmp eax, 29
    jne .core
.sbr:
    AAC_STAT AAC_S_SBR_CFG
    AAC_GET 4                       ; extensionSamplingFrequencyIndex
    cmp eax, 15
    jne .sbr_rate
    AAC_GET 24
.sbr_rate:
    call aac_get_aot
.core:
    cmp eax, 2                      ; AAC LC
    jne .bad_aot
    ; GASpecificConfig
    AAC_GET 1                       ; frameLengthFlag: 960-sample frames
    test eax, eax
    jnz .bad_len
    AAC_GET 1                       ; dependsOnCoreCoder
    test eax, eax
    jz .no_core
    AAC_GET 14                      ; coreCoderDelay
.no_core:
    AAC_GET 1                       ; extensionFlag (nothing for LC)
    ; (an SBR / PS sync extension may follow; the core does not need it)
    lea edi, [ebx + AAC_C_SCE]      ; no channel slots yet
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

; aac_get_aot: read an audioObjectType (5 bits, 31 = escape to 32 + 6 bits)
; Out: EAX.
aac_get_aot:
    AAC_GET 5
    cmp eax, 31
    jne .done
    AAC_GET 6
    add eax, 32
.done:
    ret

; aac_set_role: give slot EDX the output weights of role EAX (aac_role_l/r).
; In: EBX = context. Keeps all registers.
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

; aac_default_map: slots and roles for channelConfiguration 1-15, in the
; order the elements come in a frame. In: EBX = context.
aac_default_map:
    mov eax, [ebx + AAC_C_CHCFG]
    lea esi, [aac_cfg_seq + eax * 8]
    cmp byte [esi], 0
    je .bad
    xor edx, edx                    ; next free slot
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
    mov ecx, [aac_nlfe]             ; LFE: no weight (left out of the mix)
    mov [ebx + AAC_C_LFE + ecx], dl
    inc dword [aac_nlfe]
    inc edx
    jmp .next
.sce:
    mov ecx, [aac_nsce]
    mov [ebx + AAC_C_SCE + ecx], dl
    mov eax, 7                      ; mono: the channel itself
    cmp dword [ebx + AAC_C_CHCFG], 1
    je .sce_role
    mov eax, 1                      ; first SCE: front centre
    test ecx, ecx
    jz .sce_role
    mov eax, 6                      ; later ones: back centre
.sce_role:
    call aac_set_role
    inc dword [aac_nsce]
    inc edx
    jmp .next
.cpe:
    mov ecx, [aac_ncpe]
    mov [ebx + AAC_C_CPE + ecx], dl
    mov eax, 2                      ; first pair: front left / right
    test ecx, ecx
    jz .cpe_role
    mov eax, 4                      ; later pairs: surround (side / back)
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
    mov byte [ebx + AAC_C_SCE], 2   ; a lone SCE in a stereo stream: both
    mov edx, 2                      ; sides
    mov eax, 7
    call aac_set_role
    ret
.not_stereo:
    cmp eax, 1
    jne .ret
    mov dword [ebx + AAC_C_OUTCH], 1
    mov byte [ebx + AAC_C_CPE], 1   ; a CPE in a mono stream: average
    mov eax, [aac_half]
    mov [ebx + AAC_C_WL + 4], eax
    mov [ebx + AAC_C_WL + 8], eax
.ret:
    ret
.bad:
    AAC_FAIL AAC_E_CONFIG

; aac_pce_map: read the program_config_element of the config (4.4.1.1) and
; give its elements slots by tag: front SCE = centre, first front CPE =
; left/right, other CPEs = surround, other SCEs = back centre, LFE = none.
; In: EBX = context.
aac_pce_map:
    mov dword [ebx + AAC_C_PCE], 1
    AAC_GET 10                      ; tag, object type, rate index
    AAC_GET 4
    mov [aac_tmp], eax              ; front elements
    AAC_GET 4
    mov [aac_tmp + 4], eax          ; side
    AAC_GET 4
    mov [aac_tmp + 8], eax          ; back
    AAC_GET 2
    mov [aac_nlfe], eax
    AAC_GET 3
    mov [aac_lists], eax            ; associated data elements
    AAC_GET 4
    mov [aac_ind], eax              ; coupling elements
    call aac_pce_mixdowns
    xor edx, edx                    ; next free slot
    xor edi, edi                    ; channels in the configuration
    mov dword [aac_ncpe], 0         ; front pairs so far
    xor esi, esi                    ; part: 0 front, 1 side, 2 back
.part:
    mov ecx, [aac_tmp + esi * 4]
.element:
    test ecx, ecx
    jz .next_part
    dec ecx
    AAC_GET 1                       ; is_cpe
    push eax
    AAC_GET 4                       ; tag
    mov [aac_tmp + 12], eax
    pop eax
    test eax, eax
    jnz .cpe
    inc edi                         ; one more channel
    cmp edx, AAC_SLOTS
    jae .element
    mov eax, [aac_tmp + 12]
    cmp byte [ebx + AAC_C_SCE + eax], 0
    jge .element                    ; (tag used twice: ignore the second)
    mov [ebx + AAC_C_SCE + eax], dl
    mov eax, 1                      ; front: centre; side / back: back centre
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
    mov eax, 4                      ; surround, unless the first front pair
    test esi, esi
    jnz .cpe_role
    cmp dword [aac_ncpe], 0
    jne .cpe_role
    mov eax, 2
    inc dword [aac_ncpe]
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
    mov ecx, [aac_nlfe]             ; LFE elements
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
    mov [ebx + AAC_C_LFE + eax], dl ; (weight stays 0)
    inc edx
    jmp .lfe
.lfe_done:
    mov ecx, [aac_lists]            ; skip the data / coupling element tags
    shl ecx, 2
    mov eax, [aac_ind]
    lea eax, [eax + eax * 4]
    add ecx, eax
    call aac_skip
    call aac_align
    AAC_GET 8                       ; comment field
    lea ecx, [eax * 8]
    call aac_skip
    test edi, edi
    jz .bad
    mov dword [ebx + AAC_C_OUTCH], 2
    cmp edi, 1
    jne .ret
    mov dword [ebx + AAC_C_OUTCH], 1   ; one channel: mono, at full level
    mov eax, [aac_one]
    mov [ebx + AAC_C_WL], eax
.ret:
    ret
.bad:
    AAC_FAIL AAC_E_CONFIG

; aac_pce_mixdowns: read past the three mixdown fields of a PCE
aac_pce_mixdowns:
    AAC_GET 1                       ; mono_mixdown_present
    test eax, eax
    jz .stereo
    AAC_GET 4
.stereo:
    AAC_GET 1                       ; stereo_mixdown_present
    test eax, eax
    jz .matrix
    AAC_GET 4
.matrix:
    AAC_GET 1                       ; matrix_mixdown_idx_present
    test eax, eax
    jz .done
    AAC_GET 3
.done:
    ret

; aac_normalise: stereo downmix weights scaled so the left ones add up to 1
; (not for plain stereo, where they already are). In: EBX = context.
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

; -----------------------------------------------------------------------------
; int aac_decode(ctx, frame, len, out): decode one raw frame (an MP4
; sample) into 1024 frames of 16-bit PCM. Returns 1024 or < 0.
; -----------------------------------------------------------------------------
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
    mov edi, aac_mix                ; nothing mixed yet
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
    AAC_GET 3                       ; id_syn_ele
    cmp eax, 7                      ; END
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

; =============================================================================
;  Bit reader (MSB first, over aac_buf)
; =============================================================================

; aac_load: copy ECX bytes from ESI into aac_buf, zero the padding after
; them, and start reading at bit 0. Fails if longer than 8192 bytes.
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

; aac_getbits: EAX = the next ECX bits (1-25), most significant first;
; 0 once the data has run out (the position still advances, which the
; callers check). Keeps all other registers.
aac_getbits:
    push edx
    mov edx, [aac_bitpos]
    add [aac_bitpos], ecx
    cmp edx, [aac_bitend]
    jae .past
    push ecx
    mov ecx, edx
    shr edx, 3
    mov eax, [aac_buf + edx]        ; (bytes past the end are zeros)
    bswap eax
    and ecx, 7
    shl eax, cl                     ; drop the bits already read
    pop ecx
    neg cl                          ; shift right by 32 - n
    shr eax, cl
    neg cl
    pop edx
    ret
.past:
    xor eax, eax
    pop edx
    ret

; aac_peek32: EAX = the next 32 bits (0 past the end), without moving on
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

; aac_skip: move on ECX bits
aac_skip:
    add [aac_bitpos], ecx
    ret

; aac_align: move on to the next byte boundary (from the start of the data)
aac_align:
    add dword [aac_bitpos], 7
    and dword [aac_bitpos], ~7
    ret

; aac_huff: read one Huffman codeword. In: ESI = the codebook's decode table
; (in aac_hcb). Out: EAX = the leaf value (scale factor index, or packed
; spectral values, see aac_tables.inc). Keeps all other registers.
; The table is looked up 8 bits at a time first, then through links to
; smaller tables for longer codewords.
aac_huff:
    push ebx
    push ecx
    push edx
    push edi
    call aac_peek32                 ; the codeword is at the top of EAX
    xor edi, edi                    ; start of the current level's table
    mov ecx, 8                      ; its index bits
    xor ebx, ebx                    ; bits used so far
.level:
    mov edx, eax
    neg cl
    shr edx, cl                     ; top ECX bits
    neg cl
    add edx, edi
    movzx edx, word [esi + edx * 2]
    test edx, 0x8000
    jz .leaf
    add ebx, ecx                    ; link: those bits are used
    shl eax, cl
    mov edi, edx
    and edi, 0x7FF                  ; next table
    shr edx, 11
    and edx, 15
    mov ecx, edx                    ; and its index bits
    jmp .level
.leaf:
    mov ecx, edx
    shr ecx, 10
    and ecx, 31                     ; bits of the codeword at this level
    add ebx, ecx
    add [aac_bitpos], ebx
    mov eax, edx
    and eax, 0x3FF
    pop edi
    pop edx
    pop ecx
    pop ebx
    ret

; aac_huff_sf: EAX = next scale factor codeword's index (0-120, 60 = no
; change). Keeps all other registers.
aac_huff_sf:
    push esi
    mov esi, aac_hcb                ; (the scale factor book comes first)
    call aac_huff
    pop esi
    ret

; =============================================================================
;  Syntax elements. Each is called after its 3-bit id has been read.
; =============================================================================

; aac_find_slot: the slot for an element. In: EAX = its tag, ECX = how many
; of its kind came before it in this frame, EDX = the context's map (offset
; AAC_C_SCE / CPE / LFE). Out: EAX = slot (AAC_SCRATCH if it has none).
aac_find_slot:
    mov ebx, [aac_ctx]
    cmp dword [ebx + AAC_C_PCE], 0
    je .by_order
    mov ecx, eax                    ; PCE configuration: by tag
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

; single_channel_element (4.4.2.1)
aac_el_sce:
    AAC_GET 4                       ; element_instance_tag
    mov ecx, [aac_nsce]
    inc dword [aac_nsce]
    mov edx, AAC_C_SCE
    jmp aac_one_channel

; lfe_channel_element: like an SCE
aac_el_lfe:
    AAC_GET 4
    mov ecx, [aac_nlfe]
    inc dword [aac_nlfe]
    mov edx, AAC_C_LFE
    ; fall through
; aac_one_channel: decode one channel into the slot found for it
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

; channel_pair_element (4.4.2.1): two channels, maybe with one shared
; ics_info and M/S / intensity stereo
aac_el_cpe:
    AAC_GET 4
    mov ecx, [aac_ncpe]
    inc dword [aac_ncpe]
    mov edx, AAC_C_CPE
    call aac_find_slot
    mov [aac_slot], eax
    AAC_GET 1                       ; common_window
    mov [aac_common], eax
%ifdef NATIVE
    mov ecx, AAC_S_SEPARATE
    sub ecx, eax                    ; 1: AAC_S_COMMON
    inc dword [aac_stats + ecx * 4]
%endif
    mov dword [aac_ms_present], 0
    test eax, eax
    jz .channels
    mov ebp, aac_ics0
    call aac_ics_info
    mov esi, aac_ics0               ; the right channel has the same windows
    mov edi, aac_ics1
    mov ecx, AAC_I_INFO / 4
    rep movsd
    AAC_GET 2                       ; ms_mask_present
    cmp eax, 3
    je .bad_ms
    mov [aac_ms_present], eax
%ifdef NATIVE
    test eax, eax
    jz .ms_counted
    AAC_STATR AAC_S_MS1 - 1, eax
.ms_counted:
%endif
    mov edi, aac_ms_used            ; 2: every band; 0, 1: none yet
    mov ecx, 128 / 4
    cmp eax, 2
    sete al
    movzx eax, al
    imul eax, eax, 0x01010101
    rep stosd
    cmp dword [aac_ms_present], 1
    jne .channels
    xor edx, edx                    ; 1: one bit per band
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

; coupling_channel_element (4.4.2.1): read past it - its channel and gain
; elements are decoded only to find where it ends
aac_el_cce:
    AAC_GET 4                       ; tag
    AAC_GET 1                       ; ind_sw_cce_flag
    mov [aac_ind], eax
    AAC_GET 3                       ; num_coupled_elements
    lea ecx, [eax + 1]
    mov dword [aac_lists], 0
.target:
    inc dword [aac_lists]
    AAC_GET 1                       ; cc_target_is_cpe
    push eax
    AAC_GET 4                       ; cc_target_tag_select
    pop eax
    test eax, eax
    jz .next_target
    AAC_GET 1                       ; cc_l
    mov edx, eax
    AAC_GET 1                       ; cc_r
    and eax, edx
    add [aac_lists], eax            ; both: one more gain list
.next_target:
    dec ecx
    jnz .target
    AAC_GET 4                       ; cc_domain, gain sign, gain scale
    mov ebp, aac_ics0
    mov dword [aac_common], 0
    call aac_ics
    mov ecx, 1
.list:
    cmp ecx, [aac_lists]
    jae .done
    mov eax, 1                      ; common_gain_element_present
    cmp dword [aac_ind], 0
    jne .have_cge
    AAC_GET 1
.have_cge:
    test eax, eax
    jz .per_band
    call aac_huff_sf                ; common_gain_element
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
    call aac_huff_sf                ; dpcm_gain_element
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

; data_stream_element: skip its bytes
aac_el_dse:
    AAC_GET 4                       ; tag
    AAC_GET 1                       ; data_byte_align_flag
    mov edx, eax
    AAC_GET 8                       ; count
    cmp eax, 255
    jne .count
    mov ecx, eax
    AAC_GET 8                       ; esc_count
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

; program_config_element in a frame: read past it (the configuration
; comes from aac_init)
aac_el_pce:
    AAC_GET 10
    xor edx, edx                    ; bits of the element lists
    AAC_GET 4
    lea edx, [edx + eax * 4]        ; front: 5 bits each
    add edx, eax
    AAC_GET 4
    lea edx, [edx + eax * 4]        ; side
    add edx, eax
    AAC_GET 4
    lea edx, [edx + eax * 4]        ; back
    add edx, eax
    AAC_GET 2
    lea edx, [edx + eax * 4]        ; lfe: 4 bits each
    AAC_GET 3
    lea edx, [edx + eax * 4]        ; data elements: 4 bits each
    AAC_GET 4
    lea edx, [edx + eax * 4]        ; coupling: 5 bits each
    add edx, eax
    call aac_pce_mixdowns
    mov ecx, edx
    call aac_skip
    call aac_align
    AAC_GET 8                       ; comment_field_bytes
    lea ecx, [eax * 8]
    call aac_skip
    ret

; fill_element: skip its payload (SBR data of HE-AAC lives here)
aac_el_fil:
    AAC_GET 4                       ; count
    cmp eax, 15
    jne .skip
    AAC_GET 8                       ; esc_count
    add eax, 14
.skip:
%ifdef NATIVE
    test eax, eax
    jz .counted
    push eax
    call aac_peek32
    shr eax, 28                     ; extension_type 13 / 14: SBR
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

; =============================================================================
;  individual_channel_stream (4.4.2.7). In: EBP = aac_ics0 / aac_ics1.
; =============================================================================

; aac_ics_info: window sequence, shape, max_sfb, grouping (4.4.2.7)
aac_ics_info:
    AAC_GET 1                       ; ics_reserved_bit
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
    AAC_GET 7                       ; scale_factor_grouping: bit 6 for
    mov edx, eax                    ;  window 1 ... bit 0 for window 7
    mov dword [ebp + AAC_I_NWIN], 8
    mov dword [ebp + AAC_I_GLEN], 1
    mov ecx, 1                      ; groups so far
    mov esi, 6
.group:
    bt edx, esi
    jnc .new_group
    inc dword [ebp + AAC_I_GLEN + ecx * 4 - 4]   ; same group as before
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
    shl ebx, 5                      ; 16 words per rate
    add ebx, aac_swb_short
    mov [ebp + AAC_I_SWB], ebx
    jmp .check
.long:
    AAC_GET 6
    mov [ebp + AAC_I_MAXSFB], eax
    AAC_GET 1                       ; predictor_data_present
    test eax, eax
    jnz .predict
    mov dword [ebp + AAC_I_NWIN], 1
    mov dword [ebp + AAC_I_NGRP], 1
    mov dword [ebp + AAC_I_GLEN], 1
    movzx eax, byte [aac_rate_info + ebx * 4]
    mov [ebp + AAC_I_NSWB], eax
    imul ebx, ebx, 104              ; 52 words per rate
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

; aac_ics: one channel's side information and spectral values (quantised,
; with pulses added) into AAC_I_Q
aac_ics:
    AAC_GET 8                       ; global_gain
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

; aac_sections: section_data (4.4.2.7): codebook of every band -> AAC_I_BT
aac_sections:
    lea edi, [ebp + AAC_I_BT]
    mov ecx, 128 / 4
    xor eax, eax
    rep stosd
    mov dword [aac_sbits], 5        ; long windows: 5-bit lengths
    mov dword [aac_sesc], 31
    cmp dword [ebp + AAC_I_SEQ], AAC_EIGHT_SHORT
    jne .bits
    mov dword [aac_sbits], 3        ; short: 3-bit
    mov dword [aac_sesc], 7
.bits:
    mov dword [aac_g], 0
.group:
    mov eax, [aac_g]
    cmp eax, [ebp + AAC_I_NGRP]
    jae .done
    xor ebx, ebx                    ; band
.section:
    cmp ebx, [ebp + AAC_I_MAXSFB]
    jae .next_group
    AAC_GET 4                       ; sect_cb
    cmp eax, 12
    je .bad_book
    mov esi, eax
    xor edi, edi                    ; sect_len
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

; aac_scalefactors: scale_factor_data (4.4.2.7, 4.6.2) -> AAC_I_SF:
; scale factor (0-255) of spectral bands, intensity position of intensity
; bands, noise energy of PNS bands
aac_scalefactors:
    mov eax, [aac_gain]
    mov [aac_osf], eax              ; scale factors start at global_gain
    mov dword [aac_ois], 0          ; intensity positions at 0
    sub eax, 90
    mov [aac_onz], eax              ; noise energies at global_gain - 90
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
    add edx, ebx                    ; index of the band
    movzx eax, byte [ebp + AAC_I_BT + edx]
    test eax, eax
    jz .store                       ; (zero band: 0)
    cmp eax, 13
    je .noise
    jb .spectral
    call aac_huff_sf                ; intensity: clipped like ffmpeg
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
    AAC_GET 9                       ; the first one: 9 bits, offset 256
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
    ja .bad_scale                   ; (also catches negative)
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

; aac_clamp: EAX limited to ECX..ESI (signed)
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

; aac_side_data: pulse_data, tns_data, gain_control_data (4.4.2.7)
aac_side_data:
    AAC_GET 1                       ; pulse_data_present
    mov [ebp + AAC_I_PULSE], eax
    test eax, eax
    jz .tns
    cmp dword [ebp + AAC_I_SEQ], AAC_EIGHT_SHORT
    je .bad_pulse                   ; (long windows only)
    AAC_STAT AAC_S_PULSE
    AAC_GET 2
    inc eax
    mov [ebp + AAC_I_NP], eax
    AAC_GET 6                       ; pulse_start_sfb
    cmp eax, [ebp + AAC_I_NSWB]
    jae .bad_pulse
    mov esi, [ebp + AAC_I_SWB]
    movzx edx, word [esi + eax * 2]
    xor ebx, ebx
.pulse:
    AAC_GET 5                       ; pulse_offset
    add edx, eax
    cmp edx, 1023
    ja .bad_pulse
    mov [ebp + AAC_I_PPOS + ebx * 4], edx
    AAC_GET 4                       ; pulse_amp
    mov [ebp + AAC_I_PAMP + ebx * 4], eax
    inc ebx
    cmp ebx, [ebp + AAC_I_NP]
    jb .pulse
.tns:
    AAC_GET 1                       ; tns_data_present
    mov [ebp + AAC_I_TNS], eax
    test eax, eax
    jz .gain
    call aac_tns_data
.gain:
    AAC_GET 1                       ; gain_control_data_present
    test eax, eax
    jnz .bad_gain
    AAC_CHECK AAC_E_DATA
    ret
.bad_pulse:
    AAC_FAIL AAC_E_PULSE
.bad_gain:
    AAC_FAIL AAC_E_GAIN

; aac_tns_data: the TNS filters of every window (4.4.2.7): length, order,
; direction and coefficients (sign-extended) of up to 3 (long) or 1 (short)
; filters per window
aac_tns_data:
    mov ebx, 0                      ; window
.window:
    cmp ebx, [ebp + AAC_I_NWIN]
    jae .done
    cmp dword [ebp + AAC_I_SEQ], AAC_EIGHT_SHORT
    je .short_nfilt
    AAC_GET 2                       ; n_filt
    jmp .have_nfilt
.short_nfilt:
    AAC_GET 1
.have_nfilt:
    mov [ebp + AAC_I_NFILT + ebx * 4], eax
    test eax, eax
    jz .next_window
    AAC_GET 1                       ; coef_res
    mov [ebp + AAC_I_CRES + ebx * 4], eax
    xor esi, esi                    ; filter
.filter:
    cmp esi, [ebp + AAC_I_NFILT + ebx * 4]
    jae .next_window
    lea edi, [ebx * 4 + esi]        ; (window, filter) index
    cmp dword [ebp + AAC_I_SEQ], AAC_EIGHT_SHORT
    je .short_len
    AAC_GET 6                       ; length
    mov [ebp + AAC_I_TLEN + edi * 4], eax
    AAC_GET 5                       ; order
    cmp eax, 12
    ja .bad_order
    jmp .have_order
.short_len:
    AAC_GET 4
    mov [ebp + AAC_I_TLEN + edi * 4], eax
    AAC_GET 3                       ; (at most 7)
.have_order:
    mov [ebp + AAC_I_TORD + edi * 4], eax
    test eax, eax
    jz .next_filter
    mov ecx, eax                    ; coefficients to read
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
    AAC_GET 1                       ; direction
    mov [ebp + AAC_I_TDIR + edi * 4], eax
%ifdef NATIVE
    test eax, eax
    jz .up
    AAC_STAT AAC_S_TNS_DOWN
.up:
%endif
    AAC_GET 1                       ; coef_compress
%ifdef NATIVE
    test eax, eax
    jz .uncompressed
    AAC_STAT AAC_S_TNS_COMPR
.uncompressed:
%endif
    mov edx, [ebp + AAC_I_CRES + ebx * 4]
    add edx, 3
    sub edx, eax                    ; bits per coefficient: 2-4
    shl edi, 4
    lea edi, [ebp + AAC_I_TCOEF + edi]
.coef:
    push ecx
    mov ecx, edx
    call aac_getbits
    neg cl
    add cl, 32
    shl eax, cl                     ; sign-extend from EDX bits
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

; aac_spectral: spectral_data (4.4.2.7): the quantised values of every
; band with a spectral codebook, window by window within each group
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
    ja .next_band                   ; noise / intensity: no values
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

; one value of an unsigned codebook in EDX: read its sign bit if nonzero,
; store it at [EDI + %1]
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

; aac_values: read ECX quantised values (a multiple of 4) into the dwords
; at EDI. In: EAX = codebook 1-11, ESI = its decode table. Keeps EBX, EBP.
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

.signed_quads:                      ; books 1, 2: values -1..1, stored + 1
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

.unsigned_quads:                    ; books 3, 4: 0..2 and sign bits
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

.signed_pairs:                      ; books 5, 6: -4..4, stored + 4
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

.unsigned_pairs:                    ; books 7-10: 0..7 / 0..12, sign bits
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

.escape_pairs:                      ; book 11: 0..16, sign bits, then an
    call aac_huff                   ; escape sequence for each 16
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

; aac_escape: an escape sequence (4.6.3.3): N ones, a zero, then N+4 bits
; w; value 2^(N+4) + w (N at most 8, so values up to 8191). Out: EAX.
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
    call aac_getbits                ; ECX = N + 4 bits
    bts eax, ecx
    pop ecx
    ret
.too_long:
    AAC_FAIL AAC_E_ESCAPE

; aac_pulses: add the pulses to the quantised values (4.6.4): away from 0
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

; =============================================================================
;  Inverse quantisation, noise, stereo, TNS
; =============================================================================

; aac_exp2q: XMM0 = 2^(EAX/4) for EAX in about -500..500. Keeps others but
; EAX.
aac_exp2q:
    push ecx
    mov ecx, eax
    and ecx, 3
    sar eax, 2                      ; floor(n / 4) ...
    add eax, 127
    shl eax, 23                     ; ... as a float's exponent
    movd xmm0, eax
    mulss xmm0, [aac_pow2q + ecx * 4]   ; times 2^((n mod 4) / 4)
    pop ecx
    ret

; aac_pow43_big: XMM0 = EAX^(4/3) for EAX >= 1024 (x87: 2^(4/3 log2 x)).
; Leaves the x87 stack empty.
aac_pow43_big:
    push eax
    fld qword [aac_four_thirds]
    fild dword [esp]
    fyl2x                           ; t = 4/3 log2(x)
    fld st0
    frndint                         ; i = round(t)
    fsub st1, st0                   ; i, f = t - i (|f| <= 1)
    fxch st1
    f2xm1
    fld1
    faddp st1, st0                  ; 2^f, i
    fscale                          ; 2^f * 2^i, i
    fstp st1
    fstp dword [esp]
    movss xmm0, [esp]
    pop eax
    ret

; aac_dequant: AAC_I_Q -> AAC_I_SPEC: |q|^(4/3) * 2^((sf-100)/4) with the
; sign of q in spectral bands; PNS noise in noise bands; 0 elsewhere
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
    ja .next_band                   ; intensity: filled by aac_stereo
    mov eax, [ebp + AAC_I_SF + edx * 4]
    je .noise_gain
    sub eax, 100
.noise_gain:
    call aac_exp2q
    movss [aac_tmp], xmm0           ; the band's gain
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
    cdq                             ; EDX = 0 or -1
    xor eax, edx
    sub eax, edx                    ; |q|
    cmp eax, 1024
    jae .big
    movss xmm0, [aac_pow43 + eax * 4]
.scaled:
    mulss xmm0, xmm7
    movd eax, xmm0
    and edx, 0x80000000
    or eax, edx                     ; the sign of q
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

; aac_noise: fill ECX floats at EDI with random values whose energy (sum of
; squares) is the square of the gain in [aac_tmp] (4.6.13.3). The random
; values: a 32-bit linear congruential generator in the context.
aac_noise:
    push ebx
    mov ebx, [aac_ctx]
    mov eax, [ebx + AAC_C_RND]
    push ecx
    push edi
    xorps xmm1, xmm1                ; energy
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
    jbe .done                       ; (no energy: leave as is)
    sqrtss xmm1, xmm1
    movss xmm0, [aac_tmp]
    divss xmm0, xmm1                ; gain / sqrt(energy)
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

; aac_band_ptrs: for band EBX of group [aac_g]: ESI = &left spec, EDI =
; &right spec of window [aac_w] at the band's start, ECX = its width
; (from the right channel's layout). Keeps EBX, EDX.
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

; aac_stereo: intensity stereo (right = scaled left) and M/S (L = M + S,
; R = M - S) of a channel pair, band by band (4.6.8)
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
    add edx, ebx                    ; band index
    movzx eax, byte [aac_ics1 + AAC_I_BT + edx]
    cmp eax, 14
    jb .ms
    ; intensity: scale = +-2^(-is_position/4), - for book 14, inverted
    ; where M/S is on
    mov ecx, eax
    mov eax, [aac_ics1 + AAC_I_SF + edx * 4]
    neg eax
    call aac_exp2q
    movss xmm1, [aac_signs]
    cmp ecx, 15                     ; book 14: out of phase
    je .is_pos
    xorps xmm0, xmm1
.is_pos:
    cmp dword [aac_ms_present], 0
    je .is_go
    cmp byte [aac_ms_used + edx], 0
    je .is_go
    movss xmm1, [aac_signs]         ; (inverted by ms_used)
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
    cmp eax, 13                     ; not with noise in either channel
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
; the windows of the current group: [aac_w] = first, [aac_wcnt] = count
.windows_start:
    mov eax, [aac_w0]
    mov [aac_w], eax
    mov eax, [aac_g]
    mov eax, [aac_ics1 + AAC_I_GLEN + eax * 4]
    mov [aac_wcnt], eax
    ret
; next window; ZF set when the group is done
.windows_next:
    inc dword [aac_w]
    dec dword [aac_wcnt]
    ret

; aac_pns_pair: where M/S is on and both channels are noise, the right
; channel gets the left one's noise, rescaled to its own energy (4.6.13.3)
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
    call aac_exp2q                  ; right energy / left energy, as gain
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

; aac_tns: run the channel's TNS filters over its spectrum (4.6.9). Each
; filter covers the bands below the previous one (from the top), limited to
; TNS_MAX_BANDS and max_sfb; it runs upwards or downwards (direction) in
; place: y(n) = x(n) - sum lpc(i) y(n - i).
aac_tns:
    cmp dword [ebp + AAC_I_TNS], 0
    je .ret
    mov ebx, [aac_ctx]
    mov ebx, [ebx + AAC_C_SFI]
    movzx eax, byte [aac_rate_info + ebx * 4 + 2]   ; long windows
    cmp dword [ebp + AAC_I_SEQ], AAC_EIGHT_SHORT
    jne .maxb
    movzx eax, byte [aac_rate_info + ebx * 4 + 3]   ; short
.maxb:
    cmp eax, [ebp + AAC_I_MAXSFB]
    jbe .have_max
    mov eax, [ebp + AAC_I_MAXSFB]
.have_max:
    mov [aac_tmaxb], eax            ; min(TNS_MAX_BANDS, max_sfb)
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
    lea edi, [ebx * 4 + eax]        ; (window, filter) index
    mov eax, [aac_tbot]
    mov [aac_ttop], eax             ; top = the last filter's bottom
    sub eax, [ebp + AAC_I_TLEN + edi * 4]
    jge .bottom
    xor eax, eax
.bottom:
    mov [aac_tbot], eax
    mov eax, [ebp + AAC_I_TORD + edi * 4]
    test eax, eax
    jz .next_filter
    mov [aac_tord], eax
    ; dequantised reflection coefficients
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
    mov edx, [esi + edx * 4 + 32]   ; (table index = value + 8)
    mov [aac_lpct + ecx * 4], edx
    inc ecx
    cmp ecx, eax
    jb .coef
    pop edi
    call aac_tns_lpc
    ; the spectrum range: bands min(bottom/top, max) of this window
    mov esi, [ebp + AAC_I_SWB]
    mov eax, [aac_tbot]
    cmp eax, [aac_tmaxb]
    jbe .lo
    mov eax, [aac_tmaxb]
.lo:
    movzx ecx, word [esi + eax * 2] ; start
    mov eax, [aac_ttop]
    cmp eax, [aac_tmaxb]
    jbe .hi
    mov eax, [aac_tmaxb]
.hi:
    movzx eax, word [esi + eax * 2] ; end
    sub eax, ecx                    ; size
    jle .next_filter
    mov edx, [aac_tw]
    shl edx, 7
    add ecx, edx                    ; + window * 128
    lea esi, [ebp + AAC_I_SPEC + ecx * 4]
    mov ecx, eax
    mov edx, 4                      ; upwards
    cmp dword [ebp + AAC_I_TDIR + edi * 4], 0
    je .run
    lea esi, [esi + eax * 4 - 4]    ; downwards from the top
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

; aac_tns_lpc: the filter coefficients aac_lpc[1..order] from the
; reflection coefficients aac_lpct[0..order-1] (4.6.9.3: step-up recursion).
; In: [aac_tord] = order.
aac_tns_lpc:
    mov ecx, 1                      ; m
.m:
    cmp ecx, [aac_tord]
    ja .done
    movss xmm0, [aac_lpct + ecx * 4 - 4]   ; k = tmp[m - 1]
    mov edx, 1                      ; b[i] = a[i] + k a[m - i], i < m
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
    movss [aac_lpc + ecx * 4], xmm0 ; a[m] = k
    inc ecx
    jmp .m
.done:
    ret

; aac_tns_filter: all-pole filter in place over ECX floats from ESI, step
; EDX bytes (+4 / -4), order EBX: x(n) -= sum_{i<=min(n,order)} lpc(i) x(n-i)
; (x(n-i) already filtered)
aac_tns_filter:
    xor edi, edi                    ; n
.sample:
    movss xmm0, [esi]
    mov eax, edi                    ; terms: min(n, order)
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

; =============================================================================
;  Filter bank: inverse MDCT, windows, overlap-add, mixing
; =============================================================================

; aac_dct4: DCT-IV of ECX = M (1024 or 128) floats at ESI into aac_ubuf:
;   u(m) = sum_k x(k) cos(pi/M (m + 1/2)(k + 1/2)), times 1/M
; As a complex FFT of M/2 points: z(p) = (x(2p) + i x(M-1-2p)) w(p), with
; w(p) = e^(-i phi (4p+1)) / M, phi = pi / 4M (stored in bit-reversed
; order); Z = FFT(z); Z(q) e^(-i 4 phi q) = u(2q) - i u(M-1-2q).
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
    lea edi, [esi + ecx * 4 - 4]    ; x(M-1-2p), downwards
    shr ecx, 1                      ; M/2
    mov [aac_tmp + 8], ecx
.pre:
    movss xmm0, [esi]               ; x(2p)
    movss xmm1, [edi]               ; x(M-1-2p)
    movss xmm2, [ebx]               ; cos
    movss xmm3, [ebx + 4]           ; sin
    movaps xmm4, xmm0
    mulss xmm4, xmm2
    movaps xmm5, xmm1
    mulss xmm5, xmm3
    addss xmm4, xmm5                ; re = x(2p) cos + x(M-1-2p) sin
    mulss xmm1, xmm2
    mulss xmm0, xmm3
    subss xmm1, xmm0                ; im = x(M-1-2p) cos - x(2p) sin
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
    mov ebx, [aac_tmp]              ; post-twiddle into u
    mov ecx, [aac_tmp + 8]
    mov esi, aac_cbuf
    mov edi, aac_ubuf               ; u(2q), upwards
    mov edx, [aac_tmp + 4]
    lea edx, [aac_ubuf + edx * 4 - 4]   ; u(M-1-2q), downwards
.post:
    movss xmm0, [esi]               ; re
    movss xmm1, [esi + 4]           ; im
    movss xmm2, [ebx]               ; cos
    movss xmm3, [ebx + 4]           ; sin
    movaps xmm4, xmm0
    mulss xmm4, xmm2
    movaps xmm5, xmm1
    mulss xmm5, xmm3
    addss xmm4, xmm5                ; re cos + im sin
    mulss xmm0, xmm3
    mulss xmm1, xmm2
    subss xmm0, xmm1                ; re sin - im cos
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

; aac_fft: in-place forward complex FFT of ECX (64 or 512) points in
; aac_cbuf, input in bit-reversed order: radix-2 stages of length 2, 4, ...
; Two butterflies at a time (SSE); twiddles from aac_fft_tw.
aac_fft:
    mov esi, aac_cbuf               ; length 2: (a, b) -> (a + b, a - b)
    mov edx, ecx
    shr edx, 1
    movups xmm7, [aac_neg_hi]
.two:
    movups xmm0, [esi]
    movaps xmm1, xmm0
    movlhps xmm1, xmm1              ; a a
    movhlps xmm0, xmm0              ; b b
    xorps xmm0, xmm7                ; b -b
    addps xmm1, xmm0
    movups [esi], xmm1
    add esi, 16
    dec edx
    jnz .two
    lea ebp, [aac_cbuf + ecx * 8]   ; end
    mov ebx, aac_fft_tw
    mov edx, 4                      ; length L
.stage:
    cmp edx, ecx
    ja .done
    lea edi, [edx * 4]              ; L/2 complex = 4L bytes apart
    xor eax, eax                    ; j (pairs of butterflies)
.pair:
    movups xmm6, [ebx]              ; re w, re w, re w', re w'
    movups xmm7, [ebx + 16]         ; -im w, im w, -im w', im w'
    add ebx, 32
    lea esi, [aac_cbuf + eax * 8]
.block:
    movups xmm0, [esi]              ; a
    movups xmm1, [esi + edi]        ; b
    movaps xmm2, xmm1
    shufps xmm2, xmm2, 0xB1         ; im b, re b (both pairs)
    mulps xmm1, xmm6
    mulps xmm2, xmm7
    addps xmm1, xmm2                ; t = b w
    movaps xmm3, xmm0
    addps xmm0, xmm1
    subps xmm3, xmm1
    movups [esi], xmm0              ; a + t
    movups [esi + edi], xmm3        ; a - t
    lea esi, [esi + edi * 2]        ; next block of length L
    cmp esi, ebp
    jb .block
    add eax, 2
    mov esi, edx
    shr esi, 1                      ; L/2 butterflies per block
    cmp eax, esi
    jb .pair
    shl edx, 1
    jmp .stage
.done:
    ret

; aac_window: window the inverse MDCT output and add it to EDI.
; In: ESI = u (the DCT-IV of the spectrum, ECX = M values), EBX = M values
; of the rising (left) window half, EDX = M values of the falling (right)
; half. The 2M outputs y(n) come from u by symmetry (h = M/2):
;   y(n) = u(h+n), -u(3h-1-n), -u(h-1-(n-M)), -u(n-M-h)
; for n in [0,h), [h,M), [M,M+h), [M+h,2M).
aac_window:
    push ebp
    movups xmm7, [aac_signs]
    mov ebp, ecx
    shr ebp, 3                      ; h/4 blocks of 4 per quarter
    mov [aac_tmp], ebp
    shl ecx, 1                      ; 2h ... as bytes: h * 4 = M * 2
    lea eax, [esi + ecx]            ; u(h)
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
    lea eax, [esi + ecx * 2 - 16]   ; u(M-4 .. M-1), downwards
    mov ebp, [aac_tmp]
.q2:
    movups xmm0, [eax]
    shufps xmm0, xmm0, 0x1B         ; reversed
    xorps xmm0, xmm7                ; negated
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
    lea eax, [esi + ecx - 16]       ; u(h-4 .. h-1), downwards
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
    mov eax, esi                    ; u(0 ..), upwards
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

; aac_reverse: ECX floats from ESI to EDI in reverse order (a rising window
; half becomes a falling one)
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

; aac_filterbank: the time signal of a channel: inverse MDCT and windows by
; window sequence (4.6.11), plus the previous frame's overlap; mixed into
; aac_mix with the slot's weights. In: EBP = channel, EBX = slot.
aac_filterbank:
    mov [aac_fb_slot], ebx
    mov eax, [aac_ctx]
    mov eax, [eax + AAC_C_SHAPE + ebx * 4]
    mov [aac_fb_prev], eax          ; the last frame's window shape
    mov edi, aac_tbuf
    mov ecx, 2048
    xor eax, eax
    rep stosd
    cmp dword [ebp + AAC_I_SEQ], AAC_EIGHT_SHORT
    je .short
    ; --- one long window: left half from the last shape (or LONG_STOP's
    ; zeros / short slope / ones), right half from this one (or
    ; LONG_START's ones / short slope / zeros)
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
    ; --- eight short windows, overlapped at 448 + 128 w
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
    shl eax, 9                      ; 128 floats per window
    lea esi, [ebp + AAC_I_SPEC + eax]
    mov ecx, 128
    call aac_dct4
    mov ebx, aac_win_sine_short     ; first window: the last frame's shape
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
    ; --- output = overlap + first half; overlap = second half
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
    lea edi, [ebx + AAC_C_OVL + eax]    ; the slot's overlap
    mov esi, aac_tbuf
    mov edx, aac_mix
    mov ecx, 1024 / 4
.mix:
    movups xmm0, [edi]
    movups xmm1, [esi]
    addps xmm0, xmm1                ; this frame's output
    movups xmm1, [esi + 4096]
    movups [edi], xmm1              ; the next frame's overlap
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

; aac_output: aac_mix -> 16-bit PCM at [aac_out], rounded to nearest and
; clipped (NaN gives -32768)
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
    packssdw xmm0, xmm1             ; 8 left samples
    packssdw xmm2, xmm3             ; 8 right samples
    movdqa xmm1, xmm0
    punpcklwd xmm0, xmm2            ; interleaved
    punpckhwd xmm1, xmm2
    movdqu [edi], xmm0
    movdqu [edi + 16], xmm1
    add esi, 32
    add edi, 32
    dec ecx
    jnz .stereo
    ret

section .text
