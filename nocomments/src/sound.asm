SND_NONE    equ 0
SND_HDA     equ 1
SND_AC97    equ 2

SS_CLOSED   equ 0
SS_IDLE     equ 1

SS_RUN      equ 2
SS_PAUSED   equ 3

SND_RBITS   equ 18
SND_RING    equ 1 << SND_RBITS
SND_RMASK   equ SND_RING - 1
SND_NBDL    equ 32
SND_BBITS   equ SND_RBITS - 5
SND_BUFF    equ 1 << SND_BBITS
SND_FILL_MS equ 1000
SND_GUARD_MS equ 10
SND_LEAD_MS equ 20
SND_MAXCONN equ 32
SND_MAXOUT  equ 4
SND_MAXHOP  equ 5
SND_MAXSEEN equ 4
SND_LINE    equ 64
SND_TCHUNK  equ 1024

R_OK        equ 0
R_NODRIVER  equ 1
R_BAR       equ 2
R_RESET     equ 3
R_NOCODEC   equ 4
R_NOOUT     equ 5
R_NOSTREAM  equ 6

SND_CORB    equ 0x000
SND_RIRB    equ 0x400
SND_BDL     equ 0xC00

HDA_GCAP      equ 0x00
HDA_VMIN      equ 0x02
HDA_VMAJ      equ 0x03
HDA_GCTL      equ 0x08
HDA_STATESTS  equ 0x0E
HDA_INTCTL    equ 0x20
HDA_CORBLBASE equ 0x40
HDA_CORBUBASE equ 0x44
HDA_CORBWP    equ 0x48
HDA_CORBRP    equ 0x4A
HDA_CORBCTL   equ 0x4C
HDA_CORBSIZE  equ 0x4E
HDA_RIRBLBASE equ 0x50
HDA_RIRBUBASE equ 0x54
HDA_RIRBWP    equ 0x58
HDA_RINTCNT   equ 0x5A
HDA_RIRBCTL   equ 0x5C
HDA_RIRBSTS   equ 0x5D
HDA_RIRBSIZE  equ 0x5E
HDA_ICOI      equ 0x60
HDA_ICII      equ 0x64
HDA_ICIS      equ 0x68
HDA_SD0       equ 0x80
SD_CTL        equ 0x00
SD_STS        equ 0x03
SD_LPIB       equ 0x04
SD_CBL        equ 0x08
SD_LVI        equ 0x0C
SD_FMT        equ 0x12
SD_BDPL       equ 0x18
SD_BDPU       equ 0x1C

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
P_VENDOR    equ 0x00
P_REVISION  equ 0x02
P_NODES     equ 0x04
P_FGTYPE    equ 0x05
P_WCAPS     equ 0x09
P_PCM       equ 0x0A
P_PINCAPS   equ 0x0C
P_INAMP     equ 0x0D
P_CONNLEN   equ 0x0E
P_OUTAMP    equ 0x12
W_DAC       equ 0
W_MIXER     equ 2
W_SEL       equ 3
W_PIN       equ 4
WC_INAMP    equ 1 << 1
WC_OUTAMP   equ 1 << 2
WC_AMPOVR   equ 1 << 3
WC_FMTOVR   equ 1 << 4
WC_CONN     equ 1 << 8
WC_DIGITAL  equ 1 << 9
WC_POWER    equ 1 << 10
WC_EXISTS   equ 1 << 31
PC_HP       equ 1 << 3
PC_OUT      equ 1 << 4
PC_HDMI     equ 1 << 7
PC_EAPD     equ 1 << 16
PC_DP       equ 1 << 24
HDA_AMP_OUT equ 0x8000
HDA_AMP_IN  equ 0x4000
HDA_TAG     equ 1
PCM_44K     equ 1 << 5
PCM_48K     equ 1 << 6

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
AC_PO_BDBAR  equ 0x10
AC_PO_CIV    equ 0x14
AC_PO_LVI    equ 0x15
AC_PO_SR     equ 0x16
AC_PO_PICB   equ 0x18
AC_PO_CR     equ 0x1B
AC_GLOB_CNT  equ 0x2C
AC_GLOB_STA  equ 0x30

section .data
snd_vol     dd 80

