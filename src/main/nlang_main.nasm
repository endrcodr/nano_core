; nlang_main.nasm - entry point for the Nano compiler (Windows x64)
;
; Build (from src/main, so the %includes resolve):
;   nasm -f win64 nlang_main.nasm -o nlang.obj
;   link /subsystem:console /entry:main nlang.obj kernel32.lib
; Run:
;   nlang.exe path\to\script.n
;
; Exit code: 0 = ok, 1 = could not open/read the input file,
;            0x100 + n = compile error n (see `error` in nlang_compiler.nasm)
bits 64
default rel

extern ExitProcess
global main

; Includes must sit at file level, NOT inside a label: they carry their own
; `section`/`extern` directives and would otherwise be executed as code.
%include "nlang_opener.nasm"
%include "nlang_compiler.nasm"

section .text
main:
    sub  rsp, 40                ; entry rsp is 8 mod 16; 32 shadow + 8 -> aligned
    call main_opener            ; eax = 0 ok, 1 failure
    test eax, eax
    jnz  .exit                  ; don't compile if the file couldn't be read
    call compile                ; eax = 0 ok (errors exit through `error`)
.exit:
    mov  ecx, eax               ; exit code
    call ExitProcess            ; never returns
