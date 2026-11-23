; nlang_asm.nasm - the in-memory assembler of the Nano interpreter.
;
; Turns the NASM text the Nano compiler writes (Linux x86-64 target) into machine code placed at a fixed address.
; Only the instruction forms the compiler emits are supported (55 mnemonics); anything else is an error, never a guess.
; The reference model is miniasm.py: this file must produce exactly the same bytes.
;
; Rules that keep it small:
;   - every jump and call is rel32 (no size optimisation, no relaxation)
;   - the whole image sits at ASM_BASE (below 2 GiB) so every label is an absolute 32-bit value
;   - pass 0 reads the `equ` constants, pass 1 measures (labels get section + offset), pass 2 writes the bytes
;   - a memory operand with no register is RIP-relative; with registers it is [base + index*scale + disp]
;
; API (both need the text in memory; they do not call the operating system):
;   asm_pass01   rsi = text, rcx = length   -> eax = 0 or an error code;  asm_size = bytes of image to reserve
;   asm_pass2    rdi = the image (ASM_BASE, writable, zeroed)  -> eax = 0 or an error code
; Error codes: 1 unknown instruction / directive, 2 bad operand, 3 undefined symbol, 4 bad expression, 5 table full, 6 operand mix
; not supported.  asm_err_line = the line of the first error.
;
; Registers inside this file: RSI = cursor in the line, R12 = end of the line (kept by every routine below).
bits 64
default rel

ASM_BASE   equ 0x20000000
SYM_SLOTS  equ 65536            ; hash table slots (32 bytes each), must be a power of two
SYM_POOL   equ 0x200000
E_UNKNOWN  equ 1
E_OPERAND  equ 2
E_UNDEF    equ 3
E_EXPR     equ 4
E_FULL     equ 5
E_FORM     equ 6
E_SIZE     equ 7                ; an instruction changed its size between pass 1 and pass 2 (a bug in this file)

; operand record (16 bytes)
O_KIND     equ 0                ; 0 none, 1 register, 2 memory, 3 immediate, 4 x87 stack register
O_SIZE     equ 1                ; register / memory / immediate size in bytes (0 = not given)
O_REG      equ 2
O_BASE     equ 3                ; 0xFF = none
O_IDX      equ 4                ; 0xFF = none
O_SCALE    equ 5
O_USED     equ 6                ; the value mentions a label
O_VAL      equ 8                ; displacement / immediate

; mnemonic classes
C_ALU      equ 1
C_MOV      equ 2
C_LEA      equ 3
C_TEST     equ 4
C_INCDEC   equ 5
C_UN       equ 6
C_IMUL     equ 7
C_SHIFT    equ 8
C_MOVX     equ 9
C_PUSH     equ 10
C_POP      equ 11
C_CALL     equ 12
C_JMP      equ 13
C_JCC      equ 14
C_SETCC    equ 15
C_BSWAP    equ 16
C_SIMPLE   equ 17
C_REP      equ 18
C_FILD     equ 19
C_FISTP    equ 20
C_FLDCW    equ 21
C_FNSTCW   equ 22
C_FDIV     equ 23
C_FSTP     equ 24
C_SECTION  equ 30
C_IGN      equ 31
C_DATA     equ 32
C_RES      equ 33
C_TIMES    equ 34

section .bss
asm_err        resd 1
asm_err_line   resd 1
asm_size       resq 1
a_pass         resd 1
a_line         resd 1
a_sec          resd 1
a_img          resq 1
a_end          resq 1
a_src          resq 1
next_line      resq 1
cur_addr       resq 1
sec_off        resq 3
sec_start      resq 3
sec_size       resq 3
scope_len      resd 1
scope_buf      resb 256
name_len       resd 1
name_buf       resb 512
tok_q          resq 1
tok_ptr        resq 1
tok_len        resd 1
ev_used        resb 1
a_nops         resb 1
ins_len        resd 1
ins_buf        resb 32
opd_a          resb 16
opd_b          resb 16
er_pfx         resb 1
er_w           resb 1
er_force       resb 1
er_immlen      resb 1
er_opclen      resb 1
er_reg         resb 1
er_opc         resd 1
er_rm          resq 1
er_imm         resq 1
sym_pool_len   resq 1
sym_tab        resb SYM_SLOTS * 32
sym_pool       resb SYM_POOL

section .data
; ---- registers: name (packed, lower case), number, size -----------------------------------------------------------
%macro PK 1
    %strlen %%n %1
    %assign %%v 0
    %assign %%i 0
    %rep %%n
        %substr %%c %1 %%i + 1
        %assign %%v %%v | (%%c << (8 * %%i))
        %assign %%i %%i + 1
    %endrep
    dq %%v
%endmacro
%macro REGE 3
    PK %1
    db %2, %3
    times 6 db 0
%endmacro
reg_tab:
    REGE "rax", 0, 8
    REGE "rcx", 1, 8
    REGE "rdx", 2, 8
    REGE "rbx", 3, 8
    REGE "rsp", 4, 8
    REGE "rbp", 5, 8
    REGE "rsi", 6, 8
    REGE "rdi", 7, 8
    REGE "r8", 8, 8
    REGE "r9", 9, 8
    REGE "r10", 10, 8
    REGE "r11", 11, 8
    REGE "r12", 12, 8
    REGE "r13", 13, 8
    REGE "r14", 14, 8
    REGE "r15", 15, 8
    REGE "eax", 0, 4
    REGE "ecx", 1, 4
    REGE "edx", 2, 4
    REGE "ebx", 3, 4
    REGE "esp", 4, 4
    REGE "ebp", 5, 4
    REGE "esi", 6, 4
    REGE "edi", 7, 4
    REGE "r8d", 8, 4
    REGE "r9d", 9, 4
    REGE "r10d", 10, 4
    REGE "r11d", 11, 4
    REGE "r12d", 12, 4
    REGE "r13d", 13, 4
    REGE "r14d", 14, 4
    REGE "r15d", 15, 4
    REGE "ax", 0, 2
    REGE "cx", 1, 2
    REGE "dx", 2, 2
    REGE "bx", 3, 2
    REGE "sp", 4, 2
    REGE "bp", 5, 2
    REGE "si", 6, 2
    REGE "di", 7, 2
    REGE "r8w", 8, 2
    REGE "r9w", 9, 2
    REGE "r10w", 10, 2
    REGE "r11w", 11, 2
    REGE "r12w", 12, 2
    REGE "r13w", 13, 2
    REGE "r14w", 14, 2
    REGE "r15w", 15, 2
    REGE "al", 0, 1
    REGE "cl", 1, 1
    REGE "dl", 2, 1
    REGE "bl", 3, 1
    REGE "spl", 4, 1
    REGE "bpl", 5, 1
    REGE "sil", 6, 1
    REGE "dil", 7, 1
    REGE "r8b", 8, 1
    REGE "r9b", 9, 1
    REGE "r10b", 10, 1
    REGE "r11b", 11, 1
    REGE "r12b", 12, 1
    REGE "r13b", 13, 1
    REGE "r14b", 14, 1
    REGE "r15b", 15, 1
reg_end:
REG_N equ 64

; ---- condition codes (for jcc / setcc) ------------------------------------------------------------------------------
%macro CCE 2
    PK %1
    dq %2
%endmacro
cc_tab:
    CCE "o", 0
    CCE "no", 1
    CCE "b", 2
    CCE "c", 2
    CCE "nae", 2
    CCE "ae", 3
    CCE "nb", 3
    CCE "nc", 3
    CCE "e", 4
    CCE "z", 4
    CCE "ne", 5
    CCE "nz", 5
    CCE "be", 6
    CCE "na", 6
    CCE "a", 7
    CCE "nbe", 7
    CCE "s", 8
    CCE "ns", 9
    CCE "p", 10
    CCE "np", 11
    CCE "l", 12
    CCE "nge", 12
    CCE "ge", 13
    CCE "nl", 13
    CCE "le", 14
    CCE "ng", 14
    CCE "g", 15
    CCE "nle", 15
cc_end:
CC_N equ 28

; ---- mnemonics and directives: name (packed), class, n, then 3 literal bytes for the simple ones -----------------------
%macro MNE 3
    PK %1
    db %2, %3, 0, 0, 0, 0, 0, 0
%endmacro
%macro MNS 3-5 0, 0
    PK %1
    db C_SIMPLE, 0, %2
    db %3, %4, %5, 0, 0
