; =============================================================================
;  lite.asm - what the BIOS kernel has instead of the desktop
;
;  The graphical desktop, the browser and the media players need a UEFI PC
;  (a graphics screen through the firmware), so the kernel the boot sector
;  loads on BIOS PCs leaves them out and stays small: it must fit the 256 KB
;  reserved for it. These few names stand in for what the rest of the
;  system refers to.
; =============================================================================
section .bss
gui_capture resb 1                  ; (the desktop's terminal output capture)
gui_active  resb 1
alignb 4
gfx_w       resd 1                  ; (read by the firmware mouse code)
gfx_h       resd 1
section .text

; gui_log_char: never called (gui_capture stays 0)
gui_log_char:
    ret

cmd_gui:
    PRINTF `The graphical desktop needs a UEFI PC (it draws on a graphics\nscreen). This computer started from a BIOS, so only the text\nconsole is available.\n`
    ret
