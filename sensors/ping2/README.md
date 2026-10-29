# Ping2 sonar on the KR260: ROS 2 node

The node is a plain Python script. There is no colcon workspace and nothing extra to download. It only needs what the board already has: ROS 2 Humble (`ros-humble-ros-base`) and `python3-serial`.

**Status (2026-10-29):** installed on the board in `~/sonar/` and started at boot by `ping2.service`.
- Measured: about 1.5 % of one CPU core and 54 MB of RAM.

| File (on the board: `~/sonar/`) | What it does |
|---|---|
| `ping2_node.py` | The node. Publishes `/sonar/range` (`sensor_msgs/Range`, metres) and `/sonar/confidence` (`std_msgs/UInt8`, 0–100 %), one message per ping. |
| `ping2.yaml` | The sonar settings. The node sends them every time the sonar powers up or reconnects. |
| `ping2.service` | Starts the node at boot and restarts it if it crashes. |

## Changing a setting
On the board:
```bash
nano ~/sonar/ping2.yaml          # edit, then Ctrl+O, Enter, Ctrl+X
sudo systemctl restart ping2     # the node re-reads the file and sends it to the sonar
journalctl -u ping2 -n 20        # check for "Sonar settings applied: ..."
```
To try a value without editing the file (it lasts until the next restart): `ros2 param set /ping2 water_temp_c 11.5`

| Setting | Default | Meaning |
|---|---|---|
| `device` | BLUART by-id path | `ls /dev/serial/by-id/` shows it. The name is the same on every USB port. |
| `water_temp_c` | 15.0 | Measured water temperature. The node turns it into the fresh-water speed of sound. |
| `speed_of_sound_mps` | 0.0 | Above 0, this value is used instead of `water_temp_c`. |
| `ping_interval_ms` | 100 | Shortest time between pings. 0 keeps the sonar's own 250 ms. Deep water pings slower anyway. |
| `mode_auto` | true | The sonar picks its range and gain itself. |
| `scan_start_m`, `scan_length_m`, `gain_setting` | 0, 10, 3 | Manual mode only (`mode_auto: false`). Length is 1–100 m; gain is 0–6. |
| `min_confidence` | 0 | `/sonar/range` reads +inf when confidence is below this. Confidence is always on `/sonar/confidence`. |

The node rejects bad values with a message, both from the file and from `ros2 param set`. It logs any value the sonar itself refuses.

## Everyday commands (on the board)
| Task | Command |
|---|---|
| Watch the node's log | `journalctl -u ping2 -f` (Ctrl+C stops watching, not the node) |
| See readings | `ros2 topic echo /sonar/range` |
| See the ping rate | `ros2 topic hz /sonar/range` |
| Record a survey | `ros2 bag record -o survey_$(date +%F_%H%M) /sonar/range /sonar/confidence` |
| Free the RAM the `ros2` command-line tools keep (about 50 MB) | `ros2 daemon stop` |
| Stop, start or restart the node | `sudo systemctl stop ping2`, `start ping2` or `restart ping2` |
| Turn autostart off or on | `sudo systemctl disable ping2` / `enable ping2` |

## Updating the files from the laptop
Edit the files in the repo (`sensors\ping2\sonar\`). Then, in PowerShell on the laptop:
```
scp -r "D:\School\Senior Design\KRIA-Based-Bathymetric-Surveying-ASV\sensors\ping2\sonar" ubuntu@10.1.9.104:~/
```
Then, on the board:
```bash
sudo systemctl restart ping2
```
If you changed `ping2.service` itself, also run:
```bash
sudo cp ~/sonar/ping2.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl restart ping2
```

## Setting up a fresh board
```bash
# after the scp above
sudo cp ~/sonar/ping2.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ping2
```
To run the node in the foreground instead, stop the service first, because only one program can hold the serial port:
```bash
sudo systemctl stop ping2
python3 ~/sonar/ping2_node.py --ros-args --params-file ~/sonar/ping2.yaml    # Ctrl+C to stop
```

## How it works, and why
- **Settings at power-up.** The sonar forgets every setting at power-off. The node sends `ping2.yaml` in four cases:
  - when it connects
  - when the pings stop for 3 s (the sonar was power-cycled)
  - when the sonar's ping counter jumps back
  - when a check every 30 s finds different values
- **Streaming instead of polling.** The node asks the sonar to stream one `profile` message per ping, so each ping is published exactly once.
- **Low CPU.** A reader thread sleeps in a blocking serial read and wakes only when data arrives. An earlier version that polled the port 50 times a second used 9 % of a core.
- **Ping2 firmware 1.0 quirks.** The board's sonar showed these on 2026-10-29:
  - The ping counter in the `distance` reply stays at 0.
  - In bluerobotics-ping 0.2.5, `get_speed_of_sound()` and `get_range()` fail on this firmware, although the sonar answers correctly.
  - For these reasons the node speaks the Ping protocol itself. It needs only `python3-serial`.
- **Readings in air are meaningless** (confidence near 0). Test the distance with the sonar face under water, at least 0.3 m from the bottom.
- **Logs:** journald keeps the node's output, and the service writes no log files under `~/.ros/log`.
- **Bench checks on the laptop:** use Ping Viewer with the BLUART plugged into the laptop.