%endmacro
mn_tab:
    MNE "add", C_ALU, 0
    MNE "or", C_ALU, 1
    MNE "and", C_ALU, 4
    MNE "sub", C_ALU, 5
    MNE "xor", C_ALU, 6
    MNE "cmp", C_ALU, 7
    MNE "mov", C_MOV, 0
    MNE "lea", C_LEA, 0
    MNE "test", C_TEST, 0
    MNE "inc", C_INCDEC, 0
    MNE "dec", C_INCDEC, 1
    MNE "not", C_UN, 2
    MNE "neg", C_UN, 3
    MNE "mul", C_UN, 4
    MNE "div", C_UN, 6
    MNE "idiv", C_UN, 7
    MNE "imul", C_IMUL, 0
    MNE "shl", C_SHIFT, 4
    MNE "shr", C_SHIFT, 5
    MNE "sar", C_SHIFT, 7
    MNE "rol", C_SHIFT, 0
    MNE "ror", C_SHIFT, 1
    MNE "movzx", C_MOVX, 0
    MNE "movsx", C_MOVX, 8
    MNE "push", C_PUSH, 0
    MNE "pop", C_POP, 0
    MNE "call", C_CALL, 0
    MNE "jmp", C_JMP, 0
    MNE "bswap", C_BSWAP, 0
    MNE "rep", C_REP, 0
    MNE "fild", C_FILD, 0
    MNE "fistp", C_FISTP, 0
    MNE "fldcw", C_FLDCW, 0
    MNE "fnstcw", C_FNSTCW, 0
    MNE "fdiv", C_FDIV, 0
    MNE "fstp", C_FSTP, 0
    MNE "section", C_SECTION, 0
    MNE "bits", C_IGN, 0
    MNE "default", C_IGN, 0
    MNE "global", C_IGN, 0
    MNE "extern", C_IGN, 0
    MNE "db", C_DATA, 1
    MNE "dw", C_DATA, 2
    MNE "dd", C_DATA, 4
    MNE "dq", C_DATA, 8
    MNE "resb", C_RES, 1
    MNE "resw", C_RES, 2
    MNE "resd", C_RES, 4
    MNE "resq", C_RES, 8
    MNE "times", C_TIMES, 0
    MNS "ret", 1, 0xC3
    MNS "syscall", 2, 0x0F, 0x05
    MNS "cqo", 2, 0x48, 0x99
    MNS "cdq", 1, 0x99
    MNS "nop", 1, 0x90
    MNS "movsb", 1, 0xA4
    MNS "movsq", 2, 0x48, 0xA5
    MNS "stosb", 1, 0xAA
    MNS "stosq", 2, 0x48, 0xAB
    MNS "cld", 1, 0xFC
mn_end:
MN_N equ (mn_end - mn_tab) / 16

section .text
; ============================================================================================================================
;  lexing
; ============================================================================================================================
skip_ws:
    cmp  rsi, r12
    jae  .r
    mov  al, [rsi]
    cmp  al, ' '
    je   .n
    cmp  al, 9
    jne  .r
.n: inc  rsi
    jmp  skip_ws
.r: ret

; al = a character -> eax = 1 when it can be part of a name
as_ident_char:
    cmp  al, '_'
    je   .y
    cmp  al, '.'
    je   .y
    cmp  al, '@'
    je   .y
    cmp  al, '$'
    je   .y
    cmp  al, '0'
    jb   .n
    cmp  al, '9'
    jbe  .y
    cmp  al, 'A'
    jb   .n
    cmp  al, 'Z'
    jbe  .y
    cmp  al, 'a'
    jb   .n
    cmp  al, 'z'
    jbe  .y
.n: xor  eax, eax
    ret
.y: mov  eax, 1
    ret

; reads a name at RSI: [tok_ptr], [tok_len], tok_q = the name packed in lower case (0xFF.. when longer than 8)
as_read_ident:
    mov  [tok_ptr], rsi
.l: cmp  rsi, r12
    jae  .d
    mov  al, [rsi]
    call as_ident_char
    test eax, eax
    jz   .d
    inc  rsi
    jmp  .l
.d: mov  rcx, rsi
    sub  rcx, [tok_ptr]
    mov  [tok_len], ecx
    mov  rdi, [tok_ptr]
    xor  eax, eax
    cmp  ecx, 8
    ja   .long
    mov  r9d, ecx                   ; the length
    xor  edx, edx
.p: cmp  edx, r9d
    jae  .ok
    movzx r8d, byte [rdi + rdx]
    cmp  r8b, 'A'
    jb   .lc
    cmp  r8b, 'Z'
    ja   .lc
    or   r8b, 0x20
.lc:lea  ecx, [rdx * 8]
    shl  r8, cl
    or   rax, r8
    inc  edx
    jmp  .p
.long:
    mov  rax, -1
.ok:mov  [tok_q], rax
    ret

; tok_q -> RAX = the register record or 0
find_reg:
    lea  rdx, [reg_tab]
    mov  ecx, REG_N
    mov  rax, [tok_q]
.l: cmp  [rdx], rax
    je   .f
    add  rdx, 16
    dec  ecx
    jnz  .l
    xor  eax, eax
    ret
.f: mov  rax, rdx
    ret

; ============================================================================================================================
;  symbols
; ============================================================================================================================
; RDI = name, ECX = length -> RAX = entry or 0 ;  R10 = the slot when not found (for sym_add)
sym_find:
    mov  eax, 0x811C9DC5
    xor  edx, edx
.h: cmp  edx, ecx
    jae  .hd
    movzx r8d, byte [rdi + rdx]
    xor  eax, r8d
    imul eax, eax, 0x01000193
    inc  edx
    jmp  .h
.hd:and  eax, SYM_SLOTS - 1
.p: mov  r10d, eax
    shl  r10, 5
    lea  r11, [sym_tab]
    add  r10, r11
    cmp  byte [r10 + 12], 0
    je   .none
    cmp  [r10 + 8], ecx
    jne  .next
    mov  r8, [r10]
    xor  edx, edx
.c: cmp  edx, ecx
    jae  .hit
    mov  r9b, [r8 + rdx]
    cmp  r9b, [rdi + rdx]
    jne  .next
    inc  edx
    jmp  .c
.hit:
    mov  rax, r10
    ret
.next:
    inc  eax
    and  eax, SYM_SLOTS - 1
    jmp  .p
.none:
    xor  eax, eax
    ret

; the name in name_buf; AL = kind (1 label, 2 constant), RDX = section (labels), R8 = value -> adds it (R10 is the free slot)
sym_add:
    push rax
    push rdx
    push r8
    lea  rdi, [name_buf]
    mov  ecx, [name_len]
    call sym_find
    test rax, rax
    jnz  .dup
    mov  rax, [sym_pool_len]
    lea  rdx, [rcx + rax]
    cmp  rdx, SYM_POOL
    jae  .full
    lea  r9, [sym_pool]
    add  r9, rax
    mov  [r10], r9                  ; name pointer
    mov  [r10 + 8], ecx
    xor  edx, edx
.c: cmp  edx, ecx
    jae  .cd
    mov  al, [rdi + rdx]
    mov  [r9 + rdx], al
    inc  edx
    jmp  .c
.cd:mov  rax, [sym_pool_len]
    add  rax, rcx
    mov  [sym_pool_len], rax
    pop  r8
    pop  rdx
    pop  rax
    mov  [r10 + 12], al
    mov  [r10 + 13], dl
    mov  [r10 + 16], r8
    ret
.dup:
    pop  r8
    pop  rdx
    pop  rax
    ret
.full:
    mov  dword [asm_err], E_FULL
    pop  r8
    pop  rdx
    pop  rax
    ret

; RDI = name from the text, ECX = length -> name_buf / name_len ( a name that starts with '.' belongs to the last real label)
build_name:
    lea  r8, [name_buf]
    xor  edx, edx
    cmp  byte [rdi], '.'
    jne  .copy
    lea  r9, [scope_buf]
    mov  edx, [scope_len]
    xor  eax, eax
.s: cmp  eax, edx
    jae  .copy
    mov  r10b, [r9 + rax]
    mov  [r8 + rax], r10b
    inc  eax
    jmp  .s
.copy:
    xor  eax, eax
.c: cmp  eax, ecx
    jae  .d
    mov  r10b, [rdi + rax]
    lea  r11d, [rdx + rax]
    mov  [r8 + r11], r10b
    inc  eax
    jmp  .c
