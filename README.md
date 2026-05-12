
A robust ATM Machine simulation written in 8086 Assembly (TASM) for DOSBox. Features file-based account persistence, PIN authentication with auto-blocking, transaction history tracking, and a hidden admin interface. 

---

### README.md

# 8086 Assembly ATM Simulation

A fully functional ATM machine simulation written in 8086 Assembly. Designed to be compiled with Turbo Assembler (TASM) and run within DOSBox, this project demonstrates file I/O operations, string parsing, mathematical constraints, and basic session management in Assembly.

## Features

* **Account Management:** Automatically creates a new account with a default balance of $1,000 and PIN `1234` if the entered account number doesn't exist.
* **Persistent Storage:** Uses text-based `.DAT` files to save account details (balances, PINs, block status) and transaction histories. 
* **Secure Login:** PIN authentication system that automatically blocks the account after 3 failed attempts.
* **Transaction Constraints:** * Withdrawals must be in multiples of 100.
  * Minimum withdrawal: $200.
  * Maximum withdrawal: $50,000.
  * Checks for insufficient funds.
* **Transaction History:** Parses and displays a log of previous deposits, withdrawals, and PIN changes.
* **Admin Mode:** A hidden administrator menu to unblock locked accounts.

## Prerequisites

To build and run this project, you will need:
* **DOSBox:** An emulator for DOS (e.g., DOSBox 0.74-3).
* **TASM 4.1:** Borland Turbo Assembler and TLINK.

## How to Build and Run

1. Mount your local directory containing the source code in DOSBox.
2. Compile the assembly file (`atmfinal.asm` or `ks.asm`) using TASM:
   ```dos
   tasm ks.asm
