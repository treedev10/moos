; =============================================================================
;  cmd_net.asm - the "net" command: connect to the network and show status
; =============================================================================
section .data
str_up      db "up", 0
str_down    db "down", 0
str_status  db "status", 0
str_test    db "test", 0
str_dns     db "dns", 0
str_http    db "http", 0
str_selftest db "selftest", 0
str_cards   db "cards", 0
str_native  db "native", 0
str_firmware db "firmware", 0
str_cookies db "cookies", 0
str_loss    db "loss", 0
drv_names   dd drv_none, drv_rtl8139, drv_e1000, drv_rtl8168, drv_snp
drv_none    db "no MOOS driver", 0
drv_rtl8139 db "MOOS driver: rtl8139", 0
drv_e1000   db "MOOS driver: e1000", 0
drv_rtl8168 db "MOOS driver: rtl8168", 0
drv_snp     db "the UEFI firmware's driver", 0
link_up     db "link up", 0
link_down   db "no link (cable?)", 0

section .text

; ip_print: EAX = IP in network byte order -> prints "a.b.c.d"
ip_print:
    push eax
    push ebx
    mov ebx, eax
    movzx eax, bl
    PRINTF `%d.`, eax
    movzx eax, bh
    PRINTF `%d.`, eax
    shr ebx, 16
    movzx eax, bl
    PRINTF `%d.`, eax
    movzx eax, bh
    PRINTF `%d`, eax
    pop ebx
    pop eax
    ret

cmd_net:
    cmp dword [argc], 2
    jb .status
    mov esi, [argv + 4]
    mov edi, str_up
    call str_icmp
    je .up
    mov edi, str_status
    call str_icmp
    je .status
    mov edi, str_down
    call str_icmp
    je .down
    mov edi, str_test
    call str_icmp
    je .test
    mov edi, str_dns
    call str_icmp
    je .setdns
    mov edi, str_http
    call str_icmp
    je .http
    mov edi, str_selftest
    call str_icmp
    je .selftest
    mov edi, str_cards
    call str_icmp
    je net_cards
    mov edi, str_cookies
    call str_icmp
    je .cookies
    mov edi, str_loss
    call str_icmp
    je .loss
.status:
    cmp byte [net_up], 0
    je .not_up
    PRINTF `\x01wNetwork\x01n - connected\n`
    PRINTF `  IP address ..... `
    mov eax, [my_ip]
    call ip_print
    PRINTF `\n  Subnet mask .... `
    mov eax, [my_mask]
    call ip_print
    PRINTF `\n  Gateway ........ `
    mov eax, [gw_ip]
    call ip_print
    PRINTF `\n  DNS server ..... `
    mov eax, [dns_ip]
    call ip_print
    PRINTF `\n`
    call nic_describe
    ret
.not_up:
    PRINTF `The network is not connected. Type \x01wnet up\x01n to connect.\n`
    cmp byte [net_present], 0
    je .no_card
    call nic_describe
    ret
.no_card:
    PRINTF `(No network card is in use yet. \x01wnet cards\x01n lists what is there.)\n`
    ret
.up:
    mov byte [nic_prefer], NET_AUTO ; "net up native" / "net up firmware"
    cmp dword [argc], 3
    jb .up_go
    mov byte [net_present], 0       ; (a choice was given: detect again)
    mov esi, [argv + 8]
    mov edi, str_native
    call str_icmp
    jne .up_fw
    mov byte [nic_prefer], NET_NATIVE
    jmp .up_go
.up_fw:
    mov edi, str_firmware
    call str_icmp
    jne .up_go
    mov byte [nic_prefer], NET_FIRMWARE
.up_go:
    PRINTF `Connecting to the network...\n`
    call net_up_bring
    jc .failed
    PRINTF `\x01gConnected.\x01n  IP `
    mov eax, [my_ip]
    call ip_print
    PRINTF `, gateway `
    mov eax, [gw_ip]
    call ip_print
    PRINTF `\n`
    call nic_describe
    ret
.failed:
    PRINTF `\x01rCould not connect:\x01n %s\n`, esi
    cmp byte [net_present], 0
    je .r_failed
    call nic_describe
.r_failed:
    ret