snd_s_test   db "test", 0
snd_s_volume db "volume", 0
snd_s_reset  db "reset", 0
snd_s_codec  db "codec", 0
snd_s_status db "status", 0
snd_s_pio    db "pio", 0
snd_s_gap    db "gap", 0
snd_s_pause  db "pause", 0
snd_s_reopen db "reopen", 0

snd_k_2pi   dq 0.0061359231515425649
snd_k_amp   dd 16384.0

snd_ac97_ids:
    dd 0x24158086, 0x24258086, 0x24458086, 0x24858086
    dd 0x24C58086, 0x24D58086, 0x25A68086, 0x266E8086
    dd 0x27DE8086, 0x71958086
    dd 0x74451022, 0x746D1022
    dd 0x01B110DE, 0x006A10DE, 0x00DA10DE, 0x00EA10DE
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
snd_vendors:
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
snd_ready     resb 1
snd_tried     resb 1
snd_card      resb 1
snd_state     resb 1
snd_imm       resb 1
snd_force_imm resb 1
snd_clfl      resb 1
snd_tick_on   resb 1
snd_stopped   resb 1
snd_vra       resb 1
snd_sw        resb 1
snd_sine_ok   resb 1
snd_cl_long   resb 1
snd_t_mode    resb 1
alignb 4
snd_swvol     resd 1
snd_pci       resd 1
snd_vendev    resd 1
snd_mmio      resd 1
snd_nam       resd 1
snd_nabm      resd 1
snd_ctl       resd 1
snd_buf       resd 1
snd_buf_end   resd 1
snd_sd        resd 1
snd_gcap      resd 1
snd_codecs    resd 1
snd_corb_mask resd 1
snd_rirb_mask resd 1
snd_rirb_rp   resd 1
snd_cad       resd 1
snd_cadn      resd 1
snd_codec_id  resd 1
snd_codec_rev resd 1
snd_afg       resd 1
snd_afg_pcm   resd 1
snd_afg_oamp  resd 1
snd_afg_iamp  resd 1
snd_wfirst    resd 1
snd_wcount    resd 1
snd_rates     resd 1
snd_fmt       resd 1
snd_nout      resd 1
snd_opin      resd SND_MAXOUT
snd_odac      resd SND_MAXOUT
snd_onhop     resd SND_MAXOUT
snd_ohop      resb SND_MAXOUT * 16
snd_ovol_nid  resd SND_MAXOUT
snd_ovol_amp  resd SND_MAXOUT
snd_ovol_caps resd SND_MAXOUT
snd_fmax      resd 1
snd_fhops     resd 1
snd_fhop      resb 16
snd_cl_prev   resd 1
snd_cl_resp   resd 1
snd_until     resd 1
snd_wcaps     resd 128
snd_pcaps     resd 128
snd_pcfg      resd 128
snd_nconn     resb 128
snd_conn      resb 128 * SND_MAXCONN
snd_ac_vid    resd 1
snd_ac_ext    resd 1
snd_ac_max    resd 1
snd_nseen     resd 1
snd_seen_pci  resd SND_MAXSEEN
snd_seen_ids  resd SND_MAXSEEN
snd_seen_cls  resd SND_MAXSEEN
snd_seen_res  resd SND_MAXSEEN

snd_rate      resd 1
snd_chans     resd 1
snd_stride    resd 1
snd_dev_rate  resd 1
snd_step_i    resd 1
snd_step_f    resd 1
snd_frac      resd 1
snd_need      resd 1
snd_prevl     resd 1
snd_prevr     resd 1
snd_curl      resd 1
snd_curr      resd 1
snd_base      resd 1
snd_hw        resd 1
snd_wr        resd 1
snd_tick_p    resd 1
snd_tick_cnt  resd 1
snd_lead      resd 1
snd_guard     resd 1
snd_maxfill   resd 1
snd_p_n       resd 1
snd_p_in      resd 1
snd_p_r       resd 1
snd_p_room    resd 1
snd_tmp       resd 1

