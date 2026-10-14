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
;    buffer it plays and how much of that is left).
;    Every frame the card has played is set back to silence. So when the
;    player falls behind (an underrun) the card plays silence, never old
;    sound a second time, and snd_played keeps counting; the next write
;    then goes just ahead of the card (SND_LEAD_MS), to be heard at once.
;    This silencing is done by snd_sync64, which both the API and the
;    firmware's 100 Hz timer (efi_tick) call: so it goes on while the
;    player is busy elsewhere, even for minutes. On AC'97 it also moves the
;    card's "last valid buffer" along, so that the card never stops.
;    Nothing plays until the first snd_write after snd_open, and
;    snd_played counts from there. At most SND_FILL_MS of sound is queued,
;    which bounds the delay of what the player writes. Pausing stops the
;    card; resuming moves the samples not yet played to the start of the
;    ring and starts the card afresh there (a clean start works the same on
;    every card, and QEMU's cards do not resume where they stopped).
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
;                  The first write of a stream starts playing.
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
SND_GUARD_MS equ 10                     ; less queued than this: an underrun
SND_LEAD_MS equ 20                      ; after an underrun, this far ahead
SND_MAXCONN equ 32                      ; connections kept per widget
SND_MAXOUT  equ 4                       ; HDA outputs played at once
SND_MAXHOP  equ 5                       ; longest way from a pin to a DAC
SND_MAXSEEN equ 4                       ; audio devices noted by snd_find
SND_LINE    equ 64                      ; cache line size
SND_TCHUNK  equ 1024                    ; "sound test": frames made at a time

; why an audio device is not used (snd_seen_res)
R_OK        equ 0
R_NODRIVER  equ 1                       ; a kind MOOS has no driver for
R_BAR       equ 2                       ; its registers cannot be reached
R_RESET     equ 3                       ; the controller would not reset
R_NOCODEC   equ 4                       ; no codec answered
R_NOOUT     equ 5                       ; no analogue output (HDMI only?)
R_NOSTREAM  equ 6                       ; no output stream engine

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
V_SETFMT4   equ 0x2
V_SETAMP4   equ 0x3
P_VENDOR    equ 0x00                    ; parameters
P_REVISION  equ 0x02
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
PCM_44K     equ 1 << 5                  ; rate bits (P_PCM)
PCM_48K     equ 1 << 6

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

section .data
snd_vol     dd 80                       ; volume 0-100

snd_s_test   db "test", 0
snd_s_volume db "volume", 0
snd_s_reset  db "reset", 0
snd_s_codec  db "codec", 0
snd_s_status db "status", 0
snd_s_pio    db "pio", 0
snd_s_gap    db "gap", 0
snd_s_pause  db "pause", 0
snd_s_reopen db "reopen", 0

snd_k_2pi   dq 0.0061359231515425649    ; 2 pi / 1024
snd_k_amp   dd 16384.0                  ; test tones at half of full scale

; ICH-compatible AC'97 controllers (device << 16 | vendor)
snd_ac97_ids:
    dd 0x24158086, 0x24258086, 0x24458086, 0x24858086 ; Intel ICH, ICH0-3
    dd 0x24C58086, 0x24D58086, 0x25A68086, 0x266E8086 ; ICH4, ICH5, ESB, ICH6
    dd 0x27DE8086, 0x71958086                         ; ICH7, 440MX
    dd 0x74451022, 0x746D1022                         ; AMD 768, 8111
    dd 0x01B110DE, 0x006A10DE, 0x00DA10DE, 0x00EA10DE ; NVIDIA nForce
    dd 0x003A10DE, 0x005910DE, 0x008A10DE, 0x026B10DE
    dd 0

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
    dd 0x4144, snd_v_ad, 0x414C, snd_v_realtek, 0x4352, snd_v_cirrus
    dd 0x5649, snd_v_via, 0x594D, snd_v_yamaha, 0x5452, snd_v_tritech
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
snd_v_yamaha    db "Yamaha", 0
snd_v_tritech   db "TriTech", 0
snd_v_other     db "unknown maker", 0
snd_results:    dd snd_r0, snd_r1, snd_r2, snd_r3, snd_r4, snd_r5, snd_r6
snd_r0          db "in use", 0
snd_r1          db "no MOOS driver for this kind", 0
snd_r2          db "its registers cannot be reached", 0
snd_r3          db "the controller would not reset", 0
snd_r4          db "no codec answered", 0
snd_r5          db "no analogue output (HDMI/DisplayPort only?)", 0
snd_r6          db "no output stream", 0
snd_states:     dd snd_st0, snd_st1, snd_st2, snd_st3
snd_st0         db "none open", 0
snd_st1         db "open, waiting for sound", 0
snd_st2         db "playing", 0
snd_st3         db "paused", 0

section .bss
snd_ready     resb 1                    ; a card is set up
snd_tried     resb 1                    ; snd_init has looked (and failed)
snd_card      resb 1                    ; SND_NONE / SND_HDA / SND_AC97
snd_state     resb 1                    ; SS_*
snd_imm       resb 1                    ; HDA: immediate command interface
snd_force_imm resb 1                    ; ("sound reset pio")
snd_clfl      resb 1                    ; the CPU has CLFLUSH
snd_tick_on   resb 1                    ; snd_sync64 may work on the ring
snd_stopped   resb 1                    ; snd_sync64 saw the card stop
snd_vra       resb 1                    ; AC'97: the codec can change rate
snd_sw        resb 1                    ; volume by scaling the samples
snd_sine_ok   resb 1
snd_cl_long   resb 1                    ; reading a connection list
snd_t_mode    resb 1                    ; "sound test": which test
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
snd_gcap      resd 1
snd_codecs    resd 1                    ; codecs present (STATESTS)
snd_corb_mask resd 1
snd_rirb_mask resd 1
snd_rirb_rp   resd 1                    ; last response read
snd_cad       resd 1                    ; codec address << 28
snd_cadn      resd 1                    ; codec address
snd_codec_id  resd 1                    ; vendor << 16 | device
snd_codec_rev resd 1
snd_afg       resd 1                    ; audio function group node
snd_afg_pcm   resd 1                    ; its defaults: rates, amplifiers
snd_afg_oamp  resd 1
snd_afg_iamp  resd 1
snd_wfirst    resd 1                    ; its widgets: first node, count
snd_wcount    resd 1
snd_rates     resd 1                    ; rates (P_PCM bits) all our DACs do
snd_fmt       resd 1                    ; HDA stream format
snd_nout      resd 1                    ; HDA outputs in use (primary first)
snd_opin      resd SND_MAXOUT           ; their pins...
snd_odac      resd SND_MAXOUT           ; ... DACs ...
snd_onhop     resd SND_MAXOUT           ; ... and the way between:
snd_ohop      resb SND_MAXOUT * 16      ; (node, connection) from the pin
snd_ovol_nid  resd SND_MAXOUT           ; the amplifier used as volume (0:
snd_ovol_amp  resd SND_MAXOUT           ; none), which one of the node's,
snd_ovol_caps resd SND_MAXOUT           ; and its capabilities
snd_fmax      resd 1                    ; path search: longest way allowed
snd_fhops     resd 1                    ; the way found
snd_fhop      resb 16
snd_cl_prev   resd 1                    ; reading a connection list
snd_cl_resp   resd 1
snd_until     resd 1                    ; snd_timer / snd_late
snd_wcaps     resd 128                  ; the codec's widgets, by node
snd_pcaps     resd 128
snd_pcfg      resd 128
snd_nconn     resb 128
snd_conn      resb 128 * SND_MAXCONN
snd_ac_vid    resd 1                    ; AC'97 codec ID, extended ID
snd_ac_ext    resd 1
snd_ac_max    resd 1                    ; AC'97 master: most attenuation
snd_nseen     resd 1                    ; audio devices snd_find saw
snd_seen_pci  resd SND_MAXSEEN
snd_seen_ids  resd SND_MAXSEEN
snd_seen_cls  resd SND_MAXSEEN          ; subclass
snd_seen_res  resd SND_MAXSEEN          ; R_*
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
snd_tick_p    resd 1                    ; snd_sync64: ring position last seen
snd_tick_cnt  resd 1                    ; ... frames played since the start
snd_lead      resd 1                    ; SND_LEAD_MS in card frames
snd_guard     resd 1                    ; SND_GUARD_MS in card frames
snd_maxfill   resd 1                    ; SND_FILL_MS in card frames
snd_p_n       resd 1                    ; (snd_put)
snd_p_in      resd 1
snd_p_r       resd 1
snd_p_room    resd 1
snd_tmp       resd 1
; "sound test"
snd_t_rate    resd 1
snd_t_done    resd 1                    ; frames written so far
snd_t_end     resd 1                    ; ... and where this part ends
snd_t_switch  resd 1                    ; the frame where 880 Hz begins
snd_t_f1      resd 1                    ; the two frequencies
snd_t_f2      resd 1
snd_t_phase   resd 1
snd_t_start   resd 1                    ; ticks at the first sound
snd_t_limit   resd 1                    ; ticks when the test gives up
snd_t_p1      resd 1
snd_t_p2      resd 1
snd_t_loop    resd 1
snd_sine      resw 1024
snd_tbuf      resd SND_TCHUNK
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
    mov dword [snd_nseen], 0
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
    mov edi, eax                        ; (big_alloc cleared it through the
    mov ecx, 4096                       ; cache: write that out before the
    call snd_flush_bytes                ; card writes there)
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
    xor eax, eax
    mov ecx, SND_RING
    call snd_flush_ring
.have_buf:
    call snd_find
    jc .fail
    mov byte [snd_ready], 1
    call snd_apply_volume
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
    call snd_hw_format                  ; ... set (it may still change it)
    mov [snd_dev_rate], eax
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
    mov [snd_tick_p], eax
    mov [snd_tick_cnt], eax
    mov [snd_stopped], al
    mov eax, SND_LEAD_MS                ; queue limits in card frames
    call snd_ms_frames
    mov [snd_lead], eax
    mov eax, SND_GUARD_MS
    call snd_ms_frames
    mov [snd_guard], eax
    mov eax, SND_FILL_MS
    call snd_ms_frames
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

; snd_ms_frames: EAX = milliseconds -> EAX = card frames
snd_ms_frames:
    push ecx
    push edx
    mul dword [snd_dev_rate]
    mov ecx, 1000
    div ecx
    pop edx
    pop ecx
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
    ; Converting: allow for the converter's rounding and the frames it
    ; holds, so that all of these are surely taken.
    sub eax, 2
    jbe .none
    mul ecx
    div dword [snd_dev_rate]
    sub eax, 1
    ja .same
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
    mov eax, edi
    call snd_flush_ring                 ; (for cards that do not snoop)
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
    cmp byte [snd_state], SS_RUN
    je .run
    cmp byte [snd_state], SS_IDLE
    jne .done
    mov byte [snd_state], SS_PAUSED
.done:
    ret
.run:
    call snd_halt
    mov byte [snd_state], SS_PAUSED
    ret

; snd_resume: carry on after snd_pause
snd_resume:
    cmp byte [snd_state], SS_PAUSED
    jne .done
    push eax
    mov eax, [snd_wr]
    sub eax, [snd_hw]
    test eax, eax
    jle .empty
    call snd_restart                    ; play what is queued
    pop eax
.done:
    ret
.empty:
    mov eax, [snd_hw]                   ; nothing queued: wait for snd_write
    mov [snd_wr], eax                   ; (the whole ring is silent, so slot
    mov [snd_base], eax                 ; 0 can be the next frame)
    mov byte [snd_state], SS_IDLE
    pop eax
    ret

; snd_close: stop the card and forget the stream
snd_close:
    cmp byte [snd_state], SS_CLOSED
    je .done
    call snd_halt
    mov byte [snd_state], SS_CLOSED
.done:
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
; snd_sync: run snd_sync64 (count what the card played, silence it)
snd_sync:
    push eax
    mov eax, snd_sync_far64
    call efi64
    pop eax
    ret

; snd_update: bring snd_hw up to date with the card's position (while it
; runs). Restarts the card if it has stopped by itself (AC'97 at the end of
; its buffers, HDA on a descriptor error).
snd_update:
    cmp byte [snd_state], SS_RUN
    je .go
    ret
