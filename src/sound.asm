; =============================================================================
;  sound.asm - sound cards: Intel High Definition Audio and AC'97
;
;  Plays 16-bit PCM sound on the two kinds of sound hardware PCs have had
;  since 1997, both found on the PCI bus:
;
;    HDA    Intel High Definition Audio (PCI class 04, subclass 03), in every
;           PC since about 2005 (QEMU: -device intel-hda -device hda-output).
;           A controller streams samples from memory over the HDA link to
;           one or more codec chips (Realtek, Conexant, IDT, ...). A codec is
;           a little network of "widgets" - DACs (digital to analogue
;           converters), mixers, selectors and pins (jacks and speakers).
;           MOOS asks the codec about them with commands ("verbs"), finds a
;           way from a DAC through mixers and selectors to the line-out,
;           speaker and headphone pins, and powers, unmutes and connects
;           everything on the way.
;    AC'97  the audio of older Intel chipsets (ICH) and compatibles, and of
;           VirtualBox (PCI class 04, subclass 01; QEMU: -device AC97). One
;           codec with fixed mixer registers. It plays at 48 kHz, or at
;           44.1 kHz too when the codec has variable rate audio (VRA).
;
;  How playing works
;    MOOS owns no interrupts under UEFI, so the driver is polled. The card
;    plays a ring of SND_RING stereo frames in memory, round and round, by
;    DMA. The player writes its samples into the ring ahead of the card
;    (snd_write) and asks how far the card has got (snd_played); the card
;    itself says where it is (HDA: the stream's LPIB register; AC'97: the
;    buffer it plays and how much of it is left).
;    Every frame the card has played is set back to silence. So when the
;    player falls behind (an underrun) the card plays silence, never old
;    sound a second time, and snd_played keeps counting; the next write
;    then goes just ahead of the card (SND_LEAD_MS), to be heard at once.
;    Nothing plays until the first snd_write after snd_open, and
;    snd_played counts from there. At most SND_FILL_MS of sound is queued,
;    which bounds the delay of what the player writes. Pausing stops the
;    card; resuming moves the samples not yet played to the start of the
;    ring and restarts the card there (a clean start works the same on
;    every card, and QEMU's cards do not resume where they stopped).
;    The firmware's 100 Hz timer also calls snd_tick64, which silences
;    what has been played (and keeps an AC'97 card going) while the
;    player is busy elsewhere, even for minutes.
;
;  Formats
;    The card plays 16-bit stereo at 44100 or 48000 Hz. Other rates are
;    converted by linear interpolation; mono is played on both sides, and
;    of more channels the first two (left, right) are played.
;
;  Memory
;    The card reads and writes memory by DMA. Memory is identity-mapped, so
;    an address is also what the card uses. One 4 KB page from big_alloc
;    (owner OWN_SOUND) holds the HDA command and response rings and the
;    buffer descriptor list; the sample ring is a second block. Cards that
;    read memory without looking into the CPU's cache are handled by
;    writing every changed cache line back (CLFLUSH).
;
;  API (registers; everything not named is kept, flags change)
;    snd_init      -> CF=1 if there is no sound card MOOS can use. Finds and
;                     sets up the card the first time; then returns at once.
;    snd_open      EAX = sample rate in Hz (4000-192000), ECX = channels
;                  (1-8) -> CF=1 if that cannot be played. Starts a new
;                  stream (an old one is closed first); may be called again
;                  and again (on every seek, say).
;    snd_space     -> EAX = frames snd_write takes now
;    snd_write     ESI = interleaved signed 16-bit samples, ECX = frames
;                  -> EAX = frames taken (copied: the buffer may be reused).
;                  The first write after snd_open starts playing.
;    snd_played    -> EAX = frames played since snd_open, counted at the rate
;                  given to snd_open, from the card's position. It never goes
;                  back, keeps counting through the silence of an underrun,
;                  and stands still while paused.
;    snd_pause     stop playing (and the position)
;    snd_resume    carry on where it stopped
;    snd_close     stop and forget the stream (the card stays set up)
;    snd_volume    EAX = volume, 0 (silent) to 100 (full). Kept for later
;                  streams too; 80 at start-up.
;    snd_status    print the card, codec, output, rates and volume (the
;                  "sound" command)
;  A frame is one sample for every channel.
; =============================================================================

SND_NONE    equ 0                       ; snd_card
SND_HDA     equ 1
SND_AC97    equ 2

SS_CLOSED   equ 0                       ; snd_state: no stream
SS_IDLE     equ 1                       ; open, the card stopped; ring slot 0
                                        ; is frame snd_base when it starts
SS_RUN      equ 2                       ; the card plays the ring
SS_PAUSED   equ 3                       ; stopped by snd_pause

SND_RBITS   equ 18
SND_RING    equ 1 << SND_RBITS          ; frames in the ring (1 MB, ~5.5 s)
SND_RMASK   equ SND_RING - 1
SND_NBDL    equ 32                      ; buffer descriptors (AC'97 has 32)
SND_BBITS   equ SND_RBITS - 5
SND_BUFF    equ 1 << SND_BBITS          ; frames per descriptor (8192)
SND_FILL_MS equ 1000                    ; most sound queued ahead of the card
SND_LEAD_MS equ 20                      ; after an underrun, this far ahead
SND_LAPT    equ 150                     ; ticks after which the card may have
                                        ; gone round the ring (snd_update)
SND_MAXCONN equ 32                      ; connections kept per widget
SND_MAXOUT  equ 4                       ; HDA outputs played at once
SND_LINE    equ 64                      ; cache line size

; the DMA page
SND_CORB    equ 0x000                   ; HDA commands: 256 x 4 bytes
SND_RIRB    equ 0x400                   ; HDA responses: 256 x 8 bytes
SND_BDL     equ 0xC00                   ; buffer descriptors (32 x 16 / x 8)

; ---- HDA controller registers (memory-mapped, BAR 0)
HDA_GCAP      equ 0x00                  ; streams the controller has
HDA_VMIN      equ 0x02
HDA_VMAJ      equ 0x03
HDA_GCTL      equ 0x08                  ; bit 0: out of reset
HDA_STATESTS  equ 0x0E                  ; bit n: codec n is there
HDA_INTCTL    equ 0x20
HDA_CORBLBASE equ 0x40                  ; command ring (CORB)
HDA_CORBUBASE equ 0x44
HDA_CORBWP    equ 0x48
HDA_CORBRP    equ 0x4A
HDA_CORBCTL   equ 0x4C
HDA_CORBSIZE  equ 0x4E
HDA_RIRBLBASE equ 0x50                  ; response ring (RIRB)
HDA_RIRBUBASE equ 0x54
HDA_RIRBWP    equ 0x58
HDA_RINTCNT   equ 0x5A
HDA_RIRBCTL   equ 0x5C
HDA_RIRBSTS   equ 0x5D
HDA_RIRBSIZE  equ 0x5E
HDA_ICOI      equ 0x60                  ; immediate command interface
HDA_ICII      equ 0x64
HDA_ICIS      equ 0x68
HDA_SD0       equ 0x80                  ; stream descriptors, 0x20 each
SD_CTL        equ 0x00                  ; (3 bytes)
SD_STS        equ 0x03
SD_LPIB       equ 0x04                  ; bytes played in the ring
SD_CBL        equ 0x08
SD_LVI        equ 0x0C
SD_FMT        equ 0x12
SD_BDPL       equ 0x18
SD_BDPU       equ 0x1C

; ---- codec verbs (12-bit verbs with an 8-bit payload, 4-bit verbs with 16)
%define VERB(v, p)  (((v) << 8) | (p))
%define VERB4(v, p) (((v) << 16) | (p))
V_GETPARAM  equ 0xF00
V_GETCONN   equ 0xF02
V_SETSEL    equ 0x701
V_SETPOWER  equ 0x705
V_GETPOWER  equ 0xF05
V_SETSTREAM equ 0x706
V_SETPIN    equ 0x707
V_GETEAPD   equ 0xF0C
V_SETEAPD   equ 0x70C
V_GETCFG    equ 0xF1C
V_GETSUBSYS equ 0xF20
V_SETFMT4   equ 0x2
V_SETAMP4   equ 0x3
P_VENDOR    equ 0x00                    ; parameters
P_NODES     equ 0x04
P_FGTYPE    equ 0x05
P_WCAPS     equ 0x09
P_PCM       equ 0x0A
P_PINCAPS   equ 0x0C
P_INAMP     equ 0x0D
P_CONNLEN   equ 0x0E
P_OUTAMP    equ 0x12
W_DAC       equ 0                       ; widget types (capabilities 23:20)
W_MIXER     equ 2
W_SEL       equ 3
W_PIN       equ 4
WC_INAMP    equ 1 << 1                  ; widget capabilities
WC_OUTAMP   equ 1 << 2
WC_AMPOVR   equ 1 << 3                  ; its own amplifier parameters
WC_FMTOVR   equ 1 << 4                  ; its own rates
WC_CONN     equ 1 << 8                  ; has a connection list
WC_DIGITAL  equ 1 << 9
WC_POWER    equ 1 << 10
WC_EXISTS   equ 1 << 31                 ; (MOOS's mark: the widget is there)
PC_HP       equ 1 << 3                  ; pin capabilities
PC_OUT      equ 1 << 4
PC_HDMI     equ 1 << 7
PC_EAPD     equ 1 << 16
PC_DP       equ 1 << 24
HDA_AMP_OUT equ 0x8000                  ; which amplifier (Set Amplifier)
HDA_AMP_IN  equ 0x4000
HDA_TAG     equ 1                       ; our stream number

; ---- AC'97: mixer registers (I/O, BAR 0) and bus master (I/O, BAR 1)
AC_RESET     equ 0x00
AC_MASTER    equ 0x02
AC_HEADPHONE equ 0x04
AC_PCMOUT    equ 0x18
AC_POWERDOWN equ 0x26
AC_EXTID     equ 0x28
AC_EXTCTL    equ 0x2A
AC_FRONTRATE equ 0x2C
AC_VID1      equ 0x7C
AC_VID2      equ 0x7E
AC_PO_BDBAR  equ 0x10                   ; PCM out channel
AC_PO_CIV    equ 0x14
AC_PO_LVI    equ 0x15
AC_PO_SR     equ 0x16
AC_PO_PICB   equ 0x18
AC_PO_CR     equ 0x1B
AC_GLOB_CNT  equ 0x2C
AC_GLOB_STA  equ 0x30
AC_CAS       equ 0x34

section .data
snd_vol     dd 80                       ; volume 0-100

snd_s_test   db "test", 0
snd_s_volume db "volume", 0
snd_s_reset  db "reset", 0
snd_s_codec  db "codec", 0
snd_s_status db "status", 0
snd_s_pio    db "pio", 0

snd_k_2pi   dq 0.0061359231515425649    ; 2 pi / 1024
snd_k_full  dd 32767.0

snd_types:  dd snd_t0, snd_t1, snd_t2, snd_t3, snd_t4, snd_t5, snd_t6, snd_t7
            dd snd_tx, snd_tx, snd_tx, snd_tx, snd_tx, snd_tx, snd_tx, snd_tf
snd_t0      db "DAC", 0
snd_t1      db "ADC", 0
snd_t2      db "mixer", 0
snd_t3      db "selector", 0
snd_t4      db "pin", 0
snd_t5      db "power", 0
snd_t6      db "volume knob", 0
snd_t7      db "beep", 0
snd_tx      db "?", 0
snd_tf      db "vendor", 0
snd_devs:   dd snd_d0, snd_d1, snd_d2, snd_d3, snd_d4, snd_d5, snd_d6, snd_d7
            dd snd_d8, snd_d9, snd_d10, snd_d11, snd_d12, snd_d13, snd_d14, snd_d15
snd_d0      db "line out", 0
snd_d1      db "speaker", 0
snd_d2      db "headphone", 0
snd_d3      db "CD", 0
snd_d4      db "S/PDIF out", 0
snd_d5      db "digital out", 0
snd_d6      db "modem line", 0
snd_d7      db "modem handset", 0
snd_d8      db "line in", 0
snd_d9      db "aux", 0
snd_d10     db "microphone", 0
snd_d11     db "telephony", 0
snd_d12     db "S/PDIF in", 0
snd_d13     db "digital in", 0
snd_d14     db "reserved", 0
snd_d15     db "other", 0
snd_conns:  dd snd_c0, snd_c1, snd_c2, snd_c3
snd_c0      db "jack", 0
snd_c1      db "not connected", 0
snd_c2      db "built in", 0
snd_c3      db "jack and built in", 0
snd_vendors:                            ; codec makers (PCI vendor IDs)
    dd 0x10EC, snd_v_realtek, 0x14F1, snd_v_conexant, 0x111D, snd_v_idt
    dd 0x8384, snd_v_sigmatel, 0x11D4, snd_v_ad, 0x1106, snd_v_via
    dd 0x1013, snd_v_cirrus, 0x8086, snd_v_intel, 0x10DE, snd_v_nvidia
    dd 0x1002, snd_v_amd, 0x1022, snd_v_amd, 0x1AF4, snd_v_qemu
    dd 0x434D, snd_v_cmedia, 0x11C1, snd_v_agere, 0x14E4, snd_v_broadcom
    dd 0x1102, snd_v_creative, 0x15AD, snd_v_vmware, 0x17E8, snd_v_chrontel
    dd 0, snd_v_other
snd_v_realtek   db "Realtek", 0
snd_v_conexant  db "Conexant", 0
snd_v_idt       db "IDT", 0
snd_v_sigmatel  db "SigmaTel", 0
snd_v_ad        db "Analog Devices", 0
snd_v_via       db "VIA", 0
snd_v_cirrus    db "Cirrus Logic", 0
snd_v_intel     db "Intel (HDMI/DisplayPort)", 0
snd_v_nvidia    db "NVIDIA (HDMI)", 0
snd_v_amd       db "AMD", 0
snd_v_qemu      db "QEMU", 0
snd_v_cmedia    db "C-Media", 0
snd_v_agere     db "Agere/LSI", 0
snd_v_broadcom  db "Broadcom", 0
snd_v_creative  db "Creative", 0
snd_v_vmware    db "VMware", 0
snd_v_chrontel  db "Chrontel", 0
snd_v_other     db "unknown maker", 0

section .bss
snd_ready     resb 1                    ; a card is set up
snd_tried     resb 1                    ; snd_init has looked (and failed)
snd_card      resb 1                    ; SND_NONE / SND_HDA / SND_AC97
snd_state     resb 1                    ; SS_*
snd_imm       resb 1                    ; HDA: immediate command interface
snd_force_imm resb 1                    ; ("sound reset pio")
snd_clfl      resb 1                    ; the CPU has CLFLUSH
snd_tick_on   resb 1                    ; snd_tick64 may work on the ring
snd_vra       resb 1                    ; AC'97: the codec can change rate
snd_sw        resb 1                    ; volume by scaling the samples
snd_sine_ok   resb 1
snd_pass      resb 1
alignb 4
snd_swvol     resd 1                    ; software gain, 32768 = 1.0
snd_pci       resd 1                    ; the card: PCI address, IDs
snd_vendev    resd 1
snd_mmio      resd 1                    ; HDA registers
snd_nam       resd 1                    ; AC'97 mixer ports
snd_nabm      resd 1                    ; AC'97 bus master ports
snd_ctl       resd 1                    ; the DMA page
snd_buf       resd 1                    ; the sample ring...
snd_buf_end   resd 1                    ; ... and its end
snd_sd        resd 1                    ; HDA output stream registers
snd_sdctl     resd 1                    ; its stream number (and direction)
snd_gcap      resd 1
snd_codecs    resd 1                    ; codecs present (STATESTS)
snd_corb_mask resd 1
snd_rirb_mask resd 1
snd_rirb_rp   resd 1                    ; last response read
snd_cad       resd 1                    ; codec address << 28
snd_cadn      resd 1                    ; codec address
snd_codec_id  resd 1                    ; vendor << 16 | device
snd_afg       resd 1                    ; audio function group node
snd_afg_pcm   resd 1                    ; its defaults: rates, amplifiers
snd_afg_oamp  resd 1
snd_afg_iamp  resd 1
snd_rates     resd 1                    ; rates (P_PCM bits) all our DACs do
snd_fmt       resd 1                    ; HDA stream format
snd_nout      resd 1                    ; HDA outputs in use (primary first)
snd_opin      resd SND_MAXOUT           ; their pins...
snd_odac      resd SND_MAXOUT           ; ... DACs ...
snd_onhop     resd SND_MAXOUT           ; ... and the way between:
snd_ohop      resb SND_MAXOUT * 16      ; (node, connection) from the pin
snd_ovol_nid  resd SND_MAXOUT           ; the amplifier used as volume
snd_ovol_amp  resd SND_MAXOUT           ; (which one, its capabilities)
snd_ovol_caps resd SND_MAXOUT
snd_fmax      resd 1                    ; path search: longest way allowed
snd_fhops     resd 1                    ; the way found
snd_fhop      resb 16
snd_cl_len    resd 1                    ; reading a connection list
snd_cl_prev   resd 1
snd_cl_resp   resd 1
snd_wcaps     resd 128                  ; the codec's widgets, by node
snd_pcaps     resd 128
snd_pcfg      resd 128
snd_nconn     resb 128
snd_conn      resb 128 * SND_MAXCONN
snd_ac_vid    resd 1                    ; AC'97 codec ID, extended ID
snd_ac_ext    resd 1
; the stream
snd_rate      resd 1                    ; the player's rate and channels
snd_chans     resd 1
snd_stride    resd 1                    ; bytes per input frame
snd_dev_rate  resd 1                    ; the card's rate
snd_step_i    resd 1                    ; input frames per card frame (32.32)
snd_step_f    resd 1
snd_frac      resd 1                    ; rate conversion: where between...
snd_need      resd 1                    ; (input frames to take first)
snd_prevl     resd 1                    ; ... these two input frames
snd_prevr     resd 1
snd_curl      resd 1
snd_curr      resd 1
snd_base      resd 1                    ; frame number of ring slot 0
snd_hw        resd 1                    ; frames the card has played
snd_wr        resd 1                    ; where the next frame is written
snd_lastp     resd 1                    ; ring position at the last look
snd_lasttick  resd 1                    ; ... and the time then
snd_tick_p    resd 1                    ; ring position snd_tick64 saw last
snd_lead      resd 1                    ; SND_LEAD_MS in card frames
snd_maxfill   resd 1                    ; SND_FILL_MS in card frames
snd_p_in      resd 1                    ; (snd_put)
snd_p_room    resd 1
snd_p_slot    resd 1
snd_tmp       resd 1
; "sound test"
snd_t_rate    resd 1
snd_t_total   resd 1
snd_t_done    resd 1
snd_t_inc     resd 1
snd_t_start   resd 1
snd_t_end     resd 1
snd_sine      resw 1024
snd_tbuf      resd 1024
section .text

; =============================================================== the API
; snd_init: find and set up a sound card (once) -> CF=1 if there is none
snd_init:
    cmp byte [snd_ready], 0
    jne .yes
    cmp byte [snd_tried], 0
    jne .no
    pushad
    mov byte [snd_tried], 1
    mov byte [snd_card], SND_NONE
    cmp dword [bootinfo + BI.platform], PLATFORM_UEFI
    jne .fail
    mov eax, 1                          ; CLFLUSH (CPUID 1, EDX bit 19)?
    cpuid
    shr edx, 19
    and dl, 1
    mov [snd_clfl], dl
    cmp dword [snd_ctl], 0              ; memory for the card (kept for good)
    jne .have_ctl
    mov ecx, 4096
    mov edx, OWN_SOUND
    call big_alloc
    test eax, eax
    jz .fail
    mov [snd_ctl], eax
.have_ctl:
    cmp dword [snd_buf], 0
    jne .have_buf
    mov ecx, SND_RING * 4
    mov edx, OWN_SOUND
    call big_alloc
    test eax, eax
    jz .fail
    mov [snd_buf], eax
    add eax, SND_RING * 4
    mov [snd_buf_end], eax
.have_buf:
    call snd_find
    jc .fail
    mov byte [snd_ready], 1
    popad
.yes:
    clc
    ret
.fail:
    mov byte [snd_card], SND_NONE
    popad
.no:
    stc
    ret

; snd_open: EAX = rate (Hz), ECX = channels -> CF=1 if it cannot be played.
; A new stream: the card is told the rate; nothing plays until snd_write.
snd_open:
    pushad
    cmp eax, 4000
    jb .bad
    cmp eax, 192000
    ja .bad
    cmp ecx, 1
    jb .bad
    cmp ecx, 8
    ja .bad
    call snd_init
    jc .bad
    call snd_close
    mov [snd_rate], eax
    mov [snd_chans], ecx
    add ecx, ecx
    mov [snd_stride], ecx
    call snd_pick_rate                  ; the card's rate...
    mov [snd_dev_rate], eax
    call snd_hw_format                  ; ... set (it may still change it)
    ; rate conversion: input frames per card frame, as 32.32 fixed point
    mov eax, [snd_rate]
    xor edx, edx
    div dword [snd_dev_rate]
    mov [snd_step_i], eax
    xor eax, eax                        ; (remainder * 2^32 / card rate)
    div dword [snd_dev_rate]
    mov [snd_step_f], eax
    mov dword [snd_need], 2             ; take two input frames, then start
    xor eax, eax                        ; exactly at the first
    mov [snd_frac], eax
    mov [snd_prevl], eax
    mov [snd_prevr], eax
    mov [snd_curl], eax
    mov [snd_curr], eax
    mov [snd_base], eax                 ; the counters
    mov [snd_hw], eax
    mov [snd_wr], eax
    mov [snd_lastp], eax
    mov eax, [snd_dev_rate]             ; queue limits in card frames
    imul eax, SND_LEAD_MS
    xor edx, edx
    mov ecx, 1000
    div ecx
    mov [snd_lead], eax
    mov eax, [snd_dev_rate]
    imul eax, SND_FILL_MS
    xor edx, edx
    div ecx
    mov [snd_maxfill], eax
    xor eax, eax                        ; all silence
    mov ecx, SND_RING
    call snd_ring_zero
    mov byte [snd_state], SS_IDLE
    popad
    clc
    ret
.bad:
    popad
    stc
    ret

; snd_space: -> EAX = frames (at the player's rate) snd_write takes now
snd_space:
    xor eax, eax
    cmp byte [snd_state], SS_CLOSED
    je .out
    push ecx
    push edx
    call snd_update
    call snd_room                       ; EAX = card frames
    mov ecx, [snd_rate]
    cmp ecx, [snd_dev_rate]
    je .same
    ; Converting: allow for the converter's rounding (and the frames it
    ; holds), so that this many are surely all taken.
    push eax
    mov eax, [snd_dev_rate]
    xor edx, edx
    div ecx                             ; card frames per input frame
    lea ecx, [eax + 3]
    pop eax
    sub eax, ecx
    jbe .none
    mul dword [snd_rate]
    div dword [snd_dev_rate]
    jmp .same
.none:
    xor eax, eax
.same:
    pop edx
    pop ecx
.out:
    ret

; snd_write: ESI = interleaved 16-bit samples, ECX = frames -> EAX = frames
; taken. They go just after what is queued (or, after an underrun, just
; ahead of the card); the first write of a stream starts the card.
snd_write:
    pushad
    mov dword [esp + 28], 0
    cmp byte [snd_state], SS_CLOSED
    je .done
    test ecx, ecx
    jz .done
    call snd_update
    call snd_room                       ; EAX = card frames that fit
    test eax, eax
    jz .done
    mov edx, eax
    mov edi, [snd_wr]
    sub edi, [snd_base]
    and edi, SND_RMASK                  ; EDI = ring slot to write
    call snd_put                        ; -> EAX taken, ECX card frames
    mov [esp + 28], eax
    add [snd_wr], ecx
    cmp byte [snd_state], SS_IDLE
    jne .done
    test ecx, ecx
    jz .done
    call snd_restart                    ; the first sound: start the card
.done:
    popad
    ret

; snd_played: -> EAX = frames played since snd_open (at the player's rate)
snd_played:
    push ecx
    push edx
    call snd_update
    mov eax, [snd_hw]
    mov ecx, [snd_dev_rate]
    cmp ecx, [snd_rate]
    je .done
    mul dword [snd_rate]                ; card frames * rate / card rate,
    push ebx                            ; divided in two steps so that it
    mov ebx, eax                        ; cannot overflow
    mov eax, edx
    xor edx, edx
    div ecx
    mov eax, ebx
    div ecx
    pop ebx
.done:
    pop edx
    pop ecx
    ret

; snd_pause: stop the card where it is (snd_resume carries on)
snd_pause:
    pushad
    cmp byte [snd_state], SS_IDLE
    je .paused
    cmp byte [snd_state], SS_RUN
    jne .done
    call snd_update
    mov byte [snd_tick_on], 0
    call snd_hw_stop
    call snd_hw_pos                     ; count what it played before it
    sub eax, [snd_lastp]                ; stopped (no more than a moment)
    and eax, SND_RMASK
    add [snd_lastp], eax
    call snd_advance
.paused:
    mov byte [snd_state], SS_PAUSED
.done:
    popad
    ret

; snd_resume: carry on after snd_pause
snd_resume:
    pushad
    cmp byte [snd_state], SS_PAUSED
    jne .done
    mov eax, [snd_wr]
    sub eax, [snd_hw]
    test eax, eax
    jle .empty
    call snd_restart                    ; play what is queued
    jmp .done
.empty:
    mov eax, [snd_hw]                   ; nothing queued: wait for snd_write
    mov [snd_wr], eax                   ; (the whole ring is silent, so slot
    mov [snd_base], eax                 ; 0 can be the next frame)
    mov byte [snd_state], SS_IDLE
.done:
    popad
    ret

; snd_close: stop the card and forget the stream
snd_close:
    pushad
    cmp byte [snd_state], SS_CLOSED
    je .done
    mov byte [snd_tick_on], 0
    call snd_hw_stop
    mov byte [snd_state], SS_CLOSED
.done:
    popad
    ret

; snd_volume: EAX = volume 0-100 (more counts as 100)
snd_volume:
    push eax
    cmp eax, 100
    jbe .ok
    mov eax, 100
.ok:
    mov [snd_vol], eax
    cmp byte [snd_ready], 0
    je .done
    call snd_apply_volume
.done:
    pop eax
    ret

; ============================================================ the stream
; snd_update: bring snd_hw up to date with the card's position and silence
; what it has played (while it runs). Restarts the card if it has stopped
; by itself (AC'97 at the end of its buffers, HDA on a descriptor error).
snd_update:
    cmp byte [snd_state], SS_RUN
    je .go
    ret
.go:
    pushad
    call snd_hw_pos                     ; EAX = ring position, CF = stopped
    sbb ebp, ebp                        ; EBP = -1 if it stopped
    mov ebx, eax
    sub eax, [snd_lastp]
    and eax, SND_RMASK                  ; EAX = frames since the last look
    mov [snd_lastp], ebx
    mov ecx, [ticks]
    mov edx, ecx
    sub ecx, [snd_lasttick]             ; ECX = ticks since then
    mov [snd_lasttick], edx
    test ebp, ebp
    jnz .advance                        ; (a stopped card went round once)
    cmp ecx, SND_LAPT
    jb .advance
    ; A long time since the last look: the card may have gone round the
    ; ring more than once. The clock says about how far it got; add the
    ; whole trips round the ring that come closest to that.
    cmp ecx, 1000000                    ; (keeps the sums in 32 bits)
    jbe .t
    mov ecx, 1000000
.t: mov esi, eax                        ; ESI = frames by the position
    mov eax, ecx
    mul dword [snd_dev_rate]
    mov ecx, 100
    div ecx                             ; EAX = frames by the clock
    sub eax, esi
    jbe .no_trips
    add eax, SND_RING / 2
    and eax, ~SND_RMASK                 ; whole trips, rounded
    add esi, eax
.no_trips:
    mov eax, esi
.advance:
    call snd_advance
    test ebp, ebp
    jz .done
    call snd_restart
.done:
    popad
    ret

; snd_advance: EAX = frames the card has played since snd_hw -> snd_hw moves
; on, and those frames of the ring are made silent
snd_advance:
    pushad
    test eax, eax
    jz .done
    mov edx, eax
    mov ecx, eax
    cmp ecx, SND_RING
    jbe .n
    mov ecx, SND_RING
.n: mov eax, [snd_hw]
    sub eax, [snd_base]                 ; the slot of the first one
    call snd_ring_zero
    add [snd_hw], edx
.done:
    popad
    ret

; snd_room: put the write position where new frames must go -> EAX = card
; frames that may be written there now. While the card runs, new frames go
; at least snd_lead ahead of it (the card reads a little ahead of what it
; reports, and frames behind it would only be heard a whole trip later).
snd_room:
    push ecx
    mov eax, [snd_wr]
    sub eax, [snd_hw]                   ; EAX = frames queued (< 0: underrun)
    cmp byte [snd_state], SS_RUN
    jne .stopped
    cmp eax, [snd_lead]
    jge .placed
    mov eax, [snd_lead]                 ; too close, or behind: jump ahead
    jmp .move
.stopped:
    test eax, eax
    jns .placed
    xor eax, eax
.move:
    mov ecx, [snd_hw]
    add ecx, eax
    mov [snd_wr], ecx
.placed:
    mov ecx, [snd_maxfill]
    sub ecx, eax
    jns .ok
    xor ecx, ecx
.ok:
    mov eax, ecx
    pop ecx
    ret

; snd_restart: (re)start the card at ring slot 0, which becomes frame
; snd_hw. The frames not yet played are moved there first.
snd_restart:
    pushad
    mov byte [snd_tick_on], 0
    call snd_hw_stop
    mov eax, [snd_wr]
    sub eax, [snd_hw]
    test eax, eax
    jle .empty
    mov eax, [snd_hw]
    sub eax, [snd_base]
    call snd_ring_rotate
    jmp .based
.empty:
    mov eax, [snd_hw]                   ; (all silence: nothing to move)
    mov [snd_wr], eax
.based:
    mov eax, [snd_hw]
    mov [snd_base], eax
    xor eax, eax
    mov [snd_lastp], eax
    mov [snd_tick_p], eax
    mov eax, [ticks]
    mov [snd_lasttick], eax
    call snd_hw_start
    mov byte [snd_state], SS_RUN
    mov byte [snd_tick_on], 1
    popad
    ret

; snd_put: copy frames into the ring in the card's format, converting the
; rate and channels and applying the software volume.
; ESI = samples, ECX = frames, EDX = room (card frames), EDI = ring slot
; -> EAX = input frames taken, ECX = card frames written
snd_put:
    push ebx
    push edx
    push esi
    push edi
    push ebp
    mov [snd_p_in], ecx
    mov [snd_p_room], edx
    mov [snd_p_slot], edi
    shl edi, 2
    add edi, [snd_buf]                  ; EDI = where in the ring
    mov eax, [snd_rate]
    cmp eax, [snd_dev_rate]
    jne .convert
    cmp ecx, edx                        ; the same rate: frame for frame
    jbe .n
    mov ecx, edx
.n: mov edx, ecx
    sub [snd_p_room], ecx
    sub [snd_p_in], ecx
.copy:
    test edx, edx
    jz .written
    call snd_get                        ; EAX = left, EBP = right
    add esi, [snd_stride]
    call snd_store
    dec edx
    jmp .copy
.convert:
    ; Linear interpolation: each card frame lies snd_frac of the way from
    ; the input frame "prev" to the next one, "cur". After each card frame
    ; the position moves on by the step (input / card rate); snd_need says
    ; how many input frames to take before the next card frame.
    cmp dword [snd_need], 0
    je .emit
    test ecx, ecx                       ; input left?
    jz .converted
    mov eax, [snd_curl]
    mov [snd_prevl], eax
    mov eax, [snd_curr]
    mov [snd_prevr], eax
    call snd_get
    add esi, [snd_stride]
    mov [snd_curl], eax
    mov [snd_curr], ebp
    dec ecx
    dec dword [snd_need]
    jmp .convert
.emit:
    test edx, edx                       ; room left?
    jz .converted
    mov ebx, [snd_frac]
    shr ebx, 17                         ; EBX = fraction, 15 bits
    mov eax, [snd_curl]
    sub eax, [snd_prevl]
    imul eax, ebx
    sar eax, 15
    add eax, [snd_prevl]
    mov ebp, [snd_curr]
    sub ebp, [snd_prevr]
    imul ebp, ebx
    sar ebp, 15
    add ebp, [snd_prevr]
    call snd_store
    dec edx
    mov eax, [snd_step_f]               ; on to the next card frame
    add [snd_frac], eax
    mov eax, [snd_step_i]
    adc eax, 0
    mov [snd_need], eax
    jmp .convert
.converted:
    sub [snd_p_in], ecx                 ; (what is left of each)
    sub [snd_p_room], edx
.written:
    mov eax, [snd_p_in]                 ; input frames taken
    neg eax
    add eax, ecx
    mov eax, ecx                        ; (placeholder, set below)
    ; taken = frames given - frames left; written = room - room left
    pop ebp
    pop edi
    pop esi
    pop edx
    pop ebx
    jmp snd_put_end

; snd_get: ESI = an input frame -> EAX = left, EBP = right (sign-extended)
snd_get:
    movsx eax, word [esi]
    movsx ebp, word [esi + 2]
    cmp dword [snd_chans], 1
    jne .r
    mov ebp, eax                        ; mono: the same on both sides
.r: ret

; snd_store: EAX = left, EBP = right -> one card frame at EDI (moves on,
; round the ring), at the software volume
snd_store:
    cmp dword [snd_swvol], 32768
    je .full
    imul eax, [snd_swvol]
    sar eax, 15
    imul ebp, [snd_swvol]
    sar ebp, 15
.full:
    shl ebp, 16
    and eax, 0xFFFF
    or eax, ebp
    mov [edi], eax
    add edi, 4
    cmp edi, [snd_buf_end]
    jb .r
    mov edi, [snd_buf]
.r: ret
