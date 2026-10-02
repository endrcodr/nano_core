bits 64
default rel
section .text
global main
main:
    ; Include nlang_opener.nasm
    %include "nlang_opener.nasm"
    ; Include nlang_compiler.nasm
    %include "nlang_compiler.nasm"

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
