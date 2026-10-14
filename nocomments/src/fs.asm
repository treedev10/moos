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
DE_PARENT       equ DE_FLAGS + 1
FLAG_USED       equ 1
FLAG_DIR        equ 2
FS_PATH_MAX     equ 256

section .bss
fs_persist      resb 1
alignb 4
fs_part_lba     resd 1
fs_sector       resb 512
alignb 4
fs_cwd          resd 1
fs_chain        resd FS_MAX_FILES
fs_leaf         resb 24
fs_tmp_path     resb FS_PATH_MAX

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
err_name_bad    db "invalid name (1-19 letters, digits, '.', '-', '_')", 0
err_too_big     db "file too large (the limit is 4096 bytes)", 0
err_disk_full   db "all 32 entries are in use (files and folders together)", 0
err_exists      db "a file or folder with that name already exists there", 0
err_no_folder   db "no such folder", 0
err_not_folder  db "that is a file, not a folder", 0
err_is_folder   db "that is a folder, not a file", 0
err_not_empty   db "the folder is not empty - delete what is in it first", 0
err_into_self   db "a folder cannot be moved into itself", 0

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
    call fs_check_tree
    call fs_stats
    call fs_counts
    call fs_method
    PRINTF `\x01g[ OK ]\x01n Disk: %d file(s)/%d folder(s), %d bytes, saved through %s\n`, eax, ecx, edx, esi
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
    mov dword [fs_cwd], 0
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

fs_up:
    test eax, eax
    jz .r
    shl eax, 5
    movzx eax, byte [FS_DIR - DE_SIZEOF + DE_PARENT + eax]
.r: ret

fs_lookup:
    xor ebx, ebx
.l: call fs_entry
    test byte [edi + DE_FLAGS], FLAG_USED
    jz .n
    cmp [edi + DE_PARENT], al
    jne .n
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

fs_resolve:
    push ebx
    push ecx
    push esi
    push edi
    mov eax, [fs_cwd]
    cmp byte [esi], '/'
    jne .start
    xor eax, eax
.start:
    mov byte [fs_leaf], 0
.skip:
    cmp byte [esi], '/'
    jne .part
    inc esi
    jmp .skip
.part:
    cmp byte [esi], 0
    je .ok
    mov edi, fs_leaf
    xor ecx, ecx
.copy:
    mov bl, [esi]
    test bl, bl
    jz .copied
    cmp bl, '/'
    je .copied
    cmp ecx, FS_NAME_MAX
    jae .bad
    mov [edi + ecx], bl
    inc ecx
    inc esi
    jmp .copy
.copied:
    mov byte [edi + ecx], 0
    cmp byte [edi], '.'
    jne .name
    cmp byte [edi + 1], 0
    je .dot
    cmp word [edi + 1], '.'
    jne .name
    call fs_up
.dot:
    mov byte [fs_leaf], 0
    jmp .skip
.name:
    mov ebx, esi
.more:
    cmp byte [ebx], '/'
    jne .last
    inc ebx
    jmp .more
.last:
    cmp byte [ebx], 0
    je .ok
    push esi
    mov esi, fs_leaf
    call fs_lookup
    pop esi
    jc .no_folder
    test byte [edi + DE_FLAGS], FLAG_DIR
    jz .not_folder
    lea eax, [ebx + 1]
    jmp .skip
.ok:
    clc
    jmp .out
.bad:
    mov eax, err_name_bad
    jmp .fail
.no_folder:
    mov eax, err_no_folder
    jmp .fail
.not_folder:
    mov eax, err_not_folder
.fail:
    mov byte [fs_leaf], 0
    stc
.out:
    pop edi
    pop esi
    pop ecx
    pop ebx
    ret

fs_find:
    push eax
    call fs_resolve
    jc .no
    cmp byte [fs_leaf], 0
    je .folder
    push esi
    mov esi, fs_leaf
    call fs_lookup
    pop esi
    pop eax
    ret
.folder:
    test eax, eax
    jz .no
    lea ebx, [eax - 1]
    call fs_entry
    pop eax
    clc
    ret
.no:
    pop eax
    stc
    ret

fs_find_dir:
    push ebx
    push edi
    call fs_resolve
    jc .out
    cmp byte [fs_leaf], 0
    je .ok
    push esi
    mov esi, fs_leaf
    call fs_lookup
    pop esi
    mov eax, err_no_folder
    jc .out
    mov eax, err_not_folder
    test byte [edi + DE_FLAGS], FLAG_DIR
    stc
    jz .out
    lea eax, [ebx + 1]
.ok:
    clc
.out:
    pop edi
    pop ebx
    ret

fs_find_top:
    push dword [fs_cwd]
    mov dword [fs_cwd], 0
    call fs_find
    pop dword [fs_cwd]
    ret

