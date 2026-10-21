; nlang_compiler.nasm - front end of the Nano compiler.
; Included by nlang_main.nasm AFTER nlang_opener.nasm (needs `buffer` and `bytes_read`).
;
; Calling convention: compile takes no args, returns EAX = 0 on success, and
; preserves the Windows non-volatile registers. Compile errors jump to `error`,
; which exits the process with code 0x100 + BX.
bits 64
default rel

extern ExitProcess

; ---- statement flags kept in R14 (0 = start of a statement) -----------------
FN_NONE   equ 0
FN_IF     equ 2
FN_ELIF   equ 3
FN_ELSE   equ 4
FN_VAR    equ 5
FN_WHILE  equ 6
FN_UNTIL  equ 7
FN_FOR    equ 8
FN_BOOL   equ 9
FN_DEF    equ 10
FN_IMPORT equ 11
FN_MEM    equ 12
FN_FS     equ 13
FN_TVAR   equ 14                ; like FN_VAR, but the variable is temporary
FN_LISTDECL equ 15              ; list num|str name
FN_LISTOP   equ 16              ; list.name.append / insert / remove / clear / sort

; ---- variable type byte -----------------------------------------------------
VAR_TEMP      equ 0x80          ; bit 7 set = temporary (tvar), removed by purge_tvars
VAR_TYPE_MASK equ 0x7F          ; low bits: 0 = num, 1 = str, 2 = lstr, 3 = list num, 4 = list str

