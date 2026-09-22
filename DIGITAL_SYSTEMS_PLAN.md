# FPGA-Based ASV — Digital Systems Plan

Boat 2 of the DOT-funded Autonomous Surface Vehicle (bathymetric surveying / bridge-pier
mapping) project. This sub-team is replacing the current digital stack —
**NVIDIA Jetson Orin Nano + Cube Orange+** — with a single **AMD/Xilinx Kria KR260**
(Zynq UltraScale+ MPSoC), running Vitis AI (DPU + YOLO) and ROS2. The hull itself is a
boogie board with waterproof boxes mounted on it for electronics/sensors.
Power system will be redesigned from the current boat as different digital hardware has different power needs.
This doc is the living plan for the electronics/compute side: toolchain, sensor interfacing,
PS/PL partitioning, and open decisions. Update it as decisions get made, don't let it go stale.

---

## 1. Toolchain

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

AMD announced a new "Kria AI" line (Ryzen AI Embedded X100-based,
CPU/GPU/NPU, not FPGA/DPU) at Advancing AI 2026, shipping Q4 2026. Doesn't affect the
already-purchased KR260 — just confirms the DPU/Zynq path is a mature, stable, no-longer-evolving
branch. Fine for a fixed-scope senior project.

---

## 2. Architecture decision — how much of the Cube Orange+ gets replaced?

**Decision: full replacement (Option A), with the manual-override safety net kept outside the
KR260.** The Cube Orange+ is removed entirely and no separate autopilot board replaces it. The
KR260 does perception, navigation, and motor command generation itself. An **external PWM
multiplexer** sits between the KR260/RC receiver and the ESCs so a human can take over with an RC
transmitter if the autonomous system misbehaves, independent of whether the KR260 is running
(see §13).

For context, the Cube Orange+ was not just a motor driver. It was a full autopilot
(ArduSub/ArduPilot): EKF sensor fusion, closed-loop stabilization, failsafes, mode logic, MAVLink.
Replacing it outright means the team now owns that layer.

**What the KR260 takes on**
- Heading/speed control and waypoint following (for an ASV this is heading/speed PID plus
  waypoint logic, not full attitude stabilization).
- Position estimation: GPS + Marvelmind fusion in `robot_localization` (§8). Heading source is
  still open (§15).
- Motor command generation, including left/right mixing, in a ROS2 node.
- PWM output in the PL (PMOD J2, §6, §13.2) with a PL watchdog that forces neutral if the PS stops
  refreshing the outputs.
- Obstacle avoidance from YOLO on the OAK-D RGB stream and the RPLidar S2 (§4, §8).

**What is not in the system:** ArduPilot, MAVLink, MAVROS, and QGroundControl-style tooling. There
is no MAVLink-speaking autopilot left to bridge to, so §3.1's non-MAVLink path applies.

**Where the safety comes from instead of the autopilot**
- **Manual override:** the external mux plus an RC transmitter/receiver (§13.3, §13.5). It works
  with the KR260 hung or unpowered.
- **PL-side failsafes:** neutral outputs on reset and on a PS watchdog timeout (§13.2), and the
  J18 hardware e-stop input (§6).
- **Still open:** what the e-stop physically cuts once a mux is in the path, since a PWM-level stop
  in the PL only covers the autonomous path (§13.4), and who takes control when the RC link drops
  (§13.5).

**Risk accepted:** control loops and failsafe logic that ArduPilot had hardened over years are now
custom code, so they need real bench and on-water testing (§13.6) before the boat is trusted with
autonomy near a bridge.

**Considered and not chosen:** a hybrid (Option B) that would keep a small ArduRover-class
low-level board, or bare-metal/RTOS code on the Zynq's R5F cores, for stabilization, motor mixing,
and failsafes. It would have reused proven control logic and put RC/telemetry on that board at no
memory cost to the KR260. It is retained in §3.1 and §13.3 only as a reference.

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

**Manual override/e-stop: answered.** The RC receiver's PWM outputs drive the external mux
directly (§13.2, §13.3) — with SEL on manual, the receiver has sole control of the ESCs and the
KR260's state is irrelevant. This satisfies "a way to manually stop/override the boat that doesn't
depend on the same link carrying everything else": the RC link is physically independent of
WiFi/SSH.