fs_save_top:
    push dword [fs_cwd]
    mov dword [fs_cwd], 0
    call fs_save
    pop dword [fs_cwd]
    ret

fs_dir_count:
    push ebx
    push edi
    xor ecx, ecx
    xor ebx, ebx
.l: call fs_entry
    test byte [edi + DE_FLAGS], FLAG_USED
    jz .n
    cmp [edi + DE_PARENT], al
    jne .n
    inc ecx
.n: inc ebx
    cmp ebx, FS_MAX_FILES
    jb .l
    pop edi
    pop ebx
    ret

fs_inside:
    push eax
    push ecx
    mov ecx, FS_MAX_FILES + 1
.l: test eax, eax
    jz .no
    dec eax
    cmp eax, ebx
    je .yes
    inc eax
    call fs_up
    loop .l
.no:
    clc
    jmp .out
.yes:
    stc
.out:
    pop ecx
    pop eax
    ret

fs_path:
    pushad
    xor ecx, ecx
.up:
    test eax, eax
    jz .down
    cmp ecx, FS_MAX_FILES
    jae .down
    mov [fs_chain + ecx * 4], eax
    inc ecx
    call fs_up
    jmp .up
.down:
    lea edx, [edi + FS_PATH_MAX - 1]
    test ecx, ecx
    jnz .part
    mov byte [edi], '/'
    inc edi
    jmp .end
.part:
    dec ecx
    cmp edi, edx
    jae .end
    mov byte [edi], '/'
    inc edi
    mov esi, [fs_chain + ecx * 4]
    shl esi, 5
    add esi, FS_DIR - DE_SIZEOF
.ch:
    lodsb
    test al, al
    jz .next
    cmp edi, edx
    jae .end
    stosb
    jmp .ch
.next:
    test ecx, ecx
    jnz .part
.end:
    mov byte [edi], 0
    popad
    ret

fs_entry_path:
    pushad
    mov edx, edi
    call fs_entry
    movzx eax, byte [edi + DE_PARENT]
    mov esi, edi
    mov edi, edx
    call fs_path
    call str_len
    push esi
    mov esi, edi
    push ecx
    call str_len
    mov eax, ecx
    pop ecx
    pop esi
    lea ecx, [eax + ecx + 2]
    cmp ecx, FS_PATH_MAX
    ja .done
    cmp eax, 1
    je .top
    mov byte [edi + eax], '/'
    inc eax
.top:
    add edi, eax
    call str_copy
.done:
    popad
    ret

fs_name_valid:
    push eax
    push ecx
    push esi
    cmp byte [esi], '.'
    jne .chars
    cmp byte [esi + 1], 0
    je .bad
    cmp word [esi + 1], '.'
    je .bad
.chars:
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

fs_leaf_check:
    push esi
    mov esi, fs_leaf
    call fs_name_valid
    pop esi
    jnc .r
    mov eax, err_name_bad
.r: ret

fs_claim:
    push ecx
    push esi
    xor ebx, ebx
.l: call fs_entry
    test byte [edi + DE_FLAGS], FLAG_USED
    jz .free
    inc ebx
    cmp ebx, FS_MAX_FILES
    jb .l
    mov eax, err_disk_full
    stc
    jmp .out
.free:
    push eax
    mov ecx, DE_SIZEOF
    xor eax, eax
    rep stosb
    sub edi, DE_SIZEOF
    pop eax
    mov esi, fs_leaf
    call str_copy
    mov byte [edi + DE_FLAGS], FLAG_USED
    mov [edi + DE_PARENT], al
    clc
.out:
    pop esi
    pop ecx
    ret

fs_check_tree:
    pushad
    xor ebx, ebx
.l: call fs_entry
    test byte [edi + DE_FLAGS], FLAG_USED
    jz .n
    test byte [edi + DE_FLAGS], FLAG_DIR
    jz .walk
    mov dword [edi + DE_SIZE], 0
.walk:
    movzx eax, byte [edi + DE_PARENT]
    mov ecx, FS_MAX_FILES + 1
.up:
    test eax, eax
    jz .n
    cmp eax, FS_MAX_FILES
    ja .orphan
    mov edx, eax
    shl edx, 5
    add edx, FS_DIR - DE_SIZEOF
    test byte [edx + DE_FLAGS], FLAG_USED
    jz .orphan
    test byte [edx + DE_FLAGS], FLAG_DIR
    jz .orphan
    movzx eax, byte [edx + DE_PARENT]
    loop .up
.orphan:
    mov byte [edi + DE_PARENT], 0
