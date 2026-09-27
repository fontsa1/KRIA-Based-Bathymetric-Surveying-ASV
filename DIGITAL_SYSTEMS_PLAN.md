# FPGA-Based ASV — Digital Systems Plan

Boat 2 of the DOT-funded Autonomous Surface Vehicle (bathymetric surveying / bridge-pier
mapping) project. This sub-team is replacing the current digital stack —
**NVIDIA Jetson Orin Nano + Cube Orange+** — with a single **AMD/Xilinx Kria KR260**
(Zynq UltraScale+ MPSoC), running Vitis AI (DPU + YOLO) and ROS2. The hull itself is a
boogie board with waterproof boxes mounted on it for electronics/sensors.
The power system is redesigned around the new digital hardware (§15).
This doc is the living plan for the electronics/compute side: toolchain, sensor interfacing,
PS/PL partitioning, and open decisions. Update it as decisions get made, don't let it go stale.

---

## 1. Toolchain

**Vivado / Vitis / PetaLinux 2023.1, Vitis AI 3.5. Whole team confirmed on this set** (Enterprise
licenses cover it). **Linux base: Kria Ubuntu 22.04 (already installed on the board), ROS2
Humble** — chosen for best out-of-the-box app support.

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
- Position estimation: Marvelmind in `robot_localization` (§8). The GPS stays on shore and only
  georeferences the beacons (§8.1). Heading source is still open (§16).
- Motor command generation, including left/right mixing, in a ROS2 node.
- PWM output in the PL (PMOD J2, §6, §13.2) with a PL watchdog that forces neutral if the PS stops
  refreshing the outputs.
- Obstacle avoidance from YOLO on the OAK-D RGB stream and the RPLidar S2 (§4, §8).

**What is not in the system:** ArduPilot, MAVLink, MAVROS, and QGroundControl-style tooling. There
is no MAVLink-speaking autopilot left to bridge to; field access and survey start are covered in
§3.1 without any of it.

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
memory cost to the KR260. It is retained in §13.3 only as a reference.

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
still open — see §3.1 on whether a second radio link beyond WiFi range is needed.

### 3.1 Field access and survey start

**Return-to-beacon is dropped.** With the external mux, the pilot can take over and drive the boat
back at any time (§13), so the KR260 doesn't need its own retrieval behavior. That also drops the
SBUS decoding and the extra RC serial path it needed.

What the field still needs is a way to start and stop a survey, and ideally SSH, away from the lab
network. Either way the KR260 boots straight into the stack: a systemd unit loads the bitstream,
the ROS2 launch starts after it (§14.4), and the survey waits for a start command.

**Memory, measured on the board (Sep 2026):** idle and headless, before ROS2, it uses about 230 MB
with about 3.5 GB available (§10). NetworkManager and wpa_supplicant already run, and
`dnsmasq-base`, which NetworkManager uses to hand out addresses on a hotspot, is already installed.

| Option | How | Memory on the KR260 | Notes |
|---|---|---|---|
| **A. WiFi hosted on the KR260** | A USB WiFi adapter in access-point mode, set up as a NetworkManager hotspot | A few MB: one `dnsmasq` process plus the driver; the rest already runs | The adapter's chipset needs an in-kernel driver on this image; `mt76x2u`, `mt76x0u`, `ath9k_htc`, `rt2800usb` and `rtl8xxxu` are built. MT7612U adapters (in-kernel since Linux 4.19, access-point mode supported; e.g. the Alfa AWUS036ACM) are a well-tested choice. The trimmed image has no WiFi firmware, so install the adapter's firmware file. Host on 5 GHz to stay off the RC link's 2.4 GHz band. Uses USB0 port B (§6); the antenna needs a clear path out of the box. |
| **B. WiFi from a travel router on the boat** | A small 5 V travel router on the KR260's Ethernet port hosts the network | None | The KR260 keeps its static IP and doesn't change. Costs a little 5 V power and box space. Pick a dual-band model: GL.iNet's Mango (GL-MT300N-V2), for example, is 2.4 GHz only. |
| **C. RC survey button, no network** | A spare ER8 channel, on a transmitter button, goes through the interface board to a PMOD J2 pin (§13.7). The PL measures its pulse width (§14.5) and `thruster_driver` publishes it. | None: no new process | `mission_manager` starts or stops the survey on a short press. Holding it for several seconds closes the logs and shuts Linux down cleanly, so power is never cut mid-write to the SD card. Set the channel's failsafe to "not pressed". Optional: a status LED on a spare PMOD pin, so the operator can see the survey is running. |

**Plan:** host WiFi on the KR260 (A) once the §10 memory budget confirms the room; the measured
numbers above suggest it will. Build the RC button (C) regardless, as the zero-memory fallback that
works without any network. B is the alternative if networking should stay off the KR260 entirely.

**Live telemetry beyond WiFi range** (still open): if it's needed, a cheap SiK/RFD900-class serial
radio carrying a small custom packet (position, battery, mode — not MAVLink). Confirm the real
operating range before building a second radio link.

**Action items:**
- [ ] Add the survey-button input to the thruster block (§14.5) and the start/stop/shutdown handling
      to `mission_manager`.