.go:
    push eax
    call snd_sync
    mov eax, [snd_base]
    add eax, [snd_tick_cnt]
    mov [snd_hw], eax
    cmp byte [snd_stopped], 0
    je .done
    call snd_halt                       ; (it stopped: start it again where
    call snd_restart                    ; it got to)
.done:
    pop eax
    ret

; snd_halt: stop the card, count what it played up to that moment
snd_halt:
    push eax
    cmp byte [snd_tick_on], 0
    je .done
    call snd_hw_stop
    call snd_sync
    mov byte [snd_tick_on], 0
    mov eax, [snd_base]
    add eax, [snd_tick_cnt]
    mov [snd_hw], eax
.done:
    pop eax
    ret

; snd_room: put the write position where new frames must go -> EAX = card
; frames that may be written there now. While the card runs, new frames go
; at least snd_guard ahead of it; when fewer are queued (an underrun, or
; nearly) they go snd_lead ahead (the card reads a little ahead of what it
; reports, and frames behind it would only be heard a whole trip later).
snd_room:
    push ecx
    mov eax, [snd_wr]
    sub eax, [snd_hw]                   ; EAX = frames queued (< 0: underrun)
    cmp byte [snd_state], SS_RUN
    jne .stopped
    cmp eax, [snd_guard]
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

; snd_restart: start the (stopped) card at ring slot 0, which becomes frame
; snd_hw. The frames not yet played are moved there first.
snd_restart:
    pushad
    mov ecx, [snd_wr]
    sub ecx, [snd_hw]
    test ecx, ecx
    jg .move
    mov eax, [snd_hw]                   ; (all silence: nothing to move)
    mov [snd_wr], eax
    jmp .based
.move:
    mov eax, [snd_hw]
    sub eax, [snd_base]
    call snd_ring_rotate
.based:
    mov eax, [snd_hw]
    mov [snd_base], eax
    xor eax, eax
    mov [snd_tick_p], eax
    mov [snd_tick_cnt], eax
    mov [snd_stopped], al
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
    mov [snd_p_n], ecx
    mov [snd_p_in], ecx
    mov [snd_p_r], edx
    mov [snd_p_room], edx
    shl edi, 2
    add edi, [snd_buf]                  ; EDI = where in the ring
    mov eax, [snd_rate]
    cmp eax, [snd_dev_rate]
    jne .convert
    cmp dword [snd_chans], 2
    jne .copy
    cmp dword [snd_swvol], 32768
    jne .copy
.fast:                                  ; stereo, same rate, full volume:
    mov ecx, [snd_p_in]                 ; plain copies, up to the ring's end
    cmp ecx, [snd_p_room]
    jbe .f1
    mov ecx, [snd_p_room]
.f1:
    mov eax, [snd_buf_end]
    sub eax, edi
    shr eax, 2
    cmp ecx, eax
    jbe .f2
    mov ecx, eax
.f2:
    test ecx, ecx
    jz .end
    sub [snd_p_in], ecx
    sub [snd_p_room], ecx
    rep movsd
    cmp edi, [snd_buf_end]
    jb .fast
    mov edi, [snd_buf]
    jmp .fast
.copy:                                  ; the same rate: frame for frame
    cmp dword [snd_p_in], 0
    je .end
    cmp dword [snd_p_room], 0
    je .end
    call snd_get                        ; EAX = left, EBP = right
    add esi, [snd_stride]
    call snd_store
    dec dword [snd_p_in]
    dec dword [snd_p_room]
    jmp .copy
.convert:
    ; Linear interpolation: each card frame lies snd_frac of the way from
    ; the input frame "prev" to the next one, "cur". After each card frame
    ; the position moves on by the step (input / card rate); snd_need says
    ; how many input frames to take before the next card frame. The state
    ; carries over from one write to the next.
    cmp dword [snd_need], 0
    je .emit
    cmp dword [snd_p_in], 0             ; input left?
    je .end
    mov eax, [snd_curl]
    mov [snd_prevl], eax
    mov eax, [snd_curr]
    mov [snd_prevr], eax
    call snd_get
    add esi, [snd_stride]
    mov [snd_curl], eax
    mov [snd_curr], ebp
    dec dword [snd_p_in]
    dec dword [snd_need]
    jmp .convert
.emit:
    cmp dword [snd_p_room], 0           ; room left?
    je .end
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
    dec dword [snd_p_room]
    mov eax, [snd_step_f]               ; on to the next card frame
    add [snd_frac], eax
    mov eax, [snd_step_i]
    adc eax, 0
    mov [snd_need], eax
    jmp .convert
.end:
    mov eax, [snd_p_n]                  ; taken = given - left over
    sub eax, [snd_p_in]
    mov ecx, [snd_p_r]                  ; written = room - room left
    sub ecx, [snd_p_room]
    pop ebp
    pop edi
    pop esi
    pop edx
    pop ebx
    ret

; snd_get: ESI = an input frame -> EAX = left, EBP = right (sign-extended)
snd_get:
    movsx eax, word [esi]
    cmp dword [snd_chans], 1
    je .mono
    movsx ebp, word [esi + 2]
    ret
.mono:
    mov ebp, eax                        ; mono: the same on both sides
    ret

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

