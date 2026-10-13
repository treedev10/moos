; =============================================================================
;  html.asm - the browser's engine: HTML in, a painted page out
;
;  A page goes through three steps:
;
;  1. html_parse reads the HTML once and writes "page nodes" (BR_NODES):
;     text, already decoded (entities like &amp;, UTF-8 turned into the
;     screen font's characters, runs of spaces made one space), and the
;     start and end of the elements MOOS knows, with the few attributes it
;     uses (href, alt, id, type, value, colour, ...). Scripts, styles,
;     <svg>, <select> and anything hidden (hidden attribute, or
;     style="display:none") are dropped here. A plain text page becomes one
;     <pre>.
;
;  2. html_layout flows the nodes into lines of a given width: block
;     elements (p, div, h1, ul, table, ...) start new lines with some space
;     around them, text wraps between words, lists get bullets or numbers,
;     headings are drawn larger, table rows become lines with their cells
;     side by side. The result is a display list of "items" (BR_ITEMS):
;     a run of text in one style, or a filled rectangle, each with its
;     place on the page. Layout runs again whenever the window's width
;     changes, so text always fits the window.
;
;  3. html_paint draws the items inside the visible part of the page;
;     html_link_at finds the link under a point.
;
;  There is no CSS beyond a few inline style properties, no JavaScript and
;  no images (an image shows its description, its "alt" text).
; =============================================================================
%define BR_NODES    (BR_BASE)               ; parsed page (640 KB)
BR_NODES_SIZE equ 0xA0000
%define BR_ITEMS    (BR_BASE + 0xA0000)     ; display list (768 KB)
BR_MAX_ITEMS  equ 0xC0000 / 32
%define BR_POOL     (BR_BASE + 0x160000)    ; short texts made by the layout
BR_POOL_SIZE  equ 0x10000
%define BR_ANCH     (BR_BASE + 0x170000)    ; anchors: name, y (4096 x 8)
BR_MAX_ANCH   equ 4096
%define BR_STACK    (BR_BASE + 0x178000)    ; open elements (512 x 64)
BR_MAX_DEPTH  equ 512
%define BR_HIST     (BR_BASE + 0x180000)    ; history (browser.asm)
%define BR_TMP      (BR_BASE + 0x190000)    ; 64 KB to build pages in
%define BR_TABLES   (BR_BASE + 0x1A0000)    ; table columns (256 x 128)
BR_MAX_TABLES equ 256
TB_COLS     equ 16                  ; columns lined up (more: not lined up)
TI_N        equ 0                   ; table info: columns,
TI_LEFT     equ 4                   ; its left edge,
TI_X        equ 8                   ; where each column starts
%define BR_INPUTS   (BR_BASE + 0x1A8000)    ; form fields (256 x 256)
BR_MAX_INPUTS equ 256
%define BR_FORMS    (BR_BASE + 0x1B8000)    ; forms (64 x 8)
BR_MAX_FORMS  equ 64
; a form field (BR_INPUTS): made by the layout, in page order, so field k
; is the same field each time the page is laid out; what was typed stays
IN_TYPE     equ 0                   ; IT_*
IN_FORM     equ 4                   ; its form's number, -1 if none
IN_NAME     equ 8                   ; name=, value=, placeholder= (or 0)
IN_VALUE    equ 12
IN_PH       equ 16
IN_W        equ 20                  ; box width in characters
IN_LEN      equ 24                  ; characters typed
IN_CHK      equ 28                  ; checkbox / radio: 1 = ticked
IN_INIT     equ 32                  ; 1 = set up for this page
IN_TEXT     equ 64                  ; what is typed (up to IN_MAXLEN)
IN_SIZE     equ 256
IN_MAXLEN   equ 180
IT_TEXT     equ 1
IT_HIDDEN   equ 2
IT_SUBMIT   equ 3
IT_CHECK    equ 4
IT_RADIO    equ 5
IT_PASSWORD equ 6
IT_BUTTON   equ 7                   ; a button that does nothing here
FM_ACTION   equ 0                   ; a form: action=, 1 = method="post"
FM_POST     equ 4

; page nodes
NT_END      equ 0                   ; end of the page
NT_TEXT     equ 1                   ; 1, length (word), the characters
NT_OPEN     equ 2                   ; 2, tag, attribute bytes (word), attributes
NT_CLOSE    equ 3                   ; 3, tag
; attributes: id byte, value, 0 - ...; a 0 id ends them
A_HREF      equ 1
A_ALT       equ 2
A_ID        equ 3                   ; id, or name on <a>: a place to jump to
A_TYPE      equ 4
A_VALUE     equ 5
A_FG        equ 6                   ; text colour (color=, style="color:")
A_START     equ 7
A_ALIGN     equ 8                   ; "c" = centred
A_PLACEHOLDER equ 9
A_BOLD      equ 10
A_ITALIC    equ 11
A_CHECKED   equ 12
A_NAME      equ 13                  ; a field's name (a jump place on <a>)
A_ACTION    equ 14
A_METHOD    equ 15
A_SIZE      equ 16

; tag flags
TF_BLOCK    equ 1                   ; starts and ends a line
TF_VOID     equ 2                   ; never has content
TF_SKIP     equ 4                   ; the whole element is dropped
TF_RAW      equ 8                   ; content is not HTML (script, title)
; tag styles
SB_BOLD     equ 1                   ; (the same bits as GS_*)
SB_ITALIC   equ 2
SB_ULINE    equ 4
SB_STRIKE   equ 8
SB_CODE     equ 16                  ; code: tinted background
SB_MARK     equ 32                  ; highlighter
SB_HEAD     equ 64                  ; heading colour

; layout style (ly_st, and saved on the element stack)
ST_FLAGS    equ 0                   ; GS_* in the low byte, SF_* above
ST_CW       equ 4                   ; character width (height is twice)
ST_FG       equ 8
ST_BG       equ 12                  ; -1 = none
ST_LINK     equ 16                  ; the href of the link we are in, or 0
ST_LEFT     equ 20                  ; left and right edges of the text
ST_RIGHT    equ 24
ST_LIST     equ 28                  ; 1 = <ul>, 2 = <ol>
ST_COUNT    equ 32                  ; next <ol> number
ST_DEPTH    equ 36                  ; how many lists deep
ST_CELL     equ 40                  ; cells so far in this table row
ST_TABLE    equ 44                  ; the table's column places (-1: none)
ST_FORM     equ 48                  ; the form we are in (-1: none)
ST_SIZE     equ 52
SE_TAG      equ 52                  ; stack entry: the saved style, the tag,
SE_RECT     equ 56                  ; its background item (or -1)
SE_SIZE     equ 64
SF_PRE      equ 0x100
SF_CENTER   equ 0x200
GS_FRAME    equ 0x10                ; item style: a box around it (inputs)

; display list items (32 bytes)
DI_TYPE     equ 0                   ; DT_*
DI_STYLE    equ 1                   ; GS_* bits
DI_CW       equ 2                   ; character width
DI_LEN      equ 3                   ; characters (text)
DI_X        equ 4                   ; place on the page
DI_Y        equ 8
DI_W        equ 12                  ; (word)
DI_H        equ 14                  ; (word)
DI_FG       equ 16                  ; 0xRRGGBB (text, or the rectangle)
DI_BG       equ 20                  ; -1 = none
DI_TEXT     equ 24                  ; the characters
DI_LINK     equ 28                  ; href, or 0
DI_SIZE     equ 32
DT_TEXT     equ 1
DT_RECT     equ 2
DT_INPUT    equ 3                   ; a form field (DI_LINK = its record)

; colours of the page
C_PAGE_BG   equ 0xFFFFFF
C_TEXT      equ 0x202122
C_LINK      equ 0x1A0DAB
C_HOVER     equ 0xC0392B
C_HEAD      equ 0x101418
C_CODE_FG   equ 0x7A1F48
C_CODE_BG   equ 0xEEF0F3
C_PRE_BG    equ 0xF3F4F6
C_MARK      equ 0xFFF29A
C_RULE      equ 0xC4C9CF
C_ALT       equ 0x6A737D
C_BUTTON_BG equ 0xE1E5EA
C_FIELD_BG  equ 0xFFFFFF
C_FRAME     equ 0x8C959F
C_FOCUS     equ 0xFFE38A

; ------------------------------------------------------------------ tags
; Each tag: name (padded to 12 bytes), flags, margin above and below
; (pixels, blocks only), style, character width (0 = unchanged).
%macro TAGDEF 6                     ; T_name, "name", flags, margin, style, cw
    %1 equ ($ - tag_table) / 16 + 1
    db %2
    times 12 - %strlen(%2) db 0
    db %3, %4, %5, %6
%endmacro

; TAGBYTE dest, tag, field: one byte of a tag's entry (field 12 = flags,
; 13 = margin, 14 = style, 15 = character width). dest must differ from tag.
%macro TAGBYTE 3
    mov %1, %2
    shl %1, 4
    movzx %1, byte [tag_table + %1 - 16 + %3]
%endmacro

section .data
align 4
tag_table:
TAGDEF T_A,         "a",          0, 0, 0, 0
TAGDEF T_ABBR,      "abbr",       0, 0, 0, 0
TAGDEF T_ADDRESS,   "address",    TF_BLOCK, 8, SB_ITALIC, 0
TAGDEF T_AREA,      "area",       TF_VOID, 0, 0, 0
TAGDEF T_ARTICLE,   "article",    TF_BLOCK, 0, 0, 0
TAGDEF T_ASIDE,     "aside",      TF_BLOCK, 0, 0, 0
TAGDEF T_AUDIO,     "audio",      TF_SKIP, 0, 0, 0
TAGDEF T_B,         "b",          0, 0, SB_BOLD, 0
TAGDEF T_BASE,      "base",       TF_VOID, 0, 0, 0
TAGDEF T_BIG,       "big",        0, 0, 0, 0
TAGDEF T_BLOCKQUOTE, "blockquote", TF_BLOCK, 10, 0, 0
TAGDEF T_BODY,      "body",       0, 0, 0, 0
TAGDEF T_BR,        "br",         TF_VOID, 0, 0, 0
TAGDEF T_BUTTON,    "button",     0, 0, 0, 0
TAGDEF T_CANVAS,    "canvas",     TF_SKIP, 0, 0, 0
TAGDEF T_CAPTION,   "caption",    TF_BLOCK, 4, SB_BOLD, 0
TAGDEF T_CENTER,    "center",     TF_BLOCK, 0, 0, 0
TAGDEF T_CITE,      "cite",       0, 0, SB_ITALIC, 0
TAGDEF T_CODE,      "code",       0, 0, SB_CODE, 0
TAGDEF T_COL,       "col",        TF_VOID, 0, 0, 0
TAGDEF T_DD,        "dd",         TF_BLOCK, 0, 0, 0
TAGDEF T_DEL,       "del",        0, 0, SB_STRIKE, 0
TAGDEF T_DETAILS,   "details",    TF_BLOCK, 6, 0, 0
TAGDEF T_DFN,       "dfn",        0, 0, SB_ITALIC, 0
TAGDEF T_DIALOG,    "dialog",     TF_SKIP, 0, 0, 0
TAGDEF T_DIV,       "div",        TF_BLOCK, 0, 0, 0
TAGDEF T_DL,        "dl",         TF_BLOCK, 8, 0, 0
TAGDEF T_DT,        "dt",         TF_BLOCK, 0, SB_BOLD, 0
TAGDEF T_EM,        "em",         0, 0, SB_ITALIC, 0
TAGDEF T_EMBED,     "embed",      TF_VOID, 0, 0, 0
TAGDEF T_FIELDSET,  "fieldset",   TF_BLOCK, 8, 0, 0
TAGDEF T_FIGCAPTION, "figcaption", TF_BLOCK, 4, 0, 0
TAGDEF T_FIGURE,    "figure",     TF_BLOCK, 10, 0, 0
TAGDEF T_FONT,      "font",       0, 0, 0, 0
TAGDEF T_FOOTER,    "footer",     TF_BLOCK, 0, 0, 0
TAGDEF T_FORM,      "form",       TF_BLOCK, 0, 0, 0
TAGDEF T_H1,        "h1",         TF_BLOCK, 14, SB_BOLD | SB_HEAD, 16
TAGDEF T_H2,        "h2",         TF_BLOCK, 12, SB_BOLD | SB_HEAD, 12
TAGDEF T_H3,        "h3",         TF_BLOCK, 10, SB_BOLD | SB_HEAD, 10
TAGDEF T_H4,        "h4",         TF_BLOCK, 8, SB_BOLD | SB_HEAD, 0
TAGDEF T_H5,        "h5",         TF_BLOCK, 8, SB_BOLD | SB_HEAD, 0
TAGDEF T_H6,        "h6",         TF_BLOCK, 8, SB_BOLD | SB_HEAD, 0
TAGDEF T_HEAD,      "head",       0, 0, 0, 0
TAGDEF T_HEADER,    "header",     TF_BLOCK, 0, 0, 0
TAGDEF T_HR,        "hr",         TF_VOID, 0, 0, 0
TAGDEF T_HTML,      "html",       0, 0, 0, 0
TAGDEF T_I,         "i",          0, 0, SB_ITALIC, 0
TAGDEF T_IFRAME,    "iframe",     TF_SKIP, 0, 0, 0
TAGDEF T_IMG,       "img",        TF_VOID, 0, 0, 0
TAGDEF T_INPUT,     "input",      TF_VOID, 0, 0, 0
TAGDEF T_INS,       "ins",        0, 0, SB_ULINE, 0
TAGDEF T_KBD,       "kbd",        0, 0, SB_CODE, 0
TAGDEF T_LABEL,     "label",      0, 0, 0, 0
TAGDEF T_LI,        "li",         TF_BLOCK, 0, 0, 0
TAGDEF T_LINK,      "link",       TF_VOID, 0, 0, 0
TAGDEF T_MAIN,      "main",       TF_BLOCK, 0, 0, 0
TAGDEF T_MARK,      "mark",       0, 0, SB_MARK, 0
TAGDEF T_MATH,      "math",       TF_SKIP, 0, 0, 0
TAGDEF T_META,      "meta",       TF_VOID, 0, 0, 0
TAGDEF T_NAV,       "nav",        TF_BLOCK, 0, 0, 0
TAGDEF T_NOSCRIPT,  "noscript",   0, 0, 0, 0
TAGDEF T_OBJECT,    "object",     TF_SKIP, 0, 0, 0
TAGDEF T_OL,        "ol",         TF_BLOCK, 8, 0, 0
TAGDEF T_P,         "p",          TF_BLOCK, 10, 0, 0
TAGDEF T_PARAM,     "param",      TF_VOID, 0, 0, 0
TAGDEF T_PICTURE,   "picture",    0, 0, 0, 0
TAGDEF T_PRE,       "pre",        TF_BLOCK, 10, 0, 0
TAGDEF T_Q,         "q",          0, 0, 0, 0
TAGDEF T_S,         "s",          0, 0, SB_STRIKE, 0
TAGDEF T_SAMP,      "samp",       0, 0, SB_CODE, 0
TAGDEF T_SCRIPT,    "script",     TF_RAW | TF_SKIP, 0, 0, 0
TAGDEF T_SECTION,   "section",    TF_BLOCK, 0, 0, 0
TAGDEF T_SELECT,    "select",     TF_SKIP, 0, 0, 0
TAGDEF T_SMALL,     "small",      0, 0, 0, 0
TAGDEF T_SOURCE,    "source",     TF_VOID, 0, 0, 0
TAGDEF T_SPAN,      "span",       0, 0, 0, 0
TAGDEF T_STRIKE,    "strike",     0, 0, SB_STRIKE, 0
TAGDEF T_STRONG,    "strong",     0, 0, SB_BOLD, 0
TAGDEF T_STYLE,     "style",      TF_RAW | TF_SKIP, 0, 0, 0
TAGDEF T_SUB,       "sub",        0, 0, 0, 0
TAGDEF T_SUMMARY,   "summary",    TF_BLOCK, 0, SB_BOLD, 0
TAGDEF T_SUP,       "sup",        0, 0, 0, 0
TAGDEF T_SVG,       "svg",        TF_SKIP, 0, 0, 0
TAGDEF T_TABLE,     "table",      TF_BLOCK, 6, 0, 0
TAGDEF T_TBODY,     "tbody",      0, 0, 0, 0
TAGDEF T_TD,        "td",         0, 0, 0, 0
TAGDEF T_TEMPLATE,  "template",   TF_SKIP, 0, 0, 0
TAGDEF T_TEXTAREA,  "textarea",   TF_RAW, 0, 0, 0
TAGDEF T_TFOOT,     "tfoot",      0, 0, 0, 0
TAGDEF T_TH,        "th",         0, 0, SB_BOLD, 0
TAGDEF T_THEAD,     "thead",      0, 0, 0, 0
TAGDEF T_TITLE,     "title",      TF_RAW, 0, 0, 0
TAGDEF T_TR,        "tr",         TF_BLOCK, 0, 0, 0
TAGDEF T_TRACK,     "track",      TF_VOID, 0, 0, 0
TAGDEF T_TT,        "tt",         0, 0, 0, 0
TAGDEF T_U,         "u",          0, 0, SB_ULINE, 0
TAGDEF T_UL,        "ul",         TF_BLOCK, 8, 0, 0
TAGDEF T_VAR,       "var",        0, 0, SB_ITALIC, 0
TAGDEF T_VIDEO,     "video",      TF_SKIP, 0, 0, 0
TAGDEF T_WBR,       "wbr",        TF_VOID, 0, 0, 0
tag_table_end:
T_COUNT equ (tag_table_end - tag_table) / 16

