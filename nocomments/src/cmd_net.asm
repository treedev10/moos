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
drv_names   dd drv_none, drv_rtl8139, drv_e1000, drv_rtl8168, drv_snp
drv_none    db "no MOOS driver", 0
drv_rtl8139 db "MOOS driver: rtl8139", 0
drv_e1000   db "MOOS driver: e1000", 0
drv_rtl8168 db "MOOS driver: rtl8168", 0
drv_snp     db "the UEFI firmware's driver", 0
link_up     db "link up", 0
link_down   db "no link (cable?)", 0

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
    mov edi, str_cards
    call str_icmp
    je net_cards
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
    mov byte [nic_prefer], NET_AUTO
    cmp dword [argc], 3
    jb .up_go
    mov byte [net_present], 0
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

net_cards:
    PRINTF `\x01wNetwork cards\x01n (PCI):\n`
    mov ebx, -1
    xor ebp, ebp
.next:
    call pci_next
    jc .done
    mov [nc_vendev], eax
    mov al, 0x08
    call pci_read32
    shr eax, 16
    cmp ah, 0x02
    jne .next
    mov [nc_sub], al
    inc ebp
    mov eax, [nc_vendev]
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
    cmp byte [nc_sub], 0x80
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
