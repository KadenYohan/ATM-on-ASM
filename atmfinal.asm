; ======================================================================
; ATM MACHINE — 8086 / TASM 4.1 / DOSBox 0.74-3
; Build:  tasm ks.asm
;         tlink ks.obj
; Run:    ks.exe
; Files per account:
;   A####.DAT = ACC(2) | PIN(2) | BAL(2) | BLOCK(1) | ATT(1)
;   H####.DAT = append entries: [Type(1)][AmountLo(1)][AmountHi(1)] (LE)
; Exit program when account number 0000 is entered.
; Admin account: 9999 (PIN 1337)
; ======================================================================

.MODEL  SMALL
.STACK  200h

.DATA
; ---- strings ----
msg_welcome     DB 0Dh,0Ah,'============================',0Dh,0Ah
                DB '  ATM MACHINE SIMULATION  ',0Dh,0Ah
                DB '============================$'
msg_note        DB 0Dh,0Ah,'(Note: All amounts limited to 65,535)$',0
msg_enter_acct  DB 0Dh,0Ah,'Enter Account Number (0000 to exit, 9999 for Admin): $'
msg_pin         DB 0Dh,0Ah,'Enter PIN: $'
msg_wrong       DB 0Dh,0Ah,'Invalid PIN!$',0
msg_blocked     DB 0Dh,0Ah,'Account blocked! Contact administrator.$',0
msg_menu        DB 0Dh,0Ah,0Dh,0Ah,'--- ATM MENU ---',0Dh,0Ah
                DB '1. Show Balance',0Dh,0Ah
                DB '2. Deposit',0Dh,0Ah
                DB '3. Withdraw',0Dh,0Ah
                DB '4. Change PIN',0Dh,0Ah
                DB '5. Transaction History',0Dh,0Ah
                DB '6. Logout',0Dh,0Ah,0Dh,0Ah
                DB 'Enter choice: $'
msg_balance     DB 0Dh,0Ah,'Balance: $'
msg_enter_amt   DB 0Dh,0Ah,'Enter amount: $'
msg_min_wdraw   DB 0Dh,0Ah,'Minimum withdrawal is 200.$'
msg_max_wdraw   DB 0Dh,0Ah,'Maximum withdrawal is 50,000.$'
msg_mult_wdraw  DB 0Dh,0Ah,'Withdrawal must be in multiples of 100.$'
msg_no_funds    DB 0Dh,0Ah,'Insufficient funds.$'
msg_pin_changed DB 0Dh,0Ah,'PIN changed.$'
msg_hist_hdr    DB 0Dh,0Ah,'=== TRANSACTION HISTORY ===$',0
msg_hist_dep    DB 0Dh,0Ah,'Deposit: +$',0
msg_hist_wdr    DB 0Dh,0Ah,'Withdraw: -$',0
msg_hist_pin    DB 0Dh,0Ah,'PIN change recorded.',0
msg_hist_none   DB 0Dh,0Ah,'No transactions.',0
msg_exit        DB 0Dh,0Ah,0Dh,0Ah,'Goodbye!$',0
; --- admin strings ---
msg_admin_pin   DB 0Dh,0Ah,'Enter Admin PIN: $'
msg_admin_menu  DB 0Dh,0Ah,'Enter Account Number to unblock: $'
msg_admin_ok    DB 0Dh,0Ah,'Account unblocked. Press any key to continue.$'
msg_admin_nok   DB 0Dh,0Ah,'Account was not blocked. Press any key to continue.$'
newline         DB 0Dh,0Ah,'$'

; filenames (digits replaced)
acct_name       DB 'A0000.DAT',0
hist_name       DB 'H0000.DAT',0

RECSZ           EQU 8
TYPE_DEP        EQU 1
TYPE_WDR        EQU 2
TYPE_PIN        EQU 3

; session state
curr_acc        DW 0
curr_pin        DW 1234
curr_bal        DW 1000
curr_block      DB 0
curr_att        DB 0

; scratch / IO buffers
fh              DW ?
buf3            DB 3 DUP(?)          ; [type][amount_lo][amount_hi]
accbuf          DB RECSZ DUP(?)

; robust capture for history write
tmp_type        DB 0
tmp_amount      DW 0

.CODE

