; nlang_compiler.nasm - front end of the Nano compiler.
; Included by nlang_main.nasm AFTER nlang_opener.nasm (needs `buffer` and `bytes_read`).
;
; Calling convention: compile takes no args, returns EAX = 0 on success, and
; preserves the Windows non-volatile registers. Compile errors jump to `error`,
; which exits the process with code 0x100 + BX.
bits 64
default rel

extern ExitProcess
extern GetStdHandle
extern WriteFile

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
FN_ASSIGN   equ 17              ; x = expr / x += expr / x -= expr / name(args)
FN_RET      equ 18              ; ret [value]
FN_MAX      equ 64              ; functions per program
FN_SIZE     equ 160             ; bytes per function record (see "functions" below)
MAX_PARAMS  equ 8
CA_MAX      equ 128             ; text (lstr) arguments in the whole program
BIN_BYTES   equ 4096            ; bytes of bits a bin can hold (BIN_BYTES in the generated code)
BIN_BITS    equ 32768
LSTR_MAX    equ 4096            ; bytes of text an lstr can hold (LSTR_CAP in the generated code)

; ---- open blocks (if / elif / else / while / until / for, and def which is not compiled yet) ----
BLK_MAX    equ 32               ; nesting depth
BLK_SIZE   equ 40               ; bytes per entry of blk_stack (layout: see "blocks" below)
BODY_UNSET equ 0xFFFFFFFF       ; the first line of a block's body has not been seen yet
BK_IF      equ 1                ; in an if / elif branch (an elif / else may follow)
BK_ELSE    equ 2                ; in an else branch
BK_OPAQUE  equ 3                ; def body (compiled later)
BK_LOOP    equ 4                ; while / until body
BK_FOR     equ 5                ; for body
BK_DEF     equ 6                ; def body

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
EX_BIN_LEN  equ 8               ; b.length (bits)
EX_BIN_IDX  equ 9               ; b[#]     (bit number # counted from the least significant end)

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
ERR_INVALID_VAR_SYNTAX equ 5    ; malformed var / tvar / list / if / elif / else statement
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
ERR_UTF16              equ 20   ; input file is UTF-16 (BOM FF FE / FE FF)
ERR_EXPECT_COLON       equ 21   ; if / elif / else line does not end with ':'
ERR_ELSE_NO_IF         equ 22   ; elif / else with no open if at the same indentation
ERR_BAD_INDENT         equ 23   ; indentation matches no open block
ERR_BAD_COMPARE        equ 24   ; strings can only be compared with == and !=
ERR_TOO_DEEP           equ 25   ; more than BLK_MAX blocks nested
ERR_LSTR_TOO_BIG       equ 26   ; text longer than LSTR_MAX
ERR_DEF_NESTED         equ 27   ; def inside a block
ERR_RET_TYPE           equ 28   ; value of a function used before its type is known
ERR_ARG_COUNT          equ 29   ; wrong number of arguments
ERR_RET_OUTSIDE        equ 30   ; ret outside a def
ERR_BIN_TOO_BIG        equ 31   ; bin literal longer than BIN_BITS
ERR_BIN_LOCAL          equ 32   ; bin variable inside a def
ERR_COUNT              equ 28   ; number of messages in err_msgs (codes 5..30)

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

    ; Messages to the console.
    err_code    resd 1              ; 0x100 + ERR_*
    mb_len      resd 1              ; bytes used in msg_buf
    pt_ptr      resq 1
    pt_len      resq 1
    pt_written  resq 1
    pd_buf      resb 32
    hx_buf      resb 8
    msg_buf     resb 1024
    stmt_count  resd 1              ; statements seen (a statement starts with a keyword)
    skip_count  resd 1              ; ... of which not compiled yet
    ns_flag     resb 1
    resb 3

    ; Blocks (if / elif / else) and indentation.
    blk_depth   resd 1              ; open blocks
    chain_ctr   resd 1              ; if-chains started so far: their number is used in the labels
    cur_indent  resd 1              ; indentation of the line being compiled
    bl_w        resd 1              ; indentation of the statement being started
    bl_kw       resd 1              ; its FN_* keyword (0 = not a keyword)
    bl_cont     resd 1              ; 1 = this elif / else continues the open if-chain
    cb_chain    resd 1              ; chain / branch numbers that the writer prints in labels
    cb_k        resd 1
    bl_first    resb 1              ; 1 = the statement is the first thing on its line
    cond_op     resb 1              ; comparison: 1 ==, 2 !=, 3 <, 4 >, 5 <=, 6 >=
    cmp_ltype   resb 1              ; type of the left operand: 0 num, 1 str
    cmp_tmp     resb 1
    cond_neg    resb 1              ; 1 = jump when the condition is TRUE (until)
    resb 7
    fo_name     resq 1              ; loop variable of a for
    fo_len      resq 1
    as_name     resq 1              ; assignment target: name in the source, length
    as_len      resq 1
    st_name     resq 1              ; where the writer stores a value: name, length, type of the variable
    st_len      resq 1
    ex_start    resq 1              ; start of the expression being parsed (to parse it again)
    lit_ctr     resd 1              ; long string literals emitted so far (lit_<n>)
    as_kind     resb 1              ; 0 '=', 1 '+=', 2 '-='
    st_type     resb 1
    ex_type     resb 1              ; type of the expression: 0 num, 1 str, 2 lstr
    ex_cur      resb 1              ; type of the value so far
    ex_sb       resb 1              ; 1 = the value so far is in the text builder
    ex_plus     resb 1              ; the operator being parsed is '+' (otherwise ',')
    ex_space    resb 1              ; ', ' joins with a space
    ex_pure     resb 1              ; a ',' started from a number: the right side has to be text
    ex_hint     resb 1              ; 1 = the next parse_expr reads 0x... literals as bits (set by the caller)
    ex_binctx   resb 1              ; ... and while the value so far is a bin
    ex_bin      resb 1              ; 1 = the value so far is in rt_bacc (a bit operation was done)
    ex_op       resb 1              ; the bit operation being parsed
    bin_bits    resq 1              ; a bin literal being built: its length
    bin_buf     resb BIN_BYTES + 8  ; ... and its bits
    ex_noc      resb 1              ; 1 = inside call arguments: a ',' ends the expression (it separates arguments)
    scope_cnt   resb 1              ; number of variables when the current def began
    w_rt        resb 1
    resb 5
    fv_hit      resq 1
    scope_lo    resq 1              ; variables at or above this address belong to the def being compiled (0 = none)
    cur_fn      resq 1              ; record of the def being compiled (0 = top level)
    call_fn     resq 1              ; the function a call refers to
    w_fn        resq 1              ; writer: the function being called
    cur_fn_id   resd 1
    fn_ids      resd 1              ; functions seen so far: their number is used in the labels
    fn_count    resd 1
    call_ctr    resd 1              ; call sites so far
    w_id        resd 1
    w_site      resd 1
    w_idx       resd 1
    w_ci        resd 1
    ca_n        resd 1
    resd 1
    fn_table    resb FN_MAX * FN_SIZE
    ca_tab      resd CA_MAX
    cmp_imm     resq 1              ; literal operand
    tk_ptr      resq 1              ; the token being looked at (saved across calls that clobber RDI / RCX)
    tk_len      resq 1
    blk_stack   resb BLK_MAX * BLK_SIZE

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
    KW "ret",    FN_RET
    KW "import", FN_IMPORT
    db 0
; "mem." and "fs." families are matched by prefix in match_keyword.

zero_char: db '0'               ; default value of an uninitialised str / lstr

; STR name, text  ->  name: db text   /   name_len equ <length>      (also used by the writer)
%macro STR 2
%1:      db %2
%1_len   equ $ - %1
%endmacro

; one length-prefixed message per error code, in code order (5, 6, 7, ...)
%macro MSG 1
    db %%end - %%start
%%start: db %1
%%end:
%endmacro
err_msgs:
    MSG "malformed var / tvar / list / if / elif / else / while / until / for statement" ; 5
    MSG "block comment '###' is never closed"                   ; 6
    MSG "name is longer than 255 characters"                    ; 7
    MSG "unknown type (use num, str or lstr; lists: num or str)" ; 8
    MSG "a str holds at most 8 characters (use lstr)"           ; 9
    MSG "string is not closed on its line"                      ; 10
    MSG "name is already declared"                              ; 11
    MSG "too many variables"                                    ; 12
    MSG "generated output is too large"                         ; 13
    MSG "could not write the output file"                       ; 14
    MSG "names starting with __ are reserved for .ns files"     ; 15
    MSG "value has the wrong type here"                         ; 16
    MSG "unknown name"                                          ; 17
    MSG "that name is not a list"                               ; 18
    MSG "that name is not a str / lstr"                         ; 19
    MSG "file is UTF-16: save it as UTF-8 or ANSI"              ; 20
    MSG "expected ':' at the end of the line (conditions can't be joined: use bool)" ; 21
    MSG "elif / else without a matching if"                     ; 22
    MSG "indentation does not match any open block"             ; 23
    MSG "strings can only be compared with == and !="           ; 24
    MSG "blocks are nested too deeply (32 levels at most)"      ; 25
    MSG "text is longer than 4096 bytes (the lstr limit)"       ; 26
    MSG "def is only allowed at the top level (not inside a block)" ; 27
    MSG "the return type is not known yet: put a ret with a value first, or write it in the header: def f (num n) num:" ; 28
    MSG "wrong number of arguments"                             ; 29
    MSG "ret outside of a def"                                  ; 30
    MSG "binary literal is longer than 32768 bits"              ; 31
    MSG "bin variables can only be declared outside a def (they can still be used inside one)" ; 32

STR s_msg_err,  "nlang: error 0x"
STR s_msg_line, " (line "
STR s_msg_end,  "): "
STR s_msg_nl,   `\n`
STR s_msg_wrote, "nlang: wrote "
STR s_msg_comp,  "nlang: compiling "
STR s_msg_open,  " ("
STR s_msg_bytes, " bytes"
STR s_msg_pkg,   ", package file"
STR s_msg_close, `)\n`
STR s_msg_done,  "nlang: done - "
STR s_msg_stmts, " statements"
STR s_msg_skipd, " not compiled yet)"
STR s_msg_names, " names declared"
STR s_msg_comma, ", "
STR s_msg_ind,   "  ["
STR s_msg_rb,    "] "
STR s_msg_todo,  "   (not compiled yet)"
hex_digits: db "0123456789abcdef"

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
; var bin @@@ [= *] - Defines a binary variable: a string of bits (up to 32768) used directly as bits, not as text. Literals are 0b1010 (binary) and 0xF0 (4 bits per hex digit); x.length is the number of bits, x[#] is bit # (0 = least significant) as a num.
; @ and @ / @ or @ / @ xor @ - Bitwise operations between bins; the shorter bin is padded with zeros on the left. Put 'not' before the operator to invert the result (nand, nor, xnor): a not and b. 'not a' flips every bit. Operations run left to right.
; bin(n) / num(b) - Convert a num to a 64-bit bin / the lowest 64 bits of a bin to a num. == and != compare bins. In a text join a bin shows as 0b....
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
    mov  dword [blk_depth], 0
    mov  dword [chain_ctr], 0
    mov  dword [cur_indent], 0
    call detect_ns              ; package names are only legal in .ns files
    cmp  qword [bytes_read], 2  ; a UTF-16 file (BOM FF FE or FE FF) would be read as garbage
    jb   .not_utf16
    movzx eax, word [rsi]
    cmp  ax, 0xFEFF
    je   .utf16
    cmp  ax, 0xFFFE
    jne  .not_utf16
.utf16:
    mov  bx, ERR_UTF16
    jmp  error
.not_utf16:
    mov  rcx, rsi               ; UTF-16 without a BOM: source text never contains a NUL byte
.nul_scan:
    cmp  rcx, r12
    jae  .text_ok
    cmp  byte [rcx], 0
    je   .utf16
    inc  rcx
    jmp  .nul_scan
.text_ok:
    call print_start            ; "nlang: compiling <file> (N bytes)"
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

    ; A statement may start here: find out how far it is indented and which block it belongs to.
    mov  [tk_ptr], rdi
    mov  [tk_len], rcx
    call match_keyword
    mov  [bl_kw], eax
    call line_indent            ; EAX = indentation, or -1 when something else precedes it on the line
    cmp  eax, -1
    je   .not_first
    mov  [bl_w], eax
    mov  [cur_indent], eax
    mov  byte [bl_first], 1
    call blocks_line_start      ; ends finished blocks (emitting their labels); EAX = 1: continues an if-chain
    mov  [bl_cont], eax
    jmp  .indent_done
.not_first:
    mov  eax, [cur_indent]
    mov  [bl_w], eax
    mov  byte [bl_first], 0
    mov  dword [bl_cont], 0
    mov  eax, [bl_kw]           ; if / elif / else only start a statement at the beginning of a line
    cmp  eax, FN_IF
    je   .not_a_stmt
    cmp  eax, FN_ELIF
    je   .not_a_stmt
    cmp  eax, FN_ELSE
    jne  .indent_done
.not_a_stmt:
    mov  dword [bl_kw], 0
.indent_done:
    mov  rdi, [tk_ptr]
    mov  rcx, [tk_len]
    mov  eax, [bl_kw]
    test eax, eax
    jz   .as_variable
    mov  r14d, eax
    call note_stmt              ; count it (and show it with -v)
    mov  eax, r14d
    cmp  eax, FN_VAR
    je   .decl
    cmp  eax, FN_TVAR
    je   .decl
    cmp  eax, FN_LISTDECL
    je   .decl
    cmp  eax, FN_LISTOP
    je   .list_op
    cmp  eax, FN_IF
    je   .if_stmt
    cmp  eax, FN_ELIF
    je   .elif_stmt
    cmp  eax, FN_ELSE
    je   .else_stmt
    cmp  byte [bl_first], 0     ; loops / def only start a statement at the beginning of a line
    je   .func_logic
    cmp  eax, FN_WHILE
    je   .while_stmt
    cmp  eax, FN_UNTIL
    je   .until_stmt
    cmp  eax, FN_FOR
    je   .for_stmt
    cmp  eax, FN_DEF
    je   .def_stmt
    cmp  eax, FN_RET
    je   .ret_stmt
    jmp  .func_logic
.opaque:
    mov  dword [cb_chain], 0
    mov  dword [cb_k], 0
    mov  al, BK_OPAQUE
    call push_frame
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

; ---- if / elif / else ---------------------------------------------------------
; Generated code for   if A == B: ... elif C > D: ... else: ...   (n = chain number):
;       <A into rax> mov rbx, rax / <B into rax> / cmp rbx, rax / jne if_n_1
;       ...if body...        jmp if_n_end
;   if_n_1:  <C> ... / <D> ... / cmp rbx, rax / jle if_n_2
;       ...elif body...      jmp if_n_end
;   if_n_2:  ...else body...
;   if_n_end:
.if_stmt:
    inc  dword [chain_ctr]
    mov  eax, [chain_ctr]
    mov  [cb_chain], eax
    mov  dword [cb_k], 1
    call write_comment_if
    call parse_condition
    call expect_colon_end
    mov  al, BK_IF
    call push_frame
    jmp  .stmt_done
.elif_stmt:
    cmp  dword [bl_cont], 1
    jne  .err_else_no_if
    call top_frame
    mov  eax, [r8 + 8]
    mov  [cb_chain], eax
    mov  eax, [r8 + 12]
    mov  [cb_k], eax
    call write_jmp_end          ; the branch that just ended jumps over the rest of the chain
    call write_label_next       ; ... and a failed condition lands here
    inc  dword [cb_k]
    call write_comment_elif
    call parse_condition
    call expect_colon_end
    call top_frame
    mov  eax, [cb_k]
    mov  [r8 + 12], eax
    mov  dword [r8 + 4], BODY_UNSET
    jmp  .stmt_done
.else_stmt:
    cmp  dword [bl_cont], 1
    jne  .err_else_no_if
    call top_frame
    mov  eax, [r8 + 8]
    mov  [cb_chain], eax
    mov  eax, [r8 + 12]
    mov  [cb_k], eax
    call write_jmp_end
    call write_label_next
    call write_comment_else
    call expect_colon_end
    call top_frame
    mov  byte [r8 + 16], BK_ELSE
    mov  dword [r8 + 4], BODY_UNSET
    jmp  .stmt_done
.err_else_no_if:
    mov  bx, ERR_ELSE_NO_IF
    jmp  error

; ---- while / until / for -------------------------------------------------------------
; while A < B:            until A < B:               for i = N:
;   lp_n_top:               lp_n_top:                  <N into rax>  mov [lp_n_tgt], rax   (N is evaluated once)
;     <cond>, jump to         <cond>, jump to        lp_n_top:
;     if_n_1 when FALSE       if_n_1 when TRUE         cmp [v_i], [lp_n_tgt] / je if_n_1
;     ...body...              ...body...               ...body...
;     jmp lp_n_top            jmp lp_n_top             i moves one step toward N (+1 or -1), jmp lp_n_top
;   if_n_1:                 if_n_1:                  if_n_1:
.while_stmt:
    mov  byte [cond_neg], 0
    jmp  .loop_common
.until_stmt:
    mov  byte [cond_neg], 1
.loop_common:
    inc  dword [chain_ctr]
    mov  eax, [chain_ctr]
    mov  [cb_chain], eax
    mov  dword [cb_k], 1
    mov  eax, r14d
    call write_comment_loop     ; "; while" / "; until", then  lp_n_top:
    call write_loop_top
    call parse_condition
    call expect_colon_end
    mov  al, BK_LOOP
    call push_frame
    jmp  .stmt_done
.for_stmt:
    inc  dword [chain_ctr]
    mov  eax, [chain_ctr]
    mov  [cb_chain], eax
    mov  dword [cb_k], 1
    call skip_blanks
    cmp  rsi, r12
    jae  .err_invalid_var
    call read_ident             ; the loop variable: a declared num
    test rcx, rcx
    jz   .err_invalid_var
    mov  [fo_name], rdi
    mov  [fo_len], rcx
    call find_var
    test rax, rax
    jz   .err_unknown_name
    movzx eax, byte [rax + 1]
    and  eax, VAR_TYPE_MASK
    jnz  .err_wrong_type
    call skip_blanks
    cmp  rsi, r12
    jae  .err_invalid_var
    cmp  byte [rsi], '='
    jne  .err_invalid_var
    inc  rsi
    call write_comment_for
    call write_for_decl
    call parse_cmp_operand      ; the target: a number, a num variable, s.length ...
    test al, al
    jnz  .err_wrong_type
    call write_for_head
    call expect_colon_end
    mov  al, BK_FOR
    call push_frame
    jmp  .stmt_done
.err_unknown_name:
    mov  bx, ERR_UNKNOWN_VAR
    jmp  error

; ---- def / ret ----------------------------------------------------------------------
.def_stmt:
    cmp  dword [blk_depth], 0
    jne  .err_def_nested
    call parse_def_header
    call expect_colon_end
    mov  eax, [cur_fn_id]
    mov  [cb_chain], eax
    mov  dword [cb_k], 0
    mov  al, BK_DEF
    call push_frame
    jmp  .stmt_done
.err_def_nested:
    mov  bx, ERR_DEF_NESTED
    jmp  error
.ret_stmt:
    cmp  qword [cur_fn], 0
    je   .err_ret_outside
    call skip_blanks
    cmp  rsi, r12
    jae  .ret_bare
    mov  al, [rsi]
    cmp  al, 0x0A
    je   .ret_bare
    cmp  al, 0x0D
    je   .ret_bare
    cmp  al, '#'
    je   .ret_bare
    call parse_expr
    mov  [ex_type], al
    cmp  al, 3
    je   .err_wrong_type        ; (functions don't return a bin yet)
    call expect_end
    mov  r8, [cur_fn]
    movzx eax, byte [r8 + 21]
    cmp  eax, 2                 ; a function that returns an lstr takes a str too
    jne  .ret_nw
    cmp  byte [ex_type], 1
    jne  .ret_nw
    call write_str_to_sb
    mov  byte [ex_type], 2
    mov  r8, [cur_fn]
    movzx eax, byte [r8 + 21]
.ret_nw:
    cmp  eax, 0xFF
    jne  .ret_chk
    mov  al, [ex_type]
    mov  [r8 + 21], al          ; the first ret decides the type of the function
    jmp  .ret_emit
.ret_chk:
    cmp  al, [ex_type]
    jne  .err_wrong_type
.ret_emit:
    movzx eax, byte [ex_type]
    call write_ret_value
    jmp  .stmt_done
.ret_bare:
    mov  r8, [cur_fn]
    movzx eax, byte [r8 + 21]
    cmp  eax, 0xFF
    jne  .rb1
    mov  byte [r8 + 21], 0xFE   ; no value
    jmp  .rb2
.rb1:
    cmp  eax, 0xFE
    jne  .err_wrong_type
.rb2:
    call expect_end
    call write_ret_void
    jmp  .stmt_done
.err_ret_outside:
    mov  bx, ERR_RET_OUTSIDE
    jmp  error

; ---- a call as a statement: name(args) ---------------------------------------------
.call_stmt:
    mov  rdi, [as_name]
    mov  rcx, [as_len]
    call fn_find
    test rax, rax
    jz   .err_unknown_name      ; name( ... ) and no such function
    mov  [call_fn], rax
    inc  rsi                    ; past '('
    mov  r14d, FN_ASSIGN
    mov  rdi, [as_name]
    mov  rcx, [as_len]
    call note_stmt
    mov  al, 1                  ; a call with no value is fine here
    call parse_call
    call expect_end
    jmp  .stmt_done
.err_wrong_type:
    mov  bx, ERR_TYPE_MISMATCH
    jmp  error

.as_variable:                   ; a name: at the start of a line it may be  x = ...  x += ...  x -= ...
    test r14d, r14d
    jnz  .func_logic            ; inside a statement that is not compiled yet
    cmp  byte [bl_first], 0
    je   .func_logic
    mov  [as_name], rdi
    mov  [as_len], rcx
    call skip_blanks
    cmp  rsi, r12
    jae  .func_logic
    mov  al, [rsi]
    cmp  al, '('
    je   .call_stmt
    cmp  al, '='
    je   .as_eq
    cmp  al, '+'
    je   .as_plus
    cmp  al, '-'
    jne  .func_logic
    mov  byte [as_kind], 2
    jmp  .as_op2
.as_plus:
    mov  byte [as_kind], 1
.as_op2:                        ; "+=" / "-="
    lea  rax, [rsi + 1]
    cmp  rax, r12
    jae  .func_logic
    cmp  byte [rsi + 1], '='
    jne  .func_logic
    add  rsi, 2
    jmp  .as_go
.as_eq:                         ; "=" but not "=="
    mov  byte [as_kind], 0
    lea  rax, [rsi + 1]
    cmp  rax, r12
    jae  .as_eq1
    cmp  byte [rsi + 1], '='
    je   .func_logic
.as_eq1:
    inc  rsi
.as_go:
    mov  rdi, [as_name]
    mov  rcx, [as_len]
    call find_var
    test rax, rax
    jz   .err_unknown_name
    mov  r14d, FN_ASSIGN
    mov  rdi, [as_name]
    mov  rcx, [as_len]
    call note_stmt
    call parse_assign
    jmp  .stmt_done

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
    jz   .close_blocks
    call write_current_func     ; last statement had no trailing newline
.close_blocks:
    call close_all_blocks       ; end of file ends every open block
.finish:
    call purge_tvars            ; temporaries die with the script
    call out_end                ; footer, then write <input>.nasm
    call print_summary          ; "nlang: done - N statements, ..."
    call print_ok               ; "nlang: wrote <file> (N bytes)"
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

; Report the error, then exit with 0x100 + BX. Aligns the stack itself so it is
; safe from any depth. (RSI is still compile's cursor, which gives the line.)
error:
    movzx eax, bx
    add  eax, 0x100
    mov  [err_code], eax
    and  rsp, -16
    sub  rsp, 32
    call print_error
    mov  ecx, [err_code]
    call ExitProcess

%macro PUT 1
    lea  rdx, [%1]
    mov  ecx, %1_len
    call put_text
%endmacro

; "nlang: error 0x10b (line 2): name is already declared"  -> stderr
print_error:
    mov  dword [mb_len], 0
    PUT  s_msg_err
    mov  eax, [err_code]
    call put_hex3
    mov  eax, [err_code]
    cmp  eax, 0x100 + ERR_OUTPUT_FULL    ; these two are not about a line of the source
    je   .no_line
    cmp  eax, 0x100 + ERR_WRITE_FAILED
    je   .no_line
    cmp  eax, 0x100 + ERR_UTF16
    je   .no_line
    PUT  s_msg_line
    call count_line
    call put_dec
    PUT  s_msg_end
    jmp  .text
.no_line:
    mov  ecx, 2                          ; ": "
    lea  rdx, [s_msg_end + 1]
    call put_text
.text:
    mov  eax, [err_code]
    sub  eax, 0x100 + 5                  ; index into err_msgs
    cmp  eax, ERR_COUNT
    jae  .done
    lea  rdx, [err_msgs]
.skip:
    test eax, eax
    jz   .found
    movzx ecx, byte [rdx]
    lea  rdx, [rdx + rcx + 1]
    dec  eax
    jmp  .skip
.found:
    movzx ecx, byte [rdx]
    inc  rdx
    call put_text
.done:
    PUT  s_msg_nl
    mov  ecx, -12                        ; STD_ERROR_HANDLE
    lea  rdx, [msg_buf]
    mov  r8d, [mb_len]
    jmp  print_text

; "nlang: wrote <output file>"  -> stdout
print_ok:
    mov  dword [mb_len], 0
    PUT  s_msg_wrote
    lea  rdx, [out_path]
    xor  ecx, ecx
.len:
    cmp  byte [rdx + rcx], 0
    je   .got
    inc  ecx
    jmp  .len
.got:
    call put_text
    PUT  s_msg_open
    mov  rax, [out_len]
    call put_dec
    PUT  s_msg_bytes
    PUT  s_msg_close
    jmp  flush_stdout

; send msg_buf to stdout
flush_stdout:
    mov  ecx, -11                        ; STD_OUTPUT_HANDLE
    lea  rdx, [msg_buf]
    mov  r8d, [mb_len]
    jmp  print_text

; "nlang: compiling .\script.n (2314 bytes)"   (", package file" for a .ns)
print_start:
    mov  dword [mb_len], 0
    PUT  s_msg_comp
    lea  rdx, [path_buf]
    xor  ecx, ecx
.len:
    cmp  byte [rdx + rcx], 0
    je   .got
    inc  ecx
    jmp  .len
.got:
    call put_text
    PUT  s_msg_open
    mov  rax, [bytes_read]
    call put_dec
    PUT  s_msg_bytes
    cmp  byte [is_ns], 0
    je   .close
    PUT  s_msg_pkg
.close:
    PUT  s_msg_close
    jmp  flush_stdout

; "nlang: done - 31 statements (2 not compiled yet), 24 names declared"
print_summary:
    mov  dword [mb_len], 0
    PUT  s_msg_done
    mov  eax, [stmt_count]
    call put_dec
    PUT  s_msg_stmts
    cmp  dword [skip_count], 0
    je   .names
    PUT  s_msg_open
    mov  eax, [skip_count]
    call put_dec
    PUT  s_msg_skipd
.names:
    PUT  s_msg_comma
    movzx eax, byte [r15]                ; variables + lists left in the table
    call put_dec
    PUT  s_msg_names
    PUT  s_msg_nl
    jmp  flush_stdout

; A statement starts (R14D = FN_* flag, RDI = keyword, RSI just past it). Count it;
; with -v also show it:   "  [12] var num a = 5"   (+ "(not compiled yet)" if so)
; Preserves every register compile uses.
note_stmt:
    inc  dword [stmt_count]
    mov  byte [ns_flag], 0
    cmp  r14d, FN_VAR
    je   .compiled
    cmp  r14d, FN_TVAR
    je   .compiled
    cmp  r14d, FN_LISTDECL
    je   .compiled
    cmp  r14d, FN_LISTOP
    je   .compiled
    cmp  r14d, FN_IF
    je   .compiled
    cmp  r14d, FN_ELIF
    je   .compiled
    cmp  r14d, FN_ELSE
    je   .compiled
    cmp  r14d, FN_ASSIGN
    je   .compiled
    cmp  r14d, FN_DEF
    je   .compiled
    cmp  r14d, FN_RET
    je   .compiled
    cmp  r14d, FN_WHILE
    je   .compiled
    cmp  r14d, FN_UNTIL
    je   .compiled
    cmp  r14d, FN_FOR
    je   .compiled
    inc  dword [skip_count]
    mov  byte [ns_flag], 1
.compiled:
    cmp  byte [verbose], 0
    je   .ret
    push rbx                             ; 5 pushes: keeps rsp 16-byte aligned for the calls
    push rcx
    push rdx
    push rsi
    push rdi
    mov  dword [mb_len], 0
    PUT  s_msg_ind
    call count_line                      ; EAX = line number of RSI
    call put_dec
    PUT  s_msg_rb
    lea  rbx, [buffer]
    mov  rdx, rdi
.back:                                   ; start of this line
    cmp  rdx, rbx
    jbe  .start
    cmp  byte [rdx - 1], 0x0A
    je   .start
    dec  rdx
    jmp  .back
.start:
    cmp  rdx, rdi                        ; skip indentation
    jae  .indented
    cmp  byte [rdx], ' '
    je   .skip_one
    cmp  byte [rdx], 0x09
    jne  .indented
.skip_one:
    inc  rdx
    jmp  .start
.indented:
    mov  rcx, rsi                        ; end of this line
.fwd:
    cmp  rcx, r12
    jae  .end
    cmp  byte [rcx], 0x0A
    je   .end
    cmp  byte [rcx], 0x0D
    je   .end
    inc  rcx
    jmp  .fwd
.end:
    sub  rcx, rdx                        ; length of the line text
    cmp  rcx, 100
    jbe  .show
    mov  ecx, 100                        ; long lines are cut
.show:
    call put_text
    cmp  byte [ns_flag], 0
    je   .eol
    PUT  s_msg_todo
.eol:
    PUT  s_msg_nl
    call flush_stdout
    pop  rdi
    pop  rsi
    pop  rdx
    pop  rcx
    pop  rbx
.ret:
    ret

; in: ECX = -11 (stdout) / -12 (stderr), RDX = text, R8D = length.  Result ignored.
print_text:
    sub  rsp, 40                ; entry rsp is 8 mod 16: 32 shadow + 1 stack arg keeps calls aligned
    mov  [pt_ptr], rdx
    mov  [pt_len], r8
    call GetStdHandle
    mov  rcx, rax
    mov  rdx, [pt_ptr]
    mov  r8d, [pt_len]
    lea  r9, [pt_written]
    mov  qword [pt_written], 0
    mov  qword [rsp + 32], 0
    call WriteFile
    add  rsp, 40
    ret

; append RDX/ECX (text, length) to msg_buf
put_text:
    lea  r9, [msg_buf]
    mov  r8d, [mb_len]
    add  r9, r8
    xor  eax, eax
.l: cmp  eax, ecx
    jae  .d
    mov  r10b, [rdx + rax]
    mov  [r9 + rax], r10b
    inc  eax
    jmp  .l
.d: add  [mb_len], ecx
    ret

put_dec:                        ; EAX as decimal
    mov  eax, eax
    lea  r9, [pd_buf + 24]
    mov  r10, r9
    mov  ecx, 10
.d: xor  edx, edx
    div  rcx
    add  dl, '0'
    dec  r9
    mov  [r9], dl
    test rax, rax
    jnz  .d
    mov  rdx, r9
    mov  rcx, r10
    sub  rcx, r9
    jmp  put_text

put_hex3:                       ; low 12 bits of EAX as 3 hex digits
    lea  r9, [hex_digits]
    lea  r10, [hx_buf]
    mov  edx, eax
    shr  edx, 8
    and  edx, 15
    mov  dl, [r9 + rdx]
    mov  [r10], dl
    mov  edx, eax
    shr  edx, 4
    and  edx, 15
    mov  dl, [r9 + rdx]
    mov  [r10 + 1], dl
    and  eax, 15
    mov  al, [r9 + rax]
    mov  [r10 + 2], al
    mov  rdx, r10
    mov  ecx, 3
    jmp  put_text

; line of the source RSI points into (1-based), capped at the end of the input
count_line:
    lea  rdx, [buffer]
    mov  r8, [bytes_read]
    add  r8, rdx
    mov  r9, rsi
    cmp  r9, r8
    jbe  .go
    mov  r9, r8
.go:
    mov  eax, 1
.l: cmp  rdx, r9
    jae  .d
    cmp  byte [rdx], 0x0A
    jne  .n
    inc  eax
.n: inc  rdx
    jmp  .l
.d: ret

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
    mov  [fv_hit], rdx          ; a match: keep looking, a later (local) one hides it
    jmp  .skip
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
    mov  rax, [fv_hit]
    mov  qword [fv_hit], 0
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
    cmp  word [rdi], 'bi'
    je   .try_bin
    cmp  word [rdi], 'st'
    jne  .bad_type
    cmp  byte [rdi + 2], 'r'
    jne  .bad_type
    mov  byte [vd_type], 1
    jmp  .got_type
.try_bin:
    cmp  byte [rdi + 2], 'n'
    jne  .bad_type
    cmp  qword [cur_fn], 0
    jne  .bin_local
    mov  byte [vd_type], 5
    jmp  .got_type
.bin_local:
    mov  bx, ERR_BIN_LOCAL
    jmp  error
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
    mov  [ex_start], rsi
    cmp  byte [vd_type], 5
    jne  .not_bin
    mov  byte [ex_hint], 1      ; a bin: always an expression (0x... is read as bits)
    jmp  .do_expr
.not_bin:
    cmp  byte [vd_type], 2
    jne  .not_lstr
    cmp  rsi, r12
    jae  .literal               ; (the literal parser reports the missing value)
    mov  al, [rsi]
    cmp  al, "'"
    je   .literal
    cmp  al, '"'
    je   .literal
    jmp  .do_expr               ; lstr: anything but a plain literal is an expression
.not_lstr:
    cmp  rsi, r12
    jae  .literal
    call at_bool                ; var num ok = bool a < b
    test eax, eax
    jz   .not_bool
    mov  rsi, [ex_start]
    jmp  .do_expr
.not_bool:
    mov  al, [rsi]
    call is_ident_start
    test eax, eax
    jz   .literal
    call try_builtin            ; var num n = num(b)
    test eax, eax
    jz   .nb1
    mov  rsi, [ex_start]
    jmp  .do_expr
.nb1:
    call try_call               ; var num n = f(1, 2)
    test eax, eax
    jz   .expr
    mov  rsi, [ex_start]
    jmp  .do_expr
.literal:
    cmp  byte [vd_type], 0
    jne  .init_str
    call parse_number
    mov  [vd_value], rax
    jmp  .chk_op
.expr:
    call parse_value_expr       ; var, s.length, s[#], list.x.length, list.x[#]
    mov  [cmp_tmp], al
    call skip_blanks
    cmp  rsi, r12
    jae  .plain
    mov  dl, [rsi]
    cmp  dl, '+'
    je   .rewind
    cmp  dl, ','
    je   .rewind
.plain:
    mov  al, [cmp_tmp]
    cmp  al, [vd_type]
    je   .k1
    cmp  byte [vd_type], 1      ; the only copy between types: lstr -> str (fit checked at run time)
    jne  .mismatch
    cmp  al, 2
    jne  .mismatch
.rewind:
    mov  rsi, [ex_start]
    jmp  .do_expr
.k1:
    mov  byte [vd_init_kind], 1
    jmp  .end_check
.init_str:
    call parse_string_lit
    cmp  byte [vd_type], 2
    je   .chk_op
    call pack_str_lit           ; str: up to 8 chars in a qword, first char lowest
    mov  [vd_value], rax
.chk_op:                        ; a literal followed by + or , is the start of an expression
    call skip_blanks
    cmp  rsi, r12
    jae  .end_check
    mov  al, [rsi]
    cmp  al, '+'
    je   .rewind
    cmp  al, ','
    je   .rewind
    jmp  .end_check
.do_expr:
    call parse_expr             ; code that leaves the value in rax; AL = its type
    mov  [ex_type], al
    cmp  byte [vd_type], 5
    je   .dx_bin
    cmp  byte [vd_type], 0
    jne  .dx_text
    test al, al
    jnz  .mismatch
    jmp  .dx_ok
.dx_text:
    test al, al
    jz   .mismatch
    cmp  al, 3                  ; a bin is not text
    je   .mismatch
    jmp  .dx_ok
.dx_bin:
    cmp  al, 3
    jne  .mismatch
.dx_ok:
    mov  byte [vd_init_kind], 2
    mov  qword [vd_lit_len], 0  ; an lstr starts empty; the code stores the value
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
    jz   .fn_chk
    cmp  rax, [scope_lo]        ; a global can be hidden by a local of the same name
    jae  .redeclared            ; (scope_lo is 0 at the top level: every match is a redeclaration)
.fn_chk:
    mov  rdi, [vd_name]
    mov  rcx, [vd_len]
    call fn_find
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
    cmp  eax, 5
    je   .copy_bin
    cmp  eax, 2
    ja   .mismatch              ; num, str and lstr can be copied (lists can't)
    mov  [expr_type], al
    mov  byte [expr_kind], EX_COPY
    ret
.copy_bin:
    mov  byte [expr_type], 3
    mov  byte [expr_kind], EX_COPY
    mov  eax, 3
    ret
.str_len:
    cmp  eax, 1
    je   .is_str_len
    cmp  eax, 5
    je   .is_bin_len
    cmp  eax, 2
    jne  .not_string
    mov  byte [expr_kind], EX_LSTR_LEN
    jmp  .len_done
.is_bin_len:
    mov  byte [expr_kind], EX_BIN_LEN
    jmp  .len_done
.is_str_len:
    mov  byte [expr_kind], EX_STR_LEN
.len_done:
    xor  eax, eax
    ret
.str_idx:
    cmp  eax, 1
    je   .is_str_idx
    cmp  eax, 5
    je   .is_bin_idx
    cmp  eax, 2
    jne  .not_string
    mov  byte [expr_kind], EX_LSTR_IDX
    jmp  .idx_done
.is_bin_idx:
    mov  byte [expr_kind], EX_BIN_IDX
    call parse_index
    xor  eax, eax               ; a bit is a number
    ret
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

; ---- blocks: indentation, if / elif / else --------------------------------------
; A block is the run of lines indented deeper than the statement that opens it (like Python).
; Open blocks live on blk_stack, BLK_SIZE bytes each:
;   +0  dword  indentation of the header line (the if / elif / else)
;   +4  dword  indentation of the body (BODY_UNSET until its first line is seen)
;   +8  dword  chain number; the generated labels are if_<chain>_<k> and if_<chain>_end
;   +12 dword  k: number of the label the NEXT branch of the chain starts at
;   +16 byte   BK_IF / BK_ELSE / BK_OPAQUE / BK_LOOP / BK_FOR
;   +24 qword  for: the loop variable's name (in the source),  +32 qword: its length
; Rules: a tab moves to the next multiple of 4 columns; blank and comment-only lines don't count;
; a body may be empty; at the top level (no open block) any indentation is accepted; inside a
; block every line has to line up with the body or with an enclosing block.

; out: R8 = the innermost open block (blk_depth must be > 0). Clobbers EAX.
top_frame:
    mov  eax, [blk_depth]
    dec  eax
    imul eax, eax, BLK_SIZE
    lea  r8, [blk_stack]
    add  r8, rax
    ret

; in: AL = BK_*, [bl_w] = indentation of the header line, [cb_chain] / [cb_k]
push_frame:
    mov  r10b, al
    mov  ecx, [blk_depth]
    cmp  ecx, BLK_MAX
    jae  .too_deep
    imul ecx, ecx, BLK_SIZE
    lea  r8, [blk_stack]
    add  r8, rcx
    mov  eax, [bl_w]
    mov  [r8], eax
    mov  dword [r8 + 4], BODY_UNSET
    mov  eax, [cb_chain]
    mov  [r8 + 8], eax
    mov  eax, [cb_k]
    mov  [r8 + 12], eax
    mov  [r8 + 16], r10b
    mov  rax, [fo_name]
    mov  [r8 + 24], rax
    mov  rax, [fo_len]
    mov  [r8 + 32], rax
    inc  dword [blk_depth]
    ret
.too_deep:
    mov  bx, ERR_TOO_DEEP
    jmp  error

; Ends the innermost block: closes its if-chain in the output and pops it.
finalize_top:
    call top_frame
    movzx eax, byte [r8 + 16]
    cmp  eax, BK_OPAQUE
    je   .pop
    mov  ecx, [r8 + 8]
    mov  [cb_chain], ecx
    mov  ecx, [r8 + 12]
    mov  [cb_k], ecx
    mov  rcx, [r8 + 24]
    mov  [fo_name], rcx
    mov  rcx, [r8 + 32]
    mov  [fo_len], rcx
    cmp  eax, BK_LOOP
    je   .loop_end
    cmp  eax, BK_FOR
    je   .for_end
    cmp  eax, BK_DEF
    je   .def_end
    cmp  eax, BK_IF
    jne  .end_only
    call write_label_next       ; no else followed: a failed last condition lands here
.end_only:
    call write_label_end
.pop:
    dec  dword [blk_depth]
    ret
.loop_end:                      ; back to the test, and the exit lands after it
    call write_jmp_top
    call write_label_next
    jmp  .pop
.for_end:
    call write_for_step
    call write_label_next
    jmp  .pop
.def_end:                       ; the function's closing code; its parameters and locals go out of scope
    call write_def_end
    mov  al, [scope_cnt]
    mov  [r15], al
    mov  qword [cur_fn], 0
    mov  dword [cur_fn_id], 0
    mov  qword [scope_lo], 0
    jmp  .pop

close_all_blocks:
    cmp  dword [blk_depth], 0
    je   .done
    call finalize_top
    jmp  close_all_blocks
.done:
    ret

; in: RDI = start of a token
; out: EAX = indentation of its line (space = 1, tab = to the next multiple of 4), or -1 if anything
;      other than blanks comes before the token on its line. Clobbers RCX, RDX, R8, R9.
line_indent:
    lea  rdx, [buffer]
    mov  r8, rdi
.back:
    cmp  r8, rdx
    jbe  .at_start
    cmp  byte [r8 - 1], 0x0A
    je   .at_start
    dec  r8
    jmp  .back
.at_start:
    cmp  r8, rdx
    jne  .go
    lea  r9, [rdx + 3]          ; a UTF-8 BOM at the very start of the file is not indentation
    cmp  rdi, r9
    jb   .go
    cmp  word [rdx], 0xBBEF
    jne  .go
    cmp  byte [rdx + 2], 0xBF
    jne  .go
    add  r8, 3
.go:
    xor  eax, eax
.scan:
    cmp  r8, rdi
    jae  .done
    movzx ecx, byte [r8]
    cmp  cl, ' '
    je   .space
    cmp  cl, 0x09
    je   .tab
    cmp  cl, 0x0D
    je   .next
    mov  eax, -1
    ret
.space:
    inc  eax
    jmp  .next
.tab:
    add  eax, 4
    and  eax, -4
.next:
    inc  r8
    jmp  .scan
.done:
    ret

; A statement starts on a new line: [bl_w] = its indentation, [bl_kw] = its keyword (FN_*, 0 = none).
; Ends the blocks that this line is no longer part of (emitting their closing labels) and checks the
; indentation.  out: EAX = 1 when the line is an elif / else that continues the open if-chain.
blocks_line_start:
.loop:
    cmp  dword [blk_depth], 0
    je   .none                  ; top level: any indentation is fine
    call top_frame              ; R8
    mov  eax, [bl_w]
    mov  edx, [r8 + 4]
    cmp  edx, BODY_UNSET
    jne  .has_body
    cmp  eax, [r8]
    jbe  .ended                 ; not indented deeper than its header: the block had no body
    mov  [r8 + 4], eax          ; first line of the body: its indentation is the body's
    jmp  .none
.has_body:
    cmp  eax, edx
    je   .none                  ; an ordinary line of the body
    ja   .bad_indent            ; deeper than the body, with nothing opening a block
.ended:                         ; the body is over
    cmp  eax, [r8]
    ja   .bad_indent            ; between the header and the body: lines up with nothing
    jb   .close                 ; less than the header: the whole block is over
    mov  ecx, [bl_kw]           ; exactly as far in as the header
    cmp  ecx, FN_ELIF
    je   .chain
    cmp  ecx, FN_ELSE
    jne  .close
.chain:
    cmp  byte [r8 + 16], BK_IF
    jne  .no_if                 ; after an else (or a while ...) there is nothing to continue
    mov  eax, 1
    ret
.close:
    call finalize_top
    jmp  .loop
.none:
    xor  eax, eax
    ret
.bad_indent:
    mov  bx, ERR_BAD_INDENT
    jmp  error
.no_if:
    mov  bx, ERR_ELSE_NO_IF
    jmp  error

; ---- functions ------------------------------------------------------------------------
;   def name (num a, str b, lstr c):      ...body...       ret [value]          name(args)
; Function record (FN_SIZE bytes):  +0 name ptr  +8 name length  +16 id  +20 parameter count
;   +21 return type (0 num, 1 str, 2 lstr, 0xFE nothing, 0xFF not known yet)  +22 parameter types (8)
;   +32 parameter names: 8 x (ptr, length)
; Parameters and everything declared in the body are local: they get their own storage (labels end in
; @<id>) and go out of scope at the end of the def. A recursive call saves the storage of the running
; call in a save area and restores it afterwards, so every call starts with its own variables.

; in: RDI = name, RCX = length   out: RAX = record or 0   clobbers RDX, R8-R10
fn_find:
    mov  r8d, [fn_count]
    lea  rdx, [fn_table]
.next:
    test r8d, r8d
    jz   .none
    cmp  [rdx + 8], rcx
    jne  .skip
    mov  r9, [rdx]
    xor  r10d, r10d
.cmp:
    mov  al, [r9 + r10]
    cmp  al, [rdi + r10]
    jne  .skip
    inc  r10
    cmp  r10, rcx
    jb   .cmp
    mov  rax, rdx
    ret
.skip:
    add  rdx, FN_SIZE
    dec  r8d
    jmp  .next
.none:
    xor  eax, eax
    ret

; in: RDI = type word, RCX = its length   out: AL = 0 num, 1 str, 2 lstr
type_word:
    cmp  rcx, 3
    jne  .l4
    cmp  word [rdi], 'nu'
    jne  .s
    cmp  byte [rdi + 2], 'm'
    jne  .bad
    xor  eax, eax
    ret
.s:
    cmp  word [rdi], 'st'
    jne  .bad
    cmp  byte [rdi + 2], 'r'
    jne  .bad
    mov  eax, 1
    ret
.l4:
    cmp  rcx, 4
    jne  .bad
    cmp  dword [rdi], 'lstr'
    jne  .bad
    mov  eax, 2
    ret
.bad:
    mov  bx, ERR_BAD_VAR_TYPE
    jmp  error

; def NAME (type a, type b):     RSI is just past "def"
parse_def_header:
    call read_new_name          ; checks the name against variables (vd_name / vd_len)
    mov  rdi, [vd_name]
    mov  rcx, [vd_len]
    call fn_find
    test rax, rax
    jnz  .redeclared
    mov  eax, [fn_count]
    cmp  eax, FN_MAX
    jae  .full
    imul eax, eax, FN_SIZE
    lea  r8, [fn_table]
    add  r8, rax
    mov  rax, [vd_name]
    mov  [r8], rax
    mov  rax, [vd_len]
    mov  [r8 + 8], rax
    inc  dword [fn_count]
    inc  dword [fn_ids]
    mov  eax, [fn_ids]
    mov  [r8 + 16], eax
    mov  byte [r8 + 20], 0
    mov  byte [r8 + 21], 0xFF
    mov  [cur_fn], r8
    mov  [cur_fn_id], eax
    movzx eax, byte [r15]
    mov  [scope_cnt], al        ; the variables that exist now stay; the ones added from here on are local
    xor  ecx, ecx
    call find_var               ; (no match: RDX = end of the variable table)
    mov  [scope_lo], rdx
    call write_def_begin
    call skip_blanks
    cmp  rsi, r12
    jae  .syntax
    cmp  byte [rsi], '('
    jne  .syntax
    inc  rsi
    call skip_blanks
    cmp  rsi, r12
    jae  .syntax
    cmp  byte [rsi], ')'
    jne  .param
    inc  rsi
    jmp  .after
.param:
    call skip_blanks
    call read_ident
    test rcx, rcx
    jz   .syntax
    call type_word
    mov  [vd_type], al
    call read_new_name
    mov  byte [vd_temp], 0
    mov  byte [vd_has_init], 0
    mov  byte [vd_init_kind], 0
    mov  qword [vd_value], 0
    mov  qword [vd_lit_len], 0
    mov  r8, [cur_fn]
    movzx ecx, byte [r8 + 20]
    cmp  ecx, MAX_PARAMS
    jae  .full
    mov  al, [vd_type]
    mov  [r8 + 22 + rcx], al
    mov  edx, ecx
    shl  edx, 4
    mov  rax, [vd_name]
    mov  [r8 + 32 + rdx], rax
    mov  rax, [vd_len]
    mov  [r8 + 40 + rdx], rax
    inc  byte [r8 + 20]
    call add_var
    call write_param_decl
    call skip_blanks
    cmp  rsi, r12
    jae  .syntax
    mov  al, [rsi]
    inc  rsi
    cmp  al, ','
    je   .param
    cmp  al, ')'
    jne  .syntax
.after:                         ; optional return type:  def f (num n) num:
    call skip_blanks
    cmp  rsi, r12
    jae  .enter
    mov  al, [rsi]
    call is_ident_start
    test eax, eax
    jz   .enter
    call read_ident
    call type_word
    mov  r8, [cur_fn]
    mov  [r8 + 21], al
.enter:
    jmp  write_def_enter
.redeclared:
    mov  bx, ERR_REDECLARED
    jmp  error
.full:
    mov  bx, ERR_TABLE_FULL
    jmp  error
.syntax:
    mov  bx, ERR_INVALID_VAR_SYNTAX
    jmp  error

; RSI is at a name. When it is a function followed by '(' : consume both, [call_fn] = the record, EAX = 1.
; Otherwise nothing is consumed and EAX = 0.
try_call:
    push rsi
    call read_ident
    test rcx, rcx
    jz   .no
    call fn_find
    test rax, rax
    jz   .no
    mov  [call_fn], rax
    call skip_blanks
    cmp  rsi, r12
    jae  .no
    cmp  byte [rsi], '('
    jne  .no
    inc  rsi
    add  rsp, 8
    mov  eax, 1
    ret
.no:
    pop  rsi
    xor  eax, eax
    ret

; The arguments and the call itself.  in: [call_fn], RSI just past '(',  AL = 1 when the function may return
; nothing (a call used as a statement).  out: AL = type of the value (the generated code leaves it in RAX)
parse_call:
    push rbp
    movzx eax, al
    push rax                    ; +104 allow
    push qword [call_fn]        ; +96  the function
    movzx eax, byte [ex_cur]
    push rax                    ; +88
    movzx eax, byte [ex_sb]
    push rax                    ; +80
    movzx eax, byte [ex_pure]
    push rax                    ; +72
    movzx eax, byte [ex_plus]
    push rax                    ; +64
    movzx eax, byte [ex_space]
    push rax                    ; +56
    movzx eax, byte [ex_noc]
    push rax                    ; +48
    movzx eax, byte [cond_op]
    push rax                    ; +40
    movzx eax, byte [cmp_ltype]
    push rax                    ; +32
    movzx eax, byte [cmp_tmp]
    push rax                    ; +24
    push qword [cmp_imm]        ; +16
    inc  dword [call_ctr]
    mov  eax, [call_ctr]
    push rax                    ; +8   call site number
    push 0                      ; +0   arguments so far
    mov  rbp, rsp
    mov  r8, [rbp + 96]
    mov  [w_fn], r8
    mov  eax, [rbp + 8]
    mov  [w_site], eax
    call write_call_begin       ; push rbx: the caller's left operand survives the call
    cmp  qword [rbp + 80], 0
    je   .nosb
    call write_sb_save          ; the text being built by the caller survives too
.nosb:
    mov  byte [ex_noc], 1
    call skip_blanks
    cmp  rsi, r12
    jae  .syntax
    cmp  byte [rsi], ')'
    je   .close
.arg:
    call parse_expr             ; the generated code leaves the value in RAX
    mov  [w_site], eax          ; (AL = its type; w_site is rewritten below)
    mov  r8, [rbp + 96]
    mov  rcx, [rbp]
    movzx edx, byte [r8 + 20]
    cmp  rcx, rdx
    jae  .argcount
    mov  eax, [w_site]
    cmp  al, [r8 + 22 + rcx]
    je   .type_ok
    cmp  byte [r8 + 22 + rcx], 2
    jne  .mismatch
    cmp  al, 1                  ; a str can be passed where an lstr is wanted
    jne  .mismatch
    call write_str_to_sb
    mov  eax, 2
    mov  rcx, [rbp]
.type_ok:
    mov  edx, [rbp + 8]
    mov  [w_site], edx
    movzx eax, al
    call write_arg_push         ; EAX = type, ECX = argument number
    inc  qword [rbp]
    call skip_blanks
    cmp  rsi, r12
    jae  .syntax
    mov  al, [rsi]
    cmp  al, ','
    jne  .chk_close
    inc  rsi
    jmp  .arg
.chk_close:
    cmp  al, ')'
    jne  .syntax
.close:
    mov  r8, [rbp + 96]
    movzx edx, byte [r8 + 20]
    cmp  [rbp], rdx
    jne  .argcount
    inc  rsi
    mov  [w_fn], r8
    mov  eax, [rbp + 8]
    mov  [w_site], eax
    call write_call_emit
    cmp  qword [rbp + 80], 0
    je   .nosb2
    call write_sb_restore
.nosb2:
    call write_call_end
    mov  r8, [rbp + 96]
    movzx r9d, byte [r8 + 21]   ; the type of the value
    cmp  r9d, 0xFE
    jae  .novalue
.restore:
    add  rsp, 16                ; counter, site
    pop  rdx
    mov  [cmp_imm], rdx
    pop  rdx
    mov  [cmp_tmp], dl
    pop  rdx
    mov  [cmp_ltype], dl
    pop  rdx
    mov  [cond_op], dl
    pop  rdx
    mov  [ex_noc], dl
    pop  rdx
    mov  [ex_space], dl
    pop  rdx
    mov  [ex_plus], dl
    pop  rdx
    mov  [ex_pure], dl
    pop  rdx
    mov  [ex_sb], dl
    pop  rdx
    mov  [ex_cur], dl
    add  rsp, 16                ; function, allow
    pop  rbp
    mov  eax, r9d
    ret
.novalue:
    cmp  qword [rbp + 104], 0   ; allowed as a statement
    jne  .restore_void
    cmp  r9d, 0xFF
    jne  .mismatch
    cmp  r8, [cur_fn]
    jne  .mismatch              ; a function that never returns a value
    mov  bx, ERR_RET_TYPE       ; its own recursive call before its first ret
    jmp  error
.restore_void:
    mov  r9d, 0xFE
    jmp  .restore
.argcount:
    mov  bx, ERR_ARG_COUNT
    jmp  error
.mismatch:
    mov  bx, ERR_TYPE_MISMATCH
    jmp  error
.syntax:
    mov  bx, ERR_INVALID_VAR_SYNTAX
    jmp  error

; ---- expressions: numbers and text --------------------------------------------------
;   expr := term { ( '+' | ',' | ', ' ) term }          evaluated from left to right
;   term := number | 'text' | variable | s.length | s[#] | list.x.length | list.x[#]
;   +   two numbers: their sum.  Two texts (str / lstr): joined.
;   ,   joins two texts, or a text and a number (the number becomes its decimal digits), with nothing between
;   ,_  the same with a space between: a comma that is followed by a space or tab
; Text is built in a runtime buffer (rt_sb); the result of a join is an lstr value (rax = its address).
; Types: 0 num, 1 str (rax = up to 8 characters), 2 lstr (rax = address of [length][bytes]).

; out: AL = type of the term; the generated code leaves its value in RAX
parse_term:
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
    call try_builtin            ; bin( ... )  num( ... )
    test eax, eax
    jz   .not_builtin
    jmp  parse_builtin
.not_builtin:
    call try_call
    test eax, eax
    jz   .plain_term
    xor  eax, eax               ; a call that returns nothing is no value here
    jmp  parse_call
.plain_term:
    call parse_value_expr
    mov  [cmp_tmp], al
    call write_expr
    mov  al, [cmp_tmp]
    ret
.num:
    mov  dl, [ex_binctx]
    call bin_prefix
    test eax, eax
    jz   .num_plain
    call parse_bin_lit
    call write_lit_bin
    mov  eax, 3
    ret
.num_plain:
    call parse_number
    mov  [cmp_imm], rax
    call write_mov_rax_imm
    xor  eax, eax
    ret
.str:
    call parse_string_lit
    cmp  qword [vd_lit_len], 8
    ja   .long
    call pack_str_lit
    mov  [cmp_imm], rax
    call write_mov_rax_imm
    mov  eax, 1
    ret
.long:                          ; more than 8 characters: a constant lstr in the output
    call write_lit_lstr
    mov  eax, 2
    ret
.syntax:
    mov  bx, ERR_INVALID_VAR_SYNTAX
    jmp  error

; ---- bin: bit strings ---------------------------------------------------------------------
;   var bin x = 0b1010      0x3F (4 bits per digit)      bin(n) (the 64 bits of a num)      num(b) (the lowest 64 bits)
;   x = a and b    a or b    a xor b      a not and b = nand,  a not or b = nor,  a not xor b = xnor,   not a = every bit flipped
;   x.length = number of bits      x[#] = bit # (0 = least significant) as a num
;   == and != compare two bins (the shorter one is padded with zeros on the left); a bin joins text as 0b...
; A bin is stored as [length in bits][bits packed into bytes, bit 0 = lowest bit of byte 0] and holds up to
; BIN_BITS bits.  A shorter operand is padded with zeros on the left (like numbers), the result is as long as
; the longer operand.  Operations are done left to right in the accumulator rt_bacc.

; EAX = 1 when RSI is at  0b  (always) or  0x  (when DL = 1: the text is read as bits)
bin_prefix:
    lea  rax, [rsi + 3]
    cmp  rax, r12
    ja   .no
    cmp  byte [rsi], '0'
    jne  .no
    mov  al, [rsi + 1]
    or   al, 0x20
    cmp  al, 'b'
    je   .yes
    cmp  al, 'x'
    jne  .no
    test dl, dl
    jz   .no
.yes:
    mov  eax, 1
    ret
.no:
    xor  eax, eax
    ret

; in: AL = character, R9D = bits per digit (1: binary, 4: hex)   out: EAX = digit value or -1
bin_digit:
    movzx eax, al
    cmp  eax, '0'
    jb   .no
    cmp  r9d, 1
    jne  .hex
    cmp  eax, '1'
    ja   .no
    sub  eax, '0'
    ret
.hex:
    cmp  eax, '9'
    jbe  .dec
    or   eax, 0x20
    cmp  eax, 'a'
    jb   .no
    cmp  eax, 'f'
    ja   .no
    sub  eax, 'a' - 10
    ret
.dec:
    sub  eax, '0'
    ret
.no:
    mov  eax, -1
    ret

; RSI at 0b... or 0x...   -> bin_bits / bin_buf, RSI past the literal
parse_bin_lit:
    lea  rdi, [bin_buf]
    mov  ecx, (BIN_BYTES + 8) / 8
    xor  eax, eax
    rep  stosq
    mov  al, [rsi + 1]
    or   al, 0x20
    mov  r9d, 1
    cmp  al, 'x'
    jne  .go
    mov  r9d, 4
.go:
    add  rsi, 2
    mov  r8, rsi                ; first digit
    xor  r10d, r10d             ; number of digits
.cnt:
    cmp  rsi, r12
    jae  .counted
    mov  al, [rsi]
    call bin_digit
    cmp  eax, -1
    je   .counted
    inc  r10
    inc  rsi
    jmp  .cnt
.counted:
    test r10, r10
    jz   .bad
    cmp  rsi, r12
    jae  .sized
    movzx eax, byte [rsi]
    call ident_char             ; a letter or digit right after the last digit: not a valid literal
    test eax, eax
    jnz  .bad
.sized:
    mov  rax, r10
    imul rax, r9
    cmp  rax, BIN_BITS
    ja   .big
    mov  [bin_bits], rax
    lea  rbx, [bin_buf]
    xor  r11d, r11d             ; digit number, from the left
.fill:
    cmp  r11, r10
    jae  .done
    mov  al, [r8 + r11]
    call bin_digit
    mov  edx, eax
    mov  rax, r10
    dec  rax
    sub  rax, r11
    imul rax, r9                ; number of the lowest bit of this digit
    xor  ecx, ecx
.bit:
    cmp  ecx, r9d
    jae  .nextd
    bt   edx, ecx
    jnc  .skip
    lea  rdi, [rax + rcx]
    bts  [rbx], rdi
.skip:
    inc  ecx
    jmp  .bit
.nextd:
    inc  r11
    jmp  .fill
.done:
    ret
.bad:
    mov  bx, ERR_INVALID_VAR_SYNTAX
    jmp  error
.big:
    mov  bx, ERR_BIN_TOO_BIG
    jmp  error

; EAX = 1 (RSI moved past "not") when the text is  not  followed by a space or tab
at_not:
    lea  rax, [rsi + 4]
    cmp  rax, r12
    jae  .no
    cmp  word [rsi], 'no'
    jne  .no
    cmp  byte [rsi + 2], 't'
    jne  .no
    mov  al, [rsi + 3]
    cmp  al, ' '
    je   .yes
    cmp  al, 0x09
    jne  .no
.yes:
    add  rsi, 3
    mov  eax, 1
    ret
.no:
    xor  eax, eax
    ret

; at  and / or / xor  (optionally with not in front): consumes it.  out: EAX = 0 and, 1 or, 2 xor, +4 when inverted;
; -1 (nothing consumed) when something else is there
match_bin_op:
    push rsi
    call read_ident
    xor  r8d, r8d
    cmp  rcx, 3
    jne  .word
    cmp  word [rdi], 'no'
    jne  .word
    cmp  byte [rdi + 2], 't'
    jne  .word
    mov  r8d, 4
    call skip_blanks
    call read_ident
.word:
    cmp  rcx, 3
    jne  .or
    cmp  word [rdi], 'an'
    jne  .xor
    cmp  byte [rdi + 2], 'd'
    jne  .none
    xor  eax, eax
    jmp  .got
.xor:
    cmp  word [rdi], 'xo'
    jne  .none
    cmp  byte [rdi + 2], 'r'
    jne  .none
    mov  eax, 2
    jmp  .got
.or:
    cmp  rcx, 2
    jne  .none
    cmp  word [rdi], 'or'
    jne  .none
    mov  eax, 1
.got:
    or   eax, r8d
    add  rsp, 8
    ret
.none:
    pop  rsi
    mov  eax, -1
    ret

; RSI at a name:  bin(  or  num(   ->  EAX = 1 / 2, name and '(' consumed;  otherwise EAX = 0, nothing consumed
try_builtin:
    push rsi
    call read_ident
    cmp  rcx, 3
    jne  .no
    mov  eax, 1
    cmp  word [rdi], 'bi'
    jne  .num
    cmp  byte [rdi + 2], 'n'
    je   .paren
    jmp  .no
.num:
    mov  eax, 2
    cmp  word [rdi], 'nu'
    jne  .no
    cmp  byte [rdi + 2], 'm'
    jne  .no
.paren:
    mov  r8d, eax
    call skip_blanks
    cmp  rsi, r12
    jae  .no
    cmp  byte [rsi], '('
    jne  .no
    inc  rsi
    add  rsp, 8
    mov  eax, r8d
    ret
.no:
    pop  rsi
    xor  eax, eax
    ret

; bin(n) / num(b)  after the '(' .  out: AL = type of the value (3 / 0), code that leaves it in RAX
parse_builtin:
    push rax                    ; kind
    movzx eax, byte [ex_cur]
    push rax
    movzx eax, byte [ex_sb]
    push rax
    movzx eax, byte [ex_pure]
    push rax
    movzx eax, byte [ex_plus]
    push rax
    movzx eax, byte [ex_space]
    push rax
    movzx eax, byte [ex_noc]
    push rax
    movzx eax, byte [ex_binctx]
    push rax
    movzx eax, byte [ex_bin]
    push rax
    movzx eax, byte [ex_op]
    push rax
    mov  byte [ex_noc], 1
    cmp  qword [rsp + 72], 2
    jne  .arg
    mov  byte [ex_hint], 1      ; num( 0xFF ): the hex literal is bits
.arg:
    call parse_expr
    mov  rdx, [rsp + 72]
    cmp  edx, 2
    je   .want_bin
    test al, al                 ; bin( needs a number
    jnz  .mismatch
    jmp  .close
.want_bin:
    cmp  al, 3
    jne  .mismatch
.close:
    call skip_blanks
    cmp  rsi, r12
    jae  .syntax
    cmp  byte [rsi], ')'
    jne  .syntax
    inc  rsi
    cmp  qword [rsp + 72], 2
    je   .to_num
    call write_bin_from_num
    jmp  .restore
.to_num:
    call write_bin_to_num
.restore:
    pop  rdx
    mov  [ex_op], dl
    pop  rdx
    mov  [ex_bin], dl
    pop  rdx
    mov  [ex_binctx], dl
    pop  rdx
    mov  [ex_noc], dl
    pop  rdx
    mov  [ex_space], dl
    pop  rdx
    mov  [ex_plus], dl
    pop  rdx
    mov  [ex_pure], dl
    pop  rdx
    mov  [ex_sb], dl
    pop  rdx
    mov  [ex_cur], dl
    pop  rax
    cmp  eax, 2
    je   .r_num
    mov  eax, 3
    ret
.r_num:
    xor  eax, eax
    ret
.mismatch:
    mov  bx, ERR_TYPE_MISMATCH
    jmp  error
.syntax:
    mov  bx, ERR_INVALID_VAR_SYNTAX
    jmp  error

; out: AL = type; code that leaves the value in RAX (see above)
parse_expr:
    mov  al, [ex_hint]
    mov  [ex_binctx], al
    mov  byte [ex_hint], 0
    mov  byte [ex_bin], 0
    call skip_blanks
    call at_bool                ; bool a < b is the whole value (a num: 1 or 0)
    test eax, eax
    jz   .no_bool
    call parse_bool
    xor  eax, eax
    ret
.no_bool:
    call at_not                 ; not b   (a bin with every bit flipped)
    test eax, eax
    jz   .first
    mov  byte [ex_binctx], 1
    call parse_term
    cmp  al, 3
    jne  .mismatch
    call write_bin_load
    call write_bin_not
    mov  byte [ex_bin], 1
    call write_bin_result
    mov  byte [ex_cur], 3
    mov  byte [ex_sb], 0
    mov  byte [ex_pure], 0
    jmp  .loop
.first:
    call parse_term
    mov  [ex_cur], al
    mov  byte [ex_sb], 0
    mov  byte [ex_pure], 0
.loop:
    call skip_blanks
    cmp  rsi, r12
    jae  .done
    cmp  byte [ex_cur], 3       ; a bin: and / or / xor  (with  not  in front of the word: nand / nor / xnor)
    jne  .nobin
    cmp  byte [ex_sb], 0
    jne  .nobin
    call match_bin_op
    cmp  eax, -1
    je   .nobin
    mov  [ex_op], al
    mov  byte [ex_binctx], 1
    cmp  byte [ex_bin], 0
    jne  .have_acc
    call write_bin_load         ; the first term goes into the accumulator
    mov  byte [ex_bin], 1
.have_acc:
    movzx eax, byte [ex_op]
    push rax
    call parse_term
    pop  rdx
    mov  [ex_op], dl
    cmp  al, 3
    jne  .mismatch
    call write_bin_op
    call write_bin_result
    jmp  .loop
.nobin:
    mov  al, [rsi]
    mov  byte [ex_space], 0
    cmp  al, '+'
    je   .plus
    cmp  al, ','
    jne  .done
    cmp  byte [ex_noc], 0
    jne  .done                  ; inside call arguments: the comma separates arguments
    mov  byte [ex_plus], 0
    inc  rsi
    cmp  rsi, r12
    jae  .op
    mov  al, [rsi]
    cmp  al, ' '
    je   .sp
    cmp  al, 0x09
    jne  .op
.sp:
    mov  byte [ex_space], 1
    jmp  .op
.plus:
    mov  byte [ex_plus], 1
    inc  rsi
.op:
    cmp  byte [ex_sb], 0
    jne  .append
    cmp  byte [ex_cur], 0
    jne  .not_num_start
    cmp  byte [ex_plus], 0
    je   .start_num
    call write_mov_rbx_rax      ; number + term
    call parse_term
    test al, al
    jnz  .mismatch
    call write_add_rbx
    jmp  .loop
.not_num_start:
    cmp  byte [ex_plus], 0      ; '+' does not join a bin
    je   .start_text
    cmp  byte [ex_cur], 3
    je   .mismatch
    jmp  .start_text
.start_num:                     ; number , term  ->  text
    mov  byte [ex_pure], 1
.start_text:
    call write_sb_start         ; the builder now holds the value so far
    mov  byte [ex_sb], 1
.append:
    cmp  byte [ex_space], 0
    je   .nospace
    call write_sb_space
.nospace:
    call parse_term
    cmp  byte [ex_plus], 0
    je   .chk_pure
    test al, al
    jz   .mismatch              ; '+' needs text on both sides
    cmp  al, 3
    je   .mismatch
.chk_pure:
    cmp  byte [ex_pure], 0
    je   .do_app
    mov  byte [ex_pure], 0
    test al, al
    jz   .mismatch              ; two numbers can't be joined with ','
.do_app:
    call write_sb_append        ; AL = type of the term
    jmp  .loop
.done:
    cmp  byte [ex_sb], 0
    je   .plain
    call write_sb_result
    mov  eax, 2
    ret
.plain:
    movzx eax, byte [ex_cur]
    ret
.mismatch:
    mov  bx, ERR_TYPE_MISMATCH
    jmp  error

; EAX = 1 (and RSI moved past the word) when the text at RSI is  bool  followed by a space or tab
at_bool:
    lea  rax, [rsi + 5]
    cmp  rax, r12
    jae  .no
    cmp  dword [rsi], 'bool'
    jne  .no
    mov  al, [rsi + 4]
    cmp  al, ' '
    je   .yes
    cmp  al, 0x09
    jne  .no
.yes:
    add  rsi, 4
    mov  eax, 1
    ret
.no:
    xor  eax, eax
    ret

; bool A op B   /   bool A  (a number on its own: true when not 0)      RSI is just past "bool"
; The generated code leaves 1 or 0 in RAX. Same operands and operators as an if condition.
parse_bool:
    mov  byte [cmp_ltype], 0xFF
    call parse_cmp_operand
    mov  [cmp_ltype], al
    call write_mov_rbx_rax
    call skip_blanks
    cmp  rsi, r12
    jae  .truthy
    mov  al, [rsi]
    cmp  al, 0x0A
    je   .truthy
    cmp  al, 0x0D
    je   .truthy
    cmp  al, '#'
    je   .truthy
    cmp  byte [ex_noc], 0
    je   .cmp_op
    cmp  al, ','
    je   .truthy
    cmp  al, ')'
    je   .truthy
.cmp_op:
    call parse_cmp_op
    call parse_cmp_operand
    cmp  al, [cmp_ltype]
    jne  .mismatch
    cmp  al, 1                  ; strings and bins: only == and !=
    je   .eqonly
    cmp  al, 3
    jne  .emit
.eqonly:
    cmp  byte [cond_op], 2
    ja   .bad_cmp
    cmp  al, 3
    jne  .emit
    call write_bin_eq           ; the comparison is made on 1 / 0
.emit:
    jmp  write_setcc
.truthy:
    cmp  byte [cmp_ltype], 0
    jne  .mismatch
    mov  byte [cond_op], 2
    mov  qword [cmp_imm], 0
    call write_mov_rax_imm
    jmp  write_setcc
.mismatch:
    mov  bx, ERR_TYPE_MISMATCH
    jmp  error
.bad_cmp:
    mov  bx, ERR_BAD_COMPARE
    jmp  error

; x = expr / x += expr / x -= expr   ([as_name], [as_len], [as_kind]; RSI is just past the operator)
parse_assign:
    mov  rdi, [as_name]
    mov  rcx, [as_len]
    call find_var
    movzx eax, byte [rax + 1]
    and  eax, VAR_TYPE_MASK
    cmp  eax, 5
    je   .bin_target
    cmp  eax, 2
    ja   .mismatch              ; lists can't be assigned
.bin_target:
    mov  [st_type], al
    cmp  al, 5
    jne  .nohint
    mov  byte [ex_hint], 1
.nohint:
    mov  rax, [as_name]
    mov  [st_name], rax
    mov  rax, [as_len]
    mov  [st_len], rax
    call parse_expr
    mov  [ex_type], al
    call expect_end
    movzx eax, byte [ex_type]
    cmp  byte [st_type], 5
    jne  .not_bin_var
    cmp  eax, 3                 ; a bin takes a bin (and only = : no += / -=)
    jne  .mismatch
    cmp  byte [as_kind], 0
    jne  .mismatch
    jmp  write_assign
.not_bin_var:
    cmp  byte [st_type], 0
    jne  .text_var
    test eax, eax               ; a num variable takes a number
    jnz  .mismatch
    jmp  write_assign
.text_var:
    cmp  byte [as_kind], 2
    je   .mismatch              ; -= is for numbers
    test eax, eax
    jz   .mismatch              ; str / lstr take text
    cmp  eax, 3
    je   .mismatch
    jmp  write_assign
.mismatch:
    mov  bx, ERR_TYPE_MISMATCH
    jmp  error

; ---- conditions -------------------------------------------------------------------
; if / elif / while / until take ONE comparison:   operand  ==  !=  <  >  <=  >=  operand   or just  operand
; (a number on its own means "not zero"). An operand is a number, a 'string', a variable, or
; s.length  s[#]  list.x.length  list.x[#].  Numbers compare signed; strings only with == and !=;
; lstr values and lists can't be compared. Combine several conditions with bool, not and / or.
; The generated code jumps to the next branch when the condition is FALSE.

; in: [cb_chain] / [cb_k] = label to jump to when the condition fails; RSI after the keyword
parse_condition:
    mov  byte [cmp_ltype], 0xFF
    call parse_cmp_operand      ; AL = type, the value is left in RAX by the generated code
    mov  [cmp_ltype], al
    call write_mov_rbx_rax      ; keep the left value in RBX while the right one is computed
    call skip_blanks
    cmp  rsi, r12
    jae  .no_colon
    mov  al, [rsi]
    cmp  al, ':'
    je   .truthy
    cmp  al, 0x0A               ; "if x" and the line ends: the colon is what is missing
    je   .no_colon
    cmp  al, 0x0D
    je   .no_colon
    cmp  al, '#'
    je   .no_colon
    call parse_cmp_op
    call parse_cmp_operand
    cmp  al, [cmp_ltype]
    jne  .mismatch
    cmp  al, 1                  ; strings and bins: only == and !=
    je   .eqonly
    cmp  al, 3
    jne  .emit
.eqonly:
    cmp  byte [cond_op], 2
    ja   .bad_cmp
    cmp  al, 3
    jne  .emit
    call write_bin_eq           ; the comparison is made on 1 / 0
.emit:
    jmp  write_cmp_jump
.truthy:                        ; "if x:" is "if x != 0:"
    cmp  byte [cmp_ltype], 0
    jne  .mismatch
    mov  byte [cond_op], 2
    mov  qword [cmp_imm], 0
    call write_mov_rax_imm
    jmp  write_cmp_jump
.no_colon:
    mov  bx, ERR_EXPECT_COLON
    jmp  error
.mismatch:
    mov  bx, ERR_TYPE_MISMATCH
    jmp  error
.bad_cmp:
    mov  bx, ERR_BAD_COMPARE
    jmp  error

; One operand; the generated code leaves its value in RAX.  out: AL = type (0 num, 1 str)
parse_cmp_operand:
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
    call try_builtin            ; bin( ) / num( ) as an operand
    test eax, eax
    jz   .not_bi
    call parse_builtin
    ret
.not_bi:
    call try_call
    test eax, eax
    jz   .plain_opd
    xor  eax, eax
    call parse_call
    cmp  al, 2
    je   .lstr_cmp
    ret
.plain_opd:
    call parse_value_expr       ; variable, s.length, s[#], list.x.length, list.x[#]
    mov  [cmp_tmp], al
    cmp  al, 2
    je   .lstr_cmp              ; an lstr can't be compared
    call write_expr
    mov  al, [cmp_tmp]
    ret
.lstr_cmp:
    mov  bx, ERR_TYPE_MISMATCH
    jmp  error
.num:
    xor  edx, edx
    cmp  byte [cmp_ltype], 3    ; the right side of a bin comparison: 0x... is bits
    sete dl
    call bin_prefix
    test eax, eax
    jz   .num_plain
    call parse_bin_lit
    call write_lit_bin
    mov  eax, 3
    ret
.num_plain:
    call parse_number
    mov  [cmp_imm], rax
    call write_mov_rax_imm
    xor  eax, eax
    ret
.str:
    call parse_string_lit
    call pack_str_lit
    mov  [cmp_imm], rax
    call write_mov_rax_imm
    mov  eax, 1
    ret
.syntax:
    mov  bx, ERR_INVALID_VAR_SYNTAX
    jmp  error

parse_cmp_op:                   ; -> cond_op
    call skip_blanks
    cmp  rsi, r12
    jae  .syntax
    movzx eax, byte [rsi]
    inc  rsi
    cmp  al, '='
    je   .eq
    cmp  al, '!'
    je   .ne
    cmp  al, '<'
    je   .lt
    cmp  al, '>'
    je   .gt
.syntax:
    mov  bx, ERR_INVALID_VAR_SYNTAX
    jmp  error
.eq:
    mov  byte [cond_op], 1
    jmp  .need_eq
.ne:
    mov  byte [cond_op], 2
.need_eq:                       ; "==" and "!=": the second character has to be '='
    cmp  rsi, r12
    jae  .syntax
    cmp  byte [rsi], '='
    jne  .syntax
    inc  rsi
    ret
.lt:
    mov  byte [cond_op], 3
    mov  cl, 5
    jmp  .maybe_eq
.gt:
    mov  byte [cond_op], 4
    mov  cl, 6
.maybe_eq:                      ; "<=" / ">="
    cmp  rsi, r12
    jae  .done
    cmp  byte [rsi], '='
    jne  .done
    inc  rsi
    mov  [cond_op], cl
.done:
    ret

; the rest of an if / elif / else line: ':' and then nothing (a comment is fine)
expect_colon_end:
    call skip_blanks
    cmp  rsi, r12
    jae  .no
    cmp  byte [rsi], ':'
    jne  .no
    inc  rsi
    jmp  expect_end
.no:
    mov  bx, ERR_EXPECT_COLON
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
