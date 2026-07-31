OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
  ITCM (rx)  : ORIGIN = 0x00000000, LENGTH = 8K
  DTCM (rw)  : ORIGIN = 0x00010000, LENGTH = 32K
}

SECTIONS {
  .text : ALIGN(16) {
    *(.text._start)
    *(.text .text.*)
  } > ITCM

  .data : ALIGN(16) {
    *(.data .data.*)
  } > DTCM

  .htif : ALIGN(16) {
    KEEP(*(.htif))
  } > DTCM
}