.down:
    mov byte [net_up], 0
    PRINTF `Network marked as down.\n`
    ret
.test:
    cmp byte [net_up], 0
    je .need_up
    cmp dword [argc], 3             ; optional: net test <server-ip>
    jb .test_name
    mov esi, [argv + 8]
    call parse_ipv4
    jc .test_name
    PRINTF `Asking that server the time...\n`
    call ntp_query_addr
    jmp .test_show
.test_name:
    PRINTF `Looking up pool.ntp.org and asking it the time...\n`
    call ntp_query
.test_show:
    jc .test_fail
    push eax
    call epoch_to_datetime          ; fills rtc_* (UTC)
    PRINTF `\x01gThe internet says:\x01n %d-%02d-%02d %02d:%02d:%02d UTC\n`, dword [rtc_year], dword [rtc_month], dword [rtc_day], dword [rtc_hour], dword [rtc_min], dword [rtc_sec]
    pop eax
    ret
.test_fail:
    PRINTF `\x01rThe time request failed.\x01n Check the connection with \x01wnet status\x01n.\n`
    ret
.need_up:
    PRINTF `Connect first with \x01wnet up\x01n.\n`
    ret
.setdns:
    mov esi, [argv + 8]
    call parse_ipv4
    jc .dns_bad
    mov [dns_ip], eax
    PRINTF `DNS server set to `
    call ip_print
    PRINTF `\n`
    ret
.dns_bad:
    PRINTF `Usage: net dns <a.b.c.d>\n`
    ret
.http:                                  ; net http <ip> <port> <path>
    cmp dword [argc], 5
    jb .http_usage
    mov esi, [argv + 8]
    call parse_ipv4
    jc .http_usage
    mov esi, [argv + 12]
    call parse_uint
    jc .http_usage
    mov edi, url_argbuf                 ; -> "http://ip:port/path"
    mov esi, url_http
    call str_copy_noterm
    mov esi, [argv + 8]
    call str_copy_noterm
    mov byte [edi], ':'
    inc edi
    mov esi, [argv + 12]
    call str_copy_noterm
    mov esi, [argv + 16]
    cmp byte [esi], '/'
    je .http_path
    mov byte [edi], '/'
    inc edi
.http_path:
    call str_copy
    PRINTF `Downloading...\n`
    mov esi, url_argbuf
    call url_fetch
    jc .http_fail
    PRINTF `\x01gHTTP %d\x01n, %d bytes. Date: %s\n`, dword [http_status], dword [pkg_len], http_date
    mov esi, PKG_BUF                    ; show the first part of the body
    mov ecx, [pkg_len]
    cmp ecx, 200
    jbe .show
    mov ecx, 200
.show:
    call out_begin
    call out_text
    xor ebx, ebx
    call out_flush
    PRINTF `\n`
    ret
.http_fail:
    PRINTF `\x01rerror:\x01n %s\n`, dword [url_err]
    ret
.selftest:
    call crypto_selftest
    ret
.http_usage:
    PRINTF `Usage: net http <ip> <port> <path>   (example: net http 10.0.2.2 8000 /hi.txt)\n`
    ret
.cookies:                               ; net cookies [clear]
    cmp dword [argc], 3
    jb .ck_list
    mov esi, [argv + 8]
    mov edi, str_clear
    call str_icmp
    jne .ck_usage
    call cookie_clear
    PRINTF `All cookies forgotten.\n`
    ret
.ck_list:
    PRINTF `\x01wCookies\x01n (kept until MOOS restarts):\n`
    call cookie_list
    ret
.ck_usage:
    PRINTF `Usage: net cookies [clear]\n`
    ret
.loss:                                  ; net loss <percent> (testing only)
    cmp dword [argc], 3
    jb .loss_usage
    mov esi, [argv + 8]
    call parse_uint
    jc .loss_usage
    cmp eax, 50
    ja .loss_usage
    mov [tcp_loss], al
    test eax, eax
    jz .loss_off
    PRINTF `\x01yTesting:\x01n TCP now throws away %d%% of the segments it sends and\nreceives, to check that lost data is sent again. "net loss 0" stops it.\n`, eax
    ret
.loss_off:
    PRINTF `TCP loss test off.\n`
    ret
