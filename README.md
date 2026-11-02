# Forth-1968-CM

**Public domain.**

Charles H. Moore's original Forth, written in 1968 for the IBM 1130. The name on the scan is FORTH. This Xcode project holds a transcription of that 16-page scan and a Mac program that assembles the kernel, loads the Forth deck, and runs it.

The Mac program simulates the IBM 1130 instructions, disk, and Selectric console that this kernel uses. It then starts at the real entry point and lets the 1968 program compile and run itself.

## Run it

Open `Forth-1968-CM.xcodeproj` and press ⌘R.

Xcode builds the tool and opens Terminal. The debug console prints `Forth is running in Terminal.` and that Run ends. The session is the Terminal window.

The window then prints:

```text
Assembled FORTH.asm: 0900–0DC3, entry 09FA, listing matches.
First disk record: .DEP LOC DEPOSIT, .DEPOSIT IC INC=,
HI THERE
```

`HI THERE` is the deck reaching its last line, `HOME 'HI THERE' REPLY CONSOLE`. The console is waiting. There is no prompt.

Type in that window, in upper case, and press Return after each word. Press Control-D to end the program. It prints `end of input` and exits. Closing the window stops it too.

If you launch the built tool yourself from Terminal, it runs in that same window.

## Typing

A dictionary name is four characters. `CONSOLE` is stored as `CONS`. When two words share those four letters, the later one runs. `CONSOLE` is later than `CONSTANT`, so `CONS` is `CONSOLE`.

`$` is an ordinary word. It is defined as `'OK' REPLY`, and it prints `OK`. The terminal shows the character you typed, and the 1130 prints it again, so the word can appear twice.

```text
$
'HELLO' REPLY
WARN
```

`$` prints `OK`. `'HELLO' REPLY` prints `HELLO`. `WARN` prints `NO SUCH FILE`.

A period starts a definition and a comma ends it, which is how the deck is written:

```text
.HI 'HELLO' REPLY,
HI
```

`DUP` `DROP` `SWAP` `MINUS` `+` `-` `*` `/` `AND` and a hex number such as `2A` are real words. The deck has no word that prints a number.

The disk words are `CREATE` `ACTIVATE` `DELETE` `RETRIEVE` `EXAMINE` `EMPLACE` `SEARCH` `WRITE` `HOME`. `FILL` waits for another line of typing.

Every name defined in `FO.FO`, and the kernel dictionary at the end of `FORTH.asm`, can be typed. The deck itself is the word list.

## What the scan is

`Resources/FORTH-1968-CM.pdf` is the scan. The transcription follows the printed text. Handwriting is notes. `Resources/TRANSCRIPTION.txt` records the page map and the places where the paper was clipped or marked in ink.

| Pages | What they are |
| --- | --- |
| 1 | Assembler listing, page 1. The red ink across the top reads FORTH ORIGINAL 1130. |
| 2–5 | Disk dump of the Forth program. The dump title is FO.FO. |
| 6–16 | Assembler listing, pages 2–12. It ends with `END START-1`. |

## Files

```text
Forth-1968-CM.xcodeproj
Forth-1968-CM/
  main.swift            load, check the listing, run, open Terminal from Xcode
  Assembler.swift       IBM 1130 assembler for the kernel
  Machine.swift         1130 CPU, disk, printer, and keyboard
  Resources/
    FORTH-1968-CM.pdf   the scan
    FORTH.asm           kernel source
    FO.FO               the Forth deck
    listing/            assembler object listing, one file per scan page
    TRANSCRIPTION.txt   notes on the scan
```

`FORTH.asm` is the kernel. Addresses and object code live in `listing/`, and the assembler checks every assembled word against that listing. A mismatch stops the run before the machine starts.

`FO.FO` is the deck. A dot begins a definition and a comma ends one. `OPERATION` introduces a code word, the cent sign in later Forth. Whitespace separates words, and a new line is whitespace. The sequence numbers printed down the left of the dump are not in the file.

The kernel reads that deck from a simulated disk, last record slot first, the same way the 1130 program does. The first record it accepts is `.DEP LOC DEPOSIT, .DEPOSIT IC INC=,`.
