section .data
str_up      db "up", 0
str_down    db "down", 0
str_status  db "status", 0
str_test    db "test", 0
str_dns     db "dns", 0
str_http    db "http", 0
str_selftest db "selftest", 0

section .text

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
    PRINTF `\n  Card ........... RTL8139 at I/O 0x%x, MAC `, dword [nic_io]
    call mac_print
    PRINTF `\n`
    ret
.not_up:
    PRINTF `The network is not connected. Type \x01wnet up\x01n to connect.\n`
    cmp byte [net_present], 0
    je .no_card
    PRINTF `  Card ........... RTL8139 at I/O 0x%x, MAC `, dword [nic_io]
    call mac_print
    PRINTF `\n`
    ret
.no_card:
    PRINTF `(No network card has been detected yet.)\n`
    ret
.up:
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
    ret
.failed:
    PRINTF `\x01rCould not connect:\x01n %s\n`, esi
    ret
.down:
    mov byte [net_up], 0
    PRINTF `Network marked as down.\n`
    ret
.test:
    cmp byte [net_up], 0
    je .need_up
    cmp dword [argc], 3
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
    call epoch_to_datetime
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
.http:
    cmp dword [argc], 5
    jb .http_usage
    mov esi, [argv + 8]
    call parse_ipv4
    jc .http_usage
    mov [http_test_ip], eax
    mov esi, [argv + 12]
    call parse_uint
    jc .http_usage
    mov [http_test_port], ax
    PRINTF `Downloading...\n`
    mov eax, [http_test_ip]
    mov bx, [http_test_port]
    mov esi, [argv + 8]
    mov edi, [argv + 16]
    call http_get
    jc .http_fail
    PRINTF `\x01gHTTP %d\x01n, %d bytes. Date: %s\n`, dword [http_status], dword [pkg_len], http_date
    mov esi, PKG_BUF
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
    PRINTF `\x01rCould not connect to the server.\x01n\n`
    ret
.selftest:
    call crypto_selftest
    ret
.http_usage:
    PRINTF `Usage: net http <ip> <port> <path>   (example: net http 10.0.2.2 8000 /hi.txt)\n`
    ret

section .bss
alignb 4
http_test_ip    resd 1
http_test_port  resw 1
section .text

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