.d: add  edx, ecx
    mov  [name_len], edx
    ret

; ============================================================================================================================
;  expressions:  numbers (decimal, 0x hex), 'c', names, unary -, *, + and -
; ============================================================================================================================
fail_expr:
    mov  dword [asm_err], E_EXPR
    xor  eax, eax
    ret
ev_factor:
    call skip_ws
    cmp  rsi, r12
    jae  fail_expr
    mov  al, [rsi]
    cmp  al, '-'
    jne  .n1
    inc  rsi
    call ev_factor
    neg  rax
    ret
.n1:cmp  al, "'"
    jne  .n2
    lea  rax, [rsi + 3]
    cmp  rax, r12
    ja   fail_expr
    movzx eax, byte [rsi + 1]
    add  rsi, 3
    ret
.n2:cmp  al, '0'
    jb   .name
    cmp  al, '9'
    ja   .name
    xor  eax, eax
    cmp  byte [rsi], '0'
    jne  .dec
    lea  rdx, [rsi + 1]
    cmp  rdx, r12
    jae  .dec
    cmp  byte [rsi + 1], 'x'
    je   .hex
.dec:
    cmp  rsi, r12
    jae  .nd
    movzx ecx, byte [rsi]
    sub  ecx, '0'
    cmp  ecx, 9
    ja   .nd
    imul rax, rax, 10
    add  rax, rcx
    inc  rsi
    jmp  .dec
.hex:
    add  rsi, 2
.h: cmp  rsi, r12
    jae  .nd
    movzx ecx, byte [rsi]
    cmp  cl, '0'
    jb   .nd
    cmp  cl, '9'
    jbe  .hd
    or   cl, 0x20
    cmp  cl, 'a'
    jb   .nd
    cmp  cl, 'f'
    ja   .nd
    sub  cl, 'a' - 10 - '0'
.hd:sub  ecx, '0'
    shl  rax, 4
    add  rax, rcx
    inc  rsi
    jmp  .h
.nd:ret
.name:
    call as_read_ident
    mov  ecx, [tok_len]
    test ecx, ecx
    jz   fail_expr
    mov  rdi, [tok_ptr]
    call build_name
    lea  rdi, [name_buf]
    mov  ecx, [name_len]
    call sym_find
    test rax, rax
    jz   .undef
    cmp  byte [rax + 12], 2
    jne  .label
    mov  rax, [rax + 16]            ; a constant
    ret
.label:
    mov  byte [ev_used], 1
    cmp  dword [a_pass], 2
    jb   .zero
    movzx edx, byte [rax + 13]
    lea  rcx, [sec_start]
    mov  rcx, [rcx + rdx * 8]
    mov  rax, [rax + 16]
    add  rax, rcx
    ret
.zero:
    xor  eax, eax
    ret
.undef:
    mov  byte [ev_used], 1
    cmp  dword [a_pass], 1
    je   .zero
    mov  dword [asm_err], E_UNDEF
    xor  eax, eax
    ret

; factor ( '*' factor )*
ev_product:
    call ev_factor
.l: push rax
    call skip_ws
    cmp  rsi, r12
    jae  .d
    cmp  byte [rsi], '*'
    jne  .d
    inc  rsi
    call ev_factor
    pop  rdx
    imul rax, rdx
    jmp  .l
.d: pop  rax
    ret

; product ( ('+'|'-') product )*   -> RAX ; [ev_used] says whether a label was in it
ev_sum:
    call ev_product
.l: push rax
    call skip_ws
    cmp  rsi, r12
    jae  .d
    mov  al, [rsi]
    cmp  al, '+'
    je   .add
    cmp  al, '-'
    jne  .d
    inc  rsi
    call ev_product
    pop  rdx
    sub  rdx, rax
    mov  rax, rdx
    jmp  .l
.add:
    inc  rsi
    call ev_product
    pop  rdx
    add  rax, rdx
    jmp  .l
.d: pop  rax
    ret

; ============================================================================================================================
;  operands
; ============================================================================================================================
section .data
kw_byte:  PK "byte"
kw_word:  PK "word"
kw_dword: PK "dword"
kw_qword: PK "qword"
kw_equ:   PK "equ"
kw_text:  PK ".text"
kw_data:  PK ".data"
kw_bss:   PK ".bss"
section .bss
mm_buf  resb 16

section .text
; RDI = operand record;  parses one operand at RSI
as_parse_operand:
    push rbx
    push r13
    push r14
    mov  rbx, rdi
    mov  qword [rbx], 0
    mov  qword [rbx + 8], 0
    mov  byte [rbx + O_BASE], 0xFF
    mov  byte [rbx + O_IDX], 0xFF
    mov  byte [rbx + O_SCALE], 1
    mov  byte [ev_used], 0
    call skip_ws
    cmp  rsi, r12
    jae  .bad
    mov  al, [rsi]
    cmp  al, '['
    je   .mem
    cmp  al, '0'
    jb   .chk
    cmp  al, '9'
    jbe  .imm
.chk:
    call as_ident_char
    test eax, eax
    jz   .imm
    mov  r13, rsi
    call as_read_ident
    call find_reg
    test rax, rax
    jz   .notreg
    mov  byte [rbx + O_KIND], 1
    mov  cl, [rax + 9]
    mov  [rbx + O_SIZE], cl
    mov  cl, [rax + 8]
    mov  [rbx + O_REG], cl
    jmp  .done
.notreg:
    mov  rax, [tok_q]
    mov  cl, 1
    cmp  rax, [kw_byte]
    je   .size
    mov  cl, 2
    cmp  rax, [kw_word]
    je   .size
    mov  cl, 4
    cmp  rax, [kw_dword]
    je   .size
    mov  cl, 8
    cmp  rax, [kw_qword]
    je   .size
    cmp  dword [tok_len], 3         ; st0 .. st7
    jne  .backimm
    mov  rdx, [tok_ptr]
    cmp  word [rdx], 'st'
    jne  .backimm
    movzx eax, byte [rdx + 2]
    sub  eax, '0'
    cmp  eax, 7
    ja   .backimm
    mov  byte [rbx + O_KIND], 4
    mov  [rbx + O_REG], al
    jmp  .done
.backimm:
    mov  rsi, r13
    jmp  .imm
.size:
    mov  [rbx + O_SIZE], cl
    call skip_ws
    cmp  rsi, r12
    jae  .bad
    cmp  byte [rsi], '['
    je   .mem
.imm:
    call ev_sum
    mov  [rbx + O_VAL], rax
    mov  byte [rbx + O_KIND], 3
    jmp  .done
.mem:
    inc  rsi
    mov  byte [rbx + O_KIND], 2
.mt:call skip_ws
    cmp  rsi, r12
    jae  .bad
    mov  r14d, 1
    mov  al, [rsi]
    cmp  al, ']'
    je   .mclose
    cmp  al, '+'
    jne  .m1
    inc  rsi
    call skip_ws
    jmp  .m2
.m1:cmp  al, '-'
    jne  .m2
    mov  r14d, -1
    inc  rsi
    call skip_ws
.m2:cmp  rsi, r12
    jae  .bad
    mov  al, [rsi]
    cmp  al, '0'
    jb   .m3
    cmp  al, '9'
    jbe  .mval
.m3:call as_ident_char
    test eax, eax
    jz   .mval
    mov  r13, rsi
    call as_read_ident
    call find_reg
    test rax, rax
    jz   .mnotreg
    movzx ecx, byte [rax + 8]
    call skip_ws
    cmp  rsi, r12
    jae  .mset
    cmp  byte [rsi], '*'
    jne  .mset
    inc  rsi
    call skip_ws
    movzx edx, byte [rsi]
    sub  edx, '0'
    inc  rsi
    mov  [rbx + O_IDX], cl
    mov  [rbx + O_SCALE], dl
    jmp  .mt
.mset:
    cmp  byte [rbx + O_BASE], 0xFF
    jne  .mi
    mov  [rbx + O_BASE], cl
    jmp  .mt
.mi:mov  [rbx + O_IDX], cl
    mov  byte [rbx + O_SCALE], 1
    jmp  .mt
.mnotreg:
    mov  rsi, r13
.mval:
    call ev_product
    movsxd rdx, r14d
    imul rax, rdx
    add  [rbx + O_VAL], rax
    jmp  .mt
.mclose:
    inc  rsi
