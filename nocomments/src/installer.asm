INST_CHUNK  equ 64
GPT_SECTORS equ 34

%define CHS_H(l) (((l) / 63) % 255)
%define CHS_S(l) (((l) % 63) + 1)
%define CHS_C(l) ((l) / (255 * 63))
PART_LAST   equ PART_START + PART_SECTORS - 1

section .bss
alignb 4
tgt_index   resd 1
tgt_drive   resd 1
tgt_sectors resd 2
tgt_bio     resd 2
inst_files  resb 1
size_pad    resb 1
alignb 4
inst_pos    resd 1
inst_volid  resd 1

section .data
u_install       db "install", 0
q_copy_files    db "Copy your files to the new disk too?", 0
str_erase       db "ERASE", 0
inst_prompt     db "disk number> ", 0
erase_prompt    db "type ERASE> ", 0
dtype_names     dd dn_disk, dn_usb, dn_nvme, dn_sata, dn_ata, dn_scsi, dn_sd, dn_emmc
dn_disk         db "disk", 0
dn_usb          db "USB", 0
dn_nvme         db "NVMe SSD", 0
dn_sata         db "SATA", 0
dn_ata          db "IDE/ATA", 0
dn_scsi         db "SCSI", 0
dn_sd           db "SD card", 0
dn_emmc         db "eMMC", 0
st_ok           db "", 0
st_boot         db "MOOS is running from this disk", 0
st_small        db "too small - MOOS needs 5 MB", 0
st_readonly     db "read-only", 0
st_sector       db "sector size is not 512 bytes", 0

section .text

list_disks:
    cmp dword [bootinfo + BI.platform], PLATFORM_UEFI
    je efi_list_disks

    pushad
    movzx ecx, byte [0x475]
    cmp ecx, MAX_DISKS
    jbe .count_ok
    mov ecx, MAX_DISKS
.count_ok:
    xor ebx, ebx
    xor ebp, ebp
.drive:
    cmp ebx, ecx
    jae .done
    lea edx, [ebx + 0x80]
    call bios_drive_info
    jc .next
    mov edi, ebp
    shl edi, 5
    add edi, disk_tab
    mov [edi + DT_DRIVE], edx
    mov dword [edi + DT_DRIVE + 4], 0
    mov eax, [BOUNCE + 0x10]
    mov [edi + DT_SECTORS], eax
    mov eax, [BOUNCE + 0x14]
    mov [edi + DT_SECTORS + 4], eax
    movzx eax, word [BOUNCE + 0x18]
    test eax, eax
    jnz .bsize
    mov eax, 512
.bsize:
    mov [edi + DT_BSIZE], eax
    xor eax, eax
    test byte [BOUNCE + 2], 4
    jz .fixed
    or eax, DF_REMOVABLE
.fixed:
    cmp dl, [bootinfo + BI.drive]
    jne .not_boot
    or eax, DF_BOOT
.not_boot:
    mov [edi + DT_FLAGS], eax
    call bios_interface_type
    mov [edi + DT_TYPE], eax
    inc ebp
.next:
    inc ebx
    jmp .drive
.done:
    mov [disk_count], ebp
    mov [esp + 28], ebp
    popad
    ret

bios_interface_type:
    mov eax, DTYPE_DISK
    cmp word [BOUNCE + 0x1E], 0xBEDD
    jne .r
    cmp dword [BOUNCE + 0x28], 'USB '
    je .usb
    cmp dword [BOUNCE + 0x28], 'SATA'
    je .sata
    cmp dword [BOUNCE + 0x28], 'ATA '
    je .ata
    cmp dword [BOUNCE + 0x28], 'SCSI'
    je .scsi
    cmp dword [BOUNCE + 0x28], 'NVME'
    je .nvme
.r: ret
.usb:   mov eax, DTYPE_USB
        ret
.sata:  mov eax, DTYPE_SATA
        ret
.ata:   mov eax, DTYPE_ATA
        ret
.scsi:  mov eax, DTYPE_SCSI
        ret
.nvme:  mov eax, DTYPE_NVME
        ret

disk_status:
    mov esi, st_boot
    test dword [edi + DT_FLAGS], DF_BOOT
    jnz .bad
    mov esi, st_sector
    cmp dword [edi + DT_BSIZE], 512
    jne .bad
    mov esi, st_readonly
    test dword [edi + DT_FLAGS], DF_READONLY
    jnz .bad
    mov esi, st_small
    cmp dword [edi + DT_SECTORS + 4], 0
    jne .ok
    cmp dword [edi + DT_SECTORS], MOOS_DISK_SECTORS
    jb .bad
