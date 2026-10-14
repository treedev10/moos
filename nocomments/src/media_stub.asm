section .bss
alignb 4
hs_status   resd 1
hs_clen     resd 1
hs_total    resd 1
url_range_start resd 1
url_range_end resd 1
url_method  resd 1
url_body    resd 1
url_body_len resd 1
url_body_type resd 1
url_headers resd 1
url_agent   resd 1
section .text
MP4S_OFF    equ 0
MP4S_SIZE   equ 4
MP4S_PTS    equ 8
MP4S_FLAGS  equ 12
MP4I_V_OK   equ 0
MP4I_V_W    equ 4
MP4I_V_H    equ 8
MP4I_V_SCALE equ 12
MP4I_V_DUR  equ 16
MP4I_V_AVCC equ 20
MP4I_V_AVCCLEN equ 24
MP4I_V_N    equ 28
MP4I_V_SAMP equ 32
MP4I_A_OK   equ 40
MP4I_A_SCALE equ 44
MP4I_A_DUR  equ 48
MP4I_A_ASC  equ 52
MP4I_A_ASCLEN equ 56
MP4I_A_N    equ 60
MP4I_A_SAMP equ 64
MP4I_SIZE   equ 128
H264F_Y     equ 0
H264F_U     equ 4
H264F_V     equ 8
H264F_YS    equ 12
H264F_CS    equ 16
H264F_W     equ 20
H264F_H     equ 24
H264F_POC   equ 28
hs_open:
    stc
    ret
hs_read:
    mov eax, -2
    ret
hs_close:
    ret
snd_init:
snd_open:
    stc
    ret
snd_space:
snd_write:
snd_played:
    xor eax, eax
    ret
snd_pause:
snd_resume:
snd_close:
snd_volume:
    ret
mp4_parse_moov:
mp4_find_sync:
h264_init:
h264_decode_avcc:
h264_decode_nal:
h264_flush:
aac_init:
aac_info:
aac_decode:
json_parse:
json_key:
json_index:
json_str:
png_info:
png_decode:
gif_info:
gif_decode:
jpeg_info:
jpeg_decode:
    mov eax, -1
    ret
h264_get_frame:
json_eq:
    xor eax, eax
    ret
h264_ctx_size:
h264_mem_size:
aac_ctx_size:
    mov eax, 4096
    ret
