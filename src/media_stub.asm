; =============================================================================
;  media_stub.asm - STAND-INS, to be replaced
;
;  The browser's picture cache, video player and YouTube pages call the
;  H.264 / JPEG / PNG / GIF decoders. Until those modules are added, these
;  stand-ins let the kernel assemble: every one of them reports failure, so
;  pictures show their alt text and a video says it could not be loaded.
; =============================================================================
section .bss
alignb 4
section .text
H264F_Y     equ 0
H264F_U     equ 4
H264F_V     equ 8
H264F_YS    equ 12
H264F_CS    equ 16
H264F_W     equ 20
H264F_H     equ 24
H264F_POC   equ 28
h264_init:
h264_decode_avcc:
h264_decode_nal:
h264_flush:
png_info:
png_decode:
gif_info:
gif_decode:
jpeg_info:
jpeg_decode:
    mov eax, -1
    ret
h264_get_frame:
    xor eax, eax
    ret
h264_ctx_size:
h264_mem_size:
    mov eax, 4096
    ret