.done:
    mov  al, [ev_used]
    mov  [rbx + O_USED], al
    pop  r14
    pop  r13
    pop  rbx
    ret
.bad:
    mov  dword [asm_err], E_OPERAND
    jmp  .done

; ============================================================================================================================
;  the ModRM / REX / opcode / immediate builder.  In:  er_pfx er_w er_force er_opc (up to 3 bytes) er_opclen er_reg er_rm er_imm er_immlen
;  Out: ins_buf / ins_len
; ============================================================================================================================
emit_rm:
    push rbx
    push rsi
    push r13
    push r14
    push r15
    mov  rbx, [er_rm]
    movzx r8d, byte [er_reg]
    xor  r10d, r10d                 ; REX.X
    xor  r11d, r11d                 ; REX.B
    xor  r13d, r13d                 ; 1 = RIP-relative
    lea  rdi, [mm_buf]
    mov  r14d, r8d
    and  r14d, 7
    shl  r14d, 3
    cmp  byte [rbx + O_KIND], 1
    jne  .memop
    movzx eax, byte [rbx + O_REG]
    mov  r11d, eax
    shr  r11d, 3
    and  eax, 7
    or   eax, r14d
    or   eax, 0xC0
    mov  [rdi], al
    mov  r9d, 1
    jmp  .built
.memop:
    movzx eax, byte [rbx + O_BASE]
    movzx ecx, byte [rbx + O_IDX]
    cmp  eax, 0xFF
    jne  .hasbase
    cmp  ecx, 0xFF
    jne  .idxonly
    lea  eax, [r14 + 5]             ; RIP-relative: fixed up below
    mov  [rdi], al
    mov  dword [rdi + 1], 0
    mov  r9d, 5
    mov  r13d, 1
    jmp  .built
.idxonly:                           ; [index*scale + disp32]
    mov  r10d, ecx
    shr  r10d, 3
    lea  eax, [r14 + 4]
    mov  [rdi], al
    movzx edx, byte [rbx + O_SCALE]
    bsf  edx, edx
    shl  edx, 6
    and  ecx, 7
    shl  ecx, 3
    or   edx, ecx
    or   edx, 5
    mov  [rdi + 1], dl
    mov  rax, [rbx + O_VAL]
    mov  [rdi + 2], eax
    mov  r9d, 6
    jmp  .built
.hasbase:
    mov  r11d, eax
    shr  r11d, 3
    mov  r15d, eax
    and  r15d, 7                    ; base & 7
    xor  edx, edx                   ; 1 = SIB needed
    cmp  ecx, 0xFF
    je   .noidx
    mov  edx, 1
    mov  r10d, ecx
    shr  r10d, 3
.noidx:
    cmp  r15d, 4
    jne  .nosib4
    mov  edx, 1
.nosib4:
    mov  rax, [rbx + O_VAL]
    cmp  byte [rbx + O_USED], 0
    jne  .mod2
    test rax, rax
    jnz  .tryb
    cmp  r15d, 5
    je   .mod1
    xor  esi, esi                   ; mod 0, no displacement bytes (ESI is free here: RSI is saved on entry)
    jmp  .modok
.tryb:
    cmp  rax, -128
    jl   .mod2
    cmp  rax, 127
    jg   .mod2
.mod1:
    mov  esi, 1
    jmp  .modok
.mod2:
    mov  esi, 2
.modok:
    ; ESI = mod
    mov  eax, esi
    shl  eax, 6
    or   eax, r14d
    test edx, edx
    jz   .nosib
    or   eax, 4
    mov  [rdi], al
    cmp  ecx, 0xFF
    jne  .hasidx
    mov  ecx, 4
    xor  edx, edx                   ; scale 1 -> 0
    jmp  .sibb
.hasidx:
    movzx edx, byte [rbx + O_SCALE]
    bsf  edx, edx
.sibb:
    shl  edx, 6
    and  ecx, 7
    shl  ecx, 3
    or   edx, ecx
    or   edx, r15d
    mov  [rdi + 1], dl
    mov  r9d, 2
    jmp  .disp
.nosib:
    or   eax, r15d
    mov  [rdi], al
    mov  r9d, 1
.disp:
    mov  rax, [rbx + O_VAL]
    cmp  esi, 1
    jne  .d2
    mov  [rdi + r9], al
    inc  r9d
    jmp  .built
.d2:cmp  esi, 2
    jne  .built
    mov  [rdi + r9], eax
    add  r9d, 4
.built:
    ; REX
    mov  eax, 0x40
    movzx ecx, byte [er_w]
    shl  ecx, 3
    or   eax, ecx
    mov  ecx, r8d
    shr  ecx, 3
    shl  ecx, 2
    or   eax, ecx
    lea  ecx, [r10 * 2]
    or   eax, ecx
    or   eax, r11d
    mov  r15d, eax                  ; REX byte
    ; write the instruction
    lea  rdi, [ins_buf]
    cmp  byte [er_pfx], 0
    je   .nopfx
    mov  al, [er_pfx]
    stosb
.nopfx:
    cmp  r15d, 0x40
    jne  .rex
    cmp  byte [er_force], 0
    je   .norex
.rex:
    mov  al, r15b
    stosb
.norex:
    mov  eax, [er_opc]
    movzx ecx, byte [er_opclen]
.oc:test ecx, ecx
    jz   .ocd
    stosb
    shr  eax, 8
    dec  ecx
    jmp  .oc
.ocd:
    lea  rsi, [mm_buf]
    mov  r14, rdi                   ; where the ModRM starts
    mov  ecx, r9d
.mb:test ecx, ecx
    jz   .mbd
    mov  al, [rsi]
    stosb
    inc  rsi
    dec  ecx
    jmp  .mb
.mbd:
    movzx ecx, byte [er_immlen]
    mov  rax, [er_imm]
.im:test ecx, ecx
    jz   .imd
    stosb
    shr  rax, 8
    dec  ecx
    jmp  .im
.imd:
    lea  rax, [ins_buf]
    sub  rdi, rax
    mov  [ins_len], edi             ; total length
    test r13d, r13d
    jz   .ret
    xor  eax, eax                   ; RIP-relative displacement
    cmp  dword [a_pass], 2
    jne  .rp
    mov  rax, [rbx + O_VAL]
    sub  rax, [cur_addr]
    mov  ecx, [ins_len]
    sub  rax, rcx
.rp:mov  [r14 + 1], eax
.ret:
    pop  r15
    pop  r14
    pop  r13
    pop  rsi
    pop  rbx
    ret

; ============================================================================================================================
;  instructions
; ============================================================================================================================
section .bss
cur_n      resb 1
cur_cls    resb 1
cur_sz     resd 1
cur_ent    resq 1

section .text
; sets er_pfx / er_w from the operand size in EAX; clears the rest of the builder
er_init:
    xor  ecx, ecx
    mov  [er_pfx], cl
    mov  [er_w], cl
    mov  [er_force], cl
    mov  [er_immlen], cl
    mov  qword [er_imm], 0
    cmp  eax, 2
    jne  .a
    mov  byte [er_pfx], 0x66
.a: cmp  eax, 8
    jne  .b
    mov  byte [er_w], 1
.b: ret

; EAX = the operand size from opd_a / opd_b (a register first, then a memory operand that has a size); 0 + error when there is none
get_osz:
    cmp  byte [opd_a + O_KIND], 1
    jne  .1
    movzx eax, byte [opd_a + O_SIZE]
    ret
.1: cmp  byte [opd_b + O_KIND], 1
    jne  .2
    movzx eax, byte [opd_b + O_SIZE]
    ret
.2: cmp  byte [opd_a + O_KIND], 2
    jne  .3
    movzx eax, byte [opd_a + O_SIZE]
    test eax, eax
    jnz  .r
.3: cmp  byte [opd_b + O_KIND], 2
    jne  .4
    movzx eax, byte [opd_b + O_SIZE]
    test eax, eax
    jnz  .r
.4: mov  dword [asm_err], E_OPERAND
    xor  eax, eax
.r: ret

; AL = 1 when the register operand RDI is spl / bpl / sil / dil (they need a REX prefix)
rex8:
    cmp  byte [rdi + O_KIND], 1
    jne  .n
    cmp  byte [rdi + O_SIZE], 1
    jne  .n
    movzx eax, byte [rdi + O_REG]
    sub  eax, 4
    cmp  eax, 3
    ja   .n
    mov  eax, 1
    ret
