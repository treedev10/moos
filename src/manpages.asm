; =============================================================================
;  manpages.asm - the manual pages, embedded from the man/ folder
;  Each page is a plain text file. Lines starting with a capital letter are
;  shown as headings. Edit the .txt files and rebuild to change a manual.
; =============================================================================
section .data

%macro MANPAGE 2
%1: incbin %2
    db 0
%endmacro

MANPAGE man_intro,    "man/intro.txt"
MANPAGE man_keys,     "man/keys.txt"
MANPAGE man_files,    "man/files.txt"
MANPAGE man_install,  "man/install.txt"
MANPAGE man_edit,     "man/edit.txt"
MANPAGE man_help,     "man/help.txt"
MANPAGE man_man,      "man/man.txt"
MANPAGE man_ls,       "man/ls.txt"
MANPAGE man_cat,      "man/cat.txt"
MANPAGE man_write,    "man/write.txt"
MANPAGE man_append,   "man/append.txt"
MANPAGE man_rm,       "man/rm.txt"
MANPAGE man_rename,   "man/rename.txt"
MANPAGE man_copy,     "man/copy.txt"
MANPAGE man_find,     "man/find.txt"
MANPAGE man_wc,       "man/wc.txt"
MANPAGE man_hexdump,  "man/hexdump.txt"
MANPAGE man_echo,     "man/echo.txt"
MANPAGE man_calc,     "man/calc.txt"
MANPAGE man_clear,    "man/clear.txt"
MANPAGE man_color,    "man/color.txt"
MANPAGE man_time,     "man/time.txt"
MANPAGE man_clock,    "man/clock.txt"
MANPAGE man_net,      "man/net.txt"
MANPAGE man_apt,      "man/apt.txt"
MANPAGE man_get,      "man/get.txt"
MANPAGE man_script,   "man/script.txt"
MANPAGE man_gui,      "man/gui.txt"
MANPAGE man_browser,  "man/browser.txt"
MANPAGE man_uptime,   "man/uptime.txt"
MANPAGE man_mem,      "man/mem.txt"
MANPAGE man_sysinfo,  "man/sysinfo.txt"
MANPAGE man_fetch,    "man/fetch.txt"
MANPAGE man_history,  "man/history.txt"
MANPAGE man_login,    "man/login.txt"
MANPAGE man_format,   "man/format.txt"
MANPAGE man_reboot,   "man/reboot.txt"
MANPAGE man_shutdown, "man/shutdown.txt"

section .text