.ok:
    mov esi, st_ok
    cmp esi, esi
    ret
.bad:
    or esi, esi
    ret

print_size:
    pushad
    shrd eax, edx, 11
    shr edx, 11
    test edx, edx
    jz .mb_ok
    mov eax, 0xFFFFFFFF
.mb_ok:
    cmp eax, 10240
    jae .gb
    cmp byte [size_pad], 0
    je .mb_plain
    PRINTF `%7d MB`, eax
    popad
    ret
.mb_plain:
    PRINTF `%d MB`, eax
    popad
    ret
.gb:
    xor edx, edx
    mov ecx, 1024
    div ecx
    imul edx, edx, 10
    shr edx, 10
    cmp byte [size_pad], 0
    je .gb_plain
    PRINTF `%5d.%d GB`, eax, edx
    popad
    ret
.gb_plain:
    PRINTF `%d.%d GB`, eax, edx
    popad
    ret

cmd_install:
    cmp byte [disk_mode], DISK_NONE
    jne .can_read
    PRINTF `\x01rerror:\x01n the installer copies MOOS from the disk it started from, but that\n`
    PRINTF `disk cannot be read here (MOOS is running in RAM-only mode).\n`
    ret
.can_read:
    PRINTF `\x01wMOOS installer\x01n - copies MOOS onto another disk so this computer can start\n`
    PRINTF `from it. Disks this computer has:\n\n`
    call list_disks
    test eax, eax
    jz .no_disks
    PRINTF `\x01w  #  type        size        \x01n\n`
    mov byte [size_pad], 1
    xor ebx, ebx
.show:
    cmp ebx, [disk_count]
    jae .shown
    mov edi, ebx
    shl edi, 5
    add edi, disk_tab
    mov eax, [edi + DT_TYPE]
    and eax, 7
    mov ecx, [dtype_names + eax * 4]
    lea eax, [ebx + 1]
    PRINTF `  \x01c%d\x01n  %10s`, eax, ecx
    mov eax, [edi + DT_SECTORS]
    mov edx, [edi + DT_SECTORS + 4]
    call print_size
    test dword [edi + DT_FLAGS], DF_REMOVABLE
    jz .not_removable
    PRINTF `  removable`
.not_removable:
    call disk_status
    je .usable
    PRINTF `  \x01d(%s)\x01n`, esi
.usable:
    PRINTF `\n`
    inc ebx
    jmp .show
.shown:
    mov byte [size_pad], 0
    PRINTF `\nWhich disk should MOOS be installed on? Type its number, or just press Enter\n`
    PRINTF `to cancel.\n`
    mov esi, inst_prompt
    mov bl, C_HEADING
    xor bh, bh
    call readline
    test eax, eax
    jnz .cancel
    mov esi, line_buf
    call skip_spaces
    cmp byte [esi], 0
    je .cancel
    call parse_uint
    jc .bad_number
    test eax, eax
    jz .bad_number
    cmp eax, [disk_count]
    ja .bad_number
    dec eax
    mov [tgt_index], eax
    mov edi, eax
    shl edi, 5
    add edi, disk_tab
    call disk_status
    jne .unusable
    mov eax, [edi + DT_SECTORS]
    mov [tgt_sectors], eax
    mov eax, [edi + DT_SECTORS + 4]
    mov [tgt_sectors + 4], eax
    mov eax, [edi + DT_DRIVE]
    mov [tgt_drive], eax
    mov [tgt_bio], eax
    mov eax, [edi + DT_HANDLE + 4]
    mov [tgt_bio + 4], eax
    push edi
    call same_disk_check
    pop edi
    jc .itself

    mov eax, [edi + DT_TYPE]
    and eax, 7
    mov ecx, [dtype_names + eax * 4]
    mov eax, [tgt_index]
    inc eax
    PRINTF `\n\x01rWARNING:\x01n everything on disk %d (%s, `, eax, ecx
    mov eax, [tgt_sectors]
    mov edx, [tgt_sectors + 4]
    call print_size
    PRINTF `) will be \x01rERASED\x01n: all its\n`
    PRINTF `partitions and files, and any other operating system on it.\n`
    PRINTF `Type \x01wERASE\x01n (in capitals) to continue. Anything else cancels.\n`
    mov esi, erase_prompt
    mov bl, 0x0C
    xor bh, bh
    call readline
    test eax, eax
    jnz .cancel
    mov esi, line_buf
    call skip_spaces
    mov edi, str_erase