snd_t_rate    resd 1
snd_t_done    resd 1
snd_t_end     resd 1
snd_t_switch  resd 1
snd_t_f1      resd 1
snd_t_f2      resd 1
snd_t_phase   resd 1
snd_t_start   resd 1
snd_t_limit   resd 1
snd_t_p1      resd 1
snd_t_p2      resd 1
snd_t_loop    resd 1
snd_sine      resw 1024
snd_tbuf      resd SND_TCHUNK
section .text

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
    mov eax, 1
    cpuid
    shr edx, 19
    and dl, 1
    mov [snd_clfl], dl
    cmp dword [snd_ctl], 0
    jne .have_ctl
    mov ecx, 4096
    mov edx, OWN_SOUND
    call big_alloc
    test eax, eax
    jz .fail
    mov [snd_ctl], eax
    mov edi, eax
    mov ecx, 4096
    call snd_flush_bytes
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
    call snd_pick_rate
    call snd_hw_format
    mov [snd_dev_rate], eax

    mov eax, [snd_rate]
    xor edx, edx
    div dword [snd_dev_rate]
    mov [snd_step_i], eax
    xor eax, eax
    div dword [snd_dev_rate]
    mov [snd_step_f], eax
    mov dword [snd_need], 2
    xor eax, eax
    mov [snd_frac], eax
    mov [snd_prevl], eax
    mov [snd_prevr], eax
    mov [snd_curl], eax
    mov [snd_curr], eax
    mov [snd_base], eax
    mov [snd_hw], eax
    mov [snd_wr], eax
    mov [snd_tick_p], eax
    mov [snd_tick_cnt], eax
    mov [snd_stopped], al
    mov eax, SND_LEAD_MS
    call snd_ms_frames
    mov [snd_lead], eax
    mov eax, SND_GUARD_MS
    call snd_ms_frames
    mov [snd_guard], eax
    mov eax, SND_FILL_MS
    call snd_ms_frames
    mov [snd_maxfill], eax
    xor eax, eax
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

snd_ms_frames:
    push ecx
    push edx
    mul dword [snd_dev_rate]
    mov ecx, 1000
    div ecx
    pop edx
    pop ecx
    ret

snd_space:
    xor eax, eax
    cmp byte [snd_state], SS_CLOSED
    je .out
    push ecx
    push edx
    call snd_update
    call snd_room
    mov ecx, [snd_rate]
    cmp ecx, [snd_dev_rate]
    je .same

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

snd_write:
    pushad
    mov dword [esp + 28], 0
    cmp byte [snd_state], SS_CLOSED
    je .done
    test ecx, ecx
    jz .done
    call snd_update
    call snd_room
    test eax, eax
    jz .done
    mov edx, eax
    mov edi, [snd_wr]
    sub edi, [snd_base]
    and edi, SND_RMASK
    call snd_put
    mov [esp + 28], eax
    mov eax, edi
    call snd_flush_ring
    add [snd_wr], ecx
    cmp byte [snd_state], SS_IDLE
    jne .done
    test ecx, ecx
    jz .done
    call snd_restart
.done:
    popad
    ret

snd_played:
    push ecx
    push edx
    call snd_update
    mov eax, [snd_hw]
    mov ecx, [snd_dev_rate]
    cmp ecx, [snd_rate]
    je .done
    mul dword [snd_rate]
    push ebx
    mov ebx, eax
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

snd_resume:
    cmp byte [snd_state], SS_PAUSED
    jne .done
    push eax
    mov eax, [snd_wr]
    sub eax, [snd_hw]
    test eax, eax
    jle .empty
    call snd_restart
    pop eax
.done:
    ret
.empty:
    mov eax, [snd_hw]
    mov [snd_wr], eax
    mov [snd_base], eax
    mov byte [snd_state], SS_IDLE
    pop eax
    ret

snd_close:
    cmp byte [snd_state], SS_CLOSED
    je .done
    call snd_halt
    mov byte [snd_state], SS_CLOSED
.done:
    ret

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

snd_sync:
    push eax
    mov eax, snd_sync_far64
    call efi64
    pop eax
    ret

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
    call snd_halt
    call snd_restart
.done:
    pop eax
    ret

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

snd_room:
    push ecx
    mov eax, [snd_wr]
    sub eax, [snd_hw]
    cmp byte [snd_state], SS_RUN
    jne .stopped
    cmp eax, [snd_guard]
    jge .placed
    mov eax, [snd_lead]
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

snd_restart:
    pushad
    mov ecx, [snd_wr]
    sub ecx, [snd_hw]
    test ecx, ecx
    jg .move
    mov eax, [snd_hw]
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
    add edi, [snd_buf]
    mov eax, [snd_rate]
    cmp eax, [snd_dev_rate]
    jne .convert
    cmp dword [snd_chans], 2
    jne .copy
    cmp dword [snd_swvol], 32768
    jne .copy