.loss_usage:
    PRINTF `Usage: net loss <percent>   (0-50; 0 = off)\n`
    ret


; mac_print: print nic_mac as aa:bb:cc:dd:ee:ff
mac_print:
    push eax
    push ecx
    push esi
    mov esi, nic_mac
    mov ecx, 6
.l: movzx eax, byte [esi]
    PRINTF `%02x`, eax
    inc esi
    dec ecx
    jz .done
    PRINTF `:`
    jmp .l
.done:
    pop esi
    pop ecx
    pop eax
    ret

; nic_describe: one line about the card in use
nic_describe:
    pushad
    cmp byte [nic_kind], NIC_SNP
    jne .native
    PRINTF `  Card ........... the UEFI firmware's network driver`
    jmp .mac
.native:
    mov ebx, [nic_pci]
    call pci_loc_print_prep
    PRINTF `  Card ........... %s (PCI %02x:%02x.%d, %04x:%04x)`, dword [nic_name], eax, ecx, edx, esi, edi
.mac:
    PRINTF `\n  MAC address .... `
    call mac_print
    mov esi, link_up
    cmp byte [net_link], 0
    jne .lk
    mov esi, link_down
.lk:
    PRINTF `\n  Link ........... %s\n`, esi
    popad
    ret

; pci_loc_print_prep: EBX = PCI address -> EAX bus, ECX device, EDX function,
; ESI vendor, EDI device id (of nic_vendev, for the card in use)
pci_loc_print_prep:
    mov eax, ebx
    shr eax, 16
    and eax, 0xFF
    mov ecx, ebx
    shr ecx, 11
    and ecx, 0x1F
    mov edx, ebx
    shr edx, 8
    and edx, 7
    movzx esi, word [nic_vendev]
    movzx edi, word [nic_vendev + 2]
    ret

; net_cards: list every network controller on the PCI buses, and whether the
; UEFI firmware offers a network driver
net_cards:
    PRINTF `\x01wNetwork cards\x01n (PCI):\n`
    mov ebx, -1
    xor ebp, ebp
.next:
    call pci_next
    jc .done
    mov [nc_vendev], eax
    mov al, 0x08                    ; class code
    call pci_read32
    shr eax, 16
    cmp ah, 0x02                    ; network controller
    jne .next
    mov [nc_sub], al
    inc ebp
    mov eax, [nc_vendev]            ; name and driver from the table
    call nic_lookup
    jc .unknown
    mov eax, [esi + NT_NAME]
    mov [nc_name], eax
    movzx eax, byte [esi + NT_DRIVER]
    mov eax, [drv_names + eax * 4]
    mov [nc_drv], eax
    jmp .print
.unknown:
    mov dword [nc_name], nm_other
    cmp byte [nc_sub], 0x80         ; "other network": almost always Wi-Fi
    jne .unk_drv
    mov dword [nc_name], nm_wireless
.unk_drv:
    mov dword [nc_drv], drv_none
.print:
    mov eax, ebx
    shr eax, 16
    and eax, 0xFF
    mov ecx, ebx
    shr ecx, 11
    and ecx, 0x1F
    mov edx, ebx
    shr edx, 8
    and edx, 7
    movzx esi, word [nc_vendev]
    movzx edi, word [nc_vendev + 2]
    PRINTF `  %02x:%02x.%d  %04x:%04x  %s\n             - %s\n`, eax, ecx, edx, esi, edi, dword [nc_name], dword [nc_drv]
    jmp .next
.done:
    test ebp, ebp
    jnz .counted
    PRINTF `  (none found on PCI)\n`
.counted:
    PRINTF `  USB network adapters (Wi-Fi or Ethernet) are not listed: MOOS has no USB\n  network drivers.\n`
    cmp dword [bootinfo + BI.platform], PLATFORM_UEFI
    jne .bios
    mov eax, efi_snp_probe64
    call efi64
    test eax, eax
    jz .no_fw
    PRINTF `\x01gThe UEFI firmware offers a network driver\x01n (%d interface(s)) - "net up" uses it.\n`, eax
    ret
.no_fw:
    PRINTF `The UEFI firmware offers \x01wno\x01n network driver. To let MOOS use it, turn on\n"Network Stack" (or PXE / LAN Option ROM) in your PC's firmware setup.\n`
    ret
