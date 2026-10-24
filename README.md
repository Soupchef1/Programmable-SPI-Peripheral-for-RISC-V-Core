# Programmable-SPI-Peripheral-for-RISC-V-Core

## 1. Purpose

`programmable_spi` is a memory-mapped, single-master SPI controller. Software writes words into an 8-deep TX FIFO, `spi_core` shifts them out on SCLK/MOSI while capturing MISO, and received words land in an 8-deep RX FIFO for software to read back.

**Features**

- All four SPI modes (CPOL/CPHA), selectable at run time
- Word widths of 4, 8, 16 or 32 bits, MSB-first or LSB-first
- SCLK = f_clk / clock_ratio, 16-bit ratio field (2 to 65534, even values)
- 8 × 32-bit TX FIFO and 8 × 32-bit RX FIFO
- Four software-controlled, active-low chip-select lines
- Write-only mode (`receive_enable = 0`) for devices with no useful MISO data
- Configuration shadowing: CONFIG changes reach the core only between transfers
- error flag for dropped or ignored accesses
- One level-sensitive interrupt line with four maskable sources

**Not in scope:**

- Dual/quad SPI, 3-wire SPI, slave mode, multi-master
- Automatic per-word chip select (CS is fully manual, driven by software)
- The block has a bare strobe interface; a bus bridge in the parent does the translation.
- Pin muxing / pad control. `chip_select_n_o` goes to GPIO in the parent.
- Everything runs on `clk_i`.

**Module hierarchy**

| Instance | Module | File | Role |
| --- | --- | --- | --- |
| (top) | `programmable_spi` | `programmable_spi.sv` | Registers, bus decode, read mux, Interrupts, CS, config shadowing |
| `u_tx_fifo` | `fifo` (`DATA_WIDTH=32`, `MAX_FIFO_DEPTH=8`) | `fifo.sv` | Software → core transmit queue |
| `u_rx_fifo` | `fifo` (`DATA_WIDTH=32`, `MAX_FIFO_DEPTH=8`) | `fifo.sv` | Core → software receive queue |
| `u_spi_core` | `spi_core` (`MAX_DATA_WIDTH=32`) | `spi_core.sv` | Clock divider, shift registers, IDLE/TRANSFER FSM |

## 2. Block diagram

Software only touches the memory mapped registers. TX words flow through the TX FIFO into `spi_core`; received words flow back through the RX FIFO. The core runs from the active copy of CONFIG, which reloads only while `transfer_done` is true. Chip selects and the interrupt line come straight from the register block, not from the core.

<img width="872" height="410" alt="Screenshot 2026-10-10 125747 (1)" src="https://github.com/user-attachments/assets/81454de4-3dcc-4beb-a506-390dad86bda4" />

- `interrupt_request_o` and `transfer_done` are combinational.

## 3. Parameters

`programmable_spi` itself has **no module parameters**. Sizes are `localparam`s, and the submodule parameters are set from them.

| Name | Where | Default | Legal range | Meaning |
| --- | --- | --- | --- | --- |
| `FIFO_DEPTH` | `programmable_spi` (localparam) | 8 | 2–255 | Depth of both FIFOs. ≥ 2 because of the `fifo` pointer width (see §9). ≤ 255 because STATUS count fields are 8 bits. |
| `DATA_WIDTH` | `programmable_spi` (localparam) | 32 | 32 only | Bus / FIFO / core word width |
| `COUNT_WIDTH` | `programmable_spi` (localparam) | `$clog2(FIFO_DEPTH+1)` = 4 | derived | FIFO count width |
| `DATA_WIDTH` | `fifo` | 32 | ≥ 1 | Word width |
| `MAX_FIFO_DEPTH` | `fifo` | 5 (8 in this design) | ≥ 2 | Number of entries. Need not be a power of two. |
| `MAX_DATA_WIDTH` | `spi_core` | 32 | **32 only** | Shift-register width. The RTL hardcodes `tx_data_i[31:1]`, `<< 28/24/16` and `rx_shift[31:28]` etc., so other values do not work. |

## 4. Interface