.fast:
    mov ecx, [snd_p_in]
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
.copy:
    cmp dword [snd_p_in], 0
    je .end
    cmp dword [snd_p_room], 0
    je .end
    call snd_get
    add esi, [snd_stride]
    call snd_store
    dec dword [snd_p_in]
    dec dword [snd_p_room]
    jmp .copy
.convert:

    cmp dword [snd_need], 0
    je .emit
    cmp dword [snd_p_in], 0
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
    cmp dword [snd_p_room], 0
    je .end
    mov ebx, [snd_frac]
    shr ebx, 17
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
    mov eax, [snd_step_f]
    add [snd_frac], eax
    mov eax, [snd_step_i]
    adc eax, 0
    mov [snd_need], eax
    jmp .convert
.end:
    mov eax, [snd_p_n]
    sub eax, [snd_p_in]
    mov ecx, [snd_p_r]
    sub ecx, [snd_p_room]
    pop ebp
    pop edi
    pop esi
    pop edx
    pop ebx
    ret

snd_get:
    movsx eax, word [esi]
    cmp dword [snd_chans], 1
    je .mono
    movsx ebp, word [esi + 2]
    ret
.mono:
    mov ebp, eax
    ret

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

snd_flush_bytes:
    cmp byte [snd_clfl], 0
    je .r
    test ecx, ecx
    jz .r
    push eax
    push ecx
    add ecx, edi
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

snd_flush_ring:
    pushad
    mov edx, eax
    and edx, SND_RMASK
    mov ebx, ecx
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
    shl ecx, 2
    call snd_flush_bytes
    xor edx, edx
    jmp .part
.done:
    popad
    ret

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

snd_ring_rotate:
    pushad
    and eax, SND_RMASK
    jz .done
    mov ebx, eax
    mov edx, ecx
    lea eax, [ebx + edx]
    cmp eax, SND_RING
    ja .wraps

    mov esi, [snd_buf]
    lea esi, [esi + ebx * 4]
    mov edi, [snd_buf]
    mov ecx, edx
    rep movsd
    mov eax, ebx
    cmp eax, edx
    jae .z
    mov eax, edx
.z: lea ecx, [ebx + edx]
    sub ecx, eax
    call snd_ring_zero
    jmp .flush
.wraps:

    mov ebp, SND_RING
    sub ebp, ebx
    mov ecx, edx
    sub ecx, ebp
    mov esi, [snd_buf]
    lea esi, [esi + ecx * 4 - 4]
    mov edi, [snd_buf]
    lea edi, [edi + edx * 4 - 4]
    std
    rep movsd
    cld
    mov esi, [snd_buf]
    lea esi, [esi + ebx * 4]
    mov edi, [snd_buf]
    mov ecx, ebp
    rep movsd
    mov eax, ebx
    mov ecx, ebp
    call snd_ring_zero
.flush:
    xor eax, eax
    mov ecx, edx
    call snd_flush_ring
.done:
    popad
    ret

snd_hw_start:
    cmp byte [snd_card], SND_AC97
    je ac97_start
    jmp hda_start

snd_hw_stop:
    cmp byte [snd_card], SND_AC97
    je ac97_stop
    jmp hda_stop

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

snd_hw_format:
    cmp byte [snd_card], SND_AC97
    je ac97_format
    jmp hda_format

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
    inc ebx
    call snd_amp_unity
    mov eax, 100
    sub eax, [snd_vol]
    add eax, eax
    mov edx, ebx
    shr edx, 1
    add eax, edx
    xor edx, edx
    div ebx
    mov edx, ecx
    sub edx, eax
    jns .done
    xor edx, edx
.done:
    pop ecx
    pop ebx
    pop eax
    ret

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

snd_find:
    pushad
    mov ebx, -1
.scan:
    call pci_next
    jc .none
    mov ecx, eax
    mov al, 0x08
    call pci_read32
    shr eax, 16
    cmp ah, 0x04
    jne .scan
    movzx edx, al
    mov esi, [snd_nseen]
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
    mov edi, snd_ac97_ids
.id:
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

