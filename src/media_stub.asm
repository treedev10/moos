; =============================================================================
;  media_stub.asm - STAND-INS, to be replaced
;
;  The browser's picture cache calls the GIF decoder. Until that
;  module is added, these stand-ins let the kernel assemble: they
;  report failure, so pictures show their alt text (and a video its black
;  box instead of the poster).
; =============================================================================
section .text
gif_info:
gif_decode:
    mov eax, -1
    ret