; ----------------------------------------------------------- ring helpers
; snd_flush_bytes: EDI = address, ECX = bytes -> those cache lines are
; written out to memory (for cards that read memory past the CPU's cache)
snd_flush_bytes:
    cmp byte [snd_clfl], 0
    je .r
    test ecx, ecx
    jz .r
    push eax
    push ecx
    add ecx, edi                        ; ECX = the end
    mov eax, edi
    and eax, -SND_LINE
.l: clflush [eax]
    add eax, SND_LINE
    cmp eax, ecx
    jb .l
    mfence
    pop ecx
    pop eax
.r: ret

; snd_flush_ring: EAX = ring slot, ECX = frames -> written out (round the
; end of the ring if need be)
snd_flush_ring:
    pushad
    mov edx, eax
    and edx, SND_RMASK
    mov ebx, ecx
.part:
    test ebx, ebx
    jz .done
    mov ecx, SND_RING
    sub ecx, edx                        ; frames up to the end of the ring
    cmp ecx, ebx
    jbe .n
    mov ecx, ebx
.n: sub ebx, ecx
    lea edi, [edx * 4]
    add edi, [snd_buf]
    shl ecx, 2
    call snd_flush_bytes
    xor edx, edx
    jmp .part
.done:
    popad
    ret

; snd_ring_zero: EAX = ring slot, ECX = frames -> made silent (round the end
; of the ring if need be; at most the whole ring)
snd_ring_zero:
    pushad
    mov edx, eax
    and edx, SND_RMASK
    mov ebx, ecx
    cmp ebx, SND_RING
    jbe .part
    mov ebx, SND_RING
.part:
    test ebx, ebx
    jz .done
    mov ecx, SND_RING
    sub ecx, edx
    cmp ecx, ebx
    jbe .n
    mov ecx, ebx
.n: sub ebx, ecx
    lea edi, [edx * 4]
    add edi, [snd_buf]
    push ecx
    push edi
    xor eax, eax
    rep stosd
    pop edi
    pop ecx
    shl ecx, 2
    call snd_flush_bytes
    xor edx, edx
    jmp .part
.done:
    popad
    ret

; snd_ring_rotate: EAX = ring slot S of the first frame not yet played,
; ECX = frames N queued from there (fewer than half the ring) -> they are
; moved to slot 0, and their old place made silent. The rest of the ring
; is silence already.
snd_ring_rotate:
    pushad
    and eax, SND_RMASK
    jz .done
    mov ebx, eax                        ; EBX = S
    mov edx, ecx                        ; EDX = N
    lea eax, [ebx + edx]
    cmp eax, SND_RING
    ja .wraps
    ; [S, S+N) -> [0, N): copying forwards is safe (the target is lower)
    mov esi, [snd_buf]
    lea esi, [esi + ebx * 4]
    mov edi, [snd_buf]
    mov ecx, edx
    rep movsd
    mov eax, ebx                        ; silence [max(N, S), S + N)
    cmp eax, edx
    jae .z
    mov eax, edx
.z: lea ecx, [ebx + edx]
    sub ecx, eax
    call snd_ring_zero
    jmp .flush
.wraps:
    ; A = [S, end) (a frames) and B = [0, b): B moves up to [a, N) first
    ; (backwards, as the two places overlap), then A down to [0, a). A's
    ; old place lies above N, so nothing is lost.
    mov ebp, SND_RING
    sub ebp, ebx                        ; EBP = a
    mov ecx, edx
    sub ecx, ebp                        ; ECX = b
    mov esi, [snd_buf]
    lea esi, [esi + ecx * 4 - 4]        ; the last frame of B
    mov edi, [snd_buf]
    lea edi, [edi + edx * 4 - 4]        ; ... goes to slot N - 1
    std
    rep movsd
    cld
    mov esi, [snd_buf]
    lea esi, [esi + ebx * 4]
    mov edi, [snd_buf]
    mov ecx, ebp
    rep movsd
    mov eax, ebx                        ; [S, end) is silence again
    mov ecx, ebp
    call snd_ring_zero
.flush:
    xor eax, eax
    mov ecx, edx
    call snd_flush_ring
.done:
    popad
    ret

; ===================================================== hardware, either card
; snd_hw_start: start the card at the start of the ring
snd_hw_start:
    cmp byte [snd_card], SND_AC97
    je ac97_start
    jmp hda_start

; snd_hw_stop: stop the card (its position stays readable)
snd_hw_stop:
    cmp byte [snd_card], SND_AC97
    je ac97_stop
    jmp hda_stop

; snd_pick_rate: EAX = the player's rate -> EAX = the rate to run the card
; at: 44100 for rates of that family (11025, 22050, 88200 ...) if the card
; can do it, else 48000 (or 44100 when it cannot do 48000)
snd_pick_rate:
    push ecx
    push edx
    mov ecx, [snd_rates]
    xor edx, edx
    push eax
    push ecx
    mov ecx, 11025
    div ecx
    pop ecx
    pop eax
    test edx, edx
    jnz .not44
    test ecx, PCM_44K
    jnz .r44
.not44:
    test ecx, PCM_48K
    jnz .r48
    test ecx, PCM_44K
    jnz .r44
.r48:
    mov eax, 48000
    jmp .done
.r44:
    mov eax, 44100
.done:
    pop edx
    pop ecx
    ret

; snd_hw_format: EAX = rate (44100 / 48000) -> the card set to 16-bit stereo
; at that rate; EAX = the rate it really plays at
snd_hw_format:
    cmp byte [snd_card], SND_AC97
    je ac97_format
    jmp hda_format

; snd_apply_volume: set the card (or the software gain) to snd_vol
snd_apply_volume:
    pushad
    mov dword [snd_swvol], 32768
    mov byte [snd_sw], 0
    cmp byte [snd_card], SND_AC97
    je .ac97
    cmp byte [snd_card], SND_HDA
    jne .done
    call hda_volume
    jmp .done
.ac97:
    call ac97_volume
.done:
    cmp byte [snd_sw], 0
    je .out
    ; software: -0.5 dB per step below 100 (0.944 = 30935 / 32768)
    mov eax, 32768
    mov ecx, 100
    sub ecx, [snd_vol]
    jz .out
    cmp dword [snd_vol], 0
    jne .soft
    xor eax, eax
    jmp .set
.soft:
    imul eax, 30935
    shr eax, 15
    loop .soft
.set:
    mov [snd_swvol], eax
.out:
    popad
    ret

; snd_vol_steps: EAX = amplifier capabilities -> EDX = gain bits for
; snd_vol (0x80 = mute): 100 is 0 dB, each step below it -0.5 dB
snd_vol_steps:
    push eax
    push ebx
    push ecx
    mov edx, 0x80
    cmp dword [snd_vol], 0
    je .done
    mov ebx, eax
    shr ebx, 16
    and ebx, 0x7F
    inc ebx                             ; EBX = step size, quarter dB
    call snd_amp_unity                  ; ECX = the 0 dB step
    mov eax, 100
    sub eax, [snd_vol]
    add eax, eax                        ; quarter dB down
    mov edx, ebx
    shr edx, 1
    add eax, edx
    xor edx, edx
    div ebx                             ; EAX = steps down
    mov edx, ecx
    sub edx, eax
    jns .done
    xor edx, edx
.done:
    pop ecx
    pop ebx
    pop eax
    ret

; snd_amp_unity: EAX = amplifier capabilities -> ECX = its 0 dB step (the
; offset; not more than the steps it has)
snd_amp_unity:
    push eax
    mov ecx, eax
    and ecx, 0x7F
    shr eax, 8
    and eax, 0x7F
    cmp ecx, eax
    jbe .r
    mov ecx, eax
.r: pop eax
    ret

; ================================================================ finding
; snd_find: look on the PCI buses for a sound card and set the first one
; that works up -> CF=1 if there is none. Every audio device seen is noted
; (snd_seen_*) for the status text.
snd_find:
    pushad
    mov ebx, -1
.scan:
    call pci_next
    jc .none
    mov ecx, eax                        ; ECX = IDs
    mov al, 0x08
    call pci_read32
    shr eax, 16                         ; AH = class, AL = subclass
    cmp ah, 0x04
    jne .scan
    movzx edx, al
    mov esi, [snd_nseen]                ; note it
    cmp esi, SND_MAXSEEN
    jae .noted
    mov [snd_seen_pci + esi * 4], ebx
    mov [snd_seen_ids + esi * 4], ecx
    mov [snd_seen_cls + esi * 4], edx
    mov dword [snd_seen_res + esi * 4], R_NODRIVER
    inc dword [snd_nseen]
.noted:
    mov [snd_pci], ebx
    mov [snd_vendev], ecx
    cmp dl, 0x03
    je .hda
    cmp dl, 0x01
    jne .scan
    mov edi, snd_ac97_ids               ; AC'97: only the chips that work
.id:                                    ; like Intel's
    mov eax, [edi]
    test eax, eax
    jz .scan
    add edi, 4
    cmp eax, ecx
    jne .id
    call snd_pci_d0
    call ac97_init
    jmp .tried
.hda:
    call snd_pci_d0
    call hda_init
.tried:
    pushf
    cmp esi, SND_MAXSEEN
    jae .result
    movzx eax, al
    mov [snd_seen_res + esi * 4], eax
.result:
    popf
    jc .scan
    popad
    clc
    ret
.none:
    popad
    stc
    ret

; snd_pci_d0: EBX = PCI device -> put in the working power state (D0) if
; the firmware left it asleep
snd_pci_d0:
    pushad
    mov al, 0x04
    call pci_read32
    test eax, 1 << 20                   ; has a capability list?
    jz .done
    mov al, 0x34
    call pci_read32
    movzx edx, al
    mov ecx, 48                         ; (a bad list cannot loop for ever)
.next:
    and edx, 0xFC
    jz .done
    mov al, dl
    call pci_read32
    cmp al, 0x01                        ; power management
    je .pm
    movzx edx, ah
    loop .next
    jmp .done
.pm:
    lea eax, [edx + 4]                  ; PMCSR
    call pci_read32
    test al, 3
    jz .done
    and eax, 0xFFFF7FFC                 ; D0 (and do not clear PME status)
    mov ecx, eax
    lea eax, [edx + 4]
    call pci_write32
    mov ecx, 2                          ; (10 ms to wake up)
    call snd_sleep
.done:
    popad
    ret

; ---------------------------------------------------------------- timing
; snd_timer: ECX = ticks -> snd_late says "late" once that many whole
; ticks (1/100 s) have passed
snd_timer:
    push eax
    mov eax, [ticks]
    lea eax, [eax + ecx + 1]
    mov [snd_until], eax
    pop eax
    ret

; snd_late: -> CF=1 when the time set by snd_timer has come
snd_late:
    push eax
    mov eax, [ticks]
    sub eax, [snd_until]
    pop eax
    jns .late
    clc
    ret
.late:
    stc
    ret

; snd_sleep: ECX = ticks -> waits at least that many whole ticks
snd_sleep:
    call snd_timer
.w: call snd_late
    jc .r
    hlt
    jmp .w
.r: ret

; ========================================================================
;  Intel High Definition Audio
; ========================================================================
; hda_init: EBX = PCI address of an HDA controller -> CF=0 if it has a codec
; with an output MOOS can use, all set up; else CF=1, AL = R_* (why not)
hda_init:
    pushad
    mov al, 0x10
    call pci_mmio_bar
    mov byte [esp + 28], R_BAR
    jc .fail
    mov [snd_mmio], eax
    call pci_enable                     ; memory decoding, bus master
    cmp word [snd_vendev], 0x8086       ; Intel: traffic class 0 (TCSEL), as
    jne .tc                             ; other drivers do against crackles
    mov al, 0x44
    call pci_read32
    and eax, ~7
    mov ecx, eax
    mov al, 0x44
    call pci_write32
.tc:
    mov byte [esp + 28], R_RESET
    call hda_reset
    jc .fail
    mov byte [esp + 28], R_NOCODEC
    cmp dword [snd_codecs], 0
    je .fail
    call hda_rings
    mov esi, [snd_mmio]
    movzx eax, word [esi + HDA_GCAP]
    mov [snd_gcap], eax
    mov ecx, eax
    shr ecx, 12
    and ecx, 15                         ; output streams
    mov byte [esp + 28], R_NOSTREAM
    jz .fail
    shr eax, 8
    and eax, 15                         ; input streams come first
    shl eax, 5
    lea eax, [esi + eax + HDA_SD0]
    mov [snd_sd], eax
    ; the first codec with an output
    mov byte [esp + 28], R_NOCODEC
    xor ecx, ecx
.codec:
    bt dword [snd_codecs], ecx
    jnc .nextc
    mov [snd_cadn], ecx
    mov eax, ecx
    shl eax, 28
    mov [snd_cad], eax
    call hda_codec
    jnc .found
    mov [esp + 28], al                  ; (the reason of the last codec)
.nextc:
    inc ecx
    cmp ecx, 15
    jb .codec
.fail:
    mov eax, [esp + 28]
    mov byte [esp + 28 + 1], 0
    popad
    stc
    ret
.found:
    call hda_setup
    mov byte [snd_card], SND_HDA
    popad
    mov al, R_OK
    clc
    ret

; hda_reset: stop what the firmware may have left running, reset the
; controller and see which codecs are there (snd_codecs) -> CF=1 if the
; controller would not come out of reset
hda_reset:
    pushad
    mov esi, [snd_mmio]
    mov byte [esi + HDA_CORBCTL], 0
    mov byte [esi + HDA_RIRBCTL], 0
    movzx ecx, word [esi + HDA_GCAP]    ; every stream: stop
    mov eax, ecx
    shr eax, 12
    and eax, 15
    mov edx, ecx
    shr edx, 8
    and edx, 15
    add eax, edx
    shr ecx, 3
    and ecx, 31
    add ecx, eax
    lea edi, [esi + HDA_SD0]
    jecxz .stopped
.stop:
    and byte [edi + SD_CTL], ~2
    add edi, 0x20
    loop .stop
.stopped:
    mov ecx, 1
    call snd_sleep
    and dword [esi + HDA_GCTL], ~1      ; into reset ...
    mov ecx, 10
    call snd_timer
.in:
    test byte [esi + HDA_GCTL], 1
    jz .reset
    call snd_late
    jc .fail
    pause
    jmp .in
.reset:
    mov ecx, 1
    call snd_sleep
    or dword [esi + HDA_GCTL], 1        ; ... and out again
    mov ecx, 10
    call snd_timer
.out:
    test byte [esi + HDA_GCTL], 1
    jnz .running
    call snd_late
    jc .fail
    pause
    jmp .out
.running:
    ; the codecs say they are there within a few frames of the link; give
    ; slow ones up to 200 ms
    mov ecx, 2
    call snd_sleep
    mov ecx, 20
    call snd_timer
.codecs:
    movzx eax, word [esi + HDA_STATESTS]
    and eax, 0x7FFF
    jnz .seen
    call snd_late
    jc .seen
    hlt
    jmp .codecs
.seen:
    mov [snd_codecs], eax
    mov [esi + HDA_STATESTS], ax        ; (writing the bits clears them)
    mov dword [esi + HDA_INTCTL], 0
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

; hda_rings: set up and start the command ring (CORB) and the response ring
; (RIRB) - or choose the immediate command interface ("sound reset pio")
hda_rings:
    pushad
    mov esi, [snd_mmio]
    mov edi, [snd_ctl]
    mov byte [snd_imm], 1
    cmp byte [snd_force_imm], 0
    jne .done
    mov byte [snd_imm], 0
    call hda_rings_off
    ; CORB: the largest size the controller offers
    lea ebx, [esi + HDA_CORBSIZE]
    call hda_ring_size
    mov [snd_corb_mask], eax
    lea eax, [edi + SND_CORB]
    mov [esi + HDA_CORBLBASE], eax
    mov dword [esi + HDA_CORBUBASE], 0
    mov word [esi + HDA_CORBRP], 0x8000 ; reset the read pointer (the bit
    mov ecx, 1                          ; should read back as 1, then 0; not
    call snd_timer                      ; every controller shows that)
.rp1:
    test word [esi + HDA_CORBRP], 0x8000
    jnz .rp0
    call snd_late
    jnc .rp1
.rp0:
    mov word [esi + HDA_CORBRP], 0
    mov ecx, 1
    call snd_timer
.rp2:
    test word [esi + HDA_CORBRP], 0x8000
    jz .rpok
    call snd_late
    jnc .rp2
.rpok:
    mov word [esi + HDA_CORBWP], 0
    ; RIRB
    lea ebx, [esi + HDA_RIRBSIZE]
    call hda_ring_size
    mov [snd_rirb_mask], eax
    lea eax, [edi + SND_RIRB]
    mov [esi + HDA_RIRBLBASE], eax
    mov dword [esi + HDA_RIRBUBASE], 0
    mov word [esi + HDA_RIRBWP], 0x8000 ; write pointer back to 0
    mov word [esi + HDA_RINTCNT], 1
    mov dword [snd_rirb_rp], 0
    mov byte [esi + HDA_RIRBSTS], 0x05  ; (clear old status)
    mov byte [esi + HDA_CORBCTL], 2     ; run both (no interrupts)
    mov byte [esi + HDA_RIRBCTL], 2
.done:
    popad
    ret

; hda_ring_size: EBX = a CORBSIZE / RIRBSIZE register -> the largest size
; chosen; EAX = entries - 1
hda_ring_size:
    push ecx
    movzx ecx, byte [ebx]
    mov eax, ecx
    and cl, 0xF0
    test al, 0x40                       ; 256 entries possible?
    jnz .s256
    test al, 0x20
    jnz .s16
    test al, 0x10
    jnz .s2
.s256:                                  ; (no sizes listed: it has only 256)
    or cl, 2
    mov [ebx], cl
    mov eax, 255
    jmp .done
.s16:
    or cl, 1
    mov [ebx], cl
    mov eax, 15
    jmp .done
.s2:
    mov [ebx], cl
    mov eax, 1
.done:
    pop ecx
    ret

; hda_rings_off: stop the command and response rings
hda_rings_off:
    push ecx
    push esi
    mov esi, [snd_mmio]
    mov byte [esi + HDA_CORBCTL], 0
    mov byte [esi + HDA_RIRBCTL], 0
    mov ecx, 2
    call snd_timer
.w: mov cl, [esi + HDA_CORBCTL]
    or cl, [esi + HDA_RIRBCTL]
    test cl, 2
    jz .done
    call snd_late
    jnc .w
.done:
    pop esi
    pop ecx
    ret

; hda_cmd: EBX = node, EAX = verb and payload (20 bits) -> EAX = the codec's
; answer; CF=1 (EAX = 0) if it gave none. If the command rings fail, the
; immediate command interface is used from then on.
hda_cmd:
    push ebx
    and ebx, 0x7F
    shl ebx, 20
    or eax, ebx
    or eax, [snd_cad]
    pop ebx
    cmp byte [snd_imm], 0
    jne .imm
    call hda_corb_cmd
    jnc .r
    call hda_rings_off
    mov byte [snd_imm], 1
.imm:
    call hda_imm_cmd
    jnc .r
    xor eax, eax
    stc
.r: ret

; hda_corb_cmd: EAX = whole command -> EAX = answer, CF=1 (EAX kept) if no
; answer came within about 30 ms
hda_corb_cmd:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    mov esi, [snd_mmio]
    mov edi, [snd_ctl]
    movzx ecx, word [esi + HDA_CORBWP]
    inc ecx
    and ecx, [snd_corb_mask]
    lea edx, [edi + SND_CORB + ecx * 4]
    mov [edx], eax
    cmp byte [snd_clfl], 0
    je .sent
    clflush [edx]
    mfence
.sent:
    mov [esi + HDA_CORBWP], cx          ; the controller sends it
    mov ebx, eax
    mov ecx, 3
    call snd_timer
.wait:
    movzx eax, byte [esi + HDA_RIRBWP]
    cmp eax, [snd_rirb_rp]
    jne .got
    call snd_late
    jc .none
    pause
    jmp .wait
.got:
    mov ecx, [snd_rirb_rp]
    inc ecx
    and ecx, [snd_rirb_mask]
    mov [snd_rirb_rp], ecx
    lea edx, [edi + SND_RIRB + ecx * 8]
    cmp byte [snd_clfl], 0
    je .read
    clflush [edx]                       ; (read what the card wrote, not an
    mfence                              ; old copy in the cache)
.read:
    mov eax, [edx]
    test byte [edx + 4], 0x10           ; unsolicited (a jack event): skip
    jnz .wait
    mov byte [esi + HDA_RIRBSTS], 0x05
    clc
    jmp .out
.none:
    mov eax, ebx
    stc
.out:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; hda_imm_cmd: EAX = whole command -> EAX = answer, through the immediate
; command interface; CF=1 if none
hda_imm_cmd:
    push ecx
    push esi
    mov esi, [snd_mmio]
    mov ecx, 3
    call snd_timer
.idle:
    test word [esi + HDA_ICIS], 1       ; busy?
    jz .send
    call snd_late
    jc .none
    pause
    jmp .idle
.send:
    mov word [esi + HDA_ICIS], 2        ; (clear "answer valid")
    mov [esi + HDA_ICOI], eax
    mov word [esi + HDA_ICIS], 1        ; send
    mov ecx, 3
    call snd_timer
.wait:
    test word [esi + HDA_ICIS], 2
    jnz .got
    call snd_late
    jc .none
    pause
    jmp .wait
.got:
    mov eax, [esi + HDA_ICII]
    mov word [esi + HDA_ICIS], 2
    clc
    jmp .out
.none:
    stc
.out:
    pop esi
    pop ecx
    ret

; hda_param: EBX = node, AL = parameter -> EAX = its value (CF=1: no answer)
hda_param:
    movzx eax, al
    or eax, V_GETPARAM << 8
    jmp hda_cmd

; hda_power_d0: EBX = node -> powered up (waits until it says so, at most
; 100 ms)
hda_power_d0:
    push eax
    push ecx
    mov eax, V_SETPOWER << 8
    call hda_cmd
    jc .done
    mov ecx, 10
    call snd_timer
.w: mov eax, V_GETPOWER << 8
    call hda_cmd
    jc .done
    test al, 0xF0                       ; the state it is in (bits 7:4)
    jz .done
    call snd_late
    jc .done
    pause
    jmp .w
.done:
    pop ecx
    pop eax
    ret

; hda_codec: look at codec snd_cad: its audio function group, widgets and
; outputs -> CF=0 if it has an output MOOS can use (snd_opin...), else
; CF=1, AL = R_*
hda_codec:
    pushad
    mov edi, snd_wcaps                  ; forget the last codec
    mov ecx, 128
    xor eax, eax
    rep stosd
    mov edi, snd_nconn
    mov ecx, 128
    rep stosb
    mov byte [esp + 28], R_NOCODEC
    xor ebx, ebx                        ; the root node: who made it
    mov al, P_VENDOR
    call hda_param
    jc .fail
    mov [snd_codec_id], eax
    lea ecx, [eax + 1]
    cmp ecx, 1
    jbe .fail                           ; (0 or FFFFFFFF: nobody there)
    mov al, P_REVISION
    call hda_param
    mov [snd_codec_rev], eax
    mov al, P_NODES                     ; its function groups
    call hda_param
    jc .fail
    movzx ecx, al
    shr eax, 16
    movzx ebx, al
    mov byte [esp + 28], R_NOOUT
.fg:
    test ecx, ecx
    jz .fail
    cmp ebx, 128
    jae .fail
    mov al, P_FGTYPE
    call hda_param
    jc .fail
    cmp al, 1                           ; audio (2 would be a modem)
    je .afg
    inc ebx
    dec ecx
    jmp .fg
.afg:
    mov [snd_afg], ebx
    call hda_power_d0
    mov al, P_PCM
    call hda_param
    mov [snd_afg_pcm], eax
    mov al, P_OUTAMP
    call hda_param
    mov [snd_afg_oamp], eax
    mov al, P_INAMP
    call hda_param
    mov [snd_afg_iamp], eax
    mov al, P_NODES                     ; its widgets
    call hda_param
    jc .fail
    movzx ecx, al
    shr eax, 16
    movzx ebx, al
    mov [snd_wfirst], ebx
    mov [snd_wcount], ecx
.widget:
    test ecx, ecx
    jz .walked
    cmp ebx, 128
    jae .walked
    mov al, P_WCAPS
    call hda_param
    jc .fail
    or eax, WC_EXISTS
    mov [snd_wcaps + ebx * 4], eax
    shr eax, 20
    and eax, 15
    cmp eax, W_PIN
    jne .conns
    mov al, P_PINCAPS
    call hda_param
    mov [snd_pcaps + ebx * 4], eax
    mov eax, V_GETCFG << 8
    call hda_cmd
    mov [snd_pcfg + ebx * 4], eax
.conns:
    test dword [snd_wcaps + ebx * 4], WC_CONN
    jz .nextw
    call hda_read_conns
    jc .fail
.nextw:
    inc ebx
    dec ecx
    jmp .widget
.walked:
    call hda_outputs
    jc .fail
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

; hda_read_conns: EBX = node -> its connection list in snd_conn/snd_nconn
; (ranges written out; nodes above 127 kept as 0 so the indexes stay
; right). CF=1 if the codec stopped answering.
hda_read_conns:
    pushad
    mov byte [snd_nconn + ebx], 0
    mov al, P_CONNLEN
    call hda_param
    jc .fail
    mov edx, eax
    and edx, 0x7F                       ; EDX = entries
    test al, 0x80
    setnz byte [snd_cl_long]            ; 15-bit entries, 2 per answer
    xor esi, esi                        ; ESI = which entry
    mov dword [snd_cl_prev], 0
.entry:
    cmp esi, edx
    jae .done
    mov ecx, 3
    cmp byte [snd_cl_long], 0
    je .per
    mov ecx, 1
.per:
    test esi, ecx                       ; a new answer every 4 (or 2)
    jnz .have
    mov eax, esi
    or eax, V_GETCONN << 8
    call hda_cmd
    jc .fail
    mov [snd_cl_resp], eax
.have:
    mov eax, [snd_cl_resp]
    mov ecx, esi
    cmp byte [snd_cl_long], 0
    jne .long
    and ecx, 3
    shl ecx, 3
    shr eax, cl
    movzx edi, al
    and edi, 0x7F                       ; EDI = node
    test al, 0x80                       ; a range up to it?
    jmp .one
.long:
    and ecx, 1
    shl ecx, 4
    shr eax, cl
    movzx edi, ax
    and edi, 0x7FFF
    test ax, 0x8000
.one:
    jz .single
    mov eax, [snd_cl_prev]              ; every node after the last one
.range:
    inc eax
    cmp eax, edi
    ja .next
    call .add
    jmp .range
.single:
    mov eax, edi
    call .add
.next:
    mov [snd_cl_prev], edi
    inc esi
    jmp .entry
.done:
    popad
    clc
    ret
.fail:
    popad
    stc
    ret
.add:                                   ; EAX = node -> added to the list
    push ecx
    push edx
    movzx ecx, byte [snd_nconn + ebx]
    cmp ecx, SND_MAXCONN
    jae .full
    cmp eax, 128
    jb .ok
    xor eax, eax
.ok:
    mov edx, ebx
    shl edx, 5
    mov [snd_conn + edx + ecx], al
    inc byte [snd_nconn + ebx]
.full:
    pop edx
    pop ecx
    ret

; hda_outputs: choose the output pins and a way from each to a DAC
; (snd_nout, snd_opin, snd_odac, snd_onhop, snd_ohop, snd_rates) -> CF=1 if
; there is none. Line out first, then speakers, then headphones, all as
; the pin's configuration says they are wired; if no pin says so, any
; analogue output pin.
hda_outputs:
    pushad
    mov dword [snd_nout], 0
    xor edx, edx                        ; EDX = device type wanted
.kind:
    mov ebx, 1
.pin:
    call hda_out_ok
    jc .nextpin
    mov eax, [snd_pcfg + ebx * 4]
    shr eax, 30
    cmp eax, 1                          ; "not connected"
    je .nextpin
    mov eax, [snd_pcfg + ebx * 4]
    shr eax, 20
    and eax, 15
    cmp eax, edx
    jne .nextpin
    call hda_add_output
    cmp dword [snd_nout], SND_MAXOUT
    jae .found
.nextpin:
    inc ebx
    cmp ebx, 128
    jb .pin
    inc edx
    cmp edx, 2                          ; line out, speaker, headphone
    jbe .kind
    cmp dword [snd_nout], 0
    jne .found
    mov ebx, 1                          ; nothing wired: any analogue pin
.any:
    call hda_out_ok
    jc .nextany
    mov eax, [snd_pcfg + ebx * 4]
    shr eax, 20
    and eax, 15
    cmp eax, 4                          ; (not S/PDIF or other digital)
    je .nextany
    cmp eax, 5
    je .nextany
    call hda_add_output
    cmp dword [snd_nout], SND_MAXOUT
    jae .found
.nextany:
    inc ebx
    cmp ebx, 128
    jb .any
    cmp dword [snd_nout], 0
    jne .found
    popad
    stc
    ret
.found:
    ; the rates every DAC used can play
    mov eax, -1
    xor ecx, ecx
.rate:
    mov ebx, [snd_odac + ecx * 4]
    mov edx, [snd_afg_pcm]
    test dword [snd_wcaps + ebx * 4], WC_FMTOVR
    jz .and
    push eax
    mov al, P_PCM
    call hda_param
    mov edx, eax
    pop eax
.and:
    and eax, edx
    inc ecx
    cmp ecx, [snd_nout]
    jb .rate
    mov [snd_rates], eax
    popad
    clc
    ret

; hda_out_ok: EBX = node -> CF=0 if it is an analogue output pin
hda_out_ok:
    push eax
    mov eax, [snd_wcaps + ebx * 4]
    test eax, eax
    jz .no
    shr eax, 20
    and eax, 15
    cmp eax, W_PIN
    jne .no
    mov eax, [snd_pcaps + ebx * 4]
    test eax, PC_OUT
    jz .no
    test eax, PC_HDMI | PC_DP
    jnz .no
    test dword [snd_wcaps + ebx * 4], WC_DIGITAL
    jnz .no
    pop eax
    clc
    ret
.no:
    pop eax
    stc
    ret

; hda_add_output: EBX = output pin -> added to the outputs if a way leads
; from it to a DAC
hda_add_output:
    pushad
    call hda_find_path
    jc .done
    mov ecx, [snd_nout]
    mov [snd_opin + ecx * 4], ebx
    mov [snd_odac + ecx * 4], edx
    mov eax, [snd_fhops]
    mov [snd_onhop + ecx * 4], eax
    mov esi, snd_fhop
    mov edi, ecx
    shl edi, 4
    add edi, snd_ohop
    mov ecx, 16
    rep movsb
    inc dword [snd_nout]
.done:
    popad
    ret

; hda_find_path: EBX = pin -> CF=0, EDX = a DAC and the way to it in
; snd_fhop / snd_fhops; the shortest way is found first
hda_find_path:
    push ecx
    mov dword [snd_fmax], 1
.depth:
    xor ecx, ecx
    call hda_dfs
    jnc .found
    inc dword [snd_fmax]
    cmp dword [snd_fmax], SND_MAXHOP
    jbe .depth
    stc
.found:
    pop ecx
    ret

; hda_dfs: EBX = node, ECX = steps so far -> CF=0, EDX = DAC if a way of
; at most snd_fmax steps leads from the node to an analogue DAC through
; mixers and selectors (step k = node, connection index: snd_fhop[2k])
hda_dfs:
    push eax
    push ebx
    push esi
    push edi
    xor esi, esi                        ; ESI = connection index
.l: movzx eax, byte [snd_nconn + ebx]
    cmp esi, eax
    jae .no
    mov edi, ebx
    shl edi, 5
    movzx edi, byte [snd_conn + edi + esi]  ; EDI = where it leads
    test edi, edi
    jz .n
    mov eax, [snd_wcaps + edi * 4]
    test eax, eax
    jz .n
    mov [snd_fhop + ecx * 2], bl
    mov edx, esi
    mov [snd_fhop + ecx * 2 + 1], dl
    shr eax, 20
    and eax, 15
    cmp eax, W_DAC
    jne .via
    test dword [snd_wcaps + edi * 4], WC_DIGITAL
    jnz .n
    lea eax, [ecx + 1]
    mov [snd_fhops], eax
    mov edx, edi
    clc
    jmp .out
.via:
    cmp eax, W_MIXER
    je .deeper
    cmp eax, W_SEL
    jne .n
.deeper:
    lea eax, [ecx + 1]
    cmp eax, [snd_fmax]
    jae .n
    push ebx
    push ecx
    mov ebx, edi
    mov ecx, eax
    call hda_dfs
    pop ecx
    pop ebx
    jnc .out
.n: inc esi
    jmp .l
.no:
    stc
.out:
    pop edi
    pop esi
    pop ebx
    pop eax
    ret

; hda_setup: power, connect and unmute every output's way, point the DACs
; at our stream and choose the amplifiers for the volume
hda_setup:
    pushad
    xor ebp, ebp                        ; EBP = output
.output:
    cmp ebp, [snd_nout]
    jae .done
    mov dword [snd_ovol_nid + ebp * 4], 0
    mov esi, ebp
    shl esi, 4
    add esi, snd_ohop                   ; ESI = the way, from the pin
    xor edi, edi                        ; EDI = step
.step:
    cmp edi, [snd_onhop + ebp * 4]
    jae .dac
    movzx ebx, byte [esi + edi * 2]     ; EBX = node, EDX = connection used
    movzx edx, byte [esi + edi * 2 + 1]
    call hda_wake
    mov eax, [snd_wcaps + ebx * 4]
    shr eax, 20
    and eax, 15
    cmp eax, W_PIN
    jne .notpin
    call hda_pin_on
.notpin:
    cmp eax, W_MIXER
    je .mixer
    cmp byte [snd_nconn + ebx], 1       ; pins and selectors: choose the
    jbe .amps                           ; input
    mov eax, edx
    or eax, V_SETSEL << 8
    call hda_cmd
    test dword [snd_wcaps + ebx * 4], WC_INAMP
    jz .amps
    mov ecx, 1                          ; (a selector's input amplifier)
    call hda_amp_unity_set
    jmp .amps
.mixer:
    call hda_mixer_inputs
.amps:
    test dword [snd_wcaps + ebx * 4], WC_OUTAMP
    jz .nexts
    xor ecx, ecx
    call hda_amp_unity_set
.nexts:
    inc edi
    jmp .step
.dac:
    mov ebx, [snd_odac + ebp * 4]
    call hda_wake
    test dword [snd_wcaps + ebx * 4], WC_OUTAMP
    jz .stream
    xor ecx, ecx
    call hda_amp_unity_set
.stream:
    mov eax, (V_SETSTREAM << 8) | (HDA_TAG << 4)    ; stream 1, channel 0
    call hda_cmd
    call hda_pick_volume
    inc ebp
    jmp .output
.done:
    popad
    ret

; hda_wake: EBX = node -> powered up, if it has power control
hda_wake:
    test dword [snd_wcaps + ebx * 4], WC_POWER
    jz .r
    call hda_power_d0
.r: ret

; hda_pin_on: EBX = output pin -> its output (and headphone amplifier)
; switched on, and the external amplifier (EAPD) if it has one
hda_pin_on:
    push eax
    push ecx
    mov ecx, 0x40                       ; output enable
    test dword [snd_pcaps + ebx * 4], PC_HP
    jz .ctl
    mov eax, [snd_pcfg + ebx * 4]
    shr eax, 20
    and eax, 15
    cmp eax, 2                          ; a headphone jack
    jne .ctl
    or ecx, 0x80                        ; headphone amplifier
.ctl:
    mov eax, ecx
    or eax, V_SETPIN << 8
    call hda_cmd
    test dword [snd_pcaps + ebx * 4], PC_EAPD
    jz .done
    mov eax, V_GETEAPD << 8
    call hda_cmd
    and eax, 0x07
    or eax, 0x02                        ; EAPD on
    or eax, V_SETEAPD << 8
    call hda_cmd
.done:
    pop ecx
    pop eax
    ret

; hda_mixer_inputs: EBX = mixer, EDX = the input used -> that input
; unmuted at 0 dB, the others (loopback from the inputs...) muted
hda_mixer_inputs:
    pushad
    test dword [snd_wcaps + ebx * 4], WC_INAMP
    jz .done
    mov esi, edx
    xor edx, edx
.l: movzx eax, byte [snd_nconn + ebx]
    cmp edx, eax
    jae .done
    cmp edx, esi
    je .used
    mov eax, edx                        ; mute
    shl eax, 8
    or eax, HDA_AMP_IN
    push edx
    mov edx, 0x80
    call hda_amp_set
    pop edx
    jmp .n
.used:
    mov ecx, 1
    call hda_amp_unity_set
.n: inc edx
    jmp .l
.done:
    popad
    ret

; hda_amp_caps: EBX = node, ECX = 0 output / 1 input amplifier -> EAX =
; its capabilities (the function group's when it has none of its own)
hda_amp_caps:
    test dword [snd_wcaps + ebx * 4], WC_AMPOVR
    jnz .own
    mov eax, [snd_afg_oamp]
    test ecx, ecx
    jz .r
    mov eax, [snd_afg_iamp]
.r: ret
.own:
    mov al, P_OUTAMP
    test ecx, ecx
    jz .get
    mov al, P_INAMP
.get:
    jmp hda_param

; hda_amp_set: EBX = node, EAX = HDA_AMP_OUT or HDA_AMP_IN | index << 8,
; EDX = gain (0x80 = mute) -> set on both sides
hda_amp_set:
    push eax
    or eax, 0x3000                      ; left and right
    or eax, edx
    or eax, V_SETAMP4 << 16
    call hda_cmd
    pop eax
    ret

; hda_amp_unity_set: EBX = node, ECX = 0 output / 1 input (EDX = index)
; -> that amplifier unmuted at 0 dB
hda_amp_unity_set:
    pushad
    call hda_amp_caps
    push ecx
    call snd_amp_unity                  ; ECX = 0 dB step
    mov eax, ecx
    pop ecx
    xchg eax, edx                       ; EDX = gain, EAX = index
    shl eax, 8
    or eax, HDA_AMP_OUT
    test ecx, ecx
    jz .set
    xor eax, HDA_AMP_OUT | HDA_AMP_IN
.set:
    call hda_amp_set
    popad
    ret

; hda_pick_volume: EBP = output -> the amplifier nearest its DAC that can
; turn the sound down by at least 24 dB becomes its volume control
hda_pick_volume:
    pushad
    mov ebx, [snd_odac + ebp * 4]       ; the DAC's own
    xor ecx, ecx
    mov eax, HDA_AMP_OUT
    call .try
    jnc .done
    mov edi, [snd_onhop + ebp * 4]      ; then along the way, back to the pin
    mov esi, ebp
    shl esi, 4
    add esi, snd_ohop
.back:
    dec edi
    js .done
    movzx ebx, byte [esi + edi * 2]
    mov eax, [snd_wcaps + ebx * 4]
    shr eax, 20
    and eax, 15
    cmp eax, W_MIXER
    jne .out
    movzx eax, byte [esi + edi * 2 + 1] ; (a mixer: the input used)
    shl eax, 8
    or eax, HDA_AMP_IN
    mov ecx, 1
    call .try
    jnc .done
.out:
    xor ecx, ecx
    mov eax, HDA_AMP_OUT
    call .try
    jnc .done
    jmp .back
.done:
    popad
    ret
.try:                                   ; EBX node, EAX which, ECX in/out
    push eax
    mov eax, WC_OUTAMP
    jecxz .has
    mov eax, WC_INAMP
.has:
    test [snd_wcaps + ebx * 4], eax
    pop eax
    jz .no
    push eax
    call hda_amp_caps
    mov edx, eax
    pop eax
    push ecx
    push eax
    mov eax, edx
    call snd_amp_unity                  ; ECX = 0 dB step
    mov eax, edx
    shr eax, 16
    and eax, 0x7F
    inc eax
    imul ecx, eax                       ; quarter dB below 0 dB
    cmp ecx, 96
    pop eax
    pop ecx
    jb .no
    mov [snd_ovol_nid + ebp * 4], ebx
    mov [snd_ovol_amp + ebp * 4], eax
    mov [snd_ovol_caps + ebp * 4], edx
    clc
    ret
.no:
    stc
    ret

; hda_volume: set every output's volume amplifier to snd_vol (snd_sw = 1
; when the main output has none: then the samples are scaled)
hda_volume:
    pushad
    cmp dword [snd_ovol_nid], 0
    jne .hw
    mov byte [snd_sw], 1
.hw:
    xor ebp, ebp
.l: cmp ebp, [snd_nout]
    jae .done
    mov ebx, [snd_ovol_nid + ebp * 4]
    test ebx, ebx
    jz .n
    mov eax, [snd_ovol_caps + ebp * 4]
    call snd_vol_steps
    mov eax, [snd_ovol_amp + ebp * 4]
    call hda_amp_set
.n: inc ebp
    jmp .l
.done:
    popad
    ret

; hda_format: EAX = rate (44100 / 48000) -> the stream format, also told to
; every DAC; EAX = the rate
hda_format:
    push eax
    push ebx
    push ecx
    mov ecx, 0x0011                     ; 48 kHz, 16-bit, 2 channels
    cmp eax, 44100
    jne .f
    or ecx, 0x4000                      ; 44.1 kHz base
.f: mov [snd_fmt], ecx
    xor ebx, ebx
.dac:
    cmp ebx, [snd_nout]
    jae .done
    push ebx
    mov ebx, [snd_odac + ebx * 4]
    mov eax, ecx
    or eax, V_SETFMT4 << 16
    call hda_cmd
    pop ebx
    inc ebx
    jmp .dac
.done:
    pop ecx
    pop ebx
    pop eax
    ret

; hda_start: reset our output stream, give it the ring (32 descriptors)
; and the format, and run it
hda_start:
    pushad
    mov esi, [snd_sd]
    mov byte [esi + SD_CTL], 1          ; stream reset ...
    mov ecx, 2
    call snd_timer
.r1:
    test byte [esi + SD_CTL], 1
    jnz .r0
    call snd_late
    jnc .r1
.r0:
    mov byte [esi + SD_CTL], 0          ; ... and out of it
    mov ecx, 2
    call snd_timer
.r2:
    test byte [esi + SD_CTL], 1
    jz .reset
    call snd_late
    jnc .r2
.reset:
    mov dword [esi + SD_CTL], HDA_TAG << 20
    mov byte [esi + SD_STS], 0x1C       ; (clear old status)
    mov edi, [snd_ctl]
    add edi, SND_BDL
    mov eax, [snd_buf]
    mov ecx, SND_NBDL
    push edi
.bdl:
    mov [edi], eax                      ; address
    mov dword [edi + 4], 0
    mov dword [edi + 8], SND_BUFF * 4   ; length in bytes
    mov dword [edi + 12], 0             ; (no interrupt)
    add eax, SND_BUFF * 4
    add edi, 16
    loop .bdl
    pop edi
    mov ecx, SND_NBDL * 16
    call snd_flush_bytes
    mov [esi + SD_BDPL], edi
    mov dword [esi + SD_BDPU], 0
    mov dword [esi + SD_CBL], SND_RING * 4
    mov word [esi + SD_LVI], SND_NBDL - 1
    mov eax, [snd_fmt]
    mov [esi + SD_FMT], ax
    mov dword [esi + SD_CTL], (HDA_TAG << 20) | 2   ; run
    popad
    ret

; hda_stop: stop our output stream (LPIB keeps its place)
hda_stop:
    pushad
    mov esi, [snd_sd]
    mov dword [esi + SD_CTL], HDA_TAG << 20
    mov ecx, 2
    call snd_timer
.w: test byte [esi + SD_CTL], 2
    jz .done
    call snd_late
    jnc .w
.done:
    popad
    ret

; ========================================================================
;  AC'97
; ========================================================================
; ac97_init: EBX = PCI address of an ICH-compatible AC'97 controller ->
; CF=0 if its codec answered, all set up; else CF=1, AL = R_*
ac97_init:
    pushad
    mov byte [esp + 28], R_BAR
    mov al, 0x10                        ; mixer (NAM) and bus master (NABM)
    call pci_read32                     ; registers: I/O ports
    test al, 1
    jz .fail
    and eax, 0xFFFC
    jz .fail
    mov [snd_nam], eax
    mov al, 0x14
    call pci_read32
    test al, 1
    jz .fail
    and eax, 0xFFFC
    jz .fail
    mov [snd_nabm], eax
    call pci_enable
    cmp word [snd_vendev], 0x8086       ; ICH4 and later: the I/O ports
    jne .io                             ; must be switched on (IOSE)
    mov al, 0x18
    call pci_read32
    test al, 1
    jnz .io                             ; (no memory BARs: an older ICH)
    test eax, eax
    jz .io
    mov al, 0x40
    call pci_read32
    or eax, 1 << 8
    mov ecx, eax
    mov al, 0x40
    call pci_write32
.io:
    mov edx, [snd_nabm]                 ; stop the PCM out channel
    add edx, AC_PO_CR
    mov al, 0
    out dx, al
    ; cold reset of the link and the codec
    mov byte [esp + 28], R_NOCODEC
    mov edx, [snd_nabm]
    add edx, AC_GLOB_CNT
    in eax, dx
    and eax, ~7                         ; reset on, interrupts off
    out dx, eax
    mov ecx, 2
    call snd_sleep
    or eax, 2                           ; reset off
    out dx, eax
    mov edx, [snd_nabm]
    add edx, AC_GLOB_STA
    mov ecx, 100                        ; codec ready within 1 s
    call snd_timer
.ready:
    in eax, dx
    test eax, 1 << 8                    ; primary codec ready
    jnz .codec
    call snd_late
    jc .fail
    hlt
    jmp .ready
.codec:
    mov edx, [snd_nam]
    mov ax, 0                           ; mixer registers to defaults
    out dx, ax
    mov ecx, 1
    call snd_sleep
    add edx, AC_POWERDOWN               ; everything powered
    out dx, ax
    mov ecx, 100
    call snd_timer
.power:
    in ax, dx
    and ax, 0x0E                        ; DAC, analogue, reference ready
    cmp ax, 0x0E
    je .powered
    call snd_late
    jc .powered
    hlt
    jmp .power
.powered:
    mov edx, [snd_nam]
    add edx, AC_VID1
    in ax, dx
    shl eax, 16
    add edx, AC_VID2 - AC_VID1
    in ax, dx
    mov [snd_ac_vid], eax
    mov edx, [snd_nam]
    add edx, AC_EXTID
    in ax, dx
    movzx eax, ax
    mov [snd_ac_ext], eax
    and al, 1
    mov [snd_vra], al
    mov dword [snd_rates], PCM_48K
    jz .rates
    or dword [snd_rates], PCM_44K
    add edx, AC_EXTCTL - AC_EXTID       ; variable rate on
    in ax, dx
    or ax, 1
    out dx, ax
.rates:
    mov edx, [snd_nam]                  ; master volume: 5 or 6 bits?
    add edx, AC_MASTER
    mov ax, 0x2020
    out dx, ax
    in ax, dx
    mov dword [snd_ac_max], 63
    test ax, 0x20
    jnz .bits
    mov dword [snd_ac_max], 31
.bits:
    mov edx, [snd_nam]
    add edx, AC_PCMOUT
    mov ax, 0x0808                      ; PCM out at 0 dB, unmuted
    out dx, ax
    mov byte [snd_card], SND_AC97
    popad
    mov al, R_OK
    clc
    ret
.fail:
    mov eax, [esp + 28]
    popad
    stc
    ret

; ac97_format: EAX = rate -> the codec set to it; EAX = the rate it plays
; (48000 when it cannot change rate)
ac97_format:
    push edx
    cmp byte [snd_vra], 0
    je .fixed
    push eax
    mov edx, [snd_nam]
    add edx, AC_FRONTRATE
    out dx, ax
    in ax, dx
    movzx edx, ax
    pop eax
    cmp edx, eax
    je .done
    mov eax, 48000                      ; (it would not: back to 48 kHz)
    mov edx, [snd_nam]
    add edx, AC_FRONTRATE
    out dx, ax
    jmp .done
.fixed:
    mov eax, 48000
.done:
    pop edx
    ret

; ac97_volume: master and headphone volume from snd_vol (1.5 dB steps)
ac97_volume:
    pushad
    mov eax, 0x8000                     ; 0: mute
    cmp dword [snd_vol], 0
    je .set
    mov eax, 100
    sub eax, [snd_vol]                  ; 0.5 dB per step = 1/3 of 1.5 dB
    inc eax
    xor edx, edx
    mov ecx, 3
    div ecx
    cmp eax, [snd_ac_max]
    jbe .att
    mov eax, [snd_ac_max]
.att:
    mov ah, al
.set:
    mov edx, [snd_nam]
    add edx, AC_MASTER
    out dx, ax
    add edx, AC_HEADPHONE - AC_MASTER
    out dx, ax
    popad
    ret

; ac97_start: reset the PCM out channel, give it the ring (32 buffers) and
; run it
ac97_start:
    pushad
    mov edx, [snd_nabm]
    add edx, AC_PO_CR
    mov al, 2                           ; reset the channel's registers
    out dx, al
    mov ecx, 2
    call snd_timer
.rr:
    in al, dx
    test al, 2
    jz .reset
    call snd_late
    jnc .rr
.reset:
    mov edi, [snd_ctl]
    add edi, SND_BDL
    mov eax, [snd_buf]
    mov ecx, SND_NBDL
    push edi
.bdl:
    mov [edi], eax                      ; address
    mov dword [edi + 4], (1 << 30) | (SND_BUFF * 2)    ; samples; zeros if
    add eax, SND_BUFF * 4               ; it ever runs out (BUP)
    add edi, 8
    loop .bdl
    pop edi
    mov ecx, SND_NBDL * 8
    call snd_flush_bytes
    mov edx, [snd_nabm]
    add edx, AC_PO_BDBAR
    mov eax, edi
    out dx, eax
    add edx, AC_PO_LVI - AC_PO_BDBAR
    mov al, SND_NBDL - 1
    out dx, al
    add edx, AC_PO_SR - AC_PO_LVI
    mov ax, 0x1C                        ; (clear old status)
    out dx, ax
    add edx, AC_PO_CR - AC_PO_SR
    mov al, 1                           ; run
    out dx, al
    popad
    ret

; ac97_stop: stop the PCM out channel (its position stays readable)
ac97_stop:
    pushad
    mov edx, [snd_nabm]
    add edx, AC_PO_CR
    mov al, 0
    out dx, al
    add edx, AC_PO_SR - AC_PO_CR
    mov ecx, 2
    call snd_timer
.w: in ax, dx
    test al, 1                          ; halted
    jnz .done
    call snd_late
    jnc .w
.done:
    popad
    ret

; ========================================================================
;  The "sound" command
; ========================================================================
cmd_sound:
    cmp dword [argc], 2
    jb snd_status
    mov esi, [argv + 4]
    mov edi, snd_s_status
    call str_icmp
    je snd_status
    mov edi, snd_s_test
    call str_icmp
    je snd_test
    mov edi, snd_s_volume
    call str_icmp
    je .volume
    mov edi, snd_s_codec
    call str_icmp
    je snd_codec_list
    mov edi, snd_s_reset
    call str_icmp
    je .reset
    PRINTF `Usage: sound [status] | sound test [rate] | sound volume [0-100] | sound codec | sound reset\n`
    ret
.volume:
    cmp dword [argc], 3
    jb .show_vol
    mov esi, [argv + 8]
    call parse_uint
    jc .bad_vol
    cmp eax, 100
    ja .bad_vol
    call snd_volume
.show_vol:
    PRINTF `Volume: %d%%\n`, dword [snd_vol]
    ret
.bad_vol:
    PRINTF `The volume is a number from 0 (silent) to 100 (loudest).\n`
    ret
.reset:
    call snd_close                      ; look for the card again
    mov byte [snd_force_imm], 0
    cmp dword [argc], 3
    jb .again
    mov esi, [argv + 8]
    mov edi, snd_s_pio
    call str_icmp
    jne .again
    mov byte [snd_force_imm], 1         ; (HDA: no command rings)
.again:
    mov byte [snd_ready], 0
    mov byte [snd_tried], 0
    jmp snd_status

; snd_vendor_name: EAX = PCI vendor ID -> ESI = the maker's name
snd_vendor_name:
    push ecx
    push edi
    mov edi, snd_vendors
.l: mov ecx, [edi]
    mov esi, [edi + 4]
    test ecx, ecx
    jz .done
    add edi, 8
    cmp ecx, eax
    jne .l
.done:
    pop edi
    pop ecx
    ret

; snd_pci_print: EBX = PCI address, EAX = IDs -> prints "PCI bb:dd.f, vvvv:dddd"
snd_pci_print:
    pushad
    movzx esi, ax
    shr eax, 16
    mov edi, eax
    mov eax, ebx
    shr eax, 16
    and eax, 0xFF
    mov ecx, ebx
    shr ecx, 11
    and ecx, 0x1F
    mov edx, ebx
    shr edx, 8
    and edx, 7
    PRINTF `PCI %02x:%02x.%d, %04x:%04x`, eax, ecx, edx, esi, edi
    popad
    ret

; snd_node_print: EBX = node -> "pin 20" (its type and number)
snd_node_print:
    pushad
    mov eax, [snd_wcaps + ebx * 4]
    shr eax, 20
    and eax, 15
    mov esi, [snd_types + eax * 4]
    PRINTF `%s %d`, esi, ebx
    popad
    ret

; snd_status: tell what card is used and how (the "sound" command)
snd_status:
    pushad
    call snd_init
    jc .none
    PRINTF `\x01wSound\x01n\n`
    cmp byte [snd_card], SND_AC97
    je .ac97
    mov esi, [snd_mmio]
    movzx eax, byte [esi + HDA_VMAJ]
    movzx ecx, byte [esi + HDA_VMIN]
    PRINTF `  Card ........... Intel High Definition Audio %d.%d (`, eax, ecx
    mov ebx, [snd_pci]
    mov eax, [snd_vendev]
    call snd_pci_print
    mov eax, [snd_codec_id]
    shr eax, 16
    call snd_vendor_name
    movzx ecx, word [snd_codec_id]
    PRINTF `)\n  Codec .......... %d: %s (%04x:%04x), audio function group = node %d\n`, dword [snd_cadn], esi, eax, ecx, dword [snd_afg]
    xor ebp, ebp
.out:
    PRINTF `  Output ......... `
    mov ebx, [snd_opin + ebp * 4]
    mov eax, [snd_pcfg + ebx * 4]
    mov ecx, eax
    shr eax, 20
    and eax, 15
    shr ecx, 30
    PRINTF `%s (%s): `, dword [snd_devs + eax * 4], dword [snd_conns + ecx * 4]
    mov esi, ebp
    shl esi, 4
    add esi, snd_ohop
    xor edi, edi
.hop:
    cmp edi, [snd_onhop + ebp * 4]
    jae .last
    movzx ebx, byte [esi + edi * 2]
    call snd_node_print
    PRINTF ` <- `
    inc edi
    jmp .hop
.last:
    mov ebx, [snd_odac + ebp * 4]
    call snd_node_print
    PRINTF `\n`
    inc ebp
    cmp ebp, [snd_nout]
    jb .out
    mov esi, snd_s_corb
    cmp byte [snd_imm], 0
    je .cmds
    mov esi, snd_s_imm
.cmds:
    PRINTF `  Commands ....... %s\n`, esi
    jmp .common
.ac97:
    PRINTF `  Card ........... AC'97 (`
    mov ebx, [snd_pci]
    mov eax, [snd_vendev]
    call snd_pci_print
    mov eax, [snd_ac_vid]
    shr eax, 16
    call snd_vendor_name
    PRINTF `)\n  Codec .......... %s (ID %x)`, esi, dword [snd_ac_vid]
    mov esi, snd_s_vra
    cmp byte [snd_vra], 0
    jne .vra
    mov esi, snd_s_novra
.vra:
    PRINTF `, %s\n  Output ......... line out and headphone (master volume)\n`, esi
.common:
    PRINTF `  Rates .......... `
    test dword [snd_rates], PCM_44K
    jz .no44
    PRINTF `44.1 kHz  `
.no44:
    test dword [snd_rates], PCM_48K
    jz .no48
    PRINTF `48 kHz  `
.no48:
    PRINTF `(16-bit stereo; other rates are converted)\n`
    mov esi, snd_s_hwvol
    cmp byte [snd_sw], 0
    je .vol
    mov esi, snd_s_swvol
.vol:
    PRINTF `  Volume ......... %d%% (%s)\n`, dword [snd_vol], esi
    movzx eax, byte [snd_state]
    PRINTF `  Stream ......... %s`, dword [snd_states + eax * 4]
    test eax, eax
    jz .stream_done
    call snd_played
    PRINTF `: %d Hz, %d channel(s), the card at %d Hz; %d frames played`, dword [snd_rate], dword [snd_chans], dword [snd_dev_rate], eax
.stream_done:
    PRINTF `\n`
    call snd_others
    popad
    ret
.none:
    PRINTF `No sound card MOOS can use was found.\n`
    cmp dword [bootinfo + BI.platform], PLATFORM_UEFI
    jne .done
    PRINTF `MOOS plays sound on Intel High Definition Audio and AC'97 (Intel ICH and\ncompatible) sound cards.\n`
    call snd_others
.done:
    popad
    ret

section .data
snd_s_corb  db "command rings (CORB/RIRB)", 0
snd_s_imm   db "immediate command interface", 0
snd_s_vra   db "variable rate (44.1 and 48 kHz)", 0
snd_s_novra db "fixed rate (48 kHz)", 0
snd_s_hwvol db "the card's amplifier", 0
snd_s_swvol db "scaling the samples", 0
section .text

; snd_others: list the audio devices that are not in use, and why
snd_others:
    pushad
    xor esi, esi
.l: cmp esi, [snd_nseen]
    jae .done
    mov edx, [snd_seen_res + esi * 4]
    test edx, edx
    jz .n
    PRINTF `  Not used ....... `
    mov ebx, [snd_seen_pci + esi * 4]
    mov eax, [snd_seen_ids + esi * 4]
    call snd_pci_print
    mov eax, [snd_seen_cls + esi * 4]
    PRINTF ` (class 04.%02x): %s\n`, eax, dword [snd_results + edx * 4]
.n: inc esi
    jmp .l
.done:
    popad
    ret

; snd_codec_list: every widget of the HDA codec in use ("sound codec")
snd_codec_list:
    pushad
    call snd_init
    jc .none
    cmp byte [snd_card], SND_HDA
    jne .ac97
    call out_begin
    mov eax, [snd_codec_id]
    shr eax, 16
    call snd_vendor_name
    movzx ecx, word [snd_codec_id]
    PRINTF `\x01wCodec %d\x01n: %s (%04x:%04x, revision %x), audio function group = node %d\n`, dword [snd_cadn], esi, eax, ecx, dword [snd_codec_rev], dword [snd_afg]
    PRINTF `Rates/formats %x, amplifiers: out %x, in %x (by default)\n`, dword [snd_afg_pcm], dword [snd_afg_oamp], dword [snd_afg_iamp]
    PRINTF `node type         capabilities  connections\n`
    xor ebx, ebx
.node:
    mov eax, [snd_wcaps + ebx * 4]
    test eax, eax
    jz .next
    mov ecx, eax
    shr ecx, 20
    and ecx, 15
    and eax, 0x7FFFFFFF
    PRINTF `%4d %-12s %08x `, ebx, dword [snd_types + ecx * 4], eax
    movzx edi, byte [snd_nconn + ebx]
    xor esi, esi
.conn:
    cmp esi, edi
    jae .conns_done
    mov eax, ebx
    shl eax, 5
    movzx eax, byte [snd_conn + eax + esi]
    PRINTF ` %d`, eax
    inc esi
    jmp .conn
.conns_done:
    cmp ecx, W_PIN
    jne .eol
    mov eax, [snd_pcfg + ebx * 4]
    mov edx, eax
    shr eax, 20
    and eax, 15
    shr edx, 30
    PRINTF `   [%s, %s; config %x, pin caps %x]`, dword [snd_devs + eax * 4], dword [snd_conns + edx * 4], dword [snd_pcfg + ebx * 4], dword [snd_pcaps + ebx * 4]
.eol:
    call snd_in_use
    jc .nl
    PRINTF `  \x01g<- used\x01n`
.nl:
    PRINTF `\n`
.next:
    inc ebx
    cmp ebx, 128
    jb .node
    xor ebx, ebx
    call out_flush
    popad
    ret
.ac97:
    PRINTF `The AC'97 codec (ID %x) has fixed mixer registers; see "sound".\n`, dword [snd_ac_vid]
    popad
    ret
.none:
    PRINTF `No sound card MOOS can use was found.\n`
    popad
    ret

; snd_in_use: EBX = node -> CF=0 if it is on one of the outputs' ways
snd_in_use:
    pushad
    xor ebp, ebp
.out:
    cmp ebp, [snd_nout]
    jae .no
    cmp ebx, [snd_odac + ebp * 4]
    je .yes
    mov esi, ebp
    shl esi, 4
    add esi, snd_ohop
    xor edi, edi
.hop:
    cmp edi, [snd_onhop + ebp * 4]
    jae .n
    movzx eax, byte [esi + edi * 2]
    cmp eax, ebx
    je .yes
    inc edi
    jmp .hop
.n: inc ebp
    jmp .out
.yes:
    popad
    clc
    ret
.no:
    popad
    stc
    ret

; ------------------------------------------------------------ sound test
; snd_test: "sound test [rate] [gap|pause|reopen]": play test tones and
; check the timing by the card's position
;   (none)   1 s of 440 Hz, then 1 s of 880 Hz
;   gap      0.5 s of 440 Hz, 7 s of nothing written (longer than the
;            ring: an underrun the card must fill with silence), 0.5 s of
;            880 Hz
;   pause    440 Hz, paused for 1 s after 0.5 s, then 880 Hz
;   reopen   eight short tones, each a new stream (open / write / close)
snd_test:
    pushad
    mov dword [snd_t_rate], 44100
    mov byte [snd_t_mode], 0
    mov ebx, 2                          ; the words after "test"
.arg:
    cmp ebx, [argc]
    jae .args_done
    mov esi, [argv + ebx * 4]
    inc ebx
    call parse_uint
    jc .word
    mov [snd_t_rate], eax
    jmp .arg
.word:
    mov edi, snd_s_gap
    call str_icmp
    mov byte [snd_t_mode], 1
    je .arg
    mov edi, snd_s_pause
    call str_icmp
    mov byte [snd_t_mode], 2
    je .arg
    mov edi, snd_s_reopen
    call str_icmp
    mov byte [snd_t_mode], 3
    je .arg
    PRINTF `Usage: sound test [rate] [gap | pause | reopen]\n`
    popad
    ret
.args_done:
    call snd_init
    jc .nocard
    call snd_make_sine
    mov eax, [ticks]                    ; the whole test gives up after 15 s
    add eax, 1500
    mov [snd_t_limit], eax
    cmp byte [snd_t_mode], 3
    je .reopen
    mov eax, [snd_t_rate]
    mov ecx, 2
    call snd_open
    jc .badrate
    mov dword [snd_t_f1], 440
    mov dword [snd_t_f2], 880
    mov dword [snd_t_phase], 0
    mov dword [snd_t_done], 0
    mov dword [snd_t_start], 0
    mov eax, [snd_t_rate]
    mov [snd_t_switch], eax
    PRINTF `Playing 440 Hz, then 880 Hz at %d Hz (the card plays %d Hz)...\n`, eax, dword [snd_dev_rate]
    cmp byte [snd_t_mode], 1
    je .gap
    cmp byte [snd_t_mode], 2
    je .pause
    ; --- 1 s + 1 s
    mov eax, [snd_t_rate]
    add eax, eax
    mov [snd_t_end], eax
    call snd_t_feed
    jc .timeout
    mov eax, [snd_t_end]
    call snd_t_wait
    jc .timeout
    call snd_t_report
    jmp .close
.gap:
    ; --- 0.5 s, a 7 s gap, 0.5 s
    mov eax, [snd_t_rate]
    shr eax, 1
    mov [snd_t_end], eax
    mov [snd_t_switch], eax
    call snd_t_feed
    jc .timeout
    mov eax, [snd_t_end]
    call snd_t_wait
    jc .timeout
    call snd_played
    mov [snd_t_p1], eax
    mov ecx, 700                        ; nothing written, nothing asked
    call snd_sleep
    call snd_played
    mov [snd_t_p2], eax
    PRINTF `Before the gap %d frames played, after it %d.\n`, dword [snd_t_p1], eax
    mov eax, [snd_t_rate]
    shr eax, 1
    add [snd_t_end], eax
    call snd_t_feed
    jc .timeout
    call snd_played                     ; (the new sound went in ahead of
    mov ecx, [snd_t_rate]               ; the card: wait for half a second
    shr ecx, 1                          ; and the lead from now)
    add eax, ecx
    add eax, [snd_t_rate]
    call snd_t_wait
    jc .timeout
    call snd_t_report
    jmp .close
.pause:
    ; --- 1 s of 440 Hz with a pause of 1 s in the middle, 1 s of 880 Hz
    mov eax, [snd_t_rate]
    mov [snd_t_end], eax
    call snd_t_feed
    jc .timeout
    mov eax, [snd_t_rate]
    shr eax, 1
    call snd_t_wait
    jc .timeout
    call snd_pause
    call snd_played
    mov [snd_t_p1], eax
    mov ecx, 100
    call snd_sleep
    call snd_played
    mov [snd_t_p2], eax
    PRINTF `Paused at %d frames; a second later %d.\n`, dword [snd_t_p1], eax
    call snd_resume
    mov eax, [snd_t_rate]
    add eax, eax
    mov [snd_t_end], eax
    call snd_t_feed
    jc .timeout
    mov eax, [snd_t_end]
    call snd_t_wait
    jc .timeout
    call snd_t_report
    jmp .close
.reopen:
    ; --- eight streams of 0.25 s each, closed after half of it
    mov dword [snd_t_loop], 0
    mov dword [snd_t_start], 0
.again:
    mov eax, [snd_t_rate]
    mov ecx, 2
    call snd_open
    jc .badrate
    mov eax, [snd_t_loop]
    imul eax, 110
    add eax, 440
    mov [snd_t_f1], eax
    mov [snd_t_f2], eax
    mov dword [snd_t_phase], 0
    mov dword [snd_t_done], 0
    mov eax, [snd_t_rate]
    shr eax, 2
    mov [snd_t_end], eax
    mov [snd_t_switch], eax
    call snd_t_feed
    jc .timeout
    mov eax, [snd_t_end]
    shr eax, 1
    call snd_t_wait
    jc .timeout
    call snd_played
    PRINTF `Stream %d: %d Hz, closed after %d frames.\n`, dword [snd_t_loop], dword [snd_t_f1], eax
    call snd_close
    inc dword [snd_t_loop]
    cmp dword [snd_t_loop], 8
    jb .again
    jmp .close
.timeout:
    call snd_played
    PRINTF `\x01rThe card did not keep up\x01n (%d frames played).\n`, eax
.close:
    call snd_close
    popad
    ret
.badrate:
    PRINTF `That rate cannot be played (4000 to 192000 Hz).\n`
    popad
    ret
.nocard:
    PRINTF `No sound card MOOS can use was found (see "sound").\n`
    popad
    ret

; snd_t_report: print what was played and how long it took
snd_t_report:
    pushad
    call snd_played
    mov ebx, eax
    mov eax, [ticks]
    sub eax, [snd_t_start]
    xor edx, edx
    mov ecx, 100
    div ecx
    PRINTF `Done: %d frames played (%d written) in %d.%02d s.\n`, ebx, dword [snd_t_done], eax, edx
    popad
    ret

; snd_t_feed: write test tone frames snd_t_done up to snd_t_end, waiting
; for room -> CF=1 if the card did not take them in time (or Esc)
snd_t_feed:
    pushad
.more:
    mov ecx, [snd_t_end]
    sub ecx, [snd_t_done]
    jbe .done
    call snd_space
    test eax, eax
    jz .wait
    cmp ecx, eax
    jbe .n1
    mov ecx, eax
.n1:
    cmp ecx, SND_TCHUNK
    jbe .n2
    mov ecx, SND_TCHUNK
.n2:
    call snd_t_make
    mov esi, snd_tbuf
    call snd_write
    add [snd_t_done], eax
    mov ebx, ecx                        ; (the frames not taken are made
    sub ebx, eax                        ; again: wind the tone back)
    jz .taken
.back:
    mov edx, [snd_t_f1]
    call snd_t_inc
    sub [snd_t_phase], edx
    dec ebx
    jnz .back
.taken:
    cmp dword [snd_t_start], 0
    jne .more
    mov eax, [ticks]                    ; the card started
    mov [snd_t_start], eax
    jmp .more
.wait:
    call snd_t_check
    jc .fail
    hlt
    jmp .more
.done:
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

; snd_t_wait: EAX = frames -> waits until snd_played reaches them; CF=1 if
; it did not in time (or Esc)
snd_t_wait:
    push eax
    push ebx
    mov ebx, eax
.l: call snd_played
    cmp eax, ebx
    jae .done
    call snd_t_check
    jc .fail
    hlt
    jmp .l
.done:
    pop ebx
    pop eax
    clc
    ret
.fail:
    pop ebx
    pop eax
    stc
    ret

; snd_t_check: -> CF=1 if the test has run too long or Esc was pressed
snd_t_check:
    push eax
    mov eax, [ticks]
    sub eax, [snd_t_limit]
    jns .stop
    call kbd_poll
    cmp eax, 27
    je .stop
    pop eax
    clc
    ret
.stop:
    pop eax
    stc
    ret

; snd_t_inc: EDX = frequency -> EDX = phase step per frame at snd_t_rate
; (the phase is a 32-bit fraction of a turn)
snd_t_inc:
    push eax
    mov eax, 0
    div dword [snd_t_rate]              ; frequency * 2^32 / rate
    mov edx, eax
    pop eax
    ret

; snd_t_make: ECX = frames -> that much test tone in snd_tbuf (stereo),
; starting at frame snd_t_done (440 Hz before snd_t_switch, 880 after)
snd_t_make:
    pushad
    mov edi, snd_tbuf
    mov ebx, [snd_t_done]
.l: test ecx, ecx
    jz .done
    mov edx, [snd_t_f1]
    cmp ebx, [snd_t_switch]
    jb .f
    mov edx, [snd_t_f2]
.f: call snd_t_inc
    mov eax, [snd_t_phase]
    add [snd_t_phase], edx
    shr eax, 22                         ; 1024 steps a turn
    movzx eax, word [snd_sine + eax * 2]
    mov edx, eax
    shl edx, 16
    or eax, edx
    stosd
    inc ebx
    dec ecx
    jmp .l
.done:
    popad
    ret

; snd_make_sine: the sine table (1024 steps of a turn, at half volume)
snd_make_sine:
    cmp byte [snd_sine_ok], 0
    jne .r
    push ecx
    xor ecx, ecx
.l: mov [snd_tmp], ecx
    fild dword [snd_tmp]
    fmul qword [snd_k_2pi]
    fsin
    fmul dword [snd_k_amp]
    fistp word [snd_sine + ecx * 2]
    inc ecx
    cmp ecx, 1024
    jb .l
    mov byte [snd_sine_ok], 1
    pop ecx
.r: ret

; ========================================================================
;  64-bit: counting what the card played and making it silent
; ========================================================================
bits 64

; snd_sync_far64: snd_sync64 for the 32-bit kernel (through efi64)
snd_sync_far64:
    ENTER64
    call snd_sync64
    LEAVE64

; snd_sync64: called by snd_sync and, 100 times a second, by the firmware's
; timer (efi_tick). Reads where the card is, makes the frames it has
; played since the last look silent and counts them (snd_tick_cnt).
; Interrupts are off meanwhile, so the two never run at once. Uses only
; RAX, RCX, RDX and R8-R11 (as a firmware callback may) and keeps the
; flags.
snd_sync64:
    pushfq
    cli
    cmp byte [rel snd_tick_on], 0
    je .out
    call snd_pos64                      ; EAX = ring position, CF = stopped
    jnc .moving
    mov byte [rel snd_stopped], 1
.moving:
    mov edx, eax
    sub eax, [rel snd_tick_p]
    and eax, SND_RMASK                  ; EAX = frames played since
    jz .out
    mov ecx, [rel snd_tick_p]           ; ECX = the first of them
    mov [rel snd_tick_p], edx
    add [rel snd_tick_cnt], eax
    call snd_zero64
.out:
    popfq
    ret

; snd_pos64: -> EAX = the frame of the ring the card has got to, CF=1 if it
; has stopped. AC'97: also moves the last valid buffer to the one before
; the card's, so that it goes round and round.
snd_pos64:
    cmp byte [rel snd_card], SND_AC97
    je .ac97
    mov edx, [rel snd_sd]
    mov eax, [rdx + SD_LPIB]            ; bytes
    mov ecx, [rdx + SD_CTL]             ; (and SD_STS in the top byte)
    shr eax, 2
    and eax, SND_RMASK
    test cl, 2                          ; still running,
    jz .stopped
    test ecx, 1 << 28                   ; no descriptor error?
    jnz .stopped
    clc
    ret
.stopped:
    stc
    ret
.ac97:
    mov r8d, 4                          ; buffer and position: read the
.again:                                 ; buffer again to be sure they match
    mov edx, [rel snd_nabm]
    add edx, AC_PO_CIV
    in al, dx
    movzx r9d, al
    add edx, AC_PO_PICB - AC_PO_CIV
    in ax, dx
    movzx r10d, ax                      ; R10 = samples left in it
    sub edx, AC_PO_PICB - AC_PO_CIV
    in al, dx
    movzx eax, al
    cmp eax, r9d
    je .same
    dec r8d
    jnz .again
.same:
    and eax, SND_NBDL - 1
    mov r9d, eax
    lea ecx, [rax - 1]                  ; last valid = the one before
    and ecx, SND_NBDL - 1
    add edx, AC_PO_LVI - AC_PO_CIV
    mov al, cl
    out dx, al
    mov eax, SND_BUFF * 2
    cmp r10d, eax
    jbe .in
    mov r10d, eax
.in:
    sub eax, r10d
    shr eax, 1                          ; frames done in this buffer
    shl r9d, SND_BBITS
    add eax, r9d
    and eax, SND_RMASK
    add edx, AC_PO_SR - AC_PO_LVI
    mov r9d, eax
    in ax, dx
    test al, 1                          ; halted?
    mov eax, r9d
    jnz .stopped
    clc
    ret

; snd_zero64: ECX = ring slot, EAX = frames -> made silent (round the end of
; the ring if need be), and written out of the cache for the card
snd_zero64:
    push rdi
    mov r8d, eax                        ; R8 = frames left
    mov r9d, ecx                        ; R9 = slot
.part:
    mov ecx, SND_RING
    sub ecx, r9d
    cmp ecx, r8d
    jbe .n
    mov ecx, r8d
.n: sub r8d, ecx
    mov edi, [rel snd_buf]
    lea rdi, [rdi + r9 * 4]
    mov r11, rdi
    xor eax, eax
    cld
    rep stosd
    cmp byte [rel snd_clfl], 0
    je .next
    and r11, -SND_LINE
.fl:
    clflush [r11]
    add r11, SND_LINE
    cmp r11, rdi
    jb .fl
    mfence
.next:
    xor r9d, r9d
    test r8d, r8d
    jnz .part
    pop rdi
    ret

bits 32