.n: inc ebx
    cmp ebx, FS_MAX_FILES
    jb .l
    popad
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
    pushad
    call fs_resolve
    jc .fail
    call fs_leaf_check
    jc .fail
    push esi
    mov esi, fs_leaf
    call fs_lookup
    pop esi
    jnc .have
    call fs_claim
    jc .fail
.have:
    mov eax, err_is_folder
    test byte [edi + DE_FLAGS], FLAG_DIR
    jnz .fail
    mov [edi + DE_SIZE], ecx
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
.fail:
    mov [esp + 4], eax
    popad
    stc
    ret
.too_big:
    mov esi, err_too_big
    stc
    ret

fs_mkdir:
    pushad
    call fs_resolve
    jc .fail
    cmp byte [fs_leaf], 0
    je .exists
    call fs_leaf_check
    jc .fail
    push esi
    mov esi, fs_leaf
    call fs_lookup
    pop esi
    jnc .exists
    call fs_claim
    jc .fail
    or byte [edi + DE_FLAGS], FLAG_DIR
    call fs_timestamp
    mov [edi + DE_MTIME], eax
    call fs_commit
    mov [esp + 16], ebx
    popad
    clc
    ret
.exists:
    mov eax, err_exists
.fail:
    mov [esp + 4], eax
    popad
    stc
    ret

fs_make_parents:
    pushad
    call str_len
    cmp ecx, FS_PATH_MAX - 1
    jae .done
    mov edi, fs_tmp_path
    call str_copy
    mov edx, edi
.scan:
    mov al, [edx]
    test al, al
    jz .done
    cmp al, '/'
    jne .next
    cmp edx, fs_tmp_path
    je .next
    mov byte [edx], 0
    mov esi, fs_tmp_path
    call fs_find_dir
    jnc .there
    cmp eax, err_no_folder
    jne .fail
    call fs_mkdir
    mov eax, esi
    jc .fail
.there:
    mov byte [edx], '/'
.next:
    inc edx
    jmp .scan
.done:
    popad
    clc
    ret
.fail:
    mov [esp + 4], eax
    popad
    stc
    ret

fs_delete:
    pushad
    call fs_entry
    test byte [edi + DE_FLAGS], FLAG_DIR
    jz .go
    lea eax, [ebx + 1]
    call fs_dir_count
    test ecx, ecx
    jnz .not_empty
    cmp [fs_cwd], eax
    jne .go
    movzx eax, byte [edi + DE_PARENT]
    mov [fs_cwd], eax
.go:
    mov ecx, DE_SIZEOF
    xor eax, eax
    rep stosb
    call fs_commit
    popad
    clc
    ret
.not_empty:
    popad
    mov esi, err_not_empty
    stc
    ret

fs_rename:
    pushad
    call fs_resolve
    jc .fail
    cmp byte [fs_leaf], 0
    je .into
    push ebx
    push esi
    mov esi, fs_leaf
    call fs_lookup
    mov ecx, ebx
    pop esi
    pop ebx
    jc .new_name
    cmp ecx, ebx
    je .new_name
    push ebx
    mov ebx, ecx
    call fs_entry
    pop ebx
    test byte [edi + DE_FLAGS], FLAG_DIR
    jz .exists
    lea eax, [ecx + 1]
.into:
    call fs_entry
    push esi
    mov esi, edi
    mov edi, fs_leaf
    call str_copy
    mov esi, fs_leaf
    push ebx
    call fs_lookup
    mov ecx, ebx
    pop ebx
    pop esi
    jc .tree
    cmp ecx, ebx
    jne .exists
    jmp .tree
.new_name:
    call fs_leaf_check
    jc .fail
.tree:
    call fs_entry
    test byte [edi + DE_FLAGS], FLAG_DIR
    jz .apply
    call fs_inside
    jnc .apply
    mov eax, err_into_self
    jmp .fail
.apply:
    push eax
    mov ecx, FS_NAME_MAX + 1
    xor eax, eax
    rep stosb
    sub edi, FS_NAME_MAX + 1
    pop eax
    push esi
    mov esi, fs_leaf
    call str_copy
    pop esi
    mov [edi + DE_PARENT], al
    call fs_commit
    popad
    clc
    ret
.exists:
    mov eax, err_exists
.fail:
    mov [esp + 4], eax
    popad
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

fs_counts:
    push ebx
    push edi
    xor eax, eax
    xor ecx, ecx
    xor ebx, ebx
.l: call fs_entry
    test byte [edi + DE_FLAGS], FLAG_USED
    jz .n
    test byte [edi + DE_FLAGS], FLAG_DIR
    jz .file
    inc ecx
    jmp .n
.file:
    inc eax
.n: inc ebx
    cmp ebx, FS_MAX_FILES
    jb .l
    pop edi
    pop ebx
    ret