.n: xor  eax, eax
    ret
; er_force = rex8(opd_a) | rex8(opd_b)
set_force:
    lea  rdi, [opd_a]
    call rex8
    mov  edx, eax
    lea  rdi, [opd_b]
    call rex8
    or   al, dl
    mov  [er_force], al
    ret

; the 16 / 32 bit immediate length of an operation of size [cur_sz]; value from opd_b
imm_for_size:
    mov  rax, [opd_b + O_VAL]
    mov  [er_imm], rax
    mov  byte [er_immlen], 4
    cmp  dword [cur_sz], 2
    jne  .r
    mov  byte [er_immlen], 2
.r: ret

; BL = a one byte opcode,  ECX..: builds with the opcode in er_opc
set_opc1:
    mov  [er_opc], eax
    mov  byte [er_opclen], 1
    ret

; ---- ALU:  add or and sub xor cmp -------------------------------------------------------------------------------------------
h_alu:
    call get_osz
    test eax, eax
    jz   .ret
    mov  [cur_sz], eax
    call er_init
    call set_force
    movzx r8d, byte [cur_n]
    mov  [er_reg], r8b
    cmp  byte [opd_b + O_KIND], 3
    jne  .notimm
    lea  rax, [opd_a]
    mov  [er_rm], rax
    mov  rdx, [opd_b + O_VAL]
    cmp  dword [cur_sz], 1
    jne  .n1
    mov  eax, 0x80
    call set_opc1
    mov  [er_imm], rdx
    mov  byte [er_immlen], 1
    jmp  .go
.n1:cmp  byte [opd_b + O_USED], 0
    jne  .big
    cmp  rdx, -128
    jl   .big
    cmp  rdx, 127
    jg   .big
    mov  eax, 0x83
    call set_opc1
    mov  [er_imm], rdx
    mov  byte [er_immlen], 1
    jmp  .go
.big:
    mov  eax, 0x81
    call set_opc1
    call imm_for_size
    jmp  .go
.notimm:
    mov  eax, r8d
    shl  eax, 3
    cmp  byte [opd_a + O_KIND], 1
    jne  .store
    cmp  byte [opd_b + O_KIND], 1
    je   .store
    ; reg, r/m
    or   eax, 3
    cmp  dword [cur_sz], 1
    jne  .l1
    dec  eax
.l1:call set_opc1
    movzx eax, byte [opd_a + O_REG]
    mov  [er_reg], al
    lea  rax, [opd_b]
    mov  [er_rm], rax
    jmp  .go
.store:                             ; r/m, reg
    cmp  byte [opd_b + O_KIND], 1
    jne  .form
    or   eax, 1
    cmp  dword [cur_sz], 1
    jne  .l2
    dec  eax
.l2:call set_opc1
    movzx eax, byte [opd_b + O_REG]
    mov  [er_reg], al
    lea  rax, [opd_a]
    mov  [er_rm], rax
.go:call emit_rm
.ret:ret
.form:
    mov  dword [asm_err], E_FORM
    ret

; ---- mov ---------------------------------------------------------------------------------------------------------------------
h_mov:
    call get_osz
    test eax, eax
    jz   h_alu.ret
    mov  [cur_sz], eax
    call er_init
    call set_force
    cmp  byte [opd_b + O_KIND], 3
    jne  .nonimm
    mov  rdx, [opd_b + O_VAL]
    cmp  byte [opd_a + O_KIND], 1
    jne  .memimm
    movzx ecx, byte [opd_a + O_REG]
    cmp  dword [cur_sz], 8
    jne  .r4
    cmp  byte [opd_b + O_USED], 0
    jne  .c7
    movsxd rax, edx
    cmp  rax, rdx
    je   .c7                        ; fits 32 bits signed: the C7 form
    ; mov r64, imm64
    lea  rdi, [ins_buf]
    mov  al, 0x48
    cmp  ecx, 8
    jb   .i1
    or   al, 1
.i1:stosb
    mov  al, 0xB8
    and  ecx, 7
    or   al, cl
    stosb
    mov  rax, rdx
    stosq
    mov  dword [ins_len], 10
    ret
.r4:cmp  dword [cur_sz], 4
    jne  .r1
    lea  rdi, [ins_buf]
    cmp  ecx, 8
    jb   .i2
    mov  al, 0x41
    stosb
.i2:mov  al, 0xB8
    and  ecx, 7
    or   al, cl
    stosb
    mov  eax, edx
    stosd
    lea  rax, [ins_buf]
    sub  rdi, rax
    mov  [ins_len], edi
    ret
.r1:cmp  dword [cur_sz], 1
    jne  .r2
    lea  rdi, [ins_buf]
    cmp  ecx, 8
    jb   .l8
    mov  al, 0x41
    stosb
    jmp  .i3
.l8:cmp  ecx, 4
    jb   .i3
    mov  al, 0x40
    stosb
.i3:mov  al, 0xB0
    and  ecx, 7
    or   al, cl
    stosb
    mov  al, dl
    stosb
    lea  rax, [ins_buf]
    sub  rdi, rax
    mov  [ins_len], edi
    ret
.r2:lea  rdi, [ins_buf]            ; 16 bit
    mov  al, 0x66
    stosb
    cmp  ecx, 8
    jb   .i4
    mov  al, 0x41
    stosb
.i4:mov  al, 0xB8
    and  ecx, 7
    or   al, cl
    stosb
    mov  ax, dx
    stosw
    lea  rax, [ins_buf]
    sub  rdi, rax
    mov  [ins_len], edi
    ret
.c7:lea  rax, [opd_a]               ; mov r64, imm32 (sign extended)
    mov  [er_rm], rax
    mov  byte [er_w], 1
    mov  eax, 0xC7
    call set_opc1
    mov  byte [er_reg], 0
    mov  [er_imm], rdx
    mov  byte [er_immlen], 4
    jmp  .go
.memimm:
    lea  rax, [opd_a]
    mov  [er_rm], rax
    mov  byte [er_reg], 0
    mov  [er_imm], rdx
    mov  eax, 0xC7
    cmp  dword [cur_sz], 1
    jne  .m2
    mov  eax, 0xC6
    call set_opc1
    mov  byte [er_immlen], 1
    jmp  .go
.m2:call set_opc1
    mov  byte [er_immlen], 4
    cmp  dword [cur_sz], 2
    jne  .go
    mov  byte [er_immlen], 2
    jmp  .go
.nonimm:
    cmp  byte [opd_a + O_KIND], 1
    jne  .store
    cmp  byte [opd_b + O_KIND], 1
    je   .store
    mov  eax, 0x8B                  ; mov reg, r/m
    cmp  dword [cur_sz], 1
    jne  .l1
    mov  eax, 0x8A
.l1:call set_opc1
    movzx eax, byte [opd_a + O_REG]
    mov  [er_reg], al
    lea  rax, [opd_b]
    mov  [er_rm], rax
    jmp  .go
.store:
    cmp  byte [opd_b + O_KIND], 1
    jne  h_alu.form
    mov  eax, 0x89
    cmp  dword [cur_sz], 1
    jne  .l2
    mov  eax, 0x88
.l2:call set_opc1
    movzx eax, byte [opd_b + O_REG]
    mov  [er_reg], al
    lea  rax, [opd_a]
    mov  [er_rm], rax
.go:call emit_rm
    ret

; ---- lea ---------------------------------------------------------------------------------------------------------------------
h_lea:
    cmp  byte [opd_a + O_KIND], 1
    jne  h_alu.form
    movzx eax, byte [opd_a + O_SIZE]
    call er_init
    mov  byte [er_pfx], 0
    mov  eax, 0x8D
    call set_opc1
    movzx eax, byte [opd_a + O_REG]
    mov  [er_reg], al
    lea  rax, [opd_b]
    mov  [er_rm], rax
    call emit_rm
    ret

; ---- test --------------------------------------------------------------------------------------------------------------------
h_test:
    call get_osz
    test eax, eax
    jz   h_alu.ret
    mov  [cur_sz], eax
    call er_init
    call set_force
    cmp  byte [opd_b + O_KIND], 3
    jne  .reg
    mov  eax, 0xF7
    cmp  dword [cur_sz], 1
    jne  .l1
    mov  eax, 0xF6
