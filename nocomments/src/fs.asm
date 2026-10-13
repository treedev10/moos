%include "src/layout.inc"
FS_LBA_HDR      equ PART_FS_LBA
FS_LBA_DIR      equ PART_FS_LBA + 1
FS_DIR_SECTS    equ 2
FS_LBA_DATA     equ PART_FS_LBA + 8
FS_MAX_FILES    equ 32
FS_SLOT_SIZE    equ 4096
FS_SLOT_SECTS   equ 8
FS_NAME_MAX     equ 19

DE_NAME         equ 0
DE_SIZE         equ 20
DE_FLAGS        equ 24
DE_MTIME        equ 28
DE_SIZEOF       equ 32
FLAG_USED       equ 1

section .bss
fs_persist      resb 1
alignb 4
fs_part_lba     resd 1
fs_sector       resb 512

section .data
fs_magic        db "MOOSFS01"
fs_magic_old    db "NOVAFS01"
welcome_name    db "welcome.txt", 0
welcome_text:
    db "Welcome to MOOS!", 10
    db 10
    db "This is a text file stored on the MOOS file system.", 10
    db "You just displayed it with:  cat welcome.txt", 10
    db 10
    db "Things to try:", 10
    db "  help             list every command", 10
    db "  man intro        a guided tour of the system", 10
    db "  edit notes.txt   create a file in the text editor", 10
    db "  calc 6*7         use the built-in calculator", 10
    db "  color ocean      change the colour theme", 10
    db 10
    db "Files are saved to disk automatically - they survive a reboot.", 10
welcome_len equ $ - welcome_text

disk_method_names dd dm_none, dm_ata, dm_bios, dm_uefi
dm_none         db "nothing (RAM only)", 0
dm_ata          db "the MOOS ATA driver", 0
dm_bios         db "the BIOS (INT 13h)", 0
dm_uefi         db "the UEFI firmware", 0
err_name_bad    db "invalid file name (use 1-19 letters, digits, '.', '-' or '_')", 0
err_too_big     db "file too large (the limit is 4096 bytes)", 0
err_disk_full   db "no free file slots (the limit is 32 files) - delete something first", 0
err_exists      db "a file with that name already exists", 0

section .text

fs_entry:
    mov edi, ebx
    shl edi, 5
    add edi, FS_DIR
    ret

fs_slot:
    mov esi, ebx
    shl esi, 12
    add esi, FS_DATA
    ret

fs_init:
    pushad
    mov byte [fs_persist], 0
    cmp dword [bootinfo + BI.platform], PLATFORM_UEFI
    je .uefi
    mov eax, [bootinfo + BI.part_lba]
    mov [fs_part_lba], eax
    mov byte [disk_mode], DISK_ATA
    mov dx, ATA_IO + 7
    in al, dx
    cmp al, 0xFF
    je .try_bios
    call fs_is_boot_disk
    jnc .found
.try_bios:
    mov byte [disk_mode], DISK_BIOS
    call fs_is_boot_disk
    jnc .found
    jmp .nothing
.uefi:
    mov dword [fs_part_lba], 0
    mov eax, [bootinfo + BI.blockio]
    mov edx, [bootinfo + BI.blockio + 4]
    mov [efi_cur_bio], eax
    mov [efi_cur_bio + 4], edx
    or eax, edx
    jz .nothing
    mov byte [disk_mode], DISK_UEFI
    call fs_is_boot_part
    jnc .found
.nothing:
    mov byte [disk_mode], DISK_NONE
    jmp .ram_only
.found:
    mov byte [fs_persist], 1

    mov eax, FS_LBA_HDR
    mov ecx, 1
    mov edi, fs_sector
    call part_read
    jc .disk_failed
    mov esi, fs_sector
    mov edi, fs_magic
    mov ecx, 2
    repe cmpsd
    je .load_dir
    mov esi, fs_sector
    mov edi, fs_magic_old
    mov ecx, 2
    repe cmpsd
    jne .fresh
    call fs_write_header
    jc .disk_failed
.load_dir:

    mov eax, FS_LBA_DIR
    mov ecx, FS_DIR_SECTS
    mov edi, FS_DIR
    call part_read
    jc .disk_failed
    xor ebx, ebx
