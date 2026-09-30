compile:
    mov rsi, buffer
    mov rdx, [bytes_read]
    add rdx, rsi
    mov ah, 0x0
    mov bx, 0x0
    mov rdi, 0x0
    mov r14, 0x0

; From this point on is the compiler for the code.
; The functions are as follows:
; if ### % ###: - Basic logic, depends on a boolean value, represented here by hashes for the values and a % for the type of comparison operation.
; elif ### % ###: - More logic, allowing nested if-else conditions to be replaced with a single, longer block of code. Identical in functionality to the 'if' function.
; else: - Function for what happens should an if condition and all elif conditions are not met.
; while ### % ###: - Loop that continues until a condition is not met
; until ### % ###: - Loop that continues until a contition is met
; for @ = *: - Loop that continues until a value, here represented as an @, is equal to a number, represented as an *.
; var num/str/lstr @@@ [= *] - Defines a variable. Its name is represented here as '@@@', and the brackets show an optional way of defining the variable immediately. Otherwise, the variable is initialized to 0 or '0'. Num sets the variable type to a number. Str sets the variable type to a string, at most 8 characters. Lstr sets the variable type to a long string, using RAM space to store the value. Lstr variables are slower, but can contain much more data at once.
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
.func_logic:
    cmp rsi, rdx
    jae .end_of_file
    
    mov al, [rsi]
    cmp al, 0xA
    je .newline
    cmp r14, 0x0001
    je .next_char
    jmp .var_detect
.newline:
    cmp r14, 0x0001
    je .clear_flag_cmmt
    ; Honestly I'm pretty sure newlines clear all flags EXCEPT triple hash, which triggers a multiline comment. That's the only one I think.
.clear_flag_cmmt:
    mov r14, 0x0000

.var_detect:
    ; Variable detection logic
    ; Since variables can be named with any character, we first need to check the current token to see if it is a variable or a function. We start by checking the characters of the token to see if it matches any variable names, and if it does, we assume it is a variable. One exception to this rule is if the variable name is the same as a function name, in which case we cross-check it to see if that line has a function already in use. If so, we assume the token to be a variable, and if not, we assume it to be a function. In the case a variable is named the same as a function, we look at the context to determine the meaning. For example, use the term 'if if == 0'. As the function 'if' is already in use, we know that the second 'if' is the variable, assuming 'if' is a valid variable. However, in the term 'if = 0', we can see that the term 'if' is using the incorrect syntax for a function, and we assume it is a variable if it is a valid variable. It it is not a valid variable, we assume it is a function and give the user an 'invalid syntax' error.
    ; Variables are defined in a table at the location 0xF000 in RAM. This address shows the number of variables defined. The variable's type, represented as a '0' for a number, '1' for a string, and '2' for a long string, is next. The following address is the length of the variable name, followed by the name itself. The type of the variable changes what the next byte means; for a number, the next 8 bytes are the number's value. For a standard string, the next 8 bytes are the string's value. For a long string, the next 8 bytes are the length of the string, followed by the string's value. 
    ; For example, a number variable named 'myVar' with the value of 123 would be formatted as this: 
    ; [0xF000] = 1 (number of variables)
    ; The following bytes are repeated per-variable:
    ; [0xF001] = 5 (length of variable name)
    ; [0xF002] = 0 (type of variable, 0 for number, 1 for string, 2 for long string)
    ; [0xF003] = 'm'
    ; [0xF004] = 'y'
    ; [0xF005] = 'V'
    ; [0xF006] = 'a'
    ; [0xF007] = 'r'
    ; [0xF008] through [0xF015] = 123 (value of myVar, 8 bytes)
    mov ah, [0xF000]
    cmp ah, 0
    je .func_detect
    mov r8, ah ; Faster to copy the number of variables to a register than to reread it from RAM.
    mov r9, 1 ; Used for looping through variables. Starts at 1, as the number of variables starts at 1, and the number and counter are more easily read if they line up at 0.
    mov rdi, 0x1
    movzx rcx, byte [0xF000 + rdi]
    inc rdi
    movzx r10, byte [0xF000 + rdi]
    inc rdi
    cmp byte [0xF000 + rdi], al
    je .var_found
    cmp r8, r9 
    jne .next_var ; Used for looping through variables.
    jmp .func_detect ; If we have looped through all the variables and not found a match, we assume it is a function.
