# nlang_main.nasm
section .data
    nlang_opener db 'nlang_opener.nasm', 0
    nlang_compiler db 'nlang_compiler.nasm', 0

section .text
global main
main:
    ; Include nlang_opener.nasm
    incbin nlang_opener
    ; Include nlang_compiler.nasm
    incbin nlang_compiler

    ; Call the main function from nlang_opener.nasm
    call main_opener

    ; Call the compile function from nlang_compiler.nasm
    call compile_code

    ; Exit the program
    xor rax, rax
    xor rbx, rbx
    xor rcx, rcx
    xor rdx, rdx
    call ExitProcess

main_opener:
    ; Call the main function from nlang_opener.nasm
    call main
    ret

compile_code:
    ; Call the compile function from nlang_compiler.nasm
    call compile
    ret
