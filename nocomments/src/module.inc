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
