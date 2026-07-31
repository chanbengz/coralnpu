// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package coralnpu

import chisel3._
import chisel3.util._

/** Decode helpers for the conservative out-of-order issue domain.
  *
  * Memory, control-flow, CSR, floating-point, and vector instructions remain on the legacy in-order
  * path. Keeping those instructions as issue-window boundaries avoids memory disambiguation and
  * speculative recovery while still allowing the scalar core to hide long multiply/divide stalls
  * with independent integer work.
  */
object OutOfOrderIssue {
  def isSafeScalarArithmetic(p: Parameters, instruction: FetchInstruction): Bool = {
    val decoded = DecodeInstruction(p, 0, instruction.addr, instruction.inst, 0.U(3.W))
    decoded.isAlu() || decoded.isMul() || decoded.isDvu()
  }
}

/** Compact metadata decoded once when an instruction enters the issue window. */
class OutOfOrderIssueEntry(p: Parameters) extends Bundle {
  val instruction = new FetchInstruction(p)
  val readsRs1    = Bool()
  val readsRs2    = Bool()
  val isMlu       = Bool()
  val isDvu       = Bool()
}

class OutOfOrderIssueQueueIO(p: Parameters, entries: Int) extends Bundle {
  val enq = Vec(p.instructionLanes, Flipped(Decoupled(new FetchInstruction(p))))
  // The connected DispatchV2 sink accepts every valid selected operation in a
  // cycle or accepts none. This all-or-none contract keeps an unaccepted
  // selection resident without needing a second grant-holding structure.
  val issue = Vec(p.instructionLanes, Decoupled(new FetchInstruction(p)))

  // Registers owned by already-issued operations. The queue separately checks
  // dependencies against all older, not-yet-issued entries.
  val scoreboard = Input(UInt(p.scalarRegCount.W))

  // Multi-cycle units are single-issue and can only be decoded in lane zero.
  val mluReady = Input(Bool())
  val dvuReady = Input(Bool())

  // Squash all queued instructions in lockstep with the retirement buffer.
  val flush = Input(Bool())

  val empty     = Output(Bool())
  val nEnqueued = Output(UInt(log2Ceil(entries + 1).W))
  val nSpace    = Output(UInt(log2Ceil(entries + 1).W))
}

/** An age-ordered, compacting issue window for scalar integer arithmetic.
  *
  * The window allocates instructions in program order, then selects the oldest ready instructions
  * for issue. RAW, WAR, and WAW checks against older queued instructions make execution safe
  * without register renaming. Execution writeback updates the existing architectural register file;
  * `RetirementBuffer` observes those completions and retires their bookkeeping in program order.
  * This is precise only because the eligible arithmetic operations cannot fault and every other
  * instruction is a full drain boundary.
  */
class OutOfOrderIssueQueue(p: Parameters, entries: Int = 8) extends Module {
  require(entries >= p.instructionLanes)

  val io = IO(new OutOfOrderIssueQueueIO(p, entries))

  val countWidth = log2Ceil(entries + 1)
  val count      = RegInit(0.U(countWidth.W))
  val queue      = Reg(Vec(entries, new OutOfOrderIssueEntry(p)))

  io.empty     := count === 0.U || io.flush
  io.nEnqueued := Mux(io.flush, 0.U, count)

  val valid = Wire(Vec(entries, Bool()))
  for (i <- 0 until entries) {
    valid(i) := i.U < count && !io.flush
  }

  val rs1Addr = queue.map(_.instruction.inst(19, 15))
  val rs2Addr = queue.map(_.instruction.inst(24, 20))
  val rdAddr  = queue.map(_.instruction.inst(11, 7))

  val readMasks = (0 until entries).map(i =>
    MuxOR(queue(i).readsRs1, UIntToOH(rs1Addr(i), p.scalarRegCount)) |
      MuxOR(queue(i).readsRs2, UIntToOH(rs2Addr(i), p.scalarRegCount))
  )
  val writeMasks =
    (0 until entries).map(i => Mux(rdAddr(i) === 0.U, 0.U, UIntToOH(rdAddr(i), p.scalarRegCount)))
  // DispatchV2 conservatively includes x0 in its same-cycle destination scan.
  // Mirror that behavior for issue grouping so every selected operation is
  // accepted together, while architectural WAW ownership still ignores x0.
  val dispatchWriteMasks =
    (0 until entries).map(i => UIntToOH(rdAddr(i), p.scalarRegCount))

  // A candidate can bypass older entries only when doing so cannot change the
  // value observed by any instruction. WAR is required because this design
  // intentionally avoids the area cost of physical-register renaming.
  val dataReady = (0 until entries).map(i => {
    val olderReads =
      if (i == 0) 0.U(p.scalarRegCount.W)
      else
        readMasks
          .take(i)
          .zip(valid.take(i))
          .map { case (mask, v) => Mux(v, mask, 0.U) }
          .reduce(_ | _)
    val olderWrites =
      if (i == 0) 0.U(p.scalarRegCount.W)
      else
        dispatchWriteMasks
          .take(i)
          .zip(valid.take(i))
          .map { case (mask, v) => Mux(v, mask, 0.U) }
          .reduce(_ | _)

    val raw = (readMasks(i) & (olderWrites | io.scoreboard)) =/= 0.U
    val war = (writeMasks(i) & olderReads) =/= 0.U
    val waw = (dispatchWriteMasks(i) & (olderWrites | io.scoreboard)) =/= 0.U
    !raw && !war && !waw
  })

  val selected  = WireInit(VecInit.fill(entries)(false.B))
  val issueSlot = Wire(Vec(entries, UInt(log2Ceil(p.instructionLanes).W)))