.bios:
    PRINTF `(Started from BIOS: only MOOS's own drivers can be used.)\n`
    ret

section .bss
alignb 4
nc_vendev   resd 1
nc_name     resd 1
nc_drv      resd 1
nc_sub      resb 1
section .text

; ------------------------------------------------------------- nettest
; nettest [-k] [-n] [-r START-END] <url|@file>
; Downloads a URL with the stream API (hs_open, then hs_read until the end),
; the way a media player reads a video, and reports the size, the time, the
; speed and the SHA-256 of what came - compare it with "sha256sum" of the
; server's copy. -k skips the certificate check (testing only), -n skips
; the hash (to time the network alone), -r asks for a part of the file.
; Esc stops it.
NT_BUF      equ SCRATCH                 ; each hs_read goes here
NT_BUF_SIZE equ SCRATCH_SIZE

section .bss
alignb 4
nt_url      resd 1
nt_rs       resd 1                      ; -r START-END (-1 = none)
nt_re       resd 1
nt_t0       resd 1                      ; ticks: start, body start,
nt_t1       resd 1
nt_shown    resd 1                      ;   last progress line,
nt_keyt     resd 1                      ;   last look at the keyboard
nt_bytes    resd 1
nt_nohash   resb 1
alignb 4
nt_sha      resb SHA_CTX
nt_digest   resb 32

section .data
str_dash_n  db "-n", 0
nt_hex      db "0123456789abcdef"

section .text

cmd_nettest:
    mov byte [url_insecure], 0
    mov byte [nt_nohash], 0
    mov dword [nt_rs], -1
    mov dword [nt_re], -1
    mov ebx, 1                          ; argument index
.opt:
    cmp ebx, [argc]
    jae .usage
    mov esi, [argv + ebx * 4]
    mov edi, str_dash_k
    call str_icmp
    jne .not_k
    mov byte [url_insecure], 1
    inc ebx
    jmp .opt
.not_k:
    mov edi, str_dash_n
    call str_icmp
    jne .not_n
    mov byte [nt_nohash], 1
    inc ebx
    jmp .opt
.not_n:
    mov edi, str_dash_r
    call str_icmp
    jne .url
    inc ebx                             ; -r START-END (END may be left out)
    cmp ebx, [argc]
    jae .usage
    mov esi, [argv + ebx * 4]
    call parse_uint_partial
    jc .usage
    mov [nt_rs], eax
    cmp byte [esi], '-'
    jne .usage
    inc esi
    cmp byte [esi], 0
    je .r_open
    call parse_uint_partial
    jc .usage
    mov [nt_re], eax
.r_open:
    inc ebx
    jmp .opt
.url:
    call url_arg                        ; ("@file": the URL is in a file)
    jc .fail
    mov [nt_url], esi
    cmp byte [url_insecure], 0
    je .open
    PRINTF `\x01yWarning:\x01n -k: the server's certificate is not checked.\n`
.open:
    PRINTF `Opening %s ...\n`, dword [nt_url]
    mov eax, [nt_rs]
    mov [url_range_start], eax
    mov eax, [nt_re]
    mov [url_range_end], eax
    mov eax, [ticks]
    mov [nt_t0], eax
    mov esi, [nt_url]
    call hs_open
    pushfd
    call url_options_reset
    mov byte [url_insecure], 0
    popfd
    jc .fail
    mov eax, [ticks]
    sub eax, [nt_t0]
    imul eax, 10
    PRINTF `\x01gHTTP %d\x01n, Content-Length %d, Content-Range total %d (headers after %d ms)\n`, dword [hs_status], dword [hs_clen], dword [hs_total], eax
    cmp byte [http_ctype], 0
    je .ct
    PRINTF `Content-Type: %s\n`, http_ctype
.ct:
    CCALL sha256_init, nt_sha
    mov dword [nt_bytes], 0
    mov eax, [ticks]
    mov [nt_t1], eax
    mov [nt_shown], eax
    mov [nt_keyt], eax
