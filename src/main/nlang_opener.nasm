; nlang_opener.nasm - reads the .n/.nc/.ns file named on the command line into `buffer`.
; Included by nlang_main.nasm (do NOT define `main` here).
; main_opener returns EAX = 0 on success, 1 on failure.
bits 64
default rel

%define BUFFER_SIZE 6291456
%define PATH_MAX    520

extern GetCommandLineA
extern CreateFileA
extern ReadFile
extern CloseHandle
extern ExitProcess

section .bss
    file_handle resq 1
    bytes_read  resq 1          ; ReadFile writes a DWORD; qword is zeroed first
    path_buf    resb PATH_MAX
    buffer      resb BUFFER_SIZE

section .text
main_opener:
    push rbx
    push rsi
    push rdi
    sub  rsp, 64                ; 32 shadow + 3 stack args (CreateFileA has 7 params); keeps 16-byte alignment

    call GetCommandLineA
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
    mov  edx, 0x80000000        ; GENERIC_READ
    mov  r8d, 1                 ; FILE_SHARE_READ
    xor  r9d, r9d               ; no security attributes
    mov  qword [rsp + 32], 3    ; OPEN_EXISTING
    mov  qword [rsp + 40], 0x80 ; FILE_ATTRIBUTE_NORMAL
    mov  qword [rsp + 48], 0    ; no template
    call CreateFileA
    cmp  rax, -1                ; INVALID_HANDLE_VALUE
    je   .fail
    mov  [file_handle], rax

    mov  rcx, rax
    lea  rdx, [buffer]
    mov  r8d, BUFFER_SIZE
    lea  r9,  [bytes_read]
    mov  qword [bytes_read], 0
    mov  qword [rsp + 32], 0    ; lpOverlapped = NULL
    call ReadFile
    mov  ebx, eax               ; keep result across CloseHandle (rbx is non-volatile)

    mov  rcx, [file_handle]
    call CloseHandle

    test ebx, ebx
    jz   .fail
    cmp  dword [bytes_read], BUFFER_SIZE
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