.load:
    call fs_entry
    test byte [edi + DE_FLAGS], FLAG_USED
    jz .next
    cmp dword [edi + DE_SIZE], FS_SLOT_SIZE
    jbe .size_ok
    mov dword [edi + DE_SIZE], FS_SLOT_SIZE
.size_ok:
    mov byte [edi + DE_NAME + FS_NAME_MAX], 0
    mov ecx, [edi + DE_SIZE]
    add ecx, 511
    shr ecx, 9
    mov eax, ebx
    shl eax, 3
    add eax, FS_LBA_DATA
    call fs_slot
    mov edi, esi
    call part_read
    jc .disk_failed
.next:
    inc ebx
    cmp ebx, FS_MAX_FILES
    jb .load
    call fs_stats
    call fs_method
    PRINTF `\x01g[ OK ]\x01n Disk: %d file(s), %d bytes, saved through %s\n`, eax, edx, esi
    jmp .done

.fresh:
    call fs_format
    call fs_add_welcome
    call fs_method
    PRINTF `\x01g[ OK ]\x01n Disk: new file system created, saved through %s\n`, esi
    jmp .done
.disk_failed:
    mov byte [fs_persist], 0
    mov byte [disk_mode], DISK_NONE
.ram_only:
    call fs_format
    call fs_add_welcome
    PRINTF `\x01y[WARN]\x01n Disk: boot disk not found - files are kept in RAM only\n`
.done:
    popad
    ret

fs_is_boot_disk:
    pushad
    xor eax, eax
    mov ecx, 1
    mov edi, fs_sector
    call disk_read
    jc .no
    mov esi, fs_sector
    mov edi, 0x7C00
    mov ecx, 32
    repe cmpsd
    jne .no
    cmp word [fs_sector + 510], 0xAA55
    jne .no
    popad
    jmp fs_is_boot_part
.no:
    popad
    stc
    ret

fs_is_boot_part:
    pushad
    xor eax, eax
    mov ecx, 1
    mov edi, fs_sector
    call part_read
    jc .no
    cmp dword [fs_sector + 3], 'MOOS'
    jne .no
    cmp word [fs_sector + 510], 0xAA55
    jne .no
    popad
    clc
    ret
.no:
    popad
    stc
    ret

part_read:
    push eax
    add eax, [fs_part_lba]
    call disk_read
    pop eax
    ret

part_write:
    push eax
    add eax, [fs_part_lba]
    call disk_write
    pop eax
    ret

fs_method:
    push ebx
    movzx ebx, byte [disk_mode]
    mov esi, [disk_method_names + ebx * 4]
    pop ebx
    ret

fs_add_welcome:
    pushad
    mov esi, welcome_name
    mov edx, welcome_text
    mov ecx, welcome_len
    call fs_save
    popad
    ret

fs_format:
    pushad
    mov edi, FS_DIR
    mov ecx, FS_MAX_FILES * DE_SIZEOF / 4
    xor eax, eax
    rep stosd
    cmp byte [fs_persist], 0
    je .done
    call fs_write_header
    jc .fail
    call fs_save_dir
    jnc .done
.fail:
    call fs_disk_error
.done:
    popad
    ret

fs_write_header:
    pushad
    mov edi, fs_sector
    mov ecx, 128
    xor eax, eax
    rep stosd
    mov esi, fs_magic
    mov edi, fs_sector
    movsd
    movsd
    mov eax, FS_LBA_HDR
    mov ecx, 1
    mov esi, fs_sector
    call part_write
    popad
    ret

fs_save_dir:
    cmp byte [fs_persist], 0
    je .skip
    pushad
    mov eax, FS_LBA_DIR
    mov ecx, FS_DIR_SECTS
    mov esi, FS_DIR
    call part_write
    popad
    ret
.skip:
    clc
    ret

fs_commit:
    cmp byte [fs_persist], 0
    je .skip
    pushad
    call fs_entry
    mov ecx, [edi + DE_SIZE]
    add ecx, 511
    shr ecx, 9
    test byte [edi + DE_FLAGS], FLAG_USED
    jnz .used
    xor ecx, ecx
.used:
    mov eax, ebx
    shl eax, 3
    add eax, FS_LBA_DATA
    call fs_slot
    call part_write
    jc .fail
    call fs_save_dir
    jnc .ok