snd_pci_d0:
    pushad
    mov al, 0x04
    call pci_read32
    test eax, 1 << 20
    jz .done
    mov al, 0x34
    call pci_read32
    movzx edx, al
    mov ecx, 48
.next:
    and edx, 0xFC
    jz .done
    mov al, dl
    call pci_read32
    cmp al, 0x01
    je .pm
    movzx edx, ah
    loop .next
    jmp .done
.pm:
    lea eax, [edx + 4]
    call pci_read32
    test al, 3
    jz .done
    and eax, 0xFFFF7FFC
    mov ecx, eax
    lea eax, [edx + 4]
    call pci_write32
    mov ecx, 2
    call snd_sleep
.done:
    popad
    ret

snd_pci_on:
    pushad
    call pci_enable
    mov al, 0x04
    call pci_read32
    and eax, 0xFFFF
    or eax, 1 << 10
    mov ecx, eax
    mov al, 0x04
    call pci_write32
    popad
    ret

snd_timer:
    push eax
    mov eax, [ticks]
    lea eax, [eax + ecx + 1]
    mov [snd_until], eax
    pop eax
    ret

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

snd_sleep:
    call snd_timer
.w: call snd_late
    jc .r
    hlt
    jmp .w
.r: ret

hda_init:
    pushad
    mov al, 0x10
    call pci_mmio_bar
    mov byte [esp + 28], R_BAR
    jc .fail
    mov [snd_mmio], eax
    call snd_pci_on
    cmp word [snd_vendev], 0x8086
    jne .tc
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
    and ecx, 15
    mov byte [esp + 28], R_NOSTREAM
    jz .fail
    shr eax, 8
    and eax, 15
    shl eax, 5
    lea eax, [esi + eax + HDA_SD0]
    mov [snd_sd], eax

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
    mov [esp + 28], al
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

hda_reset:
    pushad
    mov esi, [snd_mmio]
    mov byte [esi + HDA_CORBCTL], 0
    mov byte [esi + HDA_RIRBCTL], 0
    movzx ecx, word [esi + HDA_GCAP]
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
    and dword [esi + HDA_GCTL], ~1
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
    or dword [esi + HDA_GCTL], 1
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
    mov [esi + HDA_STATESTS], ax
    mov dword [esi + HDA_INTCTL], 0
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

hda_rings:
    pushad
    mov esi, [snd_mmio]
    mov edi, [snd_ctl]
    mov byte [snd_imm], 1
    cmp byte [snd_force_imm], 0
    jne .done
    mov byte [snd_imm], 0
    call hda_rings_off

    lea ebx, [esi + HDA_CORBSIZE]
    call hda_ring_size
    mov [snd_corb_mask], eax
    lea eax, [edi + SND_CORB]
    mov [esi + HDA_CORBLBASE], eax
    mov dword [esi + HDA_CORBUBASE], 0
    mov word [esi + HDA_CORBRP], 0x8000
    mov ecx, 1
    call snd_timer
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

    lea ebx, [esi + HDA_RIRBSIZE]
    call hda_ring_size
    mov [snd_rirb_mask], eax
    lea eax, [edi + SND_RIRB]
    mov [esi + HDA_RIRBLBASE], eax
    mov dword [esi + HDA_RIRBUBASE], 0
    mov word [esi + HDA_RIRBWP], 0x8000
    mov word [esi + HDA_RINTCNT], 1
    mov dword [snd_rirb_rp], 0
    mov byte [esi + HDA_RIRBSTS], 0x05

    mov byte [esi + HDA_CORBCTL], 2
    mov byte [esi + HDA_RIRBCTL], 3
.done:
    popad
    ret

hda_ring_size:
    push ecx
    movzx ecx, byte [ebx]
    mov eax, ecx
    and cl, 0xF0
    test al, 0x40
    jnz .s256
    test al, 0x20
    jnz .s16
    test al, 0x10
    jnz .s2
.s256:
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
    mov [esi + HDA_CORBWP], cx
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
    clflush [edx]
    mfence
.read:
    mov eax, [edx]
    test byte [edx + 4], 0x10
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

hda_imm_cmd:
    push ecx
    push esi
    mov esi, [snd_mmio]
    mov ecx, 3
    call snd_timer
.idle:
    test word [esi + HDA_ICIS], 1
    jz .send
    call snd_late
    jc .none
    pause
    jmp .idle
