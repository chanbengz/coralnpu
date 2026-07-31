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
  /*
   * Inputs are positive fixed-point scheduling stand-ins, not literal softmax
   * logits. x^2 + x + 2 represents the vector kernel's polynomial exp stage;
   * 1024/sum(exp) represents its fixed-point reciprocal.
   */
  li a0, 1
  li a1, 2
  li a2, 3
  li a3, 4
  li a4, 1024
  li s8, 0
  li s9, 64

  csrw mcycle, zero

  .balign 16
1:
  .rept 4
  /*
   * Context A: approximate exp, reduce, then start reciprocal division.
   * The two contexts model different heads or Q blocks. They are not
   * consecutive KV tiles from one online-softmax recurrence.
   */
  mul t0, a0, a0
  add t1, t0, a0
  addi t1, t1, 2
  mul t2, a1, a1
  add t3, t2, a1
  addi t3, t3, 2
  add t4, t1, t3
  div t5, a4, t4
  mul t6, t1, t5

  /*
   * Context B is independent of Context A's reciprocal. The in-order dispatcher
   * stalls here behind t5; the OOO window can execute this exp/reduction work.
   */
  mul s0, a2, a2
  add s1, s0, a2
  addi s1, s1, 2
  mul s2, a3, a3
  add s3, s2, a3
  addi s3, s3, 2
  add s4, s1, s3
  div s5, a4, s4
  mul s6, s1, s5

  /* Consume one normalized output from each independent context. */
  add s7, t6, s6
  add s8, s8, s7
  .endr
  addi s9, s9, -1
  bnez s9, 1b

  la t0, benchmark_checksum
  sw s8, 0(t0)

  /* 256 * ((4 * (1024 / 12)) + (14 * (1024 / 36))) = 187392. */
  li t0, 187392
  bne s8, t0, 2f
  li t0, 1
  j 3f
2:
  li t0, 3
3:
  la t1, tohost
  sw t0, 0(t1)
  .word 0x08000073  /* mpause */
4:
  j 4b
  .size _start, .-_start

  .section .data, "aw", @progbits
  .balign 16
  .global benchmark_checksum
benchmark_checksum:
  .word 0

  .section .htif, "aw", @progbits
  .balign 16
  .global tohost
tohost:
  .word 0
