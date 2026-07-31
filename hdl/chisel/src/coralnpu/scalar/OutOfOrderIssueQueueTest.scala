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
import chisel3.simulator.scalatest.ChiselSim
import org.scalatest.freespec.AnyFreeSpec

class OutOfOrderIssueQueueSpec extends AnyFreeSpec with ChiselSim {
  val p = new Parameters

  def rType(funct7: Int, rs2: Int, rs1: Int, funct3: Int, rd: Int): BigInt = {
    (BigInt(funct7) << 25) |
      (BigInt(rs2) << 20) |
      (BigInt(rs1) << 15) |
      (BigInt(funct3) << 12) |
      (BigInt(rd) << 7) |
      0x33
  }

  def add(rd: Int, rs1: Int, rs2: Int): BigInt = rType(0, rs2, rs1, 0, rd)
  def div(rd: Int, rs1: Int, rs2: Int): BigInt = rType(1, rs2, rs1, 4, rd)

  def initialize(dut: OutOfOrderIssueQueue): Unit = {
    dut.io.scoreboard.poke(0.U)
    dut.io.mluReady.poke(true.B)
    dut.io.dvuReady.poke(true.B)
    dut.io.flush.poke(false.B)
    for (i <- 0 until p.instructionLanes) {
      dut.io.enq(i).valid.poke(false.B)
      dut.io.enq(i).bits.addr.poke(0.U)
      dut.io.enq(i).bits.inst.poke(0.U)
      dut.io.enq(i).bits.brchFwd.poke(false.B)
      dut.io.issue(i).ready.poke(false.B)
    }
  }

  def enqueue(dut: OutOfOrderIssueQueue, instructions: Seq[BigInt], basePc: Int = 0x100): Unit = {
    for (i <- 0 until p.instructionLanes) {
      val active = i < instructions.length
      dut.io.enq(i).valid.poke(active.B)
      if (active) {
        dut.io.enq(i).bits.addr.poke((basePc + 4 * i).U)
        dut.io.enq(i).bits.inst.poke(instructions(i).U)
      }
    }
    dut.clock.step()
    for (i <- 0 until p.instructionLanes) {
      dut.io.enq(i).valid.poke(false.B)
    }
  }

  "Younger independent ALUs bypass a RAW-blocked instruction" in {
    simulate(new OutOfOrderIssueQueue(p)) { dut =>
      initialize(dut)
      enqueue(
        dut,
        Seq(
          div(rd = 5, rs1 = 1, rs2 = 2),
          add(rd = 6, rs1 = 5, rs2 = 3),
          add(rd = 7, rs1 = 8, rs2 = 9),
          add(rd = 10, rs1 = 11, rs2 = 12)
        )
      )

      dut.io.nEnqueued.expect(4.U)
      dut.io.issue(0).valid.expect(true.B)
      dut.io.issue(0).bits.addr.expect(0x100.U)
      dut.io.issue(1).valid.expect(true.B)
      dut.io.issue(1).bits.addr.expect(0x108.U)
      dut.io.issue(2).valid.expect(true.B)
      dut.io.issue(2).bits.addr.expect(0x10c.U)
      dut.io.issue(3).valid.expect(false.B)

      for (i <- 0 until 3) {
        dut.io.issue(i).ready.poke(true.B)
      }
      dut.clock.step()

      // The dependent add stays queued while the divider owns x5.
      dut.io.scoreboard.poke((BigInt(1) << 5).U)
      dut.io.nEnqueued.expect(1.U)
      dut.io.issue(0).valid.expect(false.B)

      // Writeback forwarding clears the scoreboard and wakes it.
      dut.io.scoreboard.poke(0.U)
      dut.io.issue(0).valid.expect(true.B)
      dut.io.issue(0).bits.addr.expect(0x104.U)
    }
  }

  "WAR hazards wait for older queued instructions and WAW admission is blocked" in {
    simulate(new OutOfOrderIssueQueue(p)) { dut =>
      initialize(dut)
      enqueue(
        dut,
        Seq(
          add(rd = 5, rs1 = 1, rs2 = 2),
          add(rd = 1, rs1 = 8, rs2 = 9),  // WAR on the older rs1.
          add(rd = 5, rs1 = 10, rs2 = 11) // WAW on the older rd.
        )
      )

      // The WAR instruction is admitted but cannot bypass the older reader.
      // The duplicate x5 writer is rejected before ROB allocation.
      dut.io.nEnqueued.expect(2.U)
      dut.io.issue(0).valid.expect(true.B)
      dut.io.issue(0).bits.addr.expect(0x100.U)
      dut.io.issue(1).valid.expect(false.B)
    }
  }

