; nlang_main.nasm - entry point for the Nano compiler, and the only file that talks to the operating system.
;
; One source for both systems. The system the compiler is built FOR is picked by the format NASM is asked to write
; (a program can't be a Windows and a Linux executable at once), and the other system's code is not assembled:
;
;   Windows x64   nasm -f win64 nlang_main.nasm -o nlang.obj
;                 link /subsystem:console /entry:main nlang.obj kernel32.lib
;                 nlang.exe [-v] [--win64|--linux] path\to\script.n
;   Linux x86-64  nasm -f elf64 nlang_main.nasm -o nlang.o
;                 ld nlang.o -o nlang
;                 ./nlang [-v] [--win64|--linux] path/to/script.n
;
; (Build from src/main so the %includes resolve. -DOS_WIN32 / -DOS_LINUX force one system regardless of the format;
;  the test harness uses -DOS_WIN32 with stand-ins for kernel32.)
;
; The rest of the compiler (opener, compiler, writer) never calls the OS directly. It calls these functions, which are
; defined below once for Windows and once for Linux. They keep RBX, RSI, RDI, RBP and R12-R15:
;   os_cmdline     -> RAX = the command line as one NUL-terminated string:  program arg arg ...  (an argument with a
;                     space in it is in "quotes")
;   os_read_file   RCX = path, RDX = buffer, R8 = size   -> RAX = bytes read, -1 when the file can't be read
;   os_write_file  RCX = path, RDX = bytes, R8 = length  -> EAX = 0 ok, 1 failed   (creates / replaces the file)
;   os_write_std   ECX = 1 stdout / 2 stderr, RDX = text, R8 = length
;   os_exit        ECX = exit code. Windows keeps all of it; Linux keeps the low 8 bits only (0x105 is seen as 5).
;                  The text of an error message always carries the full code.
;
; Exit code: 0 = ok, 1 = could not open/read the input file,
;            0x100 + n = compile error n (see `error` in nlang_compiler.nasm)
bits 64
default rel

%ifdef OS_WIN32
  %define HOST_WINDOWS
%elifdef OS_LINUX
  %define HOST_LINUX
%else
  %ifidn __OUTPUT_FORMAT__, win64
    %define HOST_WINDOWS
  %elifidn __OUTPUT_FORMAT__, elf64
    %define HOST_LINUX
  %else
    %error "nlang: assemble with -f win64 (Windows) or -f elf64 (Linux)"
  %endif
%endif

; the system the programs Nano writes are for, unless --win64 / --linux says otherwise
%ifdef HOST_WINDOWS
  %define HOST_TARGET 0
%else
  %define HOST_TARGET 1
%endif

%ifdef HOST_WINDOWS
extern ExitProcess
extern GetCommandLineA
extern GetStdHandle
extern CreateFileA
extern ReadFile
extern WriteFile
extern CloseHandle
extern VirtualAlloc
extern GetModuleHandleA
extern GetProcAddress
global main
%else
global _start
%endif

; Includes must sit at file level, NOT inside a label: they carry their own
; `section` directives and would otherwise be executed as code.
%include "nlang_opener.nasm"
%include "nlang_compiler.nasm"
%include "nlang_interpreter.nasm"

section .bss
    os_h    resq 1
    os_n    resq 1
    os_p    resq 1
    os_l    resq 1
%ifdef HOST_LINUX
    os_argv resq 1
    os_cmd  resb 4096
%endif

section .text
%ifdef HOST_WINDOWS
main:
    sub  rsp, 40                ; entry rsp is 8 mod 16; 32 shadow + 8 -> aligned
    jmp  nano_start
%else
_start:
    lea  rax, [rsp + 8]         ; argv (rsp -> argc, then the argv pointers, a NULL, the environment)
    mov  [os_argv], rax
    jmp  nano_start             ; rsp is 16-aligned here: the same state as main after its sub
%endif

nano_start:
    call main_opener            ; eax = 0 ok, 1 failure
    test eax, eax
    jnz  .cannot_read           ; don't compile if the file couldn't be read
    call compile                ; eax = 0 ok (errors exit through `error`)
.exit:
    mov  ecx, eax               ; exit code
    call os_exit                ; never returns
.cannot_read:
    mov  ecx, 2                 ; stderr
    lea  rdx, [s_usage]
    mov  r8d, s_usage_len
    call os_write_std
    mov  eax, 1
    jmp  .exit

; ---- --run: assemble the program in memory and run it ---------------------------------------------------------
; out_buf holds the NASM text the compiler just wrote. interp_run never returns: the program ends with its own exit.
;   Linux:   the image is mapped at ASM_BASE with mmap and the program's own _start is entered.
;   Windows: the image is mapped at ASM_BASE with VirtualAlloc.  Every `extern NAME` of the program gets a small stub
;            `NAME: jmp [__imp_NAME]` appended to the text, and the pointer behind it is filled with GetProcAddress
;            (kernel32.dll) once the image exists.  Then the program's `main` is called like a Windows function.
section .data
STR s_run_asm, "nlang: assembler error "
STR s_run_line, " at line "
STR s_run_nl, `\n`
STR s_run_map, `nlang: cannot map memory for the program\n`
STR s_run_win, `nlang: --run only runs programs for the system nlang itself runs on (not --win64 / --linux of the other one)\n`
STR s_run_imp, `nlang: cannot find a Windows function the program needs\n`
s_run_start: db "_start"
s_run_main:  db "main"
s_run_k32:   db "kernel32.dll", 0
STR s_st_a, `\nsection .data\n__imp_`
STR s_st_b, `: dq 0\nsection .text\n`
STR s_st_c, `: jmp [__imp_`
STR s_st_d, `]\n`
section .bss
ext_tab: resb 64 * 32           ; the externs of the program: a length byte, then up to 31 characters
ext_cnt: resd 1
ext_i:   resd 1
ext_h:   resq 1
ext_fn:  resq 1
ext_len: resd 1
ext_buf: resb 64
section .text
%macro EMIT_AT 2
    lea  rdx, [%1]
    mov  r8d, %2
    call emit_bytes
%endmacro
interp_run:
    sub  rsp, 72                ; entry rsp is 8 mod 16: now aligned, 32 bytes of shadow space for Windows calls
%ifdef HOST_LINUX
    cmp  byte [target], 1
%else
    cmp  byte [target], 0
%endif
    jne  .nosys
%ifdef HOST_WINDOWS
    call win_collect_externs
    call win_emit_stubs
%endif
    lea  rsi, [out_buf]
    mov  rcx, [out_len]
    call asm_pass01
    test eax, eax
    jnz  .asmerr
%ifdef HOST_LINUX
    mov  eax, 9                 ; mmap(ASM_BASE, size, RWX, PRIVATE|ANON|FIXED_NOREPLACE)
    mov  edi, ASM_BASE
    mov  rsi, [asm_size]
    mov  edx, 7
    mov  r10d, 0x100022
    mov  r8, -1
    xor  r9d, r9d
    syscall
%else
    mov  ecx, ASM_BASE          ; VirtualAlloc(ASM_BASE, size, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE)
    mov  rdx, [asm_size]
    mov  r8d, 0x3000
    mov  r9d, 0x40
    call VirtualAlloc
%endif
    cmp  rax, ASM_BASE
    jne  .nomap
    mov  edi, ASM_BASE
    call asm_pass2
    test eax, eax
    jnz  .asmerr
%ifdef HOST_LINUX
    lea  rsi, [s_run_start]
    mov  ecx, 6
    call asm_lookup
    test rax, rax
    jz   .asmerr
    jmp  rax                    ; the program's own _start: it ends with the exit system call
%else
    lea  rcx, [s_run_k32]
    call GetModuleHandleA
    mov  [ext_h], rax
    mov  dword [ext_i], 0
.imp:                           ; for every extern: GetProcAddress, then store it behind __imp_NAME
    mov  eax, [ext_i]
    cmp  eax, [ext_cnt]
    jae  .imp_done
    shl  eax, 5
    lea  rbx, [ext_tab + rax]
    movzx ecx, byte [rbx]       ; length of the name
    mov  [ext_len], ecx
    lea  rdi, [ext_buf + 6]     ; "__imp_" + name, kept for the lookup
    lea  rsi, [rbx + 1]
    rep  movsb
    mov  byte [rdi], 0          ; the plain name, NUL ended, is at ext_buf + 6
    mov  dword [ext_buf], '__im'
    mov  word [ext_buf + 4], 'p_'
    mov  rcx, [ext_h]
    lea  rdx, [ext_buf + 6]
    call GetProcAddress
    test rax, rax
    jz   .noimp
    mov  [ext_fn], rax
    lea  rsi, [ext_buf]
    mov  ecx, [ext_len]
    add  ecx, 6
    call asm_lookup             ; the address of __imp_NAME in the image
    test rax, rax
    jz   .asmerr
    mov  rdx, [ext_fn]
    mov  [rax], rdx
    inc  dword [ext_i]
    jmp  .imp
.imp_done:
    lea  rsi, [s_run_main]
    mov  ecx, 4
    call asm_lookup
    test rax, rax
    jz   .asmerr
    and  rsp, -16
    sub  rsp, 32
    call rax                    ; main: sub rsp, 40 ... it ends with ExitProcess
    xor  ecx, ecx
    call os_exit
.noimp:
    mov  ecx, 2
    lea  rdx, [s_run_imp]
    mov  r8d, s_run_imp_len
    call os_write_std
    mov  ecx, 3
    call os_exit
%endif
.asmerr:
    mov  dword [mb_len], 0
    PUT  s_run_asm
    mov  eax, [asm_err]
    call put_dec
    PUT  s_run_line
    mov  eax, [asm_err_line]
    call put_dec
    PUT  s_run_nl
    mov  ecx, 2
    lea  rdx, [msg_buf]
    mov  r8d, [mb_len]
    call os_write_std
    mov  ecx, 3
    call os_exit
.nomap:
    mov  ecx, 2
    lea  rdx, [s_run_map]
    mov  r8d, s_run_map_len
    call os_write_std
    mov  ecx, 3
    call os_exit
.nosys:
    mov  ecx, 2
    lea  rdx, [s_run_win]
    mov  r8d, s_run_win_len
    call os_write_std
    mov  ecx, 3
    call os_exit

%ifdef HOST_WINDOWS
; ext_tab = the distinct names after "extern " at the start of a line of out_buf
win_collect_externs:
    mov  dword [ext_cnt], 0
    lea  rsi, [out_buf]
    mov  rdi, rsi
    add  rdi, [out_len]         ; the end of the text
.line:
    lea  rax, [rsi + 8]
    cmp  rax, rdi
    ja   .done
    cmp  dword [rsi], 'exte'
    jne  .next
    cmp  word [rsi + 4], 'rn'
    jne  .next
    cmp  byte [rsi + 6], ' '
    jne  .next
    lea  r8, [rsi + 7]          ; the name
    xor  ecx, ecx
.len:
    movzx eax, byte [r8 + rcx]
    cmp  al, ' '
    jbe  .got
    cmp  al, ';'
    je   .got
    inc  ecx
    cmp  ecx, 31
    jb   .len
.got:
    test ecx, ecx
    jz   .next
    xor  edx, edx               ; already in the table?
.dup:
    cmp  edx, [ext_cnt]
    jae  .add
    mov  eax, edx
    shl  eax, 5
    lea  r9, [ext_tab + rax]
    movzx eax, byte [r9]
    cmp  eax, ecx
    jne  .dup_next
    push rsi
    push rdi
    push rcx
    lea  rsi, [r9 + 1]
    mov  rdi, r8
    repe cmpsb
    pop  rcx
    pop  rdi
    pop  rsi
    je   .next                  ; the same name
.dup_next:
    inc  edx
    jmp  .dup
.add:
    cmp  dword [ext_cnt], 64
    jae  .next
    mov  eax, [ext_cnt]
    shl  eax, 5
    lea  r9, [ext_tab + rax]
    mov  [r9], cl
    push rsi
    push rdi
    lea  rdi, [r9 + 1]
    mov  rsi, r8
    rep  movsb
    pop  rdi
    pop  rsi
    inc  dword [ext_cnt]
.next:
    cmp  rsi, rdi
    jae  .done
    cmp  byte [rsi], 0x0A
    lea  rsi, [rsi + 1]
    jne  .next
    jmp  .line
.done:
    ret

; append the stub of every extern to out_buf (the assembler ignores `extern` itself)
win_emit_stubs:
    mov  dword [ext_i], 0
.each:
    mov  eax, [ext_i]
    cmp  eax, [ext_cnt]
    jae  .r
    shl  eax, 5
    lea  rbx, [ext_tab + rax]
    movzx r13d, byte [rbx]
    EMIT_AT s_st_a, s_st_a_len
    lea  rdx, [rbx + 1]
    mov  r8d, r13d
    call emit_bytes
    EMIT_AT s_st_b, s_st_b_len
    lea  rdx, [rbx + 1]
    mov  r8d, r13d
    call emit_bytes
    EMIT_AT s_st_c, s_st_c_len
    lea  rdx, [rbx + 1]
    mov  r8d, r13d
    call emit_bytes
    EMIT_AT s_st_d, s_st_d_len
    inc  dword [ext_i]
    jmp  .each
.r: ret
%endif

section .data
STR s_usage, `nlang: cannot read the input file.\nUsage: nlang [-v] [-r|--run] [--win64|--linux] <file.n | file.nc | file.ns>\n  -v, --verbose   show every statement as it is compiled\n  -r, --run       run the program at once instead of writing a .nasm file\n  --win64         write a program for Windows (the default on Windows)\n  --linux         write a program for Linux (the default on Linux)\n`
section .text

; ===================================================================================================================
%ifdef HOST_WINDOWS
; ---- Windows (kernel32) ----------------------------------------------------------------------------------------

os_exit:
    and  rsp, -16
    sub  rsp, 32
    call ExitProcess

os_cmdline:
    sub  rsp, 40
    call GetCommandLineA
    add  rsp, 40
    ret

os_write_std:
    sub  rsp, 40                ; entry rsp is 8 mod 16: 32 shadow + 1 stack arg keeps calls aligned
    mov  [os_p], rdx
    mov  [os_l], r8
    mov  eax, ecx               ; 1 / 2  ->  -11 (STD_OUTPUT_HANDLE) / -12 (STD_ERROR_HANDLE)
    neg  eax
    sub  eax, 10
    mov  ecx, eax
    call GetStdHandle
    mov  rcx, rax
    mov  rdx, [os_p]
    mov  r8d, [os_l]
    lea  r9, [os_n]
    mov  qword [os_n], 0
    mov  qword [rsp + 32], 0
    call WriteFile
    add  rsp, 40
    ret

os_read_file:
    push rbx
    push rsi
    push rdi
    sub  rsp, 64                ; 32 shadow + 3 stack args (CreateFileA has 7 params); keeps 16-byte alignment
    mov  rsi, rdx               ; buffer
    mov  rdi, r8                ; size
    mov  edx, 0x80000000        ; GENERIC_READ
    mov  r8d, 1                 ; FILE_SHARE_READ
    xor  r9d, r9d               ; no security attributes
    mov  qword [rsp + 32], 3    ; OPEN_EXISTING
    mov  qword [rsp + 40], 0x80 ; FILE_ATTRIBUTE_NORMAL
    mov  qword [rsp + 48], 0    ; no template
    call CreateFileA
    cmp  rax, -1                ; INVALID_HANDLE_VALUE
    je   .fail
    mov  [os_h], rax
    mov  rcx, rax
    mov  rdx, rsi
    mov  r8d, edi
    lea  r9, [os_n]
    mov  qword [os_n], 0
    mov  qword [rsp + 32], 0    ; lpOverlapped = NULL
    call ReadFile
    mov  ebx, eax               ; keep result across CloseHandle (rbx is non-volatile)
    mov  rcx, [os_h]
    call CloseHandle
    test ebx, ebx
    jz   .fail
    mov  eax, [os_n]
    jmp  .done
.fail:
    mov  rax, -1
.done:
    add  rsp, 64
    pop  rdi
    pop  rsi
    pop  rbx
    ret

os_write_file:
    push rbx
    sub  rsp, 64                ; entry rsp is 8 mod 16: push + 64 keeps calls aligned
    mov  [os_p], rdx
    mov  [os_l], r8
    mov  edx, 0x40000000        ; GENERIC_WRITE
    xor  r8d, r8d
    xor  r9d, r9d
    mov  qword [rsp + 32], 2    ; CREATE_ALWAYS
    mov  qword [rsp + 40], 0x80 ; FILE_ATTRIBUTE_NORMAL
    mov  qword [rsp + 48], 0
    call CreateFileA
    cmp  rax, -1
    je   .fail
    mov  [os_h], rax
    mov  rcx, rax
    mov  rdx, [os_p]
    mov  r8d, [os_l]
    lea  r9, [os_n]
    mov  qword [os_n], 0
    mov  qword [rsp + 32], 0
    call WriteFile
    mov  ebx, eax               ; RBX is non-volatile: survives CloseHandle
    mov  rcx, [os_h]
    call CloseHandle
    test ebx, ebx
    jz   .fail
    mov  rax, [os_n]
    cmp  rax, [os_l]
    jne  .fail
    xor  eax, eax
    jmp  .done
.fail:
    mov  eax, 1
.done:
    add  rsp, 64
    pop  rbx
    ret

%else
; ---- Linux (system calls) --------------------------------------------------------------------------------------
; syscall number in EAX, arguments in RDI, RSI, RDX, R10; it changes only RAX, RCX and R11.

os_exit:
    mov  edi, ecx
    mov  eax, 60                ; exit
    syscall

os_write_std:
    push rsi
    push rdi
    mov  edi, ecx               ; the file descriptor: 1 = stdout, 2 = stderr
    mov  rsi, rdx
    mov  rdx, r8
    mov  eax, 1                 ; write
    syscall
    pop  rdi
    pop  rsi
    ret

; The command line is rebuilt from argv in the form the opener reads:  prog arg arg  (spaces inside an argument: "quoted")
os_cmdline:
    push rsi
    push rdi
    push rbx
    lea  rdi, [os_cmd]
    lea  r8, [os_cmd + 4000]    ; (the end: what does not fit is dropped)
    mov  rbx, [os_argv]
.arg:
    mov  rsi, [rbx]
    test rsi, rsi
    jz   .end
    xor  ecx, ecx               ; 1 when the argument contains a space
    mov  rdx, rsi
.scan:
    mov  al, [rdx]
    test al, al
    jz   .scanned
    cmp  al, ' '
    jne  .sn
    mov  ecx, 1
.sn:
    inc  rdx
    jmp  .scan
.scanned:
    test ecx, ecx
    jz   .copy
    cmp  rdi, r8
    jae  .copy
    mov  byte [rdi], '"'
    inc  rdi
.copy:
    mov  al, [rsi]
    test al, al
    jz   .copied
    cmp  rdi, r8
    jae  .skipc
    mov  [rdi], al
    inc  rdi
.skipc:
    inc  rsi
    jmp  .copy
.copied:
    test ecx, ecx
    jz   .sep
    cmp  rdi, r8
    jae  .sep
    mov  byte [rdi], '"'
    inc  rdi
.sep:
    add  rbx, 8
    cmp  qword [rbx], 0
    je   .end
    cmp  rdi, r8
    jae  .arg
    mov  byte [rdi], ' '
    inc  rdi
    jmp  .arg
.end:
    mov  byte [rdi], 0
    lea  rax, [os_cmd]
    pop  rbx
    pop  rdi
    pop  rsi
    ret

os_read_file:
    push rbx
    push rsi
    push rdi
    mov  r9, rdx                ; buffer
    mov  r10, r8                ; size
    mov  rdi, rcx
    xor  esi, esi               ; O_RDONLY
    xor  edx, edx
    mov  eax, 2                 ; open
    syscall
    test rax, rax
    js   .fail
    mov  ebx, eax               ; the file descriptor
    xor  r8d, r8d               ; bytes read so far
.rd:
    mov  rdx, r10
    sub  rdx, r8
    jz   .rdone                 ; the buffer is full
    lea  rsi, [r9 + r8]
    mov  edi, ebx
    xor  eax, eax               ; read
    syscall
    test rax, rax
    js   .rfail
    jz   .rdone
    add  r8, rax
    jmp  .rd
.rdone:
    mov  edi, ebx
    mov  eax, 3                 ; close
    syscall
    mov  rax, r8
    jmp  .out
.rfail:
    mov  edi, ebx
    mov  eax, 3
    syscall
.fail:
    mov  rax, -1
.out:
    pop  rdi
    pop  rsi
    pop  rbx
    ret

os_write_file:
    push rbx
    push rsi
    push rdi
    mov  r9, rdx                ; bytes
    mov  r10, r8                ; length
    mov  rdi, rcx
    mov  esi, 0x241             ; O_WRONLY | O_CREAT | O_TRUNC
    mov  edx, 0x1A4             ; mode 0644
    mov  eax, 2                 ; open
    syscall
    test rax, rax
    js   .fail
    mov  ebx, eax
    xor  r8d, r8d               ; bytes written so far
.wr:
    mov  rdx, r10
    sub  rdx, r8
    jz   .wdone
    lea  rsi, [r9 + r8]
    mov  edi, ebx
    mov  eax, 1                 ; write
    syscall
    test rax, rax
    jle  .wfail
    add  r8, rax
    jmp  .wr
.wdone:
    mov  edi, ebx
    mov  eax, 3                 ; close
    syscall
    xor  eax, eax
    jmp  .out
.wfail:
    mov  edi, ebx
    mov  eax, 3
    syscall
.fail:
    mov  eax, 1
.out:
    pop  rdi
    pop  rsi
    pop  rbx
    ret
%endif
