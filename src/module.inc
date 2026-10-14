; =============================================================================
;  module.inc - shared start of a self-contained module (decoders, parsers)
;
;  A module (h264.asm, aac.asm, jpeg.asm, ...) is pure computation: it gets
;  its input and its memory from the caller and calls nothing outside
;  itself, so the very same source is
;    - %included into the full kernel (kernel.asm), and
;    - assembled on its own as a 32-bit ELF object (nasm -f elf32 -DNATIVE)
;      and linked with a C test program on Linux (tests/native/), where it
;      is checked against reference decoders (ffmpeg, zlib, Pillow).
;  Its functions use the C calling convention (CENTER / CLEAVE / ARG in
;  macros.inc): arguments on the stack, EBX ESI EDI EBP kept, the result in
;  EAX. EXPORT(name) makes a function visible to the C test program.
; =============================================================================
%ifndef MODULE_INC
%define MODULE_INC
%ifdef NATIVE
bits 32
%include "src/macros.inc"
%define EXPORT(x) global x
%else
%define EXPORT(x)
%endif
%endif