.l1:call set_opc1
    mov  byte [er_reg], 0
    lea  rax, [opd_a]
    mov  [er_rm], rax
    mov  rax, [opd_b + O_VAL]
    mov  [er_imm], rax
    mov  byte [er_immlen], 4
    cmp  dword [cur_sz], 1
    jne  .l2
    mov  byte [er_immlen], 1
    jmp  .go
.l2:cmp  dword [cur_sz], 2
    jne  .go
    mov  byte [er_immlen], 2
    jmp  .go
.reg:
    cmp  byte [opd_b + O_KIND], 1
    jne  h_alu.form
    mov  eax, 0x85
    cmp  dword [cur_sz], 1
    jne  .l3
    mov  eax, 0x84
.l3:call set_opc1
    movzx eax, byte [opd_b + O_REG]
    mov  [er_reg], al
    lea  rax, [opd_a]
    mov  [er_rm], rax
.go:call emit_rm
    ret

; ---- one operand r/m:  inc dec not neg mul div idiv ---------------------------------------------------------------------------
h_unary:
    call get_osz
    test eax, eax
    jz   h_alu.ret
    mov  [cur_sz], eax
    call er_init
    lea  rdi, [opd_a]
    call rex8
    mov  [er_force], al
    movzx eax, byte [cur_n]
    mov  [er_reg], al
    mov  eax, 0xF7
    cmp  byte [cur_cls], C_INCDEC
    jne  .l0
    mov  eax, 0xFF
    cmp  dword [cur_sz], 1
    jne  .l1
    mov  eax, 0xFE
    jmp  .l1
.l0:cmp  dword [cur_sz], 1
    jne  .l1
    mov  eax, 0xF6
.l1:call set_opc1
    lea  rax, [opd_a]
    mov  [er_rm], rax
    call emit_rm
    ret

; ---- imul r, r/m ---------------------------------------------------------------------------------------------------------------
h_imul:
    cmp  byte [a_nops], 2
    jne  h_alu.form
    cmp  byte [opd_a + O_KIND], 1
    jne  h_alu.form
    movzx eax, byte [opd_a + O_SIZE]
    call er_init
    mov  dword [er_opc], 0xAF0F
    mov  byte [er_opclen], 2
    movzx eax, byte [opd_a + O_REG]
    mov  [er_reg], al
    lea  rax, [opd_b]
    mov  [er_rm], rax
    call emit_rm
    ret

; ---- shifts ----------------------------------------------------------------------------------------------------------------------
h_shift:
    movzx eax, byte [opd_a + O_SIZE]
    cmp  byte [opd_a + O_KIND], 1
    je   .sz
    call get_osz
    test eax, eax
    jz   h_alu.ret
.sz:mov  [cur_sz], eax
    call er_init
    lea  rdi, [opd_a]
    call rex8
    mov  [er_force], al
    movzx eax, byte [cur_n]
    mov  [er_reg], al
    lea  rax, [opd_a]
    mov  [er_rm], rax
    cmp  byte [opd_b + O_KIND], 1
    jne  .imm
    mov  eax, 0xD3
    cmp  dword [cur_sz], 1
    jne  .l1
    mov  eax, 0xD2
.l1:call set_opc1
    jmp  .go
.imm:
    mov  eax, 0xC1
    cmp  dword [cur_sz], 1
    jne  .l2
    mov  eax, 0xC0
.l2:call set_opc1
    mov  rax, [opd_b + O_VAL]
    mov  [er_imm], rax
    mov  byte [er_immlen], 1
.go:call emit_rm
    ret

; ---- movzx / movsx -----------------------------------------------------------------------------------------------------------------
h_movx:
    cmp  byte [opd_a + O_KIND], 1
    jne  h_alu.form
    movzx eax, byte [opd_b + O_SIZE]    ; the size of the source (register or memory with a size)
    mov  [cur_sz], eax
    movzx eax, byte [opd_a + O_SIZE]
    call er_init
    lea  rdi, [opd_b]
    call rex8
    mov  [er_force], al
    mov  eax, 0xB60F
    cmp  dword [cur_sz], 2
    jne  .l1
    mov  eax, 0xB70F
.l1:movzx ecx, byte [cur_n]             ; 8 for movsx
    shl  ecx, 8
    or   eax, ecx
    mov  [er_opc], eax
    mov  byte [er_opclen], 2
    movzx eax, byte [opd_a + O_REG]
    mov  [er_reg], al
    lea  rax, [opd_b]
    mov  [er_rm], rax
    call emit_rm
    ret

; ---- push / pop -----------------------------------------------------------------------------------------------------------------
h_push:
    cmp  byte [opd_a + O_KIND], 1
    jne  h_alu.form
    mov  r8d, 0x50
    jmp  push_pop
h_pop:
    cmp  byte [opd_a + O_KIND], 1
    jne  h_alu.form
    mov  r8d, 0x58
push_pop:
    lea  rdi, [ins_buf]
    movzx ecx, byte [opd_a + O_REG]
    cmp  ecx, 8
    jb   .n
    mov  al, 0x41
    stosb
.n: and  ecx, 7
    or   ecx, r8d
    mov  al, cl
    stosb
    lea  rax, [ins_buf]
    sub  rdi, rax
    mov  [ins_len], edi
    ret

; ---- call / jmp / jcc ----------------------------------------------------------------------------------------------------------------
h_call:
    mov  r8d, 0xE8
    mov  r9d, 2
    jmp  jump_common
h_jmp:
    mov  r8d, 0xE9
    mov  r9d, 4
jump_common:
    cmp  byte [opd_a + O_KIND], 3
    jne  .indirect
    lea  rdi, [ins_buf]
    mov  al, r8b
    stosb
    xor  eax, eax
    cmp  dword [a_pass], 2
    jne  .z
    mov  rax, [opd_a + O_VAL]
    sub  rax, [cur_addr]
    sub  rax, 5
.z: stosd
    mov  dword [ins_len], 5
    ret
.indirect:
    xor  eax, eax
    call er_init
    mov  eax, 0xFF
    call set_opc1
    mov  [er_reg], r9b
    lea  rax, [opd_a]
    mov  [er_rm], rax
    call emit_rm
    ret
h_jcc:
    cmp  byte [opd_a + O_KIND], 3
    jne  h_alu.form
    lea  rdi, [ins_buf]
    mov  al, 0x0F
    stosb
    movzx eax, byte [cur_n]
    or   al, 0x80
    stosb
    xor  eax, eax
    cmp  dword [a_pass], 2
    jne  .z
    mov  rax, [opd_a + O_VAL]
    sub  rax, [cur_addr]
    sub  rax, 6
.z: stosd
    mov  dword [ins_len], 6
    ret

; ---- setcc r/m8 ---------------------------------------------------------------------------------------------------------------------
h_setcc:
    xor  eax, eax
    call er_init
    lea  rdi, [opd_a]
    call rex8
    mov  [er_force], al
    movzx eax, byte [cur_n]
    shl  eax, 8
    or   eax, 0x900F
    mov  [er_opc], eax
    mov  byte [er_opclen], 2
    mov  byte [er_reg], 0
    lea  rax, [opd_a]
    mov  [er_rm], rax
    call emit_rm
    ret

; ---- bswap ------------------------------------------------------------------------------------------------------------------------
h_bswap:
    cmp  byte [opd_a + O_KIND], 1
    jne  h_alu.form
    lea  rdi, [ins_buf]
    movzx ecx, byte [opd_a + O_REG]
    cmp  byte [opd_a + O_SIZE], 8
    jne  .d
    mov  al, 0x48
    cmp  ecx, 8
    jb   .w
    or   al, 1
.w: stosb
    jmp  .op
.d: cmp  ecx, 8
    jb   .op
    mov  al, 0x41
    stosb
.op:mov  al, 0x0F
    stosb
    and  ecx, 7
    or   ecx, 0xC8
    mov  al, cl
    stosb
    lea  rax, [ins_buf]
    sub  rdi, rax
    mov  [ins_len], edi
    ret

; ---- x87 ---------------------------------------------------------------------------------------------------------------------------
; EAX = the opcode of the 8 byte form,  EDX = the /digit of it ; the 4 byte form is opcode EAX' ...  (set by the callers)
fpu_mem:
    mov  [er_opc], eax
    mov  byte [er_opclen], 1
    mov  [er_reg], dl
    xor  eax, eax
    call er_init
    lea  rax, [opd_a]
    mov  [er_rm], rax
    call emit_rm
    ret
