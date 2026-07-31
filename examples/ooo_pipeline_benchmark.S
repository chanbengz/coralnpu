/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * https://www.apache.org/licenses/LICENSE-2.0
 */

  .option norvc

  .section .text._start, "ax", @progbits
  .balign 16
  .global _start
  .type _start, @function
_start:
  li a0, 1000
  li a1, 7
  li a2, 3
  li a3, 11
  li a4, 13
  li a5, 17
  li a6, 19
  li t4, 0
  li t6, 64

  csrw mcycle, zero

  .balign 16
1:
  .rept 4
  div t0, a0, a1
  add t1, t0, a2
  add t2, a3, a4
  add t3, a5, a6
  xor s0, a3, a5
  or s1, a4, a6
  and s2, a3, a6
  sub s3, a5, a4
  xor s4, a3, a6
  or s5, a3, a4
  and s6, a5, a6
  sub s7, a6, a3
  add s8, a3, a6
  xor s9, a4, a5
  or s10, a3, a5
  add t4, t4, t1
  .endr
  addi t6, t6, -1
  bnez t6, 1b

  csrr s5, mcycle
  la t5, benchmark_cycles
  sw s5, 0(t5)
  la t5, benchmark_checksum
  sw t4, 0(t5)

  li t5, 37120
  bne t4, t5, 2f
  li t5, 1
  j 3f
2:
  li t5, 3
3:
  la t6, tohost
  sw t5, 0(t6)
  .word 0x08000073  /* mpause */
4:
  j 4b
  .size _start, .-_start

  .section .data, "aw", @progbits
  .balign 16
  .global benchmark_cycles
benchmark_cycles:
  .word 0
  .global benchmark_checksum
benchmark_checksum:
  .word 0

  .section .htif, "aw", @progbits
  .balign 16
  .global tohost
tohost:
  .word 0
