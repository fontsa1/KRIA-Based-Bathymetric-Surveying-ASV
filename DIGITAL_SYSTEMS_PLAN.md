# FPGA-Based ASV — Digital Systems Plan

Boat 2 of the DOT-funded Autonomous Surface Vehicle (bathymetric surveying / bridge-pier
mapping) project. This sub-team is replacing the current digital stack —
**NVIDIA Jetson Orin Nano + Cube Orange+** — with a single **AMD/Xilinx Kria KR260**
(Zynq UltraScale+ MPSoC), running Vitis AI (DPU + YOLO) and ROS2. The hull itself is a
boogie board with waterproof boxes mounted on it for electronics/sensors — not a 3D-printed
structure; the 3D prints (reused from the original boat) are mounting brackets/enclosures for
sensors and digital hardware, not the platform itself. Power system is already solved and
carried over from the original boat.

This doc is the living plan for the electronics/compute side: toolchain, sensor interfacing,
PS/PL partitioning, and open decisions. Update it as decisions get made — don't let it go stale.

---

## 1. Toolchain — decided

**Vivado / Vitis / PetaLinux 2023.1, Vitis AI 3.5. Whole team confirmed on this set** (Enterprise
licenses cover it). **Linux base: Kria Ubuntu 22.04 (already installed on the board), ROS2
Humble** — chosen for best out-of-the-box app support. This also matches what the previous
Jetson/Cube team used, which matters: see §9 on reusing their ROS2 code.