All logic runs on `clk_i`. Reset is **asynchronous assert**, active-low. The bus is a simple strobe interface: each cycle `enable_i` is high is one access. There is no wait/ready signal; every access completes.

| Port | Dir | Width / type | Clock domain | Description |
| --- | --- | --- | --- | --- |
| `clk_i` | in | 1 | — | System clock. SCLK is derived from it. |
| `rstn_i` | in | 1 | clk_i | Active-low, asynchronous assert. Deassert synchronously (external reset synchronizer). |
| `enable_i` | in | 1 | clk_i | Access strobe. Each cycle it is high is one access. |
| `write_enable_i` | in | 1 | clk_i | 1 = write, 0 = read (sampled when `enable_i` = 1) |
| `address_i` | in | 5 | clk_i | Byte address. Bits [4:2] select the register; bits [1:0] are ignored. |
| `write_data_i` | in | 32 | clk_i | Write data. No byte enables: every write is a full 32-bit write. |
| `read_data_o` | out | 32 | clk_i | Read data, registered. Valid the cycle after the read; holds until the next read. |
| `read_valid_o` | out | 1 | clk_i | High for one cycle when `read_data_o` carries new data |
| `interrupt_request_o` | out | 1 | clk_i | Level-sensitive interrupt, combinational from status flags and IRQ_ENABLE |
| `sclk_o` | out | 1 | clk_i (registered) | SPI clock. Idles at CPOL. |
| `chip_select_n_o` | out | 4 | clk_i (registered) | Active-low chip selects. Reset 4’hF (all deselected). |
| `mosi_o` | out | 1 | clk_i (registered) | Master out, slave in |
| `miso_i` | in | 1 | clk_i | Master in, slave out. **Not synchronized internally**; constrain as a synchronous input. |

### 4.1 Bus timing

- **Write:** drive `enable_i` = 1, `write_enable_i` = 1, `address_i`, `write_data_i` for one cycle. The register (or FIFO) updates on that clock edge.
- **Read:** drive `enable_i` = 1, `write_enable_i` = 0, `address_i` for one cycle. On the next cycle `read_valid_o` = 1 and `read_data_o` holds the value. A read of RX_DATA pops the RX FIFO on the same edge that captures the data.
- **Back-to-back:** accesses may be issued every cycle. Holding `enable_i` high for N cycles is N separate accesses (e.g. N pops of RX_DATA or N pushes to TX_DATA).
- `chip_select_n_o` changes one cycle after the write edge, because the pins are a second flop stage.

### 4.2 Memory map

Six 32-bit registers occupy offsets 0x00–0x14 of a 32-byte window. 0x18 and 0x1C are reserved: reads return 0, writes are ignored and do not set `error`. Unused bits read as 0.

| Offset | Name | Access | Reset | Summary |
| --- | --- | --- | --- | --- |
| 0x00 | CONFIG | R/W | 0x0020_0088 | Mode, bit order, word width, clock ratio, receive enable |
| 0x04 | CHIP_SELECT | R/W | 0x0000_000F | Active-low chip-select lines |
| 0x08 | TX_DATA | W | — | Push a word into the TX FIFO (reads return 0, no side effect) |
| 0x0C | RX_DATA | R (pop) | — | Pop a word from the RX FIFO (writes ignored) |
| 0x10 | STATUS | R, W = clear error | 0x0000_0034 | FIFO levels and flags, busy, done, error |
| 0x14 | IRQ_ENABLE | R/W | 0x0000_0000 | Interrupt source mask |
| 0x18–0x1C | — | — | 0 | no access. does nothing. |

#### 0x00 CONFIG

Reset 0x0020_0088 = receive enabled, clock_ratio 4, 8-bit words, MSB-first, mode 0. Reads return the software copy, which is not necessarily what the core is using (see STATUS.config_pending). If a CPOL change was refused, the read shows the kept CPOL, not the written one.