; attributes MOOS keeps: name, its id
attr_names:
    db "href", 0, A_HREF
    db "alt", 0, A_ALT
    db "id", 0, A_ID
    db "name", 0, A_NAME
    db "type", 0, A_TYPE
    db "value", 0, A_VALUE
    db "color", 0, A_FG
    db "start", 0, A_START
    db "align", 0, A_ALIGN
    db "placeholder", 0, A_PLACEHOLDER
    db "checked", 0, A_CHECKED
    db "action", 0, A_ACTION
    db "method", 0, A_METHOD
    db "size", 0, A_SIZE
    db 0

; named character references: name, 0, code point (word)
entities:
    db "amp", 0
    dw 38
    db "lt", 0
    dw 60
    db "gt", 0
    dw 62
    db "quot", 0
    dw 34
    db "apos", 0
    dw 39
    db "nbsp", 0
    dw 160
    db "copy", 0
    dw 169
    db "reg", 0
    dw 174
    db "trade", 0
    dw 8482
    db "mdash", 0
    dw 8212
    db "ndash", 0
    dw 8211
    db "hellip", 0
    dw 8230
    db "lsquo", 0
    dw 8216
    db "rsquo", 0
    dw 8217
    db "sbquo", 0
    dw 8218
    db "ldquo", 0
    dw 8220
    db "rdquo", 0
    dw 8221
    db "bdquo", 0
    dw 8222
    db "laquo", 0
    dw 171
    db "raquo", 0
    dw 187
    db "lsaquo", 0
    dw 8249
    db "rsaquo", 0
    dw 8250
    db "bull", 0
    dw 8226
    db "middot", 0
    dw 183
    db "deg", 0
    dw 176
    db "plusmn", 0
    dw 177
    db "times", 0
    dw 215
    db "divide", 0
    dw 247
    db "frac12", 0
    dw 189
    db "frac14", 0
    dw 188
    db "frac34", 0
    dw 190
    db "sup1", 0
    dw 185
    db "sup2", 0
    dw 178
    db "sup3", 0
    dw 179
    db "micro", 0
    dw 181
    db "para", 0
    dw 182
    db "sect", 0
    dw 167
    db "cent", 0
    dw 162
    db "pound", 0
    dw 163
    db "yen", 0
    dw 165
    db "euro", 0
    dw 8364
    db "curren", 0
    dw 164
    db "iexcl", 0
    dw 161
    db "iquest", 0
    dw 191
    db "shy", 0
    dw 173
    db "ensp", 0
    dw 8194
    db "emsp", 0
    dw 8195
    db "thinsp", 0
    dw 8201
    db "zwnj", 0
    dw 8204
    db "zwj", 0
    dw 8205
    db "larr", 0
    dw 8592
    db "uarr", 0
    dw 8593
    db "rarr", 0
    dw 8594
    db "darr", 0
    dw 8595
    db "harr", 0
    dw 8596
    db "minus", 0
    dw 8722
    db "le", 0
    dw 8804
    db "ge", 0
    dw 8805
    db "ne", 0
    dw 8800
    db "asymp", 0
    dw 8776
    db "infin", 0
    dw 8734
    db "radic", 0
    dw 8730
    db "alpha", 0
    dw 945
    db "beta", 0
    dw 946
    db "pi", 0
    dw 960
    db "mu", 0
    dw 956
    db "sigma", 0
    dw 963
    db "Sigma", 0
    dw 931
    db "Omega", 0
    dw 937
    db "hearts", 0
    dw 9829
    db "check", 0
    dw 10003
    db "Auml", 0
    dw 196
    db "Ouml", 0
    dw 214
    db "Uuml", 0
    dw 220
    db "auml", 0
    dw 228
    db "ouml", 0
    dw 246
    db "uuml", 0
    dw 252
    db "szlig", 0
    dw 223
    db "eacute", 0
    dw 233
    db "egrave", 0
    dw 232
    db "ecirc", 0
    dw 234
    db "aacute", 0
    dw 225
    db "agrave", 0
    dw 224
    db "acirc", 0
    dw 226
    db "iacute", 0
    dw 237
    db "oacute", 0
    dw 243
    db "uacute", 0
    dw 250
    db "ccedil", 0
    dw 231
    db "ntilde", 0
    dw 241
    db "Eacute", 0
    dw 201
    db "aring", 0
    dw 229
    db "Aring", 0
    dw 197
    db "aelig", 0
    dw 230
    db "oslash", 0
    dw 248
    db 0

; Latin-1 (U+00A0 - U+00FF) in the screen font (code page 437);
; 0 = see uni_437
lat1_437:
    db 0xFF, 0xAD, 0x9B, 0x9C, 0,    0x9D, '|',  0x15   ; A0
    db '"',  0,    0xA6, 0xAE, 0xAA, 0,    0,    '-'    ; A8
    db 0xF8, 0xF1, 0xFD, '3',  "'",  0xE6, 0x14, 0xFA   ; B0
    db ',',  '1',  0xA7, 0xAF, 0xAC, 0xAB, 0,    0xA8   ; B8
    db 'A',  'A',  'A',  'A',  0x8E, 0x8F, 0x92, 0x80   ; C0
    db 'E',  0x90, 'E',  'E',  'I',  'I',  'I',  'I'    ; C8
    db 'D',  0xA5, 'O',  'O',  'O',  'O',  0x99, 'x'    ; D0
    db 'O',  'U',  'U',  'U',  0x9A, 'Y',  'P',  0xE1   ; D8
    db 0x85, 0xA0, 0x83, 'a',  0x84, 0x86, 0x91, 0x87   ; E0
    db 0x8A, 0x82, 0x88, 0x89, 0x8D, 0xA1, 0x8C, 0x8B   ; E8
    db 'd',  0xA4, 0x95, 0xA2, 0x93, 'o',  0x94, 0xF6   ; F0
    db 'o',  0x97, 0xA3, 0x96, 0x81, 'y',  'p',  0x98   ; F8

; other code points: dd code point, db how many characters, the characters
%macro UNI 2-4
    dd %1
    %if %0 == 2
        db 1, %2, 0, 0
    %elif %0 == 3
        db 2, %2, %3, 0
    %else
        db 3, %2, %3, %4
    %endif
%endmacro
%macro UNI0 1                       ; shown as nothing
    dd %1
    db 0, 0, 0, 0
%endmacro
uni_437:
    UNI 0xA4, '*'
    UNI 0xA9, '(', 'c', ')'
    UNI 0xAE, '(', 'R', ')'
    UNI 0xBE, '3', '/', '4'
    UNI0 0xAD
    UNI 0x2010, '-'
    UNI 0x2011, '-'
    UNI 0x2012, '-'
    UNI 0x2013, '-'
    UNI 0x2014, '-', '-'
    UNI 0x2015, '-', '-'
    UNI 0x2018, "'"
    UNI 0x2019, "'"
    UNI 0x201A, ','
    UNI 0x201C, '"'
    UNI 0x201D, '"'
    UNI 0x201E, '"'
    UNI 0x2022, 0x07
    UNI 0x2023, 0x10
    UNI 0x2026, '.', '.', '.'
    UNI 0x2030, '%'
    UNI 0x2032, "'"
    UNI 0x2033, '"'
    UNI 0x2039, '<'
    UNI 0x203A, '>'
    UNI 0x2044, '/'
    UNI 0x20AC, 'E', 'U', 'R'
    UNI 0x2122, 'T', 'M'
    UNI 0x2190, 0x1B
    UNI 0x2191, 0x18
    UNI 0x2192, 0x1A
    UNI 0x2193, 0x19
    UNI 0x2194, 0x1D
    UNI 0x2195, 0x12
    UNI 0x2212, '-'
    UNI 0x2215, '/'
    UNI 0x2219, 0xF9
    UNI 0x221A, 0xFB
    UNI 0x221E, 0xEC
    UNI 0x2229, 0xEF
    UNI 0x2248, 0xF7
    UNI 0x2260, '!', '='
    UNI 0x2261, 0xF0
    UNI 0x2264, 0xF3
    UNI 0x2265, 0xF2
    UNI 0x2302, 0x7F
    UNI 0x2500, 0xC4
    UNI 0x2502, 0xB3
    UNI 0x25A0, 0xFE
    UNI 0x25AA, 0xFE
    UNI 0x25B2, 0x1E
    UNI 0x25B6, 0x10
    UNI 0x25BA, 0x10
    UNI 0x25BC, 0x1F
    UNI 0x25C0, 0x11
    UNI 0x25C4, 0x11
    UNI 0x25CB, 0x09
    UNI 0x25CF, 0x07
    UNI 0x263A, 0x01
    UNI 0x263B, 0x02
    UNI 0x263C, 0x0F
    UNI 0x2660, 0x06
    UNI 0x2663, 0x05
    UNI 0x2665, 0x03
    UNI 0x2666, 0x04
    UNI 0x266A, 0x0D
    UNI 0x266B, 0x0E
    UNI 0x2713, 0xFB
    UNI 0x2714, 0xFB
    UNI 0x2715, 'x'
    UNI 0x2716, 'x'
    UNI 0x2717, 'x'
    UNI 0x2718, 'x'
    UNI 0x0391, 'A'
    UNI 0x0392, 'B'
    UNI 0x0393, 0xE2
    UNI 0x0398, 0xE9
    UNI 0x03A3, 0xE4
    UNI 0x03A6, 0xE8
    UNI 0x03A9, 0xEA
    UNI 0x03B1, 0xE0
    UNI 0x03B2, 0xE1
    UNI 0x03B4, 0xEB
    UNI 0x03B5, 0xEE
    UNI 0x03BC, 0xE6
    UNI 0x03C0, 0xE3
    UNI 0x03C3, 0xE5
    UNI 0x03C4, 0xE7
    UNI 0x03C6, 0xED
    UNI 0x0152, 'O', 'E'
    UNI 0x0153, 'o', 'e'
    UNI 0x0160, 'S'
    UNI 0x0161, 's'
    UNI 0x0178, 'Y'
    UNI 0x017D, 'Z'
    UNI 0x017E, 'z'
    UNI 0x0192, 0x9F
    UNI 0x02C6, '^'
    UNI 0x02DC, '~'
    UNI0 0x200B
    UNI0 0x200C
    UNI0 0x200D
    UNI0 0x200E
    UNI0 0x200F
    UNI0 0x2060
    UNI0 0xFEFF
    UNI0 0xFE0F
    dd 0

; Windows-1252 0x80 - 0x9F (a stray byte that is not UTF-8 is read as
; Windows-1252 / Latin-1, what older pages use)
cp1252:
    dw 0x20AC, 0xFFFD, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021
    dw 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0x017D, 0xFFFD
    dw 0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014
    dw 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0x017E, 0x0178

css_display     db "display", 0
css_visibility  db "visibility", 0
css_weight      db "font-weight", 0
css_fstyle      db "font-style", 0
css_color       db "color", 0
css_talign      db "text-align", 0
css_none        db "none", 0
css_hidden      db "hidden", 0
css_bold        db "bold", 0
css_italic      db "italic", 0
css_oblique     db "oblique", 0
css_center      db "center", 0
at_hidden       db "hidden", 0
at_style        db "style", 0
at_class        db "class", 0
; class names that pages use to hide things (from style sheets MOOS does not
; read). A class like "md:block" next to them means it shows on big screens.
hide_classes    db "hidden", 0, "d-none", 0, "sr-only", 0, "visually-hidden", 0
                db "screen-reader-text", 0, "hide", 0, "is-hidden", 0
                db "u-hidden", 0, "noprint", 0, 0
at_href         db "href", 0

section .bss
alignb 4
hp_src      resd 1                  ; next byte of the HTML
hp_end      resd 1
hp_out      resd 1                  ; where the next node byte goes
hp_lim      resd 1
hp_text     resd 1                  ; the text node being written (0 = none)
hp_tlen     resd 1
hp_sp       resd 1                  ; 1 = the last character written was a space
hp_pre      resd 1                  ; inside how many <pre>
hp_sink     resd 1                  ; where decoded characters go
hp_aout     resd 1                  ; (hp_asink: where, and the end)
hp_alim     resd 1
hp_apos     resd 1                  ; the tag's attributes collected so far
hp_tagid    resd 1
hp_hidden   resd 1
hp_selfclose resd 1                 ; the tag ended with "/>"
hp_nlen     resd 1                  ; length of hp_name
hp_vs       resd 1                  ; an attribute value: start, end
hp_ve       resd 1
hp_name     resb 16                 ; tag name, lower case
hp_an       resb 24                 ; attribute name, lower case
hp_ent      resb 16
hp_attrs    resb 2048
br_title    resb 160                ; the page's <title>
br_base     resb 512                ; its <base href>, if any
section .text

; ======================================================== 1. parsing
; html_parse: ESI = HTML, ECX = its length -> page nodes in BR_NODES,
; br_title, br_base
html_parse:
    pushad
    call hp_begin
    add ecx, esi
    mov [hp_src], esi
    mov [hp_end], ecx
.loop:
    mov esi, [hp_src]
    cmp esi, [hp_end]
    jae .end
    mov eax, [hp_out]
    cmp eax, [hp_lim]
    jae .end
    movzx eax, byte [esi]
    cmp al, '<'
    je .tag
    call hp_char                    ; text: one character
    jmp .loop
.tag:
    call hp_tag
    jmp .loop
.end:
    call hp_finish
    popad
    ret

; html_parse_text: ESI = plain text, ECX = its length -> page nodes: the
; text in one <pre>
html_parse_text:
    pushad
    call hp_begin
    add ecx, esi
    mov [hp_src], esi
    mov [hp_end], ecx
    mov eax, T_PRE
    call hp_open_plain
    inc dword [hp_pre]
.loop:
    mov esi, [hp_src]
    cmp esi, [hp_end]
    jae .end
    mov eax, [hp_out]
    cmp eax, [hp_lim]
    jae .end
    movzx eax, byte [esi]
    inc dword [hp_src]
    cmp al, 0x80
    jb .ascii
    call hp_utf8