**Action item:** live telemetry/monitoring (watching the boat's status, not controlling it) is
still open — see §3.1's last bullet on whether a second radio link beyond WiFi range is needed.

### 3.1 Keeping telemetry cheap on a 4GB board

The instinct to avoid "much memory overhead" for telemetry is right, but the actual lever isn't
which telemetry library is smallest — it's **whether the KR260 needs to run any telemetry/RC
stack at all**. §2 decided full replacement (Option A), so the KR260 does run it, and the
second bullet below is the path that applies. The first bullet is kept for reference only.

- **Reference only, not chosen (Option B, hybrid):** put RC input, telemetry radio, and
  "return home" logic entirely on the small low-level controller board, exactly like the current
  Cube does today. A SiK/RFD900-class radio + ArduRover's own RC/telemetry handling costs the
  KR260 **zero** memory — it never runs on the Zynq PS at all. ArduRover also already has a
  built-in RC-switch-triggered `RETURN_TO_LAUNCH` mode (`RCx_OPTION`), so "one switch flip →
  boat comes home" is a firmware feature, not something to build. **Caveat:** stock RTL returns
  to the *GPS* home position, not a Marvelmind beacon specifically — fine if the retrieval point
  itself has clear sky view (likely, if it's a dock/bank away from the bridge), but if retrieval
  also needs to happen in a GPS-denied spot, that's the case below instead.
- **The path that applies (Option A, full replacement; also required if retrieval must be
  anchored to a Marvelmind beacon, e.g. the retrieval point itself is GPS-denied):** don't reach for
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

**Action item:** build the lightweight SBUS + custom-node path on the KR260 for the
return-to-beacon trigger, and confirm the real-world WiFi range needed before assuming a second
radio link is necessary.

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
| **Marvelmind Super-MP beacons** (hedgehog) (**existing**) | UART, CMOS 3.3V, default 500kbps (configurable down to 4.8kbps), CSV stream; or USB-CDC virtual COM port | **USB** (native USB-CDC, USB1 hub — see §6) | Simplest sensor to bring in — no adapter needed. Bigger role than "just a sensor": GPS-denial positioning under bridges (§8) and the anchor for return-to-beacon retrieval (§3.1). Beacon locations must be georeferenced to GPS (§15). |
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
| Hiwonder/Deptrum Aurora930 Pro | **USB 2.0** | Not found | Considered, **not recommended** — see below. |

**Aurora930 Pro, checked against the team's question — not recommended over the OAK-D.** A
structured-light depth camera (active IR pattern projection + an onboard ASIC depth chip), not a
stereo camera like the OAK-D. Two concerns, checked directly against Hiwonder's own docs:
- **Depth range is only 0.3–3 m.** Shorter than the OAK-D's already-short effective stereo range
  (§ above), which matters more here since it's the camera actually being bought for depth.
- **Structured light is the category of depth sensing that struggles most in direct sunlight** —
  the projected IR pattern gets washed out by ambient IR, which is the textbook reason devices
  like the Kinect don't work outdoors. Hiwonder's spec lists "Operating Illumination: 3~80,000
  Lux," but their own docs don't say whether that's for RGB image quality or for depth accuracy
  specifically — unverified, and it's the exact question that matters for a boat in direct
  sunlight on open water.
- In its favor: USB 2.0 (lighter on the port budget than the OAK-D's USB3, §6), explicit ROS1/ROS2
  support, and low power (<1.6 W). Not enough to outweigh the range and outdoor-depth concerns for
  this application. Keeping the OAK-D decision below.

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
| USB0, port B | Free — spare/expansion headroom (the board is SSH-only, §7, so no keyboard/mouse use is planned here) |
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

## 7. Development environment & remote access — decided, working

**Decided and working: the KR260 is never connected to a monitor or keyboard/mouse.** It's always
used over SSH — from the lab and from home alike. It has a static IP on the PS-native Ethernet
port and boots headless by default (`multi-user.target`, no GNOME/desktop running), after the
fresh Ubuntu 22.04 install and package trim. The physical Ethernet jack question and the
static-IP-vs-lab-IT question are both resolved by this working setup and don't need separate
tracking.

**Action item:**
- [ ] Set up SSH keys in place of password auth, now that this is the daily-driver path.

---

## 8. Navigation & data collection architecture

Clarified data/control flow: **sonar (Ping2) bathymetric data is recorded in parallel with
position**, since a depth reading is only useful survey data once it's geotagged. Position also
drives steering (waypoint following), blended with **YOLO-based object detection** for reactive
obstacle avoidance (pylons, rocks, riverbank) — this reactive layer is exactly the kind of
low-level control logic that §2 assigns to the KR260 (Option A, full replacement).

### 8.1 Live navigation source: Marvelmind-only, GPS only to georeference — with a real caveat

**The team's proposal:** GPS only establishes the Marvelmind beacons' absolute position once
(georeferencing), and the boat never uses GPS live for its own position — it navigates purely off
Marvelmind the whole time.

**Partly right, but there's a coverage catch worth checking before committing to it.**
Marvelmind's beacon-to-beacon range for actual position triangulation (the "submap" range) is
**about 30 m** — this is a different, much shorter number than the ~100–400 m figures Marvelmind
quotes for radio range, which is just the data link and doesn't mean positioning works at that
distance. Submaps can be chained to cover longer routes (Marvelmind cites setups spanning hundreds
of meters), but that means **a beacon roughly every 30 m along the entire route**, not just
bracketing a bridge.

- **If the survey area really is one bridge crossing** (river width plus a modest approach on
  each side), Marvelmind-only is plausible — that might be only a handful of beacons, and it
  removes GPS as a live dependency entirely, which is a genuine simplification (one less sensor in
  the real-time fusion loop, §4's GPS row becomes a one-time-use tool rather than a running
  sensor).
- **If the survey covers longer stretches of open river between bridges**, Marvelmind-only means
  buying, mounting, powering, and individually GPS-surveying a beacon every ~30 m for the whole
  route — a much larger infrastructure commitment than the original plan (GPS for the open-water
  majority, Marvelmind only bracketing each bridge).

**Action item — this is the actual decision to make:** get the real extent of the survey area
from the SOW/professor. If it's bridge-crossing-scale, go Marvelmind-only as proposed. If it's
longer open-river stretches, keep GPS live for open water and reserve Marvelmind for the
bridge-denial pockets (the original §8 plan, kept below as the fallback).

### 8.2 If GPS stays live: fusion architecture (fallback, if 8.1 needs it)

If any segment still needs GPS live, this is a sensor-fusion problem, not just a "swap sources"
problem — the boat needs to blend GPS (open river) and Marvelmind-derived position (under/near
bridges) into one continuous position estimate, ideally handled by ROS2's standard
[`robot_localization`](https://github.com/cra-ros-pkg/robot_localization) package (EKF/UKF
fusion, with `navsat_transform` for GPS specifically) rather than hand-rolled blending logic. If
8.1 lands on Marvelmind-only, `robot_localization` is still worth using, just fusing Marvelmind
plus the heading source (§15) rather than GPS plus Marvelmind.

Marvelmind does publish official ROS2 packages
([marvelmind_ros2_upstream](https://github.com/MarvelmindRobotics/marvelmind_ros2_upstream) +
`marvelmind_ros2_msgs_upstream`), which is good — but last pushed **November 2022**, so treat
it as a starting point that may need porting/patching for current ROS2 Humble rather than a
guaranteed drop-in. This applies either way §8.1 lands.

**Action items:**
- [ ] Get the survey area's real extent (§8.1) — this decides Marvelmind-only vs. GPS+Marvelmind
      fusion.
- [ ] Confirm the Marvelmind ROS2 package builds and runs cleanly on ROS2 Humble; budget time to
      patch it if not.
- [ ] If GPS stays live anywhere, design the GPS↔Marvelmind fusion/handoff explicitly
      (`robot_localization`) rather than leaving it implicit.
- [ ] Decide how the YOLO-avoidance layer and the waypoint-following layer arbitrate (ties to §2).

---

## 9. Reuse research — previous team's code and datasets

**ROS2 code: decided not to reuse.** The previous team's ROS2 Humble Linux-side nodes were a
plausible reuse candidate on paper (§1 matches their ROS2 distro), but the team's assessment,
having looked at it, is that it's not worth the archaeology: it's disorganized and much of it is
built around the Cube (which §2 removes entirely), so a large fraction wouldn't apply anyway.
**Decision: write the ROS2 stack from scratch**, informed by this doc's node list (§14.7) rather
than by porting their code.

**Training dataset: still worth getting.** Earlier assumption in this doc was that a custom river/bridge dataset
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

**Confirmed on the board:** the boot command line reserves `cma=1000M` — 1GB of the 4GB pool set
aside as contiguous memory for the DPU's buffers (§14.3). That's a real, checked number to start
the budget from, not an estimate.

**Action item:** build an actual rough memory budget (OS/ROS2 baseline + per-node estimate + the
1GB CMA reservation, revised if it's resized + camera/LiDAR buffers) once the model and DPU size
are chosen — before assuming it'll fit.

---

## 11. DDR / memory-bandwidth budget — flag early

Distinct from the capacity question above: the DPU, any PL-side camera capture, and PL-generated
PWM/UART-adjacent logic all share the same HP/HPC AXI ports into DDR, which is a *throughput*
constraint, not a capacity one. Once the camera and DPU architecture (B-size) are chosen, do a
rough bandwidth budget before finalizing the Vivado block design.

---

## 12. Collaboration workflow (source control across a two-person team)

**Decision: adopting the git-based approach below for Vivado/PetaLinux/Vitis source control.**
**A shared NAS was considered and dropped** — not worth the setup/maintenance effort for a
two-person team. Backups instead: each person backs up their own working copy to their own home
network whenever they're off-site with their laptop (informal, personal responsibility, not a
shared team resource). Bulky binary artifacts that used to be pointed at the NAS (`.xsa` hardware
platforms, `.bit`/boot images, `.xmodel` files, raw training datasets, full project backups) now
just live in each person's own backup, not in a shared, always-available location. **Consequence
worth flagging:** without a shared drop point, handing a teammate a large build artifact means
sending it directly (or re-generating it from git, which is the point of the git strategy below)
rather than pointing them at a shared path — fine for two people, worth revisiting if the team
grows.

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
§3.1 (manual override, RC), and §2 (decided: full replacement, external mux for manual override).

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

**Implementation approach for the PL PWM core: Vitis HLS in C++, then package as an IP — this is
standard practice, not a workaround.** Checked against AMD's own material: their
["AXI Basics 6"](https://adaptivesupport.amd.com/s/article/1137153?language=en_US) tutorial is
specifically about building an AXI4-Lite-controlled IP in Vitis HLS, and AMD ships a
[Vitis Motor Control Library](https://docs.amd.com/r/2024.1-English/Vitis_Libraries/motor_control/tutorial.html)
with PWM duty-cycle generation blocks built the same way. Nothing about this is naive; it's the
normal path for a team more comfortable in C++ than hand-written RTL. One tradeoff worth knowing:
a bare PWM generator (a counter compared against a threshold) is simple enough that some teams
just write it directly as a few lines of Verilog instead of going through HLS, since HLS's
compile-and-schedule step adds effort that a design this small doesn't strictly need. Either way
gets to the same AXI-Lite-controlled block described below and in §14.5 — pick whichever the team
is faster in.

**Where the FSM actually lives — this is the one thing to get right.** The "FSM controlled by
ROS" idea is correct in spirit but the FSM itself has to run **in the PL hardware that the HLS
core generates, not in the ROS node**. Linux/ROS2 isn't a real-time OS, so anything generating the
actual 50 Hz pulse edges from software would have jitter. The split that already matches this
document (§14.5's proposed register map) is: the HLS-generated hardware FSM inside the PL block
owns pulse timing, the watchdog countdown, and clamping to 1100–1900 µs, entirely in hardware; the
ROS2 `thruster_driver` node only writes target pulse-width registers and a heartbeat over
UIO (§14.3) — it commands the FSM, it doesn't implement it. This is exactly the "FSM controlled by
ROS" idea, just with the boundary drawn at the register interface instead of at the pulse
waveform.

### 13.3 Options for switching between KR260 and RC

The BlueRobotics Thruster Commander can't do this: its inputs are potentiometer
inputs, mode is chosen by which pins are wired, and it has no source selection. Checked against
its manual and docs. Options that can:

| Option | Switching | Cost | Notes |
|---|---|---|---|
| **A. Basic ESCs + Pololu 4-channel RC servo multiplexer (recommended)** | Hardware. A spare RC channel on SEL picks master (M) or slave (S) inputs per a user-set threshold (default ~1700 µs, ±64 µs hysteresis). | ~$18 ([product](https://www.pololu.com/product/2806)) | Purpose-built for autonomous/manual override. 2.5–16 V supply, SEL accepts 0.5–2.5 ms pulses at 10–330 Hz. Failsafe is a jumper: off, master inputs take control if SEL is lost; on, outputs go low. Keeps the Basic ESCs. Works with the KR260 hung or unpowered. |
| B. Basic ESCs + Acroname RxMux | Same idea, 8 channels, 2 sources. | ~$19 ([product](https://acroname.com/store/s56-rxmux-1)) | Defaults to input A if SEL is absent, and the vendor states it provides no failsafe or redundancy by itself. More channels than needed here. |
| C. Mux inside the PL | Logic in the KR260's fabric selects between the decoded RC signal and the autonomous PWM. | No hardware cost | Extends the J18 e-stop gating design. Loses manual control if the KR260 loses power or the PL is unconfigured, which is exactly when a manual override matters. Acceptable only if the KR260 is trusted to stay up. |
| D. Option B hybrid low-level board (§2) | Native to the flight-controller firmware (ArduRover RC passthrough and mode arbitration). | Depends on board | No separate mux needed and no PL PWM work. **Not applicable:** §2 chose full replacement with an external mux. Kept for reference. |
| E. VESC-class ESCs | Firmware supports combined PPM+UART control ([Flipsky](https://flipsky.net/blogs/vesc-tool/vx4-three-control-mode-ppm-uart-ppm-and-uart)). | Varies | Which input wins when both are active was not found documented, and T200 compatibility with VESC is unconfirmed. Not recommended without a bench test. |
| F. Roboteq BLDC controllers | RC, serial and CAN inputs. | High | Sized for much larger motors than a T200. Input-priority behavior not verified. Overkill here. |

**Decision context:** §2 chose full replacement with an external mux for manual override, which is
this section's Option A (the Pololu mux; not the same "Option A" as in §2). **Not yet verified on
hardware:** that the Pololu mux passes 1100–1900 µs pulses
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
- [ ] On-water check of thrust against river current (§15 item; inherited assumption).

**Action items:**
- [ ] Confirm the mux product (§13.3): Pololu 4-channel is the current recommendation, since §2
      is decided as an external mux.
- [ ] Decide what the e-stop cuts and where (§13.4).
- [ ] Confirm the RC pair (§13.5, recommended Pocket ELRS + ER8): check EdgeTX tank mixing and
      range, set per-channel failsafe (SEL above ~1700 µs if the KR260 should take over on link
      loss), and confirm the SBUS-vs-CRSF serial output for the return-to-beacon trigger.
- [ ] Confirm power-system current capacity and fusing against T200 peak draw.

---

## 14. Full system architecture and how Linux/ROS talks to the PL

This section is the system-level view the design review asks for: what the robot is made of, how
the pieces connect, and, in detail, how Linux and ROS2 communicate with the programmable logic (PL)
on the KR260. Facts about the KR260 image below were checked directly on the board (kernel
5.15.0-1027-xilinx-zynqmp, Kria Ubuntu 22.04). Register maps and behaviors marked "proposed" are
design proposals, not existing IP.

### 14.1 Robot subsystems

| Subsystem | Contents | Where it's documented / status |
|---|---|---|
| Hull and mechanical | Boogie-board hull, waterproof boxes, reused 3D-printed brackets, 3D-printed camera chassis with anti-reflective glass panel and hydrophobic coating | §5 (camera enclosure). Hull, mounting, cable penetrators, and thermal layout are not covered in this doc. |
| Power | Battery, distribution, fusing, regulation for the KR260/USB hub/sensors, thruster supply | Carried over from the original boat and not documented here. See 15.9 for what this plan needs from it. |
| Propulsion | 2× T200 + Basic ESC, PWM multiplexer, RC receiver | §13 |
| Sensing | Ping2, RPLidar S2, Marvelmind, GPS, OAK-D camera, heading source (open) | §4, §6, §8 |
| Compute | KR260: PS (Linux, ROS2) + PL (DPU, thruster block) | §1, §10, §11, this section |
| Communications | WiFi/SSH from a lab laptop; 2.4 GHz RC link | §3, §7, §13.5 |
| Safety | External mux + RC override, PL watchdog, hardware e-stop, RC failsafe | §2, §13.4, 15.6 |

### 14.2 System block diagram

```
                              +------------------------ KR260 -------------------------+
  USB hub --> Ping2           |  PS (Linux + ROS2)                 PL (one bitstream)   |
          --> RPLidar S2      |  +------------------------+       +------------------+  |
          --> Marvelmind      |  | sensor driver nodes    |       | DPU (YOLO)       |  |
          --> GPS             |  | robot_localization     |<-AXI->|  AXI-Lite ctrl   |  |
  USB0    --> OAK-D camera    |  | nav / mission / avoid  |  HP   |  AXI HP -> DDR   |  |
                              |  | dpu_detector (VART)    |       +------------------+  |
                              |  | motor_mixer            |       | Thruster block   |  |
                              |  | thruster_driver (UIO)  |<-AXI->|  regs, 2x PWM,   |  |
                              |  +------------------------+ Lite  |  watchdog,e-stop |  |
                              |                                   +--------+---------+  |
                              +--------------------------------------------|------------+
                                        PMOD J2 (2x PWM) <-----------------+   ^ PMOD J18
                                               |                                | e-stop in
   RC receiver (2x thrust PWM + SEL) --> +-----v-------+                        |
   RC transmitter ~~ 2.4 GHz link ~~     | PWM mux     |--> Basic ESC x2 --> T200 x2
                                         | (external)  |
                                         +-------------+
```

The mux sits outside the KR260. With SEL on manual, the RC receiver drives the ESCs directly and
the KR260 has no influence on the thrusters. With SEL on autonomous, the PL's PWM outputs drive
them.

### 14.3 How the PS talks to the PL

There are two separate paths, and they use different mechanisms.

**Path 1: thruster block (control and status registers)**
- **Hardware link:** an AXI4-Lite slave in the PL, reached from an AXI master port on the PS (for
  example HPM0_LPD, which tutorial 2 enables). It is a small block of 32-bit registers.
- **Linux mechanism: UIO.** The PL block appears as a device-tree node with
  `compatible = "generic-uio"` and a `reg` range, and Linux exposes it as `/dev/uioN`. A ROS2 C++
  node `mmap`s that device and reads and writes registers. **The board is already set up for this:**
  its kernel command line contains `uio_pdrv_genirq.of_id=generic-uio`, and the `uio_pdrv_genirq`
  module is available.
- **Why not `/dev/mem`:** the kernel has `CONFIG_STRICT_DEVMEM=y`, which restricts it, and UIO
  gives a scoped mapping plus a standard interrupt path.
- **Why not a kernel PWM driver:** the kernel config has no Xilinx PWM driver, so a custom
  register block is the practical route. A small kernel driver could replace UIO later if wanted.
- **Interrupts (optional):** a PL-to-PS interrupt (for example on watchdog trip or e-stop) can be
  delivered through UIO. Polling the status register at 10-20 Hz is enough to start.
- **AXI GPIO** would also work natively (`CONFIG_GPIO_XILINX=y`, appears as a gpiochip), but the
  thruster block already carries its own status bits, so GPIO IP is not needed.

**Path 2: DPU (inference)**
- **Hardware link:** the DPU has an AXI-Lite control port and AXI master ports to DDR through the
  PS high-performance ports (§11). Weights, activations, and image buffers live in DDR.
- **Linux mechanism: XRT + `zocl`.** The image ships the `zocl` kernel module and XRT, so it
  uses the Vitis flow (an `.xclbin` loaded through XRT). **The in-kernel Xilinx DPU driver is not
  built** (`CONFIG_XILINX_DPU` is not set and no `dpu` module exists). That means the Vivado-flow
  DPU of the LogicTronix tutorial would need an out-of-tree kernel module. The Vitis flow of
  tutorial 2 matches this image.
- **Software:** a C++ ROS2 node uses VART (Vitis AI runtime). Getting VART onto Kria Ubuntu without
  PYNQ is still unverified (see 15.10).
- **DDR buffers:** the boot command line reserves `cma=1000M` of contiguous memory. Contiguous
  buffers for the DPU come from there. That is 1 GB of the 4 GB pool, so it belongs in the §10
  memory budget. CMA memory can be lent to movable allocations, so it isn't fully idle, but it
  is not a free 1 GB either.

### 14.4 Loading the PL and boot sequence

- **One bitstream** contains both the DPU and the thruster block, packaged as a Kria firmware app:
  `.bit` to `.bit.bin`, the device-tree source to `.dtbo`, plus a `shell.json`, and the `.xclbin`
  for the DPU. These are installed under `/lib/firmware/xilinx/<app-name>/`. AMD's
  [custom firmware guide](https://xilinx.github.io/kria-apps-docs/kr260/build/html/docs/generating_custom_firmware.html)
  describes this with a makefile in `kria-apps-firmware`. The `shell.json` contents are not
  covered there and are unverified here.
- **Loading:** `xmutil unloadapp` then `xmutil loadapp <app-name>`. On the board today,
  `xmutil listapps` shows only the default `k26-starter-kits`, so the custom app must be created.
- **Automation:** a systemd oneshot unit runs the load before the ROS2 launch starts.
- **Safe state during boot:** until the bitstream loads, the PMOD pins are not driven. The mux
  must therefore default to **manual (RC)** so the ESCs see the receiver's neutral, not a floating
  line. Verify the Pololu SEL default and failsafe jumper (§13.3), and never leave SEL on
  autonomous while reloading the bitstream.

### 14.5 Thruster block (proposed register map)

Custom PL block, AXI4-Lite, 32-bit registers, offsets from the block's base address:

| Offset | Name | Access | Function |
|---|---|---|---|
| 0x00 | ID / VERSION | RO | Fixed ID and version, to confirm the right bitstream is loaded |
| 0x04 | CTRL | RW | Bit 0: ENABLE autonomous outputs. Bit 1: CLEAR_FAULT (write 1 to re-arm after a watchdog trip). Bit 2: SOFT_ESTOP. |
| 0x08 | STATUS | RO | Output enabled, watchdog tripped, hardware e-stop input active |
| 0x0C | PWM_L_US | RW | Left pulse width in µs. Default 1500. |
| 0x10 | PWM_R_US | RW | Right pulse width in µs. Default 1500. |
| 0x14 | WD_TIMEOUT_MS | RW | Watchdog timeout. Default 200. |
| 0x18 | HEARTBEAT | WO | Any write refreshes the watchdog |
| 0x1C / 0x20 | PWM_L/R_ACTUAL | RO | Pulse width actually being driven after gating |

Hardware rules that do not depend on software:
- Pulse widths are **clamped to 1100-1900 µs in the PL**, whatever software writes.
- Outputs are **1500 µs (neutral) at reset**, never 0.
- On a watchdog trip, both outputs go to neutral and stay there until software writes CLEAR_FAULT.
  A restart does not silently resume thrust.
- The J18 e-stop input forces neutral in the PL (the autonomous path only, see §13.4).
- **Optional:** wiring the RC receiver's SEL line to a PL input as well would let the block
  measure it and report which source is live. That helps logging and stops the autonomous
  controller winding up while a human is driving. It is not required for safety.

Frame timing: the PL generates a 50 Hz frame with 1 µs pulse resolution, independent of Linux
scheduling. Software only updates the target values.

### 14.6 Failure behavior

| Event | What happens | Who is in control |
|---|---|---|
| ROS2 node crash or Linux hang | Heartbeat stops, watchdog trips, autonomous outputs go to neutral | Pilot can flip SEL to manual |
| Upstream navigation stops sending commands | `thruster_driver` stops refreshing the heartbeat (see 15.7), same as above | Pilot |
| KR260 loses power | PL outputs are undriven. What the Basic ESC does on signal loss is **unverified**; test it. | Pilot must already be on manual, or flip to it |
| RC link lost | Receiver sets SEL and thrust channels to their configured failsafe values (§13.5) | Per failsafe setting |
| E-stop pressed | PL forces neutral on the autonomous path. Power cut is still to be decided (§13.4). | Depends on §13.4 |
| Boot or bitstream reload | PMOD pins undriven until load completes | Mux defaults to manual (15.4) |

### 14.7 ROS2 software architecture

| Node | Runs | Inputs | Outputs |
|---|---|---|---|
| Sensor drivers: `rplidar_ros`, `depthai-ros`, Ping2, `marvelmind_ros2`, `nmea_navsat_driver`, heading (TBD) | PS | USB devices | `/scan`, camera images and depth, sonar depth, Marvelmind position, `/fix`, IMU |
| `robot_localization` | PS | GPS, Marvelmind, IMU | Fused pose and odometry (§8) |
| `dpu_detector` (C++, VART) | PS + DPU | Camera RGB | Detections (e.g. `vision_msgs`) |
| Obstacle avoidance | PS | Detections, `/scan`, depth | Adjusted velocity request |
| `mission_manager` | PS | Fused pose, waypoints, RC channels | Survey / hold / return-to-beacon commands |
| `sbus_serial` | PS | ER8 serial output | RC channels (return-to-beacon trigger, §3.1) |
| `motor_mixer` | PS | Speed and yaw request | Left/right thrust, -1 to 1 |
| `thruster_driver` (C++, UIO) | PS to PL | Left/right thrust | PL registers; publishes thruster status (actual µs, watchdog, e-stop) |
| `rosbag2` | PS | Sonar, position, status | Geotagged survey log |

Data flow: sensors, then `robot_localization`, then mission/avoidance, then `motor_mixer`, then
`thruster_driver`, then PL registers, then PWM, then the mux, then the ESCs. Camera to
`dpu_detector` to avoidance.

**Heartbeat rule (proposed):** `thruster_driver` refreshes the heartbeat only when it has received
a fresh command within a set window, not from an independent timer. A stuck or dead upstream node
then trips the watchdog as well, not just a dead driver.

**Rates (proposed starting points):** control loop 20-50 Hz; watchdog 200 ms (about 10 missed
updates at 50 Hz); DPU inference at whatever the chosen model sustains.

### 14.8 Bring-up order

1. **Spike A, PS-PL path only:** a minimal PL design with just the thruster block, packaged as a
   firmware app, loaded with `xmutil`, mapped through UIO from a C++ program, with the PWM outputs
   checked on a scope. This proves the device tree, UIO, and packaging without the DPU.
2. **Spike B, DPU only:** a Vitis-flow DPU `.xclbin` loaded on Kria Ubuntu without PYNQ, running a
   small model through VART.
3. **Merge:** one bitstream with both. Check timing, resource use, and DDR bandwidth (§10, §11).
4. **ROS2 integration:** the nodes in 15.7, then the mux and ESC bench tests (§13.6).

Spikes A and B are independent and can run in parallel between teammates.

### 14.9 What the whole-robot plan still needs from other subsystems

- **Power:** battery voltage and capacity, distribution diagram, fusing, the KR260 and USB hub
  supply, the thruster supply and its peak current (§13.1), and whether an e-stop contactor is in
  the thruster supply (§13.4).
- **Mechanical:** enclosure layout, cable penetrators, and thermal design. The KR260 has a fan
  (checked earlier, driven at a low duty cycle), so in a sealed box the heat has to reach the
  hull or air. That needs a plan.
- **Test plan:** on-water tests of thrust in current, the mux and failsafe behavior, and
  survey-data quality.

### 14.10 Open items from this section

- [ ] Confirm the Vitis-flow `.xclbin` DPU loads and runs through `xmutil` + XRT + `zocl` on Kria
      Ubuntu without PYNQ (Spike B).
- [ ] Find out how to install VART / the Vitis AI runtime on Kria Ubuntu 22.04 without PYNQ.
- [ ] Prove the UIO register path with a minimal firmware app (Spike A), including the `shell.json`
      and DTBO details.
- [ ] Decide the PMOD pin mapping for the PWM, e-stop, and (optionally) SEL monitoring, against the
      KR260 pinout.
- [ ] Verify what the Basic ESC does when its signal disappears (KR260 power loss case).
- [ ] Decide whether to shrink `cma=1000M` and fold the result into the §10 memory budget.
- [ ] Get the power and mechanical inputs listed in 15.9.

---

## 15. Open questions / action items

- [x] ~~Decide Option A vs. B (§2)~~ — **decided: full replacement of the Cube, with an external
      PWM mux for manual override** (§2, §13). The KR260 now owns navigation, motor mixing, and
      PL-side failsafes.
- [ ] **Finalize the e-stop design (§13.4)**: what it physically cuts now that a mux is in the
      path, and who takes control when the RC link drops (§13.5).
- [x] ~~Define the manual-override path (§3)~~ — **answered: the RC receiver drives the mux
      directly** (§13.2, §13.3), independent of the KR260. Still open: live telemetry beyond WiFi
      range, and the SBUS + custom-node return-to-beacon trigger on the KR260 (§3.1).
- [x] ~~Identify the current GPS module~~ — confirmed **Here 3+ (DroneCAN, Cube-specific)**;
      **recommend replacing** with a plain USB/UART GNSS module (§4). **Action item:** purchase
      and confirm.
- [x] ~~Pick a replacement camera~~ — **Luxonis OAK-D family chosen** (§5); Aurora930 Pro
      considered and not recommended (short 0.3–3 m depth range, structured-light outdoor-sunlight
      risk). Still open: S2 vs. Lite, fixed vs. autofocus, and a DepthAI test on the KR260.
- [ ] **Heading source.** The Here 3+ has a built-in compass and IMU; replacing it with a plain
      GNSS module removes both. A single GNSS receiver gives course-over-ground only, which is
      unreliable at low speed in current. Decide where heading comes from (an external
      compass/IMU, whether the OAK-D's onboard IMU is usable, or dual-GNSS heading) before
      finalizing the §8 fusion design.
- [x] ~~Decide the GPS module~~ — **NEO-M8N (or M9N) USB module chosen** (§4). Precision GPS
      isn't needed because Marvelmind covers the GPS-denied bridge segments. Purchase and confirm.
- [ ] **Georeference the Marvelmind beacons, and decide Marvelmind-only vs. GPS-live (§8.1).**
      Get the survey area's real extent — a single bridge crossing likely makes Marvelmind-only
      practical, but longer open-river stretches would need a beacon roughly every 30 m
      (Marvelmind's real submap range, not its longer radio range) to stay GPS-free the whole way.
- [ ] Sanity-check that the Basic-ESC/T200 thrust is adequate against river current, not just
      lake conditions (inherited assumption from the previous team).
- [x] ~~Decide whether the RPLidar A2M12 will work well with the KR260~~ — the KR260/USB
      interface side is fine either way; the real issue is the **sensor's own direct-sunlight
      limitation** for outdoor river use (§4). **Recommendation: replace with RPLidar S2**
      ($399, 80klux sunlight-rated, same USB integration path). **Action item:** purchase and
      confirm.
- [ ] Design the RC-triggered "return to beacon" behavior (§3.1) as a custom SBUS-triggered ROS2
      node using the fused `robot_localization` position estimate (Marvelmind-anchored
      retrieval). ArduRover's native RTL is not available with the Cube gone.
- [ ] **Sign off on the physical port assignment (§6) as a team** — especially the USB1 hub
      absorbing 4 of the 5 USB-hungry sensors (the 5-sensors-vs-4-ports constraint) — and buy the
      powered USB hub it depends on. Also confirm the RPLidar S2 adapter's scan-motor behavior; the
      GPS CAN contingency is retired (§4).
- [x] ~~Development environment / remote access~~ — **decided and working**: static IP, direct
      SSH to the board, boots headless by default (§7). SSH keys still to set up.
- [x] ~~Get the previous team's ROS2 code~~ — **decided not to reuse it** (§9); writing the ROS2
      stack from scratch instead. Their **training dataset is still wanted** — get the specific
      name(s)/links.
- [ ] Confirm the Marvelmind ROS2 package runs on current ROS2 Humble (last upstream push was
      Nov 2022) and design the fusion explicitly (§8, `robot_localization`) — GPS+Marvelmind or
      Marvelmind+heading, depending on §8.1.
- [ ] Build a rough memory budget (§10) once the YOLO variant/DPU B-size are chosen.
- [ ] Rough DDR/bandwidth budget (§11) once camera + DPU size are chosen.
- [ ] Decide HLS vs. hand-written RTL for the PWM core (§13.2) — either is standard, pick based on
      team comfort.

---

## References

- [KR260 DPU-TRD Vivado-flow tutorial (Vitis AI 3.0), LogicTronix/Hackster](https://www.hackster.io/LogicTronix/kria-kr260-dpu-trd-vivado-flow-vitis-ai-3-0-tutorial-0085fd)
- [KR260-DPU-TRD-Vitis-AI-3.0 repo](https://github.com/LogicTronixInc/KR260-DPU-TRD-Vitis-AI-3.0)
- [Vitis AI 3.5 IP and Tool Version Compatibility](https://xilinx.github.io/Vitis-AI/3.5/html/docs/reference/version_compatibility.html)
- [Pruning YOLOv3 and deploying with Vitis AI on a Kria board](https://www.hackster.io/LogicTronix/pruning-yolov3-and-deploying-with-vitis-ai-on-kria-kv260-de654a)
- [Xilinx/KRS repo](https://github.com/Xilinx/KRS)
- [Kria custom firmware app guide (xmutil/dfx-mgr, kria-apps-firmware)](https://xilinx.github.io/kria-apps-docs/kr260/build/html/docs/generating_custom_firmware.html)
- [Kria SmartCamera AI customization docs](https://xilinx.github.io/kria-apps-docs/creating_applications/2022.1/build/html/docs/AI_customization.html)
- [AMD Kria AI / Robotics Developer Platform announcement, Advancing AI 2026](https://newsroom.amd.com/news/aai-2026-kria-robotics-dev-platform/)
- [BlueRobotics Ping Sonar Technical Guide](https://bluerobotics.com/learn/ping-sonar-technical-guide/)
- [RPLIDAR A2M12 datasheet](https://bucket-download.slamtec.com/f65f8e37026796c56ddd512d33c7d4308d9edf94/LD310_SLAMTEC_rplidar_datasheet_A2M12_v1.0_en.pdf)
- [BlueRobotics Basic ESC R3 Arduino example (PWM spec)](https://bluerobotics.com/learn/basicesc-r3-example-code-for-arduino/)
- [BlueESC documentation](https://docs.bluerobotics.com/bluesc/)
- [Marvelmind beacon hardware interfaces](https://marvelmind.com/pics/marvelmind_interfaces.pdf)
- [Marvelmind ROS2 upstream package](https://github.com/MarvelmindRobotics/marvelmind_ros2_upstream)
- [Marvelmind FAQ (submap/radio range)](https://marvelmind.com/faq/)
- [Hiwonder Aurora930 Pro docs](https://wiki.hiwonder.com/projects/Aurora930-Pro/en/latest/docs/1.Introduction_to_Depth_Camera.html)
- [AMD "AXI Basics 6" — AXI4-Lite in Vitis HLS](https://adaptivesupport.amd.com/s/article/1137153?language=en_US)
- [Vitis Motor Control Library tutorial](https://docs.amd.com/r/2024.1-English/Vitis_Libraries/motor_control/tutorial.html)
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