| Bits | Field | Reset | Description |
| --- | --- | --- | --- |
| [31:22] | — | 0 | Reserved, write 0 (ignored on write) |
| [21] | receive_enable | 1 | 1 = received words go to the RX FIFO. 0 = received words are discarded. |
| [20:5] | clock_ratio | 4 | SCLK period in `clk_i` cycles. Must be even and ≥ 2 (see §5.5). |
| [4:3] | word_width | 01 | 00 = 4 bit, 01 = 8 bit, 10 = 16 bit, 11 = 32 bit |
| [2] | lsb_first | 0 | 1 = LSB first, 0 = MSB first |
| [1] | cpol | 0 | SCLK idle level. Write-protected: only changes when `transfer_done` = 1 **and** CHIP_SELECT = 0xF. Otherwise the old value is kept, the other fields are stored, and STATUS.error is set. |
| [0] | cpha | 0 | 0 = sample on leading edge, 1 = sample on trailing edge |

A CONFIG write during a transfer is stored but not applied. The core picks it up on the first cycle `transfer_done` is true.

#### 0x04 CHIP_SELECT

| Bits | Field | Reset | Description |
| --- | --- | --- | --- |
| [31:4] | — | 0 | empty/not used |
| [3:0] | cs_n | 0xF | Drives `chip_select_n_o`. 0 = selected. Write 0xE for device 0, 0xD for device 1, and so on. |

Writes are accepted only while `transfer_done` = 1. A write during a transfer is dropped and sets STATUS.error, unless it writes the current value.

#### 0x08 TX_DATA

| Bits | Field | Description |
| --- | --- | --- |
| [31:0] | data | Word to transmit, right-aligned. Only the low 4/8/16/32 bits (per word_width) are sent; upper bits are ignored. |

A write when the TX FIFO is full is dropped and sets STATUS.error.

#### 0x0C RX_DATA

| Bits | Field | Description |
| --- | --- | --- |
| [31:0] | data | Oldest received word, right-aligned and zero-extended to 32 bits |

Every read pops the FIFO. A read when the FIFO is empty returns 0 and sets STATUS.error.

#### 0x10 STATUS

Any write (data ignored) clears `error`. Reset 0x0000_0034 = tx_empty, rx_empty, transfer_done.

| Bits | Field | Description |
| --- | --- | --- |
| [31:24] | — | not used |
| [23:16] | rx_count | Words in the RX FIFO (0–8) |
| [15:8] | tx_count | Words in the TX FIFO (0–8) |
| [7] | error | Sticky. Set by a dropped or ignored access (§5.5). Cleared by any write to STATUS. |
| [6] | config_pending | 1 = software CONFIG ≠ active CONFIG (written but not yet taken by the core) |
| [5] | transfer_done | TX FIFO empty AND core idle AND no received word waiting to be stored |
| [4] | rx_empty | RX FIFO empty |
| [3] | rx_full | RX FIFO full |
| [2] | tx_empty | TX FIFO empty |
| [1] | tx_full | TX FIFO full |
| [0] | busy | Core is shifting a word (`spi_core` in TRANSFER) |

#### 0x14 IRQ_ENABLE

`interrupt_request_o = |(IRQ_ENABLE[3:0] & {error, rx_not_empty, tx_empty, transfer_done})`. All sources are levels, not pulses.

| Bit | Source | Asserts while |
| --- | --- | --- |
| [3] | error | STATUS.error = 1 |
| [2] | rx_not_empty | RX FIFO holds at least one word |
| [1] | tx_empty | TX FIFO is empty |
| [0] | transfer_done | All queued words are sent and received |

Bits [31:4] are not used.

## 5. Behavior

### 5.1 Normal operation

The typical sequence is: configure while idle, assert CS, queue words, drain RX, wait for `transfer_done`, deassert CS.

**SPI modes**

| Mode | CPOL | CPHA | SCLK idle | MISO sampled on | MOSI changes on |
| --- | --- | --- | --- | --- | --- |
| 0 | 0 | 0 | low | rising (leading) | falling (trailing) |
| 1 | 0 | 1 | low | falling (trailing) | rising (leading) |
| 2 | 1 | 0 | high | falling (leading) | rising (trailing) |
| 3 | 1 | 1 | high | rising (trailing) | falling (leading) |