.send:
    mov word [esi + HDA_ICIS], 2
    mov [esi + HDA_ICOI], eax
    mov word [esi + HDA_ICIS], 1
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

hda_param:
    movzx eax, al
    or eax, V_GETPARAM << 8
    jmp hda_cmd

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
    test al, 0xF0
    jz .done
    call snd_late
    jc .done
    pause
    jmp .w
.done:
    pop ecx
    pop eax
    ret

hda_codec:
    pushad
    mov edi, snd_wcaps
    mov ecx, 128
    xor eax, eax
    rep stosd
    mov edi, snd_nconn
    mov ecx, 128
    rep stosb
    mov byte [esp + 28], R_NOCODEC
    xor ebx, ebx
    mov al, P_VENDOR
    call hda_param
    jc .fail
    mov [snd_codec_id], eax
    lea ecx, [eax + 1]
    cmp ecx, 1
    jbe .fail
    mov al, P_REVISION
    call hda_param
    mov [snd_codec_rev], eax
    mov al, P_NODES
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
    cmp al, 1
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
    mov al, P_NODES
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

hda_read_conns:
    pushad
    mov byte [snd_nconn + ebx], 0
    mov al, P_CONNLEN
    call hda_param
    jc .fail
    mov edx, eax
    and edx, 0x7F
    test al, 0x80
    setnz byte [snd_cl_long]
    xor esi, esi
    mov dword [snd_cl_prev], 0
.entry:
    cmp esi, edx
    jae .done
    mov ecx, 3
    cmp byte [snd_cl_long], 0
    je .per
    mov ecx, 1
.per:
    test esi, ecx
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
    and edi, 0x7F
    test al, 0x80
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
    mov eax, [snd_cl_prev]
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
.add:
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

hda_outputs:
    pushad
    mov dword [snd_nout], 0
    xor edx, edx
.kind:
    mov ebx, 1
.pin:
    call hda_out_ok
    jc .nextpin
    mov eax, [snd_pcfg + ebx * 4]
    shr eax, 30
    cmp eax, 1
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
    cmp edx, 2
    jbe .kind
    cmp dword [snd_nout], 0
    jne .found
    mov ebx, 1
.any:
    call hda_out_ok
    jc .nextany
    mov eax, [snd_pcfg + ebx * 4]
    shr eax, 20
    and eax, 15
    cmp eax, 4
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

hda_dfs:
    push eax
    push ebx
    push esi
    push edi
    xor esi, esi
.l: movzx eax, byte [snd_nconn + ebx]
    cmp esi, eax
    jae .no
    mov edi, ebx
    shl edi, 5
    movzx edi, byte [snd_conn + edi + esi]
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

hda_setup:
    pushad
    xor ebp, ebp
.output:
    cmp ebp, [snd_nout]
    jae .done
    mov dword [snd_ovol_nid + ebp * 4], 0
    mov esi, ebp
    shl esi, 4
    add esi, snd_ohop
    xor edi, edi
.step:
    cmp edi, [snd_onhop + ebp * 4]
    jae .dac
    movzx ebx, byte [esi + edi * 2]
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
    cmp byte [snd_nconn + ebx], 1
    jbe .amps
    mov eax, edx
    or eax, V_SETSEL << 8
    call hda_cmd
    test dword [snd_wcaps + ebx * 4], WC_INAMP
    jz .amps
    mov ecx, 1
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
    mov eax, (V_SETSTREAM << 8) | (HDA_TAG << 4)
    call hda_cmd
    call hda_pick_volume
    inc ebp
    jmp .output
.done:
    popad
    ret

hda_wake:
    test dword [snd_wcaps + ebx * 4], WC_POWER
    jz .r
    call hda_power_d0
.r: ret

hda_pin_on:
    push eax
    push ecx
    mov ecx, 0x40
    test dword [snd_pcaps + ebx * 4], PC_HP
    jz .ctl
    mov eax, [snd_pcfg + ebx * 4]
    shr eax, 20
    and eax, 15
    cmp eax, 2
    jne .ctl
    or ecx, 0x80
.ctl:
    mov eax, ecx
    or eax, V_SETPIN << 8
    call hda_cmd
    test dword [snd_pcaps + ebx * 4], PC_EAPD
    jz .done
    mov eax, V_GETEAPD << 8
    call hda_cmd
    and eax, 0x07
    or eax, 0x02
    or eax, V_SETEAPD << 8
    call hda_cmd