; ===== small helpers =====
ClearScreen PROC
    push ax bx cx dx
    mov ax,0600h
    xor cx,cx
    mov dx,184Fh
    mov bh,07h
    int 10h
    mov ah,02h
    xor bh,bh
    xor dx,dx
    int 10h
    pop dx cx bx ax
    ret
ClearScreen ENDP

PrintStr PROC
    push ax            ; PRESERVE AX so caller's value survives
    mov  ah,09h
    int  21h
    pop  ax
    ret
PrintStr ENDP

InputNum PROC
    push bx
    push cx
    push dx
    xor dx,dx
IN_read:
    mov ah,01h
    int 21h
    cmp al,0Dh
    je  IN_done
    cmp al,'0'
    jb  IN_read
    cmp al,'9'
    ja  IN_read
    sub al,'0'
    mov bl,al
    xor bh,bh
    mov ax,dx
    mov cx,10
    mul cx
    add ax,bx
    mov dx,ax
    jmp IN_read
IN_done:
    mov ax,dx
    pop dx
    pop cx
    pop bx
    ret
InputNum ENDP

PrintNum PROC
    push ax
    push bx
    push cx
    push dx
    xor cx,cx
    mov bx,10
PN_div:
    xor dx,dx
    div bx
    push dx
    inc cx
    or  ax,ax
    jne PN_div
PN_out:
    pop dx
    add dl,'0'
    mov ah,02h
    int 21h
    dec cx
    jnz PN_out
    pop dx
    pop cx
    pop bx
    pop ax
    ret
PrintNum ENDP

; ===== filenames from curr_acc =====
MakeNames PROC
    push ax bx cx dx si di
    mov ax,curr_acc
    mov si,OFFSET acct_name
    inc si
    mov bx,1000
    xor dx,dx
    div bx                ; thousands
    add al,'0'
    mov [si],al
    inc si
    mov ax,dx
    mov bx,100
    xor dx,dx
    div bx                ; hundreds
    add al,'0'
    mov [si],al
    inc si
    mov ax,dx
    mov bx,10
    xor dx,dx
    div bx                ; tens
    add al,'0'
    mov [si],al
    inc si
    add dl,'0'            ; units
    mov [si],dl

    ; copy digits to hist_name
    mov si,OFFSET hist_name
    inc si
    mov di,OFFSET acct_name
    inc di
    mov cx,4
MN_cp:
    mov al,[di]
    mov [si],al
    inc si
    inc di
    loop MN_cp
    pop di si dx cx bx ax
    ret
MakeNames ENDP

; ===== open/create read-write =====
OpenRW PROC                 ; DS:DX filename; OUT AX=handle CF=0
    mov ah,3Dh
    mov al,2
    int 21h
    jnc OR_ok
    mov ah,3Ch
    xor cx,cx
    int 21h
    jc  OR_fail
OR_ok:  clc
    ret
OR_fail: stc
    ret
OpenRW ENDP

; ===== account persistence =====
SaveAccount PROC
    push ax bx cx dx
    call MakeNames
    lea dx,acct_name
    call OpenRW
    jc  SA_out
    mov fh,ax
    mov ax,curr_acc
    mov WORD PTR [accbuf+0],ax
    mov ax,curr_pin
    mov WORD PTR [accbuf+2],ax
    mov ax,curr_bal
    mov WORD PTR [accbuf+4],ax
    mov al,curr_block
    mov BYTE PTR [accbuf+6],al
    mov al,curr_att
    mov BYTE PTR [accbuf+7],al
    ; seek start
    mov ah,42h
    xor al,al
    xor cx,cx
    xor dx,dx
    mov bx,fh
    int 21h
    ; write record
    mov ah,40h
    mov bx,fh
    mov cx,RECSZ
    lea dx,accbuf
    int 21h
    ; close
    mov ah,3Eh
    mov bx,fh
    int 21h
SA_out:
    pop dx cx bx ax
    ret
SaveAccount ENDP

LoadAccount PROC
    push ax bx cx dx
    call MakeNames
    lea dx,acct_name
    mov ah,3Dh
    mov al,0
    int 21h
    jc  LA_new
    mov fh,ax
    mov ah,3Fh
    mov bx,fh
    mov cx,RECSZ
    lea dx,accbuf
    int 21h
    cmp ax,RECSZ
    jne LA_close
    mov ax,WORD PTR [accbuf+0]
    mov curr_acc,ax
    mov ax,WORD PTR [accbuf+2]
    mov curr_pin,ax
    mov ax,WORD PTR [accbuf+4]
    mov curr_bal,ax
    mov al,BYTE PTR [accbuf+6]
    mov curr_block,al
    mov al,BYTE PTR [accbuf+7]
    mov curr_att,al