; ---- value expressions (var initialisers): expr_kind -------------------------
EX_COPY     equ 1               ; other_var
EX_STR_LEN  equ 2               ; s.length         (s is a str)
EX_STR_IDX  equ 3               ; s[#]
EX_LSTR_LEN equ 4               ; l.length         (l is an lstr)
EX_LSTR_IDX equ 5               ; l[#]
EX_LIST_LEN equ 6               ; list.x.length
EX_LIST_IDX equ 7               ; list.x[#]

; ---- list statements: ls_op ---------------------------------------------------
LS_APPEND equ 1
LS_INSERT equ 2
LS_REMOVE equ 3
LS_CLEAR  equ 4
LS_SORT   equ 5

; ---- comment state kept in R13 ----------------------------------------------
CMT_NONE  equ 0
CMT_LINE  equ 1                 ; '#'   -> until end of line
CMT_BLOCK equ 2                 ; '###' -> until the next '###'

; ---- error codes (loaded into BX before `jmp error`) ------------------------
ERR_INVALID_VAR_SYNTAX equ 5    ; malformed var / tvar / list statement
ERR_UNTERMINATED_CMT   equ 6    ; '###' never closed
ERR_NAME_TOO_LONG      equ 7    ; identifier longer than 255 (length is stored in 1 byte)
ERR_BAD_VAR_TYPE       equ 8    ; var/tvar type is not num, str or lstr (list: num or str)
ERR_STR_TOO_LONG       equ 9    ; 'str' literal longer than 8 characters (use lstr)
ERR_UNTERMINATED_STR   equ 10   ; string literal not closed on its line
ERR_REDECLARED         equ 11   ; name already in the variable table
ERR_TABLE_FULL         equ 12   ; 255 variables or 64 KiB table
ERR_OUTPUT_FULL        equ 13   ; generated NASM text exceeds the 1 MiB output buffer
ERR_WRITE_FAILED       equ 14   ; could not create / write the .nasm file
ERR_RESERVED_NAME      equ 15   ; name starting with "__" defined outside a .ns file
ERR_TYPE_MISMATCH      equ 16   ; value / operand has the wrong type for where it is used
ERR_UNKNOWN_VAR        equ 17   ; name is not declared
ERR_NOT_A_LIST         equ 18   ; list.x.<op> where x is not a list
ERR_NOT_A_STRING       equ 19   ; x.length / x[#] where x is not a str / lstr

VAR_TABLE_SIZE equ 0x10000

section .bss
    ; Variable table. This used to live at the absolute address 0xF000, which is
    ; inside the 64 KiB null-guard region of a Windows process -> instant access
    ; violation on first use. Layout is unchanged:
    ;   [0]            number of variables (1 byte)
    ;   per variable:  [len][type][name * len][value...]
    ;   type byte: bit 7 (VAR_TEMP) marks a temporary variable (tvar), the low
    ;              bits (VAR_TYPE_MASK) are the type below
    ;   type 0 = number : 8-byte value
    ;   type 1 = string : 8-byte value (max 8 characters)
    ;   type 2 = lstring: 8-byte big-endian length, then that many payload bytes
    ;   type 3 = list of numbers, type 4 = list of strings: 8 zero bytes
    ;            (the entries live in the generated program, not in this table)
    var_table resb VAR_TABLE_SIZE

    ; The declaration currently being compiled (filled by parse_var_decl, read by
    ; add_var and the writer's write_var).
    is_ns       resb 1              ; 1 when the input file is a .ns (package) file
    resb 7
    vd_name     resq 1              ; -> name in the source buffer
    vd_len      resq 1
    vd_type     resb 1              ; 0 num, 1 str, 2 lstr
    vd_temp     resb 1              ; 1 for tvar
    vd_has_init resb 1
    vd_init_kind resb 1             ; 0 = literal in vd_value, 1 = expression in expr_*
    resb 4
    vd_value    resq 1              ; num value, or the str packed little-endian
    vd_lit_ptr  resq 1              ; lstr payload (in the source buffer)
    vd_lit_len  resq 1

    ; Operands, value expressions and list statements.
    opd_kind    resb 1              ; 0 immediate (opd_imm), 1 variable (opd_name)
    opd_want    resb 1              ; type the operand must have: 0 num, 1 str
    expr_kind   resb 1              ; EX_*
    expr_type   resb 1              ; type of the expression's value: 0 num, 1 str
    ls_op       resb 1              ; LS_*
    ls_type     resb 1              ; 3 list num, 4 list str
    resb 2
    opd_imm     resq 1
    opd_name    resq 1
    opd_len     resq 1
    expr_name   resq 1
    expr_len    resq 1
    ls_name     resq 1
    ls_len      resq 1

section .data
; keyword table: [len][name][dw flag] ... terminated by a zero length byte
%macro KW 2
    db %%end - %%start
%%start: db %1
%%end:   dw %2
%endmacro

kw_table:
    KW "if",     FN_IF
    KW "elif",   FN_ELIF
    KW "else",   FN_ELSE
    KW "var",    FN_VAR
    KW "tvar",   FN_TVAR
    KW "list",   FN_LISTDECL
    KW "while",  FN_WHILE
    KW "until",  FN_UNTIL
    KW "for",    FN_FOR
    KW "bool",   FN_BOOL
    KW "def",    FN_DEF
    KW "import", FN_IMPORT
    db 0
; "mem." and "fs." families are matched by prefix in match_keyword.

zero_char: db '0'               ; default value of an uninitialised str / lstr

section .text

; From this point on is the compiler for the code.
; The functions are as follows:
; if ### % ###: - Basic logic, depends on a boolean value, represented here by hashes for the values and a % for the type of comparison operation.
; elif ### % ###: - More logic, allowing nested if-else conditions to be replaced with a single, longer block of code. Identical in functionality to the 'if' function.
; else: - Function for what happens should an if condition and all elif conditions are not met.
; while ### % ###: - Loop that continues until a condition is not met
; until ### % ###: - Loop that continues until a contition is met
; for @ = *: - Loop that continues until a value, here represented as an @, is equal to a number, represented as an *.
; var num/str/lstr @@@ [= *] - Defines a variable. Its name is represented here as '@@@', and the brackets show an optional way of defining the variable immediately. Otherwise, the variable is initialized to 0 or '0'. Num sets the variable type to a number. Str sets the variable type to a string, at most 8 characters. Lstr sets the variable type to a long string, using RAM space to store the value. Lstr variables are slower, but can contain much more data at once.
; tvar num/str/lstr @@@ [= *] - Defines a temporary variable. Its name is represented here as '@@@', and the brackets show an optional way of defining the variable immediately. Otherwise, the variable is initialized to 0 or '0'. Num sets the variable type to a number. Str sets the variable type to a string, at most 8 characters. Lstr sets the variable type to a long string, using RAM space to store the value. Lstr variables are slower, but can contain much more data at once. Temporary variables only exist in the compiled variable table for the duration of the active function, script, or function.
; list functions - Functions that allow the user to manipulate lists, which are arrays of values. The functions are as follows:
; list num/str @@@ - Creates a list of values, named here as '@@@'. The list can be of numbers or strings, but not long strings. The list is stored in RAM, and entries can be accessed with the list.@@@[#] function.
; list.@@@[#] - Used to access a value in a list, where the list is named here as '@@@', and the index of the value is represented here as '#'.
; list.@@@.append * - Appends a value, represented here as '*', to the end of a list, where the list is named here as '@@@'.
; list.@@@.insert #, * - Inserts a value, represented here as '*', into a list, where the list is named here as '@@@', and the index of the value is represented here as '#'.
; list.@@@.remove # - Removes a value from a list, where the list is named here as '@@@', and the index of the value is represented here as '#'.
; list.@@@.clear - Clears all values from a list, where the list is named here as '@@@'.
; list.@@@.length - Returns the number of values in a list, where the list is named here as '@@@'.
; list.@@@.sort - Sorts the values in a list by value (in the case of numerical lists), where the list is named here as '@@@'.
; @@@[#] - Used to find the value at digit # in the string @@@.
; @@@.length - Returns the length of the string @@@.
; # - Used to mark a comment. Single hashes mean one line, every character of text after that point. Triple hashes mean a multi-line comment, which continues until the next triple hash.
; bool ### % ### - used to compute boolean functions seperately, used when defining a variable's value. The result is stored in the variable, and can be used later in the code.
; def @@@ (args): - Defines a function. The name is represented here as '@@@', and arguments, however many are needed, are represented as 'args'. The function is called by using the name of the function, and passing in the arguments. The function can return a value, which can be used in the code.
; import @@@ - Imports the compiled code of another file to this location in this file. The name of the file is represented here as '@@@', and the file must be in the same directory as this file, in the defined directory, in the system's PATH, or from locations such as GitHub using its URL, then its file location. This allows projects built on a GitHub repository to be compiled and run without needing to manually download the new files, replace the file in the directory, and recompile the code, as opposed to simply recompiling the code.
; mem. functions - Functions that allow the user to manipulate memory, such as copying, moving, and deleting data. These functions are as follows:
; mem.get 0xXXXXX - Gets the value of the memory address, represented here as '0xXXXXX', and returns it. Used when defining a variable's value.
; mem.set 0xXXXXX = * - Sets the value of the memory address, represented here as '0xXXXXX', to a value, represented here as '*'.
; mem.clear 0xXXXXX:0xYYYYY - Clears the memory from the address represented here as '0xXXXXX' to the address represented here as '0xYYYYY'.
; mem.copy 0xXXXXX, 0xYYYYY - Copies the memory from the address represented here as '0xXXXXX' to the address represented here as '0xYYYYY'.
; fs. functions - Functions that allow the user to manipulate files, such as creating, deleting, and moving files. These functions are as follows:
; fs.create @@@ - Creates a file with the name represented here as '@@@'.
; fs.delete @@@ - Deletes a file with the name represented here as '@@@'.
; fs.move @@@, @@@ - Moves a file from the first location represented here as '@@@' to the second location represented here as '@@@'.
; fs.copy @@@, @@@ - Copies a file from the first location represented here as '@@@' to the second location represented here as '@@@'.
; fs.rename @@@, @@@ - Renames a file from the first name represented here as '@@@' to the second name represented here as '@@@'.
; fs.read @@@ - Reads a file with the name represented here as '@@@' and returns its contents.
; fs.write @@@, * - Writes a value, represented here as '*', to a file with the name represented here as '@@@'.
; fs.append @@@, * - Appends a value, represented here as '*', to a file with the name represented here as '@@@'.
; fs.list @@@ - Lists the contents of a directory with the name represented here as '@@@'.
; fs.exists @@@ - Checks if a file with the name represented here as '@@@' exists. Returns true if it does, false if it does not.
; fs.isdir @@@ - Checks if a directory with the name represented here as '@@@' exists. Returns true if it does, false if it does not.
; fs.mkdir @@@ - Creates a directory with the name represented here as '@@@'.
; fs.rmdir @@@ - Removes a directory with the name represented here as '@@@'.
; fs.getdir - Gets the current working directory and returns it.
; fs.getsize @@@ - Gets the size of a file with the name represented here as '@@@' and returns it.
; fs.gettime @@@ - Gets the last modified time of a file with the name represented here as '@@@' and returns it.
; fs.zip @@@, @@@ - Zips a file or directory with the name represented here as '@@@' and saves it to the location represented here as '@@@'.
; fs.unzip @@@, @@@ - Unzips a file with the name represented here as '@@@' to the location represented here as '@@@'.
; fs.secure @@@ - Secures a file with the name represented here as '@@@' by encrypting it.
; fs.unsecure @@@ - Unsecures a file with the name represented here as '@@@' by decrypting it.
; fs.getperm @@@ - Gets the permissions of a file or directory with the name represented here as '@@@' and returns it.
; fs.setperm @@@, * - Sets the permissions of a file or directory with the name represented here as '@@@' to the value represented here as '*'.
; fs.modperm @@@, * - Modifies the permissions of a file or directory with the name represented here as '@@@' to the value represented here as '*'.
; fs.getowner @@@ - Gets the owner of a file or directory with the name represented here as '@@@' and returns it.
; fs.setowner @@@, * - Sets the owner of a file or directory with the name represented here as '@@@' to the value represented here as '*'.
; fs.getsecure @@@ - Gets the security status of a file or directory with the name represented here as '@@@' and returns it.
; fs.setsecure @@@, * - Sets the security status of a file or directory with the name represented here as '@@@' to the value represented here as '*'.

; Register plan inside compile (all Windows non-volatile, so they survive calls):
;   rsi = cursor        r12 = end of input     r13 = comment state
;   r14 = statement flag (FN_*)                r15 = base of var_table
;   rdi = start of the current token, rbx = error code
compile:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub  rsp, 32                ; shadow space; 7 pushes + 32 keeps rsp 16-byte aligned

    lea  rsi, [buffer]
    mov  r12, [bytes_read]
    add  r12, rsi
    lea  r15, [var_table]
    xor  r13d, r13d
    xor  r14d, r14d
    xor  ebx, ebx
    call detect_ns              ; package names are only legal in .ns files
    call out_begin              ; NASM header

.func_logic:
    cmp  rsi, r12
    jae  .end_of_file
    movzx eax, byte [rsi]

    cmp  r13d, CMT_LINE
    je   .in_line_comment
    cmp  r13d, CMT_BLOCK
    je   .in_block_comment

    cmp  al, '#'
    je   .comment_start
    cmp  al, 0x0A
    je   .newline
    cmp  al, ' '
    je   .next_char
    cmp  al, 0x09
    je   .next_char
    cmp  al, 0x0D
    je   .next_char

    call ident_char             ; eax = 1 if this starts a token
    test eax, eax
    jnz  .token
    ; Operators, quotes, brackets...: not handled yet (TODO), just skip them.

.next_char:
    inc  rsi
    jmp  .func_logic

.newline:
    test r14d, r14d
    jz   .nl_done
    call write_current_func     ; the statement ended: hand it to the writer
.nl_done:
    xor  r14d, r14d             ; a statement ends at the end of its line
    jmp  .next_char

; ---- comments ---------------------------------------------------------------
; The old state machine overwrote its own flag on every newline (all paths ended
; in `mov r14, 0xFFFF`), so everything after the first newline was treated as an
; endless multi-line comment, and any '#' inside a '#' comment ended it early.
.comment_start:
    mov  r13d, CMT_LINE
    lea  rcx, [rsi + 3]
    cmp  rcx, r12
    ja   .next_char
    cmp  byte [rsi + 1], '#'
    jne  .next_char
    cmp  byte [rsi + 2], '#'
    jne  .next_char
    mov  r13d, CMT_BLOCK
    add  rsi, 3
    jmp  .func_logic

.in_line_comment:
    cmp  al, 0x0A
    jne  .next_char
    xor  r13d, r13d
    jmp  .newline

.in_block_comment:
    cmp  al, '#'
    jne  .next_char
    lea  rcx, [rsi + 3]
    cmp  rcx, r12
    ja   .next_char
    cmp  byte [rsi + 1], '#'
    jne  .next_char
    cmp  byte [rsi + 2], '#'
    jne  .next_char
    xor  r13d, r13d
    add  rsi, 3
    jmp  .func_logic

; ---- tokens -----------------------------------------------------------------
; Detection used to run per CHARACTER with first-letter dispatch ('i' -> if, 'e'
; -> else, ...), which mis-detects any identifier and skipped a character when
; testing "fs"/"else". Now a whole token is scanned, then matched.
.token:
    mov  rdi, rsi
.tok_loop:
    inc  rsi
    cmp  rsi, r12
    jae  .tok_done
    movzx eax, byte [rsi]
    call ident_char
    test eax, eax
    jnz  .tok_loop
.tok_done:
    mov  rcx, rsi
    sub  rcx, rdi               ; token length, rsi is just past the token

    movzx eax, byte [rdi]
    sub  eax, '0'
    cmp  eax, 9
    jbe  .func_logic            ; numeric literal (TODO: emit constants)
    cmp  rcx, 255
    ja   .err_name_too_long

    test r14d, r14d
    jnz  .as_variable           ; mid-statement: keywords are only variables here
    call match_keyword
    test eax, eax
    jz   .as_variable
    mov  r14d, eax
    cmp  eax, FN_VAR
    je   .decl
    cmp  eax, FN_TVAR
    je   .decl
    cmp  eax, FN_LISTDECL
    je   .decl
    cmp  eax, FN_LISTOP
    je   .list_op
    jmp  .func_logic
.decl:
    mov  al, [rsi]              ; 'var' / 'tvar' / 'list' must be followed by a space or tab
    cmp  al, ' '
    je   .decl_ok
    cmp  al, 0x09
    jne  .err_invalid_var
.decl_ok:
    cmp  r14d, FN_LISTDECL
    je   .list_decl
    call parse_var_decl         ; consumes the rest of the statement, writes it out
    jmp  .stmt_done
.list_decl:
    call parse_list_decl
.stmt_done:
    xor  r14d, r14d
    jmp  .func_logic
.list_op:
    call parse_list_op          ; RDI / RCX still hold the token list.name.method
    xor  r14d, r14d
    jmp  .func_logic

.as_variable:
    call find_var               ; rax = record or 0
    test rax, rax
    jz   .func_logic            ; TODO: unknown name -> new variable / function call / syntax error
    ; TODO: emit a load of the variable through the writer
    jmp  .func_logic

.err_invalid_var:
    mov  bx, ERR_INVALID_VAR_SYNTAX
    jmp  error
.err_name_too_long:
    mov  bx, ERR_NAME_TOO_LONG
    jmp  error

.end_of_file:
    cmp  r13d, CMT_BLOCK
    jne  .ok
    mov  bx, ERR_UNTERMINATED_CMT
    jmp  error
.ok:
    test r14d, r14d
    jz   .finish
    call write_current_func     ; last statement had no trailing newline
.finish:
    call purge_tvars            ; temporaries die with the script
    call out_end                ; footer, then write <input>.nasm
    ; TODO: also call purge_tvars when a `def` body / block ends (scopes aren't parsed yet)
    xor  eax, eax
    add  rsp, 32
    pop  r15
    pop  r14
    pop  r13
    pop  r12
    pop  rdi
    pop  rsi
    pop  rbx
    ret

; TODO compilation modes (were empty fall-through labels):
;   standard_compile / shell_compile / core_compile

; ---- helpers ----------------------------------------------------------------

; Exit with 0x100 + BX. Aligns the stack itself so it is safe from any depth.
error:
    movzx ecx, bx
    add  ecx, 0x100
    and  rsp, -16
    sub  rsp, 32
    call ExitProcess

; in: AL   out: EAX = 1 if AL is one of [A-Za-z0-9_.], else 0
ident_char:
    cmp  al, '_'
    je   .yes
    cmp  al, '.'
    je   .yes
    cmp  al, '0'
    jb   .no
    cmp  al, '9'
    jbe  .yes
    or   al, 0x20
    cmp  al, 'a'
    jb   .no
    cmp  al, 'z'
    jbe  .yes
.no:
    xor  eax, eax
    ret
.yes:
    mov  eax, 1
    ret

; in: RDI = token, RCX = length   out: EAX = FN_* flag, 0 if not a keyword
match_keyword:
    lea  r8, [kw_table]
.entry:
    movzx r9d, byte [r8]
    test r9d, r9d
    jz   .prefixes
    cmp  r9, rcx
    jne  .skip
    xor  r10d, r10d
.cmp:
    mov  al, [r8 + 1 + r10]
    cmp  al, [rdi + r10]
    jne  .skip
    inc  r10
    cmp  r10, rcx
    jb   .cmp
    movzx eax, word [r8 + 1 + r9]
    ret
.skip:
    lea  r8, [r8 + r9 + 3]      ; length byte + name + 2-byte flag
    jmp  .entry
.prefixes:
    cmp  rcx, 5                 ; "list." + at least one more character
    jbe  .try_mem
    cmp  dword [rdi], 'list'
    jne  .try_mem
    cmp  byte [rdi + 4], '.'
    jne  .try_mem
    mov  eax, FN_LISTOP
    ret
.try_mem:
    cmp  rcx, 4
    jbe  .try_fs
    cmp  dword [rdi], 'mem.'
    jne  .try_fs
    mov  eax, FN_MEM
    ret
.try_fs:
    cmp  rcx, 3
    jbe  .none
    cmp  word [rdi], 'fs'
    jne  .none
    cmp  byte [rdi + 2], '.'
    jne  .none
    mov  eax, FN_FS
    ret
.none:
    xor  eax, eax
    ret

; in: RDI = token, RCX = length, R15 = var_table
; out: RAX = address of the variable's record (its length byte), or 0
; clobbers RDX, R8-R11. Compares the whole name (the old code compared only the
; first character, did `movzx r8, ah`-style tricks that left dirty upper bits,
; and never finished the "found" path).
find_var:
    movzx r8d, byte [r15]       ; number of variables
    lea  rdx, [r15 + 1]
.next:
    test r8d, r8d
    jz   .none
    movzx r9d, byte [rdx]       ; name length
    movzx r10d, byte [rdx + 1]  ; type
    cmp  r9, rcx
    jne  .skip
    xor  r11d, r11d
.cmp:
    mov  al, [rdx + 2 + r11]
    cmp  al, [rdi + r11]
    jne  .skip
    inc  r11
    cmp  r11, rcx
    jb   .cmp
    mov  rax, rdx
    ret
.skip:
    lea  rdx, [rdx + 2 + r9]    ; -> value
    and  r10d, VAR_TYPE_MASK    ; ignore the temporary flag when sizing the record
    cmp  r10d, 2
    jne  .fixed
    xor  eax, eax               ; long string: decode big-endian length, skip payload
    mov  r11d, 8
.len:
    shl  rax, 8
    movzx r10d, byte [rdx]
    or   rax, r10
    inc  rdx
    dec  r11d
    jnz  .len
    add  rdx, rax
    dec  r8d
    jmp  .next
.fixed:
    add  rdx, 8
    dec  r8d
    jmp  .next
.none:
    xor  eax, eax
    ret

; ---- var / tvar declarations ------------------------------------------------
; These helpers use RSI (cursor) and R12 (end) from compile; they clobber
; RAX, RCX, RDX, RDI, RBX, R8-R11 only.

skip_blanks:                    ; skip spaces and tabs
.l: cmp  rsi, r12
    jae  .d
    mov  al, [rsi]
    cmp  al, ' '
    je   .n
    cmp  al, 0x09
    jne  .d
.n: inc  rsi
    jmp  .l
.d: ret

read_ident:                     ; out: RDI = start, RCX = length (0 = none)
    mov  rdi, rsi
.l: cmp  rsi, r12
    jae  .d
    mov  al, [rsi]
    call ident_char
    test eax, eax
    jz   .d
    inc  rsi
    jmp  .l
.d: mov  rcx, rsi
    sub  rcx, rdi
    ret

; ---- names reserved for .ns files ---------------------------------------------
; A variable name that starts with "__" (two underscores) is reserved for packages:
; it may only be defined in a .ns file; anywhere else defining one is error 0x10F.
; (The check is in parse_var_decl; to change the prefix, change it there.)

; Sets is_ns = 1 if the input path ends in ".ns" (the opener already validated it).
detect_ns:
    lea  rdx, [path_buf]
    xor  r8d, r8d               ; last '.'
.scan:
    mov  al, [rdx]
    test al, al
    jz   .done
    cmp  al, '.'
    jne  .next
    mov  r8, rdx
.next:
    inc  rdx
    jmp  .scan
.done:
    mov  byte [is_ns], 0
    test r8, r8
    jz   .ret
    cmp  dword [r8], 0x00736E2E ; ".ns", NUL
    jne  .ret
    mov  byte [is_ns], 1
.ret:
    ret

; out: RAX = value. Accepts [-]decimal or [-]0xHEX.
parse_number:
    xor  r9d, r9d               ; negative?
    cmp  rsi, r12
    jae  .bad
    cmp  byte [rsi], '-'
    jne  .digits
    mov  r9d, 1
    inc  rsi
.digits:
    xor  eax, eax
    xor  r10d, r10d             ; digit count
    mov  r11d, 10               ; base
    lea  rcx, [rsi + 2]
    cmp  rcx, r12
    ja   .loop
    cmp  byte [rsi], '0'
    jne  .loop
    mov  dl, [rsi + 1]
    or   dl, 0x20
    cmp  dl, 'x'
    jne  .loop
    mov  r11d, 16
    add  rsi, 2
.loop:
    cmp  rsi, r12
    jae  .done
    movzx edx, byte [rsi]
    sub  edx, '0'
    cmp  edx, 9
    jbe  .have
    cmp  r11d, 16
    jne  .done
    movzx edx, byte [rsi]
    or   edx, 0x20
    sub  edx, 'a'
    cmp  edx, 5
    ja   .done
    add  edx, 10
.have:
    imul rax, r11
    add  rax, rdx
    inc  r10d
    inc  rsi
    jmp  .loop
.done:
    test r10d, r10d
    jz   .bad
    test r9d, r9d
    jz   .ret
    neg  rax
.ret:
    ret
.bad:
    mov  bx, ERR_INVALID_VAR_SYNTAX
    jmp  error

; Reads 'text' or "text" (no escape sequences yet) -> vd_lit_ptr / vd_lit_len.
parse_string_lit:
    cmp  rsi, r12
    jae  .bad
    mov  al, [rsi]
    cmp  al, "'"
    je   .open
    cmp  al, '"'
    jne  .bad
.open:
    inc  rsi
    mov  [vd_lit_ptr], rsi
.scan:
    cmp  rsi, r12
    jae  .unterminated
    cmp  byte [rsi], 0x0A
    je   .unterminated
    cmp  byte [rsi], al
    je   .closed
    inc  rsi
    jmp  .scan
.closed:
    mov  rcx, rsi
    sub  rcx, [vd_lit_ptr]
    mov  [vd_lit_len], rcx
    inc  rsi                    ; past the closing quote
    ret
.unterminated:
    mov  bx, ERR_UNTERMINATED_STR
    jmp  error
.bad:
    mov  bx, ERR_INVALID_VAR_SYNTAX
    jmp  error

; var|tvar  num|str|lstr  name  [= literal]      (RSI is just past the keyword)
; Parses the rest of the statement, enters the variable in the table and writes
; its NASM. Leaves RSI at the end of the statement (newline / '#' / EOF).
parse_var_decl:
    call skip_blanks
    call read_ident
    test rcx, rcx
    jz   .syntax
    cmp  rcx, 3
    jne  .try_lstr
    cmp  word [rdi], 'nu'
    jne  .try_str
    cmp  byte [rdi + 2], 'm'
    jne  .bad_type
    mov  byte [vd_type], 0
    jmp  .got_type
.try_str:
    cmp  word [rdi], 'st'
    jne  .bad_type
    cmp  byte [rdi + 2], 'r'
    jne  .bad_type
    mov  byte [vd_type], 1
    jmp  .got_type
.try_lstr:
    cmp  rcx, 4
    jne  .bad_type
    cmp  dword [rdi], 'lstr'
    jne  .bad_type
    mov  byte [vd_type], 2
.got_type:
    call read_new_name          ; validates the name, sets vd_name / vd_len

    cmp  r14d, FN_TVAR
    sete al
    mov  [vd_temp], al
    mov  byte [vd_has_init], 0
    mov  byte [vd_init_kind], 0
    mov  qword [vd_value], 0
    cmp  byte [vd_type], 1
    jne  .def_lit
    mov  qword [vd_value], 0x30 ; str defaults to '0'
.def_lit:
    lea  rax, [zero_char]       ; lstr defaults to "0"
    mov  [vd_lit_ptr], rax
    mov  qword [vd_lit_len], 1

    call skip_blanks
    cmp  rsi, r12
    jae  .end_check
    cmp  byte [rsi], '='
    jne  .end_check
    inc  rsi
    call skip_blanks
    mov  byte [vd_has_init], 1
    cmp  byte [vd_type], 2
    je   .literal               ; lstr takes a string literal only
    cmp  rsi, r12
    jae  .literal               ; (the literal parsers report the missing value)
    mov  al, [rsi]
    call is_ident_start
    test eax, eax
    jnz  .expr
.literal:
    cmp  byte [vd_type], 0
    jne  .init_str
    call parse_number
    mov  [vd_value], rax
    jmp  .end_check
.expr:
    call parse_value_expr       ; var, s.length, s[#], list.x.length, list.x[#]
    cmp  al, [vd_type]
    jne  .mismatch
    mov  byte [vd_init_kind], 1
    jmp  .end_check
.init_str:
    call parse_string_lit
    cmp  byte [vd_type], 2
    je   .end_check
    call pack_str_lit           ; str: up to 8 chars in a qword, first char lowest
    mov  [vd_value], rax
.end_check:                     ; nothing but a comment may follow
    call skip_blanks
    cmp  rsi, r12
    jae  .store
    mov  al, [rsi]
    cmp  al, 0x0A
    je   .store
    cmp  al, 0x0D
    je   .store
    cmp  al, '#'
    je   .store
.syntax:
    mov  bx, ERR_INVALID_VAR_SYNTAX
    jmp  error
.store:
    call add_var
    jmp  write_var              ; tail call
.bad_type:
    mov  bx, ERR_BAD_VAR_TYPE
    jmp  error
.mismatch:
    mov  bx, ERR_TYPE_MISMATCH
    jmp  error

; ---- shared pieces -------------------------------------------------------------

; Reads the name of a variable / list that is being DEFINED: validates it, applies
; the reserved "__" rule and the redeclaration check, and fills vd_name / vd_len.
read_new_name:
    call skip_blanks
    call read_ident
    test rcx, rcx
    jz   .syntax
    movzx eax, byte [rdi]
    sub  eax, '0'
    cmp  eax, 9
    jbe  .syntax                ; a name can't start with a digit
    cmp  rcx, 255
    ja   .too_long
    cmp  byte [is_ns], 0
    jne  .name_ok               ; .ns files may define reserved names
    cmp  rcx, 2
    jb   .name_ok
    cmp  word [rdi], '__'       ; reserved prefix
    je   .reserved
.name_ok:
    mov  [vd_name], rdi
    mov  [vd_len], rcx
    call find_var
    test rax, rax
    jnz  .redeclared
    ret
.syntax:
    mov  bx, ERR_INVALID_VAR_SYNTAX
    jmp  error
.too_long:
    mov  bx, ERR_NAME_TOO_LONG
    jmp  error
.reserved:
    mov  bx, ERR_RESERVED_NAME
    jmp  error
.redeclared:
    mov  bx, ERR_REDECLARED
    jmp  error

; Only a comment (or nothing) may follow on the line.
expect_end:
    call skip_blanks
    cmp  rsi, r12
    jae  .ok
    mov  al, [rsi]
    cmp  al, 0x0A
    je   .ok
    cmp  al, 0x0D
    je   .ok
    cmp  al, '#'
    je   .ok
    mov  bx, ERR_INVALID_VAR_SYNTAX
    jmp  error
.ok:
    ret

is_ident_start:                 ; in: AL   out: EAX = 1 for a letter or '_'
    cmp  al, '_'
    je   .yes
    or   al, 0x20
    cmp  al, 'a'
    jb   .no
    cmp  al, 'z'
    jbe  .yes
.no:
    xor  eax, eax
    ret
.yes:
    mov  eax, 1
    ret

; in: RDI = token, RCX = length   out: EAX = 1 and RCX -= 7 if it ends in ".length"
strip_length:
    cmp  rcx, 8                 ; at least one name character + ".length"
    jb   .no
    lea  rdx, [rdi + rcx - 7]
    cmp  dword [rdx], '.len'
    jne  .no
    cmp  word [rdx + 4], 'gt'
    jne  .no
    cmp  byte [rdx + 6], 'h'
    jne  .no
    sub  rcx, 7
    mov  eax, 1
    ret
.no:
    xor  eax, eax
    ret

; vd_lit_ptr / vd_lit_len -> RAX: up to 8 characters packed little-endian
pack_str_lit:
    mov  rcx, [vd_lit_len]
    cmp  rcx, 8
    ja   .long
    mov  rdx, [vd_lit_ptr]
    xor  eax, eax
.pack:
    test rcx, rcx
    jz   .done
    dec  rcx
    shl  rax, 8
    movzx r8d, byte [rdx + rcx]
    or   rax, r8
    jmp  .pack
.done:
    ret
.long:
    mov  bx, ERR_STR_TOO_LONG
    jmp  error

; ---- operands, values and lists -------------------------------------------------

; One operand -> opd_*: a number, a 'string', or the name of a variable.
; in: [opd_want] = the type it must have (0 num, 1 str)
parse_operand:
    call skip_blanks
    cmp  rsi, r12
    jae  .syntax
    mov  al, [rsi]
    cmp  al, "'"
    je   .str
    cmp  al, '"'
    je   .str
    cmp  al, '-'
    je   .num
    mov  cl, al
    sub  cl, '0'
    cmp  cl, 9
    jbe  .num
    call is_ident_start
    test eax, eax
    jz   .syntax
    call read_ident
    call find_var
    test rax, rax
    jz   .unknown
    movzx eax, byte [rax + 1]
    and  eax, VAR_TYPE_MASK
    cmp  al, [opd_want]
    jne  .mismatch              ; also rejects lstr and lists
    mov  [opd_name], rdi
    mov  [opd_len], rcx
    mov  byte [opd_kind], 1
    ret
.num:
    cmp  byte [opd_want], 0
    jne  .mismatch
    call parse_number
    mov  [opd_imm], rax
    mov  byte [opd_kind], 0
    ret
.str:
    cmp  byte [opd_want], 1
    jne  .mismatch
    call parse_string_lit
    call pack_str_lit
    mov  [opd_imm], rax
    mov  byte [opd_kind], 0
    ret
.syntax:
    mov  bx, ERR_INVALID_VAR_SYNTAX
    jmp  error
.unknown:
    mov  bx, ERR_UNKNOWN_VAR
    jmp  error
.mismatch:
    mov  bx, ERR_TYPE_MISMATCH
    jmp  error

; '[' number-or-variable ']'   -> opd_*
parse_index:
    cmp  rsi, r12
    jae  .syntax
    cmp  byte [rsi], '['
    jne  .syntax
    inc  rsi
    mov  byte [opd_want], 0
    call parse_operand
    call skip_blanks
    cmp  rsi, r12
    jae  .syntax
    cmp  byte [rsi], ']'
    jne  .syntax
    inc  rsi
    ret
.syntax:
    mov  bx, ERR_INVALID_VAR_SYNTAX
    jmp  error

; A value on the right of 'var x =':
;   other_var | s.length | s[#] | list.x.length | list.x[#]
; out: AL = type of the value (0 num, 1 str); expr_* (and opd_* for an index) filled
parse_value_expr:
    call read_ident             ; RDI = token, RCX = length
    cmp  rcx, 6
    jb   .plain
    cmp  dword [rdi], 'list'
    jne  .plain
    cmp  byte [rdi + 4], '.'
    jne  .plain
    add  rdi, 5                 ; --- list.NAME.length / list.NAME[#]
    sub  rcx, 5
    call strip_length
    mov  [expr_kind], al        ; 1 = had ".length" (replaced by the EX_ code below)
    mov  [expr_name], rdi
    mov  [expr_len], rcx
    call find_var
    test rax, rax
    jz   .unknown
    movzx eax, byte [rax + 1]
    and  eax, VAR_TYPE_MASK
    cmp  eax, 3
    jb   .not_list
    cmp  eax, 4
    ja   .not_list
    cmp  byte [expr_kind], 1
    je   .list_len
    sub  eax, 3                 ; element type: list num -> num, list str -> str
    mov  [expr_type], al
    mov  byte [expr_kind], EX_LIST_IDX
    call parse_index
    mov  al, [expr_type]
    ret
.list_len:
    mov  byte [expr_kind], EX_LIST_LEN
    xor  eax, eax
    ret

.plain:                         ; --- NAME.length / NAME[#] / NAME
    call strip_length
    mov  [expr_kind], al
    mov  [expr_name], rdi
    mov  [expr_len], rcx
    call find_var
    test rax, rax
    jz   .unknown
    movzx eax, byte [rax + 1]
    and  eax, VAR_TYPE_MASK
    cmp  byte [expr_kind], 1
    je   .str_len
    cmp  rsi, r12
    jae  .copy
    cmp  byte [rsi], '['
    je   .str_idx
.copy:
    cmp  eax, 1
    ja   .mismatch              ; only num and str can be copied
    mov  [expr_type], al
    mov  byte [expr_kind], EX_COPY
    ret
.str_len:
    cmp  eax, 1
    je   .is_str_len
    cmp  eax, 2
    jne  .not_string
    mov  byte [expr_kind], EX_LSTR_LEN
    jmp  .len_done
.is_str_len:
    mov  byte [expr_kind], EX_STR_LEN
.len_done:
    xor  eax, eax
    ret
.str_idx:
    cmp  eax, 1
    je   .is_str_idx
    cmp  eax, 2
    jne  .not_string
    mov  byte [expr_kind], EX_LSTR_IDX
    jmp  .idx_done
.is_str_idx:
    mov  byte [expr_kind], EX_STR_IDX
.idx_done:
    call parse_index
    mov  eax, 1                 ; a character is a str
    ret
.unknown:
    mov  bx, ERR_UNKNOWN_VAR
    jmp  error
.not_list:
    mov  bx, ERR_NOT_A_LIST
    jmp  error
.not_string:
    mov  bx, ERR_NOT_A_STRING
    jmp  error
.mismatch:
    mov  bx, ERR_TYPE_MISMATCH
    jmp  error

; list  num|str  name                                   (RSI is just past 'list')
parse_list_decl:
    call skip_blanks
    call read_ident
    cmp  rcx, 3
    jne  .bad_type
    cmp  word [rdi], 'nu'
    jne  .try_str
    cmp  byte [rdi + 2], 'm'
    jne  .bad_type
    mov  byte [vd_type], 3
    jmp  .got_type
.try_str:
    cmp  word [rdi], 'st'
    jne  .bad_type
    cmp  byte [rdi + 2], 'r'
    jne  .bad_type
    mov  byte [vd_type], 4
.got_type:
    call read_new_name
    mov  byte [vd_temp], 0
    mov  byte [vd_has_init], 0
    mov  byte [vd_init_kind], 0
    mov  qword [vd_value], 0
    call expect_end
    call add_var
    jmp  write_list_decl        ; tail call
.bad_type:                      ; includes 'lstr': lists hold numbers or short strings
    mov  bx, ERR_BAD_VAR_TYPE
    jmp  error

; list.NAME.append v | .insert #, v | .remove # | .clear | .sort
; in: RDI = the token "list.NAME.METHOD", RCX = its length; RSI just past it
; (.length and list.NAME[#] produce values, so they are only legal in an initialiser)
parse_list_op:
    lea  r8, [rdi + rcx]
.back:                          ; the method is whatever follows the last '.'
    dec  r8
    cmp  byte [r8], '.'
    jne  .back
    lea  r9, [rdi + 5]          ; start of NAME
    cmp  r8, r9
    jbe  .syntax                ; no name, or no method ("list.x")
    mov  [ls_name], r9
    mov  rax, r8
    sub  rax, r9
    mov  [ls_len], rax
    lea  r10, [rdi + rcx]
    inc  r8                     ; R8 = method, R10 = its length
    sub  r10, r8
    cmp  r10, 6
    jne  .len5
    cmp  dword [r8], 'appe'
    jne  .m_insert
    cmp  word [r8 + 4], 'nd'
    jne  .syntax
    mov  byte [ls_op], LS_APPEND
    jmp  .lookup
.m_insert:
    cmp  dword [r8], 'inse'
    jne  .m_remove
    cmp  word [r8 + 4], 'rt'
    jne  .syntax
    mov  byte [ls_op], LS_INSERT
    jmp  .lookup
.m_remove:
    cmp  dword [r8], 'remo'
    jne  .syntax
    cmp  word [r8 + 4], 've'
    jne  .syntax
    mov  byte [ls_op], LS_REMOVE
    jmp  .lookup
.len5:
    cmp  r10, 5
    jne  .len4
    cmp  dword [r8], 'clea'
    jne  .syntax
    cmp  byte [r8 + 4], 'r'
    jne  .syntax
    mov  byte [ls_op], LS_CLEAR
    jmp  .lookup
.len4:
    cmp  r10, 4
    jne  .syntax
    cmp  dword [r8], 'sort'
    jne  .syntax
    mov  byte [ls_op], LS_SORT
.lookup:
    mov  rdi, [ls_name]
    mov  rcx, [ls_len]
    call find_var
    test rax, rax
    jz   .unknown
    movzx eax, byte [rax + 1]
    and  eax, VAR_TYPE_MASK
    cmp  eax, 3
    jb   .not_list
    cmp  eax, 4
    ja   .not_list
    mov  [ls_type], al
    sub  al, 3                  ; element type for the operands
    mov  cl, [ls_op]
    cmp  cl, LS_APPEND
    je   .append
    cmp  cl, LS_INSERT
    je   .insert
    cmp  cl, LS_REMOVE
    je   .remove
    jmp  .done                  ; clear / sort take no operands
.append:
    mov  [opd_want], al
    call parse_operand
    call write_load_val
    jmp  .done
.insert:
    mov  [expr_type], al        ; (scratch) element type, kept across the index operand
    mov  byte [opd_want], 0
    call parse_operand
    call write_load_idx
    call skip_blanks
    cmp  rsi, r12
    jae  .syntax
    cmp  byte [rsi], ','
    jne  .syntax
    inc  rsi
    mov  al, [expr_type]
    mov  [opd_want], al
    call parse_operand
    call write_load_val
    jmp  .done
.remove:
    mov  byte [opd_want], 0
    call parse_operand
    call write_load_idx
.done:
    call expect_end
    jmp  write_list_op          ; tail call
.syntax:
    mov  bx, ERR_INVALID_VAR_SYNTAX
    jmp  error
.unknown:
    mov  bx, ERR_UNKNOWN_VAR
    jmp  error
.not_list:
    mov  bx, ERR_NOT_A_LIST
    jmp  error

; Appends the vd_* declaration to var_table.
; (An lstr is entered with an empty payload: the table only needs its name/type.)
add_var:
    xor  ecx, ecx               ; length 0 never matches, so find_var walks to the end
    call find_var               ; ... and leaves RDX = end of the last record
    movzx eax, byte [r15]
    cmp  eax, 255
    jae  .full
    mov  r8, [vd_len]
    lea  r9, [rdx + r8 + 10]
    lea  rax, [r15 + VAR_TABLE_SIZE]
    cmp  r9, rax
    ja   .full
    mov  [rdx], r8b
    movzx eax, byte [vd_type]
    cmp  byte [vd_temp], 0
    je   .typed
    or   al, VAR_TEMP
.typed:
    mov  [rdx + 1], al
    mov  r9, [vd_name]
    xor  r10d, r10d
.nc:
    mov  r11b, [r9 + r10]
    mov  [rdx + 2 + r10], r11b
    inc  r10
    cmp  r10, r8
    jb   .nc
    lea  rdx, [rdx + 2 + r8]
    xor  eax, eax
    cmp  byte [vd_type], 2
    je   .val
    mov  rax, [vd_value]
.val:
    mov  [rdx], rax
    inc  byte [r15]
    ret
.full:
    mov  bx, ERR_TABLE_FULL
    jmp  error

; Removes every temporary variable (type bit 7) from the table and compacts the
; survivors downward, so sticky variables keep their order and values.
; in: R15 = var_table   clobbers RAX, RCX, RDX, R8-R11 (NOT rsi/rdi, compile uses them)
purge_tvars:
    movzx r8d, byte [r15]       ; records left to scan
    lea  rdx, [r15 + 1]         ; read cursor
    mov  r9, rdx                ; write cursor
.next:
    test r8d, r8d
    jz   .done
    movzx ecx, byte [rdx]       ; name length
    add  ecx, 2                 ; + len/type bytes
    movzx r10d, byte [rdx + 1]  ; type byte (keeps the temp flag)
    mov  r11d, r10d
    and  r11d, VAR_TYPE_MASK
    lea  rax, [rdx + rcx]       ; -> value
    add  rcx, 8                 ; every value starts with 8 bytes
    cmp  r11d, 2
    jne  .sized
    mov  r11, [rax]             ; lstring: big-endian payload length
    bswap r11
    add  rcx, r11
.sized:                         ; rcx = whole record size
    test r10b, VAR_TEMP
    jnz  .drop
    cmp  r9, rdx
    je   .advance               ; nothing dropped yet, already in place
    xor  eax, eax
.copy:                          ; forward copy is safe: dest is always below source
    mov  r11b, [rdx + rax]
    mov  [r9 + rax], r11b
    inc  rax
    cmp  rax, rcx
    jb   .copy
.advance:
    add  r9, rcx
    add  rdx, rcx
    dec  r8d
    jmp  .next
.drop:
    add  rdx, rcx
    dec  byte [r15]             ; one fewer variable
    dec  r8d
    jmp  .next
.done:
    ret

; Hands the finished statement to the writer. Not called yet (TODO: call it when
; a statement ends). Fixed vs. the old inline version: it is a real routine now
; (ends in `ret`; the old block fell off the end into whatever came next), the
; 15 pushes + 32 shadow bytes keep rsp aligned for the call, and the undefined
; labels are gone.
write_current_func:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    sub  rsp, 32
    cmp  r14d, FN_VAR
    je   .var
    cmp  r14d, FN_TVAR          ; same record format; the writer sets VAR_TEMP on the type byte
    je   .var
    call write_func
    jmp  .restore
.var:
    call write_var
.restore:
    add  rsp, 32
    pop  r15
    pop  r14
    pop  r13
    pop  r12
    pop  r11
    pop  r10
    pop  r9
    pop  r8
    pop  rbp
    pop  rdi
    pop  rsi
    pop  rdx
    pop  rcx
    pop  rbx
    pop  rax
    ret

section .text
; Was `section .data / nlang_writer db '...' / %include nlang_writer`, which is
; invalid (%include needs a quoted path and must be at file level).
%include "nlang_writer.nasm"