.done:
    pop ecx
    pop eax
    ret

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
    mov eax, edx
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

hda_amp_set:
    push eax
    or eax, 0x3000
    or eax, edx
    or eax, V_SETAMP4 << 16
    call hda_cmd
    pop eax
    ret

hda_amp_unity_set:
    pushad
    call hda_amp_caps
    push ecx
    call snd_amp_unity
    mov eax, ecx
    pop ecx
    xchg eax, edx
    shl eax, 8
    or eax, HDA_AMP_OUT
    test ecx, ecx
    jz .set
    xor eax, HDA_AMP_OUT | HDA_AMP_IN
.set:
    call hda_amp_set
    popad
    ret

hda_pick_volume:
    pushad
    mov ebx, [snd_odac + ebp * 4]
    xor ecx, ecx
    mov eax, HDA_AMP_OUT
    call .try
    jnc .done
    mov edi, [snd_onhop + ebp * 4]
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
    movzx eax, byte [esi + edi * 2 + 1]
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
.try:
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
    call snd_amp_unity
    mov eax, edx
    shr eax, 16
    and eax, 0x7F
    inc eax
    imul ecx, eax
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

hda_format:
    push eax
    push ebx
    push ecx
    mov ecx, 0x0011
    cmp eax, 44100
    jne .f
    or ecx, 0x4000
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

hda_start:
    pushad
    mov esi, [snd_sd]
    mov byte [esi + SD_CTL], 1
    mov ecx, 2
    call snd_timer
.r1:
    test byte [esi + SD_CTL], 1
    jnz .r0
    call snd_late
    jnc .r1
.r0:
    mov byte [esi + SD_CTL], 0
    mov ecx, 2
    call snd_timer
.r2:
    test byte [esi + SD_CTL], 1
    jz .reset
    call snd_late
    jnc .r2
.reset:
    mov dword [esi + SD_CTL], HDA_TAG << 20
    mov byte [esi + SD_STS], 0x1C
    mov edi, [snd_ctl]
    add edi, SND_BDL
    mov eax, [snd_buf]
    mov ecx, SND_NBDL
    push edi
.bdl:
    mov [edi], eax
    mov dword [edi + 4], 0
    mov dword [edi + 8], SND_BUFF * 4
    mov dword [edi + 12], 0
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
    mov dword [esi + SD_CTL], (HDA_TAG << 20) | 2
    popad
    ret

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

ac97_init:
    pushad
    mov byte [esp + 28], R_BAR
    mov al, 0x10
    call pci_read32
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
    call snd_pci_on
    cmp word [snd_vendev], 0x8086
    jne .io
    mov al, 0x18
    call pci_read32
    test al, 1
    jnz .io
    test eax, eax
    jz .io
    mov al, 0x40
    call pci_read32
    or eax, 1 << 8
    mov ecx, eax
    mov al, 0x40
    call pci_write32
.io:
    mov edx, [snd_nabm]
    add edx, AC_PO_CR
    mov al, 0
    out dx, al

    mov byte [esp + 28], R_NOCODEC
    mov edx, [snd_nabm]
    add edx, AC_GLOB_CNT
    in eax, dx
    and eax, ~7
    out dx, eax
    mov ecx, 2
    call snd_sleep
    or eax, 2
    out dx, eax
    mov edx, [snd_nabm]
    add edx, AC_GLOB_STA
    mov ecx, 100
    call snd_timer
.ready:
    in eax, dx
    test eax, 1 << 8
    jnz .codec
    call snd_late
    jc .fail
    hlt
    jmp .ready
.codec:
    mov edx, [snd_nam]
    mov ax, 0
    out dx, ax
    mov ecx, 1
    call snd_sleep
    add edx, AC_POWERDOWN
    out dx, ax
    mov ecx, 100
    call snd_timer
.power:
    in ax, dx
    and ax, 0x0E
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
    add edx, AC_EXTCTL - AC_EXTID
    in ax, dx
    or ax, 1
    out dx, ax
.rates:
    mov edx, [snd_nam]
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
    mov ax, 0x0808
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
    mov eax, 48000
    mov edx, [snd_nam]
    add edx, AC_FRONTRATE
    out dx, ax
    jmp .done