.ascii:
    call cp_out
    jmp .loop
.end:
    call np_text_end
    mov al, NT_CLOSE
    call np_byte
    mov al, T_PRE
    call np_byte
    call hp_finish
    popad
    ret

; hp_begin / hp_finish: start and end the node list
hp_begin:
    mov dword [hp_out], BR_NODES
    mov dword [hp_lim], BR_NODES + BR_NODES_SIZE - 4096
    mov dword [hp_text], 0
    mov dword [hp_pre], 0
    mov dword [hp_sp], 1
    mov dword [hp_sink], hp_tsink
    mov byte [br_title], 0
    mov byte [br_base], 0
    ret
hp_finish:
    call np_text_end
    mov al, NT_END
    call np_byte
    ret

; hp_char: one character of text at hp_src: an entity, UTF-8, or plain
hp_char:
    pushad
    mov esi, [hp_src]
    movzx eax, byte [esi]
    cmp al, '&'
    je .ent
    inc dword [hp_src]
    cmp al, 0x80
    jb .out
    call hp_utf8
    jmp .out
.ent:
    call hp_entity
.out:
    call cp_out
    popad
    ret

; ---------------------------------------------------- writing nodes
; np_byte: AL -> the node list
np_byte:
    push edi
    mov edi, [hp_out]
    mov [edi], al
    inc dword [hp_out]
    pop edi
    ret

; np_text_char: AL -> the current text node (one is started if needed)
np_text_char:
    cmp dword [hp_text], 0
    jne .have
    push eax
    mov eax, [hp_out]
    mov [hp_text], eax
    mov dword [hp_tlen], 0
    mov al, NT_TEXT
    call np_byte
    xor al, al                      ; (length, filled in later)
    call np_byte
    call np_byte
    pop eax
.have:
    call np_byte
    inc dword [hp_tlen]
    cmp dword [hp_tlen], 60000
    jb .r
    call np_text_end
.r: ret

; np_text_end: finish the current text node
np_text_end:
    push eax
    push edi
    mov edi, [hp_text]
    test edi, edi
    jz .r
    mov eax, [hp_tlen]
    mov [edi + 1], ax
    mov dword [hp_text], 0
.r: pop edi
    pop eax
    ret

; hp_open_plain: EAX = tag -> an element start with no attributes
hp_open_plain:
    push eax
    call np_text_end
    mov al, NT_OPEN
    call np_byte
    pop eax
    call np_byte
    mov al, 1                       ; one attribute byte: the end mark
    call np_byte
    xor al, al
    call np_byte
    call np_byte
    ret

; ------------------------------------------------ characters, decoding
; hp_tsink: a decoded character for the page text. EAX < 0x100: a
; character of the screen font; 0x100 + c: white space c (collapsed to one
; space outside <pre>)
hp_tsink:
    cmp eax, 0x100
    jae .ws
    call np_text_char
    mov dword [hp_sp], 0
    ret
.ws:
    cmp dword [hp_pre], 0
    je .collapse
    sub eax, 0x100
    cmp al, 13
    je .r
    cmp al, 10
    je .put
    cmp al, 9
    jne .space
    mov al, ' '                     ; a tab: four spaces
    call np_text_char
    call np_text_char
    call np_text_char
.space:
    mov al, ' '
.put:
    call np_text_char
.r: ret
.collapse:
    cmp dword [hp_sp], 0
    jne .r
    mov al, ' '
    call np_text_char
    mov dword [hp_sp], 1
    ret

; hp_asink: a decoded character for an attribute value or the title
hp_asink:
    push edi
    cmp eax, 0x100
    jb .c
    mov al, ' '
.c: mov edi, [hp_aout]
    cmp edi, [hp_alim]
    jae .r
    mov [edi], al
    inc dword [hp_aout]
.r: pop edi
    ret

; cp_out: EAX = a Unicode code point -> the screen font's character(s),
; handed to hp_sink
cp_out:
    pushad
    cmp eax, 0x80
    jae .high
    cmp al, ' '
    je .ws
    cmp al, 9
    je .ws
    cmp al, 10
    je .ws
    cmp al, 12
    je .ws
    cmp al, 13
    je .ws
    cmp al, ' '
    jb .done                        ; other control characters: nothing
    cmp al, 127
    je .done
.one:
    call [hp_sink]
    jmp .done
.ws:
    add eax, 0x100
    jmp .one
.high:
    cmp eax, 0xA0
    jb .box
    cmp eax, 0x100
    jae .table
    movzx ebx, byte [lat1_437 + eax - 0xA0]
    test ebx, ebx
    jz .table
    mov eax, ebx
    jmp .one
.table:
    mov esi, uni_437
.t: mov ebx, [esi]
    test ebx, ebx
    jz .other
    cmp ebx, eax
    je .found
    add esi, 8
    jmp .t
.found:
    movzx ecx, byte [esi + 4]
    add esi, 5
.f: jecxz .done
    movzx eax, byte [esi]
    call [hp_sink]
    inc esi
    dec ecx
    jmp .f
.other:
    cmp eax, 0x300                  ; accents that combine: nothing
    jb .box
    cmp eax, 0x370
    jb .done
    cmp eax, 0x2000                 ; the many kinds of space: a space
    jb .box
    cmp eax, 0x200A
    jbe .space
    cmp eax, 0x202F
    je .space
    cmp eax, 0x205F
    je .space
    cmp eax, 0x3000
    je .space
.box:
    mov eax, 0xFE                   ; no such character in the font: a box
    jmp .one
.space:
    mov eax, 0x100 + ' '
    jmp .one
.done:
    popad
    ret

; hp_utf8: EAX = a byte >= 0x80 just read (hp_src is past it) -> EAX = the
; code point of the UTF-8 sequence it starts (hp_src past it all). A byte
; that does not start valid UTF-8 is read as Windows-1252.
hp_utf8:
    push ebx
    push ecx
    push edx
    push esi
    mov edx, eax                    ; (the byte, in case it is not UTF-8)
    mov esi, [hp_src]
    cmp al, 0xC2
    jb .bad
    cmp al, 0xE0
    jb .two
    cmp al, 0xF0
    jb .three
    cmp al, 0xF5
    jae .bad
    and eax, 7
    mov ecx, 3
    jmp .cont
.two:
    and eax, 0x1F
    mov ecx, 1
    jmp .cont
.three:
    and eax, 0x0F
    mov ecx, 2
.cont:
    cmp esi, [hp_end]
    jae .bad
    movzx ebx, byte [esi]
    mov bh, bl
    and bh, 0xC0
    cmp bh, 0x80
    jne .bad
    and ebx, 0x3F
    shl eax, 6
    or eax, ebx
    inc esi
    dec ecx
    jnz .cont
    mov [hp_src], esi
    jmp .out
.bad:
    mov eax, edx
    cmp eax, 0xA0
    jae .out
    movzx eax, word [cp1252 + eax * 2 - 0x100]
