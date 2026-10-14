; =============================================================================
;  youtube.asm - YouTube in the MOOS browser
;
;  YouTube's own web pages are a large JavaScript program, which MOOS does
;  not run. Instead, like other small YouTube players, the browser talks to
;  the API those pages use ("innertube", JSON over HTTPS) and builds simple
;  pages of its own, which the normal HTML engine lays out:
;
;    youtube.com, m.youtube.com          a search box
;    .../results?search_query=...        search results: picture, title,
;                                        channel, length, views - each a link
;    .../watch?v=ID, youtu.be/ID,        the video: a <video> player (the MP4
;    .../shorts/ID, .../embed/ID         stream YouTube calls itag 18: H.264
;                                        + AAC, 360p), title, channel, views
;                                        and the description
;
;  To get a video's stream address, YouTube must be asked as one of its
;  apps ("clients"). Which ones answer with addresses that work without the
;  website's JavaScript changes from time to time, so the clients are tried
;  in turn, and more (or newer) can be given in the file yt.cfg, one per
;  line, tried first:
;        client NAME NUMBER VERSION USER-AGENT...
;  for example
;        client ANDROID_VR 28 1.65.10 com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip
;  Two more lines are understood, mostly for testing against a stand-in
;  server: "api URL" (where the API is, normally https://www.youtube.com)
;  and "images URL" (the pictures, normally https://i.ytimg.com).
; =============================================================================
YT_TOKS     equ 400000              ; JSON tokens for one answer (6.4 MB)
YT_CLIENTS  equ 8                   ; clients known (built in + yt.cfg)
YC_NAME     equ 0                   ; a client: name (32), number (8),
YC_NUM      equ 32                  ; version (32), user agent (192),
YC_VER      equ 40                  ; extra JSON for "client" (256)
YC_UA       equ 72
YC_EXTRA    equ 264
YC_SIZE     equ 520

section .data
yt_hosts    db "www.youtube.com", 0, "youtube.com", 0, "m.youtube.com", 0
            db "music.youtube.com", 0, "youtu.be", 0, "www.youtube-nocookie.com", 0, 0
yt_api_def  db "https://www.youtube.com", 0
yt_img_def  db "https://i.ytimg.com", 0
yt_api_player db "/youtubei/v1/player?prettyPrint=false", 0
yt_api_search db "/youtubei/v1/search?prettyPrint=false", 0
yt_cfg_name db "yt.cfg", 0
yt_p_watch  db "/watch", 0
yt_p_shorts db "/shorts/", 0
yt_p_embed  db "/embed/", 0
yt_p_live   db "/live/", 0
yt_p_results db "/results", 0
yt_q_v      db "v", 0
yt_q_search db "search_query", 0
yt_q_q      db "q", 0
yt_k_status db "playabilityStatus", 0
yt_k_st     db "status", 0
yt_k_reason db "reason", 0
yt_k_ok     db "OK", 0
yt_k_stream db "streamingData", 0
yt_k_formats db "formats", 0
yt_k_itag   db "itag", 0
yt_k_url    db "url", 0
yt_k_mime   db "mimeType", 0
yt_k_details db "videoDetails", 0
yt_k_title  db "title", 0
yt_k_author db "author", 0
yt_k_views  db "viewCount", 0
yt_k_length db "lengthSeconds", 0
yt_k_desc   db "shortDescription", 0
yt_k_vr     db "videoRenderer", 0
yt_k_vid    db "videoId", 0
yt_k_runs   db "runs", 0
yt_k_text   db "text", 0
yt_k_simple db "simpleText", 0
yt_k_byline db "longBylineText", 0
yt_k_owner  db "ownerText", 0
yt_k_len    db "lengthText", 0
yt_k_vcount db "viewCountText", 0
yt_k_pub    db "publishedTimeText", 0
yt_mime_avc db "video/mp4", 0
yt_mime_a42 db "avc1.42", 0
yt_mime_aac db "mp4a", 0
; built-in clients (tried after those in yt.cfg)
yt_builtin:
    db "ANDROID_VR", 0, "28", 0, "1.65.10", 0
    db "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip", 0
    db ',"deviceMake":"Oculus","deviceModel":"Quest 3","androidSdkVersion":32,"osName":"Android","osVersion":"12L"', 0
    db "IOS", 0, "5", 0, "20.10.4", 0
    db "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)", 0
    db ',"deviceMake":"Apple","deviceModel":"iPhone16,2","osName":"iPhone","osVersion":"18.3.2.22D82"', 0
    db "TVHTML5_SIMPLY_EMBEDDED_PLAYER", 0, "85", 0, "2.0", 0
    db "Mozilla/5.0 (PlayStation; PlayStation 4/12.00) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.4 Safari/605.1.15", 0
    db 0
    db "WEB_EMBEDDED_PLAYER", 0, "56", 0, "1.20250923.21.00", 0
    db "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36", 0
    db 0
    db 0
; the client used for searching
yt_web_name db "WEB", 0
yt_web_num  db "1", 0
yt_web_ver  db "2.20250925.01.00", 0
yt_web_ua   db "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36", 0
; JSON pieces
yt_j1       db '{"context":{"client":{"clientName":"', 0
yt_j2       db '","clientVersion":"', 0
yt_j3       db '","hl":"en","gl":"US","userAgent":"', 0
yt_j4       db '"', 0
yt_j5       db '}', 0
yt_j_vid    db '},"videoId":"', 0
yt_j_vid2   db '","contentCheckOk":true,"racyCheckOk":true}', 0
yt_j_q      db '},"query":"', 0
yt_j_q2     db '"}', 0
yt_embed_ctx db ',"thirdParty":{"embedUrl":"https://www.youtube.com/"}', 0
; header lines
yt_h_name   db "X-YouTube-Client-Name: ", 0
yt_h_ver    db 13, 10, "X-YouTube-Client-Version: ", 0
yt_h_origin db 13, 10, "Origin: https://www.youtube.com", 13, 10, 0
yt_ctype    db "application/json", 0
; page pieces
yt_home_html:
    db "<title>YouTube</title><h1>YouTube</h1>"
    db "<form action='https://www.youtube.com/results'>"
    db "<p><input type=text name=search_query size=40 placeholder='Search YouTube'> "
    db "<input type=submit value='Search'></p></form>"
    db "<p>Type what you want to watch and press Enter. Click a result to "
    db "play it. In the player: click or press <b>K</b> to pause, <b>J</b> / "
    db "<b>L</b> to go back / forward 10 seconds, <b>F</b> for full screen, "
    db "<b>M</b> to mute.</p>"
    db "<p><small>MOOS asks YouTube's API for videos and plays the H.264 / AAC "
    db "stream itself. If videos stop working, YouTube has changed what its "
    db "apps must send - see <code>man youtube</code>.</small></p>", 0
yt_s_head1  db "<title>", 0
yt_s_head2  db " - YouTube</title><form action='https://www.youtube.com/results'><p>"
            db "<input type=text name=search_query size=40 value='", 0
yt_s_head3  db "'> <input type=submit value='Search'></p></form><h2>Results for ", 0
yt_s_head4  db "</h2><table>", 0
yt_s_item1  db "<tr><td><a href='https://www.youtube.com/watch?v=", 0
yt_s_item2  db "'><img src='", 0
yt_vi       db "/vi/", 0
yt_s_item3  db "/mqdefault.jpg' width=240 height=135 alt='video'></a></td><td><b><a href='https://www.youtube.com/watch?v=", 0
yt_s_item4  db "'>", 0
yt_s_item5  db "</a></b><br>", 0
yt_s_sep    db " &middot; ", 0
yt_s_item6  db "</td></tr>", 0
yt_s_tail   db "</table>", 0
yt_s_none   db "<p>No videos found.</p>", 0
yt_w1       db "<title>", 0
yt_w2       db " - YouTube</title><form action='https://www.youtube.com/results'><p>"
            db "<input type=text name=search_query size=40 placeholder='Search YouTube'> "
            db "<input type=submit value='Search'></p></form><video src='", 0
yt_w3       db "' poster='", 0
yt_w4       db "/hqdefault.jpg' width=640 height=360 autoplay></video><h2>", 0
yt_w5       db "</h2><p><b>", 0
yt_w6       db " views</p><pre>", 0
yt_w7       db "</pre>", 0
yt_e1       db "<title>YouTube - cannot play</title><h2>This video cannot be played in MOOS</h2><p>", 0
yt_e2       db "</p><p>YouTube said: <b>", 0
yt_e3       db "</b></p><p><a href='https://www.youtube.com/'>Search YouTube</a></p>", 0
yt_e_noapi  db "MOOS could not reach YouTube's API (is the network up?), or the answer was not understood.", 0
yt_e_nofmt  db "YouTube did not offer a stream MOOS can play (an MP4 with H.264 Baseline video and AAC sound) to any of the apps MOOS asks as.", 0
yt_e_sfail  db "<p>The search did not work: MOOS could not reach YouTube or did not understand the answer.</p>", 0
yt_dot      db " &middot; ", 0

section .bss
alignb 4
yt_toks     resd 1                  ; token array (big block, kept)
yt_ntok     resd 1
yt_clients  resb YT_CLIENTS * YC_SIZE
yt_nclients resd 1
yt_id       resb 32                 ; video id
yt_query    resb 512                ; search words (decoded)
yt_body     resb 4096               ; JSON request
yt_hdrs     resb 512                ; extra header lines
yt_str      resb 8192               ; a decoded JSON string
yt_str2     resb 512
yt_fmt_url  resb 4096               ; the stream address found
yt_reason   resb 512
yt_api      resb 256                ; where the API is
yt_img      resb 256                ; where the pictures are
yt_apiurl   resb 512
yt_pagebuf_end resd 1
section .text

; ---------------------------------------------------------------- matching
; yt_match: ESI = a full address -> CF=0 if it is a YouTube page MOOS makes
; itself; yt_kind = 1 home, 2 search (yt_query), 3 watch (yt_id)
yt_match:
    pushad
    mov dword [yt_kind], 0
    mov edi, esi                    ; skip "http://" or "https://"
    mov esi, br_scheme_sep
    call str_find_ci                ; (EDI = text, ESI = what)
    jc .no
    lea esi, [eax + 3]
    mov edi, yt_hosts               ; the host must be one of YouTube's
.host:
    cmp byte [edi], 0
    je .no
    call yt_host_is                 ; ESI = address after //, EDI = a host
    je .hit
.nexth:
    cmp byte [edi], 0
    je .nh2
    inc edi
    jmp .nexth
.nh2:
    inc edi
    jmp .host
.hit:
    push edi                        ; EBX = the path (after the host)
    mov edi, esi
.hp:
    mov al, [edi]
    test al, al
    jz .hpe
    cmp al, '/'
    je .hpe
    cmp al, '?'
    je .hpe
    inc edi
    jmp .hp
.hpe:
    mov ebx, edi
    pop edi
    mov esi, yt_host_be             ; youtu.be/ID
    call str_eq
    jne .path
    cmp byte [ebx], '/'
    jne .home
    lea esi, [ebx + 1]
    jmp .id_from
.path:
    mov edi, ebx
    mov esi, yt_p_watch
    call str_iprefix
    jne .shorts
    mov esi, yt_q_v                 ; watch?v=ID
    mov ecx, 32
    mov edx, yt_id
    call yt_param
    jc .home
    jmp .watch
.shorts:
    mov esi, yt_p_shorts
    call str_iprefix
    je .after
    mov esi, yt_p_embed
    call str_iprefix
    je .after
    mov esi, yt_p_live
    call str_iprefix
    je .after
    mov esi, yt_p_results
    call str_iprefix
    jne .home
    mov esi, yt_q_search            ; results?search_query=...
    mov ecx, 500
    mov edx, yt_query
    call yt_param
    jnc .search
    mov esi, yt_q_q
    call yt_param
    jc .home
.search:
    mov dword [yt_kind], 2
    jmp .yes
.after:                             ; /shorts/ID, /embed/ID, /live/ID
    call str_len                    ; (ESI = the prefix: skip it)
    lea esi, [ebx + ecx]
.id_from:
    xor ecx, ecx
.idc:
    mov al, [esi + ecx]
    call is_alnum
    jnc .idk
    cmp al, '-'
    je .idk
    cmp al, '_'
    jne .ide
.idk:
    mov [yt_id + ecx], al
    inc ecx
    cmp ecx, 20
    jb .idc
.ide:
    mov byte [yt_id + ecx], 0
    test ecx, ecx
    jz .home
.watch:
    mov dword [yt_kind], 3
    jmp .yes
.home:
    mov dword [yt_kind], 1
.yes:
    popad
    clc
    ret
.no:
    popad
    stc
    ret

section .data
yt_host_be  db "youtu.be", 0
section .bss
alignb 4
yt_kind     resd 1
section .text

; yt_host_is: ESI = text after "//", EDI = a host name -> ZF=1 if the text
; starts with that host followed by '/', '?', ':' or its end
yt_host_is:
    push eax
    push esi
    push edi
.l: mov al, [edi]
    test al, al
    jz .end
    mov ah, [esi]
    or ah, 0x20
    cmp al, ah
    jne .out
    inc esi
    inc edi
    jmp .l
.end:
    mov al, [esi]
    test al, al
    jz .out
    cmp al, '/'
    je .out
    cmp al, '?'
    je .out
    cmp al, ':'
.out:
    pop edi
    pop esi
    pop eax
    ret

; yt_param: EDI = path with a query ("...?a=1&b=2"), ESI = a name, EDX =
; output, ECX = room -> the value, %-decoded and with + as space; CF=1 if
; the query has no such parameter
yt_param:
    pushad
    mov ebx, edi
.q: mov al, [ebx]                   ; to the '?'
    test al, al
    jz .no
    inc ebx
    cmp al, '?'
    jne .q
.name:                              ; at the start of a name=value
    mov edi, ebx
    push esi
.c: mov al, [esi]
    test al, al
    jz .cend
    cmp al, [edi]
    jne .cno
    inc esi
    inc edi
    jmp .c
.cend:
    pop esi
    cmp byte [edi], '='
    je .value
    jmp .skip
.cno:
    pop esi
.skip:                              ; to the next '&'
    mov al, [ebx]
    test al, al
    jz .no
    inc ebx
    cmp al, '&'
    jne .skip
    jmp .name
.value:
    inc edi
    mov esi, edi
    mov edi, edx
    dec ecx
.v: mov al, [esi]
    test al, al
    jz .vend
    cmp al, '&'
    je .vend
    cmp al, '#'
    je .vend
    inc esi
    cmp al, '+'
    jne .pct
    mov al, ' '
    jmp .put
.pct:
    cmp al, '%'
    jne .put
    push ecx
    movzx ecx, byte [esi]
    call hex_digit
    jc .pbad
    mov ah, cl
    movzx ecx, byte [esi + 1]
    call hex_digit
    jc .pbad
    shl ah, 4
    or ah, cl
    mov al, ah
    add esi, 2
.pbad:
    pop ecx
.put:
    jecxz .vend
    stosb
    dec ecx
    jmp .v
.vend:
    mov byte [edi], 0
    popad
    clc
    ret
.no:
    popad
    stc
    ret

; ---------------------------------------------------------------- pages
; yt_page: after yt_match -> the page in BR_TMP: ESI = it, ECX = its length
yt_page:
    call yt_load_clients            ; (yt.cfg)
    mov edi, BR_TMP
    mov byte [edi], 0
    cmp dword [yt_kind], 2
    je .search
    cmp dword [yt_kind], 3
    je .watch
    mov esi, yt_home_html
    call str_copy
    jmp .done
.search:
    call yt_search_page
    jmp .done
.watch:
    call yt_watch_page
.done:
    mov esi, BR_TMP
    call str_len
    ret

; yt_tokens: the JSON answer in PKG_BUF (pkg_len) -> tokens (yt_toks,
; yt_ntok); CF=1 if it is not JSON (or there is no memory)
yt_tokens:
    pushad
    cmp dword [yt_toks], 0
    jne .have
    mov ecx, YT_TOKS * 16
    mov edx, OWN_SYSTEM
    call big_alloc
    test eax, eax
    jz .no
    mov [yt_toks], eax
.have:
    CCALL json_parse, PKG_BUF, dword [pkg_len], dword [yt_toks], YT_TOKS
    test eax, eax
    jle .no
    mov [yt_ntok], eax
    popad
    clc
    ret
.no:
    popad
    stc
    ret

; yt_key: EAX = an object token, ESI = a key -> EAX = the value's token,
; -1 if none (EAX = -1 in gives -1 out)
yt_key:
    cmp eax, -1
    je .r
    push ecx
    push edx
    CCALL json_key, PKG_BUF, dword [yt_toks], dword [yt_ntok], eax, esi
    pop edx
    pop ecx
.r: ret

; yt_index: EAX = an array token, ECX = n -> EAX = its n-th element or -1
yt_index:
    cmp eax, -1
    je .r
    push ecx
    push edx
    CCALL json_index, dword [yt_toks], dword [yt_ntok], eax, ecx
    pop edx
    pop ecx
.r: ret

; yt_string: EAX = a string token -> its text (UTF-8) in yt_str; CF=1 if
; it is not a string. A "runs" object (title.runs[0].text) or a
; "simpleText" object is followed to its text.
yt_string:
    pushad
    cmp eax, -1
    je .no
    mov ebx, eax
    shl ebx, 4
    add ebx, [yt_toks]
    cmp byte [ebx], 1               ; an object: { "simpleText": ... } or
    jne .str                        ; { "runs": [ { "text": ... } ] }
    push eax
    mov esi, yt_k_simple
    call yt_key
    cmp eax, -1
    jne .found
    pop eax
    push eax
    mov esi, yt_k_runs
    call yt_key
    xor ecx, ecx
    call yt_index
    mov esi, yt_k_text
    call yt_key
.found:
    add esp, 4
    cmp eax, -1
    je .no
    mov ebx, eax
    shl ebx, 4
    add ebx, [yt_toks]
.str:
    cmp byte [ebx], 3
    jne .prim
.conv:
    CCALL json_str, PKG_BUF, ebx, yt_str, 8000
    test eax, eax
    js .no
    popad
    clc
    ret
.prim:
    cmp byte [ebx], 4               ; (a number: its digits)
    je .conv
.no:
    mov byte [yt_str], 0
    popad
    stc
    ret

; yt_post: ESI = API path (after yt_api), the JSON body in yt_body, the
; extra header lines in yt_hdrs, the user agent at EDX -> the answer in
; PKG_BUF; CF=1 if it could not be fetched or was not "200 OK"
yt_post:
    pushad
    mov edi, yt_apiurl
    push esi
    mov esi, yt_api
    call str_copy
    pop esi
    call str_append
    mov esi, edi
    mov dword [url_method], 1       ; POST
    mov dword [url_body], yt_body
    push esi
    mov esi, yt_body
    call str_len
    pop esi
    mov [url_body_len], ecx
    mov dword [url_body_type], yt_ctype
    mov dword [url_headers], yt_hdrs
    mov [url_agent], edx
    mov byte [url_insecure], 0
    mov byte [gui_capture], 2
    call url_fetch
    mov byte [gui_capture], 0
    pushf
    mov dword [url_method], 0       ; (back to a plain GET for the others)
    mov dword [url_body], 0
    mov dword [url_headers], 0
    mov dword [url_agent], 0
    popf
    jc .no
    cmp dword [http_status], 200
    jne .no
    popad
    clc
    ret
.no:
    popad
    stc
    ret

; yt_request: EBX = a client, then append to yt_body the start of a
; request ({"context":{"client":{...}) and fill yt_hdrs
yt_request:
    pushad
    mov edi, yt_body
    mov esi, yt_j1
    call str_copy
    lea esi, [ebx + YC_NAME]
    call str_append
    mov esi, yt_j2
    call str_append
    lea esi, [ebx + YC_VER]
    call str_append
    mov esi, yt_j3
    call str_append
    lea esi, [ebx + YC_UA]
    call str_append
    mov esi, yt_j4
    call str_append
    lea esi, [ebx + YC_EXTRA]
    call str_append
    mov esi, yt_j5                  ; (closes "client")
    call str_append
    mov edi, yt_hdrs
    mov esi, yt_h_name
    call str_copy
    lea esi, [ebx + YC_NUM]
    call str_append
    mov esi, yt_h_ver
    call str_append
    lea esi, [ebx + YC_VER]
    call str_append
    mov esi, yt_h_origin
    call str_append
    popad
    ret

; yt_json_append: ESI = text -> appended to yt_body as a JSON string's
; inside (quotes, backslashes and control characters escaped)
yt_json_append:
    pushad
    mov edi, yt_body
    push esi
    mov esi, edi
    call str_len
    add edi, ecx
    pop esi
.l: mov eax, edi
    sub eax, yt_body
    cmp eax, 4000
    jae .e
    lodsb
    test al, al
    jz .e
    cmp al, '"'
    je .esc
    cmp al, '\'
    je .esc
    cmp al, ' '
    jb .l                           ; (control characters dropped)
    stosb
    jmp .l
.esc:
    mov byte [edi], '\'
    inc edi
    stosb
    jmp .l
.e: mov byte [edi], 0
    popad
    ret

; yt_load_clients: the client list: those in yt.cfg first, then the built-in
yt_load_clients:
    pushad
    mov dword [yt_nclients], 0
    mov esi, yt_api_def
    mov edi, yt_api
    call str_copy
    mov esi, yt_img_def
    mov edi, yt_img
    call str_copy
    mov esi, yt_cfg_name            ; yt.cfg: "client NAME NUM VER UA..."
    call fs_find_top
    jc .builtin
    mov ecx, [edi + DE_SIZE]
    call fs_slot                    ; ESI = its text
    lea edx, [esi + ecx]            ; EDX = its end
.line:
    cmp esi, edx
    jae .builtin
    mov edi, yt_cfg_api             ; "api URL"?
    xchg esi, edi
    call str_iprefix
    xchg esi, edi
    jne .notapi
    add esi, 4
    mov edi, yt_api
    mov ecx, 250
    call .word
    jmp .skipline
.notapi:
    mov edi, yt_cfg_img             ; "images URL"?
    xchg esi, edi
    call str_iprefix
    xchg esi, edi
    jne .notimg
    add esi, 7
    mov edi, yt_img
    mov ecx, 250
    call .word
    jmp .skipline
.notimg:
    mov edi, yt_cfg_client
    xchg esi, edi
    call str_iprefix                ; "client "?
    xchg esi, edi
    jne .skipline
    add esi, 7
    cmp dword [yt_nclients], YT_CLIENTS - 4
    jae .builtin
    mov ebx, [yt_nclients]
    imul ebx, YC_SIZE
    add ebx, yt_clients
    lea edi, [ebx + YC_NAME]
    mov ecx, 31
    call .word
    lea edi, [ebx + YC_NUM]
    mov ecx, 7
    call .word
    lea edi, [ebx + YC_VER]
    mov ecx, 31
    call .word
    lea edi, [ebx + YC_UA]          ; the rest of the line
    mov ecx, 190
.ua:
    cmp esi, edx
    jae .uae
    lodsb
    cmp al, 13
    je .uae
    cmp al, 10
    je .uae
    jecxz .ua
    stosb
    dec ecx
    jmp .ua
.uae:
    mov byte [edi], 0
    mov byte [ebx + YC_EXTRA], 0
    inc dword [yt_nclients]
.skipline:
    cmp esi, edx
    jae .builtin
    lodsb
    cmp al, 10
    jne .skipline
    jmp .line
.builtin:
    mov esi, yt_builtin             ; then the built-in ones
.b: cmp byte [esi], 0
    je .done
    cmp dword [yt_nclients], YT_CLIENTS
    jae .done
    mov ebx, [yt_nclients]
    imul ebx, YC_SIZE
    add ebx, yt_clients
    lea edi, [ebx + YC_NAME]
    call .copyz
    lea edi, [ebx + YC_NUM]
    call .copyz
    lea edi, [ebx + YC_VER]
    call .copyz
    lea edi, [ebx + YC_UA]
    call .copyz
    lea edi, [ebx + YC_EXTRA]
    call .copyz
    inc dword [yt_nclients]
    jmp .b
.done:
    popad
    ret
; .word: copy a word (up to a space) from ESI (end EDX) to EDI, ECX max
.word:
    cmp esi, edx
    jae .we
    cmp byte [esi], ' '
    jne .wc
    inc esi
    jmp .word
.wc:
    cmp esi, edx
    jae .we
    lodsb
    cmp al, ' '
    je .we
    cmp al, 13
    je .we
    cmp al, 10
    je .we1
    jecxz .wc
    stosb
    dec ecx
    jmp .wc
.we1:
    dec esi
.we:
    mov byte [edi], 0
    ret
; .copyz: copy a 0-terminated string from ESI to EDI (ESI moves past it)
.copyz:
    lodsb
    stosb
    test al, al
    jnz .copyz
    ret

section .data
yt_cfg_client db "client ", 0
yt_cfg_api  db "api ", 0
yt_cfg_img  db "images ", 0
section .text

; yt_watch_page: the watch page of yt_id (or a page saying why not) in
; BR_TMP. Each client in turn is asked for the video until one offers a
; stream MOOS can play.
yt_watch_page:
    pushad
    call yt_load_clients
    mov byte [yt_reason], 0
    mov dword [yt_got_api], 0
    xor ebp, ebp                    ; EBP = client number
.client:
    cmp ebp, [yt_nclients]
    jae .fail
    mov ebx, ebp
    imul ebx, YC_SIZE
    add ebx, yt_clients
    call yt_request                 ; {"context":{"client":{...}}
    cmp word [ebx + YC_NUM], '85'   ; (the embedded TV player needs to say
    jne .ctx                        ; where it is embedded)
    cmp byte [ebx + YC_NUM + 2], 0
    jne .ctx
    mov esi, yt_embed_ctx
    mov edi, yt_body
    call str_append
.ctx:
    mov edi, yt_body
    mov esi, yt_j_vid
    call str_append
    mov esi, yt_id
    call yt_json_append
    mov esi, yt_j_vid2
    call str_append
    mov esi, yt_api_player
    lea edx, [ebx + YC_UA]
    call yt_post
    jc .next
    call yt_tokens
    jc .next
    mov dword [yt_got_api], 1
    xor eax, eax                    ; playabilityStatus.status == "OK"?
    mov esi, yt_k_status
    call yt_key
    mov esi, yt_k_st
    call yt_key
    call yt_string
    jc .next
    mov esi, yt_str
    mov edi, yt_k_ok
    call str_eq
    je .ok
    xor eax, eax                    ; no: remember its reason
    mov esi, yt_k_status
    call yt_key
    mov esi, yt_k_reason
    call yt_key
    call yt_string
    jc .next
    mov esi, yt_str
    mov edi, yt_reason
    mov ecx, 500
.rc:
    lodsb
    stosb
    test al, al
    jz .next
    loop .rc
    mov byte [edi], 0
    jmp .next
.ok:
    call yt_pick_format             ; a stream with a plain address?
    jnc .found
.next:
    inc ebp
    jmp .client
.found:
    call yt_build_watch
    popad
    ret
.fail:
    mov edi, BR_TMP                 ; why not
    mov esi, yt_e1
    call str_copy
    mov esi, yt_e_nofmt
    cmp dword [yt_got_api], 0
    jne .why
    mov esi, yt_e_noapi
.why:
    call html_escape_append
    cmp byte [yt_reason], 0
    je .nor
    mov esi, yt_e2
    call str_append
    mov esi, yt_reason
    call html_escape_append
.nor:
    mov esi, yt_e3
    call str_append
    popad
    ret

section .bss
alignb 4
yt_got_api  resd 1
section .text

; yt_pick_format: tokens of a "player" answer -> yt_fmt_url = the address
; of a muxed MP4 with H.264 Baseline video and AAC sound (itag 18 first);
; CF=1 if there is none with a plain address (signatureCipher ones need the
; website's JavaScript)
yt_pick_format:
    pushad
    xor eax, eax
    mov esi, yt_k_stream
    call yt_key
    mov esi, yt_k_formats
    call yt_key
    cmp eax, -1
    je .no
    mov ebx, eax                    ; EBX = the formats array
    xor ecx, ecx
.f: mov eax, ebx
    call yt_index
    cmp eax, -1
    je .no
    mov edx, eax                    ; EDX = one format
    mov esi, yt_k_mime              ; mimeType: video/mp4 with avc1.42... and
    call yt_key                     ; mp4a
    call yt_string
    jc .n
    mov esi, yt_str
    mov edi, yt_mime_avc
    xchg esi, edi
    call str_iprefix
    xchg esi, edi
    jne .n
    mov edi, yt_mime_a42
    call str_has_ci
    jne .n
    mov edi, yt_mime_aac
    call str_has_ci
    jne .n
    mov eax, edx                    ; its url
    mov esi, yt_k_url
    call yt_key
    call yt_string
    jc .n
    mov esi, yt_str
    mov edi, yt_fmt_url
    call str_copy
    popad
    clc
    ret
.n: inc ecx
    cmp ecx, 64
    jb .f
.no:
    popad
    stc
    ret

; yt_build_watch: the watch page from the tokens and yt_fmt_url -> BR_TMP
yt_build_watch:
    pushad
    mov edi, BR_TMP
    mov esi, yt_w1
    call str_copy
    call .detail_title
    call html_escape_append
    mov esi, yt_w2
    call str_append
    mov esi, yt_fmt_url
    call yt_attr_append
    mov esi, yt_w3
    call str_append
    mov esi, yt_img
    call str_append
    mov esi, yt_vi
    call str_append
    mov esi, yt_id
    call str_append
    mov esi, yt_w4
    call str_append
    call .detail_title
    call html_escape_append
    mov esi, yt_w5
    call str_append
    mov esi, yt_k_author            ; channel
    call .detail
    call html_escape_append
    mov esi, yt_s_sep
    call str_append
    mov esi, yt_k_length            ; length (m:ss)
    call .detail
    call yt_duration
    call str_append
    mov esi, yt_s_sep
    call str_append
    mov esi, yt_k_views
    call .detail
    call yt_thousands
    call str_append
    mov esi, yt_w6
    call str_append
    mov esi, yt_k_desc
    call .detail
    call html_escape_append
    mov esi, yt_w7
    call str_append
    popad
    ret
.detail_title:
    mov esi, yt_k_title
; .detail: ESI = a key of videoDetails -> ESI = its text (or "")
.detail:
    push eax
    push esi
    xor eax, eax
    mov esi, yt_k_details
    call yt_key
    pop esi
    call yt_key
    call yt_string
    mov esi, yt_str
    pop eax
    ret

; yt_attr_append: ESI = text -> appended to the string at EDI with ' and &
; and < written as HTML (for a quoted attribute)
yt_attr_append:
    pushad
    push esi
    mov esi, edi
    call str_len
    add edi, ecx
    pop esi
.l: lodsb
    test al, al
    jz .e
    cmp al, "'"
    je .apos
    cmp al, '&'
    je .amp
    cmp al, '<'
    je .lt
    stosb
    jmp .l
.apos:
    mov eax, '&#39'
    stosd
    mov al, ';'
    stosb
    jmp .l
.amp:
    mov eax, '&amp'
    stosd
    mov al, ';'
    stosb
    jmp .l
.lt:
    mov eax, '&lt;'
    stosd
    jmp .l
.e: mov byte [edi], 0
    popad
    ret

; yt_duration: ESI = seconds as text -> ESI = "m:ss" (or "h:mm:ss")
yt_duration:
    push eax
    push ebx
    push ecx
    push edx
    push edi
    call parse_uint
    jnc .ok
    xor eax, eax
.ok:
    mov edi, yt_str2
    xor edx, edx
    mov ebx, 3600
    div ebx                         ; EAX = hours, EDX = rest
    test eax, eax
    jz .min
    call .num
    mov al, ':'
    stosb
    mov eax, edx
    xor edx, edx
    mov ebx, 60
    div ebx
    call .two
    jmp .sec
.min:
    mov eax, edx
    xor edx, edx
    mov ebx, 60
    div ebx
    call .num
.sec:
    mov al, ':'
    stosb
    mov eax, edx
    call .two
    mov byte [edi], 0
    mov esi, yt_str2
    pop edi
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret
.num:
    push edx
    call ly_pool_num_edi
    pop edx
    ret
.two:
    push edx
    xor edx, edx
    mov ebx, 10
    div ebx
    add al, '0'
    stosb
    mov al, dl
    add al, '0'
    stosb
    pop edx
    ret

; ly_pool_num_edi: EAX = number -> its digits at EDI (EDI moves on)
ly_pool_num_edi:
    jmp ly_pool_num

; yt_thousands: ESI = digits -> ESI = the same with , between thousands
yt_thousands:
    push eax
    push ecx
    push edx
    push edi
    call str_len
    mov edi, yt_str2
    mov edx, ecx                    ; digits left
.l: test edx, edx
    jz .e
    lodsb
    stosb
    dec edx
    jz .e
    mov eax, edx
    push edx
    xor edx, edx
    mov ecx, 3
    div ecx
    test edx, edx
    pop edx
    jnz .l
    mov al, ','
    stosb
    jmp .l
.e: mov byte [edi], 0
    mov esi, yt_str2
    pop edi
    pop edx
    pop ecx
    pop eax
    ret

; yt_search_page: the results for yt_query -> BR_TMP
yt_search_page:
    pushad
    mov edi, BR_TMP
    mov esi, yt_s_head1
    call str_copy
    mov esi, yt_query
    call html_escape_append
    mov esi, yt_s_head2
    call str_append
    mov esi, yt_query
    call yt_attr_append
    mov esi, yt_s_head3
    call str_append
    mov esi, yt_query
    call html_escape_append
    mov esi, yt_s_head4
    call str_append
    ; ask YouTube (as its website)
    mov ebx, yt_web_client
    call yt_web_setup
    call yt_request
    mov edi, yt_body
    mov esi, yt_j_q
    call str_append
    mov esi, yt_query
    call yt_json_append
    mov esi, yt_j_q2
    call str_append
    mov esi, yt_api_search
    lea edx, [ebx + YC_UA]
    call yt_post
    jc .fail
    call yt_tokens
    jc .fail
    xor ecx, ecx                    ; every "videoRenderer" object, in order
    xor ebp, ebp                    ; (results shown)
.t: cmp ecx, [yt_ntok]
    jae .end
    mov ebx, ecx
    shl ebx, 4
    add ebx, [yt_toks]
    cmp byte [ebx], 3               ; a string token "videoRenderer" that is
    jne .n                          ; a key (an object follows)
    CCALL json_eq, PKG_BUF, ebx, yt_k_vr
    test eax, eax
    jz .n
    lea eax, [ecx + 1]
    cmp eax, [yt_ntok]
    jae .end
    mov edx, eax
    shl edx, 4
    add edx, [yt_toks]
    cmp byte [edx], 1
    jne .n
    call yt_result                  ; EAX = its object
    inc ebp
    cmp ebp, 40
    jae .end
.n: inc ecx
    jmp .t
.end:
    mov edi, BR_TMP
    mov esi, yt_s_tail
    call str_append
    test ebp, ebp
    jnz .done
    mov esi, yt_s_none
    call str_append
.done:
    popad
    ret
.fail:
    mov edi, BR_TMP
    mov esi, yt_s_tail
    call str_append
    mov esi, yt_e_sfail
    call str_append
    popad
    ret

; yt_web_setup: the website client (for searching) -> yt_web_client
yt_web_setup:
    pushad
    mov edi, yt_web_client + YC_NAME
    mov esi, yt_web_name
    call str_copy
    mov edi, yt_web_client + YC_NUM
    mov esi, yt_web_num
    call str_copy
    mov edi, yt_web_client + YC_VER
    mov esi, yt_web_ver
    call str_copy
    mov edi, yt_web_client + YC_UA
    mov esi, yt_web_ua
    call str_copy
    mov byte [yt_web_client + YC_EXTRA], 0
    popad
    ret

section .bss
yt_web_client resb YC_SIZE
section .text

; yt_result: EAX = a videoRenderer object -> a row of the results table
yt_result:
    pushad
    mov ebx, eax
    mov esi, yt_k_vid               ; its id
    call yt_key
    call yt_string
    jc .done
    mov esi, yt_str
    mov edi, yt_id
    mov ecx, 20
.c: lodsb
    stosb
    test al, al
    jz .cd
    loop .c
    mov byte [edi], 0
.cd:
    mov edi, BR_TMP                 ; (enough room left?)
    push esi
    mov esi, edi
    call str_len
    pop esi
    cmp ecx, 60000
    jae .done
    mov esi, yt_s_item1
    call str_append
    mov esi, yt_id
    call str_append
    mov esi, yt_s_item2
    call str_append
    mov esi, yt_img
    call str_append
    mov esi, yt_vi
    call str_append
    mov esi, yt_id
    call str_append
    mov esi, yt_s_item3
    call str_append
    mov esi, yt_id
    call str_append
    mov esi, yt_s_item4
    call str_append
    mov eax, ebx                    ; title
    mov esi, yt_k_title
    call yt_key
    call yt_string
    mov esi, yt_str
    call html_escape_append
    mov esi, yt_s_item5
    call str_append
    mov eax, ebx                    ; channel
    mov esi, yt_k_byline
    call yt_key
    call yt_string
    jnc .ch
    mov eax, ebx
    mov esi, yt_k_owner
    call yt_key
    call yt_string
.ch:
    mov esi, yt_str
    call html_escape_append
    mov eax, ebx                    ; length
    mov esi, yt_k_len
    call yt_key
    call yt_string
    jc .nl
    mov esi, yt_s_sep
    call str_append
    mov esi, yt_str
    call html_escape_append
.nl:
    mov eax, ebx                    ; views
    mov esi, yt_k_vcount
    call yt_key
    call yt_string
    jc .nv
    mov esi, yt_s_sep
    call str_append
    mov esi, yt_str
    call html_escape_append
.nv:
    mov eax, ebx                    ; when
    mov esi, yt_k_pub
    call yt_key
    call yt_string
    jc .np
    mov esi, yt_s_sep
    call str_append
    mov esi, yt_str
    call html_escape_append
.np:
    mov esi, yt_s_item6
    call str_append
.done:
    popad
    ret
