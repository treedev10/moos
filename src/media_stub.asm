; =============================================================================
;  media_stub.asm - STAND-INS, to be replaced
;
;  The browser's picture cache calls the PNG / GIF decoders. Until those
;  modules are added, these stand-ins let the kernel assemble: they
;  report failure, so pictures show their alt text (and a video its black
;  box instead of the poster).
; =============================================================================
section .text
png_info:
png_decode:
gif_info:
gif_decode:
    mov eax, -1
    ret