  "A destination cannot be reallocated until its older writer completes" in {
    simulate(new OutOfOrderIssueQueue(p)) { dut =>
      initialize(dut)
      dut.io.dvuReady.poke(false.B)
      enqueue(dut, Seq(div(rd = 5, rs1 = 1, rs2 = 2)))

      // The older writer is still queued.
      dut.io.enq(0).valid.poke(true.B)
      dut.io.enq(0).bits.addr.poke(0x104.U)
      dut.io.enq(0).bits.inst.poke(add(rd = 5, rs1 = 3, rs2 = 4).U)
      dut.io.enq(0).ready.expect(false.B)

      // Once issued, its scoreboard ownership continues to block admission.
      dut.io.enq(0).valid.poke(false.B)
      dut.io.dvuReady.poke(true.B)
      dut.io.issue(0).ready.poke(true.B)
      dut.clock.step()
      dut.io.issue(0).ready.poke(false.B)
      dut.io.scoreboard.poke((BigInt(1) << 5).U)
      dut.io.enq(0).valid.poke(true.B)
      dut.io.enq(0).ready.expect(false.B)

      // Completion clears the scoreboard and makes a new writer safe to admit.
      dut.io.scoreboard.poke(0.U)
      dut.io.enq(0).ready.expect(true.B)
      dut.clock.step()
      dut.io.enq(0).valid.poke(false.B)
      dut.io.nEnqueued.expect(1.U)
    }
  }

  "A busy divider does not block unrelated ALUs" in {
    simulate(new OutOfOrderIssueQueue(p)) { dut =>
      initialize(dut)
      dut.io.dvuReady.poke(false.B)
      enqueue(
        dut,
        Seq(
          div(rd = 5, rs1 = 1, rs2 = 2),
          add(rd = 7, rs1 = 8, rs2 = 9),
          add(rd = 10, rs1 = 11, rs2 = 12)
        )
      )

      dut.io.issue(0).valid.expect(true.B)
      dut.io.issue(0).bits.addr.expect(0x104.U)
      dut.io.issue(1).valid.expect(true.B)
      dut.io.issue(1).bits.addr.expect(0x108.U)
    }
  }

  "Issue ownership transfers only when the complete grant is accepted" in {
    simulate(new OutOfOrderIssueQueue(p)) { dut =>
      initialize(dut)
      enqueue(
        dut,
        Seq(
          add(rd = 5, rs1 = 1, rs2 = 2),
          add(rd = 6, rs1 = 3, rs2 = 4),
          add(rd = 7, rs1 = 8, rs2 = 9)
        )
      )

      // Dispatch applies all-or-none backpressure to the selected group.
      dut.clock.step()

      dut.io.nEnqueued.expect(3.U)
      dut.io.issue(0).valid.expect(true.B)
      dut.io.issue(0).bits.addr.expect(0x100.U)
      dut.io.issue(1).valid.expect(true.B)
      dut.io.issue(1).bits.addr.expect(0x104.U)
      dut.io.issue(2).valid.expect(true.B)
      dut.io.issue(2).bits.addr.expect(0x108.U)

      for (i <- 0 until 3) {
        dut.io.issue(i).ready.poke(true.B)
      }
      dut.clock.step()
      dut.io.nEnqueued.expect(0.U)
    }
  }

  "Simultaneous issue and allocation preserve survivor age" in {
    simulate(new OutOfOrderIssueQueue(p)) { dut =>
      initialize(dut)
      enqueue(
        dut,
        Seq(
          add(rd = 5, rs1 = 1, rs2 = 2),
          add(rd = 6, rs1 = 5, rs2 = 4),
          add(rd = 7, rs1 = 6, rs2 = 9),
          add(rd = 10, rs1 = 7, rs2 = 12)
        )
      )

      dut.io.issue(0).ready.poke(true.B)
      dut.io.enq(0).valid.poke(true.B)
      dut.io.enq(0).bits.addr.poke(0x200.U)
      dut.io.enq(0).bits.inst.poke(add(rd = 13, rs1 = 10, rs2 = 15).U)
      dut.io.enq(1).valid.poke(true.B)
      dut.io.enq(1).bits.addr.poke(0x204.U)
      dut.io.enq(1).bits.inst.poke(add(rd = 16, rs1 = 10, rs2 = 18).U)
      dut.clock.step()

      dut.io.issue(0).ready.poke(false.B)
      dut.io.enq(0).valid.poke(false.B)
      dut.io.enq(1).valid.poke(false.B)
      dut.io.nEnqueued.expect(5.U)
      dut.io.issue(0).bits.addr.expect(0x104.U)
      dut.io.issue(1).valid.expect(false.B)
    }
  }

  "A retirement-buffer flush squashes the complete issue window" in {
    simulate(new OutOfOrderIssueQueue(p)) { dut =>
      initialize(dut)
      enqueue(
        dut,
        Seq(
          add(rd = 5, rs1 = 1, rs2 = 2),
          add(rd = 6, rs1 = 3, rs2 = 4)
        )
      )
      dut.io.nEnqueued.expect(2.U)

      dut.io.flush.poke(true.B)
      dut.io.empty.expect(true.B)
      dut.io.nEnqueued.expect(0.U)
      dut.io.issue(0).valid.expect(false.B)
      dut.io.enq(0).valid.poke(true.B)
      dut.io.enq(0).bits.addr.poke(0x200.U)
      dut.io.enq(0).bits.inst.poke(add(rd = 7, rs1 = 8, rs2 = 9).U)
      dut.io.enq(0).ready.expect(false.B)
      dut.clock.step()

      dut.io.flush.poke(false.B)
      dut.io.enq(0).valid.poke(false.B)
      dut.io.empty.expect(true.B)
      dut.io.nEnqueued.expect(0.U)
    }
  }
}