.cmp:
    mov al, [esi]
    cmp al, [edi]
    jne .cancel
    inc esi
    inc edi
    test al, al
    jnz .cmp

    mov byte [inst_files], 0
    call fs_stats
    test eax, eax
    jz .install
    PRINTF `You have %d file(s). `, eax
    mov esi, q_copy_files
    call confirm
    jc .install
    mov byte [inst_files], 1
.install:
    call do_install
    ret

.no_disks:
    PRINTF `No disks were found.\n`
    ret
.bad_number:
    PRINTF `That is not one of the numbers in the list. Nothing was changed.\n`
    ret
.unusable:
    PRINTF `MOOS cannot be installed on that disk (%s). Nothing was changed.\n`, esi
    ret
.itself:
    PRINTF `That disk holds the very copy of MOOS that is running now, so it cannot be\n`
    PRINTF `the target. Nothing was changed.\n`
    ret
.cancel:
    PRINTF `Cancelled - nothing was changed.\n`
    ret

same_disk_check:
    pushad
    xor eax, eax
    mov ecx, 1
    mov edi, SCRATCH
    call part_read
    jc .different
    mov ebx, [SCRATCH + 39]
    mov eax, PART_START
    mov ecx, 1
    mov edi, SCRATCH
    call tgt_read
    jc .different
    cmp dword [SCRATCH + 3], 'MOOS'
    jne .different
    cmp [SCRATCH + 39], ebx
    jne .different
    popad
    stc
    ret
.different:
    popad
    clc
    ret

tgt_write:
    cmp dword [bootinfo + BI.platform], PLATFORM_UEFI
    je .uefi
    pushad
    mov bl, 0x43
    mov dl, [tgt_drive]
    call bios_rw
    popad
    ret
.uefi:
    push dword [efi_cur_bio + 4]
    push dword [efi_cur_bio]
    push eax
    mov eax, [tgt_bio]
    mov [efi_cur_bio], eax
    mov eax, [tgt_bio + 4]
    mov [efi_cur_bio + 4], eax
    pop eax
    call efi_write
    pop dword [efi_cur_bio]
    pop dword [efi_cur_bio + 4]
    ret

tgt_read:
    cmp dword [bootinfo + BI.platform], PLATFORM_UEFI
    je .uefi
    pushad
    mov esi, edi
    mov bl, 0x42
    mov dl, [tgt_drive]
    call bios_rw
    popad
    ret
.uefi:
    push dword [efi_cur_bio + 4]
    push dword [efi_cur_bio]
    push eax
    mov eax, [tgt_bio]
    mov [efi_cur_bio], eax
    mov eax, [tgt_bio + 4]
    mov [efi_cur_bio + 4], eax
    pop eax
    call efi_read
    pop dword [efi_cur_bio]
    pop dword [efi_cur_bio + 4]
    ret

zero_scratch:
    pushad
    mov edi, SCRATCH
    mov ecx, INST_CHUNK * 512 / 4
    xor eax, eax
    rep stosd
    popad
    ret

progress:
    pushad
    mov dword [cur_x], 0
    mov eax, [inst_pos]
    imul eax, 100
    xor edx, edx
    mov ecx, PART_SECTORS
    div ecx
    mov ebx, eax
    PRINTF `  copying  [`
    lea eax, [ebx * 2]
    xor edx, edx
    mov ecx, 5
    div ecx
    mov edx, eax
    mov ecx, 40
.bar:
    mov al, 0xDB
    cmp edx, 0
    jg .mark
    mov al, 0xB0
.mark:
    call vga_putc_raw
    dec edx
    loop .bar
    PRINTF `]  %3d%%`, ebx
    call screen_present
    popad
    ret

do_install:
    mov dword [disk_lba_hi], 0
    PRINTF `\nInstalling. Do not turn the computer off.\n`

    call zero_scratch
    mov eax, 1
.gap:
    cmp eax, PART_START
    jae .gap_done
    mov ecx, PART_START
    sub ecx, eax
    cmp ecx, INST_CHUNK
    jbe .gap_n
    mov ecx, INST_CHUNK
.gap_n:
    mov esi, SCRATCH
    call tgt_write
    jc .failed
    add eax, ecx
    jmp .gap
.gap_done:

    mov dword [inst_pos], 0
