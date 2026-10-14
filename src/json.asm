; =============================================================================
;  json.asm - JSON reader: turn a JSON text into a flat list of tokens
;
;  JSON (ECMA-404, RFC 8259) is made of objects { "key": value, ... },
;  arrays [ value, ... ], strings "..." (with backslash escapes) and the
;  primitives: numbers, true, false and null. json_parse reads a whole text
;  in one pass, checks it against the grammar, and writes one 16-byte token
;  (JTOK) for every value and every object key, in the order they appear
;  ("jsmn style": nothing is copied or converted, a token only says where
;  its text is):
;
;    JTOK  +0  u8   type: 1 object, 2 array, 3 string, 4 primitive
;          +1  u8   pad[3] (0)
;          +4  u32  start: offset of the first byte (strings: after the quote)
;          +8  u32  end: offset just past the last byte (strings: of the
;                   closing quote, so end - start is the raw length)
;          +12 u32  next: index of the first token after this one's whole
;                   subtree (its children, their children, ...)
;
;  A key is a string token directly inside an object; its value follows it
;  and counts as part of its subtree (as in jsmn, the value is the key's
;  child), so a key's next is its value's next. The members of an object
;  and the elements of an array are therefore all walked the same way:
;  from the token after the container, follow next until the container's
;  next. For example  {"a":[1,2],"b":null}  (20 bytes) gives 7 tokens:
;
;    index  type       start end  next
;      0    object       0    20    7      the whole text
;      1    string a     2     3    5      key; its value is tokens 2-4
;      2    array        5    10    5
;      3    primitive 1  6     7    4
;      4    primitive 2  8     9    5
;      5    string b    12    13    7      key; its value is token 6
;      6    primitive   15    19    7      null
;
;  so the members of the object are at 1 (then next = 5) and 5 (then
;  next = 7 = the object's next: done).
;
;  Then json_key / json_index find members and elements, json_str decodes
;  a string (escapes, including \uXXXX and surrogate pairs, to UTF-8),
;  json_int reads an integer, and json_eq compares a string with a C string.
;
;  How json_parse works: one loop over the bytes with a small stack of open
;  containers (at most JSON_MAXDEPTH = 1000 deep; deeper is refused, so a
;  hostile text cannot use up memory or time). A container's token is
;  written when it opens and finished (end, next) when it closes. Inside a
;  string the bytes are checked 16 at a time with SSE2 (looking for the
;  closing quote, a backslash or a control character), which is where most
;  of the bytes of a real document (URLs, titles) are. Bytes 0x80-0xFF are
;  passed through unchecked (UTF-8 is not validated).
;
;  Everything stays inside the given text and token buffers whatever the
;  input says; a bad text gives an error code, never a crash or a hang.
;  Module rules: tests/native/README.md.
; =============================================================================
%include "src/module.inc"

; ---- JTOK -------------------------------------------------------------------
JSON_TYPE       equ 0               ; byte: JSON_T_*
JSON_START      equ 4
JSON_END        equ 8
JSON_NEXT       equ 12
JSON_TOK        equ 16              ; bytes per token
JSON_T_OBJECT   equ 1
JSON_T_ARRAY    equ 2
JSON_T_STRING   equ 3
JSON_T_PRIM     equ 4

; ---- results ----------------------------------------------------------------
JSON_EINVAL     equ -1              ; not JSON (json_str: a bad escape)
JSON_ENOTOK     equ -2              ; more tokens than maxtoks (json_str: out
                                    ; too small; json_int: out of range)
JSON_EPART      equ -3              ; the text ends early (more could follow)
JSON_EDEEP      equ -4              ; nested deeper than JSON_MAXDEPTH
JSON_MAXDEPTH   equ 1000

; ---- a frame of the container stack (16 bytes) ---------------------------------
JSON_F_KIND     equ 0               ; 0 the top level, 1 object, 2 array
JSON_F_TOK      equ 4               ; the container's token
JSON_F_KEY      equ 8               ; object: the key whose value comes now

section .data
; json_class: what a byte can start (json_parse's value dispatch)
;   0 nothing (an error)  1 whitespace  2 string  3 object  4 array
;   5 true / false / null  6 number
json_class:
%assign json_c 0
%rep 256
  %if json_c == ' ' || json_c == 9 || json_c == 10 || json_c == 13
    db 1
  %elif json_c == '"'
    db 2
  %elif json_c == '{'
    db 3
  %elif json_c == '['
    db 4
  %elif json_c == 't' || json_c == 'f' || json_c == 'n'
    db 5
  %elif json_c == '-' || (json_c >= '0' && json_c <= '9')
    db 6
  %else
    db 0
  %endif
  %assign json_c json_c + 1
%endrep
; json_hexval: value of a hex digit, 0xFF for any other byte
json_hexval:
%assign json_c 0
%rep 256
  %if json_c >= '0' && json_c <= '9'
    db json_c - '0'
  %elif json_c >= 'a' && json_c <= 'f'
    db json_c - 'a' + 10
  %elif json_c >= 'A' && json_c <= 'F'
    db json_c - 'A' + 10
  %else
    db 0xFF
  %endif
  %assign json_c json_c + 1
%endrep
; json_escval: the byte a one-letter escape stands for (\" \\ \/ \b \f \n
; \r \t), 0 for letters that are not escapes (\u is handled apart)
json_escval:
%assign json_c 0
%rep 256
  %if json_c == '"' || json_c == '\' || json_c == '/'
    db json_c
  %elif json_c == 'b'
    db 8
  %elif json_c == 'f'
    db 12
  %elif json_c == 'n'
    db 10
  %elif json_c == 'r'
    db 13
  %elif json_c == 't'
    db 9
  %else
    db 0
  %endif
  %assign json_c json_c + 1
%endrep
json_words:     db "true", "null", "false"
align 4
json_vjump:     dd json_parse.inval, json_parse.inval, json_parse.string
                dd json_parse.object, json_parse.array, json_parse.literal
                dd json_parse.number

section .bss
alignb 16
json_dummy      resb JSON_TOK       ; the token "written" when only counting
json_stack      resb (JSON_MAXDEPTH + 1) * 16   ; open containers (frame 0 = top)
json_base       resd 1              ; json_parse: start of the text
json_max        resd 1              ;   tokens that fit (0xFFFFFFFF: counting)
json_stride     resd 1              ;   16, or 0 when counting

section .text

; -----------------------------------------------------------------------------
; JSON_SKIPWS label: move ESI past spaces, tabs, CR and LF (up to EBX, the
;   end of the text); at the end of the text, jump to label. Otherwise EAX
;   = the byte at ESI (not whitespace). Uses EAX ECX.
; -----------------------------------------------------------------------------
%macro JSON_SKIPWS 1
%%look:
    cmp esi, ebx
    jae %1
    movzx eax, byte [esi]
    cmp al, ' '
    ja %%done                       ; (most bytes: above space)
    je %%skip
    mov ecx, (1 << 9) | (1 << 10) | (1 << 13)   ; tab, LF, CR
    bt ecx, eax
    jnc %%done                      ; another control byte: the caller refuses it
%%skip:
    inc esi
    jmp %%look
%%done:
%endmacro

; -----------------------------------------------------------------------------
; int json_parse(const char *js, uint32_t len, JTOK *toks, uint32_t maxtoks)
;   Reads the JSON text js (len bytes: one value, with optional whitespace
;   around it) into toks (room for maxtoks tokens). toks = NULL only counts
;   the tokens (maxtoks is then ignored).
;   Returns the number of tokens (>= 1), or JSON_EINVAL (-1) not valid
;   JSON, JSON_ENOTOK (-2) more than maxtoks tokens, JSON_EPART (-3) the
;   text ends before the value does (only whitespace, an open string,
;   container or number...), JSON_EDEEP (-4) objects/arrays nested more
;   than 1000 deep. After an error the tokens written so far mean nothing.
;   In the loop: ESI = position, EBX = end of the text, EDI = next token
;   slot, EDX = tokens so far, EBP = frame of the innermost open container,
;   XMM5/6/7 = 16 x '"', '\', 0x1F (for the string scan).
; -----------------------------------------------------------------------------
EXPORT(json_parse)
json_parse:
    CENTER
    mov esi, ARG(0)
    mov ebx, ARG(1)
    add ebx, esi                    ; EBX = end of the text
    jc .inval                       ; (a length that wraps around)
    mov [json_base], esi
    mov edi, ARG(2)
    mov eax, ARG(3)
    mov ecx, JSON_TOK
    test edi, edi
    jnz .store
    mov edi, json_dummy             ; counting: every token goes to one dummy
    mov eax, -1                     ; slot, and there is no limit
    xor ecx, ecx
.store:
    mov [json_max], eax
    mov [json_stride], ecx
    mov eax, 0x22222222             ; the string scan's constants
    movd xmm5, eax
    pshufd xmm5, xmm5, 0
    mov eax, 0x5C5C5C5C
    movd xmm6, eax
    pshufd xmm6, xmm6, 0
    mov eax, 0x1F1F1F1F
    movd xmm7, eax
    pshufd xmm7, xmm7, 0
    xor edx, edx
    mov ebp, json_stack
    mov dword [ebp + JSON_F_KIND], 0

; ---- a value must come next
.value:
    JSON_SKIPWS .part
    movzx ecx, byte [json_class + eax]
    jmp [json_vjump + ecx * 4]

; ---- a value has just ended (ESI = the byte after it)
.after:
    cmp dword [ebp + JSON_F_KIND], JSON_T_OBJECT
    jne .after2
    mov ecx, [ebp + JSON_F_KEY]     ; in an object: the key's subtree ends
    mov [ecx + JSON_NEXT], edx      ; with its value
.after2:
    JSON_SKIPWS .afterend
    cmp al, ','
    je .comma
    cmp al, '}'
    je .closeobj
    cmp al, ']'
    je .closearr
    jmp .inval                      ; (also anything after the top value)
.afterend:
    cmp dword [ebp + JSON_F_KIND], 0
    jne .part                       ; containers still open
    mov eax, edx                    ; done: the number of tokens
    CLEAVE
.comma:
    mov ecx, [ebp + JSON_F_KIND]
    inc esi
    cmp ecx, JSON_T_ARRAY
    je .value                       ; array: the next element
    cmp ecx, JSON_T_OBJECT
    jne .inval                      ; (a comma at the top level)
    JSON_SKIPWS .part               ; object: the next key
    cmp al, '"'
    je .key
    jmp .inval
.closeobj:
    cmp dword [ebp + JSON_F_KIND], JSON_T_OBJECT
    je .close
    jmp .inval
.closearr:
    cmp dword [ebp + JSON_F_KIND], JSON_T_ARRAY
    jne .inval
.close:                             ; ESI at the closing bracket of frame EBP
    mov ecx, [ebp + JSON_F_TOK]
    inc esi
    mov eax, esi
    sub eax, [json_base]
    mov [ecx + JSON_END], eax
    mov [ecx + JSON_NEXT], edx
    sub ebp, 16
    jmp .after

; ---- { and [
.object:
    mov ecx, JSON_T_OBJECT
    jmp .open
.array:
    mov ecx, JSON_T_ARRAY
.open:
    cmp edx, [json_max]
    jae .notok
    cmp ebp, json_stack + JSON_MAXDEPTH * 16
    jae .deep
    add ebp, 16                     ; a new frame
    mov [ebp + JSON_F_KIND], ecx
    mov [ebp + JSON_F_TOK], edi
    mov [edi + JSON_TYPE], ecx      ; (type, and 0 in the pad bytes)
    mov eax, esi
    sub eax, [json_base]
    mov [edi + JSON_START], eax
    add edi, [json_stride]
    inc edx
    inc esi
    push ecx
    JSON_SKIPWS .partpop
    pop ecx
    cmp ecx, JSON_T_OBJECT
    je .objfirst
    cmp al, ']'
    je .close                       ; []
    jmp .value
.objfirst:
    cmp al, '}'
    je .close                       ; {}
    cmp al, '"'
    jne .inval
.key:                               ; ESI at the quote of a key
    cmp edx, [json_max]
    jae .notok
    mov [ebp + JSON_F_KEY], edi
    call .str
    jc .ret
    JSON_SKIPWS .part
    cmp al, ':'
    jne .inval
    inc esi
    jmp .value
.partpop:
    pop ecx
    jmp .part

; ---- "string" as a value
.string:
    cmp edx, [json_max]
    jae .notok
    call .str
    jc .ret
    jmp .after

; ---- true, false, null
.literal:
    cmp edx, [json_max]
    jae .notok
    mov ecx, ebx
    sub ecx, esi                    ; ECX = bytes left
    cmp al, 'f'
    je .lfalse
    cmp ecx, 4
    jb .lshort
    mov eax, [esi]
    cmp eax, 'true'
    je .l4
    cmp eax, 'null'
    jne .inval
.l4:
    mov ecx, 4
    jmp .lok
.lfalse:
    cmp ecx, 5
    jb .lshort
    cmp dword [esi + 1], 'alse'
    jne .inval
    mov ecx, 5
.lok:                               ; a primitive of ECX bytes at ESI
    mov dword [edi + JSON_TYPE], JSON_T_PRIM
    mov eax, esi
    sub eax, [json_base]
    mov [edi + JSON_START], eax
    add eax, ecx
    mov [edi + JSON_END], eax
    add esi, ecx
    inc edx
    mov [edi + JSON_NEXT], edx
    add edi, [json_stride]
    jmp .after
.lshort:                            ; the text ends inside the word: part of
    push edi                        ; one (more may follow) or not a word
    mov edi, json_words             ; "true"
    cmp al, 'n'
    jne .lsh2
    add edi, 4                      ; "null"
.lsh2:
    cmp al, 'f'
    jne .lsh3
    add edi, 8                      ; "false"
.lsh3:
    mov al, [esi]
    cmp al, [edi]
    jne .lshbad
    inc esi
    inc edi
    dec ecx
    jnz .lsh3
    pop edi
    jmp .part
.lshbad:
    pop edi
    jmp .inval

; ---- numbers: -? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?
.number:
    cmp edx, [json_max]
    jae .notok
    mov ecx, esi                    ; ECX = where it starts
    cmp al, '-'
    jne .nint
    inc esi
    cmp esi, ebx
    jae .part
    movzx eax, byte [esi]
.nint:
    cmp al, '0'
    je .nzero
    sub eax, '1'
    cmp eax, 8
    ja .inval                       ; (a minus without a digit)
.ndig:                              ; the integer part
    inc esi
    cmp esi, ebx
    jae .ndone
    movzx eax, byte [esi]
    sub eax, '0'
    cmp eax, 9
    jbe .ndig
    jmp .nfrac
.nzero:                             ; 0: no more digits may follow
    inc esi
    cmp esi, ebx
    jae .ndone
.nfrac:
    movzx eax, byte [esi]
    cmp al, '.'
    jne .nexp
    inc esi                         ; a fraction: at least one digit
    cmp esi, ebx
    jae .part
    movzx eax, byte [esi]
    sub eax, '0'
    cmp eax, 9
    ja .inval
.nfdig:
    inc esi
    cmp esi, ebx
    jae .ndone
    movzx eax, byte [esi]
    sub eax, '0'
    cmp eax, 9
    jbe .nfdig
    movzx eax, byte [esi]
.nexp:
    or al, 0x20                     ; (E -> e)
    cmp al, 'e'
    jne .ndone
    inc esi                         ; an exponent: sign, at least one digit
    cmp esi, ebx
    jae .part
    movzx eax, byte [esi]
    cmp al, '+'
    je .nsign
    cmp al, '-'
    jne .nedig1
.nsign:
    inc esi
    cmp esi, ebx
    jae .part
    movzx eax, byte [esi]
.nedig1:
    sub eax, '0'
    cmp eax, 9
    ja .inval
.nedig:
    inc esi
    cmp esi, ebx
    jae .ndone
    movzx eax, byte [esi]
    sub eax, '0'
    cmp eax, 9
    jbe .nedig
.ndone:                             ; the number is ECX..ESI
    mov dword [edi + JSON_TYPE], JSON_T_PRIM
    mov eax, ecx
    sub eax, [json_base]
    mov [edi + JSON_START], eax
    mov eax, esi
    sub eax, [json_base]
    mov [edi + JSON_END], eax
    inc edx
    mov [edi + JSON_NEXT], edx
    add edi, [json_stride]
    jmp .after

; ---- errors
.inval:
    mov eax, JSON_EINVAL
    jmp .ret
.notok:
    mov eax, JSON_ENOTOK
    jmp .ret
.part:
    mov eax, JSON_EPART
    jmp .ret
.deep:
    mov eax, JSON_EDEEP
.ret:
    CLEAVE

; .str: the string starting at the quote at ESI -> a string token at EDI
;   (next = the token after it), EDI and EDX advanced, ESI past the closing
;   quote; CF set and EAX = the error if the string is bad or not closed.
;   Uses EAX ECX, XMM0-XMM2.
.str:
    mov dword [edi + JSON_TYPE], JSON_T_STRING
    inc esi
    mov eax, esi
    sub eax, [json_base]
    mov [edi + JSON_START], eax
.sblock:                            ; 16 bytes at a time while 16 are left
    mov eax, ebx
    sub eax, esi
    cmp eax, 16
    jb .stail
    movdqu xmm0, [esi]
    movdqa xmm1, xmm0
    pcmpeqb xmm1, xmm5              ; quotes
    movdqa xmm2, xmm0
    pcmpeqb xmm2, xmm6              ; backslashes
    por xmm1, xmm2
    movdqa xmm2, xmm0
    pminub xmm2, xmm7
    pcmpeqb xmm2, xmm0              ; bytes 0x00-0x1F (min(b, 1F) = b)
    por xmm1, xmm2
    pmovmskb eax, xmm1
    test eax, eax
    jnz .shit
    add esi, 16
    jmp .sblock
.shit:
    bsf eax, eax                    ; the first byte that matters
    add esi, eax
    movzx eax, byte [esi]
    cmp al, '"'
    je .send
    cmp al, '\'
    je .sesc
    jmp .sbad                       ; a control character
.stail:                             ; the last bytes of the text, one by one
    cmp esi, ebx
    jae .spart
    movzx eax, byte [esi]
    cmp al, '"'
    je .send
    cmp al, '\'
    je .sesc
    cmp al, 0x20
    jb .sbad
    inc esi
    jmp .stail
.sesc:                              ; a backslash: check the escape
    inc esi
    cmp esi, ebx
    jae .spart
    movzx eax, byte [esi]
    cmp al, 'u'
    je .su
    cmp byte [json_escval + eax], 0
    je .sbad
    inc esi
    jmp .sblock
.su:                                ; \u and four hex digits
    mov ecx, 4
.suhex:
    inc esi
    cmp esi, ebx
    jae .spart
    movzx eax, byte [esi]
    cmp byte [json_hexval + eax], 0xFF
    je .sbad
    dec ecx
    jnz .suhex
    inc esi
    jmp .sblock
.send:                              ; ESI at the closing quote
    mov eax, esi
    sub eax, [json_base]
    mov [edi + JSON_END], eax
    inc edx
    mov [edi + JSON_NEXT], edx
    add edi, [json_stride]
    inc esi
    clc
    ret
.spart:
    mov eax, JSON_EPART
    stc
    ret
.sbad:
    mov eax, JSON_EINVAL
    stc
    ret

; -----------------------------------------------------------------------------
; json_hex4: EAX = the 4 hex digits at ESI (they must end by EDX), ESI moved
;   past them; CF set (ESI kept) if they are not 4 hex digits. Uses ECX.
; -----------------------------------------------------------------------------
json_hex4:
    lea ecx, [esi + 4]
    cmp ecx, edx
    ja .bad
    push ebx
    xor eax, eax
    mov ecx, 4
.dig:
    movzx ebx, byte [esi]
    movzx ebx, byte [json_hexval + ebx]
    cmp bl, 0xFF
    je .badpop
    shl eax, 4
    or eax, ebx
    inc esi
    dec ecx
    jnz .dig
    pop ebx
    clc
    ret
.badpop:
    sub esi, 4
    add esi, ecx                    ; (back to the first digit)
    pop ebx
.bad:
    stc
    ret

; -----------------------------------------------------------------------------
; json_unesc: decode one escape. In: ESI = the byte after the backslash,
;   EDX = end of the string. Out: CF clear: EAX = the character (a Unicode
;   code point; a \uD800-\uDBFF \uDC00-\uDFFF pair is joined into one, and
;   a surrogate without its partner becomes U+FFFD), ESI past the escape
;   (or the pair); CF set: not an escape. Uses ECX.
; -----------------------------------------------------------------------------
json_unesc:
    cmp esi, edx
    jae .bad
    movzx eax, byte [esi]
    inc esi
    cmp al, 'u'
    je .u
    movzx eax, byte [json_escval + eax]
    test eax, eax
    jz .bad
    clc
    ret
.u:
    call json_hex4
    jc .bad
    mov ecx, eax
    and ecx, 0xFC00
    cmp ecx, 0xDC00
    je .lone                        ; a low surrogate first
    cmp ecx, 0xD800
    jne .ok                         ; not a surrogate
    lea ecx, [esi + 6]              ; a high surrogate: is a low one next?
    cmp ecx, edx
    ja .lone
    cmp word [esi], '\u'
    jne .lone
    push eax
    add esi, 2
    call json_hex4
    jc .nolow
    mov ecx, eax
    and ecx, 0xFC00
    cmp ecx, 0xDC00
    jne .nolow4
    pop ecx                         ; the pair: 0x10000 + (hi - D800) << 10
    sub ecx, 0xD800                 ;                    + (lo - DC00)
    shl ecx, 10
    sub eax, 0xDC00
    add eax, ecx
    add eax, 0x10000
.ok:
    clc
    ret
.nolow4:
    sub esi, 4                      ; (not a low surrogate: leave that escape
.nolow:                             ; for next time)
    sub esi, 2
    pop eax
.lone:
    mov eax, 0xFFFD
    clc
    ret
.bad:
    stc
    ret

; -----------------------------------------------------------------------------
; json_utf8: EAX = a code point -> its UTF-8 bytes in EAX (first byte in AL,
;   then AH, ...), ECX = how many (1-4). Uses nothing else.
; -----------------------------------------------------------------------------
json_utf8:
    cmp eax, 0x80
    jae .two
    mov ecx, 1
    ret
.two:
    push edx
    cmp eax, 0x800
    jae .three
    mov edx, eax                    ; 110xxxxx 10xxxxxx
    shr edx, 6
    or edx, 0xC0
    and eax, 0x3F
    or eax, 0x80
    shl eax, 8
    or eax, edx
    mov ecx, 2
    pop edx
    ret
.three:
    cmp eax, 0x10000
    jae .four
    mov edx, eax                    ; 1110xxxx 10xxxxxx 10xxxxxx
    and edx, 0x3F
    or edx, 0x80
    shl edx, 16
    mov ecx, eax
    shr ecx, 6
    and ecx, 0x3F
    or ecx, 0x80
    shl ecx, 8
    or edx, ecx
    shr eax, 12
    or eax, 0xE0
    or eax, edx
    mov ecx, 3
    pop edx
    ret
.four:                              ; 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
    mov edx, eax
    and edx, 0x3F
    or edx, 0x80
    shl edx, 24
    mov ecx, eax
    shr ecx, 6
    and ecx, 0x3F
    or ecx, 0x80
    shl ecx, 16
    or edx, ecx
    mov ecx, eax
    shr ecx, 12
    and ecx, 0x3F
    or ecx, 0x80
    shl ecx, 8
    or edx, ecx
    shr eax, 18
    and eax, 7
    or eax, 0xF0
    or eax, edx
    mov ecx, 4
    pop edx
    ret

; -----------------------------------------------------------------------------
; json_text: ESI = js, EBX = a token -> ESI = its text, EDX = the end of it;
;   CF set if the token's start is after its end. Uses nothing else.
; -----------------------------------------------------------------------------
json_text:
    mov edx, esi
    add esi, [ebx + JSON_START]
    add edx, [ebx + JSON_END]
    cmp edx, esi
    ret                             ; (CF = end below start)

; -----------------------------------------------------------------------------
; json_eqi: EAX = 1 if the token at EBX equals the C string at EDI, else 0.
;   A string token is compared as decoded (so "itag" equals "itag");
;   any other token by its raw text. In: ESI = js. Uses ECX EDX; keeps ESI
;   EDI EBX.
; -----------------------------------------------------------------------------
json_eqi:
    push esi
    push edi
    call json_text
    jc .no
    cmp byte [ebx + JSON_TYPE], JSON_T_STRING
    jne .raw
.str:                               ; (a 0 byte never matches: s ends there,
    cmp esi, edx                    ; so reading on would pass its end)
    jae .end
    movzx eax, byte [esi]
    cmp al, '\'
    je .esc
    cmp al, [edi]
    jne .no
    test al, al
    jz .no
    inc esi
    inc edi
    jmp .str
.esc:
    inc esi
    call json_unesc
    jc .no
    call json_utf8                  ; compare its 1-4 UTF-8 bytes
.escb:
    cmp al, [edi]
    jne .no
    test al, al                     ; (\u0000)
    jz .no
    inc edi
    shr eax, 8
    dec ecx
    jnz .escb
    jmp .str
.raw:
    cmp esi, edx
    jae .end
    mov al, [esi]
    cmp al, [edi]
    jne .no
    test al, al
    jz .no
    inc esi
    inc edi
    jmp .raw
.end:
    cmp byte [edi], 0               ; the C string must end here too
    jne .no
    mov eax, 1
    pop edi
    pop esi
    ret
.no:
    xor eax, eax
    pop edi
    pop esi
    ret

; -----------------------------------------------------------------------------
; int json_eq(const char *js, const JTOK *tok, const char *s)
;   1 if the token equals the NUL-terminated string s, 0 if not. A string
;   token is compared after decoding its escapes (s in UTF-8), a primitive
;   by its text (json_eq(js, tok, "true")).
; -----------------------------------------------------------------------------
EXPORT(json_eq)
json_eq:
    CENTER
    mov esi, ARG(0)
    mov ebx, ARG(1)
    mov edi, ARG(2)
    call json_eqi
    CLEAVE

; -----------------------------------------------------------------------------
; int json_key(const char *js, const JTOK *toks, int ntoks, int obj,
;              const char *key)
;   The index of the value of member key in the object token obj, or -1 if
;   it has none (or obj is not an object). If a key appears more than once
;   the last one counts (as in JavaScript's JSON.parse).
; -----------------------------------------------------------------------------
EXPORT(json_key)
json_key:
    CENTER
    sub esp, 8
    mov eax, ARG(3)
    mov ecx, ARG(2)
    cmp eax, ecx
    jae .none                       ; (also a negative obj or ntoks)
    mov ebx, eax
    shl ebx, 4
    add ebx, ARG(1)
    cmp byte [ebx + JSON_TYPE], JSON_T_OBJECT
    jne .none
    mov edx, [ebx + JSON_NEXT]      ; [EBP-16] = where the object ends
    cmp edx, ecx
    jbe .endok
    mov edx, ecx
.endok:
    mov [ebp - 16], edx
    mov dword [ebp - 20], -1        ; [EBP-20] = the last match
    lea ecx, [eax + 1]              ; ECX = the first key
    mov esi, ARG(0)
    mov edi, ARG(4)
.member:
    cmp ecx, [ebp - 16]
    jae .done
    mov ebx, ecx
    shl ebx, 4
    add ebx, ARG(1)
    cmp byte [ebx + JSON_TYPE], JSON_T_STRING
    jne .skip
    push ecx
    call json_eqi
    pop ecx
    test eax, eax
    jz .skip
    lea eax, [ecx + 1]
    cmp eax, [ebp - 16]
    jae .skip
    mov [ebp - 20], eax
.skip:
    mov eax, [ebx + JSON_NEXT]      ; on to the next key (always forward)
    cmp eax, ecx
    jbe .done
    mov ecx, eax
    jmp .member
.done:
    mov eax, [ebp - 20]
    add esp, 8
    CLEAVE
.none:
    mov eax, -1
    add esp, 8
    CLEAVE

; -----------------------------------------------------------------------------
; int json_index(const JTOK *toks, int ntoks, int arr, int i)
;   The index of element i (from 0) of the array token arr, or -1 if it has
;   fewer elements (or arr is not an array).
; -----------------------------------------------------------------------------
EXPORT(json_index)
json_index:
    CENTER
    mov eax, ARG(2)
    mov edx, ARG(1)
    cmp eax, edx
    jae .none
    mov esi, ARG(0)
    mov ebx, eax
    shl ebx, 4
    cmp byte [esi + ebx + JSON_TYPE], JSON_T_ARRAY
    jne .none
    mov edi, [esi + ebx + JSON_NEXT]   ; EDI = where the array ends
    cmp edi, edx
    jbe .endok
    mov edi, edx
.endok:
    mov ecx, ARG(3)                 ; ECX = elements still to step over
    inc eax                         ; EAX = the first element
.elem:
    cmp eax, edi
    jae .none
    test ecx, ecx
    jz .found
    mov ebx, eax
    shl ebx, 4
    mov ebx, [esi + ebx + JSON_NEXT]
    cmp ebx, eax
    jbe .none                       ; (tokens not from json_parse)
    mov eax, ebx
    dec ecx
    jmp .elem
.found:
    CLEAVE
.none:
    mov eax, -1
    CLEAVE

; -----------------------------------------------------------------------------
; int json_str(const char *js, const JTOK *tok, char *out, uint32_t cap)
;   The text of a token into out (cap bytes of room), always ended by a NUL
;   (if cap > 0). A string token is decoded: its escapes become the
;   characters they stand for, in UTF-8 (\uXXXX, surrogate pairs joined, a
;   lone surrogate as U+FFFD; \u0000 gives a 0 byte inside the text). Other
;   tokens are copied as they are (a number's digits, "true", or a whole
;   object's text). Returns the length (without the NUL), JSON_EINVAL (-1)
;   for a bad escape, or -2 if it does not fit (out then holds what fit:
;   the start, NUL-terminated, never half a character: an escape or a
;   UTF-8 sequence is kept whole or left out).
; -----------------------------------------------------------------------------
EXPORT(json_str)
json_str:
    CENTER
    mov esi, ARG(0)
    mov ebx, ARG(1)
    call json_text
    jc .bad
    mov edi, ARG(2)
    mov ecx, ARG(3)
    test ecx, ecx
    jz .full0
    lea ebx, [edi + ecx - 1]        ; EBX = the last byte (kept for the NUL)
    mov eax, ARG(1)
    cmp byte [eax + JSON_TYPE], JSON_T_STRING
    jne .raw
.plain:
    cmp esi, edx
    jae .done
    movzx eax, byte [esi]
    cmp al, '\'
    je .esc
    cmp edi, ebx
    jae .full
    mov [edi], al
    inc esi
    inc edi
    jmp .plain
.esc:
    inc esi
    call json_unesc
    jc .bad0
    call json_utf8                  ; EAX = its bytes, ECX = how many
    push ecx
    add ecx, edi
    cmp ecx, ebx
    pop ecx
    ja .full                        ; (the whole character or nothing)
.escb:
    mov [edi], al
    inc edi
    shr eax, 8
    dec ecx
    jnz .escb
    jmp .plain
.raw:
    cmp esi, edx
    jae .done
    cmp edi, ebx
    jae .full
    mov al, [esi]
    mov [edi], al
    inc esi
    inc edi
    jmp .raw
.done:
    mov byte [edi], 0
    mov eax, edi
    sub eax, ARG(2)
    CLEAVE
.full:
    ; out is full at EDI. Do not leave the first bytes of a UTF-8
    ; character at the end: step back over the continuation bytes
    ; (10xxxxxx, at most 3) to the lead byte, and if the character it
    ; starts is longer than what is there, cut it off.
    mov ecx, ARG(2)                 ; ECX = start of out
    mov esi, edi                    ; ESI = scanning back
    xor edx, edx                    ; EDX = continuation bytes seen
.fback:
    cmp esi, ecx
    jbe .fend                       ; (only continuation bytes: leave them)
    dec esi
    movzx eax, byte [esi]
    mov ebx, eax
    and ebx, 0xC0
    cmp ebx, 0x80
    jne .flead
    inc edx
    cmp edx, 3
    jbe .fback
    jmp .fend                       ; (4 or more: not UTF-8, leave them)
.flead:                             ; ESI = the byte before them, EAX its value
    cmp eax, 0xC0
    jb .fend                        ; (ASCII: the end is a whole character)
    mov ebx, 2                      ; EBX = the length the lead byte gives
    cmp eax, 0xE0
    jb .flen
    inc ebx
    cmp eax, 0xF0
    jb .flen
    inc ebx
.flen:
    inc edx                         ; EDX = bytes of it that are there
    cmp edx, ebx
    jae .fend
    mov edi, esi                    ; incomplete: cut at its lead byte
.fend:
    mov byte [edi], 0
.full0:
    mov eax, -2
    CLEAVE
.bad0:
    mov byte [edi], 0
.bad:
    mov eax, JSON_EINVAL
    CLEAVE

; -----------------------------------------------------------------------------
; int json_int(const char *js, const JTOK *tok, int32_t *out)
;   The integer in a primitive token (12, -7) or in a string token that
;   holds only one ("12345": YouTube gives sizes and lengths that way). A
;   fraction is dropped (-6.83 gives -6); an exponent, other characters or
;   nothing at all give -1 (*out untouched). Beyond the int32 range: -2,
;   *out = the nearest int32. 0 = ok.
; -----------------------------------------------------------------------------
EXPORT(json_int)
json_int:
    CENTER
    mov esi, ARG(0)
    mov ebx, ARG(1)
    mov al, [ebx + JSON_TYPE]
    cmp al, JSON_T_STRING
    je .text
    cmp al, JSON_T_PRIM
    jne .bad
.text:
    call json_text                  ; ESI..EDX = the text
    jc .bad
    xor ebx, ebx                    ; EBX: bit 0 = negative, bit 1 = too big
    cmp esi, edx
    jae .bad
    cmp byte [esi], '-'
    jne .digits
    inc ebx
    inc esi
.digits:
    xor eax, eax                    ; EAX = the size of the value so far
    mov edi, esi                    ; EDI = where the digits start
.dig:
    cmp esi, edx
    jae .end
    movzx ecx, byte [esi]
    sub ecx, '0'
    cmp ecx, 9
    ja .notdig
    inc esi
    cmp eax, 0x0CCCCCCD             ; 10 * EAX would pass 2^31: too big
    jae .big
    lea eax, [eax + eax * 4]
    add eax, eax                    ; EAX * 10 + the digit: at most 0x80000001,
    add eax, ecx                    ; so no carry out of 32 bits
    cmp eax, 0x80000000             ; (2^31 itself is fine if negative)
    jbe .dig
.big:
    or ebx, 2
    mov eax, 0x0CCCCCCD             ; (so every later digit lands here too)
    jmp .dig
.notdig:
    cmp byte [esi], '.'             ; a fraction: digits that are dropped
    jne .bad
    cmp esi, edi
    je .bad                         ; (no digits before the point)
    inc esi
    cmp esi, edx
    jae .bad                        ; (and at least one after it)
.frac:
    movzx ecx, byte [esi]
    sub ecx, '0'
    cmp ecx, 9
    ja .bad
    inc esi
    cmp esi, edx
    jb .frac
.end:
    cmp esi, edi
    je .bad                         ; no digits at all
    mov edx, ARG(2)
    test ebx, 2
    jnz .huge
    test ebx, 1
    jz .pos
    neg eax                         ; (-0x80000000 is fine)
    jmp .set
.pos:
    cmp eax, 0x7FFFFFFF
    ja .huge
.set:
    mov [edx], eax
    xor eax, eax
    CLEAVE
.huge:                              ; out of range: the nearest int32
    mov eax, 0x7FFFFFFF
    test ebx, 1
    jz .hset
    inc eax                         ; (-2^31)
.hset:
    mov [edx], eax
    mov eax, -2
    CLEAVE
.bad:
    mov eax, JSON_EINVAL
    CLEAVE