.out:
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; hp_entity: hp_src at '&' -> EAX = the code point of the character
; reference there (&amp; &#169; &#xA9; ...), hp_src past it; if it is not
; one, EAX = '&' and hp_src moves one on
hp_entity:
    push ebx
    push ecx
    push esi
    push edi
    mov esi, [hp_src]
    inc esi
    cmp esi, [hp_end]
    jae .lit
    cmp byte [esi], '#'
    je .num
    xor ecx, ecx                    ; the name, up to 15 letters and digits
.n: cmp esi, [hp_end]
    jae .named
    mov al, [esi]
    call is_alnum
    jc .named
    cmp ecx, 15
    jae .lit
    mov [hp_ent + ecx], al
    inc ecx
    inc esi
    jmp .n
.named:
    test ecx, ecx
    jz .lit
    mov byte [hp_ent + ecx], 0
    mov edi, entities
.e: cmp byte [edi], 0
    je .lit
    push esi
    mov esi, hp_ent
    call str_eq                     ; (case matters: &Auml; is not &auml;)
    pop esi
    je .hit
.skip:
    cmp byte [edi], 0
    je .next
    inc edi
    jmp .skip
.next:
    add edi, 3
    jmp .e
.hit:
    call .after
    movzx eax, word [edi + ecx + 1]
    jmp .out
.num:
    inc esi
    xor eax, eax
    xor ebx, ebx                    ; digits seen
    cmp esi, [hp_end]
    jae .lit
    mov cl, [esi]
    or cl, 0x20
    cmp cl, 'x'
    je .hex
.dec:
    cmp esi, [hp_end]
    jae .ndone
    movzx ecx, byte [esi]
    sub ecx, '0'
    cmp ecx, 9
    ja .ndone
    cmp eax, 0x110000
    jae .big
    imul eax, 10
    add eax, ecx
.big:
    inc ebx
    inc esi
    jmp .dec
.hex:
    inc esi
.hx:
    cmp esi, [hp_end]
    jae .ndone
    movzx ecx, byte [esi]
    call hex_digit
    jc .ndone
    cmp eax, 0x110000
    jae .hbig
    shl eax, 4
    add eax, ecx
.hbig:
    inc ebx
    inc esi
    jmp .hx
.ndone:
    test ebx, ebx
    jz .lit
    call .after
    test eax, eax
    jz .bad
    cmp eax, 0x110000
    jb .out
.bad:
    mov eax, 0xFFFD
    jmp .out
.lit:
    inc dword [hp_src]
    mov eax, '&'
.out:
    pop edi
    pop esi
    pop ecx
    pop ebx
    ret
; .after: ESI = just past the name or number -> hp_src past the ';' too
.after:
    cmp esi, [hp_end]
    jae .a1
    cmp byte [esi], ';'
    jne .a1
    inc esi
.a1:
    mov [hp_src], esi
    ret

; is_alnum: AL -> CF=0 if a letter or digit
is_alnum:
    cmp al, '0'
    jb .no
    cmp al, '9'
    jbe .yes
    push eax
    or al, 0x20
    cmp al, 'a'
    jb .no2
    cmp al, 'z'
    ja .no2
    pop eax
.yes:
    clc
    ret
.no2:
    pop eax
.no:
    stc
    ret

; hex_digit: ECX = a character -> ECX = its value, CF=1 if not hex
hex_digit:
    cmp ecx, '0'
    jb .no
    cmp ecx, '9'
    jbe .d
    or ecx, 0x20
    cmp ecx, 'a'
    jb .no
    cmp ecx, 'f'
    ja .no
    sub ecx, 'a' - 10
    clc
    ret
.d: sub ecx, '0'
    clc
    ret
.no:
    stc
    ret

; str_eq: ESI, EDI = strings -> ZF=1 if exactly equal
str_eq:
    push eax
    push esi
    push edi
.l: mov al, [esi]
    cmp al, [edi]
    jne .out
    test al, al
    jz .out
    inc esi
    inc edi
    jmp .l
.out:
    pop edi
    pop esi
    pop eax
    ret

; ------------------------------------------------------------ tags
; hp_tag: hp_src at '<': a tag, comment or declaration (or just a '<')
hp_tag:
    pushad
    mov esi, [hp_src]
    lea eax, [esi + 1]
    cmp eax, [hp_end]
    jae .lt
    mov al, [esi + 1]
    cmp al, '!'
    je .bang
    cmp al, '?'
    je .decl
    cmp al, '/'
    je .close
    call is_alnum
    jc .lt
    cmp al, '9'
    jbe .lt
    ; <name attributes...>
    lea esi, [esi + 1]
    call hp_read_name
    call hp_read_attrs              ; ESI -> past the '>'
    mov [hp_src], esi
    call tag_lookup                 ; EAX = id (0 = not one MOOS uses)
    mov [hp_tagid], eax
    TAGBYTE ebx, eax, 12
    test eax, eax
    jnz .known
    xor ebx, ebx
.known:
    cmp dword [hp_hidden], 0
    je .shown
    test ebx, TF_VOID
    jnz .done                       ; a hidden <input>: nothing
    call .can_skip
    jc .shown
    call hp_skip_element
    jmp .done
.shown:
    test ebx, TF_RAW
    jnz .raw
    test ebx, TF_SKIP
    jz .not_skip
    call .can_skip
    jnc .skip
    jmp .done
.not_skip:
    test eax, eax
    jz .done
    cmp eax, T_BASE
    je .base
    call hp_emit_open
    cmp dword [hp_tagid], T_PRE
    jne .done
    inc dword [hp_pre]
    jmp .done
.skip:
    call hp_skip_element
    jmp .done
.raw:
    call hp_raw_element
    jmp .done
.base:
    mov esi, hp_attrs               ; <base href>: links are relative to it
.ba:
    cmp esi, [hp_apos]
    jae .done
    movzx eax, byte [esi]
    inc esi
    cmp eax, A_HREF
    je .bhref
.bs:
    lodsb
    test al, al
    jnz .bs
    jmp .ba
.bhref:
    mov edi, br_base
    call str_copy
    jmp .done
.close:
    lea esi, [esi + 2]              ; </name>
    call hp_read_name
.c1:
    cmp esi, [hp_end]
    jae .c2
    lodsb
    cmp al, '>'
    jne .c1
.c2:
    mov [hp_src], esi
    call tag_lookup
    test eax, eax
    jz .done
    push eax
    call np_text_end
    mov al, NT_CLOSE
    call np_byte
    pop eax
    call np_byte
    cmp eax, T_PRE
    jne .done
    cmp dword [hp_pre], 0
    je .done
    dec dword [hp_pre]
    jmp .done
.bang:
    lea eax, [esi + 4]              ; <!-- comment -->
    cmp eax, [hp_end]
    ja .decl
    cmp word [esi + 2], '--'
    jne .decl
    add esi, 4
.cm:
    lea eax, [esi + 3]
    cmp eax, [hp_end]
    ja .to_end
    cmp word [esi], '--'
    jne .cm1
    cmp byte [esi + 2], '>'
    je .cm_end
.cm1:
    inc esi
    jmp .cm
.cm_end:
    add esi, 3
    mov [hp_src], esi
    jmp .done
.decl:                              ; <!DOCTYPE ...>, <?xml ...?>
    inc esi
.d1:
    cmp esi, [hp_end]
    jae .to_end
    lodsb
    cmp al, '>'
    jne .d1
    mov [hp_src], esi
    jmp .done
.to_end:
    mov eax, [hp_end]
    mov [hp_src], eax
    jmp .done
.lt:
    inc dword [hp_src]              ; a '<' that starts no tag
    mov eax, '<'
    call cp_out
.done:
    popad
    ret
; .can_skip: CF=0 if the element can be skipped to its end tag: it has
; content ("<svg/>" has none) and its whole name was read
.can_skip:
    cmp dword [hp_selfclose], 0
    jne .cant
    cmp dword [hp_nlen], 15
    jae .cant
    clc
    ret
.cant:
    stc
    ret

; hp_read_name: ESI at a name -> hp_name (lower case, up to 15 characters),
; hp_nlen; ESI past the name
hp_read_name:
    push eax
    push ecx
    xor ecx, ecx
.l: cmp esi, [hp_end]
    jae .e
    mov al, [esi]
    call is_name_char
    jc .e
    inc esi
    cmp ecx, 15
    jae .l
    call to_lower
    mov [hp_name + ecx], al
    inc ecx
    jmp .l
.e: mov byte [hp_name + ecx], 0
    mov [hp_nlen], ecx
    pop ecx
    pop eax
    ret

; is_name_char: AL -> CF=0 if it can be part of a tag or attribute name
is_name_char:
    cmp al, ' '
    jbe .no
    cmp al, '>'
    je .no
    cmp al, '/'
    je .no
    cmp al, '='
    je .no
    cmp al, '"'
    je .no
    cmp al, "'"
    je .no
    cmp al, '<'
    je .no
    clc
    ret
.no:
    stc
    ret

; tag_lookup: hp_name -> EAX = tag id, 0 if MOOS does not know it
tag_lookup:
    push ecx
    push esi
    push edi
    mov edi, tag_table
    mov ecx, 1
.l: cmp ecx, T_COUNT
    ja .no
    mov esi, hp_name
    call str_eq
    je .yes
    add edi, 16
    inc ecx
    jmp .l
.no:
    xor ecx, ecx
.yes:
    mov eax, ecx
    pop edi
    pop esi
    pop ecx
    ret

; hp_read_attrs: ESI after the tag name -> the attributes MOOS uses into
; hp_attrs (up to hp_apos), hp_hidden; ESI past the closing '>'
hp_read_attrs:
    push eax
    push ebx
    push ecx
    push edi
    mov dword [hp_apos], hp_attrs
    mov dword [hp_hidden], 0
    mov dword [hp_selfclose], 0
.next:
    cmp esi, [hp_end]
    jae .done
    mov al, [esi]
    cmp al, '>'
    je .gt
    call is_name_char
    jnc .name
    inc esi                         ; spaces, '/', stray quotes
    jmp .next
.gt:
    cmp byte [esi - 1], '/'         ; <tag ... /> has no content
    jne .gt1
    mov dword [hp_selfclose], 1
.gt1:
    inc esi
    jmp .done
.name:
    xor ecx, ecx                    ; the attribute's name, lower case
.n: cmp esi, [hp_end]
    jae .done
    mov al, [esi]
    call is_name_char
    jc .n_end
    inc esi
    cmp ecx, 22
    jae .n
    call to_lower
    mov [hp_an + ecx], al
    inc ecx
    jmp .n
.n_end:
    mov byte [hp_an + ecx], 0
.sp1:
    cmp esi, [hp_end]               ; "= value"?
    jae .done
    cmp byte [esi], ' '
    ja .eq
    inc esi
    jmp .sp1
.eq:
    mov [hp_vs], esi                ; (no value: empty)
    mov [hp_ve], esi
    cmp byte [esi], '='
    jne .have
    inc esi
.sp2:
    cmp esi, [hp_end]
    jae .done
    cmp byte [esi], ' '
    ja .val
    inc esi
    jmp .sp2
.val:
    mov al, [esi]
    cmp al, '"'
    je .quoted
    cmp al, "'"
    je .quoted
    mov [hp_vs], esi                ; unquoted: up to a space or '>'
.u: cmp esi, [hp_end]
    jae .uend
    cmp byte [esi], ' '
    jbe .uend
    cmp byte [esi], '>'
    je .uend
    inc esi
    jmp .u
.uend:
    mov [hp_ve], esi
    jmp .have
.quoted:
    inc esi
    mov [hp_vs], esi
.q: cmp esi, [hp_end]
    jae .qend
    cmp [esi], al
    je .qend
    inc esi
    jmp .q
.qend:
    mov [hp_ve], esi
    cmp esi, [hp_end]
    jae .have
    inc esi
.have:
    call hp_attr
    jmp .next
.done:
    pop edi
    pop ecx
    pop ebx
    pop eax
    ret

; hp_attr: the attribute hp_an with value hp_vs..hp_ve: keep it if MOOS uses
; it (hidden and style are looked at here)
hp_attr:
    pushad
    mov esi, hp_an
    mov edi, at_hidden
    call str_eq
    jne .not_hidden
    mov dword [hp_hidden], 1
    jmp .done
.not_hidden:
    mov edi, at_style
    call str_eq
    jne .not_style
    call hp_style
    jmp .done
.not_style:
    mov edi, at_class
    call str_eq
    jne .not_class
    call hp_class
    jmp .done
.not_class:
    mov edi, attr_names
.l: cmp byte [edi], 0
    je .done
    call str_eq
    je .found
.s: inc edi
    cmp byte [edi - 1], 0
    jne .s
    inc edi                         ; (the id)
    jmp .l
.found:
    call str_len                    ; ESI = name: skip it and its 0
    movzx eax, byte [edi + ecx + 1] ; the attribute id
    cmp eax, A_HREF
    je .url
    call hp_attr_begin
    mov esi, [hp_vs]
    mov ecx, [hp_ve]
    call hp_decode
    call hp_attr_end
    jmp .done
.url:
    call hp_attr_begin              ; a URL: entities decoded, but the
    mov esi, [hp_vs]                ; bytes kept as they are
.ul:
    cmp esi, [hp_ve]
    jae .uend
    movzx eax, byte [esi]
    cmp al, '&'
    jne .ub
    push dword [hp_src]
    push dword [hp_end]
    mov [hp_src], esi
    mov eax, [hp_ve]
    mov [hp_end], eax
    call hp_entity
    mov esi, [hp_src]
    pop dword [hp_end]
    pop dword [hp_src]
    cmp eax, 0x80
    jb .ub2
    mov eax, '?'                    ; (not ASCII: rare in a link)
    jmp .ub2
.ub:
    inc esi
.ub2:
    cmp eax, ' '
    jb .ul                          ; (new lines inside a link)
    call hp_asink
    jmp .ul
.uend:
    call hp_attr_end
.done:
    popad
    ret

; hp_attr_begin: EAX = attribute id -> start writing it to hp_attrs
hp_attr_begin:
    mov edi, [hp_apos]
    lea ecx, [edi + 1]
    mov [hp_aout], ecx
    mov ecx, hp_attrs + 2048 - 2
    mov [hp_alim], ecx
    cmp edi, ecx
    jae .full
    mov [edi], al
.full:
    mov dword [hp_sink], hp_asink
    ret

; hp_attr_end: finish the attribute value being written
hp_attr_end:
    push edi
    mov edi, [hp_aout]
    cmp edi, [hp_alim]
    ja .full
    mov byte [edi], 0
    inc edi
    mov [hp_apos], edi
.full:
    mov dword [hp_sink], hp_tsink
    pop edi
    ret

; hp_decode: ESI .. ECX = HTML text -> decoded through hp_sink
hp_decode:
    pushad
    push dword [hp_src]
    push dword [hp_end]
    mov [hp_src], esi
    mov [hp_end], ecx
.l: mov esi, [hp_src]
    cmp esi, [hp_end]
    jae .e
    call hp_char
    jmp .l
.e: pop dword [hp_end]
    pop dword [hp_src]
    popad
    ret

; hp_style: a style="..." value (hp_vs..hp_ve). Looks at display: none,
; visibility: hidden, font-weight, font-style, color and text-align.
hp_style:
    pushad
    mov esi, [hp_vs]
.decl:
    cmp esi, [hp_ve]
    jae .done
    call css_skip_sp
    mov ebx, esi                    ; EBX = the property
.p: cmp esi, [hp_ve]
    jae .done
    mov al, [esi]
    cmp al, ':'
    je .colon
    cmp al, ';'
    je .semi
    inc esi
    jmp .p
.semi:
    inc esi
    jmp .decl
.colon:
    mov ecx, esi
    sub ecx, ebx                    ; ECX = its length
    inc esi
    call css_skip_sp
    mov edx, esi                    ; EDX = the value
.v: cmp esi, [hp_ve]
    jae .have
    cmp byte [esi], ';'
    je .have
    inc esi
    jmp .v
.have:
    mov edi, css_display
    call css_is
    jne .nd
    mov edi, css_none
    call css_val_is
    jne .next
    mov dword [hp_hidden], 1
    jmp .next
.nd:
    mov edi, css_visibility
    call css_is
    jne .nv
    mov edi, css_hidden
    call css_val_is
    jne .next
    mov dword [hp_hidden], 1
    jmp .next
.nv:
    mov edi, css_weight
    call css_is
    jne .nw
    mov edi, css_bold
    call css_val_is
    je .bold
    mov al, [edx]                   ; 600, 700, 800, 900
    cmp al, '6'
    jb .next
    cmp al, '9'
    ja .next
.bold:
    mov eax, A_BOLD
    call hp_attr_flag
    jmp .next
.nw:
    mov edi, css_fstyle
    call css_is
    jne .ns
    mov edi, css_italic
    call css_val_is
    je .ital
    mov edi, css_oblique
    call css_val_is
    jne .next
.ital:
    mov eax, A_ITALIC
    call hp_attr_flag
    jmp .next
.ns:
    mov edi, css_color
    call css_is
    jne .nc
    mov eax, A_FG                   ; the value, up to the ';'
    call hp_attr_begin
.cv:
    cmp edx, esi
    jae .cv_end
    movzx eax, byte [edx]
    call hp_asink
    inc edx
    jmp .cv
.cv_end:
    call hp_attr_end
    jmp .next
.nc:
    mov edi, css_talign
    call css_is
    jne .next
    mov edi, css_center
    call css_val_is
    jne .next
    mov eax, A_ALIGN
    call hp_attr_flag
.next:
    cmp esi, [hp_ve]
    jae .done
    inc esi                         ; past the ';'
    jmp .decl
.done:
    popad
    ret

; hp_class: a class="..." value (hp_vs..hp_ve): hidden if one of its
; classes is a well-known "hide this" class (and none is screen-size
; dependent, like md:block)
hp_class:
    pushad
    xor ebp, ebp                    ; 1 = a hiding class seen
    mov esi, [hp_vs]
.tok:
    call css_skip_sp
    cmp esi, [hp_ve]
    jae .end
    mov ebx, esi                    ; EBX .. ESI = one class name
.t: cmp esi, [hp_ve]
    jae .have
    mov al, [esi]
    cmp al, ' '
    jbe .have
    cmp al, ':'
    je .colon
    inc esi
    jmp .t
.colon:
    jmp .done                       ; (screen-size dependent: shown)
.have:
    mov ecx, esi
    sub ecx, ebx
    mov edi, hide_classes
.h: cmp byte [edi], 0
    je .tok
    push ecx
    push esi
    mov esi, ebx
    repe cmpsb                      ; same characters ...
    pop esi
    pop ecx
    je .same
    cmp byte [edi - 1], 0           ; (it differed at the name's end: EDI
    je .h                           ; is at the next name already)
    jmp .skip
.same:
    cmp byte [edi], 0               ; ... and the same length
    jne .skip
    mov ebp, 1
.skip:
    cmp byte [edi], 0
    je .nx
    inc edi
    jmp .skip
.nx:
    inc edi
    jmp .h
.end:
    test ebp, ebp
    jz .done
    mov dword [hp_hidden], 1
.done:
    popad
    ret

; css_skip_sp: ESI past spaces (up to hp_ve)
css_skip_sp:
    cmp esi, [hp_ve]
    jae .r
    cmp byte [esi], ' '
    ja .r
    inc esi
    jmp css_skip_sp
.r: ret

; css_is: EBX = property, ECX = its length (may end in spaces), EDI = a
; name -> ZF=1 if it is that property
css_is:
    push eax
    push ecx
    push esi
    push edi
    mov esi, ebx
.l: jecxz .end
    mov al, [esi]
    cmp al, ' '
    jbe .end
    call to_lower
    cmp al, [edi]
    jne .out
    inc esi
    inc edi
    dec ecx
    jmp .l
.end:
    cmp byte [edi], 0
.out:
    pop edi
    pop esi
    pop ecx
    pop eax
    ret

; css_val_is: EDX = a value, EDI = a word -> ZF=1 if the value starts with it
css_val_is:
    push eax
    push esi
    push edi
    mov esi, edx
.l: mov ah, [edi]
    test ah, ah
    jz .out                         ; (ZF=1)
    cmp esi, [hp_ve]
    jae .no
    mov al, [esi]
    call to_lower
    cmp al, ah
    jne .out
    inc esi
    inc edi
    jmp .l
.no:
    or al, 1                        ; ZF=0
.out:
    pop edi
    pop esi
    pop eax
    ret

; hp_attr_flag: EAX = attribute id -> stored with the value "1"
hp_attr_flag:
    call hp_attr_begin
    push eax
    mov eax, '1'
    call hp_asink
    pop eax
    jmp hp_attr_end

; hp_emit_open: the element start for hp_tagid with its attributes
hp_emit_open:
    pushad
    call np_text_end
    mov al, NT_OPEN
    call np_byte
    mov eax, [hp_tagid]
    call np_byte
    mov ecx, [hp_apos]
    sub ecx, hp_attrs
    lea eax, [ecx + 1]
    call np_byte                    ; the attribute bytes (word)
    mov al, ah
    call np_byte
    mov esi, hp_attrs
    mov edi, [hp_out]
    rep movsb
    mov byte [edi], 0
    inc edi
    mov [hp_out], edi
    mov eax, [hp_tagid]             ; an image or input is something on the
    TAGBYTE ebx, eax, 12            ; line: a space after it is kept
    test ebx, TF_VOID
    jz .r
    mov dword [hp_sp], 0
.r: popad
    ret

; hp_skip_element: drop everything up to the end of the element named
; hp_name (counting the same element inside it), hp_src just after its
; start tag
hp_skip_element:
    pushad
    mov edx, 1                      ; depth
    mov esi, [hp_src]
.l: cmp esi, [hp_end]
    jae .end
    cmp byte [esi], '<'
    je .lt
    inc esi
    jmp .l
.lt:
    lea eax, [esi + 4]
    cmp eax, [hp_end]
    jae .plain
    cmp dword [esi], '<!--'
    jne .plain
    add esi, 4                      ; a comment: to its end
.cm:
    lea eax, [esi + 3]
    cmp eax, [hp_end]
    jae .end
    cmp word [esi], '--'
    jne .cm1
    cmp byte [esi + 2], '>'
    je .cm2
.cm1:
    inc esi
    jmp .cm
.cm2:
    add esi, 3
    jmp .l
.plain:
    inc esi
    cmp esi, [hp_end]
    jae .end
    cmp byte [esi], '/'
    je .endtag
    call hp_name_here
    jne .l
    inc edx                         ; the same element, inside
    jmp .l
.endtag:
    inc esi
    call hp_name_here
    jne .l
    dec edx
    jnz .l
.gt:
    cmp esi, [hp_end]               ; the end: past its '>'
    jae .end
    lodsb
    cmp al, '>'
    jne .gt
    mov [hp_src], esi
    popad
    ret
.end:
    mov eax, [hp_end]
    mov [hp_src], eax
    popad
    ret

; hp_name_here: ESI -> ZF=1 if the text there is hp_name followed by a
; character that ends a name
hp_name_here:
    push eax
    push ecx
    push esi
    mov ecx, [hp_nlen]
    lea eax, [esi + ecx]
    cmp eax, [hp_end]
    jae .no
    push edi
    mov edi, hp_name
.l: jecxz .e
    mov al, [esi]
    call to_lower
    cmp al, [edi]
    jne .no2
    inc esi
    inc edi
    dec ecx
    jmp .l
.e: pop edi
    mov al, [esi]
    call is_name_char
    jnc .no
    xor eax, eax                    ; ZF=1
    pop esi
    pop ecx
    pop eax
    ret
.no2:
    pop edi
.no:
    or al, 1                        ; ZF=0 (AL is restored below)
    pop esi
    pop ecx
    pop eax
    ret

; hp_raw_element: an element whose content is not HTML (script, style,
; title, textarea): find its end tag. A title is kept in br_title; a
; textarea becomes an empty element start (drawn as a box).
hp_raw_element:
    pushad
    mov esi, [hp_src]
    mov ebx, esi                    ; EBX = start of the content
.l: cmp esi, [hp_end]
    jae .found
    cmp byte [esi], '<'
    jne .n
    cmp byte [esi + 1], '/'
    jne .n
    push esi
    add esi, 2
    call hp_name_here
    pop esi
    je .found
.n: inc esi
    jmp .l
.found:
    mov edx, esi                    ; EDX = end of the content
.gt:
    cmp esi, [hp_end]
    jae .past
    lodsb
    cmp al, '>'
    jne .gt
.past:
    mov [hp_src], esi
    mov eax, [hp_tagid]
    cmp eax, T_TITLE
    je .title
    cmp eax, T_TEXTAREA
    jne .done
    call hp_emit_open
    jmp .done
.title:
    cmp byte [br_title], 0          ; (the first title only: an <svg> may
    jne .done                       ; have its own)
    mov dword [hp_aout], br_title
    mov dword [hp_alim], br_title + 150
    mov dword [hp_sink], hp_asink
    mov esi, ebx
    mov ecx, edx
    call hp_decode
    mov edi, [hp_aout]
    mov byte [edi], 0
    mov dword [hp_sink], hp_tsink
    mov esi, br_title               ; tidy it: no runs of spaces
    call str_squeeze
.done:
    popad
    ret

; str_squeeze: ESI = string -> spaces at the ends removed, runs made one
str_squeeze:
    pushad
    mov edi, esi
    xor edx, edx                    ; 1 = a space is waiting
.l: lodsb
    test al, al
    jz .e
    cmp al, ' '
    jne .c
    cmp edi, [esp + 4]              ; (the start: drop it)
    je .l
    mov edx, 1
    jmp .l
.c: test edx, edx
    jz .s
    mov byte [edi], ' '
    inc edi
    xor edx, edx
.s: stosb
    jmp .l
.e: mov byte [edi], 0
    popad
    ret

; ========================================================== 2. layout
section .data
quote_ch    db '"'
img_noalt   db "[image]", 0
img_link    db "[link]", 0
it_hidden   db "hidden", 0
it_submit   db "submit", 0
it_button   db "button", 0
it_reset    db "reset", 0
it_image    db "image", 0
it_checkbox db "checkbox", 0
it_radio    db "radio", 0
it_password db "password", 0
lbl_submit  db "Submit", 0
lbl_reset   db "Reset", 0
lbl_button  db "Button", 0
cb_off      db "[ ]", 0
cb_on       db "[x]", 0
rb_off      db "( )", 0
rb_on       db "(*)", 0
; colour names: name, 0, 0xRRGGBB
color_names:
    db "black", 0
    dd 0x000000
    db "red", 0
    dd 0xCC0000
    db "green", 0
    dd 0x008000
    db "blue", 0
    dd 0x0000CC
    db "navy", 0
    dd 0x000080
    db "maroon", 0
    dd 0x800000
    db "purple", 0
    dd 0x800080
    db "teal", 0
    dd 0x008080
    db "olive", 0
    dd 0x808000
    db "gray", 0
    dd 0x808080
    db "grey", 0
    dd 0x808080
    db "orange", 0
    dd 0xE07000
    db "brown", 0
    dd 0x8B4513
    db "darkred", 0
    dd 0x8B0000
    db "darkblue", 0
    dd 0x00008B
    db "darkgreen", 0
    dd 0x006400
    db 0

section .bss
alignb 4
ly_w        resd 1                  ; width of the page's text area
ly_x        resd 1                  ; where the next text goes on the line
ly_y        resd 1                  ; top of the current line
ly_lh       resd 1                  ; height of the current line so far
ly_first    resd 1                  ; its first item
ly_n        resd 1                  ; items on the page
ly_pm       resd 1                  ; room to leave before the next line
ly_ps       resd 1                  ; 1 = a space before the next word
ly_begun    resd 1                  ; 1 = the current line has started
ly_mark     resd 1                  ; 1 = it holds only a list bullet so far
ly_sp       resd 1                  ; elements open (the stack)
ly_pool     resd 1                  ; next free byte of BR_POOL
ly_na       resd 1                  ; anchors
ly_h        resd 1                  ; height of the whole page
ly_tag      resd 1
ly_attrs    resd 1
ly_num      resd 1
ly_fld      resd 1                  ; the field ly_field made
ly_next     resd 1
ly_nt       resd 1                  ; tables measured
ly_nf       resd 1                  ; forms
ly_ni       resd 1                  ; form fields
tm_col      resd 1                  ; (ly_table_measure)
tm_cur      resd 1
tm_n        resd 1
tm_w        resd TB_COLS
ly_sflags   resd 1                  ; (a style kept while an input is drawn)
ly_sfg      resd 1
ly_sbg      resd 1
ly_st       resb ST_SIZE            ; the current style
section .text

; html_layout: EAX = width in pixels -> the display list (BR_ITEMS, ly_n),
; the page's height (ly_h) and its anchors
html_layout:
    pushad
    mov [ly_w], eax
    xor ecx, ecx
    mov [ly_x], ecx
    mov [ly_lh], ecx
    mov [ly_first], ecx
    mov [ly_n], ecx
    mov [ly_pm], ecx
    mov [ly_ps], ecx
    mov [ly_begun], ecx
    mov [ly_mark], ecx
    mov [ly_sp], ecx
    mov [ly_na], ecx
    mov dword [ly_y], 10
    mov dword [ly_pool], BR_POOL
    mov edi, ly_st
    push eax
    xor eax, eax
    mov ecx, ST_SIZE / 4
    rep stosd
    pop eax
    mov dword [ly_st + ST_CW], 8
    mov dword [ly_st + ST_FG], C_TEXT
    mov dword [ly_st + ST_BG], -1
    mov dword [ly_st + ST_TABLE], -1
    mov dword [ly_st + ST_FORM], -1
    mov [ly_st + ST_RIGHT], eax
    mov dword [ly_nt], 0
    mov dword [ly_nf], 0
    mov dword [ly_ni], 0
    mov esi, BR_NODES
.node:
    movzx eax, byte [esi]
    cmp al, NT_TEXT
    je .text
    cmp al, NT_OPEN
    je .open
    cmp al, NT_CLOSE
    je .close
    jmp .end
.text:
    movzx ecx, word [esi + 1]
    add esi, 3
    call ly_text
    add esi, ecx
    jmp .node
.open:
    movzx eax, byte [esi + 1]
    movzx ecx, word [esi + 2]
    add esi, 4
    lea edx, [esi + ecx]
    mov [ly_next], edx              ; (the node after it: tables look ahead)
    call ly_open
    add esi, ecx
    jmp .node
.close:
    movzx eax, byte [esi + 1]
    add esi, 2
    call ly_close
    jmp .node
.end:
    xor eax, eax                    ; close whatever is still open
    call ly_pop_to
    mov dword [ly_mark], 0
    call ly_finish
    mov eax, [ly_y]
    add eax, [ly_pm]
    add eax, 16
    mov [ly_h], eax
    popad
    ret

; ly_lineh: EAX = character width -> EAX = height of a line of that text
ly_lineh:
    push edx
    mov edx, eax
    add eax, eax
    shr edx, 2
    add eax, edx
    pop edx
    ret

; ly_content: EAX = 1 (ZF=0) if the current line has text on it
ly_content:
    mov eax, [ly_n]
    cmp eax, [ly_first]
    jbe .no
    cmp dword [ly_mark], 0
    jne .no
    mov eax, 1
    test eax, eax
    ret
.no:
    xor eax, eax
    ret

; ly_begin: start a line, if not started: below the pending margin, at the
; current left edge
ly_begin:
    cmp dword [ly_begun], 0
    jne .r
    push eax
    mov dword [ly_begun], 1
    mov eax, [ly_pm]
    add [ly_y], eax
    mov dword [ly_pm], 0
    mov eax, [ly_st + ST_LEFT]
    mov [ly_x], eax
    mov eax, [ly_n]
    mov [ly_first], eax
    pop eax
.r: ret

; ly_finish: end the current line: centre it if asked, line up the bottoms
; of its text, and move down by its height
ly_finish:
    cmp dword [ly_begun], 0
    je .r
    pushad
    mov esi, [ly_first]
    mov ecx, [ly_n]
    sub ecx, esi
    jbe .done
    shl esi, 5
    add esi, BR_ITEMS
    xor edx, edx                    ; EDX = how far right (centring)
    test dword [ly_st + ST_FLAGS], SF_CENTER
    jz .l
    mov edx, [ly_st + ST_RIGHT]
    sub edx, [ly_x]
    sar edx, 1
    jns .l
    xor edx, edx
.l: add [esi + DI_X], edx
    cmp byte [esi + DI_TYPE], DT_TEXT
    jne .n
    movzx eax, byte [esi + DI_CW]
    call ly_lineh
    neg eax
    add eax, [ly_lh]
    add eax, [ly_y]
    mov [esi + DI_Y], eax
.n: add esi, DI_SIZE
    dec ecx
    jnz .l
.done:
    mov eax, [ly_lh]
    add [ly_y], eax
    popad
    push eax
    xor eax, eax
    mov [ly_begun], eax
    mov [ly_lh], eax
    mov [ly_mark], eax
    mov [ly_ps], eax
    mov eax, [ly_n]
    mov [ly_first], eax
    pop eax
.r: ret

; ly_block_break: a block starts or ends: finish the line (unless it holds
; only a list bullet, which waits for the item's first text)
ly_block_break:
    mov dword [ly_ps], 0
    cmp dword [ly_mark], 0
    jne .r
    call ly_finish
.r: ret

; ly_margin: ECX = pixels of room wanted before the next line (margins
; next to each other do not add up: the larger one counts)
ly_margin:
    cmp ecx, [ly_pm]
    jbe .r
    mov [ly_pm], ecx
.r: ret

; ly_flush_margin: a new line starts here, below the pending margin
ly_flush_margin:
    cmp dword [ly_begun], 0
    jne .r
    push eax
    mov eax, [ly_pm]
    add [ly_y], eax
    mov dword [ly_pm], 0
    pop eax
.r: ret

; ly_br: end the line here (<br>, or a new line in <pre>); on an empty line
; this leaves a blank line
ly_br:
    push eax
    call ly_begin
    mov eax, [ly_st + ST_CW]
    call ly_lineh
    cmp eax, [ly_lh]
    jbe .h
    mov [ly_lh], eax
.h: mov dword [ly_mark], 0
    call ly_finish
    pop eax
    ret

; ly_item: -> EDI = a new, cleared item; CF=1 if the list is full
ly_item:
    mov edi, [ly_n]
    cmp edi, BR_MAX_ITEMS
    jae .full
    inc dword [ly_n]
    shl edi, 5
    add edi, BR_ITEMS
    push eax
    push ecx
    push edi
    xor eax, eax
    mov ecx, DI_SIZE / 4
    rep stosd
    pop edi
    pop ecx
    pop eax
    clc
    ret
.full:
    stc
    ret

; ly_rect: a filled rectangle at ECX = x, the current y, ESI = width,
; EDI = height, EAX = colour -> EAX = its item number (-1 if none). It is
; not part of a line.
ly_rect:
    push edi
    push edi
    call ly_item
    pop edx                         ; (the height)
    jc .full
    mov byte [edi + DI_TYPE], DT_RECT
    mov [edi + DI_FG], eax
    mov [edi + DI_X], ecx
    mov eax, [ly_y]
    mov [edi + DI_Y], eax
    mov [edi + DI_W], si
    mov [edi + DI_H], dx
    mov eax, [ly_n]
    mov [ly_first], eax
    dec eax
    pop edi
    ret
.full:
    mov eax, -1
    pop edi
    ret

; ly_text: ESI = text of a node, ECX = its length -> words onto lines
ly_text:
    pushad
    lea edx, [esi + ecx]            ; EDX = the end
.next:
    cmp esi, edx
    jae .done
    mov al, [esi]
    test dword [ly_st + ST_FLAGS], SF_PRE
    jnz .pre
    cmp al, ' '
    jne .word
    call ly_content                 ; a space: before the next word, unless
    jz .sp                          ; the line is still empty
    mov dword [ly_ps], 1
.sp:
    inc esi
    jmp .next
.word:
    mov edi, esi
.w: inc edi
    cmp edi, edx
    jae .wend
    cmp byte [edi], ' '
    jne .w
.wend:
    mov ecx, edi
    sub ecx, esi
    call ly_word
    mov esi, edi
    jmp .next
.pre:                               ; <pre>: spaces are kept, lines end at
    cmp al, 10                      ; new-line characters
    jne .pword
    call ly_br
    inc esi
    jmp .next
.pword:
    mov edi, esi
.p: inc edi
    cmp edi, edx
    jae .pend
    cmp byte [edi], 10
    jne .p
.pend:
    mov ecx, edi
    sub ecx, esi
    call ly_word
    mov esi, edi
    jmp .next
.done:
    popad
    ret

; ly_word: ESI = a word, ECX = its length -> onto the line, or the next
; line if it does not fit. A word longer than a whole line is split.
ly_word:
    pushad
.again:
    test ecx, ecx
    jz .done
    call ly_begin
    mov ebx, [ly_st + ST_CW]
    xor edx, edx                    ; EDX = width of the space before it
    cmp dword [ly_ps], 0
    je .nosp
    call ly_content
    jz .nosp
    mov edx, ebx
.nosp:
    mov eax, [ly_st + ST_RIGHT]
    sub eax, [ly_x]
    sub eax, edx                    ; EAX = room left
    mov edi, ecx
    imul edi, ebx                   ; EDI = room needed
    cmp edi, eax
    jle .fits
    call ly_content
    jz .split
    call ly_finish                  ; on the next line, then
    jmp .again
.split:                             ; too long even for a line of its own
    mov eax, [ly_st + ST_RIGHT]
    sub eax, [ly_x]
    cdq
    idiv ebx
    cmp eax, 1
    jge .k1
    mov eax, 1
.k1:
    cmp eax, ecx
    jbe .k2
    mov eax, ecx
.k2:
    push ecx
    mov ecx, eax
    xor edx, edx
    call ly_place
    pop ecx
    add esi, eax
    sub ecx, eax
    call ly_finish
    jmp .again
.fits:
    call ly_place
.done:
    popad
    ret

; ly_place: ESI = characters, ECX = how many, EDX = space before them ->
; an item at the end of the line (or the last item made longer, if these
; characters follow its own in the page text, in the same style)
ly_place:
    pushad
    call ly_begin
    mov eax, [ly_n]
    cmp eax, [ly_first]
    jbe .new
    dec eax
    shl eax, 5
    lea edi, [BR_ITEMS + eax]       ; the last item
    cmp byte [edi + DI_TYPE], DT_TEXT
    jne .new
    movzx eax, byte [edi + DI_CW]
    cmp eax, [ly_st + ST_CW]
    jne .new
    mov al, [edi + DI_STYLE]
    cmp al, [ly_st + ST_FLAGS]
    jne .new
    mov eax, [edi + DI_FG]
    cmp eax, [ly_st + ST_FG]
    jne .new
    mov eax, [edi + DI_BG]
    cmp eax, [ly_st + ST_BG]
    jne .new
    mov eax, [edi + DI_LINK]
    cmp eax, [ly_st + ST_LINK]
    jne .new
    mov eax, [edi + DI_X]           ; does it end where these start?
    movzx ebx, word [edi + DI_W]
    add eax, ebx
    cmp eax, [ly_x]
    jne .new
    movzx ebx, byte [edi + DI_LEN]
    mov eax, [edi + DI_TEXT]
    add eax, ebx                    ; just after its characters
    test edx, edx
    jz .nsp
    cmp byte [eax], ' '             ; (the space between is in the text)
    jne .new
    inc eax
    inc ebx
.nsp:
    cmp eax, esi
    jne .new
    add ebx, ecx
    cmp ebx, 255
    ja .new
    mov [edi + DI_LEN], bl
    mov eax, ebx
    imul eax, [ly_st + ST_CW]
    mov [edi + DI_W], ax
    jmp .moved
.new:
    call ly_item
    jc .moved
    mov byte [edi + DI_TYPE], DT_TEXT
    mov al, [ly_st + ST_FLAGS]
    mov [edi + DI_STYLE], al
    mov eax, [ly_st + ST_CW]
    mov [edi + DI_CW], al
    add eax, eax
    mov [edi + DI_H], ax
    mov [edi + DI_LEN], cl
    mov eax, [ly_x]
    add eax, edx
    mov [edi + DI_X], eax
    mov eax, [ly_y]
    mov [edi + DI_Y], eax
    mov eax, ecx
    imul eax, [ly_st + ST_CW]
    mov [edi + DI_W], ax
    mov eax, [ly_st + ST_FG]
    mov [edi + DI_FG], eax
    mov eax, [ly_st + ST_BG]
    mov [edi + DI_BG], eax
    mov [edi + DI_TEXT], esi
    mov eax, [ly_st + ST_LINK]
    mov [edi + DI_LINK], eax
.moved:
    mov eax, ecx
    imul eax, [ly_st + ST_CW]
    add eax, edx
    add [ly_x], eax
    mov eax, [ly_st + ST_CW]
    call ly_lineh
    cmp eax, [ly_lh]
    jbe .lh
    mov [ly_lh], eax
.lh:
    xor eax, eax
    mov [ly_ps], eax
    mov [ly_mark], eax
    popad
    ret

; ------------------------------------------------- elements start and end
; ly_flags: EAX = tag -> EBX = its TF_* flags
ly_flags:
    TAGBYTE ebx, eax, 12
    ret

; ly_push: EAX = tag -> the current style saved on the stack with it.
; CF=1 if the stack is full.
ly_push:
    push ecx
    push esi
    push edi
    mov edi, [ly_sp]
    cmp edi, BR_MAX_DEPTH
    jae .full
    shl edi, 6
    add edi, BR_STACK
    mov esi, ly_st
    mov ecx, ST_SIZE / 4
    rep movsd
    sub edi, ST_SIZE
    mov [edi + SE_TAG], eax
    mov dword [edi + SE_RECT], -1
    inc dword [ly_sp]
    clc
    jmp .out
.full:
    stc
.out:
    pop edi
    pop esi
    pop ecx
    ret

; ly_top: -> EDI = the stack entry of the innermost open element
ly_top:
    mov edi, [ly_sp]
    dec edi
    shl edi, 6
    add edi, BR_STACK
    ret

; ly_pop_one: the innermost element ends
ly_pop_one:
    pushad
    call ly_top
    dec dword [ly_sp]
    mov eax, [edi + SE_TAG]
    cmp eax, T_Q
    jne .nq
    mov esi, quote_ch               ; </q>: the closing quote mark
    mov ecx, 1
    call ly_word
.nq:
    cmp eax, T_LI
    jne .nli
    mov dword [ly_mark], 0          ; (an empty item still takes a line)
.nli:
    call ly_flags
    test ebx, TF_BLOCK
    jz .nb
    call ly_block_break
.nb:
    cmp eax, T_PRE
    jne .np
    add dword [ly_y], 6             ; (room under the text in the box)
.np:
    mov ecx, [edi + SE_RECT]        ; a box or bar beside it: now its height
    cmp ecx, -1                     ; is known
    je .nr
    shl ecx, 5
    add ecx, BR_ITEMS
    mov edx, [ly_y]
    sub edx, [ecx + DI_Y]
    mov [ecx + DI_H], dx
.nr:
    test ebx, TF_BLOCK
    jz .restore
    TAGBYTE ecx, eax, 13
    cmp eax, T_UL                   ; (a list inside a list: no margin)
    je .list
    cmp eax, T_OL
    jne .m
.list:
    cmp dword [edi + ST_DEPTH], 0
    je .m
    xor ecx, ecx
.m: call ly_margin
.restore:
    mov esi, edi                    ; the style from before it started
    mov edi, ly_st
    mov ecx, ST_SIZE / 4
    rep movsd
    popad
    ret

; ly_pop_to: EAX = stack depth -> close elements until only that many are
; open
ly_pop_to:
.l: cmp [ly_sp], eax
    jle .r
    call ly_pop_one
    jmp .l
.r: ret

; ly_close: EAX = tag of an end tag: close it (and anything inside it that
; is still open). An end tag for something not open is ignored.
ly_close:
    pushad
    mov ecx, [ly_sp]
.l: dec ecx
    js .done
    mov edi, ecx
    shl edi, 6
    add edi, BR_STACK
    cmp [edi + SE_TAG], eax
    jne .l
    mov eax, ecx
    call ly_pop_to
.done:
    popad
    ret

; ly_find_pop: look down the stack for tag EAX or EBX, giving up at tag
; ECX or EDX; if found, close it
ly_find_pop:
    pushad
    mov esi, [ly_sp]
.l: dec esi
    js .done
    mov edi, esi
    shl edi, 6
    add edi, BR_STACK
    mov edi, [edi + SE_TAG]
    cmp edi, eax
    je .found
    cmp edi, ebx
    je .found
    cmp edi, ecx
    je .done
    cmp edi, edx
    je .done
    jmp .l
.found:
    mov eax, esi
    call ly_pop_to
.done:
    popad
    ret

; ly_autoclose: EAX = a tag about to start: end the elements HTML lets a
; page leave open (<p> before a block, <li> before the next <li>, ...)
ly_autoclose:
    pushad
    mov edx, eax
    call ly_flags
    test ebx, TF_BLOCK
    jnz .p
    cmp edx, T_TD
    je .p
    cmp edx, T_TH
    jne .lists
.p: mov ecx, [ly_sp]                ; an open <p>, with only inline
.pl:                                ; elements above it
    dec ecx
    js .lists
    mov edi, ecx
    shl edi, 6
    add edi, BR_STACK
    mov eax, [edi + SE_TAG]
    cmp eax, T_P
    je .pfound
    call ly_flags
    test ebx, TF_BLOCK
    jnz .lists
    jmp .pl
.pfound:
    mov eax, ecx
    call ly_pop_to
.lists:
    cmp edx, T_LI
    jne .ndl
    mov eax, T_LI
    mov ebx, T_LI
    mov ecx, T_UL
    mov edi, T_OL
    jmp .find
.ndl:
    cmp edx, T_DT
    je .dd
    cmp edx, T_DD
    jne .ntr
.dd:
    mov eax, T_DT
    mov ebx, T_DD
    mov ecx, T_DL
    mov edi, T_DL
    jmp .find
.ntr:
    cmp edx, T_TR
    jne .ntd
    mov eax, T_TR
    mov ebx, T_TR
    mov ecx, T_TABLE
    mov edi, T_TABLE
    jmp .find
.ntd:
    cmp edx, T_TD
    je .td
    cmp edx, T_TH
    jne .done
.td:
    mov eax, T_TD
    mov ebx, T_TH
    mov ecx, T_TR
    mov edi, T_TABLE
.find:
    mov edx, edi
    call ly_find_pop
.done:
    popad
    ret

; ly_find_attr: EAX = attribute id -> ESI = its value in the current
; element's attributes; CF=1 if it has none
ly_find_attr:
    mov esi, [ly_attrs]
.l: cmp byte [esi], 0
    je .no
    cmp [esi], al
    je .yes
.s: inc esi
    cmp byte [esi], 0
    jne .s
    inc esi
    jmp .l
.yes:
    inc esi
    clc
    ret
.no:
    stc
    ret

; ly_open: EAX = tag, ESI = its attributes -> an element starts
ly_open:
    pushad
    mov [ly_tag], eax
    mov [ly_attrs], esi
    call ly_flags
    test ebx, TF_VOID
    jnz .void
    cmp eax, T_TEXTAREA
    je .void
    call ly_autoclose
    mov eax, [ly_tag]
    cmp eax, T_LI                   ; numbers and cells count in the
    jne .nli                        ; element around them
    mov ecx, [ly_st + ST_COUNT]
    mov [ly_num], ecx
    inc dword [ly_st + ST_COUNT]
.nli:
    cmp eax, T_TD
    je .cell
    cmp eax, T_TH
    jne .ncell
.cell:
    mov ecx, [ly_st + ST_CELL]
    mov [ly_num], ecx
    inc dword [ly_st + ST_CELL]
.ncell:
    call ly_push
    jc .done
    mov eax, [ly_tag]
    call ly_flags
    test ebx, TF_BLOCK
    jz .inline
    call ly_block_break
    TAGBYTE ecx, eax, 13
    cmp eax, T_UL
    je .lm
    cmp eax, T_OL
    jne .m
.lm:
    cmp dword [ly_st + ST_DEPTH], 0
    je .m
    xor ecx, ecx
.m: call ly_margin
.inline:
    TAGBYTE ebx, eax, 14
    mov ecx, ebx
    and ecx, 0x0F                   ; bold, italic, underline, strike
    or [ly_st + ST_FLAGS], ecx
    test ebx, SB_CODE
    jz .ncode
    mov dword [ly_st + ST_FG], C_CODE_FG
    mov dword [ly_st + ST_BG], C_CODE_BG
.ncode:
    test ebx, SB_MARK
    jz .nmark
    mov dword [ly_st + ST_BG], C_MARK
.nmark:
    test ebx, SB_HEAD
    jz .nhead
    mov dword [ly_st + ST_FG], C_HEAD
.nhead:
    TAGBYTE ecx, eax, 15
    test ecx, ecx
    jz .ncw
    mov [ly_st + ST_CW], ecx
.ncw:
    call ly_attrs_apply
    mov eax, [ly_tag]
    cmp eax, T_A
    je .a
    cmp eax, T_PRE
    je .pre
    cmp eax, T_BLOCKQUOTE
    je .quote
    cmp eax, T_UL
    je .ul
    cmp eax, T_OL
    je .ol
    cmp eax, T_LI
    je .li
    cmp eax, T_DD
    je .dd
    cmp eax, T_CENTER
    je .center
    cmp eax, T_TD
    je .td
    cmp eax, T_TH
    je .td
    cmp eax, T_TR
    je .tr
    cmp eax, T_TABLE
    je .table
    cmp eax, T_Q
    je .q
    cmp eax, T_BUTTON
    je .button
    cmp eax, T_FORM
    je .form
    jmp .done
.form:
    mov ecx, [ly_nf]                ; a form: where it is sent, and how
    cmp ecx, BR_MAX_FORMS
    jae .done
    inc dword [ly_nf]
    mov [ly_st + ST_FORM], ecx
    lea edi, [BR_FORMS + ecx * 8]
    xor edx, edx
    mov eax, A_ACTION
    call ly_find_attr
    jc .fa
    mov edx, esi
.fa:
    mov [edi + FM_ACTION], edx
    xor edx, edx
    mov eax, A_METHOD
    call ly_find_attr
    jc .fm
    mov al, [esi]
    or al, 0x20
    cmp al, 'p'
    jne .fm
    inc edx
.fm:
    mov [edi + FM_POST], edx
    jmp .done
.a:
    mov eax, A_HREF
    call ly_find_attr
    jc .done
    mov [ly_st + ST_LINK], esi
    mov dword [ly_st + ST_FG], C_LINK
    or dword [ly_st + ST_FLAGS], GS_ULINE
    jmp .done
.pre:
    or dword [ly_st + ST_FLAGS], SF_PRE
    call ly_flush_margin
    mov ecx, [ly_st + ST_LEFT]      ; a tinted box behind it
    mov esi, [ly_st + ST_RIGHT]
    sub esi, ecx
    xor edi, edi
    mov eax, C_PRE_BG
    call ly_rect
    call ly_top
    mov [edi + SE_RECT], eax
    add dword [ly_y], 6
    mov eax, 10
    call ly_indent
    sub dword [ly_st + ST_RIGHT], 10
    jmp .done
.quote:
    call ly_flush_margin
    mov ecx, [ly_st + ST_LEFT]      ; a bar down its left side
    add ecx, 6
    mov esi, 3
    xor edi, edi
    mov eax, C_RULE
    call ly_rect
    call ly_top
    mov [edi + SE_RECT], eax
    mov eax, 32
    call ly_indent
    sub dword [ly_st + ST_RIGHT], 16
    jmp .done
.ul:
    mov dword [ly_st + ST_LIST], 1
    jmp .list
.ol:
    mov dword [ly_st + ST_LIST], 2
    mov dword [ly_st + ST_COUNT], 1
    mov eax, A_START
    call ly_find_attr
    jc .list
    call parse_uint
    jc .list
    mov [ly_st + ST_COUNT], eax
.list:
    inc dword [ly_st + ST_DEPTH]
    mov eax, 32
    call ly_indent
    jmp .done
.li:
    cmp dword [ly_st + ST_LIST], 0  ; (an item outside any list)
    jne .li2
    mov eax, 32
    call ly_indent
.li2:
    call ly_marker
    jmp .done
.dd:
    mov eax, 32
    call ly_indent
    jmp .done
.center:
    or dword [ly_st + ST_FLAGS], SF_CENTER
    jmp .done
.td:
    mov eax, [ly_st + ST_TABLE]     ; a measured table: to its column
    cmp eax, -1
    je .td_flow
    shl eax, 7
    add eax, BR_TABLES
    mov ecx, [ly_num]
    cmp ecx, [eax + TI_N]
    jae .td_flow
    mov edx, [eax + TI_LEFT]
    add edx, [eax + TI_X + ecx * 4]
    call ly_begin
    cmp [ly_x], edx
    jg .td_over
    mov [ly_x], edx
    mov dword [ly_ps], 0
    jmp .done
.td_over:
    mov dword [ly_ps], 1
    jmp .done
.td_flow:
    cmp dword [ly_num], 0           ; not the row's first cell: a gap
    je .done
    call ly_content
    jz .done
    mov eax, [ly_st + ST_CW]
    add eax, eax
    add [ly_x], eax
    mov dword [ly_ps], 1
    jmp .done
.table:
    call ly_table_measure
.tr:
    mov dword [ly_st + ST_CELL], 0
    jmp .done
.q:
    mov esi, quote_ch
    mov ecx, 1
    call ly_word
    jmp .done
.button:
    mov dword [ly_st + ST_BG], C_BUTTON_BG
    mov dword [ly_st + ST_FG], C_TEXT
    mov eax, IT_SUBMIT              ; <button>: clicking its text sends the
    mov ecx, 0                      ; form (like a link to it)
    call ly_field
    jc .done
    mov edi, [ly_fld]
    mov eax, A_TYPE                 ; (type=button / reset: does nothing)
    call ly_find_attr
    jc .bt
    cmp byte [esi], 's'
    je .bt
    cmp byte [esi], 'S'
    je .bt
    mov dword [edi + IN_TYPE], IT_BUTTON
.bt:
    mov [ly_st + ST_LINK], edi
    jmp .done
.void:
    call ly_void
.done:
    popad
    ret

; ly_table_measure: a <table> starts (ly_next = its first node): if it is a
; simple one - no table or block inside a cell, at most TB_COLS columns,
; and narrow enough - measure its columns, so that its cells line up.
; Sets ST_TABLE (-1 if not).
ly_table_measure:
    pushad
    mov dword [ly_st + ST_TABLE], -1
    cmp dword [ly_nt], BR_MAX_TABLES
    jae .done
    mov edi, tm_w
    xor eax, eax
    mov ecx, TB_COLS
    rep stosd
    mov dword [tm_col], -1
    mov [tm_cur], eax
    mov [tm_n], eax
    mov esi, [ly_next]
.node:
    movzx eax, byte [esi]
    cmp al, NT_TEXT
    je .text
    cmp al, NT_OPEN
    je .open
    cmp al, NT_CLOSE
    je .close
    jmp .end
.text:
    movzx ecx, word [esi + 1]
    add esi, 3
    cmp dword [tm_col], 0
    jl .tn
    mov edx, ecx
    cmp dword [tm_cur], 0           ; (a space starting a cell does not show)
    jne .tadd
    cmp byte [esi], ' '
    jne .tadd
    dec edx
.tadd:
    add [tm_cur], edx
.tn:
    add esi, ecx
    jmp .node
.open:
    movzx eax, byte [esi + 1]
    movzx ecx, word [esi + 2]
    lea esi, [esi + ecx + 4]
    cmp eax, T_TABLE
    je .done                        ; a table in a table: not simple
    cmp eax, T_TR
    je .row
    cmp eax, T_TD
    je .cell
    cmp eax, T_TH
    je .cell
    cmp dword [tm_col], 0
    jl .node
    cmp eax, T_IMG                  ; (roughly how wide these are drawn)
    jne .ni
    add dword [tm_cur], 10
    jmp .node
.ni:
    cmp eax, T_INPUT
    jne .nin
    add dword [tm_cur], 22
    jmp .node
.nin:
    cmp eax, T_BR
    je .done
    TAGBYTE ebx, eax, 12
    test ebx, TF_BLOCK              ; a block inside a cell: not simple
    jnz .done
    jmp .node
.row:
    call .endcell
    mov dword [tm_col], -1
    jmp .node
.cell:
    call .endcell
    inc dword [tm_col]
    cmp dword [tm_col], TB_COLS
    jae .done
    jmp .node
.close:
    movzx eax, byte [esi + 1]
    add esi, 2
    cmp eax, T_TABLE
    je .end
    cmp eax, T_TD
    je .cl
    cmp eax, T_TH
    je .cl
    cmp eax, T_TR
    jne .node
.cl:
    call .endcell
    jmp .node
.end:
    call .endcell
    mov ecx, [tm_n]
    test ecx, ecx
    jz .done
    mov ebx, [ly_nt]                ; the column places
    shl ebx, 7
    add ebx, BR_TABLES
    mov [ebx + TI_N], ecx
    mov eax, [ly_st + ST_LEFT]
    mov [ebx + TI_LEFT], eax
    xor edx, edx                    ; EDX = x of the next column
    xor edi, edi
.col:
    mov [ebx + TI_X + edi * 4], edx
    mov eax, [tm_w + edi * 4]
    add eax, 2                      ; (two characters between columns)
    imul eax, [ly_st + ST_CW]
    add edx, eax
    inc edi
    cmp edi, ecx
    jb .col
    mov eax, [ly_st + ST_CW]        ; does it fit?
    add eax, eax
    sub edx, eax
    mov eax, [ly_st + ST_RIGHT]
    sub eax, [ly_st + ST_LEFT]
    cmp edx, eax
    jg .done
    mov eax, [ly_nt]
    mov [ly_st + ST_TABLE], eax
    inc dword [ly_nt]
.done:
    popad
    ret
; .endcell: the cell being measured ends: its width counts for its column
.endcell:
    mov eax, [tm_col]
    test eax, eax
    js .ec
    mov edx, [tm_cur]
    cmp edx, [tm_w + eax * 4]
    jbe .ec1
    mov [tm_w + eax * 4], edx
.ec1:
    inc eax
    cmp eax, [tm_n]
    jbe .ec
    mov [tm_n], eax
.ec:
    mov dword [tm_cur], 0
    ret

; ly_indent: EAX = pixels -> the left edge moves right that much, but the
; text keeps at least 100 pixels (deep lists in a narrow window)
ly_indent:
    push ecx
    mov ecx, [ly_st + ST_RIGHT]
    sub ecx, [ly_st + ST_LEFT]
    sub ecx, 100
    jle .r
    cmp eax, ecx
    jle .add
    mov eax, ecx
.add:
    add [ly_st + ST_LEFT], eax
.r: pop ecx
    ret

; ly_attrs_apply: the current element's colour, bold, italic, centring,
; and its id (a place a link can jump to)
ly_attrs_apply:
    pushad
    mov esi, [ly_attrs]
.l: movzx eax, byte [esi]
    test eax, eax
    jz .done
    inc esi
    cmp eax, A_FG
    je .fg
    cmp eax, A_BOLD
    je .bold
    cmp eax, A_ITALIC
    je .ital
    cmp eax, A_ALIGN
    je .align
    cmp eax, A_ID
    je .id
    cmp eax, A_NAME                 ; <a name="...">: a place to jump to
    jne .skip
    cmp dword [ly_tag], T_A
    je .id
    jmp .skip
.fg:
    call color_parse
    jc .skip
    call color_light                ; (white text on our white page: no)
    jnc .skip
    mov [ly_st + ST_FG], eax
    jmp .skip
.bold:
    or dword [ly_st + ST_FLAGS], GS_BOLD
    jmp .skip
.ital:
    or dword [ly_st + ST_FLAGS], GS_ITALIC
    jmp .skip
.align:
    mov al, [esi]
    or al, 0x20
    cmp al, 'c'
    je .center
    cmp al, '1'
    jne .skip
.center:
    or dword [ly_st + ST_FLAGS], SF_CENTER
    jmp .skip
.id:
    mov eax, [ly_y]
    cmp dword [ly_begun], 0
    jne .y
    add eax, [ly_pm]
.y: call ly_anchor
.skip:
    lodsb
    test al, al
    jnz .skip
    jmp .l
.done:
    popad
    ret

; ly_anchor: ESI = a name, EAX = its y on the page -> remembered
ly_anchor:
    push edi
    mov edi, [ly_na]
    cmp edi, BR_MAX_ANCH
    jae .r
    inc dword [ly_na]
    shl edi, 3
    add edi, BR_ANCH
    mov [edi], esi
    mov [edi + 4], eax
.r: pop edi
    ret

; html_anchor_y: ESI = a name (from a link's #part) -> EAX = where it is on
; the page; CF=1 if the page has no such place
html_anchor_y:
    push ecx
    push edi
    xor ecx, ecx
.l: cmp ecx, [ly_na]
    jae .no
    mov edi, ecx
    shl edi, 3
    add edi, BR_ANCH
    push edi
    mov edi, [edi]
    call str_eq
    pop edi
    je .yes
    inc ecx
    jmp .l
.yes:
    mov eax, [edi + 4]
    clc
    jmp .out
.no:
    stc
.out:
    pop edi
    pop ecx
    ret

; ly_marker: the bullet or number of a list item, left of its text
ly_marker:
    pushad
    call ly_pool_begin              ; EDI = where its text goes
    cmp dword [ly_st + ST_LIST], 2
    jne .bullet
    mov eax, [ly_num]               ; "12."
    call ly_pool_num
    mov al, '.'
    stosb
    jmp .made
.bullet:
    mov al, 0x07                    ; a dot, a circle, then a square
    cmp dword [ly_st + ST_DEPTH], 2
    jb .b
    mov al, 0x09
    je .b
    mov al, 0xFE
.b: stosb
.made:
    call ly_pool_end                ; ESI = the text, ECX = its length
    jc .done
    call ly_begin
    call ly_item
    jc .done
    mov byte [edi + DI_TYPE], DT_TEXT
    mov eax, [ly_st + ST_CW]
    mov [edi + DI_CW], al
    add eax, eax
    mov [edi + DI_H], ax
    mov [edi + DI_LEN], cl
    mov eax, ecx                    ; x: right before the text, one
    inc eax                         ; character of room
    imul eax, [ly_st + ST_CW]
    neg eax
    add eax, [ly_st + ST_LEFT]
    mov [edi + DI_X], eax
    mov eax, [ly_y]
    mov [edi + DI_Y], eax
    mov eax, ecx
    imul eax, [ly_st + ST_CW]
    mov [edi + DI_W], ax
    mov dword [edi + DI_FG], C_TEXT
    mov dword [edi + DI_BG], -1
    mov [edi + DI_TEXT], esi
    mov eax, [ly_st + ST_CW]
    call ly_lineh
    cmp eax, [ly_lh]
    jbe .lh
    mov [ly_lh], eax
.lh:
    mov dword [ly_mark], 1
.done:
    popad
    ret

; ly_pool_begin: -> EDI = where a short text for the page can be written
; (ly_pool_end then keeps it)
ly_pool_begin:
    mov edi, [ly_pool]
    ret

; ly_pool_end: EDI = just after the text written -> ESI = the text,
; ECX = its length; CF=1 if the pool is full (the text is dropped)
ly_pool_end:
    mov esi, [ly_pool]
    mov ecx, edi
    sub ecx, esi
    cmp edi, BR_POOL + BR_POOL_SIZE - 512
    jae .full
    mov [ly_pool], edi
    clc
    ret
.full:
    stc
    ret

; ly_pool_num: EAX = number -> its digits at EDI (EDI moved on)
ly_pool_num:
    push eax
    push ecx
    push edx
    push ebx
    mov ebx, 10
    xor ecx, ecx
.d: xor edx, edx
    div ebx
    push edx
    inc ecx
    test eax, eax
    jnz .d
.w: pop eax
    add al, '0'
    stosb
    loop .w
    pop ebx
    pop edx
    pop ecx
    pop eax
    ret

; ly_pool_copy: ESI = string, ECX = most characters -> copied to EDI with
; spaces made non-breaking (so it stays in one piece on a line)
ly_pool_copy:
    push eax
.l: test ecx, ecx
    jz .e
    lodsb
    test al, al
    jz .e
    cmp al, ' '
    jne .s
    mov al, 0xFF
.s: stosb
    dec ecx
    jmp .l
.e: pop eax
    ret

; ly_void: EAX = an element that has no content: br, hr, img, input, ...
ly_void:
    pushad
    cmp eax, T_BR
    je .br
    cmp eax, T_HR
    je .hr
    cmp eax, T_IMG
    je .img
    cmp eax, T_INPUT
    je .input
    cmp eax, T_TEXTAREA
    je .area
    jmp .done
.br:
    call ly_br
    jmp .done
.hr:
    call ly_block_break
    mov ecx, 8
    call ly_margin
    call ly_flush_margin
    mov ecx, [ly_st + ST_LEFT]      ; a thin line across
    mov esi, [ly_st + ST_RIGHT]
    sub esi, ecx
    mov edi, 1
    mov eax, C_RULE
    call ly_rect
    inc dword [ly_y]
    mov ecx, 8
    call ly_margin
    jmp .done
.img:                               ; an image: its description instead
    mov eax, A_ALT
    call ly_find_attr
    jc .noalt
    cmp byte [esi], 0
    jne .alt
    cmp dword [ly_st + ST_LINK], 0  ; alt="": only shown if it is a link
    je .done
    mov esi, img_link
    jmp .shown
.noalt:
    mov esi, img_noalt
.shown:
    call ly_pool_begin
    mov ecx, 30
    call ly_pool_copy
    jmp .imgtext
.alt:
    push esi
    call ly_pool_begin
    mov al, '['
    stosb
    pop esi
    mov ecx, 60                     ; (a long description is cut)
    call ly_pool_copy_words
    mov al, ']'
    stosb
.imgtext:
    call ly_pool_end
    jc .done
    call ly_style_save
    or dword [ly_st + ST_FLAGS], GS_ITALIC
    cmp dword [ly_st + ST_LINK], 0
    jne .imgl
    mov dword [ly_st + ST_FG], C_ALT
.imgl:
    call ly_text
    call ly_style_load
    jmp .done
.area:                              ; a text area: a wide text box
    mov eax, IT_TEXT
    mov ecx, 40
    call ly_field
    jc .done
    call ly_field_box
    jmp .done
.input:
    mov ebx, IT_TEXT                ; what kind of field
    mov eax, A_TYPE
    call ly_find_attr
    jc .itype
    mov edi, it_hidden
    mov ebx, IT_HIDDEN
    call str_icmp
    je .itype
    mov ebx, IT_SUBMIT
    mov edi, it_submit
    call str_icmp
    je .itype
    mov edi, it_image
    call str_icmp
    je .itype
    mov ebx, IT_BUTTON
    mov edi, it_reset
    call str_icmp
    je .itype
    mov edi, it_button
    call str_icmp
    je .itype
    mov ebx, IT_CHECK
    mov edi, it_checkbox
    call str_icmp
    je .itype
    mov ebx, IT_RADIO
    mov edi, it_radio
    call str_icmp
    je .itype
    mov ebx, IT_PASSWORD
    mov edi, it_password
    call str_icmp
    je .itype
    mov ebx, IT_TEXT
.itype:
    mov ecx, 24                     ; width: size= (10 to 60), else 24
    mov eax, A_SIZE
    call ly_find_attr
    jc .w
    call parse_uint
    jc .w
    mov ecx, eax
    cmp ecx, 10
    jge .w1
    mov ecx, 10
.w1:
    cmp ecx, 60
    jle .w
    mov ecx, 60
.w:
    mov eax, ebx
    call ly_field
    jc .done
    cmp ebx, IT_HIDDEN              ; (hidden: sent with the form, not shown)
    je .done
    call ly_field_box
.done:
    popad
    ret

; ly_field: EAX = IT_* type, ECX = width -> the next form field record
; (ly_fld) filled in from the current element's attributes. What was typed
; into it, or ticked, is kept if the page is only being laid out again.
; CF=1 if there are too many fields.
ly_field:
    pushad
    mov edi, [ly_ni]
    cmp edi, BR_MAX_INPUTS
    jae .full
    inc dword [ly_ni]
    shl edi, 8
    add edi, BR_INPUTS
    mov [ly_fld], edi
    mov [edi + IN_TYPE], eax
    mov [edi + IN_W], ecx
    mov eax, [ly_st + ST_FORM]
    mov [edi + IN_FORM], eax
    mov eax, A_NAME
    call .attr
    mov [edi + IN_NAME], esi
    mov eax, A_VALUE
    call .attr
    mov [edi + IN_VALUE], esi
    mov eax, A_PLACEHOLDER
    call .attr
    mov [edi + IN_PH], esi
    cmp dword [edi + IN_INIT], 0
    jne .ok
    mov dword [edi + IN_INIT], 1
    mov eax, A_CHECKED
    call .attr
    xor eax, eax
    test esi, esi
    setnz al
    mov [edi + IN_CHK], eax
    mov dword [edi + IN_LEN], 0
    mov eax, [edi + IN_TYPE]        ; a text box starts with its value=
    cmp eax, IT_TEXT
    je .text
    cmp eax, IT_PASSWORD
    jne .ok
.text:
    mov esi, [edi + IN_VALUE]
    test esi, esi
    jz .ok
    xor ecx, ecx
.c: mov al, [esi + ecx]
    test al, al
    jz .cend
    mov [edi + IN_TEXT + ecx], al
    inc ecx
    cmp ecx, IN_MAXLEN
    jb .c
.cend:
    mov [edi + IN_LEN], ecx
.ok:
    popad
    clc
    ret
.full:
    popad
    stc
    ret
; .attr: EAX = attribute -> ESI = its value, 0 if none
.attr:
    call ly_find_attr
    jnc .a
    xor esi, esi
.a: ret

; ly_field_box: the box of field ly_fld onto the line, like a word
ly_field_box:
    pushad
    mov edi, [ly_fld]
    mov eax, [edi + IN_TYPE]
    mov ecx, [edi + IN_W]           ; its width in characters
    cmp eax, IT_TEXT
    je .w
    cmp eax, IT_PASSWORD
    je .w
    mov ecx, 3                      ; [x] / (*)
    cmp eax, IT_CHECK
    je .w
    cmp eax, IT_RADIO
    je .w
    call field_label                ; a button: its label and some room
    push esi
    call str_len
    pop esi
    add ecx, 2
.w:
    imul ecx, [ly_st + ST_CW]       ; ECX = width in pixels
    call ly_content                 ; a little room before it
    jz .nsp
    mov dword [ly_ps], 1
.nsp:
    call ly_begin
    xor edx, edx                    ; EDX = space before it
    cmp dword [ly_ps], 0
    je .fit
    call ly_content
    jz .fit
    mov edx, [ly_st + ST_CW]
.fit:
    mov eax, [ly_x]
    add eax, edx
    add eax, ecx
    cmp eax, [ly_st + ST_RIGHT]
    jle .put
    call ly_content
    jz .put
    call ly_finish                  ; does not fit: on the next line
    call ly_begin
    xor edx, edx
.put:
    push edi
    call ly_item
    mov esi, edi
    pop edi
    jc .done
    mov byte [esi + DI_TYPE], DT_INPUT
    mov eax, [ly_st + ST_CW]
    mov [esi + DI_CW], al
    add eax, eax
    mov [esi + DI_H], ax
    mov eax, [ly_x]
    add eax, edx
    mov [esi + DI_X], eax
    mov eax, [ly_y]
    mov [esi + DI_Y], eax
    mov [esi + DI_W], cx
    mov [esi + DI_LINK], edi
    add edx, ecx
    add [ly_x], edx
    mov eax, [ly_st + ST_CW]
    call ly_lineh
    cmp eax, [ly_lh]
    jbe .lh
    mov [ly_lh], eax
.lh:
    mov dword [ly_ps], 1
    mov dword [ly_mark], 0
.done:
    popad
    ret

; field_label: EDI = a button field -> ESI = its label
field_label:
    mov esi, [edi + IN_VALUE]
    test esi, esi
    jz .def
    cmp byte [esi], 0
    jne .r
.def:
    mov esi, lbl_submit
    cmp dword [edi + IN_TYPE], IT_SUBMIT
    je .r
    mov esi, lbl_button
.r: ret

; html_forms_reset: a new page: its fields start empty again
html_forms_reset:
    pushad
    mov edi, BR_INPUTS
    mov ecx, BR_MAX_INPUTS
.l: mov dword [edi + IN_INIT], 0
    add edi, IN_SIZE
    loop .l
    mov dword [pg_field], 0
    mov dword [ly_ni], 0
    mov dword [ly_nf], 0
    popad
    ret

; ly_pool_copy_words: like ly_pool_copy but spaces stay spaces
ly_pool_copy_words:
    push eax
.l: test ecx, ecx
    jz .e
    lodsb
    test al, al
    jz .e
    stosb
    dec ecx
    jmp .l
.e: pop eax
    ret

; ly_style_save / ly_style_load: keep the style while an input is drawn
ly_style_save:
    push eax
    mov eax, [ly_st + ST_FLAGS]
    mov [ly_sflags], eax
    mov eax, [ly_st + ST_FG]
    mov [ly_sfg], eax
    mov eax, [ly_st + ST_BG]
    mov [ly_sbg], eax
    pop eax
    ret
ly_style_load:
    push eax
    mov eax, [ly_sflags]
    mov [ly_st + ST_FLAGS], eax
    mov eax, [ly_sfg]
    mov [ly_st + ST_FG], eax
    mov eax, [ly_sbg]
    mov [ly_st + ST_BG], eax
    pop eax
    ret

; color_parse: ESI = a colour ("#rgb", "#rrggbb" or a name) -> EAX =
; 0xRRGGBB; CF=1 if not understood
color_parse:
    push ebx
    push ecx
    push edx
    push esi
    push edi
.sp:
    cmp byte [esi], ' '
    jne .go
    inc esi
    jmp .sp
.go:
    cmp byte [esi], '#'
    jne .name
    inc esi
    xor eax, eax                    ; read the hex digits
    xor edx, edx                    ; how many
.h: movzx ecx, byte [esi]
    call hex_digit
    jc .hend
    shl eax, 4
    or eax, ecx
    inc edx
    inc esi
    cmp edx, 6
    jbe .h
    jmp .bad
.hend:
    cmp edx, 6
    je .ok
    cmp edx, 3
    jne .bad
    mov ebx, eax                    ; #abc = #aabbcc
    shr eax, 8
    imul eax, 0x11
    shl eax, 16
    mov ecx, ebx
    shr ecx, 4
    and ecx, 0x0F
    imul ecx, 0x11
    shl ecx, 8
    or eax, ecx
    mov ecx, ebx
    and ecx, 0x0F
    imul ecx, 0x11
    or eax, ecx
    jmp .ok
.name:
    mov edi, color_names
.n: cmp byte [edi], 0
    je .bad
    push esi
    push edi
.c: mov al, [esi]
    call to_lower
    mov ah, [edi]
    test ah, ah
    jz .end
    cmp al, ah
    jne .diff
    inc esi
    inc edi
    jmp .c
.end:
    call is_alnum                   ; the name must end there
    jnc .diff
    pop edi
    pop esi
    call str_len_edi
    mov eax, [edi + ecx + 1]
    jmp .ok
.diff:
    pop edi
    pop esi
    call str_len_edi
    lea edi, [edi + ecx + 5]
    jmp .n
.ok:
    clc
    jmp .out
.bad:
    stc
.out:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; str_len_edi: EDI = string -> ECX = its length
str_len_edi:
    push esi
    mov esi, edi
    call str_len
    pop esi
    ret

; color_light: EAX = 0xRRGGBB -> CF=1 if dark enough to read on white
color_light:
    push eax
    push ebx
    push edx
    movzx ebx, al                   ; blue * 11
    imul ebx, 11
    movzx edx, ah                   ; green * 59
    imul edx, 59
    add ebx, edx
    shr eax, 16                     ; red * 30
    and eax, 0xFF
    imul eax, 30
    add ebx, eax
    cmp ebx, 170 * 100              ; lightness above 170 of 255: too light
    pop edx
    pop ebx
    pop eax
    ret

; ========================================================== 3. painting
section .bss
alignb 4
pg_x0       resd 1                  ; the page's left edge on the screen
pg_y0       resd 1                  ; its top (above the window if scrolled)
pg_vt       resd 1                  ; the visible part: top and bottom
pg_vb       resd 1
pg_hover    resd 1                  ; the link under the mouse
pg_focus    resd 1                  ; the link chosen with Tab
pg_field    resd 1                  ; the form field being typed into
pt_fg       resd 1
section .text

; html_paint: draw the items that are (partly) between pg_vt and pg_vb
html_paint:
    pushad
    mov esi, BR_ITEMS
    mov ebp, [ly_n]
.l: test ebp, ebp
    jz .done
    mov edx, [esi + DI_Y]
    add edx, [pg_y0]                ; EDX = its top on the screen
    movzx eax, word [esi + DI_H]
    add eax, edx
    cmp eax, [pg_vt]
    jle .next
    cmp edx, [pg_vb]
    jge .next
    mov ecx, [esi + DI_X]
    add ecx, [pg_x0]
    cmp byte [esi + DI_TYPE], DT_RECT
    je .rect
    cmp byte [esi + DI_TYPE], DT_INPUT
    je .input
    call pt_text
    jmp .next
.input:
    call pt_input
    jmp .next
.rect:
    push esi
    push ebp
    mov eax, [esi + DI_FG]
    movzx edi, word [esi + DI_H]
    movzx esi, word [esi + DI_W]
    call gfx_rgb
    call gfx_fillrect
    pop ebp
    pop esi
.next:
    add esi, DI_SIZE
    dec ebp
    jmp .l
.done:
    popad
    ret

; pt_text: ESI = a text item, ECX / EDX = where on the screen
pt_text:
    pushad
    mov ebx, esi
    mov eax, [ebx + DI_LINK]
    test eax, eax
    jz .bg
    cmp eax, [pg_focus]
    jne .bg
    mov eax, C_FOCUS                ; the link chosen with Tab: highlighted
    jmp .fill
.bg:
    mov eax, [ebx + DI_BG]
    cmp eax, -1
    je .frame
.fill:
    pushad
    call gfx_rgb
    movzx esi, word [ebx + DI_W]
    movzx edi, word [ebx + DI_H]
    call gfx_fillrect
    popad
.frame:
    test byte [ebx + DI_STYLE], GS_FRAME
    jz .text
    pushad
    mov eax, C_FRAME
    call gfx_rgb
    dec ecx
    dec edx
    movzx esi, word [ebx + DI_W]
    movzx edi, word [ebx + DI_H]
    add esi, 2
    add edi, 2
    call gfx_frame
    popad
.text:
    movzx eax, byte [ebx + DI_CW]
    mov [gfx_cw], eax
    movzx eax, byte [ebx + DI_STYLE]
    and eax, 0x0F
    mov [gfx_style], eax
    mov eax, [ebx + DI_FG]
    mov edi, [ebx + DI_LINK]
    test edi, edi
    jz .col
    cmp edi, [pg_hover]
    jne .col
    mov eax, C_HOVER                ; the link under the mouse
.col:
    call gfx_rgb
    mov [pt_fg], eax
    movzx edi, byte [ebx + DI_LEN]
    mov esi, [ebx + DI_TEXT]
    test byte [ebx + DI_STYLE], GS_ULINE | GS_STRIKE
    setnz ah                        ; AH = 1: spaces have a line too
.c: test edi, edi
    jz .done
    cmp ecx, [gfx_cx1]
    jge .done                       ; the rest is off to the right
    mov al, [esi]
    test ah, ah
    jnz .draw
    cmp al, ' '
    je .skip
    cmp al, 0xFF
    je .skip
.draw:
    push ebx
    push ebp
    mov ebx, [pt_fg]
    mov ebp, -1
    call gfx_glyph
    pop ebp
    pop ebx
.skip:
    add ecx, [gfx_cw]
    inc esi
    dec edi
    jmp .c
.done:
    popad
    ret

; pt_input: ESI = a form field's item, ECX / EDX = where on the screen
pt_input:
    pushad
    mov ebx, esi
    mov ebp, [ebx + DI_LINK]        ; EBP = the field
    movzx eax, byte [ebx + DI_CW]
    mov [gfx_cw], eax
    mov dword [gfx_style], 0
    movzx esi, word [ebx + DI_W]
    movzx edi, word [ebx + DI_H]
    mov eax, [ebp + IN_TYPE]
    cmp eax, IT_CHECK
    je .check
    cmp eax, IT_RADIO
    je .check
    cmp eax, IT_TEXT
    je .text
    cmp eax, IT_PASSWORD
    je .text
    ; a button: a grey box with its label
    mov eax, C_BUTTON_BG
    call pt_box
    mov edi, ebp
    call field_label                ; ESI = its label
    add ecx, [gfx_cw]
    mov eax, C_TEXT
    call pt_str
    jmp .done
.check:                             ; [x] or ( )
    mov eax, '[ ]'
    cmp dword [ebp + IN_TYPE], IT_CHECK
    je .ck
    mov eax, '( )'
.ck:
    cmp dword [ebp + IN_CHK], 0
    je .ck1
    mov ah, 'x'
    cmp dword [ebp + IN_TYPE], IT_CHECK
    je .ck1
    mov ah, '*'
.ck1:
    mov [pt_tmp], eax
    mov byte [pt_tmp + 3], 0
    mov esi, pt_tmp
    mov eax, C_TEXT
    call pt_str
    jmp .done
.text:                              ; a text box
    mov eax, C_FIELD_BG
    call pt_box
    cmp ebp, [pg_field]             ; being typed into: a blue edge
    jne .t1
    pushad
    mov eax, 0x2F7FD0
    call gfx_rgb
    dec ecx
    dec edx
    add esi, 2
    add edi, 2
    call gfx_frame
    popad
.t1:
    call gfx_clip_save              ; the text stays inside the box
    push ecx
    push edx
    call gfx_clip_and
    pop edx
    pop ecx
    add ecx, 2
    mov eax, [ebp + IN_LEN]
    test eax, eax
    jnz .typed
    cmp ebp, [pg_field]
    je .cursor
    mov esi, [ebp + IN_PH]          ; empty: the placeholder, in grey
    test esi, esi
    jz .tdone
    mov eax, C_ALT
    call pt_str
    jmp .tdone
.typed:
    mov esi, [ebp + IN_W]           ; too long for the box: show its end
    sub esi, 1
    sub eax, esi
    jg .from
    xor eax, eax
.from:
    lea esi, [ebp + IN_TEXT + eax]
    mov edi, [ebp + IN_LEN]
    sub edi, eax                    ; EDI = characters to draw
    mov eax, C_TEXT
    call gfx_rgb
    push ebx
    mov ebx, eax
.ch:
    test edi, edi
    jz .chd
    mov al, [esi]
    cmp dword [ebp + IN_TYPE], IT_PASSWORD
    jne .chp
    mov al, '*'
.chp:
    push ebp
    mov ebp, -1
    call gfx_glyph
    pop ebp
    add ecx, [gfx_cw]
    inc esi
    dec edi
    jmp .ch
.chd:
    pop ebx
.cursor:
    cmp ebp, [pg_field]
    jne .tdone
    mov eax, C_TEXT                 ; the text cursor
    call gfx_rgb
    mov esi, 2
    movzx edi, word [ebx + DI_H]
    call gfx_fillrect
.tdone:
    call gfx_clip_restore
.done:
    popad
    ret

; pt_box: a field's box at ECX, EDX, size ESI x EDI, filled with EAX
pt_box:
    pushad
    call gfx_rgb
    call gfx_fillrect
    mov eax, C_FRAME
    call gfx_rgb
    dec ecx
    dec edx
    add esi, 2
    add edi, 2
    call gfx_frame
    popad
    ret

; pt_str: ESI = string, ECX / EDX = where, EAX = colour (gfx_cw set)
pt_str:
    pushad
    call gfx_rgb
    mov ebx, eax
    mov ebp, -1
.l: mov al, [esi]
    test al, al
    jz .e
    call gfx_glyph
    add ecx, [gfx_cw]
    inc esi
    jmp .l
.e: popad
    ret

section .bss
pt_tmp      resd 1
section .text

; html_field_at: EAX / EDX = a point on the page -> EAX = the form field
; there (0 if none)
html_field_at:
    push ebx
    push ecx
    push esi
    mov esi, BR_ITEMS
    xor ecx, ecx
.l: cmp ecx, [ly_n]
    jae .none
    cmp byte [esi + DI_TYPE], DT_INPUT
    jne .n
    mov ebx, [esi + DI_X]
    cmp eax, ebx
    jl .n
    push eax
    movzx eax, word [esi + DI_W]
    add ebx, eax
    pop eax
    cmp eax, ebx
    jge .n
    mov ebx, [esi + DI_Y]
    cmp edx, ebx
    jl .n
    push eax
    movzx eax, word [esi + DI_H]
    add ebx, eax
    pop eax
    cmp edx, ebx
    jge .n
    mov eax, [esi + DI_LINK]
    jmp .out
.n: add esi, DI_SIZE
    inc ecx
    jmp .l
.none:
    xor eax, eax
.out:
    pop esi
    pop ecx
    pop ebx
    ret

; html_is_field: EAX = a link's value -> ZF=1 if it is really a form field
; (the text of a <button> links to its field)
html_is_field:
    cmp eax, BR_INPUTS
    jb .no
    cmp eax, BR_INPUTS + BR_MAX_INPUTS * IN_SIZE
    jae .no
    cmp eax, eax
    ret
.no:
    test esp, esp                   ; ZF=0
    ret

; html_link_at: EAX / EDX = a point on the page -> EAX = the href of the
; link there (0 if none), ECX = that item's number
html_link_at:
    push ebx
    push esi
    push edi
    mov esi, BR_ITEMS
    xor ecx, ecx
.l: cmp ecx, [ly_n]
    jae .none
    cmp dword [esi + DI_LINK], 0
    je .n
    mov ebx, [esi + DI_X]
    cmp eax, ebx
    jl .n
    movzx edi, word [esi + DI_W]
    add ebx, edi
    cmp eax, ebx
    jge .n
    mov ebx, [esi + DI_Y]
    cmp edx, ebx
    jl .n
    push eax
    movzx eax, byte [esi + DI_CW]
    call ly_lineh
    add ebx, eax
    pop eax
    cmp edx, ebx
    jge .n
    mov eax, [esi + DI_LINK]
    jmp .out
.n: add esi, DI_SIZE
    inc ecx
    jmp .l
.none:
    xor eax, eax
.out:
    pop edi
    pop esi
    pop ebx
    ret