.next_var:
    inc r9
    add rdi, rcx
    cmp r10, 2 ; If the variable is a long string, we need to read the 8-byte length field byte-by-byte, then skip the value bytes.
    je .long_string_length
    add rdi, 8 ; Skip the fixed-size value of the variable, as we don't need to check it.
    jmp .check_next_var
.long_string_length:
    xor r11, r11 ; Clear the accumulator used for the long-string length.
    xor r12, r12 ; Clear the byte counter for the length field.
.long_string_length_loop:
    movzx r13, byte [0xF000 + rdi]
    shl r11, 8
    or r11, r13
    inc rdi
    inc r12
    cmp r12, 8
    jb .long_string_length_loop
    add rdi, r11 ; Skip the long-string payload using the decoded length.
    jmp .check_next_var
.check_next_var:
    movzx rcx, byte [0xF000 + rdi]
    inc rdi
    movzx r10, byte [0xF000 + rdi]
    inc rdi
    cmp byte [0xF000 + rdi], al
    je .var_found
    cmp r8, r9
    jne .next_var
    jmp .func_detect
.var_found:
    ; This could be a variable, but it could also be a function with the same first letter. We need to check the next digits to see if the token's value matches this variable's name. If so, we cross-check with active flags (0x0000 for a newline, 0x0001:0x02C for functions, etc.) to see if a function is in use. If so, we scan through the rest of the line to see if the line contains the correct syntax for the function. If not, we throw an error. If so, we write the code for retrieving the variable's value from the RAM, and substitute it in.
    dec rdi
    mov ah, [0xF000 + rdi]
    inc rdi
    cmp [0xF000 + rdi], al
.func_detect:
    cmp al, '#'
    je .comment
    cmp al, 'i'
    je .if_func
    cmp al, 'e'
    je .elif_else_func
    cmp al, 'w'
    je .while_func
    cmp al, 'u'
    je .until_func
    cmp al, 'f'
    je .f_func
    cmp al, 'v'
    je .var_func_det
    cmp al, 'b'
    je .bool_func
    cmp al, 'd'
    je .def_func
    cmp al, 'i'
    je .import_func
    cmp al, 'm'
    je .mem_func
.f_func:
    cmp byte [rsi + 1], 'o'
    jne .fs_func_det
    cmp byte [rsi + 2], 'r'
    jne .incomplete_for_func
    jmp .for_func
.fs_func_det:
    cmp byte [rsi + 1], 's'
    jne .incomplete_f_func
    jmp .fs_func
.elif_else_func_det:
    cmp byte [rsi + 1], 'l'
    jne .incomplete_el_func
    cmp byte [rsi + 2], 'i'
    jne .else_func_det
    cmp byte [rsi + 3], 'f'
    jne .incomplete_elif_func
    jmp .elif_func
.else_func_det:
    cmp byte [rsi + 2], 's'
    jne .incomplete_el_func
    cmp byte [rsi + 3], 'e'
    jne .incomplete_else_func
    jmp .else_func
.var_func_det:
    cmp byte [rsi + 1], 'a'
    jne .incomplete_var_func
    cmp byte [rsi + 2], 'r'
    jne .incomplete_var_func
    cmp byte [rsi + 3], ' '
    jne .invalid_var_func_sntx
    jmp .var_func
.next_char:
    inc rsi
    jmp .func_logic
.standard_compile:
    ; Standart compilation flag setup
.shell_compile:
    ; Shell compilation flag setup
.core_compile:
    ; Core compilation flag setup
.end_of_file:
    ; End of file reached. Compilation complete.
.incomplete_el_func:
    mov bx, 0x0000
    jmp error
.incomplete_elif_func:
    mov bx, 0x0001
    jmp error
.incomplete_else_func:
    mov bx, 0x0002
    jmp error
.incomplete_for_func:
    mov bx, 0x0003
    jmp error
.incomplete_f_func:
    mov bx, 0x0004
    jmp error
.invalid_var_func_sntx:
    mov bx, 0x0005
    jmp error
.comment:
    mov r14, 0x0001
    jmp .next_char
.if_func:
    mov r14, 0x0002
    jmp .next_char
.elif_func:
    mov r14, 0x0003
    jmp .next_char
.else_func:
    mov r14, 0x0004
    jmp .next_char