LA_close:
    mov ah,3Eh
    mov bx,fh
    int 21h
    jmp short LA_out
LA_new:
    mov curr_pin,1234
    mov curr_bal,1000
    mov curr_block,0
    mov curr_att,0
    call SaveAccount
LA_out:
    pop dx cx bx ax
    ret
LoadAccount ENDP

; ===== history (robust, explicit little-endian) =====
AppendHist PROC              ; IN: CL=type, AX=amount
    mov  tmp_type, cl
    mov  tmp_amount, ax

    call MakeNames
    lea  dx, hist_name
    call OpenRW
    jc   AH_exit
    mov  fh, ax

    ; seek end
    mov  ah,42h
    mov  al,2
    xor  cx,cx
    xor  dx,dx
    mov  bx,fh
    int  21h

    ; build 3 bytes [type][lo][hi]
    mov  al, tmp_type
    mov  [buf3],   al
    mov  ax, tmp_amount
    mov  [buf3+1], al   ; low
    mov  [buf3+2], ah   ; high

    ; write 3 bytes
    mov  ah,40h
    mov  bx,fh
    mov  cx,3
    lea  dx,buf3
    int  21h

    ; close
    mov  ah,3Eh
    mov  bx,fh
    int  21h
AH_exit:
    ret
AppendHist ENDP

ShowHist PROC
    push ax bx cx dx
    call MakeNames
    lea  dx,hist_name
    mov  ah,3Dh
    mov  al,0
    int  21h
    jc   SH_none
    mov  fh,ax
    lea  dx,msg_hist_hdr
    call PrintStr
SH_loop:
    mov  ah,3Fh
    mov  bx,fh
    mov  cx,3
    lea  dx,buf3
    int  21h
    cmp  ax,3
    jne  SH_done

    mov  bl,[buf3]         ; type
    mov  al,[buf3+1]       ; amount low
    mov  ah,[buf3+2]       ; amount high -> AX = amount

    cmp  bl,TYPE_DEP
    jne  SH_notDep
    lea  dx,msg_hist_dep
    call PrintStr
    call PrintNum
    jmp  short SH_nl

SH_notDep:
    cmp  bl,TYPE_WDR
    jne  SH_isPin
    lea  dx,msg_hist_wdr
    call PrintStr
    call PrintNum
    jmp  short SH_nl

SH_isPin:
    cmp  bl,TYPE_PIN
    jne  SH_nl
    lea  dx,msg_hist_pin
    call PrintStr

SH_nl:
    lea  dx,newline
    call PrintStr
    jmp  SH_loop

SH_done:
    mov  ah,3Eh
    mov  bx,fh
    int  21h
    jmp  short SH_exit

SH_none:
    lea  dx,msg_hist_none
    call PrintStr
SH_exit:
    pop  dx cx bx ax
    ret
ShowHist ENDP

; ===== UI procedures =====
AskAccount PROC               ; OUT AX=account (0 to exit)
    lea dx,msg_enter_acct
    call PrintStr
    call InputNum
    ret
AskAccount ENDP

PinAuth PROC                  ; OUT CF=1 fail/blocked, CF=0 success
    cmp curr_block,0
    jne PA_blocked
PA_loop:
    lea dx,msg_pin
    call PrintStr
    call InputNum
    cmp ax,curr_pin
    jne PA_bad
    mov curr_att,0
    call SaveAccount
    clc
    ret
PA_bad:
    mov al,curr_att
    inc al
    mov curr_att,al
    call SaveAccount
    lea dx,msg_wrong
    call PrintStr
    cmp al,3
    jb  PA_loop
    mov curr_block,1
    call SaveAccount
PA_blocked:
    lea dx,msg_blocked
    call PrintStr
    mov ah,01h
    int 21h
    stc
    ret
PinAuth ENDP

DoShowBalance PROC
    lea dx,msg_balance
    call PrintStr
    mov ax,curr_bal
    call PrintNum
    ret