.fail:
    call fs_disk_error
.ok:
    popad
.skip:
    ret

fs_disk_error:
    mov byte [fs_persist], 0
    PRINTF `\x01rwarning:\x01n disk write failed - from now on files are kept in RAM only\n`
    ret

fs_find:
    xor ebx, ebx
.l: call fs_entry
    test byte [edi + DE_FLAGS], FLAG_USED
    jz .n
    call str_icmp
    je .found
.n: inc ebx
    cmp ebx, FS_MAX_FILES
    jb .l
    stc
    ret
.found:
    clc
    ret

fs_name_valid:
    push eax
    push ecx
    push esi
    xor ecx, ecx
.l: lodsb
    test al, al
    jz .end
    inc ecx
    cmp al, '.'
    je .l
    cmp al, '-'
    je .l
    cmp al, '_'
    je .l
    cmp al, '0'
    jb .bad
    cmp al, '9'
    jbe .l
    call to_lower
    cmp al, 'a'
    jb .bad
    cmp al, 'z'
    jbe .l
.bad:
    stc
    jmp .out
.end:
    test ecx, ecx
    jz .bad
    cmp ecx, FS_NAME_MAX
    ja .bad
    clc
.out:
    pop esi
    pop ecx
    pop eax
    ret

fs_timestamp:
    push ebx
    call rtc_read
    movzx eax, word [rtc_year]
    sub eax, 2000
    shl eax, 26
    movzx ebx, byte [rtc_month]
    shl ebx, 22
    or eax, ebx
    movzx ebx, byte [rtc_day]
    shl ebx, 17
    or eax, ebx
    movzx ebx, byte [rtc_hour]
    shl ebx, 12
    or eax, ebx
    movzx ebx, byte [rtc_min]
    shl ebx, 6
    or eax, ebx
    movzx ebx, byte [rtc_sec]
    or eax, ebx
    pop ebx
    ret

fs_save:
    cmp ecx, FS_SLOT_SIZE
    ja .too_big
    call fs_name_valid
    jc .bad_name
    pushad
    call fs_find
    jnc .have
    xor ebx, ebx
.free:
    call fs_entry
    test byte [edi + DE_FLAGS], FLAG_USED
    jz .claim
    inc ebx
    cmp ebx, FS_MAX_FILES
    jb .free
    popad
    mov esi, err_disk_full
    stc
    ret
.claim:
    push ecx
    push edi
    mov ecx, DE_SIZEOF
    xor eax, eax
    rep stosb
    pop edi
    pop ecx
    call str_copy
.have:
    mov [edi + DE_SIZE], ecx
    mov dword [edi + DE_FLAGS], FLAG_USED
    call fs_timestamp
    mov [edi + DE_MTIME], eax
    call fs_slot
    mov edi, esi
    mov esi, edx
    cmp esi, edi
    je .copied
    rep movsb
.copied:
    call fs_commit
    popad
    clc
    ret
.too_big:
    mov esi, err_too_big
    stc
    ret
.bad_name:
    mov esi, err_name_bad
    stc
    ret

fs_delete:
    pushad
    call fs_entry
    mov ecx, DE_SIZEOF
    xor eax, eax
    rep stosb
    call fs_commit
    popad
    ret

fs_rename:
    call fs_name_valid
    jc .bad_name
    push ebx
    push edi
    call fs_find
    pop edi
    jnc .exists
    pop ebx
    pushad
    call fs_entry
    mov ecx, 20
    push edi
    xor eax, eax
    rep stosb
    pop edi
    call str_copy
    call fs_commit
    popad
    clc
    ret
.exists:
    pop ebx
    mov esi, err_exists
    stc
    ret
.bad_name:
    mov esi, err_name_bad
    stc
    ret

fs_stats:
    push ebx
    push edi
    xor eax, eax
    xor edx, edx
    xor ebx, ebx
.l: call fs_entry
    test byte [edi + DE_FLAGS], FLAG_USED
    jz .n
    inc eax
    add edx, [edi + DE_SIZE]
.n: inc ebx
    cmp ebx, FS_MAX_FILES
    jb .l
    pop edi
    pop ebx
    ret