With CPHA = 0 the first data bit is on MOSI while the core is idle, before the first edge. With CPHA = 1 the first bit is driven on the first (leading) edge. MISO is sampled on the same `clk_i` edge that drives the SCLK flop, so the master captures the value the slave set up before that SCLK edge.

**Clock generation:** The divider target is `(clock_ratio >> 1) - 1`, so odd ratios round down (5 behaves as 4). The divider runs only during TRANSFER. Between words SCLK sits at CPOL.

**transfer_done** = TX FIFO empty AND core not busy AND no received word waiting. It gates three things: CHIP_SELECT writes, applying CONFIG, and CPOL changes. It stays low until the whole TX queue drains, not just the current word.

**Configuration shadowing:** there are two copies of CONFIG. The software copy (`config_register`) is what reads return. The active copy (`config_active`) is what the core uses. The active copy reloads from the software copy every cycle `transfer_done` = 1. A CONFIG write while idle takes effect on the same edge. CPOL additionally requires CHIP_SELECT = 0xF, so the SCLK idle level never moves while a slave is selected.

**Chip select:** fully under software control; the hardware never toggles CS. Because CS writes are refused mid-transfer, CS cannot be released while SCLK is running. The hardware does not stop software from asserting several lines at once.

### 5.2 Control

- **`spi_core`: input-dependent FSM**, 2 states:
    - `IDLE` → `TRANSFER` when `tx_valid_i && tx_ready_o`
    - `TRANSFER` → `IDLE` when `sclk_tick && edge_cnt == 2·width`
- **Clock divider:** fixed schedule counter (`clk_div_cnt`, 15 bits) that runs only in TRANSFER.
- **Back pressure:**
    - Bus side: none. Accesses always complete; a write to a full TX FIFO is dropped and flagged, and a read from an empty RX FIFO returns 0 and is flagged.
    - TX FIFO → core: valid/ready. The core takes a word only in IDLE with no RX word pending.
    - Core → RX FIFO: valid/ready when `receive_enable` = 1. If the RX FIFO is full, the core holds `rx_valid_o` and does not start the next word until software reads RX_DATA. No data is lost, but the transfer stalls and `transfer_done` stays low. When `receive_enable` = 0, `rx_ready_i` is tied high and the core never stalls on RX.
- **Register-side control:** `transfer_done` gates CS writes, CONFIG application and CPOL changes. `access_error` sets the `error` flag.

### 5.3 Storage

| Register / memory | Width × depth | Written by | Reset value (or “no reset”) |
| --- | --- | --- | --- |
| `config_register` (CONFIG sw copy) | 22 × 1 | Bus write to CONFIG (CPOL protected) | 0x20_0088 |
| `config_active` | 22 × 1 | Reload when `transfer_done` | 0x20_0088 |
| `chip_select_register` | 4 × 1 | Bus write to CHIP_SELECT (only if `transfer_done`) | 0xF |
| `chip_select_n_o` | 4 × 1 | Copy of `chip_select_register` | 0xF |
| `irq_enable` | 4 × 1 | Bus write to IRQ_ENABLE | 0 |
| `error` | 1 | Set by `access_error`; cleared by STATUS write | 0 |
| `read_data_o` | 32 × 1 | Read mux on bus read | 0 |
| `read_valid_o` | 1 | Bus read strobe | 0 |
| TX FIFO `mem_q` | 32 × 8 | Bus write to TX_DATA | **no reset** |
| TX FIFO `wr_ptr_q`/`rd_ptr_q`/`count_q` | 3 / 3 / 4 | FIFO logic | 0 |
| RX FIFO `mem_q` | 32 × 8 | `spi_core` RX handoff | **no reset** |
| RX FIFO `wr_ptr_q`/`rd_ptr_q`/`count_q` | 3 / 3 / 4 | FIFO logic | 0 |
| `spi_core.state` | 1 | FSM | IDLE |
| `spi_core.clk_div_cnt` / `sclk_tick` | 15 / 1 | Divider | 0 / 0 |
| `spi_core.edge_cnt` | 7 | Datapath | 0 |
| `spi_core.tx_shift` / `rx_shift` | 32 / 32 | Datapath | 0 / 0 |
| `spi_core.rx_data_o` / `rx_valid_o` | 32 / 1 | Datapath | 0 / 0 |
| `spi_core.sclk_o` / `mosi_o` | 1 / 1 | Datapath | 0 / 0 |