DoShowBalance ENDP

DoDeposit PROC
    lea dx,msg_enter_amt
    call PrintStr
    call InputNum
    cmp ax,0
    je  DD_done
    push ax
    add curr_bal,ax
    call SaveAccount
    pop ax
    mov cl,TYPE_DEP
    xor ch,ch
    call AppendHist
DD_done:
    ret
DoDeposit ENDP

DoWithdraw PROC
    lea dx,msg_enter_amt
    call PrintStr
    call InputNum
    mov bx,ax
    mov cx,100
    xor dx,dx
    mov ax,bx
    div cx
    cmp dx,0
    jne DW_mult
    cmp bx,200
    jb  DW_min
    cmp bx,50000
    ja  DW_max
    cmp bx,curr_bal
    ja  DW_nof
    sub curr_bal,bx
    call SaveAccount
    mov ax,bx
    mov cl,TYPE_WDR
    xor ch,ch
    call AppendHist
    ret
DW_mult: lea dx,msg_mult_wdraw
         call PrintStr
         ret
DW_min:  lea dx,msg_min_wdraw
         call PrintStr
         ret
DW_max:  lea dx,msg_max_wdraw
         call PrintStr
         ret
DW_nof:  lea dx,msg_no_funds
         call PrintStr
         ret
DoWithdraw ENDP

DoChangePin PROC
    lea dx,msg_pin
    call PrintStr
    call InputNum
    mov curr_pin,ax
    call SaveAccount
    xor ax,ax
    mov cl,TYPE_PIN
    xor ch,ch
    call AppendHist
    lea dx,msg_pin_changed
    call PrintStr
    ret
DoChangePin ENDP

MenuLoop PROC                 ; returns when user chooses Logout
ML_again:
    call ClearScreen
    lea dx,msg_menu
    call PrintStr
    call InputNum
    cmp ax,1
    jne ML_c2
    call DoShowBalance
    jmp short ML_wait
ML_c2:
    cmp ax,2
    jne ML_c3
    call DoDeposit
    jmp short ML_again
ML_c3:
    cmp ax,3
    jne ML_c4
    call DoWithdraw
    jmp short ML_wait
ML_c4:
    cmp ax,4
    jne ML_c5
    call DoChangePin
    jmp short ML_wait
ML_c5:
    cmp ax,5
    jne ML_c6
    call ShowHist
    jmp short ML_wait
ML_c6:
    ; any value other than 1..5 means Logout
    ret
ML_wait:
    lea dx,newline
    call PrintStr
    mov ah,01h
    int 21h
    jmp ML_again
MenuLoop ENDP

; ===== MAIN =====
MAIN PROC
    mov ax,@DATA
    mov ds,ax

    call ClearScreen
    lea dx,msg_welcome
    call PrintStr
    lea dx,msg_note
    call PrintStr
    lea dx,newline
    call PrintStr
    mov ah,01h
    int 21h

MAIN_accountLoop:
    call ClearScreen
    call AskAccount
    or  ax,ax
    jz  MAIN_exitProgram
    cmp ax,9999
    je  MAIN_adminMenu
    mov curr_acc,ax
    call LoadAccount
    call PinAuth
    jc  MAIN_accountLoop
    call MenuLoop
    jmp short MAIN_accountLoop

MAIN_adminMenu:
    lea dx,msg_admin_pin
    call PrintStr
    call InputNum
    cmp ax,1337
    jne MAIN_accountLoop
ADM_unblock:
    lea dx,msg_admin_menu
    call PrintStr
    call InputNum
    cmp ax,0
    je  MAIN_accountLoop
    cmp ax,9999
    je  MAIN_accountLoop
    mov curr_acc,ax
    call LoadAccount
    cmp curr_block,0
    je  ADM_notblocked
    mov curr_block,0
    mov curr_att,0
    call SaveAccount
    lea dx,msg_admin_ok
    call PrintStr
    mov ah,01h
    int 21h
    jmp MAIN_accountLoop
ADM_notblocked:
    lea dx,msg_admin_nok
    call PrintStr
    mov ah,01h
    int 21h
    jmp MAIN_accountLoop

MAIN_exitProgram:
    call ClearScreen
    lea dx,msg_exit
    call PrintStr
    mov ah,4Ch
    int 21h
MAIN ENDP

END MAIN