.loop:
    mov edi, NT_BUF
    mov ecx, NT_BUF_SIZE
    call hs_read
    test eax, eax
    jg .data
    jl .end
    mov eax, [ticks]                    ; nothing yet: a key? (once a tick:
    cmp eax, [nt_keyt]                  ; on UEFI each look is a firmware
    je .idle                            ; call)
    mov [nt_keyt], eax
    call kbd_poll
    cmp eax, 27                         ; Esc
    je .stopped
    cmp eax, 3                          ; Ctrl+C
    je .stopped
.idle:
    call nt_progress
    call net_idle
    jmp .loop
.data:
    add [nt_bytes], eax
    cmp byte [nt_nohash], 0
    jne .shown
    CCALL sha256_update, nt_sha, NT_BUF, eax
.shown:
    call nt_progress
    jmp .loop
.stopped:
    call hs_close
    call nt_line_start
    PRINTF `Stopped after %d bytes.\n`, dword [nt_bytes]
    ret
.end:
    push eax
    call nt_line_start
    pop eax
    cmp eax, -1
    jne .broke
    call nt_report
    call hs_close
    ret
.broke:
    PRINTF `\x01rerror:\x01n %s (after %d bytes)\n`, dword [url_err], dword [nt_bytes]
    call hs_close
    ret
.fail:
    PRINTF `\x01rerror:\x01n %s\n`, dword [url_err]
    ret
.usage:
    PRINTF `Usage: \x01wnettest\x01n [-k] [-n] [-r START-END] <url|@file>\n`
    ret

; nt_line_start: back to the start of the progress line (text screen only)
nt_line_start:
    cmp byte [gui_capture], 0
    jne .r
    mov dword [cur_x], 0
.r: ret

; nt_progress: once a second, rewrite the progress line (bytes and speed)
nt_progress:
    pushad
    cmp byte [gui_capture], 0           ; (the desktop's terminal: no
    jne .r                              ; rewriting of lines)
    mov eax, [ticks]
    sub eax, [nt_shown]
    cmp eax, 100
    jb .r
    mov eax, [ticks]
    mov [nt_shown], eax
    call nt_line_start
    mov eax, [nt_bytes]
    shr eax, 10
    call nt_speed                       ; EAX = MB/s x 100
    xor edx, edx
    mov ecx, 100
    div ecx
    mov ecx, [nt_bytes]
    shr ecx, 10
    PRINTF `  %d KB  %d.%02d MB/s      `, ecx, eax, edx
    call screen_present
.r: popad
    ret

; nt_speed -> EAX = the speed so far in hundredths of MB/s (nt_bytes since
; nt_t1)
nt_speed:
    push ecx
    push edx
    mov ecx, [ticks]
    sub ecx, [nt_t1]
    jnz .t
    inc ecx
.t: mov eax, [nt_bytes]                 ; bytes x 100 / ticks = bytes/s
    mov edx, 100
    mul edx
    cmp edx, ecx                        ; (the quotient must fit 32 bits)
    jb .div
    mov eax, 0xFFFFFFFF
    jmp .mb
.div:
    div ecx
.mb:
    mov edx, 100                        ; x 100 / 2^20 = hundredths of MB/s
    mul edx
    shrd eax, edx, 20
    pop edx
    pop ecx
    ret

; nt_report: the summary at the end: size, time, speed, SHA-256
nt_report:
    pushad
    mov eax, [ticks]
    sub eax, [nt_t1]
    xor edx, edx
    mov ecx, 100
    div ecx                             ; EAX = seconds, EDX = hundredths
    mov ebx, eax
    mov ebp, edx
    call nt_speed
    xor edx, edx
    mov ecx, 100
    div ecx
    PRINTF `\x01gDone:\x01n %d bytes in %d.%02d s = %d.%02d MB/s\n`, dword [nt_bytes], ebx, ebp, eax, edx
    cmp byte [nt_nohash], 0
    jne .r
    CCALL sha256_final, nt_sha, nt_digest
    PRINTF `SHA-256: `
    xor ebx, ebx
.h: movzx eax, byte [nt_digest + ebx]
    mov edx, eax
    shr eax, 4
    mov al, [nt_hex + eax]
    call out_char
    and edx, 15
    mov al, [nt_hex + edx]
    call out_char
    inc ebx
    cmp ebx, 32
    jb .h
    PRINTF `\n`
.r: popad
    ret
