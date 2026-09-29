bits 64
default rel

extern GetCommandLineA
extern CreateFileA
extern ReadFile
extern CloseFile
extern ExitProcess

section .bss
    file_handle resq 1
    bytes_read resq 1
    buffer resb 6291456

section .text
global main
main:
    sub rsp, 40
    
    call GetCommandLineA
    mov rcx, rax
    cmp byte [rcx], '"'
    je .quoted

.not_quoted:
    mov al, [rcx]
    cmp al, 0
    je .exit_error
    cmp al, ' '
    je .next_arg
    inc rcx
    jmp .not_quoted

.quoted:
    inc rcx

.quoted_loop:
    mov al, [rcx]
    cmp al, 0
    je .exit_error
    cmp al, '"'
    je .found_quote
    inc rcx
    jmp .quoted_loop

.found_quote:
    inc rcx

.next_arg:
    mov al, [rcx]
    cmp al, 0
    je .exit_error
    cmp al, ' '
    jne .fp_found
    inc rcx
    jmp .next_arg

.fp_found:
    mov rdx, 0x80000000
    mov r8, 1
    mov r9, 0
    mov qword [rsp + 32], 3
    mov qword [rsp + 40], 128
    mov qword [rsp + 48], 0
    
    call CreateFileA
    
    cmp rax, -1
    je .exit_error
    mov [file_handle], rax
    
    mov rcx, [file_handle]
    mov rdx, buffer
    mov r8, 1024
    mov r9, bytes_read
    mov qword [rsp + 32], 0
    
    mov rdi, rcx

.find_end:
    mov al, [rdi]
    cmp al, 0
    je .search_period
    cmp al, '"'
    je .search_period
    inc rdi
    jmp .find_end

.search_period:
    dec rdi
    cmp rdi, rcx
    je .no_extension
    
    mov al, rdi
    cmp al, '\'
    je .no_extension
    cmp al, '.'
    jne .search_period
    
    cmp byte [rdi + 1], 'n'
    jne .wrong_extension
    cmp byte [rdi + 2], 0
    jne .nc_or_ns
    jmp .read_and_compile

.nc_or_ns:
    cmp byte [rdi + 2], 'c'
    jne .ns_or_other
    jmp .read_and_compile
    
.ns_or_other:
    cmp byte [rdi + 2], 's'
    jne .wrong_extension
    jmp .read_and_compile
    
.read_and_compile:
    call ReadFile
    
    jmp read
    
    jmp exit_script

.wrong_extension:
    jmp exit_error
    
close_file:
    mov rcx, [file_handle]
    call CloseHandle
    
exit_error:
    xor rax, rax
    xor rbx, rbx
    xor rcx, rcx
    xor rdx, rdx
    call ExitProcess

exit_script:
    ret