Vitis AI 3.5's DPU IP (DPUCZDX8G v4.1, the Zynq UltraScale+ target used by KR260/KV260) is
officially verified against 2023.1, not 2023.2 — worth double-checking installs are actually
.1. Vitis AI itself has since moved to 5.0, but AMD's release notes state the DPU IP and
DPU-TRD reference design for Zynq UltraScale+ "reached maturity" — no DPU IP or
reference-design updates in the 4.x/5.x minor releases. Practically: nothing is lost by pinning
to 2023.1/Vitis AI 3.5, and it's the version the available worked examples for KR260 actually
use (e.g. LogicTronix's
[KR260 DPU-TRD Vivado-flow tutorial](https://www.hackster.io/LogicTronix/kria-kr260-dpu-trd-vivado-flow-vitis-ai-3-0-tutorial-0085fd),
[KR260-DPU-TRD-Vitis-AI-3.0 repo](https://github.com/LogicTronixInc/KR260-DPU-TRD-Vitis-AI-3.0)).

**Context, not action:** AMD announced a new "Kria AI" line (Ryzen AI Embedded X100-based,
CPU/GPU/NPU, not FPGA/DPU) at Advancing AI 2026, shipping Q4 2026. Doesn't affect the
already-purchased KR260 — just confirms the DPU/Zynq path is a mature, stable, no-longer-evolving
branch. Fine for a fixed-scope senior project.

---

## 2. Open architecture decision — how much of the Cube Orange+ gets replaced?

**This is the single biggest unresolved question and should be settled before the block
diagram is finalized**, because it changes what has to be built. It also determines what (if
anything) replaces the Cube's telemetry/command-link role — see §3.

The Cube Orange+ today isn't just a motor driver — it's a full autopilot (ArduSub/ArduPilot):
EKF sensor fusion, closed-loop stabilization, failsafes, mode logic, MAVLink. The original plan
was for the KR260 to replace *both* the Jetson and the Cube outright, with the Zynq PS talking
to sensors and motors directly.

**Option A — Full replacement.** KR260 (PS + PL + ROS2) does everything: perception, mapping,
navigation, *and* low-level stabilization/motor mixing/failsafes, with no separate autopilot
board. Cleanest architecture, fully consolidated on one board — but it means re-implementing,
from scratch, safety-critical control logic that ArduPilot has spent years hardening. For an
ASV this is more tractable than for a multirotor (heading/speed PID + waypoint following vs.
full attitude stabilization), but it is still real control-systems + failsafe work on top of
everything else in this doc.

**Option B — Hybrid (recommended default).** Keep a small, cheap low-level controller (could
be a lightweight ArduRover-class board, or even bare-metal/RTOS code on the Zynq's own RPU
cores) doing closed-loop stabilization, motor mixing, and failsafes — mirroring the current
Jetson↔Cube relationship, except the "Jetson" role (perception, YOLO, mapping, mission
planning, ROS2) is now entirely absorbed into the KR260. Lower risk, reuses proven control
logic, and still consolidates the compute-heavy stuff onto one board as intended.

**Action item:** the team needs to explicitly choose A or B — it determines whether "digital
systems" includes writing a boat autopilot from scratch.

---

## 3. Command link / telemetry — needs an explicit replacement plan

The previous team's read is that "telemetry is no longer something to worry about" once the
Cube is dropped. Worth being precise about *why* before treating it as fully solved: the Cube's
MAVLink telemetry radio wasn't just a data downlink — on most ArduPilot/ArduSub setups it also
carries the operator's mode-change/manual-override/kill commands and RC failsafe behavior. If
the plan is that ROS2-over-WiFi (or a cellular/other link) between the KR260 and a ground
laptop naturally covers both the data and the command path, that's a fine replacement — but it
should be a stated design decision, not an assumption inherited by omission. In particular,
confirm there's still a way to **manually stop/override the boat** that doesn't depend on the
same link carrying everything else (a physical/RF-based independent kill switch is the usual
answer, separate from the main comms link, and is likely a safety requirement regardless of
what replaces the Cube).

**Action item:** explicitly define what replaces (a) live telemetry/monitoring and (b) manual
override/e-stop, now that the Cube's radio is gone.

### 3.1 Keeping telemetry cheap on a 4GB board — this is really an Option A/B question

The instinct to avoid "much memory overhead" for telemetry is right, but the actual lever isn't
which telemetry library is smallest — it's **whether the KR260 needs to run any telemetry/RC
stack at all**, which is decided by §2:

- **If Option B (hybrid, recommended default) is chosen:** put RC input, telemetry radio, and
  "return home" logic entirely on the small low-level controller board, exactly like the current
  Cube does today. A SiK/RFD900-class radio + ArduRover's own RC/telemetry handling costs the
  KR260 **zero** memory — it never runs on the Zynq PS at all. ArduRover also already has a
  built-in RC-switch-triggered `RETURN_TO_LAUNCH` mode (`RCx_OPTION`), so "one switch flip →
  boat comes home" is a firmware feature, not something to build. **Caveat:** stock RTL returns
  to the *GPS* home position, not a Marvelmind beacon specifically — fine if the retrieval point
  itself has clear sky view (likely, if it's a dock/bank away from the bridge), but if retrieval
  also needs to happen in a GPS-denied spot, that's the case below instead.
- **If Option A (full replacement), or if retrieval specifically must be anchored to a
  Marvelmind beacon** (e.g. retrieval point itself is GPS-denied): don't reach for
  MAVLink/MAVROS to build this — there's no MAVLink-speaking autopilot left to bridge to under
  Option A, and MAVROS/QGroundControl-class tooling is real weight (message-definition parsing,
  GeographicLib, a GCS-facing proxy) for a problem that doesn't need it here. Instead:
  - **RC input:** most hobby receivers output **SBUS** (a single-wire inverted UART) — decode it
    directly on the KR260 with [`sbus_serial`](https://github.com/jenswilly/sbus_serial), which
    already has a ROS2 Humble branch. This is one small node reading one UART; no PL work needed
    if using a USB-SBUS/PPM adapter, or a PS UART + a small inverter if wired directly. Use one
    spare channel as a single "return-to-beacon" trigger — this is not building full RC
    tele-op, just a one-bit signal.
  - **"Return to beacon" behavior:** a small ROS2 state-machine node that, on trigger, commands
    the boat toward the fixed Marvelmind beacon position already present in `robot_localization`'s
    fused estimate (§8) — this reuses the localization stack that's being built anyway, so the
    incremental memory cost is one small extra node, not a new subsystem.
  - **Live telemetry/monitoring beyond RC/WiFi range**, if needed: a cheap SiK/RFD900-class serial
    radio carrying a small custom packet (position, battery, mode — not MAVLink) is far lighter
    than any MAVLink/GCS stack, at the cost of writing that tiny protocol yourself instead of
    getting one for free. If the boat always stays in ROS2-over-WiFi range of the lab
    laptop (§7), this may not even be needed — worth confirming the actual operating range before
    building a second radio link.

**Action item:** once §2 is decided, settle whether RC/telemetry lives entirely on the low-level
board (Option B) or needs the lightweight SBUS + custom-node path on the KR260 (Option A /
Marvelmind-anchored retrieval), and confirm the real-world WiFi range needed before assuming a
second radio link is necessary.

---

## 4. Sensor interface survey

Originally carried over from the previous team's sensor list, evaluated for KR260 fit; now
updated with the team's decisions (camera, lidar, GPS, thruster control, RC link). Rows are marked
**chosen**, **recommended** (not yet bought or bench-tested), **existing**, or **open**. General rule used
throughout: **PL only when you need hard real-time determinism, raw bandwidth too high for
Linux to comfortably move, or tight multi-sensor timestamp sync — otherwise use the PS's
built-in Linux peripherals**, since the whole ROS2 driver ecosystem assumes a Linux device node
and custom PL sensor logic means custom drivers to build and maintain. On KR260 specifically,
"PS peripheral" in practice means **USB** — see §6 for why the PMOD headers don't give you a
free/simple PS path the way that instinct might suggest on other boards.

| Sensor / device | Interface (confirmed) | Recommended path | Notes |
|---|---|---|---|
| **BlueRobotics Ping2** echosounder/altimeter (**existing**) | UART TTL (0–5V), binary "Ping Protocol," default 115200 baud (auto-negotiable 9600–3M) | **USB** (BlueRobotics USB-serial adapter → USB1 hub — see §6) | Low bandwidth, request/response protocol — no case for PL. Ping is TTL 0–5V, not 3.3V — use the official BlueRobotics USB adapter cable (as the current boat likely already does) rather than wiring raw TTL into a PMOD pin, to sidestep level-shifting entirely. This is the core bathymetric data source — see §8. |
| **BlueRobotics T200** thrusters ×2 + **Basic ESC** ×2 (**decided**) | Standard RC PWM, 1100–1900µs @ 50Hz, 1500µs = stop | **PL PWM generation, PMOD J2 (§6), through the PWM mux below** — full chain in §13 | Basic ESC chosen on cost grounds: the team already owns one Basic-ESC-driven thruster. Previous team reports these "haul ass" on lakes; an inherited assumption for river current, not river-tested — worth a sanity check once on the water. The Thruster Commander is **not** in the signal path (potentiometer-only inputs, no source selection); it stays a bench-test tool (§13.3). |
| **PWM multiplexer — Pololu 4-channel RC servo mux** (**recommended, not yet bought or bench-tested**) | RC servo PWM in and out. Master and slave inputs, 4 channels; SEL takes a 0.5–2.5 ms pulse; 2.5–16 V supply | Sits between the RC receiver + KR260 PMOD J2 and the two Basic ESCs — **no KR260 port used**, see §13.2–13.3 | ~$18. A spare RC channel on SEL switches manual (RC receiver) vs. autonomous (KR260). Works with the KR260 hung or unpowered. Still to verify: it passes 1100–1900 µs unchanged and accepts the KR260's 3.3 V PWM. |
| **RC transmitter + receiver — RadioMaster Pocket (ELRS) + ER8 receiver** (**recommended, not yet bought**) | 2.4 GHz ELRS link; ER8 has 8 PWM outputs plus a CRSF/SBUS serial output | PWM outputs → mux master inputs. Optional serial output → KR260 for the return-to-beacon trigger (§3.1; needs a serial path, see §6) | ~$107 together. Per-channel failsafe (988–2012 µs) is set in the receiver's web UI; set SEL's failsafe on purpose (§13.5). Still to verify: EdgeTX tank mixing, ELRS-to-SBUS serial for `sbus_serial`, and real-world range. |
| **RPLidar S2** (**chosen; replaces A2M12**) | TTL UART, ships with a USB adapter and micro-USB cable | **USB**, via its adapter (USB1 hub — see §6) | Chosen for sunlight tolerance: the A2M12 is marketed for outdoor use "without direct sunlight" with no published ambient-light spec, while the S2 is rated for 80 klux and IP65, with a 30 m range vs. 12 m ($399 vs. $229). ROS2 support does not separate them: `ros-humble-rplidar-ros` 2.1.4 installs from the Humble apt repo, and Slamtec's `sllidar_ros2` (source build, S2 launch file `view_sllidar_s2_launch.py`) also supports it. Still to confirm: the adapter handles scan-motor control with no PL work. |
| **Marvelmind Super-MP beacons** (hedgehog) (**existing**) | UART, CMOS 3.3V, default 500kbps (configurable down to 4.8kbps), CSV stream; or USB-CDC virtual COM port | **USB** (native USB-CDC, USB1 hub — see §6) | Simplest sensor to bring in — no adapter needed. Bigger role than "just a sensor": GPS-denial positioning under bridges (§8) and the anchor for return-to-beacon retrieval (§3.1). Beacon locations must be georeferenced to GPS (§14). |
| **GPS — u-blox NEO-M8N USB-C IP67 receiver** (**chosen; replaces Here 3+**, ~€90, [GNSS Store](https://gnss.store/products/elt0380)) | USB-C, standard NMEA/UBX over USB-serial | **USB** (USB1 hub — see §6) | The Here 3+ is DroneCAN (CAN bus, built for Cube/ArduPilot) and won't plug into the KR260 without a CAN transceiver and a DroneCAN Linux stack, so it's out; the §6 CAN/J21 contingency is no longer needed. Precision isn't a requirement: Marvelmind covers the GPS-denied bridge segments. Driver: `ros-humble-nmea-navsat-driver` (apt), feeding `robot_localization`'s `navsat_transform_node` (§8). An M9N is an acceptable substitute. |
| **Camera — Luxonis OAK-D family** (**chosen; replaces RealSense D435**) | USB3 (DepthAI) | **USB0, port A, dedicated** — see §6 | Stereo depth + RGB at a reasonable price. No USB OAK-D has an IP rating, so waterproofing is the team's 3D-printed chassis with an anti-reflective glass panel and hydrophobic coating (§5). Variant still to pick: **OAK-D S2 ($329) recommended**, OAK-D Lite ($269) as the budget option. Driver: `ros-humble-depthai-ros` (2.12.2 in the apt repo for arm64). Stereo depth is short-range (about 7.5 cm baseline). Not yet tested on the KR260. |
| **Heading source (compass/IMU)** (**open**) | To be decided | Likely USB or an existing sensor | The Here 3+ had a built-in compass and IMU, and a plain GNSS module has neither. GPS course-over-ground is unreliable at low speed in current. Options: an external compass/IMU, the OAK-D's onboard IMU if usable, or dual-GNSS heading. Needed before finalizing the §8 fusion design. |

---

## 5. Camera — options, priced

Current RealSense D435 is confirmed going away. One correction to the earlier plan: the KR260's
native "PL-ingestion" camera path is **not** a generic MIPI CSI-2 ribbon connector the way the
KV260 (Vision AI kit)'s is — KR260's carrier card exposes an **SLVS-EC** connector instead,
targeted at industrial/high-performance vision sensor modules. The reference design for it is
FRAMOS's [FSM-IMX547 kit](https://framos.com/news/framos-launches-fsm-imx547-camera-accessory-for-the-amd-xilinx-kria-kr260-robotics-starter-kit/)
(Sony IMX547, up to 2472×2128 @ 120fps) — but it's **monochrome**, industrial/quote-priced (no
public price found), and a structurally different ecosystem from the commodity MIPI CSI-2
cameras (e.g. Allied Vision Alvium) that KV260 tutorials use — those target KV260's different
carrier and aren't confirmed to attach to KR260 without their own adapter work. This meaningfully
weakens the case for chasing "true PL ingestion" for the MVP — it's a real option but a much
bigger lift (mono only, unclear color story, unverified adapter path) than the original plan
implied.

KR260 does have **4× USB3.0 ports** confirmed on the carrier, which makes the USB3 path the
straightforward, low-risk default.

| Option | Interface | Price | Notes |
|---|---|---|---|
| RealSense D435 (current) | USB3 UVC | ~$300–350 (~$314 official store) | Baseline for comparison — team says this one "sucks," reason unstated (FOV? range? robustness?) — worth nailing down before assuming a same-family upgrade fixes it. |
| RealSense D455 | USB 3.1 | ~$270–420 depending on retailer (~$419 official store) | Longer range (~6m vs. D435's ~3m) and wider FOV than D435 — likely upgrade if range/FOV was the D435 complaint. Note: RealSense spun off from Intel into an independent company (RealSense, Inc.) in 2025; line is still active. |
| Luxonis OAK-D Lite / OAK-D / OAK-D S2 | USB3 | $269 / $329 / $329 | Stereo depth + RGB with onboard Myriad X AI acceleration — the onboard AI is redundant given the DPU is already doing YOLO, so pay for it only if the stereo depth quality/SDK is otherwise preferred over RealSense. |
| Luxonis OAK-D Pro / Pro W | USB3 | $429 / $529 | Adds active IR illumination for low-light depth — probably unnecessary for daytime river surveying. |
| Allied Vision Alvium 1500-C (MIPI CSI-2) | MIPI CSI-2 | $277–$477 depending on sensor/resolution | Confirmed compatible with **KV260** via a dedicated adapter board — compatibility with **KR260**'s different carrier/connector is unverified, and this is a single 2D sensor (no depth without a stereo pair + your own algorithm). |
| FRAMOS FSM-IMX547 (SLVS-EC) | SLVS-EC (KR260-native) | Quote-only, not public | The "true PL ingestion" reference path for KR260 specifically — monochrome, industrial-grade, higher effort/cost. |

**Decision: Luxonis OAK-D family over USB3.** Chosen for stereo depth plus a good RGB camera at a
reasonable price. Treat SLVS-EC/PL-native ingestion as a stretch goal only if CPU load or latency
becomes a measured bottleneck.

- **Variant:** OAK-D S2 ($329, 12 MP RGB, autofocus or fixed-focus) is the recommendation; OAK-D
  Lite ($269, 4K RGB, depth listed up to about 33 ft / 10 m) is the cheaper fallback. Fixed focus
  is probably the safer choice behind a glass panel, since autofocus can hunt on the glass.
- **The onboard Myriad X AI is redundant** with the DPU (see the table); the camera is being
  bought for depth and RGB.
- **Stereo depth range is limited.** With a ~7.5 cm baseline, depth error grows quickly with
  distance, so stereo depth is a short-range obstacle aid. Longer-range obstacle ranging comes
  from the RPLidar S2 (§4), and object recognition from YOLO on the RGB stream.
- **Waterproofing is the team's chassis, not the camera.** None of the USB OAK-D models has an IP
  rating (only the PoE variants do, and PoE would need a switch since the KR260's second Ethernet
  jack is PL-routed, §7). Plan for: glass panel close to and gasketed against both stereo lenses
  (gaps and reflections degrade depth), anti-reflective coating, a desiccant pack or vent plug
  against condensation, and a thermal path for camera heat.

**Action items:**
- [ ] Pick S2 vs. Lite, and fixed vs. autofocus.
- [ ] Test DepthAI on the KR260 (USB udev rule for vendor `03e7`, USB3 enumeration, sustained
      framerate) before committing to the enclosure design.

---

## 6. Physical port assignment (KR260 carrier)

Worth locking down early — and checking the actual carrier connectors changes the earlier
PS/PL framing in one important way.

**Key correction:** the **4 PMOD headers (J2, J18, J19, J20) and the 40-pin Raspberry Pi
header on KR260 are wired straight to the PL fabric, not to PS MIO/EMIO.** That means *any*
PMOD/RPi-header sensor — even something as simple as a plain UART or GPIO line — requires
adding an IP core (AXI UART Lite, IIC, GPIO, etc.) to the Vivado block design, a new bitstream,
and a device-tree node. There's no "just wire it to a PMOD, it's basically free" path on this
board; PMOD use is real PL work every time. The only genuinely zero-PL-work sensor path is the
**4× USB3.0 ports**, which land on the PS's hardened USB controllers and show up as normal
Linux device nodes.

That flips the original instinct (lean on PMOD for most sensors) around: given that every
sensor already in this plan speaks USB or serial-over-USB, **USB is the natural home for
nearly everything**, and PMOD should be reserved for the things that are PL work regardless
(thruster PWM, and a good candidate use below).

**Hard constraint — flag this and keep it in view: 5 sensors want USB (Ping2/sonar, RPLidar S2,
Marvelmind, GPS, camera), but the board has only 4 physical USB3 ports.** This doesn't block
the USB-first plan, but it means one port has to be shared, and it should be a deliberate
choice, not something discovered mid-build.

**USB3 topology matters for how to share, too:** the 4 physical ports aren't 4 independent
controllers — they're 2 PS USB3 controllers, each feeding a 2-port hub (USB0 → 2 ports, USB1 →
2 ports). A bandwidth-hungry device sharing a hub pair with other USB traffic can be starved,
so the fix is to keep the camera alone on its own hub pair and push *all four* of the
low-bandwidth sensors through a single small powered USB hub on one port of the other pair —
they're each trivially low-bandwidth (serial-speed UART-over-USB or CDC, nowhere near USB3
territory), so sharing one hub port among all four costs nothing in practice, and it's what
actually resolves the 5-vs-4 shortfall.

**Proposed port map:**

| Port | Assignment |
|---|---|
| USB0, port A | Camera — dedicated, don't share this hub pair with anything bandwidth-heavy |
| USB0, port B | Free — keyboard/mouse for desktop-mode bench debugging, or a WiFi dongle (ties to §3's command-link decision); not needed simultaneously with the camera in normal (non-desktop) operation |
| USB1, port A | Small powered USB hub → Ping2 (BlueRobotics USB-serial adapter), RPLidar S2 (its USB adapter), Marvelmind hedgehog (native USB-CDC), GPS (NEO-M8N USB-C), **and** optionally a USB-serial adapter for the ER8 receiver's SBUS/CRSF output (return-to-beacon trigger, §3.1) — this hub is where the 5-vs-4 port shortfall gets absorbed. A heading sensor (§4, open) may add one more. |
| USB1, port B | Free — spare/expansion headroom |
| PMOD J2 | Thruster PWM ×2 (autonomous path) → the slave inputs of the PWM mux, which feeds the Basic ESCs (§13.2). A 12-pin Pmod has plenty of pins for 2 PWM outputs with room to spare. |
| PMOD J18 | Hardware e-stop input, monitored directly by PL logic that gates the PWM outputs — a stop path that still works even if Linux/ROS2/the network link is dead. **With the mux, this gates only the autonomous path**; what the e-stop must cut for the manual path too is an open decision (§13.4). |
| PMOD J19, J20 | Reserve — spare capacity for small future PL peripherals (single sensor/actuator, low pin count) |
| **RPi HAT header, J21** | Reserve — a plausible use is decoding the ER8's SBUS output (§3.1) if a USB-serial adapter isn't used instead |

**GPS/CAN contingency — resolved, no longer needed.** §4 previously flagged that if GPS turned
out to be a CAN/DroneCAN unit (as the Here 3+ is), it would need J21 + an external CAN
transceiver, since **KR260 has no CAN connector broken out on any carrier connector** and
reaching the PS's hardened CAN-FD peripheral means routing it out through EMIO to a PL pin.
Since §4 now recommends replacing the Here 3+ with a plain USB/UART GNSS module instead of
working around DroneCAN, this whole contingency is moot — GPS just joins the USB1 hub with the
other four sensors, no PL work involved.

Worth being deliberate about *not* also moving the thruster PWM/e-stop functions onto J21 just
because it has plenty of spare pins to hold everything: consolidating safety-critical e-stop
wiring onto the same connector/cable as other functions means one loose connector takes out
both at once. Keeping e-stop on its own dedicated PMOD (J18) is the safer default even though
J21 could technically fit it.

**Action items:**
- [ ] Confirm this port map with the team before wiring anything — re-routing after enclosures
      are built is more annoying than catching it on paper.
- [ ] Buy/allocate a small powered USB hub for USB1 port A — required by the plan above, not
      optional.
- [ ] Confirm whether the RPLidar's included adapter handles scan-motor PWM onboard (as
      expected — see §4) or exposes a raw PWM pin needing its own PL generation. Applies equally
      if swapping to the recommended S2.
- [ ] Purchase the recommended USB GNSS module (§4) and confirm it fits the USB1 hub as planned.

---

## 7. Development environment & remote access

Current setup: KR260 configured as a desktop (monitor + keyboard/mouse) for ROS2 development —
a reasonable default for bring-up. Worth planning explicitly for headless/remote operation too,
since the boat obviously won't have a monitor attached in the field, and remote access from
home is now part of the plan.

**Plan:** static IP on the board, reachable from a lab laptop that stays on-site; SSH from home
into that laptop, then from the laptop into the board. Structurally this is sound — only the
laptop's own remote-in path crosses the public internet (whatever your institution's
VPN/remote-access solution already is), so the board itself never needs to be internet-facing,
just reachable on the lab LAN.

Two things worth getting right before configuring it:
- **Use the PS-native Ethernet port, not the PL-routed one.** KR260 exposes two physical
  Ethernet jacks, and earlier research on this board's connectors found one of them (J10) is
  routed through PL rather than the PS's hardened GEM controller (likely there for TSN/deterministic
  networking use cases, not general use). A PL-routed interface won't behave like a normal Linux
  NIC until PL is actually built with a driver/device-tree entry for it. Confirm which physical
  jack maps to the PS-native controller (it should already show up and work in Ubuntu with zero
  Vivado work — check with `ip link` / `ethtool`) and use that one for the static IP.
- **Check with lab/campus IT before hand-picking an address.** If the lab network is centrally
  managed (DHCP-controlled, possibly a monitored VLAN), manually configuring an arbitrary static
  IP client-side risks a conflict with another device or getting flagged. The more robust
  equivalent — same practical result, the board always answers at the same address — is asking
  IT for a **DHCP reservation** bound to the board's MAC address, rather than hard-configuring a
  static IP on the board itself. Worth a quick check before assuming either approach.

Once the address is settled: configure it via netplan (`/etc/netplan/*.yaml` on Ubuntu 22.04),
and use SSH keys rather than password auth for the laptop↔board hop, since this will be a
routine path. One practical footnote: the lab laptop being always-on and reachable is now a
dependency of home access to the board — worth disabling its sleep and setting SSH to start on
boot there.

**Action items:**
- [ ] Confirm which physical Ethernet jack is PS-native vs. PL-routed before configuring
      anything (`ip link` / `ethtool` on the board).
- [ ] Check with lab/campus IT: hand-set static IP vs. DHCP reservation.
- [ ] Set up SSH keys for the laptop↔board hop; disable sleep and enable SSH-on-boot on the
      lab laptop.

---

## 8. Navigation & data collection architecture

Clarified data/control flow: **sonar (Ping2) bathymetric data is recorded in parallel with GPS
position**, since a depth reading is only useful survey data once it's geotagged. **GPS also
drives steering** (waypoint following), blended with **YOLO-based object detection** for
reactive obstacle avoidance (pylons, rocks, riverbank) — this reactive layer is exactly the
kind of low-level control logic that §2's Option A/B decision is about.

**The known failure mode: GPS drops under bridges** — exactly the survey target per the SOW
("map the riverbed near bridge piers"), which makes this more than a driving-convenience
problem: if position is unknown while passing under a bridge, the bathymetric data collected
in the most important segment of the whole mission is unusable. The planned fix is the
**Marvelmind beacon system**: beacons placed on the riverbanks bracketing a bridge, with the
boat-mounted hedgehog producing a local position fix referenced to those beacons — effectively
synthetic GPS for exactly the GPS-denied segment.

This is a sensor-fusion problem, not just a "swap sources" problem — the boat needs to blend
GPS (open river) and Marvelmind-derived position (under/near bridges) into one continuous
position estimate, ideally handled by ROS2's standard
[`robot_localization`](https://github.com/cra-ros-pkg/robot_localization) package (EKF/UKF
fusion, with `navsat_transform` for GPS specifically) rather than hand-rolled blending logic.

Marvelmind does publish official ROS2 packages
([marvelmind_ros2_upstream](https://github.com/MarvelmindRobotics/marvelmind_ros2_upstream) +
`marvelmind_ros2_msgs_upstream`), which is good — but last pushed **November 2022**, so treat
it as a starting point that may need porting/patching for current ROS2 Humble rather than a
guaranteed drop-in.

**Action items:**
- [ ] Confirm the Marvelmind ROS2 package builds and runs cleanly on ROS2 Humble; budget time to
      patch it if not.
- [ ] Design the GPS↔Marvelmind fusion/handoff explicitly (likely `robot_localization`) rather
      than leaving it implicit.
- [ ] Decide how the YOLO-avoidance layer and GPS/Marvelmind waypoint-following layer arbitrate
      (ties to §2).

---

## 9. Reuse research — previous team's code and datasets

**ROS2 code**: the Jetson/Cube team already used ROS2 Humble, and since this team is also on
Humble (§1), their Linux-side sensor integration nodes (at minimum: Ping2, RPLidar, Marvelmind,
GPS drivers) are plausible direct or near-direct reuse candidates — much lower risk than writing
these from scratch. **Action item:** get access to their repo(s) before starting any Linux-side
sensor driver work.

**Training dataset**: earlier assumption in this doc was that a custom river/bridge dataset
would need to be collected from scratch. Correction: the previous team reportedly already found
free public datasets that showed strong fidelity when tested on local rivers — if their specific
sources still work, this removes a major long-pole item. **Action item:** get the specific
dataset name(s)/links from the previous team before assuming any collection work is needed.

As a backup/cross-check if their sources turn out to be unavailable or insufficient, public
inland-waterway/USV datasets exist and are worth knowing about:
[USVInland](https://github.com/ORCA-Uboat/USVInland-Dataset) (26km of real inland-waterway data:
LiDAR, stereo, radar, GPS, IMU — includes a water-segmentation task, directly relevant) and
[MODS](https://arxiv.org/abs/2105.02359) (maritime obstacle detection/segmentation benchmark,
~81k stereo images). Neither is confirmed as what the previous team used — just a fallback if
needed.

**Custom-class YOLO confirmed non-issue for the DPU itself** (checked directly, regardless of
which dataset is used): the DPU is class-agnostic — it just executes compiled network
instructions. Going from a pretrained Model Zoo checkpoint to a model trained on
project-specific classes (riverbank, water, bridge pylons, rocks, etc.) only requires updating
three application-layer config files (per
[AMD's Kria SmartCamera customization docs](https://xilinx.github.io/kria-apps-docs/creating_applications/2022.1/build/html/docs/AI_customization.html)):
`aiinference.json` (model path), `preprocess.json` (mean/scale matching training preprocessing —
note Vitis AI's channel order is B,G,R), and `label.json` (class list/order). No DPU-level
obstacle either way.

**KRS (Kria Robotics Stack)**: checked directly — [Xilinx/KRS](https://github.com/Xilinx/KRS)
has never left **alpha** (only release tag is `alpha`, Oct 2021), and real feature commits
stopped around 2023 — recent activity is documentation wording/link fixes only. Use it for
reference/patterns (it documents wiring HLS/Vitis-Vision-Library accelerators into ROS2 nodes on
Kria) but don't build the critical path on it as a framework/dependency — write ROS2 nodes that
call VART/XRT directly instead.

---

## 10. Memory budget — KR260's 4GB is a real constraint, plan it early

Confirmed: the KR260/K26 SOM has **4GB DDR4 total, non-ECC — shared between PS (Linux/ROS2) and
PL (DPU) alike**, since both sides access the same physical DDR through the AXI HP/HPC ports.
There's no separate "PL memory" pool to fall back on beyond small on-chip BRAM/URAM buffers.
That means Ubuntu + ROS2 (multiple nodes: sensor drivers, `robot_localization`, YOLO/VART
inference node, rosbag/data logging, mission planning) and the DPU's model weights + activation
buffers + frame buffers are all drawing from the same 4GB pool — this is worth a real budget
(rough MB estimate per component) before the design gets much further, not just a "hope it
fits."

**Two real levers, and one that's more about compute load than memory:**
- **Model size + quantization + pruning (the actual memory-footprint levers).** The DPU only
  ever runs INT8-quantized models — quantization to INT8 is mandatory, not a tunable knob, so
  "playing with quantization" mostly means: (a) picking a smaller YOLO variant (YOLOv3-tiny,
  YOLOX-Nano, etc. — far fewer parameters than full YOLOv3/v4/v5) and (b) using Vitis AI's
  **AI Optimizer** (pruning tool) to shrink a trained model further before quantizing — there's
  a public example of exactly this combination:
  [pruning YOLOv3 for Vitis AI on a Kria board](https://www.hackster.io/LogicTronix/pruning-yolov3-and-deploying-with-vitis-ai-on-kria-kv260-de654a).
  These directly shrink what's resident in memory.
- **DPU architecture size (B-size, e.g. B1600 vs. B4096)** trades inference throughput for a
  smaller internal buffer footprint — a PL-side lever alongside the model-side ones above.
- **Inference framerate** is a real lever for compute load, power, and thermal headroom, but
  *not* directly for memory footprint — a model's resident weight/buffer size is roughly
  constant regardless of how often you run it. Worth keeping this distinction straight: framerate
  reduction solves a different problem than the 4GB ceiling does.

**Action item:** build an actual rough memory budget (OS/ROS2 baseline + per-node estimate + DPU
model+buffer footprint for the chosen YOLO variant/B-size + camera/LiDAR buffers) once the model
and DPU size are chosen — before assuming it'll fit.

---

## 11. DDR / memory-bandwidth budget — flag early

Distinct from the capacity question above: the DPU, any PL-side camera capture, and PL-generated
PWM/UART-adjacent logic all share the same HP/HPC AXI ports into DDR, which is a *throughput*
constraint, not a capacity one. Once the camera and DPU architecture (B-size) are chosen, do a
rough bandwidth budget before finalizing the Vivado block design.

---

## 12. Collaboration workflow (source control across a two-person team)

**Decision: adopting the git-based approach below for Vivado/PetaLinux/Vitis source control.**
NAS use (datasets, full project backups, and the artifact shelf described below) is still being
scoped.

Past pain point: committing/copying the **live** Vivado and PetaLinux project directories
wholesale — both regenerate huge binary trees on every build (`.runs/`, `.cache/`, `.sim/`,
`.ip_user_files/`, `.hw/`, `.Xil/` for Vivado; `build/`, `images/linux/`, `pre-built/linux/`,
`components/plnx-workspace/` for PetaLinux). None of that is source; all of it is regenerable
from much smaller inputs. Fix: version only the small text that generates the binaries, treat
everything else as disposable.

**What to track in git vs. regenerate:**
- **Vivado** — track RTL, XDC constraints, `.xci` IP customization files, and Tcl build/rebuild
  scripts. For the block design, export with `write_bd_tcl` and track that regenerate-script
  instead of the binary `.bd`. Don't hand-roll the `.gitignore`: the first time a real project
  exists, run `git init` from **Vivado's own Tcl console** (not a plain shell) — it inspects the
  live project and writes a correct `.gitignore` for it (per [UG1198](https://docs.amd.com/v/u/2016.1-English/ug1198-vivado-revision-control-tutorial)).
- **PetaLinux** — ignore `build/`, `images/linux/`, `pre-built/linux/`,
  `components/plnx-workspace/`, `components/yocto/`; track `project-spec/` (meta-user layer,
  configs, recipes). Run `petalinux-build -x mrproper` before committing to shrink the tree.
  (Note: current Linux base is Kria Ubuntu 22.04, not PetaLinux — keep this section handy in
  case a custom PetaLinux build becomes necessary later.)
- **Vitis (Unified IDE)** — ignore `Debug/`, `Release/`, `.metadata/`; track `vitis-comp.json`,
  linker scripts, app/driver sources.
- **ROS2** — standard colcon convention: track `src/`, ignore `build/`, `install/`, `log/`.

**NAS — good for a shared artifact shelf and backups, not a live working copy.** Use it to drop
exported `.xsa` hardware platforms, `.bit`/boot images, quantized `.xmodel` files, raw training
datasets, and **full project backups** — legitimately binary/bulky, too big for (or simply not
meant for) git history, needs to move between people or just be safely archived without living
in version control. **Don't** point both partners'
actual Vivado project directory at the same NAS path as a live working copy: Vivado has no real
file-locking, so concurrent open/write from two machines risks silent corruption with no
diff/rollback to recover from, and synth/implementation (disk-I/O heavy) run measurably slower
over a network share than local SSD. Keep each person's working copy local; git carries source
sync, NAS carries the artifact drop.

**Block-design concurrency is a process problem, not a tooling one.** Even as Tcl, a block
diagram doesn't meaningfully merge — two simultaneous edits to the same top-level BD conflict in
ways git can't reconcile. Split the design into hierarchical sub-block-designs so each partner
owns a different one, or explicitly serialize edits to the shared top-level BD.

**Branching:** keep `main` always in a known-good, bitstream-generating state; do risky changes
on a branch, merge only after a local build succeeds. Pulling a partner's broken mid-work
hardware state costs a multi-hour synth/impl run to discover — worth avoiding structurally.

---

## 13. Thrusters

Everything needed to turn a navigation/RC command into thrust on the water: the thrusters, their
ESCs, the signal path from the KR260 and from an RC receiver, how control switches between them,
and the safety behavior around it. Ties together §4 (T200/Basic ESC), §6 (PMOD J2/J18), §3 and
§3.1 (manual override, RC), and §2 (Option A/B).

### 13.1 What's decided, and what the hardware requires

- **Thrusters:** 2× BlueRobotics T200 (one per side, differential drive), **Basic ESC** each —
  decided on cost grounds in §4.
- **ESC interface:** standard hobby PWM, **1100–1900 µs at 50 Hz, 1500 µs = stop** (bidirectional
  firmware). Blue Robotics forum guidance for third-party ESCs lists the same requirements:
  2–7S, ≤30 A, BLHeli_S firmware, bidirectional PWM. Third-party ESCs have been [reported to make
  T200s twitch](https://discuss.bluerobotics.com/t/t200-3rd-party-esc-compatibility-issue/20989),
  so treat the Basic ESC as the known-good path and don't swap ESC families casually.
- **Arming:** hobby ESCs generally need a valid neutral (1500 µs) pulse train at power-up before
  they'll respond. Whatever drives the ESC input, including a multiplexer, must present neutral
  from the moment the ESC powers on, not a floating or low line. **Verify on the bench against the
  Basic ESC's documented arming sequence.**
- **Power:** thruster power comes from the existing power system (already solved, carried over).
  Confirm it, with a fuse, can source both thrusters' peak current (T200/Basic ESC datasheet
  figures, not assumed here) and that the ESC battery/BEC ground is common with the signal
  source's ground.
- **Enclosure:** the Basic ESC is a hobby ESC, not waterproof. It lives in a waterproof box with
  the rest of the electronics, with the thruster cable through a penetrator.

### 13.2 The signal chain

```
RC receiver  ──(2 thrust PWM ch)──►  M inputs ┐
                                               │  PWM mux  ──(L/R PWM)──►  Basic ESC ×2 ──► T200 ×2
KR260 PL PWM ──(2 PWM, PMOD J2)───►  S inputs ┘
Spare RC ch  ────────────────────►  SEL
```

**KR260 side (autonomous path):**
- PWM generation in **PL**, on **PMOD J2** (§6): a small AXI-attached PWM core (two channels,
  50 Hz period, pulse width settable at ~1 µs resolution over 1100–1900 µs), plus a device-tree
  node and a bitstream. PMOD outputs are 3.3 V logic. **Confirm the mux/ESC input registers 3.3 V
  reliably** (Pololu's slave-input logic threshold is not stated on its product page).
- A ROS2 node converts navigation commands (speed/steer or left/right) into the PL registers.
  Mixing to left/right happens here for the autonomous path.
- **Watchdog in PL:** if the PS stops refreshing the PWM registers (Linux/ROS2 hang), the PL
  forces both outputs to neutral after a short timeout, without software involvement. This is
  the same "works even when Linux is dead" idea as the e-stop design in §6.
- Neutral is the reset state. On bitstream load or PS reset the outputs are 1500 µs, never 0.

**RC side (manual path):** a hobby RC receiver with PWM outputs. Left/right mixing for manual
driving is done in the transmitter or receiver (e.g. a differential/"tank" mix), since the mux
passes two independent channels straight through. This is separate from the SBUS decode described
in §3.1, which is a single-bit "return to beacon" trigger read by the KR260.

### 13.3 Options for switching between KR260 and RC

The BlueRobotics Thruster Commander can't do this: its inputs are potentiometer
inputs, mode is chosen by which pins are wired, and it has no source selection. Checked against
its manual and docs. Options that can:

| Option | Switching | Cost | Notes |
|---|---|---|---|
| **A. Basic ESCs + Pololu 4-channel RC servo multiplexer (recommended)** | Hardware. A spare RC channel on SEL picks master (M) or slave (S) inputs per a user-set threshold (default ~1700 µs, ±64 µs hysteresis). | ~$18 ([product](https://www.pololu.com/product/2806)) | Purpose-built for autonomous/manual override. 2.5–16 V supply, SEL accepts 0.5–2.5 ms pulses at 10–330 Hz. Failsafe is a jumper: off, master inputs take control if SEL is lost; on, outputs go low. Keeps the Basic ESCs. Works with the KR260 hung or unpowered. |
| B. Basic ESCs + Acroname RxMux | Same idea, 8 channels, 2 sources. | ~$19 ([product](https://acroname.com/store/s56-rxmux-1)) | Defaults to input A if SEL is absent, and the vendor states it provides no failsafe or redundancy by itself. More channels than needed here. |
| C. Mux inside the PL | Logic in the KR260's fabric selects between the decoded RC signal and the autonomous PWM. | No hardware cost | Extends the J18 e-stop gating design. Loses manual control if the KR260 loses power or the PL is unconfigured, which is exactly when a manual override matters. Acceptable only if the KR260 is trusted to stay up. |
| D. Option B hybrid low-level board (§2) | Native to the flight-controller firmware (ArduRover RC passthrough and mode arbitration). | Depends on board | No separate mux needed and no PL PWM work. Outputs PWM to the ESCs directly. Only applicable if §2 chooses B. |
| E. VESC-class ESCs | Firmware supports combined PPM+UART control ([Flipsky](https://flipsky.net/blogs/vesc-tool/vx4-three-control-mode-ppm-uart-ppm-and-uart)). | Varies | Which input wins when both are active was not found documented, and T200 compatibility with VESC is unconfirmed. Not recommended without a bench test. |
| F. Roboteq BLDC controllers | RC, serial and CAN inputs. | High | Sized for much larger motors than a T200. Input-priority behavior not verified. Overkill here. |

**Recommendation: Option A**, unless §2 selects the hybrid architecture, in which case D removes
the need for it. **Not yet verified on hardware:** that the Pololu mux passes 1100–1900 µs pulses
through unchanged (its page doesn't say so explicitly) and that it accepts the KR260's 3.3 V PWM.
Bench-test both with a scope before wiring the boat.

### 13.4 Safety: where the e-stop actually sits

§6 puts a hardware e-stop input on PMOD J18 that gates the KR260's PWM outputs in the PL. With a
mux, that gate only stops the **autonomous** path: the manual path reaches the ESCs regardless.
Decide explicitly what "e-stop" means:

- **Cut at the ESC power** (a contactor/relay in the thruster supply, driven by the e-stop) is the
  only version that stops the boat whichever source is selected. A stop at the PWM level would
  have to sit downstream of the mux.
- **Neutral-forcing after the mux** (a second gate between the mux output and the ESC inputs) is
  the lower-power alternative.
- The RC failsafe setting on the SEL channel decides who takes control when the RC link drops
  (KR260, which could run return-to-beacon, or the manual channel, likely at neutral). Choose it
  on purpose and write it down.

### 13.5 RC transmitter and receiver

The mux (§13.3 Option A) needs an RC receiver that has PWM outputs and lets you set a failsafe
value on each channel. Channel budget: left thrust, right thrust, SEL (mode switch), plus one
spare for the return-to-beacon trigger (§3.1). The mux's SEL input accepts 0.5–2.5 ms pulses at
10–330 Hz, so any standard RC channel works electrically.

**Failsafe is the requirement that matters.** Pololu's default SEL threshold is about 1700 µs,
with the slave (KR260) inputs live above it. If the team wants the KR260 to take over when the RC
link drops (e.g. to run return-to-beacon), SEL's failsafe value must sit above roughly 1700 µs
plus hysteresis. The two thrust channels should fail to 1500 µs (stop).

| Option | Price | Failsafe | Notes |
|---|---|---|---|
| **RadioMaster Pocket (ELRS) + ER8 receiver (recommended)** | ~$71.50 + $34.99 | ELRS sets each channel's failsafe between 988 and 2012 µs from the receiver's web UI ([ExpressLRS docs](https://www.expresslrs.org/hardware/pwm-receivers/), [RadioMaster guide](https://radiomasterrc.freshdesk.com/support/solutions/articles/64000308559-expresslrs-pwm-receiver-setup-and-configuration-guide)). | ER8: 8 PWM outputs, 4.5–8.4 V input, dual antenna, plus a CRSF/SBUS serial output ([product](https://radiomasterrc.com/products/er8-2-4ghz-elrs-pwm-receiver)). Pocket runs EdgeTX ([product](https://radiomasterrc.com/products/pocket-radio-controller-m2)). |
| FlySky FS-i6X + FS-iA6B | price not found | Manual says failsafe is per channel, but a [GitHub issue](https://github.com/iNavFlight/inav/issues/6210) reports it failing to trigger when the transmitter powers off. Not confirmed fixed. | Cheapest, but an unreliable failsafe is the wrong failure mode for a boat. Avoid. |
| FrSky ACCST/ACCESS (Taranis + X8R-class) | not checked | Per-channel modes: no pulse, hold, custom ([G-RX8 manual](https://www.frsky-rc.com/wp-content/uploads/Downloads/Manual/G-RX8/G-RX8%20ACCST%20-Manual.pdf)). | Proven but older. The ER8 is marketed as a direct replacement for the X8R. |

**Recommendation: Pocket (ELRS) + ER8.** Set failsafe explicitly on every channel rather than
trusting defaults: the ER8 defaults to 1500 µs except output 3, which defaults to 988 µs. ELRS
declares failsafe after 1 second with no valid packet or when link quality reaches 0, so there is
up to a second before the KR260 takes over.

**Not yet verified:**
- ELRS receivers speak CRSF natively, so `sbus_serial` (§3.1) may need the receiver's serial
  protocol set to SBUS. Confirm before relying on it for the return-to-beacon trigger.
- The Pocket product page doesn't detail EdgeTX's left/right ("tank") mixing. EdgeTX's mixer is
  believed to support it, but confirm before buying.
- No real-world range figure was found for the ER8. Check the link against the longest river
  distance planned.
- The ER8 product page doesn't mention per-channel failsafe; that comes from the ExpressLRS docs
  and RadioMaster's guide.

### 13.6 Build and test checklist

- [ ] Bench: one T200 + Basic ESC + KR260 PL PWM alone (no mux): arming, stop, both directions,
      deadband around 1500 µs (check the T200 datasheet for the exact range).
- [ ] Bench: add the mux; scope the output pulse widths against the inputs (pass-through
      accuracy), confirm 3.3 V slave input works, and test SEL switching mid-run.
- [ ] Confirm arming works through the mux, including power-up with SEL in each position.
- [ ] Test PL watchdog: kill the ROS2 node, then hang Linux; outputs must go to neutral.
- [ ] Test SEL loss, RC receiver power loss, and KR260 power loss; record who has control in each.
- [ ] Wire and test the e-stop per §13.4 in whichever form the team chooses.
- [ ] On-water check of thrust against river current (§14 item; inherited assumption).

**Action items:**
- [ ] Choose the switching option (§13.3), pending the Option A/B decision in §2.
- [ ] Decide what the e-stop cuts and where (§13.4).
- [ ] Confirm the RC pair (§13.5, recommended Pocket ELRS + ER8): check EdgeTX tank mixing and
      range, set per-channel failsafe (SEL above ~1700 µs if the KR260 should take over on link
      loss), and confirm the SBUS-vs-CRSF serial output for the return-to-beacon trigger.
- [ ] Confirm power-system current capacity and fusing against T200 peak draw.

---

## 14. Open questions / action items

- [ ] **Choose the thruster switching option and e-stop design (§13)**: mux vs. hybrid board,
      and what the e-stop physically cuts.
- [ ] **Decide Option A vs. B (§2)** — full autopilot replacement vs. keep a lightweight
      low-level controller.
- [ ] **Define the telemetry/command-link replacement (§3)** — specifically, confirm what
      provides manual override/e-stop now that the Cube's radio is gone, and settle whether
      RC/telemetry lives on a low-level board (Option B) or on the KR260 via SBUS + a custom node
      (§3.1) — depends on the Option A/B decision above.
- [x] ~~Identify the current GPS module~~ — confirmed **Here 3+ (DroneCAN, Cube-specific)**;
      **recommend replacing** with a plain USB/UART GNSS module (§4). **Action item:** purchase
      and confirm.
- [x] ~~Pick a replacement camera~~ — **Luxonis OAK-D family chosen** (§5). Still open: S2 vs.
      Lite, fixed vs. autofocus, and a DepthAI test on the KR260.
- [ ] **Heading source.** The Here 3+ has a built-in compass and IMU; replacing it with a plain
      GNSS module removes both. A single GNSS receiver gives course-over-ground only, which is
      unreliable at low speed in current. Decide where heading comes from (an external
      compass/IMU, whether the OAK-D's onboard IMU is usable, or dual-GNSS heading) before
      finalizing the §8 fusion design.
- [x] ~~Decide the GPS module~~ — **NEO-M8N (or M9N) USB module chosen** (§4). Precision GPS
      isn't needed because Marvelmind covers the GPS-denied bridge segments. Purchase and confirm.
- [ ] **Georeference the Marvelmind beacons.** Marvelmind positions are in a local frame, so the
      beacon locations must be tied to GPS coordinates (§8). The GPS quality at beacon placement
      sets the absolute accuracy of the under-bridge data; confirm meter-level is acceptable for
      the survey.
- [ ] Sanity-check that the Basic-ESC/T200 thrust is adequate against river current, not just
      lake conditions (inherited assumption from the previous team).
- [x] ~~Decide whether the RPLidar A2M12 will work well with the KR260~~ — the KR260/USB
      interface side is fine either way; the real issue is the **sensor's own direct-sunlight
      limitation** for outdoor river use (§4). **Recommendation: replace with RPLidar S2**
      ($399, 80klux sunlight-rated, same USB integration path). **Action item:** purchase and
      confirm.
- [ ] Design the RC-triggered "return to beacon" behavior (§3.1) once §2 is decided — either as
      an ArduRover-native RTL (Option B) or a custom SBUS-triggered ROS2 node using the fused
      `robot_localization` position estimate (Option A / Marvelmind-anchored retrieval).
- [ ] **Sign off on the physical port assignment (§6) as a team** — especially the USB1 hub
      absorbing 4 of the 5 USB-hungry sensors (the 5-sensors-vs-4-ports constraint) — and buy the
      powered USB hub it depends on. Also confirm the RPLidar S2 adapter's scan-motor behavior; the
      GPS CAN contingency is retired (§4).
- [ ] Confirm which Ethernet jack is PS-native (for the static-IP/SSH setup) and check with
      lab/campus IT on static IP vs. DHCP reservation (§7).
- [ ] Get the previous team's ROS2 Humble repo(s) and their specific training-dataset
      references (§9) before starting Linux sensor drivers or dataset collection from scratch.
- [ ] Confirm the Marvelmind ROS2 package runs on current ROS2 Humble (last upstream push was
      Nov 2022) and design the GPS↔Marvelmind fusion explicitly (§8, `robot_localization`).
- [ ] Build a rough memory budget (§10) once the YOLO variant/DPU B-size are chosen.
- [ ] Rough DDR/bandwidth budget (§11) once camera + DPU size are chosen.
- [ ] Scope the NAS's role (datasets, full project backups, artifact shelf — §12) alongside the
      now-decided git workflow, before the Vivado project is first created.

---

## References

- [KR260 DPU-TRD Vivado-flow tutorial (Vitis AI 3.0), LogicTronix/Hackster](https://www.hackster.io/LogicTronix/kria-kr260-dpu-trd-vivado-flow-vitis-ai-3-0-tutorial-0085fd)
- [KR260-DPU-TRD-Vitis-AI-3.0 repo](https://github.com/LogicTronixInc/KR260-DPU-TRD-Vitis-AI-3.0)
- [Vitis AI 3.5 IP and Tool Version Compatibility](https://xilinx.github.io/Vitis-AI/3.5/html/docs/reference/version_compatibility.html)
- [Pruning YOLOv3 and deploying with Vitis AI on a Kria board](https://www.hackster.io/LogicTronix/pruning-yolov3-and-deploying-with-vitis-ai-on-kria-kv260-de654a)
- [Xilinx/KRS repo](https://github.com/Xilinx/KRS)
- [Kria SmartCamera AI customization docs](https://xilinx.github.io/kria-apps-docs/creating_applications/2022.1/build/html/docs/AI_customization.html)
- [AMD Kria AI / Robotics Developer Platform announcement, Advancing AI 2026](https://newsroom.amd.com/news/aai-2026-kria-robotics-dev-platform/)
- [BlueRobotics Ping Sonar Technical Guide](https://bluerobotics.com/learn/ping-sonar-technical-guide/)
- [RPLIDAR A2M12 datasheet](https://bucket-download.slamtec.com/f65f8e37026796c56ddd512d33c7d4308d9edf94/LD310_SLAMTEC_rplidar_datasheet_A2M12_v1.0_en.pdf)
- [BlueRobotics Basic ESC R3 Arduino example (PWM spec)](https://bluerobotics.com/learn/basicesc-r3-example-code-for-arduino/)
- [BlueESC documentation](https://docs.bluerobotics.com/bluesc/)
- [Marvelmind beacon hardware interfaces](https://marvelmind.com/pics/marvelmind_interfaces.pdf)
- [Marvelmind ROS2 upstream package](https://github.com/MarvelmindRobotics/marvelmind_ros2_upstream)
- [Luxonis IP rating docs](https://docs.luxonis.com/hardware/platform/environmental-specifications/ip-rating)
- [Slamtec sllidar_ros2 driver](https://github.com/Slamtec/sllidar_ros2)
- [Pololu 4-Channel RC Servo Multiplexer](https://www.pololu.com/product/2806)
- [Acroname RxMux 8-Channel Servo Multiplexer](https://acroname.com/store/s56-rxmux-1)
- [BlueRobotics Thruster Commander docs](https://docs.bluerobotics.com/commander/)
- [Blue Robotics forum: T200 + third-party ESC compatibility](https://discuss.bluerobotics.com/t/t200-3rd-party-esc-compatibility-issue/20989)
- [Flipsky VESC PPM/UART/PPM+UART control modes](https://flipsky.net/blogs/vesc-tool/vx4-three-control-mode-ppm-uart-ppm-and-uart)
- [ExpressLRS PWM receivers](https://www.expresslrs.org/hardware/pwm-receivers/)
- [RadioMaster ELRS PWM receiver setup guide](https://radiomasterrc.freshdesk.com/support/solutions/articles/64000308559-expresslrs-pwm-receiver-setup-and-configuration-guide)
- [RadioMaster ER8 ELRS PWM receiver](https://radiomasterrc.com/products/er8-2-4ghz-elrs-pwm-receiver)
- [RadioMaster Pocket radio controller](https://radiomasterrc.com/products/pocket-radio-controller-m2)
- [FlySky FS-iA6B failsafe issue (INAV #6210)](https://github.com/iNavFlight/inav/issues/6210)
- [FrSky G-RX8 ACCST manual (failsafe modes)](https://www.frsky-rc.com/wp-content/uploads/Downloads/Manual/G-RX8/G-RX8%20ACCST%20-Manual.pdf)
- [robot_localization ROS2 package](https://github.com/cra-ros-pkg/robot_localization)
- [USVInland dataset](https://github.com/ORCA-Uboat/USVInland-Dataset)
- [MODS maritime obstacle detection benchmark](https://arxiv.org/abs/2105.02359)
- [FRAMOS FSM-IMX547 SLVS-EC camera kit for KR260](https://framos.com/news/framos-launches-fsm-imx547-camera-accessory-for-the-amd-xilinx-kria-kr260-robotics-starter-kit/)
- [KR260 Robotics Starter Kit product brief](https://www.amd.com/content/dam/amd/en/documents/products/som/kria/k26/kr260-product-brief.pdf)
- [KR260 Robotics Starter Kit User Guide (UG1092)](https://docs.amd.com/r/en-US/ug1092-kr260-starter-kit)
- [KR260-XDC pinout constraints reference (community)](https://github.com/Mikeantabian/KR260-XDC)
- [Here 3 Manual (DroneCAN), CubePilot docs](https://docs.cubepilot.org/user-guides/here-3/here-3-manual)
- [NEO-M8N GNSS USB-C IP67 receiver, GNSS Store](https://gnss.store/products/elt0380)
- [nmea_navsat_driver (ROS2 port)](https://index.ros.org/p/nmea_navsat_driver/)
- [RPLIDAR S2 product page (DFRobot)](https://www.dfrobot.com/product-2616.html)
- [Slamtec sllidar_ros2 driver (ROS2, S2/S3 support)](https://github.com/Slamtec/sllidar_ros2)
- [sbus_serial ROS2 package](https://github.com/jenswilly/sbus_serial)
- [ArduPilot Rover RC options / RETURN_TO_LAUNCH](https://ardupilot.org/rover/docs/parameters.html)