### 5.4 Edge cases & errors

| Case | What happens | Checked assertion? |
| --- | --- | --- |
| TX_DATA write when TX FIFO full (overflow) | Word dropped, `error` set | Proposed: `a_tx_overflow_sets_error` |
| RX_DATA read when RX FIFO empty (underflow) | Returns 0, no pop, `error` set | Proposed: `a_rx_underflow_sets_error` |
| CHIP_SELECT write with a new value while `transfer_done` = 0 | Write ignored, `error` set (writing the current value is OK) | Proposed: `a_cs_stable_while_busy` (`chip_select_n_o` stable while `busy`) |
| CONFIG write changing CPOL while busy or CS ≠ 0xF | CPOL kept, other fields stored, `error` set | Proposed: `a_sclk_idle_eq_cpol` (`!busy` → `sclk_o == config_active.cpol` one cycle later) |
| CONFIG write during a transfer | Stored, `config_pending` = 1, applied when the queue drains | Proposed: `a_config_active_stable_while_busy` |
| RX FIFO full with `receive_enable` = 1 | Core stalls holding the word; no data loss; `transfer_done` stays low | Proposed: `a_no_rx_drop` |
| `receive_enable` = 0 | RX words discarded, core never stalls on RX | — |
| `clock_ratio` = 0 or 1 | **Hang.** Divider target `(ratio>>1)-1` underflows to 0xFFFF, which the 15-bit `clk_div_cnt` can never reach. SCLK never ticks and the core stays busy until reset. | None today. See §9 issue 1. |
| Odd `clock_ratio` | Rounded down (3 → 2, 5 → 4) | — |
| Back-to-back accesses every cycle | Each cycle is a separate access (e.g. N RX pops) | Covered by T9 |
| Simultaneous FIFO push and pop | Count unchanged; when full, a push is still refused even if a pop happens in the same cycle | `fifo` unit test |
| Address 0x18/0x1C (reserved) | Reads 0, writes ignored, no error | — |
| Reset in the middle of a transfer | Async reset: FSM → IDLE, SCLK → 0 (= reset CPOL), CS → 0xF, FIFO pointers cleared; FIFO data and the word in flight are lost | Covered by T11 |
| `miso_i` metastability | No synchronizer. Safe only when timing-constrained: the round trip (SCLK out → slave clock-to-out → board → `miso_i`) plus setup must fit in h `clk_i` cycles. | STA constraint, not an assertion |
| MOSI in IDLE with CPHA = 0 | Follows the TX FIFO head (X in simulation until the first TX write, because FIFO memory is not reset). Harmless while CS is high. | — |
| Several CS lines low at once | Allowed by hardware; the selected slaves share MISO | Software rule |
| Level interrupts | `transfer_done`/`tx_empty` are true whenever idle, so enabling them while idle fires at once | Software rule |

**Software constraints (summary)**

| Constraint | Why |
| --- | --- |
| clock_ratio ≥ 2 | 0/1 hang the core (above) |
| clock_ratio should be even | Odd values round down |
| SCLK ≤ f_clk/2 | Fastest setting is ratio = 2 |
| Drain RX when `receive_enable` = 1 | A full RX FIFO stalls the core and `transfer_done` stays low, so code that only polls `transfer_done` deadlocks |
| Wait for `transfer_done` before changing CS | Mid-transfer CS writes are ignored and flagged |
| Deselect all CS before changing CPOL | Otherwise CPOL is kept and an error is flagged |
| Write CONFIG before queuing data | A CONFIG write after TX_DATA waits for the whole queue to drain |
| Mask level interrupts once serviced | They re-fire immediately otherwise |
| Full 32-bit accesses only | No byte enables; address bits [1:0] are ignored |
| RX_DATA reads are destructive | Debug tools or speculative reads will pop data |

## 6. Verification plan (for verif)