h_fild:
    mov  eax, 0xDF
    mov  edx, 5
    cmp  byte [opd_a + O_SIZE], 8
    je   fpu_mem
    mov  eax, 0xDB
    xor  edx, edx
    jmp  fpu_mem
h_fistp:
    mov  eax, 0xDF
    mov  edx, 7
    cmp  byte [opd_a + O_SIZE], 8
    je   fpu_mem
    mov  eax, 0xDB
    mov  edx, 3
    jmp  fpu_mem
h_fldcw:
    mov  eax, 0xD9
    mov  edx, 5
    jmp  fpu_mem
h_fnstcw:
    mov  eax, 0xD9
    mov  edx, 7
    jmp  fpu_mem
h_fdiv:                             ; fdiv st0, stN
    cmp  byte [opd_a + O_KIND], 4
    jne  h_alu.form
    cmp  byte [opd_b + O_KIND], 4
    jne  h_alu.form
    cmp  byte [opd_a + O_REG], 0
    jne  h_alu.form
    lea  rdi, [ins_buf]
    mov  al, 0xD8
    stosb
    movzx eax, byte [opd_b + O_REG]
    or   al, 0xF0
    stosb
    mov  dword [ins_len], 2
    ret
h_fstp:
    cmp  byte [opd_a + O_KIND], 4
    jne  h_alu.form
    lea  rdi, [ins_buf]
    mov  al, 0xDD
    stosb
    movzx eax, byte [opd_a + O_REG]
    or   al, 0xD8
    stosb
    mov  dword [ins_len], 2
    ret

; ============================================================================================================================
;  output and directives
; ============================================================================================================================
; AL = a byte for the current section (written in pass 2 into text / data; bss only counts)
put_byte:
    mov  edx, [a_sec]
    cmp  dword [a_pass], 2
    jne  .adv
    cmp  edx, 2
    jae  .adv
    lea  r8, [sec_start]
    mov  r8, [r8 + rdx * 8]
    lea  r9, [sec_off]
    add  r8, [r9 + rdx * 8]
    sub  r8, ASM_BASE
    add  r8, [a_img]
    mov  [r8], al
.adv:
    lea  r9, [sec_off]
    inc  qword [r9 + rdx * 8]
    ret

; db / dw / dd / dq items at RSI,  [cur_n] = the width
data_items:
    push r13
.item:
    call skip_ws
    cmp  rsi, r12
    jae  .done
    cmp  byte [rsi], "'"
    jne  .num
    lea  rax, [rsi + 2]
    cmp  rax, r12
    jae  .num
    cmp  byte [rsi + 2], "'"
    je   .num                       ; 'c' is a number
    inc  rsi                        ; a string
.s: cmp  rsi, r12
    jae  .sd
    mov  al, [rsi]
    cmp  al, "'"
    je   .sd
    call put_byte
    inc  rsi
    jmp  .s
.sd:inc  rsi
    jmp  .next
.num:
    mov  byte [ev_used], 0
    call ev_sum
    movzx ecx, byte [cur_n]
    mov  r13, rax
.w: test ecx, ecx
    jz   .next
    mov  al, r13b
    push rcx
    call put_byte
    pop  rcx
    shr  r13, 8
    dec  ecx
    jmp  .w
.next:
    call skip_ws
    cmp  rsi, r12
    jae  .done
    cmp  byte [rsi], ','
    jne  .done
    inc  rsi
    jmp  .item
.done:
    pop  r13
    ret

; ============================================================================================================================
;  one line
; ============================================================================================================================
; RDI = the table, ECX = entries, RAX = the packed name -> RAX = the entry or 0
find_mn:
    lea  rdx, [mn_tab]
    mov  ecx, MN_N
    mov  rax, [tok_q]
.l: cmp  [rdx], rax
    je   .f
    add  rdx, 16
    dec  ecx
    jnz  .l
    ; jcc / setcc
    mov  rax, [tok_q]
    cmp  rax, -1
    je   .no
    cmp  al, 'j'
    jne  .set
    shr  rax, 8
    mov  r8d, C_JCC
    jmp  .cc
.set:
    mov  rdx, rax
    and  edx, 0xFFFFFF
    cmp  edx, 'set'
    jne  .no
    shr  rax, 24
    mov  r8d, C_SETCC
.cc:test rax, rax
    jz   .no
    lea  rdx, [cc_tab]
    mov  ecx, CC_N
.c: cmp  [rdx], rax
    je   .cf
    add  rdx, 16
    dec  ecx
    jnz  .c
.no:xor  eax, eax
    ret
.cf:movzx eax, byte [rdx + 8]       ; the condition code goes into a pseudo table entry (class, n)
    lea  rdx, [cc_pseudo]
    mov  [rdx + 9], al
    mov  [rdx + 8], r8b
    mov  rax, rdx
    ret
.f: mov  rax, rdx
    ret
section .bss
cc_pseudo resb 16
section .text

; ---- the label at [tok_ptr] / [tok_len] ------------------------------------------------------------------------------------------
define_label:
    mov  rdi, [tok_ptr]
    mov  ecx, [tok_len]
    cmp  byte [rdi], '.'
    je   .local
    cmp  ecx, 255
    ja   .local
    xor  eax, eax                   ; a real label starts a new scope
.s: cmp  eax, ecx
    jae  .sd
    mov  dl, [rdi + rax]
    lea  r8, [scope_buf]
    mov  [r8 + rax], dl
    inc  eax
    jmp  .s
.sd:mov  [scope_len], ecx
.local:
    cmp  dword [a_pass], 1
    je   .add
    cmp  dword [a_pass], 2
    jne  .r
    call build_name                 ; pass 2: the label must be where pass 1 measured it
    lea  rdi, [name_buf]
    mov  ecx, [name_len]
    call sym_find
    test rax, rax
    jz   .r
    mov  edx, [a_sec]
    lea  r9, [sec_off]
    mov  r8, [r9 + rdx * 8]
    cmp  r8, [rax + 16]
    je   .r
    mov  dword [asm_err], E_SIZE
    ret
.add:
    call build_name
    mov  eax, 1
    mov  edx, [a_sec]
    lea  r9, [sec_off]
    mov  r8, [r9 + rdx * 8]
    call sym_add
.r: ret

; the line RSI .. R12 (already trimmed and without a comment)
do_line:
    cmp  rsi, r12
    jae  .ret
    mov  al, [rsi]
    call as_ident_char
    test eax, eax
    jz   .unk
    mov  r15, rsi
    call as_read_ident
    cmp  rsi, r12
    jae  .mnem
    cmp  byte [rsi], ':'
    jne  .mnem
    inc  rsi
    call define_label
    call skip_ws
    jmp  do_line
.mnem:                              ; the first word: a mnemonic, or a constant name before equ
    mov  r15, [tok_ptr]
    mov  r14d, [tok_len]
    mov  r13, rsi
    call skip_ws
    cmp  rsi, r12
    jae  .notequ
    call as_read_ident
    mov  rax, [tok_q]
    cmp  rax, [kw_equ]
    jne  .notequ
    cmp  dword [a_pass], 0
    jne  .ret
    mov  byte [ev_used], 0          ; NAME equ expression
    call ev_sum
    mov  r13, rax
    mov  rdi, r15
    mov  ecx, r14d
    call build_name
    mov  r8, r13
    mov  eax, 2
    xor  edx, edx
    call sym_add
    ret
.notequ:
    cmp  dword [a_pass], 0
    jne  .go
    ret
.go:mov  rsi, r15                   ; read the first word again
    call as_read_ident
    call find_mn
    test rax, rax
    jz   .unk
    mov  [cur_ent], rax
    movzx ecx, byte [rax + 8]
    mov  [cur_cls], cl
    movzx edx, byte [rax + 9]
    mov  [cur_n], dl
    cmp  cl, C_SECTION
    je   .section
    cmp  cl, C_IGN
    je   .ret
    cmp  cl, C_DATA
    je   .data
    cmp  cl, C_RES
    je   .res
    cmp  cl, C_TIMES
    je   .times
    cmp  cl, C_SIMPLE
    je   .simple
    cmp  cl, C_REP
    je   .rep
    ; an instruction: read the operands (an operand that is not there must not keep the one of the line before)
    mov  byte [a_nops], 0
    mov  byte [opd_a + O_KIND], 0
    mov  byte [opd_b + O_KIND], 0
    call skip_ws
    cmp  rsi, r12
    jae  .dispatch
    lea  rdi, [opd_a]
    call as_parse_operand
    mov  byte [a_nops], 1
    call skip_ws
    cmp  rsi, r12
    jae  .dispatch
    cmp  byte [rsi], ','
    jne  .dispatch
    inc  rsi
    lea  rdi, [opd_b]
    call as_parse_operand
    mov  byte [a_nops], 2
