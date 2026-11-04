; nlang_opener.nasm - reads the .n/.nc/.ns file named on the command line into `buffer`.
; Included by nlang_main.nasm (do NOT define `main` here). It only uses the os_* functions defined there.
; main_opener returns EAX = 0 on success, 1 on failure.
bits 64
default rel

%define BUFFER_SIZE 6291456
%define PATH_MAX    520

section .data
target: db HOST_TARGET          ; 0 = the programs Nano writes are for Windows, 1 = for Linux (--win64 / --linux)

section .bss
    bytes_read  resq 1
    path_buf    resb PATH_MAX
    verbose     resb 1              ; 1 with -v / --verbose: show every statement
    resb 7
    buffer      resb BUFFER_SIZE

section .text
main_opener:
    push rbx
    push rsi
    push rdi
    sub  rsp, 64                ; keeps the 16-byte alignment the os_* functions expect

    call os_cmdline
    mov  rsi, rax
    cmp  byte [rsi], '"'
    je   .quoted_exe

.skip_exe:                      ; unquoted program name: skip to first space
    mov  al, [rsi]
    test al, al
    jz   .fail
    cmp  al, ' '
    je   .skip_spaces
    inc  rsi
    jmp  .skip_exe

.quoted_exe:
    inc  rsi
.q_loop:
    mov  al, [rsi]
    test al, al
    jz   .fail
    inc  rsi
    cmp  al, '"'
    jne  .q_loop

.skip_spaces:
    mov  al, [rsi]
    cmp  al, ' '
    jne  .arg
    inc  rsi
    jmp  .skip_spaces

.arg:
    test al, al
    jz   .fail                  ; no file argument
    cmp  al, '-'
    jne  .path
    cmp  word [rsi], '-v'       ; flag: -v  or  --verbose  (then a space, or the end)
    jne  .long_flag
    movzx eax, byte [rsi + 2]
    mov  ecx, 2
    jmp  .flag_end
.long_flag:
    cmp  dword [rsi], '--ve'
    jne  .try_win
    cmp  dword [rsi + 4], 'rbos'
    jne  .path
    cmp  byte [rsi + 8], 'e'
    jne  .path
    movzx eax, byte [rsi + 9]
    mov  ecx, 9
.flag_end:
    test al, al
    jz   .set_verbose
    cmp  al, ' '
    jne  .path                  ; e.g. "-vx": just a (bad) file name
.set_verbose:
    mov  byte [verbose], 1
    add  rsi, rcx
    jmp  .skip_spaces
.try_win:                       ; --win64
    cmp  dword [rsi], '--wi'
    jne  .try_linux
    cmp  word [rsi + 4], 'n6'
    jne  .path
    cmp  byte [rsi + 6], '4'
    jne  .path
    xor  edx, edx
    jmp  .target_end
.try_linux:                     ; --linux
    cmp  dword [rsi], '--li'
    jne  .path
    cmp  word [rsi + 4], 'nu'
    jne  .path
    cmp  byte [rsi + 6], 'x'
    jne  .path
    mov  edx, 1
.target_end:
    movzx eax, byte [rsi + 7]
    test al, al
    jz   .set_target
    cmp  al, ' '
    jne  .path
.set_target:
    mov  [target], dl
    add  rsi, 7
    jmp  .skip_spaces
.path:
    mov  al, [rsi]
    lea  rdi, [path_buf]
    lea  rbx, [path_buf + PATH_MAX - 1]
    cmp  al, '"'
    jne  .copy_plain
    inc  rsi
.copy_quoted:
    mov  al, [rsi]
    test al, al
    jz   .copied
    cmp  al, '"'
    je   .copied
    cmp  rdi, rbx
    jae  .fail                  ; path too long
    mov  [rdi], al
    inc  rsi
    inc  rdi
    jmp  .copy_quoted
.copy_plain:
    mov  al, [rsi]
    test al, al
    jz   .copied
    cmp  al, ' '
    je   .copied
    cmp  rdi, rbx
    jae  .fail
    mov  [rdi], al
    inc  rsi
    inc  rdi
    jmp  .copy_plain
.copied:
    mov  byte [rdi], 0          ; properly NUL-terminated copy for CreateFileA

    ; ---- check extension (.n / .nc / .ns), scanning back from the end ----
    lea  rbx, [path_buf]
.back:
    cmp  rdi, rbx
    jbe  .fail                  ; no extension found
    dec  rdi
    mov  al, [rdi]
    cmp  al, '\'
    je   .fail
    cmp  al, '/'
    je   .fail
    cmp  al, '.'
    jne  .back
    cmp  byte [rdi + 1], 'n'
    jne  .fail
    mov  al, [rdi + 2]
    test al, al
    jz   .open                  ; ".n"
    cmp  byte [rdi + 3], 0
    jne  .fail                  ; reject ".nxyz"
    cmp  al, 'c'
    je   .open
    cmp  al, 's'
    jne  .fail

.open:
    lea  rcx, [path_buf]
    lea  rdx, [buffer]
    mov  r8d, BUFFER_SIZE
    call os_read_file           ; rax = bytes read, -1 when it can't be read
    cmp  rax, -1
    je   .fail
    mov  [bytes_read], rax
    cmp  rax, BUFFER_SIZE
    jae  .fail                  ; file too big for the buffer (would be truncated)
    xor  eax, eax
    jmp  .done

.fail:
    mov  eax, 1
.done:
    add  rsp, 64
    pop  rdi
    pop  rsi
    pop  rbx
    ret
