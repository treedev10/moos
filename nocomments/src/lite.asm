section .bss
gui_capture resb 1
gui_active  resb 1
alignb 4
gfx_w       resd 1
gfx_h       resd 1
section .text

gui_log_char:
    ret

cmd_gui:
    PRINTF `The graphical desktop needs a UEFI PC (it draws on a graphics\nscreen). This computer started from a BIOS, so only the text\nconsole is available.\n`
    ret