.copy:
    mov eax, [inst_pos]
    cmp eax, PART_SECTORS
    jae .copied
    call progress
    mov ecx, INST_CHUNK
    mov edi, SCRATCH
    call part_read
    jc .read_failed
    cmp dword [inst_pos], 0
    jne .not_vbr
    mov edx, [SCRATCH + 39]
    mov [inst_volid], edx
    rdtsc
    xor eax, [ticks]
    cmp eax, [inst_volid]
    jne .new_id
    inc eax
.new_id:
    mov [SCRATCH + 39], eax
    mov dword [SCRATCH + 28], PART_START
    mov eax, [inst_pos]
.not_vbr:
    cmp byte [inst_files], 0
    jne .write_chunk
    mov edx, PART_FS_LBA
    sub edx, eax
    js .write_chunk
    cmp edx, INST_CHUNK
    jae .write_chunk
    shl edx, 9
    mov dword [SCRATCH + edx], 0
    mov dword [SCRATCH + edx + 4], 0
.write_chunk:
    add eax, PART_START
    mov esi, SCRATCH
    call tgt_write
    jc .failed
    add dword [inst_pos], INST_CHUNK
    jmp .copy
.copied:
    call progress
    PRINTF `\n`

    call zero_scratch
    mov eax, [tgt_sectors]
    mov edx, [tgt_sectors + 4]
    test edx, edx
    jnz .wipe_end
    cmp eax, MOOS_DISK_SECTORS + GPT_SECTORS
    jb .mbr
.wipe_end:
    sub eax, GPT_SECTORS
    sbb edx, 0
    mov [disk_lba_hi], edx
    mov ecx, GPT_SECTORS
    mov esi, SCRATCH
    call tgt_write
    mov dword [disk_lba_hi], 0
    jc .failed

.mbr:
    mov esi, mbr_template
    mov edi, SCRATCH
    mov ecx, 512
    rep movsb
    rdtsc
    mov [SCRATCH + 440], eax
    mov word [SCRATCH + 444], 0
    mov edi, SCRATCH + 446
    mov byte [edi], 0x80
    mov byte [edi + 1], CHS_H(PART_START)
    mov byte [edi + 2], CHS_S(PART_START) | ((CHS_C(PART_START) >> 2) & 0xC0)
    mov byte [edi + 3], CHS_C(PART_START) & 0xFF
    mov byte [edi + 4], 0xEF
    mov byte [edi + 5], CHS_H(PART_LAST)
    mov byte [edi + 6], CHS_S(PART_LAST) | ((CHS_C(PART_LAST) >> 2) & 0xC0)
    mov byte [edi + 7], CHS_C(PART_LAST) & 0xFF
    mov dword [edi + 8], PART_START
    mov dword [edi + 12], PART_SECTORS
    mov word [SCRATCH + 510], 0xAA55
    xor eax, eax
    mov ecx, 1
    mov esi, SCRATCH
    call tgt_write
    jc .failed

    PRINTF `  checking ... `
    call screen_present
    xor eax, eax
    mov ecx, 1
    mov edi, SCRATCH + 0x8000
    call tgt_read
    jc .failed
    mov esi, SCRATCH
    mov edi, SCRATCH + 0x8000
    mov ecx, 128
    repe cmpsd
    jne .verify_failed
    mov eax, PART_START
    mov ecx, 1
    mov edi, SCRATCH + 0x8000
    call tgt_read
    jc .failed
    cmp dword [SCRATCH + 0x8000 + 3], 'MOOS'
    jne .verify_failed
    PRINTF `\x01gok\x01n\n\n`
    mov eax, [tgt_index]
    inc eax
    PRINTF `\x01gDone!\x01n MOOS is installed on disk %d.\n`, eax
    PRINTF `Remove the USB stick (or other disk MOOS started from) and type \x01wreboot\x01n.\n`
    PRINTF `If the computer does not start MOOS by itself, choose the disk in its boot menu\n`
    PRINTF `(often F12, F11, F10, F8 or Esc). See \x01wman install\x01n for help.\n`
    ret

.read_failed:
    PRINTF `\n\x01rerror:\x01n could not read MOOS from the disk it started from.\n`
    jmp .stopped
.verify_failed:
    PRINTF `\n\x01rerror:\x01n the disk did not keep what was written to it.\n`
    jmp .stopped
.failed:
    mov dword [disk_lba_hi], 0
    PRINTF `\n\x01rerror:\x01n writing to the disk failed.\n`
.stopped:
    PRINTF `The installation did not finish, so the disk will not start MOOS. You can\n`
    PRINTF `run \x01winstall\x01n again, or use another disk.\n`
    ret
