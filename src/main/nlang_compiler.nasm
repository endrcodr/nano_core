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

; ---- variable type byte -----------------------------------------------------
VAR_TEMP      equ 0x80          ; bit 7 set = temporary (tvar), removed by purge_tvars
VAR_TYPE_MASK equ 0x7F          ; low bits: 0 = num, 1 = str, 2 = lstr

; ---- comment state kept in R13 ----------------------------------------------
CMT_NONE  equ 0
CMT_LINE  equ 1                 ; '#'   -> until end of line
CMT_BLOCK equ 2                 ; '###' -> until the next '###'

; ---- error codes (loaded into BX before `jmp error`) ------------------------
ERR_INVALID_VAR_SYNTAX equ 5    ; 'var' not followed by a space
ERR_UNTERMINATED_CMT   equ 6    ; '###' never closed
ERR_NAME_TOO_LONG      equ 7    ; identifier longer than 255 (length is stored in 1 byte)

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
    var_table resb VAR_TABLE_SIZE

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
    KW "while",  FN_WHILE
    KW "until",  FN_UNTIL
    KW "for",    FN_FOR
    KW "bool",   FN_BOOL
    KW "def",    FN_DEF
    KW "import", FN_IMPORT
    db 0
; "mem." and "fs." families are matched by prefix in match_keyword.

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
    je   .need_space
    cmp  eax, FN_TVAR
    jne  .func_logic
.need_space:
    cmp  byte [rsi], ' '        ; 'var' / 'tvar' must be followed by a space
    jne  .err_invalid_var
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
    call purge_tvars            ; temporaries die with the script
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