  var selectedCount = 0.U(log2Ceil(p.instructionLanes + 1).W)
  var mluSelected   = false.B
  var dvuSelected   = false.B
  for (i <- 0 until entries) {
    val isMlu = queue(i).isMlu
    val isDvu = queue(i).isDvu

    // The multiplier and divider accept commands only from lane zero. ALU
    // operations may fill the remaining lanes after a multi-cycle command.
    val resourceReady =
      (!isMlu || (io.mluReady && !mluSelected && selectedCount === 0.U)) &&
        (!isDvu || (io.dvuReady && !dvuSelected && selectedCount === 0.U))
    val choose =
      valid(i) && dataReady(i) && resourceReady && selectedCount < p.instructionLanes.U

    selected(i)  := choose
    issueSlot(i) := selectedCount
    selectedCount = selectedCount + choose
    mluSelected = mluSelected || (choose && isMlu)
    dvuSelected = dvuSelected || (choose && isDvu)
  }

  val selectedForSlot = Wire(Vec(p.instructionLanes, Vec(entries, Bool())))
  for (slot <- 0 until p.instructionLanes) {
    for (i <- 0 until entries) {
      selectedForSlot(slot)(i) := selected(i) && issueSlot(i) === slot.U
    }
    io.issue(slot).valid := selectedForSlot(slot).asUInt.orR
    io.issue(slot).bits  := Mux(
      io.issue(slot).valid,
      PriorityMux(selectedForSlot(slot), queue.map(_.instruction)),
      0.U.asTypeOf(new FetchInstruction(p))
    )
  }

  val remove = Wire(Vec(entries, Bool()))
  for (i <- 0 until entries) {
    remove(i) := (0 until p.instructionLanes)
      .map(slot => selectedForSlot(slot)(i) && io.issue(slot).fire)
      .reduce(_ || _)
  }
  val removeCount = PopCount(remove)

  // A same-cycle issue frees space for allocation. A destination conflict with
  // any queued or in-flight writer is rejected at admission, rather than merely
  // delayed at issue: the existing retirement buffer identifies scalar
  // completions by architectural register and therefore cannot safely contain
  // two incomplete writers to the same register.
  val available    = entries.U - count + removeCount
  val queuedWrites = writeMasks
    .zip(valid)
    .map { case (mask, v) => Mux(v, mask, 0.U) }
    .reduce(_ | _)
  val enqWriteMasks = io.enq.map(enq =>
    Mux(
      enq.bits.inst(11, 7) === 0.U,
      0.U(p.scalarRegCount.W),
      UIntToOH(enq.bits.inst(11, 7), p.scalarRegCount)
    )
  )

  // Ready is prefix ordered to match fetch and retirement-buffer allocation.
  var readyPrefix           = true.B
  var earlierAcceptedWrites = 0.U(p.scalarRegCount.W)
  for (i <- 0 until p.instructionLanes) {
    val noWaw =
      (enqWriteMasks(i) & (queuedWrites | io.scoreboard | earlierAcceptedWrites)) === 0.U
    io.enq(i).ready := !io.flush && readyPrefix && i.U < available && noWaw
    earlierAcceptedWrites = earlierAcceptedWrites | Mux(io.enq(i).fire, enqWriteMasks(i), 0.U)
    readyPrefix = readyPrefix && io.enq(i).fire
  }
  io.nSpace := Mux(io.flush, entries.U(countWidth.W), available)

  val enqFires   = io.enq.map(_.fire)
  val enqEntries = io.enq.map(enq => {
    val decoded = DecodeInstruction(p, 0, enq.bits.addr, enq.bits.inst, 0.U(3.W))
    val entry   = Wire(new OutOfOrderIssueEntry(p))
    entry.instruction := enq.bits
    entry.readsRs1    := decoded.readsRs1()
    entry.readsRs2    := decoded.readsRs2()
    entry.isMlu       := decoded.isMul()
    entry.isDvu       := decoded.isDvu()
    entry
  })
  val survivorValid = (0 until entries).map(i => valid(i) && !remove(i))
  val sourceValid   = survivorValid ++ enqFires
  val sourceBits    = queue.toSeq ++ enqEntries
  val sourceRanks   = sourceValid.scanLeft(0.U(countWidth.W))(_ + _).dropRight(1)
  val nextCount     = PopCount(sourceValid)

  for (dst <- 0 until entries) {
    val sourceForDst =
      sourceValid.zip(sourceRanks).map { case (v, rank) => v && rank === dst.U }
    when(VecInit(sourceForDst).asUInt.orR) {
      queue(dst) := PriorityMux(sourceForDst, sourceBits)
    }
  }
  count := Mux(io.flush, 0.U, nextCount)

  // Interface and domain invariants.
  val enqSeenInvalid =
    io.enq.map(_.fire).scanLeft(false.B) { case (seen, fire) => seen || !fire }.drop(1)
  assert(
    !(enqSeenInvalid
      .zip(io.enq.map(_.fire))
      .map { case (seen, fire) => seen && fire }
      .reduce(_ || _))
  )
  for (i <- 0 until p.instructionLanes) {
    when(io.enq(i).fire) {
      assert(OutOfOrderIssue.isSafeScalarArithmetic(p, io.enq(i).bits))
    }
  }
  val anyIssueFire      = io.issue.map(_.fire).reduce(_ || _)
  val allValidIssueFire = io.issue.map(port => !port.valid || port.fire).reduce(_ && _)
  assert(!anyIssueFire || allValidIssueFire)
  for (i <- 0 until entries) {
    when(valid(i)) {
      assert((writeMasks(i) & io.scoreboard) === 0.U)
    }
    for (j <- i + 1 until entries) {
      when(valid(i) && valid(j)) {
        assert((writeMasks(i) & writeMasks(j)) === 0.U)
      }
    }
  }
  assert(nextCount <= entries.U)
}