.dispatch:
    cmp  dword [asm_err], 0
    jne  .ret
    movzx ecx, byte [cur_cls]
    lea  rax, [disp_tab]
    mov  rax, [rax + rcx * 8]
    test rax, rax
    jz   .unk
    mov  dword [ins_len], 0
    mov  rdx, [sec_off + 0]
    mov  edx, [a_sec]
    lea  r8, [sec_start]
    mov  r8, [r8 + rdx * 8]
    lea  r9, [sec_off]
    add  r8, [r9 + rdx * 8]
    mov  [cur_addr], r8
    call rax
    jmp  emit_ins
.simple:
    mov  rax, [cur_ent]
    lea  rdi, [ins_buf]
    movzx ecx, byte [rax + 10]
    mov  [ins_len], ecx
    lea  rsi, [rax + 11]
    rep  movsb
    jmp  emit_ins
.rep:
    call skip_ws
    call as_read_ident
    call find_mn
    test rax, rax
    jz   .unk
    cmp  byte [rax + 8], C_SIMPLE
    jne  .unk
    lea  rdi, [ins_buf]
    mov  byte [rdi], 0xF3
    inc  rdi
    movzx ecx, byte [rax + 10]
    lea  edx, [rcx + 1]
    mov  [ins_len], edx
    lea  rsi, [rax + 11]
    rep  movsb
    jmp  emit_ins
.section:
    call skip_ws
    call as_read_ident
    mov  rax, [tok_q]
    xor  edx, edx
    cmp  rax, [kw_text]
    je   .ss
    mov  edx, 1
    cmp  rax, [kw_data]
    je   .ss
    mov  edx, 2
    cmp  rax, [kw_bss]
    jne  .unk
.ss:mov  [a_sec], edx
    ret
.data:
    call data_items
    ret
.res:
    mov  byte [ev_used], 0
    call skip_ws
    call ev_sum
    movzx ecx, byte [cur_n]
    imul rax, rcx
    mov  edx, [a_sec]
    lea  r9, [sec_off]
    add  [r9 + rdx * 8], rax
    ret
.times:
    mov  byte [ev_used], 0
    call skip_ws
    call ev_sum
    mov  r13, rax                   ; the count
    call skip_ws
    call as_read_ident
    call find_mn
    test rax, rax
    jz   .unk
    cmp  byte [rax + 8], C_DATA
    jne  .unk
    movzx edx, byte [rax + 9]
    mov  [cur_n], dl
    mov  r14, rsi                   ; the items
.tl:test r13, r13
    jle  .ret
    mov  rsi, r14
    call data_items
    cmp  dword [asm_err], 0
    jne  .ret
    dec  r13
    jmp  .tl
.unk:
    mov  dword [asm_err], E_UNKNOWN
.ret:
    ret

emit_ins:
    cmp  dword [asm_err], 0
    jne  .r
    mov  r13d, [ins_len]
    lea  r14, [ins_buf]
.l: test r13d, r13d
    jz   .r
    mov  al, [r14]
    call put_byte
    inc  r14
    dec  r13d
    jmp  .l
.r: ret

section .data
align 8
disp_tab:
    dq 0, h_alu, h_mov, h_lea, h_test, h_unary, h_unary, h_imul, h_shift, h_movx, h_push, h_pop, h_call, h_jmp, h_jcc, h_setcc
    dq h_bswap, 0, 0, h_fild, h_fistp, h_fldcw, h_fnstcw, h_fdiv, h_fstp

section .text
; ============================================================================================================================
;  the passes
; ============================================================================================================================
; runs the current pass over the whole text [a_src] .. [a_end]
run_pass:
    push rbx
    push r15
    xor  eax, eax
    mov  [a_line], eax
    mov  [a_sec], eax
    mov  [scope_len], eax
    mov  qword [sec_off], 0
    mov  qword [sec_off + 8], 0
    mov  qword [sec_off + 16], 0
    mov  rbx, [a_src]
.next:
    cmp  rbx, [a_end]
    jae  .done
    inc  dword [a_line]
    mov  rsi, rbx
.f: cmp  rsi, [a_end]
    jae  .e
    cmp  byte [rsi], 10
    je   .e
    inc  rsi
    jmp  .f
.e: mov  r12, rsi                   ; end of the line
    lea  rax, [rsi + 1]
    mov  [next_line], rax
    mov  rsi, rbx
    ; cut the comment (a ';' outside quotes)
    xor  edx, edx                   ; the quote we are in (0 = none)
    mov  rdi, rsi
.c: cmp  rdi, r12
    jae  .cd
    mov  al, [rdi]
    test dl, dl
    jz   .nq
    cmp  al, dl
    jne  .cn
    xor  edx, edx
    jmp  .cn
.nq:cmp  al, "'"
    je   .q
    cmp  al, '"'
    je   .q
    cmp  al, '`'
    je   .q
    cmp  al, ';'
    jne  .cn
    mov  r12, rdi
    jmp  .cd
.q: mov  dl, al
.cn:inc  rdi
    jmp  .c
.cd:
.tr:cmp  r12, rsi                   ; trim the end
    jbe  .tl
    mov  al, [r12 - 1]
    cmp  al, ' '
    je   .td
    cmp  al, 9
    je   .td
    cmp  al, 13
    jne  .tl
.td:dec  r12
    jmp  .tr
.tl:call skip_ws
    call do_line
    cmp  dword [asm_err], 0
    je   .ok
    mov  eax, [a_line]
    cmp  dword [asm_err_line], 0
    jne  .done
    mov  [asm_err_line], eax
    jmp  .done
.ok:mov  rbx, [next_line]
    jmp  .next
.done:
    pop  r15
    pop  rbx
    ret

; RSI = the text, RCX = its length  ->  EAX = 0 / error ; [asm_size]
asm_pass01:
    push rbx
    push r15
    push r14
    push r13
    push r12
    mov  [a_src], rsi
    add  rsi, rcx
    mov  [a_end], rsi
    mov  dword [asm_err], 0
    mov  dword [asm_err_line], 0
    mov  qword [sym_pool_len], 0
    lea  rdi, [sym_tab]
    mov  ecx, SYM_SLOTS * 4
    xor  eax, eax
    rep  stosq
    mov  dword [a_pass], 0
    call run_pass
    cmp  dword [asm_err], 0
    jne  .out
    mov  dword [a_pass], 1
    call run_pass
    cmp  dword [asm_err], 0
    jne  .out
    mov  rax, ASM_BASE                      ; lay the sections out, each page aligned
    xor  ecx, ecx
.lay:
    lea  rdx, [sec_start]
    mov  [rdx + rcx * 8], rax
    lea  rdx, [sec_off]
    add  rax, [rdx + rcx * 8]
    add  rax, 0xFFF
    and  rax, -4096
    inc  ecx
    cmp  ecx, 3
    jb   .lay
    sub  rax, ASM_BASE
    mov  [asm_size], rax
.out:
    mov  eax, [asm_err]
    pop  r12
    pop  r13
    pop  r14
    pop  r15
    pop  rbx
    ret

; RDI = the image (zeroed, ASM_BASE ..)  ->  EAX = 0 / error
asm_pass2:
    push rbx
    push r15
    push r14
    push r13
    push r12
    mov  [a_img], rdi
    mov  dword [a_pass], 2
    call run_pass
    mov  eax, [asm_err]
    pop  r12
    pop  r13
    pop  r14
    pop  r15
    pop  rbx
    ret

; RSI = the name -> RAX = the address of that label, 0 when there is none (RCX = its length)
asm_lookup:
    push rbx
    mov  rdi, rsi
    mov  r8, rdi
    call sym_find
    test rax, rax
    jz   .r
    cmp  byte [rax + 12], 1
    jne  .no
    movzx edx, byte [rax + 13]
    lea  rcx, [sec_start]
    mov  rcx, [rcx + rdx * 8]
    mov  rax, [rax + 16]
    add  rax, rcx
    jmp  .r
.no:xor  eax, eax
.r: pop  rbx
    ret