- [ ] Buy a WiFi adapter for option A (MT7612U class) and test hotspot mode on the board.
- [ ] Confirm the real-world WiFi range needed before assuming a second radio link is necessary.

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
| **BlueRobotics Ping2** echosounder/altimeter (**existing**) | UART, 3.3 V logic (5 V tolerant), 4.5–5.5 V supply, 100 mA typical / 900 mA peak; binary "Ping Protocol," default 115200 baud | **USB** (BlueRobotics BLUART USB-serial adapter → USB0 hub — see §6) | Low bandwidth, request/response protocol — no case for PL. The BLUART is an FTDI adapter, and the `ftdi_sio` driver is on the board. No ROS2 package: wrap Blue Robotics' `bluerobotics-ping` Python library in a small node. Wiring from the sonar's cable to the BLUART is below the table. This is the core bathymetric data source — see §8. |
| **BlueRobotics T200** thrusters ×2 + **Basic ESC** ×2 (**decided**) | Standard RC PWM, 1100–1900µs @ 50Hz, 1500µs = stop | **PL PWM generation, PMOD J2 (§6), through the PWM mux below** — full chain in §13 | Basic ESC chosen on cost grounds: the team already owns one Basic-ESC-driven thruster. Previous team reports these "haul ass" on lakes; an inherited assumption for river current, not river-tested — worth a sanity check once on the water. The Thruster Commander is **not** in the signal path (potentiometer-only inputs, no source selection); it stays a bench-test tool (§13.3). |
| **PWM multiplexer — Pololu 4-channel RC servo mux** (**recommended, not yet bought or bench-tested**) | RC servo PWM in and out. Master and slave inputs, 4 channels; SEL takes a 0.5–2.5 ms pulse; 2.5–16 V supply | Mounted on the interface board (§13.7), between the RC receiver + KR260 PMOD J2 and the two Basic ESCs — **no KR260 port used**, see §13.2–13.3 | ~$18; buy it unassembled (#2807) to solder onto the interface board. A spare RC channel on SEL switches manual (RC receiver) vs. autonomous (KR260). Works with the KR260 hung or unpowered. Pololu's schematic shows a 74VHC157 logic multiplexer, so pulse widths pass through unchanged, but it isn't guaranteed to read 3.3 V as high and its inputs have no pull-downs; the interface board adds both. |
| **RC transmitter + receiver — RadioMaster Pocket (ELRS) + ER8 receiver** (**recommended, not yet bought**) | 2.4 GHz ELRS link; ER8 has 8 PWM outputs plus a CRSF/SBUS serial output | PWM outputs → interface board (§13.7): two thrust channels and SEL to the mux, and the survey button on to PMOD J2 (§3.1) | ~$107 together. Per-channel failsafe (988–2012 µs) is set in the receiver's web UI; set SEL's failsafe on purpose (§13.5). Still to verify: EdgeTX tank mixing and real-world range. |
| **RPLidar S2** (**chosen; replaces A2M12**) | TTL UART, ships with a USB adapter and micro-USB cable | **USB**, via its adapter (USB0 hub — see §6) | Chosen for sunlight tolerance: the A2M12 is marketed for outdoor use "without direct sunlight" with no published ambient-light spec, while the S2 is rated for 80 klux and IP65, with a 30 m range vs. 12 m ($399 vs. $229). ROS2 support does not separate them: `ros-humble-rplidar-ros` 2.1.4 installs from the Humble apt repo, and Slamtec's `sllidar_ros2` (source build, S2 launch file `view_sllidar_s2_launch.py`) also supports it. Scan motor: closed-loop inside the lidar, started and stopped by protocol commands, so no PL work; the adapter is a CP2102, and the `cp210x` driver is on the board. Power: up to 1.5 A at startup (2.5 A inrush) and 450–600 mA running, more than a KR260 USB port supplies, so the adapter takes its power from the USB charger and only data goes through the hub (§15.4). |
| **Marvelmind Super-MP beacons** (hedgehog) (**existing**) | UART, CMOS 3.3V, default 500kbps (configurable down to 4.8kbps), or USB-CDC virtual COM port; streams Marvelmind protocol, NMEA0183 or u-blox (selected in the Dashboard) | **USB** (native USB-CDC, USB0 hub — see §6) | Simplest sensor to bring in — no adapter needed. Bigger role than "just a sensor": it's the boat's only live position source (§8.1), georeferenced once per setup with the shore-side GPS. ROS2: `ros-humble-marvelmind-ros2` 1.0.3 installs from apt on the board (upstream marked unmaintained). |
| **GPS — u-blox NEO-M8N USB-C IP67 receiver** (**chosen; lives off the boat**, ~€90, [GNSS Store](https://gnss.store/products/elt0380)) | USB-C, standard NMEA/UBX over USB-serial | **The shore laptop, not the boat** (§8.1) | Only georeferences the Marvelmind beacons at setup: plugged into the laptop and averaged for a few minutes at two beacons with open sky. Rated 2.0 m CEP; no compass. Has an SMA antenna connector and no antenna listed as included, so an antenna goes on the parts list. It replaces the Here 3+, which is DroneCAN (Cube-specific). An M9N is an acceptable substitute. |
| **Camera — Luxonis OAK-D family** (**chosen; replaces RealSense D435**) | USB3 (DepthAI) | **USB1, port A, dedicated** (its neighbor port left empty) — see §6 | Stereo depth + RGB at a reasonable price. No USB OAK-D has an IP rating, so waterproofing is the team's 3D-printed chassis with an anti-reflective glass panel and hydrophobic coating (§5). Variant still to pick: **OAK-D S2 ($329) recommended**, OAK-D Lite ($269) as the budget option. Driver: `ros-humble-depthai-ros` (2.12.2 in the apt repo for arm64). Stereo depth is short-range (about 7.5 cm baseline). Not yet tested on the KR260. |
| **Heading source** (**open**) | To be decided | Marvelmind (paired beacons), USB, or an existing sensor | The Here 3+ had a built-in compass and IMU; nothing on the boat replaces them yet, and with the GPS on shore, GPS-based heading is out. Options: Marvelmind paired beacons (two hedgehogs at least 20 cm apart report heading with no magnetometer, §8.1), an external compass/IMU, or the OAK-D's IMU (current OAK-D S2 units have a 9-axis BNO086; 2021–2023 units have a 6-axis BMI270 with no magnetometer). Magnetometers are unreliable next to a steel bridge. Needed before finalizing the §8 fusion design. |

**Sonar wiring (Ping2 → BLUART).** The four loose wires on the sonar's cable are how the Ping2
ships: the cable ends in individual male header pins, and the box includes a "4 position female
header to 6 position JST GH cable adapter." Per Blue Robotics' install guide, the pins go into the
adapter's 4-position header, and the adapter's 6-pin JST-GH end plugs into the BLUART's 6-position
serial port, matching "red to red, black to black, white to white, green to green."
- **Wires:** red = 5 V, black = ground, white = the sonar's TX (out), green = its RX (in). The
  color scheme already builds in the TX/RX crossover, so match colors; don't swap them.
- **Finding the adapter:** the previous team probably left it plugged into the Cube Orange+, whose
  TELEM ports are the same 6-pin JST-GH, so check the old electronics box. If it's gone, the BLUART
  ships with loose female headers for its through-hole pads: solder one on and plug the pins in by
  function.
- **Bare wire ends** instead of pins mean the cable was cut; crimp or solder new 0.1" pins.
- **Mounting:** the cable has a factory-fitted M10 WetLink penetrator (M10-4.5mm-LC), so the box
  needs an M10 hole.
- **Temperature:** Blue Robotics rates the Ping2 for 0–30 °C.

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

**Hard constraint — keep it in view: 4 physical USB ports, and not all of them usable.** The
devices that want USB are the Ping2/sonar, RPLidar S2, Marvelmind hedgehog (possibly two, for
heading, §4), and the camera, and a WiFi adapter may join them (§3.1). The camera's neighbor port
has to stay empty (power, §15.4), so the low-bandwidth sensors share one powered hub.

**USB topology, checked on the board:** the 4 physical ports aren't 4 independent controllers —
they're 2 PS USB3 controllers. USB0 (`ff9d0000`) feeds a 3-port hub, and one of those ports is
internal: the microSD card, which holds the OS and the logs, sits behind a USB 2.0 SD bridge
there. USB1 (`ff9e0000`) feeds a 2-port hub with nothing else on it. So the camera goes alone on
USB1, and the low-bandwidth sensors share one powered hub on USB0. They're serial-speed devices,
so sharing costs nothing. The point of the split: if the camera ever fell back to USB 2.0
(Luxonis warns about cables over 2.5 m), on USB0 it would share a bus with the OS disk. To tell
the physical ports apart, plug a USB stick into each and run `lsusb -t`: USB1's ports show up as
Bus 03/04.

**Proposed port map:**

| Port | Assignment |
|---|---|
| USB0, port A | Industrial powered USB hub (StarTech ST4200USBM or equivalent, fed 12 V, §15.4) → Ping2 (BLUART), RPLidar S2 (its USB adapter; data only, since its power comes from the USB charger, §15.4), Marvelmind hedgehog (native USB-CDC). A heading sensor or a second hedgehog (§4) may add one more. |
| USB0, port B | Free; the WiFi adapter if field WiFi is hosted on the KR260 (§3.1). The microSD (OS disk) is also on this controller. |
| USB1, port A | Camera — dedicated. |
| USB1, port B | Leave empty unless the camera runs on the optional Y-adapter: it shares a 1.0 A power switch with the camera's port, and the camera draws up to 0.9 A (§15.4). |
| PMOD J2 | One cable to the interface board (§13.7): thruster PWM ×2 out (autonomous path), which the board buffers into the mux's slave inputs, and the survey-button input (§3.1). Signal and ground only. |
| PMOD J18 | Hardware e-stop input, monitored directly by PL logic that gates the PWM outputs — a stop path that still works even if Linux/ROS2/the network link is dead. **With the mux, this gates only the autonomous path**; what the e-stop must cut for the manual path too is an open decision (§13.4). |
| PMOD J19, J20 | Reserve — e.g. the optional survey status LED (§3.1) |
| **RPi HAT header, J21** | Reserve |

**GPS/CAN contingency — resolved, no longer needed.** §4 previously flagged that if GPS turned
out to be a CAN/DroneCAN unit (as the Here 3+ is), it would need J21 + an external CAN
transceiver, since **KR260 has no CAN connector broken out on any carrier connector** and
reaching the PS's hardened CAN-FD peripheral means routing it out through EMIO to a PL pin.
Since §4 now recommends replacing the Here 3+ with a plain USB/UART GNSS module instead of
working around DroneCAN, this whole contingency is moot, and the GPS has since moved off the boat
entirely (§8.1).

Worth being deliberate about *not* also moving the thruster PWM/e-stop functions onto J21 just
because it has plenty of spare pins to hold everything: consolidating safety-critical e-stop
wiring onto the same connector/cable as other functions means one loose connector takes out
both at once. Keeping e-stop on its own dedicated PMOD (J18) is the safer default even though
J21 could technically fit it.

**Action items:**
- [ ] Confirm this port map with the team before wiring anything — re-routing after enclosures
      are built is more annoying than catching it on paper.
- [ ] Buy the industrial powered hub for USB0 port A (StarTech ST4200USBM or another hub with a
      7–24 V screw-terminal input), fed 12 V per §15.4 — required by the plan above, not optional.
- [ ] Identify which physical ports are USB0 and USB1 (`lsusb -t` with a USB stick in each) before
      wiring the camera and the hub.
- [x] ~~Confirm whether the RPLidar's included adapter handles scan-motor PWM onboard~~ —
      **closed:** the S2's motor is closed-loop and controlled by protocol commands; no PL work (§4).
- [ ] Purchase the USB GNSS module for the shore laptop (§4, §8.1); its antenna goes on the parts
      list.

---

## 7. Development environment & remote access — decided, working

**Decided and working: the KR260 is never connected to a monitor or keyboard/mouse.** It's always
used over SSH — from the lab and from home alike. It has a static IP on the PS-native Ethernet
port and boots headless by default (`multi-user.target`, no GNOME/desktop running), after the
fresh Ubuntu 22.04 install and package trim. The physical Ethernet jack question and the
static-IP-vs-lab-IT question are both resolved by this working setup and don't need separate
tracking. Field access away from the lab (WiFi, or the RC survey button) is in §3.1.

**Action item:**
- [ ] Set up SSH keys in place of password auth, now that this is the daily-driver path.

---

## 8. Navigation & data collection architecture

Clarified data/control flow: **sonar (Ping2) bathymetric data is recorded in parallel with
position**, since a depth reading is only useful survey data once it's geotagged. Position also
drives steering (waypoint following), blended with **YOLO-based object detection** for reactive
obstacle avoidance (pylons, rocks, riverbank) — this reactive layer is exactly the kind of
low-level control logic that §2 assigns to the KR260 (Option A, full replacement).

### 8.1 Live navigation source: Marvelmind only; the GPS stays on shore

**Decided: the boat navigates on Marvelmind alone, and the GPS never goes on the boat.** It's used
on the shore laptop once per setup, to georeference the beacons. That removes GPS from the
real-time loop, along with any GPS-to-Marvelmind handoff.

**How georeferencing works** (from Marvelmind's operating manual):
- **The laptop is only needed for setup.** The Dashboard (Windows, Linux or Mac) sets up and
  monitors the system. The modem is the controller: it "must always be powered when the Navigation
  System is working," and a USB power bank is fine. The boat's hedgehog streams its position over
  USB straight to the KR260; the laptop isn't in that path.
- **The Dashboard doesn't take a live GPS feed.** You type in the latitude and longitude of the
  map's (0,0) point in the modem's settings, then rotate the map so +Y points to true north ("The
  Marvelmind system cannot determine north automatically").
- **So the GPS measures two points per setup:** the origin beacon, and a second beacon to set
  north. With the GPS on the laptop (u-center), average a few minutes at each point. Both points
  need open sky, so use beacons outside the bridge's shadow.
- **Output format:** once georeferenced, the hedgehog can stream standard NMEA0183 (or u-blox, or
  Marvelmind's own protocol, selected in the Dashboard), so the KR260 could read it with
  `nmea_navsat_driver` as if it were a GPS. Marvelmind's own protocol, through `marvelmind_ros2`,
  also carries the paired-beacon heading (below), which NMEA mode only provides with a paid license.

**Accuracy:**
- Marvelmind is ±2 cm relative, but its absolute accuracy is 1–3 % of the distance to the beacons
  (about 0.3–0.9 m at 30 m).
- The georeference adds the GPS's own error: the NEO-M8N is rated 2.0 m CEP. A 1 m error across a
  30 m baseline rotates the whole map about 2°, which adds roughly another 1 m at 30 m out.
- Net: meter-level absolute positions and centimeter-level relative ones, which is fine for pier
  geometry. If the sponsor needs better absolute accuracy, survey the two points with RTK or
  survey-grade GNSS; nothing on the boat changes.

**Coverage, the constraint this decision accepts:**
- In 2D the boat needs line of sight to at least 2 stationary beacons within about 30 m everywhere
  it goes (3D needs 3). Marvelmind recommends 30 m between beacons (up to 50 m indoors). The
  ~100–400 m radio range is only the data link, not positioning range.
- Piers block the ultrasound, so beacons have to be placed to cover the area behind each pier.
- Outside coverage the boat has no position at all, so `mission_manager` needs a defined behavior
  for a stale position (stop and let the pilot take over).
- Longer routes need submaps, roughly a beacon every 30 m. The survey area's extent now decides how
  many beacons to buy.

**Heading option: paired beacons.** Two hedgehogs on the boat, at least 20 cm apart (farther is
more accurate), report direction as well as position, with no magnetometer, which matters next to
a steel bridge. Heading is free in Marvelmind's own protocol; in NMEA mode the heading sentence
($GPHDT) is a paid license (MMSW0002, per beacon). A Super-MP-3D set is 4 stationary beacons plus 1
mobile, so pairing means buying a sixth beacon or running on 3 stationary. The heading source is
still an open decision (§4).

**Check the beacons:** the standard Super-Beacon isn't the IP54 outdoor version, and the one on the
boat will see spray. All units must be on the same radio band (915 MHz in the US).

### 8.2 Fusion architecture

With the GPS on shore, `robot_localization` fuses Marvelmind position with the heading source (§4)
and any IMU; there's no GPS-to-Marvelmind blending to design. `navsat_transform` is only needed if
the hedgehog runs in NMEA mode.

**Marvelmind ROS2 package: closed.** `ros-humble-marvelmind-ros2` 1.0.3 (with
`ros-humble-marvelmind-ros2-msgs` 1.0.2) installs from the Humble apt repo for arm64, checked on
the board. Upstream is marked unmaintained (last pushed November 2022), so pin the version; what's
left is running it against the real hedgehog during bring-up.

**Action items:**
- [ ] Get the survey area's real extent (§8.1); it now sizes the beacon count and placement.
- [ ] Plan beacon placement so every survey point sees at least 2 stationary beacons within ~30 m,
      including behind each pier.
- [x] ~~Confirm the Marvelmind ROS2 package builds on ROS2 Humble~~ — **closed: in the Humble apt
      repo for arm64.** Still run it against the real hedgehog during bring-up.
- [ ] Define `mission_manager`'s behavior when the Marvelmind position goes stale.
- [ ] Check that the team's beacons are the outdoor (IP54) version, or protect them, and that all
      are on the same radio band.
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

**Measured baseline (Sep 2026, idle, headless, before ROS2):** about 230 MB used and about 3.5 GB
available, out of 3.9 GB visible to Linux (`free -m`). The 1 GB CMA reservation counts as available
until the DPU claims it. Of the running system services, `snapd` (~39 MB), `multipathd` (~25 MB),
`unattended-upgrades` (~21 MB), `check-new-release` (~18 MB), `packagekitd` (~17 MB) and `udisksd`
(~12 MB) look unneeded on the boat, so another trim pass could free about 130 MB.

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
and the safety behavior around it. Ties together §4 (T200/Basic ESC), §6 (PMOD J2/J18), §3 (manual
override), §3.1 (the RC survey button), and §2 (decided: full replacement, external mux for manual
override).

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
- **Power:** each ESC runs straight off the battery bus through its own fuse (§15). Its
  servo-style lead is signal and ground only (the middle position is empty; the Basic ESC has no
  BEC), so the mux and receiver never carry thruster current and the ESCs never power them. Peak
  draw and the throttle cap that keeps it under the ESC and fuse ratings are in §15.2. All
  grounds are common.
- **Enclosure:** the Basic ESC is a hobby ESC, not waterproof. It lives in a waterproof box with
  the rest of the electronics, with the thruster cable through a penetrator.

### 13.2 The signal chain

```
RC receiver  ──(2 thrust PWM ch)──►  buffer ──►  M inputs ┐
                                                          │  PWM mux  ──(L/R PWM)──►  Basic ESC ×2 ──► T200 ×2
KR260 PL PWM ──(2 PWM, PMOD J2)───►  buffer ──►  S inputs ┘
Spare RC ch  ─────────────────────────────────►  SEL
```

The buffer, the pull-downs, and the mux all sit on one interface board (§13.7).

**KR260 side (autonomous path):**
- PWM generation in **PL**, on **PMOD J2** (§6): a small AXI-attached PWM core (two channels,
  50 Hz period, pulse width settable at ~1 µs resolution over 1100–1900 µs), plus a device-tree
  node and a bitstream. PMOD outputs are 3.3 V logic, below the ~3.4 V the mux's logic chip needs
  for a guaranteed high, so they reach the mux through the interface board's buffer (§13.7).
- A ROS2 node converts navigation commands (speed/steer or left/right) into the PL registers.
  Mixing to left/right happens here for the autonomous path.
- **Watchdog in PL:** if the PS stops refreshing the PWM registers (Linux/ROS2 hang), the PL
  forces both outputs to neutral after a short timeout, without software involvement. This is
  the same "works even when Linux is dead" idea as the e-stop design in §6.
- Neutral is the reset state. On bitstream load or PS reset the outputs are 1500 µs, never 0.

**RC side (manual path):** a hobby RC receiver with PWM outputs. Its outputs are also 3.3 V, so
the two thrust channels go through the same buffer; SEL connects to the mux directly, since the mux
reads SEL through a transistor that works at 3.3 V. Left/right mixing for manual
driving is done in the transmitter or receiver (e.g. a differential/"tank" mix), since the mux
passes two independent channels straight through. The survey button (§3.1) skips the mux: the
interface board passes it to the KR260 on the PMOD J2 cable.

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
| **A. Basic ESCs + Pololu 4-channel RC servo multiplexer (recommended)** | Hardware. A spare RC channel on SEL picks master (M) or slave (S) inputs per a user-set threshold (default ~1700 µs, ±64 µs hysteresis). | ~$18 ([product](https://www.pololu.com/product/2806); buy unassembled, [#2807](https://www.pololu.com/product/2807), for the interface board, §13.7) | Purpose-built for autonomous/manual override. 2.5–16 V supply, SEL accepts 0.5–2.5 ms pulses at 10–330 Hz. Failsafe is a jumper: off, master inputs take control if SEL is lost; on, outputs go low. Keeps the Basic ESCs. Works with the KR260 hung or unpowered. |
| B. Basic ESCs + Acroname RxMux | Same idea, 8 channels, 2 sources. | ~$19 ([product](https://acroname.com/store/s56-rxmux-1)) | Defaults to input A if SEL is absent, and the vendor states it provides no failsafe or redundancy by itself. More channels than needed here. |
| C. Mux inside the PL | Logic in the KR260's fabric selects between the decoded RC signal and the autonomous PWM. | No hardware cost | Extends the J18 e-stop gating design. Loses manual control if the KR260 loses power or the PL is unconfigured, which is exactly when a manual override matters. Acceptable only if the KR260 is trusted to stay up. |
| D. Option B hybrid low-level board (§2) | Native to the flight-controller firmware (ArduRover RC passthrough and mode arbitration). | Depends on board | No separate mux needed and no PL PWM work. **Not applicable:** §2 chose full replacement with an external mux. Kept for reference. |
| E. VESC-class ESCs | Firmware supports combined PPM+UART control ([Flipsky](https://flipsky.net/blogs/vesc-tool/vx4-three-control-mode-ppm-uart-ppm-and-uart)). | Varies | Which input wins when both are active was not found documented, and T200 compatibility with VESC is unconfirmed. Not recommended without a bench test. |
| F. Roboteq BLDC controllers | RC, serial and CAN inputs. | High | Sized for much larger motors than a T200. Input-priority behavior not verified. Overkill here. |

**Decision context:** §2 chose full replacement with an external mux for manual override, which is
this section's Option A (the Pololu mux; not the same "Option A" as in §2). **Checked against
Pololu's schematic and product photo:** the mux is a 74VHC157 logic multiplexer, so pulse widths
pass through unchanged (nanoseconds of delay, no regeneration). It isn't guaranteed to read the
KR260's or the receiver's 3.3 V signals as high, and its inputs have no pull-downs; the interface
board (§13.7) adds a buffer and pull-downs for both. Still scope the outputs on the bench (§13.6).

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
  (the KR260, which would keep running the survey, or the manual channel, likely at neutral). Choose it
  on purpose and write it down.

### 13.5 RC transmitter and receiver

The mux (§13.3 Option A) needs an RC receiver that has PWM outputs and lets you set a failsafe
value on each channel. Channel budget: left thrust, right thrust, SEL (mode switch), plus the
survey button (§3.1). The mux's SEL input accepts 0.5–2.5 ms pulses at
10–330 Hz, so any standard RC channel works electrically.

**Failsafe is the requirement that matters.** Pololu's default SEL threshold is about 1700 µs,
with the slave (KR260) inputs live above it. If the team wants the KR260 to take over when the RC
link drops (e.g. to keep surveying), SEL's failsafe value must sit above roughly 1700 µs
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

**Transmitter setup (EdgeTX):**
- **Stick-to-pulse mapping:** ELRS maps ±100 % stick to 988–2012 µs (1500 ± 512 µs), so 1 % is
  about 5.12 µs and the ESC's full 1100–1900 µs range is about ±78 %. The throttle cap (§15.2)
  becomes an output limit below that: limit % = (cap − 1500 µs) ÷ 5.12. A 1200–1800 µs cap, for
  example, is about ±59 %.
- **Stick choice:** put both thrust axes on the spring-centered stick (normally the right one) and
  mix there: left = forward + turn, right = forward − turn. Letting go of the stick then means
  stop. A non-centering throttle stick left low would command reverse, and the ESC only arms at
  neutral. Per the BLHeli_S manual Blue Robotics hosts, it also starts throttle calibration if it
  sees full throttle while arming.
- **Survey button:** a momentary button on its own channel, failsafe "not pressed" (§3.1).

**Not yet verified:**
- The Pocket product page doesn't detail EdgeTX's left/right ("tank") mixing. EdgeTX's mixer is
  believed to support it, but confirm before buying.
- No real-world range figure was found for the ER8. Check the link against the longest river
  distance planned.
- The ER8 product page doesn't mention per-channel failsafe; that comes from the ExpressLRS docs
  and RadioMaster's guide.

### 13.6 Build and test checklist

- [ ] Bench: one T200 + Basic ESC + KR260 PL PWM alone (no mux): arming, stop, both directions,
      deadband around 1500 µs (check the T200 datasheet for the exact range).
- [ ] Bench: add the interface board with the mux (§13.7); scope the output pulse widths against
      the inputs and test SEL switching mid-run.
- [ ] Bench: run the interface board's signal-loss tests (§13.7) before the mux goes in the boat.
- [ ] Confirm arming works through the mux, including power-up with SEL in each position.
- [ ] Test PL watchdog: kill the ROS2 node, then hang Linux; outputs must go to neutral.
- [ ] Test SEL loss, RC receiver power loss, and KR260 power loss; record who has control in each.
- [ ] Wire and test the e-stop per §13.4 in whichever form the team chooses.
- [ ] On-water check of thrust against river current (§16 item; inherited assumption).

**Action items:**
- [ ] Buy the Pololu mux unassembled (#2807) and build the interface board around it (§13.7).
- [ ] Decide what the e-stop cuts and where (§13.4).
- [ ] Confirm the RC pair (§13.5, recommended Pocket ELRS + ER8): check EdgeTX tank mixing and
      range, set per-channel failsafe (SEL above ~1700 µs if the KR260 should take over on link
      loss; the survey button to "not pressed").
- [ ] Set the throttle cap in both the PL clamp and the transmitter's output limits (§15.2).

### 13.7 Interface board: buffer, pull-downs, and the mux

One small perfboard carries the mux and the parts around it. It fixes two problems found in the mux
and ESC documentation:

- **3.3 V margin.** Pololu's schematic and product photo show the mux is a 74VHC157 logic
  multiplexer, powered from a 5 V regulator on the mux board. Its datasheet guarantees a logic high
  only above 0.7 × VCC, about 3.4 V here. Both signal sources are 3.3 V: the ER8 (an ESP-based
  receiver) and the KR260's Pmod pins. It would probably work, but it's outside the guaranteed
  range, with little noise margin next to 30 A ESCs. SEL doesn't need help: the mux reads it
  through a transistor, which works at 3.3 V.
- **Undriven signal lines.** Blue Robotics doesn't document what the Basic ESC does when its pulses
  stop (asked on their forum, staff weren't sure), and the BLHeli firmware project has an open
  report of a motor that kept spinning after its signal wire was pulled. The mux's M and S inputs
  connect straight to its logic chip with no pull-downs, so an unpowered KR260 or an unplugged
  receiver leaves them floating, and a mux that loses power leaves the ESC lines floating.

```
                    74AHCT125 buffer
ER8 left     ─●─ 2  1A      1Y  3 ─── mux M1
ER8 right    ─●─ 5  2A      2Y  6 ─── mux M2
KR260 left   ─●─ 9  3A      3Y  8 ─── mux S1
KR260 right  ─●─ 12 4A      4Y 11 ─── mux S2
                 1, 4, 10, 13 (enable pins) ─ GND
                 14 ─ +5 V   (0.1 µF to GND right at the pin)
                 7  ─ GND
● = 10 kΩ from that line to GND

ER8 SEL ─────────────────────────────── mux SEL (no buffer needed)
ER8 button   ── 2.2 kΩ ──●───────────── KR260 PMOD J2 (button input, no buffer)
mux M3, M4, S3, S4 ─ GND
mux OUT1 ─── left ESC signal    (10 kΩ to GND at the ESC end)
mux OUT2 ─── right ESC signal   (10 kΩ to GND at the ESC end)
```

- **Buffer:** SN74AHCT125N (TI, through-hole, in production; the pin numbers above are from its
  datasheet). It reads anything above 2.0 V as high at a 5 V supply and outputs about 5 V, above
  the mux's ~3.4 V threshold. The mux's datasheet allows inputs up to 5.5 V regardless of its own
  supply.
- **Pull-downs:** 10 kΩ on each buffer input, so a dead, unpowered, or unplugged source reads as a
  steady low instead of a floating line. The two ESC pull-downs go at the ESC end of the signal
  lead (a resistor spliced between signal and ground under heat-shrink): that's the only place
  that also covers the lead coming unplugged at the board.
- **Power:** from the mux/receiver 5 V BEC (§15.3), whose servo lead plugs into the board. The
  same 5 V reaches the mux and the ER8 through the center wires of the servo leads. Add a
  10–100 µF capacitor across the board's 5 V input.
- **Mux mounting:** the unassembled Pololu mux (#2807, the same board without its headers
  soldered) solders straight onto the perfboard, so the buffer-to-mux links are short wires instead
  of four more servo cables. Keep its LED, its threshold-learning pins, and its failsafe jumper
  reachable.
- **Unused mux inputs (M3, M4, S3, S4) go to ground.** The 74VHC157 datasheet says unused inputs
  "must always be tied to an appropriate logic voltage level." On the pre-assembled mux a jumper
  cap can't do this, because the 5 V pin sits between signal and ground; on the perfboard it's a
  wire.
- **KR260 link:** one cable to PMOD J2 carrying PWM left, PWM right, the survey button, and
  ground, on a connector type the servo headers don't use (e.g. a 4-pin JST-XH), so a 5 V servo
  lead can't be plugged into it.
- **Survey-button line (§3.1):** the ER8's 3.3 V output suits the KR260's 3.3 V Pmod bank, so it
  needs no buffer. The 2.2 kΩ series resistor keeps the receiver from pushing current into the
  KR260's pin while the KR260 is off, and the 10 kΩ pull-down on the KR260 side holds the line
  low when the receiver is unplugged. The pin still sees about 2.7 V, above the 2.0 V it needs.
- **Vibration:** glue or lock the friction-fit headers.

| Part | Qty |
|---|---|
| SN74AHCT125N + 14-pin DIP socket | 1 |
| 10 kΩ resistor (5 on the board, 2 at the ESCs) | 7 |
| 2.2 kΩ resistor | 1 |
| 0.1 µF ceramic capacitor | 1 |
| 10–100 µF electrolytic capacitor | 1 |
| Perfboard | 1 |
| 0.1" male headers | as needed |
| 4-pin JST-XH connector pair | 1 |
| Pololu 4-channel RC servo mux, unassembled (#2807) | 1 |

**Bench tests before the mux goes in the boat.** Run them with the thruster in water: Blue Robotics
warns against running a T200 dry for more than 10 seconds.

- [ ] With the ESC powered and nothing on its signal lead, measure the signal pin. It should float
      or sit low; an internal pull-up would fight the 10 kΩ pull-down.
- [ ] Scope each mux output against its input, from both the receiver and the KR260.
- [ ] Survey button: the PL register follows the button, and shows no pulses with the receiver
      unplugged.
- [ ] With a thruster running, pull each source while it's in control: the KR260 cable with SEL on
      autonomous, then the receiver's thrust lead with SEL on manual. Then unplug the ESC lead at
      the board, and finally cut the board's 5 V. The thruster must stop each time; record how
      long it takes. If it doesn't stop, the pull-downs aren't enough on their own and the
      power-cut e-stop (§13.4) is the only reliable stop.

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
| Power | Battery, distribution, fusing, regulation for the KR260/USB hub/sensors, thruster supply | §15 |
| Propulsion | 2× T200 + Basic ESC, interface board with the PWM multiplexer, RC receiver | §13 |
| Sensing | Ping2, RPLidar S2, Marvelmind, OAK-D camera, heading source (open). The GPS stays on shore. | §4, §6, §8 |
| Compute | KR260: PS (Linux, ROS2) + PL (DPU, thruster block) | §1, §10, §11, this section |
| Communications | SSH over Ethernet in the lab; field WiFi and the RC survey button; 2.4 GHz RC link | §3.1, §7, §13.5 |
| Safety | External mux + RC override, PL watchdog, hardware e-stop, RC failsafe | §2, §13.4, §14.6 |

### 14.2 System block diagrams

**Digital systems and thrusters.**

```
┌─ USB devices ──────────────────┐      ┌─ KR260 ──────────────────────────────────────────────────┐
│ USB0 ── powered hub            │      │ PS: Linux + ROS2                    PL: one bitstream    │
│         ├─ Ping2 (BLUART)      │      │  sensor drivers                                          │
│         ├─ RPLidar S2 (data)   ├─────►│  robot_localization                                      │
│         └─ Marvelmind hedgehog │      │  mission_manager, avoidance                              │
│ USB1 ── OAK-D camera           │      │  dpu_detector (VART)   ◄─ AXI HP ─►  DPU (YOLO)          │
│ (microSD / OS disk is on USB0) │      │  motor_mixer                                             │
└────────────────────────────────┘      │  thruster_driver (UIO) ◄ AXI-Lite ►  thruster block:     │
                                        │                                      2× PWM, clamp,      │
  Ethernet ── SSH (lab; field §3.1) ───►│                                      watchdog, e-stop,   │
                                        │                                      survey button in    │
                                        │                                                          │
                                        └─────────────────────────┬───────────────────────┬────────┘
                                                                  │ PMOD J2: 2× PWM out,  │ J18
                                                                  │ survey button in      │
┌─ ER8 receiver ─────────┐                  ┌─ Interface board ───┴─────┐                 ▲
│ L, R, SEL,             ├─────────────────►│ buffer, pull-downs, mux;  │           e-stop switch
│ survey button          │                  │ button passed to J2       │
└────────────────────────┘                  └─────────────┬─────────────┘
                                                          │
  RC transmitter (pilot, shore)                           ▼
  ~~ 2.4 GHz ELRS ~~► ER8                     Basic ESC ×2 ──► T200 ×2
```

The mux sits outside the KR260, on the interface board with a buffer and pull-downs (§13.7). With
SEL on manual, the RC receiver drives the ESCs directly and the KR260 has no influence on the
thrusters. With SEL on autonomous, the PL's PWM outputs drive them. The survey button skips the
mux: the interface board passes it to the KR260 on the same PMOD J2 cable (§3.1).

**Whole robot: power, sensors, digital systems, and thrusters.** Double lines carry power, single
lines carry signals and data, and `~~` marks radio links.

```
═══ power      ─── signal / data      ~~ radio

5S battery pack(s), 15–21 V ══ main fuse ══ e-stop cut point (open, §15.5) ══╗
                                                                             ║
┌─ Blue Sea 5025 fuse block (negative bus = common ground; 1 circuit spare) ─╨─────────────────────┐
└─────╥───────────────────────────╥───────────────────────────╥─────────────────────╥─────╥────────┘
      ║ 5 A                       ║ 5 A                       ║ 2 A                 ║ 30 A║ 30 A
      ║ Blue Sea 1045             ║ 12 V regulator            ║ 5 V BEC             ║     ║
      ║             ╔═ 2 A fuse ══╣                           ║                     ║     ║
┌─────╨─────────────╨───┐     ┌───╨─────────────────┐     ┌───╨───────────────┐   ┌─╨─────╨────────┐
│ USB devices           │     │ KR260               │     │ Interface board   │   │ Basic ESC ×2   │
│ powered hub:          │ USB0│ PS: Linux + ROS2    │ J2  │ buffer,           ├──►│ (raw battery)  │
│  Ping2 (BLUART)       ├─────┤  drivers, fusion,   ├─────┤ pull-downs,       │   └───────╥────────┘
│  RPLidar S2 (data)    │     │  mission, avoidance │     │ Pololu mux        │           ║
│  Marvelmind hedgehog  │ USB1│ PL: DPU (YOLO),     │     └─────────┬─────────┘        T200 ×2
│ OAK-D camera          ├─────┤  thruster block     │               │
│ 1045 ═ lidar, camera  │     │  (PWM, watchdog,    │     ┌─────────┴─────────┐
│ 12 V ═ hub            │     │  e-stop, button)    │     │ ER8 receiver      │
└───────────────────────┘     └──┬──────────────┬───┘     │ L, R, SEL, button │
                                 │              ▲         └───────────────────┘
                                 │        e-stop switch (J18)
                                 └── Ethernet (SSH)

┄┄ shore ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄
Laptop: SSH (cable, or WiFi / travel router, §3.1); Marvelmind Dashboard (setup)
USB GPS on the laptop: georeferences two beacons, then stays on shore (§8.1)
Marvelmind modem (USB power bank) + 4 stationary beacons ~~ radio + ultrasound ~~ hedgehog
RC transmitter (pilot) ~~ 2.4 GHz ELRS ~~ ER8 receiver
```

Everything on the boat runs from one fuse block (§15). The KR260 and its sensors sit on the 12 V
and USB-charger branches. Manual control (interface board, mux, receiver) has its own 5 V branch,
so it keeps working if the KR260 or its regulator fails. The GPS and the Marvelmind modem stay on
shore (§8.1).

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
  PYNQ is still unverified (see §14.10).
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
- **Automation:** a systemd oneshot unit runs the load before the ROS2 launch starts, and the
  launch is a systemd service too, so the boat is ready in the field without anyone logging in
  (§3.1).
- **Safe state during boot:** until the bitstream loads, the PMOD pins are not driven. The
  interface board's pull-downs hold those lines low (§13.7), and the mux must default to **manual
  (RC)** so the ESCs see the receiver's neutral. Verify the Pololu SEL default and failsafe jumper
  (§13.3), and never leave SEL on autonomous while reloading the bitstream.

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
| 0x24 | BUTTON_US | RO | Pulse width measured on the survey-button input (PMOD J2); 0 if no pulses for 100 ms (§3.1) |

Hardware rules that do not depend on software:
- Pulse widths are **clamped in the PL**, whatever software writes: never outside 1100-1900 µs,
  and narrowed further to the bench-measured throttle cap (§15.2).
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
| Upstream navigation stops sending commands | `thruster_driver` stops refreshing the heartbeat (see §14.7), same as above | Pilot |
| KR260 loses power | PL outputs are undriven; the interface board's pull-downs hold them low (§13.7). Whether the Basic ESC then stops is **undocumented**; bench-test it (§13.7). | Pilot must already be on manual, or flip to it |
| RC link lost | Receiver sets SEL and thrust channels to their configured failsafe values (§13.5) | Per failsafe setting |
| E-stop pressed | PL forces neutral on the autonomous path. Power cut is still to be decided (§13.4). | Depends on §13.4 |
| Boot or bitstream reload | PMOD pins undriven until load completes; pull-downs hold them low | Mux defaults to manual (§14.4) |

### 14.7 ROS2 software architecture

| Node | Runs | Inputs | Outputs |
|---|---|---|---|
| Sensor drivers: `rplidar_ros`, `depthai-ros`, Ping2 (`bluerobotics-ping` wrapper), `marvelmind_ros2`, heading (TBD) | PS | USB devices | `/scan`, camera images and depth, sonar depth, Marvelmind position (and paired-beacon heading, if used), IMU |
| `robot_localization` | PS | Marvelmind, heading, IMU | Fused pose and odometry (§8) |
| `dpu_detector` (C++, VART) | PS + DPU | Camera RGB | Detections (e.g. `vision_msgs`) |
| Obstacle avoidance | PS | Detections, `/scan`, depth | Adjusted velocity request |
| `mission_manager` | PS | Fused pose, waypoints, survey button (§3.1) | Survey start/stop and hold; clean shutdown on a long press |
| `motor_mixer` | PS | Speed and yaw request | Left/right thrust, -1 to 1 |
| `thruster_driver` (C++, UIO) | PS to PL | Left/right thrust | PL registers; publishes thruster status (actual µs, watchdog, e-stop) and the survey button |
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
4. **ROS2 integration:** the nodes in §14.7, then the mux and ESC bench tests (§13.6).

Spikes A and B are independent and can run in parallel between teammates.

### 14.9 What the whole-robot plan still needs from other subsystems

- **Power:** now its own section (§15). Still missing from it: battery capacity and C rating,
  and the e-stop cut point.
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
- [ ] Decide the PMOD pin mapping for the PWM, survey button, e-stop, and (optionally) SEL
      monitoring and a status LED, against the KR260 pinout.
- [ ] Verify the Basic ESC stops when the interface board's pull-downs hold its signal line low
      (KR260 power loss case, §13.7).
- [ ] Decide whether to shrink `cma=1000M` and fold the result into the §10 memory budget.
- [ ] Get the mechanical inputs listed in §14.9 (power is §15).

---

## 15. Power system

Two 5-cell lithium packs in parallel feed a fused distribution block. The thrusters run straight
off the battery bus. The KR260 and the mux/RC receiver each get their own regulator, fed directly
from the bus, so one load can't pull down another's voltage and manual override never depends on
the KR260's supply. The USB sensors are powered from the fuse block too, through a marine USB
charger and a powered hub, so the KR260's USB ports carry data plus, at most, the camera (§15.4).
Reused from the old boat: the batteries, and whichever of the leftover
ServoCity cables are heavy enough for their branch (§15.4).

### 15.1 Batteries

- **What we have:** two 5S lithium packs (18.5 V nominal, about 21 V full), wired in parallel as
  the previous team had them. Parallel is right: in series they'd be about 42 V, double the
  thrusters' rating. Parallel doubles capacity and splits the current between the packs. The
  chemistry (LiPo or Li-ion), capacity (Ah), C rating, and connector are on the label and still
  need to be read; the charger profile has to match the chemistry.

### 15.2 Voltage and current against component ratings

| Component | Rating | Against a 5S pack (≈15–21 V) |
|---|---|---|
| T200 thruster | 7–20 V, 12–16 V recommended. Full throttle: 24 A at 16 V, 32 A at 20 V | **About 1 V over at full charge.** See below. |
| Basic ESC | 7–26 V, 30 A continuous (depends on cooling) | Voltage fine. Full throttle near 20 V (~32 A) is over its current rating. |
| 12 V regulator (Pololu D36V50F12) | 13.3–50 V in | Fine across the whole discharge range |
| 5 V BEC (Blue Robotics 5V 6A) | 7–26 V in | Fine |
| Blue Sea 5025 fuse block | 32 V DC, 30 A per circuit, 100 A per block | Fine, given the throttle cap below |
| Pololu mux VM rail | 2.5–16 V | **Must never see battery voltage.** Fed only from the 5 V BEC. |
| RadioMaster ER8 receiver | 4.5–8.4 V | Fed from the 5 V BEC |
| Blue Sea 1045 USB charger | 9–32 V in; 5 V ±5 %, 2.4 A per port, 4.8 A total | Fine |
| Powered USB hub (StarTech ST4200USBM) | 7–24 V in | Only 3 V above a full pack, so it's fed from the 12 V regulator instead (§15.4) |

**Over-voltage at full charge (T200: 21 V vs. its 20 V max).** Two ways to handle it:
- **Charge to 4.0 V/cell (20.0 V), if the charger allows a lower end voltage.** Every component
  stays in spec, at the cost of some capacity per charge (commonly cited as roughly 10–20%), and
  it's easier on the cells. Preferred if the charger supports it.
- **Or charge to 21 V and rely on the throttle cap.** Pack voltage sags under load and falls
  below 20 V early in a run. The part that sees raw bus voltage is the ESC (rated to 26 V), and
  the cap limits the power the motor gets. Confirm with Blue Robotics before relying on this.

**Throttle cap (required either way).** The old team reports about 7–8 A per thruster in normal
use (unverified), but full throttle near 20 V is about 32 A per thruster: over the Basic ESC's
30 A rating and the 30 A branch fuses. Cap the throttle so each thruster stays around 20–25 A at
most. The cap has to be set in **two places**, because the RC path never passes through the
KR260:
- **Autonomous path:** the PL clamp (§14.5).
- **Manual path:** output limits on the thrust channels in the transmitter (EdgeTX).

Set the value from a bench measurement (a clamp meter on one ESC's supply while stepping the
pulse width), not a guess. Current doesn't scale linearly with pulse width.

### 15.3 Distribution
Each branch gets a regulator, in a star layout:

```
Battery pack(s), 5S, parallel (≈15–21 V)
   │
 Main fuse (at the battery)
   │
 [E-stop — cut point open, §13.4 / §15.5]
   │
 Blue Sea 5025 fuse block (positive bus + fuses; negative bus = common ground)
   ├── 30 A ── Basic ESC L ── T200 L          (raw battery, no regulator)
   ├── 30 A ── Basic ESC R ── T200 R          (raw battery, no regulator)
   ├──  5 A ── 12 V regulator ─┬─ KR260 (USB data to the sensors)
   │                           └─ 2 A inline fuse ── powered USB hub (sonar, Marvelmind; lidar data)
   ├──  2 A ── 5 V BEC ── interface board (§13.7) ── mux VM rail + RC receiver
   ├──  5 A ── Blue Sea 1045 USB charger ── lidar adapter power; optional camera Y-adapter
   └── spare
```

Rules:
- **Every regulator is fed directly from the bus, never from another branch.** In particular the
  5 V BEC doesn't hang off the 12 V branch: manual override has to keep working when the KR260 or
  its regulator fails (§2, §13).
- **The 5 V BEC powers the interface board (§13.7)**, which passes 5 V on to the mux's VM rail and,
  through the servo leads' center wires, to the receiver. Per Pololu, the mux draws its power from
  its VM pins and the receiver shares the rail. The KR260 connects only signal and ground.
- **The powered USB hub is the one load hung off the 12 V branch.** It only serves the KR260's
  sensors, which are useless without the KR260 anyway, and its own 2 A inline fuse limits what a
  USB fault can do to the KR260's supply.
- **Common ground, wired as a star:** the KR260's PWM needs the mux's ground as its reference, so
  all grounds are common. Run each branch's negative wire back to the fuse block's negative bus on
  its own, so thruster current never flows through a signal ground. The ground wires in the servo
  leads and the KR260 cable should carry only signal return.
- **Brownout:** thruster surges pull the bus down briefly. The regulator's 13.3 V minimum leaves
  margin above an empty 5S pack (~15 V), but add bulk capacitance at the 12 V regulator's input
  and watch for KR260 resets during hard throttle changes on the bench.
- **Every wire must be rated above the fuse that protects it** (starting fuse sizes are in the
  diagram and §15.4).

| Part | Role | Notes |
|---|---|---|
| **[Blue Sea 5025](https://www.bluesea.com/products/5025/ST_Blade_Fuse_Block_-_6_Circuits_with_Negative_Bus_and_Cover) (recommended)** | Fuse block: 6 circuits, negative bus, cover | 30 A per circuit, 100 A per block, 32 V DC, ATO/ATC blade fuses, ring terminals. Distribution, per-branch fusing, and common ground in one marine-rated part. |
| [Blue Sea 2307](https://www.bluesea.com/products/2307/Common_150A_BusBar_-_Four_1_4in-20_Studs_with_Cover) bus bars (+ and −) with inline fuses | Alternative | 150 A, 4 studs each. Use if a branch ever needs more than 30 A. More parts and bulk. |
| Main fuse and holder (MIDI/ANL class) | Main protection | 60–80 A, as close to the battery as possible, below the block's 100 A |
| [Pololu D36V50F12](https://www.pololu.com/product/4095) | 12 V for the KR260 | 12 V, up to 4.5 A (~54 W, above the KR260's 36 W adapter), 13.3–50 V in. A step-down is enough on 5S; no buck-boost needed. Also feeds the powered USB hub, a small load once the lidar is powered separately. |
| [Blue Robotics 5V 6A Power Supply](https://bluerobotics.com/store/comm-control-power/control/bec-5v6a-r1/) | 5 V for the interface board, mux, and receiver | 7–26 V in. Far more current than needed; chosen because it's built for this and comes from the thrusters' vendor. |
| [Blue Sea 1045](https://www.bluesea.com/products/1045/12_24V_DC_Dual_USB_Charger_4.8A_with_Intelligent_Device_Recognition) | 5 V USB power for the lidar (and optionally the camera) | 9–32 V in, 5 V ±5 %, 2.4 A per port, 4.8 A total. Potted; mounts in a 1-1/8" hole. |
| [StarTech ST4200USBM](https://www.startech.com/en-us/cards-adapters/st4200usbm) (or equivalent) | Powered USB hub (§6) | 4-port USB 2.0, metal, DIN-rail or wall mount, 3-pin screw terminal taking 7–24 V. 0–55 °C operating. Per-port current isn't published. |
| [Luxonis OAK Y-adapter](https://shop.luxonis.com/products/oak-y-adapter) (optional) | Separate power for the camera | $24. Data goes to the KR260, power comes from a USB charger port. |

Drone-style solder-pad distribution boards were considered and not recommended: no fusing, not
marine-rated, and harder to rework.

### 15.4 Current budget and wiring

| Branch | Typical | Peak | Fuse | Wire |
|---|---|---|---|---|
| ESC L / ESC R (each) | 7–8 A (old team, unverified) | ~32 A uncapped near 20 V; 20–25 A with the cap | 30 A | 14 AWG (the ESC's own leads); heavier for long extensions |
| 12 V regulator → KR260 + powered hub | — | ~3 A from the battery with the KR260 at its 36 W max plus the hub's sensors (≈90% efficient) | 5 A | 16–18 AWG |
| Blue Sea 1045 → lidar (+ camera) | ~0.6 A at 5 V (lidar running) | Up to 1.5 A at 5 V at lidar startup; under 2 A from the battery even at the charger's full 4.8 A | 5 A | 18 AWG |
| 5 V BEC → mux + receiver | well under 0.5 A | — | 2 A | 20–22 AWG |
| Main (battery → block) | ~17 A cruising | ~55 A with the cap | 60–80 A | 8–10 AWG |

- **Runtime** ≈ pack capacity (Ah) ÷ average current. At the old team's figure the boat averages
  about 17 A cruising, so capacity ÷ 17 gives hours on one pack. Fill in once the label is read.
- **Leftover ServoCity cables:** their servo-style cables are typically 22–26 AWG. Fine for PWM
  signal leads and the 5 V mux/receiver branch; not for ESC or main runs. Check the gauge printed
  on each cable before assigning it.
- **ESC power leads:** the Basic ESC's 14 AWG power leads come with #6 spade terminals, but the
  Blue Sea 5025's branch screws are #8-32 (its bus studs are #10-32). Re-crimp both leads of each
  ESC with #8 ring terminals for 14 AWG; rings also hold better under vibration. Blue Robotics
  sized the 14 AWG leads for the ESC's 30 A rating, which matches the 30 A fuse.

**USB power: the KR260's USB ports carry data; the sensors' power comes from the fuse block.** Each
KR260 port supplies up to 900 mA, each pair of ports shares a 1.0 A power switch, and all four share
2.0 A (UG1092). The heavy loads don't fit that: the RPLidar S2 needs up to 1.5 A to start (2.5 A
inrush; 450–600 mA running, at 4.9–5.2 V), the OAK-D draws 0.5–0.9 A, and the Ping2 peaks at 0.9 A.

| Load | Powered by | Notes |
|---|---|---|
| Sonar, Marvelmind (and the lidar's data line) | Powered hub on USB0 port A (§6) | Fed 12 V from the KR260's regulator through a 2 A inline fuse, not from the battery: a full pack's 21 V is too close to the hub's 24 V limit. |
| Lidar | Its USB adapter's own power input, from the Blue Sea 1045 | Slamtec's S2 kit includes a "USB-DC power cord" to "connect additional power to the USB adapter." The hub's per-port current isn't published, so it isn't relied on for the 1.5 A start. |
| Camera | Its KR260 port, with the neighboring port left empty (§6), or the optional OAK Y-adapter from the 1045's second port | The camera fits the KR260's per-port limit, but only just. |

Don't share the mux/receiver's 5 V BEC with any of this, so a USB fault can't take down manual
override.

### 15.5 E-stop in the power system

The cut point (§13.4) is still open, and the layout decides what's possible:
- **E-stop in the main line** (after the main fuse): cuts everything. Simplest, one switch. But
  the KR260 loses power uncleanly (SD-card corruption risk, logging stops) and the RC link dies
  with it.
- **E-stop on the thrusters only:** the two ESC circuits sit on their own positive bus behind a
  contactor or relay rated for the thruster current, with the electronics branches fed from ahead
  of it. Propulsion stops, while the KR260 keeps logging and the RC link stays up.

**Recommendation: thrusters only.** Stopping propulsion is what an e-stop is for, and keeping the
computer up preserves the log of whatever went wrong. Decide in §13.4.

### 15.6 Action items

- [ ] Read both battery labels: chemistry, capacity (Ah), C rating, connector.
- [ ] Take the swollen pack out of service and dispose of it.
- [ ] Inspect the good pack, check per-cell voltages, balance-charge it (attended).
- [ ] Decide the 21 V handling: charge to 4.0 V/cell if the charger allows it, or confirm with
      Blue Robotics that 21 V with a throttle cap is acceptable.
- [ ] Bench-measure thruster current against pulse width; set the throttle cap in the PL clamp
      (§14.5) and in the transmitter's output limits.
- [ ] Confirm the good pack's capacity × C rating covers the capped peak (~55 A) on its own.
- [ ] Check the gauge of the leftover ServoCity cables; assign them to signal and 5 V use unless
      they're heavy enough for more.
- [ ] Re-crimp both leads of each ESC with #8 ring terminals (§15.4).
- [ ] Decide the e-stop cut point (§13.4, §15.5).
- [x] ~~Decide how the powered USB hub is supplied~~ — **decided: 12 V from the KR260's regulator,
      with the lidar (and optionally the camera) powered from a Blue Sea 1045 USB charger (§15.4).**
- [ ] Bench: the lidar's supply reads 4.9–5.2 V at its connector while it runs (the charger's ±5 %
      is slightly wider than the lidar's range), and the powered hub doesn't back-feed the KR260
      (with the KR260 unplugged from power, its LEDs stay off when the hub is connected).
- [ ] Buy: Blue Sea 5025, main fuse and holder, Pololu D36V50F12, Blue Robotics 5V 6A, Blue Sea
      1045, StarTech ST4200USBM (or equivalent), a 2 A inline fuse holder, #8 ring terminals for
      14 AWG, ATC fuses (30 A ×2, 5 A ×2, 2 A, spares), and optionally the OAK Y-adapter. Check the
      1045's fuse size against Blue Sea's installation sheet.
- [ ] Price a replacement 5S pack (matching chemistry and capacity) for when budget allows.

---

## 16. Open questions / action items

- [x] ~~Decide Option A vs. B (§2)~~ — **decided: full replacement of the Cube, with an external
      PWM mux for manual override** (§2, §13). The KR260 now owns navigation, motor mixing, and
      PL-side failsafes.
- [ ] **Finalize the e-stop design (§13.4)**: what it physically cuts now that a mux is in the
      path, and who takes control when the RC link drops (§13.5).
- [x] ~~Define the manual-override path (§3)~~ — **answered: the RC receiver drives the mux
      directly** (§13.2, §13.3), independent of the KR260. Still open: live telemetry beyond WiFi
      range (§3.1).
- [x] ~~Identify the current GPS module~~ — confirmed **Here 3+ (DroneCAN, Cube-specific)**;
      **recommend replacing** with a plain USB/UART GNSS module (§4). **Action item:** purchase
      and confirm.
- [x] ~~Pick a replacement camera~~ — **Luxonis OAK-D family chosen** (§5); Aurora930 Pro
      considered and not recommended (short 0.3–3 m depth range, structured-light outdoor-sunlight
      risk). Still open: S2 vs. Lite, fixed vs. autofocus, and a DepthAI test on the KR260.
- [ ] **Heading source.** Nothing on the boat replaces the Here 3+'s compass yet, and with the GPS
      on shore, GPS-based heading is out. Options: Marvelmind paired beacons (no magnetometer;
      needs a sixth beacon or 3 stationary, §8.1), an external compass/IMU, or the OAK-D's IMU
      (§4). Magnetometers are unreliable near a steel bridge. Decide before finalizing the §8
      fusion design.
- [x] ~~Decide the GPS module~~ — **NEO-M8N (or M9N) USB module chosen, and it stays on shore**: it
      only georeferences the beacons from the laptop (§8.1). Buy it with an antenna.
- [x] ~~Decide Marvelmind-only vs. GPS-live (§8.1)~~ — **decided: Marvelmind only; the GPS
      georeferences the beacons from shore** (procedure in §8.1). Still open: the survey area's
      extent, which now sizes the beacon count and placement (§8.2).
- [ ] Sanity-check that the Basic-ESC/T200 thrust is adequate against river current, not just
      lake conditions (inherited assumption from the previous team).
- [x] ~~Decide whether the RPLidar A2M12 will work well with the KR260~~ — the KR260/USB
      interface side is fine either way; the real issue is the **sensor's own direct-sunlight
      limitation** for outdoor river use (§4). **Recommendation: replace with RPLidar S2**
      ($399, 80klux sunlight-rated, same USB integration path). **Action item:** purchase and
      confirm.
- [x] ~~Design the RC-triggered return-to-beacon behavior~~ — **dropped:** the mux lets the pilot
      take over and drive the boat back (§3.1).
- [ ] **Sign off on the physical port assignment (§6) as a team** — the camera alone on USB1, the
      sensors on a powered hub on USB0 — and buy the industrial powered hub it depends on
      (12 V-fed, §15.4). The lidar's scan-motor question is closed (§4), and the GPS CAN
      contingency is retired.
- [x] ~~Development environment / remote access~~ — **decided and working**: static IP, direct
      SSH to the board, boots headless by default (§7). SSH keys still to set up.
- [x] ~~Get the previous team's ROS2 code~~ — **decided not to reuse it** (§9); writing the ROS2
      stack from scratch instead. Their **training dataset is still wanted** — get the specific
      name(s)/links.
- [x] ~~Confirm the Marvelmind ROS2 package runs on current ROS2 Humble~~ — **closed:
      `ros-humble-marvelmind-ros2` installs from apt for arm64** (§8.2). The fusion design is now
      Marvelmind + heading (§8.2).
- [ ] Build a rough memory budget (§10) once the YOLO variant/DPU B-size are chosen.
- [ ] Rough DDR/bandwidth budget (§11) once camera + DPU size are chosen.
- [ ] Decide HLS vs. hand-written RTL for the PWM core (§13.2) — either is standard, pick based on
      team comfort.
- [ ] **Build the interface board (§13.7):** buffer, pull-downs, and the mux on one perfboard. Run
      its signal-loss bench tests before the mux goes in the boat.
- [ ] **Field access (§3.1):** build the RC survey button; host WiFi on the KR260 once the memory
      budget (§10) confirms the room, or use a travel router.
- [ ] **Power system (§15.6):** read the battery labels, retire the swollen pack, decide how to
      handle 21 V at full charge, set the throttle cap on both control paths, and buy the
      distribution and USB power parts (§15.4). Running on one pack until a replacement fits the
      budget.

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
- [ArduPilot Rover RC options / RETURN_TO_LAUNCH](https://ardupilot.org/rover/docs/parameters.html)
- [T200 Thruster specs (voltage, current, power)](https://bluerobotics.com/store/thrusters/t100-t200-thrusters/t200-thruster-r2-rp/)
- [Basic ESC specs (voltage, current, signal connector)](https://bluerobotics.com/store/thrusters/speed-controllers/besc30-r3/)
- [Blue Sea 5025 ST Blade fuse block, 6 circuits with negative bus](https://www.bluesea.com/products/5025/ST_Blade_Fuse_Block_-_6_Circuits_with_Negative_Bus_and_Cover)
- [Blue Sea 2307 Common 150A BusBar](https://www.bluesea.com/products/2307/Common_150A_BusBar_-_Four_1_4in-20_Studs_with_Cover)
- [Pololu D36V50F12 12 V, 4.5 A step-down regulator](https://www.pololu.com/product/4095)
- [Blue Robotics 5V 6A Power Supply](https://bluerobotics.com/store/comm-control-power/control/bec-5v6a-r1/)
- [Pololu 4-Channel RC Servo Multiplexer schematic (74VHC157, input wiring)](https://www.pololu.com/file/0J701/pololu-4-channel-rc-servo-multiplexer-schematic-diagram.pdf)
- [Pololu 4-Channel RC Servo Multiplexer, unassembled (#2807)](https://www.pololu.com/product/2807)
- [onsemi 74VHC157 datasheet](https://www.onsemi.com/download/data-sheet/pdf/74vhc157-d.pdf)
- [TI SN74AHCT125 datasheet](https://www.ti.com/lit/ds/symlink/sn74ahct125.pdf)
- [Blue Robotics forum: Basic ESC stop time after signal loss](https://discuss.bluerobotics.com/t/basic-esc-safety-time-to-stop-motors/12470)
- [BLHeli issue #517: motor keeps spinning with the PWM signal disconnected](https://github.com/bitdump/BLHeli/issues/517)
- [KR260 Starter Kit User Guide UG1092 v1.1, PDF (USB and Pmod power limits)](https://uk.farnell.com/site/binaries/content/assets/common/product-family-documents/amd-kria-k24-k26/kria-kr260-robotics-starter-kit-user-guide.pdf)
- [RPLIDAR S2 datasheet (power, motor control)](https://files.seeedstudio.com/products/114992738/document/SLAMTEC_rplidar_datasheet_S2M1_v1.0_en.pdf)
- [RPLIDAR S2 kit user manual (USB adapter, USB-DC power cord)](https://bucket-download.slamtec.com/1d6d308d60e27da6c910177b06370a1fe901defd/SLAMTEC_rplidarkit_usermanual_S2_v1.1_en.pdf)
- [Ping2 sonar product page (current draw)](https://bluerobotics.com/store/sonars/echosounders/ping-sonar-r2-rp/)
- [Luxonis USB deployment guide (OAK power draw)](https://docs.luxonis.com/hardware/platform/deploy/usb-deployment-guide)
- [Luxonis OAK Y-adapter](https://shop.luxonis.com/products/oak-y-adapter)
- [StarTech ST4200USBM manual](https://sgcdn.startech.com/005329/media/sets/ST4200USBM_Manual/ST4200USBM.pdf)
- [Blue Sea 1045 dual USB charger](https://www.bluesea.com/products/1045/12_24V_DC_Dual_USB_Charger_4.8A_with_Intelligent_Device_Recognition)
- [Marvelmind operating manual (georeferencing, paired beacons, NMEA output, accuracy)](https://marvelmind.com/pics/marvelmind_navigation_system_manual.pdf)
- [Marvelmind MMSW0002: $GPHDT heading license](https://marvelmind.com/product/mmsw0002/)
- [Marvelmind Starter Set Super-MP-3D](https://marvelmind.com/product/starter-set-super-mp-3d/)
- [marvelmind_ros2 on ROS Index](https://index.ros.org/p/marvelmind_ros2/)
- [Blue Robotics: installing the Ping on the BlueROV2 (cable pins, adapter, wire colors)](https://bluerobotics.com/learn/ping-installation-guide-for-the-bluerov2/)
- [Blue Robotics connector standard (JST-GH serial pinout)](https://bluerobotics.com/learn/wl-connector-standard/)
- [BLUART USB to TTL serial and RS485 adapter](https://bluerobotics.com/store/comm-control-power/tether-interface/bluart-r1-rp/)
- [bluerobotics-ping Python library](https://pypi.org/project/bluerobotics-ping/)
- [BLHeli_S manual, hosted by Blue Robotics (arming, throttle calibration)](https://bluerobotics.com/wp-content/uploads/2018/10/BLHeli_S-manual-SiLabs-Rev16.x.pdf)
- [Luxonis OAK-D S2 (IMU)](https://docs.luxonis.com/hardware/products/OAK-D%20S2)
- [Blue Sea 5025 listing with terminal sizes (#8-32 circuits, #10-32 studs)](https://mooreparts.com/blue-sea-6-circuit-atc-fuse-box-with-cover-8-32-screw-terminals)
- [morrownr/7612u: MT7612U USB WiFi on Linux (in-kernel, AP mode)](https://github.com/morrownr/7612u)
- [NetworkManager nmcli examples (hotspot)](https://networkmanager.dev/docs/api/1.44.4/nmcli-examples.html)
- [GL.iNet Mango (GL-MT300N-V2) travel router](https://www.gl-inet.com/en-us/products/gl-mt300n-v2)