.fixed:
    mov eax, 48000
.done:
    pop edx
    ret

ac97_volume:
    pushad
    mov eax, 0x8000
    cmp dword [snd_vol], 0
    je .set
    mov eax, 100
    sub eax, [snd_vol]
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

ac97_start:
    pushad
    mov edx, [snd_nabm]
    add edx, AC_PO_CR
    mov al, 2
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
    mov [edi], eax
    mov dword [edi + 4], (1 << 30) | (SND_BUFF * 2)
    add eax, SND_BUFF * 4
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
    mov ax, 0x1C
    out dx, ax
    add edx, AC_PO_CR - AC_PO_SR
    mov al, 1
    out dx, al
    popad
    ret

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
    test al, 1
    jnz .done
    call snd_late
    jnc .w
.done:
    popad
    ret

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
    call snd_close
    mov byte [snd_force_imm], 0
    cmp dword [argc], 3
    jb .again
    mov esi, [argv + 8]
    mov edi, snd_s_pio
    call str_icmp
    jne .again
    mov byte [snd_force_imm], 1
.again:
    mov byte [snd_ready], 0
    mov byte [snd_tried], 0
    jmp snd_status

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

snd_node_print:
    pushad
    mov eax, [snd_wcaps + ebx * 4]
    shr eax, 20
    and eax, 15
    mov esi, [snd_types + eax * 4]
    PRINTF `%s %d`, esi, ebx
    popad
    ret

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

snd_test:
    pushad
    mov dword [snd_t_rate], 44100
    mov byte [snd_t_mode], 0
    mov ebx, 2
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
    mov eax, [ticks]
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
    mov ecx, 700
    call snd_sleep
    call snd_played
    mov [snd_t_p2], eax
    PRINTF `Before the gap %d frames played, after it %d.\n`, dword [snd_t_p1], eax
    mov eax, [snd_t_rate]
    shr eax, 1
    add [snd_t_end], eax
    call snd_t_feed
    jc .timeout
    call snd_played
    mov ecx, [snd_t_rate]
    shr ecx, 1
    add eax, ecx
    add eax, [snd_t_rate]
    call snd_t_wait
    jc .timeout
    call snd_t_report
    jmp .close
.pause:

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
    mov ecx, 25
    call snd_sleep
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
    mov ebx, ecx
    sub ebx, eax
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
    mov eax, [ticks]
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

snd_t_inc:
    push eax
    mov eax, 0
    div dword [snd_t_rate]
    mov edx, eax
    pop eax
    ret

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
    shr eax, 22
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

bits 64

snd_sync_far64:
    ENTER64
    call snd_sync64
    LEAVE64

snd_sync64:
    pushfq
    cli
    cmp byte [rel snd_tick_on], 0
    je .out
    call snd_pos64
    jnc .moving
    mov byte [rel snd_stopped], 1
.moving:
    mov edx, eax
    sub eax, [rel snd_tick_p]
    and eax, SND_RMASK
    jz .out
    mov ecx, [rel snd_tick_p]
    mov [rel snd_tick_p], edx
    add [rel snd_tick_cnt], eax
    call snd_zero64
.out:
    popfq
    ret

snd_pos64:
    cmp byte [rel snd_card], SND_AC97
    je .ac97
    mov edx, [rel snd_sd]
    mov eax, [rdx + SD_LPIB]
    mov ecx, [rdx + SD_CTL]
    shr eax, 2
    and eax, SND_RMASK
    test cl, 2
    jz .stopped
    test ecx, 1 << 28
    jnz .stopped
    clc
    ret
.stopped:
    stc
    ret
.ac97:
    mov r8d, 4
.again:
    mov edx, [rel snd_nabm]
    add edx, AC_PO_CIV
    in al, dx
    movzx r9d, al
    add edx, AC_PO_PICB - AC_PO_CIV
    in ax, dx
    movzx r10d, ax
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
    lea ecx, [rax - 1]
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
    shr eax, 1
    shl r9d, SND_BBITS
    add eax, r9d
    and eax, SND_RMASK
    add edx, AC_PO_SR - AC_PO_LVI
    mov r9d, eax
    in ax, dx
    test al, 1
    mov eax, r9d
    jnz .stopped
    clc
    ret

snd_zero64:
    push rdi
    mov r8d, eax
    mov r9d, ecx
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
