#!/usr/bin/env python3
"""ROS 2 (Humble) node for the Blue Robotics Ping2 echosounder on the KR260.

Runs as a plain script; no colcon workspace or extra libraries (pyserial ships with Ubuntu):
    python3 ~/sonar/ping2_node.py --ros-args --params-file ~/sonar/ping2.yaml

The node talks the Ping protocol directly. The sonar streams one 'profile' message per ping,
so every ping is published exactly once. (On Ping2 firmware 1.0 the ping counter in the
'distance' reply stays at 0, so polling for distance cannot tell new pings from old ones.)
A background thread sleeps in a blocking serial read and wakes only when the sonar sends
something, which keeps CPU use low on the Cortex-A53.

The sonar forgets its settings at every power-up. The node sends the settings from ping2.yaml
whenever the sonar connects, restarts, stops streaming, or is found with other settings.

Publishes
    /sonar/range        sensor_msgs/Range   distance to the strongest echo, m (+inf below min_confidence)
    /sonar/confidence   std_msgs/UInt8      the sonar's confidence in that distance, 0-100 %

Change a setting while it runs (lasts until the node restarts):
    ros2 param set /ping2 water_temp_c 11.5
"""

import math
import struct
import threading
import time

import rclpy
from rclpy.node import Node
from rcl_interfaces.msg import ParameterDescriptor, SetParametersResult
from sensor_msgs.msg import Range
from std_msgs.msg import UInt8
import serial

try:
    from rclpy.executors import ExternalShutdownException
except ImportError:  # older rclpy
    class ExternalShutdownException(Exception):
        pass

# Ping protocol message ids (https://docs.bluerobotics.com/ping-protocol/)
ACK, NACK, GENERAL_REQUEST = 1, 2, 6
SET_RANGE, SET_SPEED_OF_SOUND, SET_MODE_AUTO = 1001, 1002, 1003
SET_PING_INTERVAL, SET_GAIN_SETTING, SET_PING_ENABLE = 1004, 1005, 1006
SPEED_OF_SOUND, GENERAL_INFO, PROFILE = 1203, 1210, 1300
CONTINUOUS_START, CONTINUOUS_STOP = 1400, 1401

BAUD = 115200
READ_TIMEOUT_S = 0.2     # longest a serial read waits for the first byte
BURST_GAP_S = 0.005      # a gap this long ends a read (one message burst per wake-up)
SEND_GAP_S = 0.01        # spacing between messages sent to the sonar
RETRY_S = 2.0            # wait between attempts to open the port
STALL_S = 3.0            # no ping for this long: send the settings and stream request again
DEAD_S = 10.0            # no bytes at all for this long: close and reopen the port
CHECK_S = 30.0           # how often to confirm the sonar still has our settings
FOV_RAD = math.radians(25.0)
MIN_RANGE_M, MAX_RANGE_M = 0.3, 100.0

DEFAULTS = {
    'device': '/dev/ttyUSB0',
    'frame_id': 'sonar_link',
    'water_temp_c': 15.0,
    'speed_of_sound_mps': 0.0,
    'ping_interval_ms': 100,
    'mode_auto': True,
    'scan_start_m': 0.0,
    'scan_length_m': 10.0,
    'gain_setting': 3,
    'min_confidence': 0,
}
SONAR_SETTINGS = ('water_temp_c', 'speed_of_sound_mps', 'ping_interval_ms', 'mode_auto',
                  'scan_start_m', 'scan_length_m', 'gain_setting')
LIMITS = {'water_temp_c': (0, 40), 'ping_interval_ms': (0, 10000), 'scan_start_m': (0, 100),
          'scan_length_m': (1, 100), 'gain_setting': (0, 6), 'min_confidence': (0, 100)}
WHOLE_NUMBERS = ('ping_interval_ms', 'gain_setting', 'min_confidence')


def fresh_water_sound_speed(temp_c):
    """Speed of sound in pure water at 1 atm, m/s (Marczak 1997, valid 0-95 C)."""
    t = temp_c
    return (1402.385 + 5.038813 * t - 5.799136e-2 * t ** 2 + 3.287156e-4 * t ** 3
            - 1.398845e-6 * t ** 4 + 2.787860e-9 * t ** 5)


def check_value(name, value):
    """Return (clean value, None) or (None, reason it is not allowed)."""
    if name in ('device', 'frame_id'):
        text = str(value).strip()
        return (text, None) if text else (None, 'must not be empty')
    if name == 'mode_auto':
        return (value, None) if isinstance(value, bool) else (None, 'must be true or false')
    if isinstance(value, bool):
        return None, 'must be a number'
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None, 'must be a number'
    if name == 'speed_of_sound_mps':
        if number == 0 or 1300 <= number <= 1700:
            return number, None
        return None, 'must be 0 (use water_temp_c) or 1300-1700'
    low, high = LIMITS[name]
    if not low <= number <= high:
        return None, 'must be %g-%g' % (low, high)
    if name in WHOLE_NUMBERS:
        if number != int(number):
            return None, 'must be a whole number'
        return int(number), None
    return number, None


def frame(msg_id, payload=b''):
    """Wrap a payload in a Ping protocol frame."""
    body = b'BR' + struct.pack('<HHBB', len(payload), msg_id, 0, 0) + payload
    return body + struct.pack('<H', sum(body) & 0xFFFF)


class PingParser:
    """Splits a byte stream into (message id, payload) pairs; drops corrupt frames and resyncs."""

    MAX_PAYLOAD = 1024

    def __init__(self):
        self.buf = bytearray()
        self.bad_frames = 0

    def feed(self, data):
        self.buf += data
        messages = []
        while True:
            start = self.buf.find(b'BR')
            if start < 0:
                keep = 1 if self.buf[-1:] == b'B' else 0
                del self.buf[:len(self.buf) - keep]
                return messages
            del self.buf[:start]
            if len(self.buf) < 8:
                return messages
            length, msg_id = struct.unpack_from('<HH', self.buf, 2)
            if length > self.MAX_PAYLOAD:
                del self.buf[:2]
                continue
            if len(self.buf) < 10 + length:
                return messages
            (checksum,) = struct.unpack_from('<H', self.buf, 8 + length)
            if sum(self.buf[:8 + length]) & 0xFFFF != checksum:
                self.bad_frames += 1
                del self.buf[:2]
                continue
            messages.append((msg_id, bytes(self.buf[8:8 + length])))
            del self.buf[:10 + length]


class Ping2Node(Node):

    def __init__(self, start_thread=True):
        super().__init__('ping2')
        self._cfg = {}
        for name, default in DEFAULTS.items():
            numeric = not isinstance(default, (bool, str))
            # dynamic typing lets the YAML or `ros2 param set` use 15 as well as 15.0
            descriptor = ParameterDescriptor(dynamic_typing=numeric)
            value = self.declare_parameter(name, default, descriptor).value
            clean, error = check_value(name, value)
            if error:
                self.get_logger().error('%s %s; using %r instead' % (name, error, default))
                clean = default
            self._cfg[name] = clean
        self.add_on_set_parameters_callback(self._on_set_parameters)

        self._pub_range = self.create_publisher(Range, 'sonar/range', 10)
        self._pub_conf = self.create_publisher(UInt8, 'sonar/confidence', 10)

        # Everything below is used only by the reader thread; the parameter callback just
        # sets the two *_request flags.
        self._port = None
        self._parser = PingParser()
        self._queue = []           # (msg id, payload, description) to send
        self._pending = {}         # msg id -> description, sent and waiting for the ACK
        self._applied = []         # descriptions of the settings being applied
        self._nacked = set()       # set-message ids the sonar rejected (not retried until changed)
        self._want_sos_mm = 0
        self._sent_all_at = None
        self._ack_warned = False
        self._reported = True      # 'settings applied' already logged for this round
        self._apply_request = None
        self._reopen_request = False
        self._last_try = None
        self._open_error, self._open_error_at = None, 0.0
        self._last_rx = self._last_ping = self._last_check = 0.0
        self._last_pn = None
        self._first_ping = True

        self._stop = threading.Event()
        self._thread = None
        if start_thread:
            self._thread = threading.Thread(target=self._run, name='ping2_reader', daemon=True)
            self._thread.start()

    # ------------------------------------------------------------- thread
    def _run(self):
        while not self._stop.is_set():
            try:
                self._step()
            except Exception as exc:   # keep the reader alive whatever happens
                if self._stop.is_set() or not rclpy.ok():
                    break              # shutting down
                self.get_logger().error('Reader error: %r' % exc, throttle_duration_sec=10.0)
                time.sleep(1.0)

    def _step(self):
        now = time.monotonic()
        if self._reopen_request:
            self._reopen_request = False
            self._close('device parameter changed')
        if self._port is None:
            if self._last_try is None or now - self._last_try >= RETRY_S:
                self._open(now)
            if self._port is None:
                time.sleep(READ_TIMEOUT_S)
                return
        if self._apply_request:
            reason, self._apply_request = self._apply_request, None
            self._apply(reason)
        try:
            while self._queue:
                msg_id, payload, description = self._queue.pop(0)
                self._port.write(frame(msg_id, payload))
                if description:
                    self._pending[msg_id] = description
                if not self._queue:
                    self._sent_all_at = time.monotonic()
                time.sleep(SEND_GAP_S)
            data = self._port.read(4096)   # sleeps until the sonar sends something
        except (serial.SerialException, OSError) as exc:
            self._close('lost the adapter (%s)' % exc)
            return
        now = time.monotonic()
        if data:
            self._last_rx = now
            stamp = self.get_clock().now().to_msg()
            for msg_id, payload in self._parser.feed(data):
                self._handle(msg_id, payload, stamp, now)
        self._watchdog(now)

    # ----------------------------------------------------------------- port
    def _open(self, now):
        self._last_try = now
        device = self._cfg['device']
        try:
            port = serial.Serial(device, BAUD, timeout=READ_TIMEOUT_S, write_timeout=0.5,
                                 inter_byte_timeout=BURST_GAP_S, exclusive=True)
        except (serial.SerialException, OSError, ValueError) as exc:
            # say it right away when the reason changes, otherwise every 30 s
            if str(exc) != self._open_error or now - self._open_error_at >= 30.0:
                self._open_error, self._open_error_at = str(exc), now
                self.get_logger().warning('Waiting for the sonar on %s (%s)' % (device, exc))
            return
        self._open_error = None
        try:
            port.set_low_latency_mode(True)   # FTDI latency timer 16 ms -> 1 ms
        except Exception:
            pass
        port.reset_input_buffer()
        self._port = port
        self._parser = PingParser()
        self._last_rx = self._last_ping = self._last_check = now
        self._last_pn = None
        self._first_ping = True
        self._nacked = set()
        self.get_logger().info('Opened %s' % device)
        self._apply('sonar connected')

    def _close(self, reason, quiet=False):
        if self._port is not None:
            if quiet:   # repeats about every DEAD_S while the sonar has no power
                self.get_logger().warning('Reopening the port: %s' % reason, throttle_duration_sec=30.0)
            else:
                self.get_logger().error('Sonar link closed: %s. Retrying every %.0f s.' % (reason, RETRY_S))
            try:
                self._port.close()
            except Exception:
                pass
        self._port = None
        self._queue, self._pending = [], {}
        self._last_try = time.monotonic()

    def shutdown(self):
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=2.0)
        if self._port is not None:
            try:
                self._port.write(frame(CONTINUOUS_STOP, struct.pack('<H', PROFILE)))
                self._port.close()
            except Exception:
                pass
            self._port = None

    # ------------------------------------------------------------- settings
    def _apply(self, reason, quiet=False):
        c = self._cfg
        if c['speed_of_sound_mps'] > 0:
            sos, note = c['speed_of_sound_mps'], ''
        else:
            sos = fresh_water_sound_speed(c['water_temp_c'])
            note = ' (fresh water, %.1f C)' % c['water_temp_c']
        self._want_sos_mm = int(round(sos * 1000))
        queue = [(SET_PING_ENABLE, struct.pack('<B', 1), 'pinging on'),
                 (SET_MODE_AUTO, struct.pack('<B', 1 if c['mode_auto'] else 0),
                  'auto range/gain' if c['mode_auto'] else 'manual range/gain')]
        if not c['mode_auto']:
            start_mm = int(round(c['scan_start_m'] * 1000))
            length_mm = int(round(c['scan_length_m'] * 1000))
            queue.append((SET_RANGE, struct.pack('<II', start_mm, length_mm),
                          'range %.1f-%.1f m' % (start_mm / 1000.0, (start_mm + length_mm) / 1000.0)))
            queue.append((SET_GAIN_SETTING, struct.pack('<B', c['gain_setting']),
                          'gain %d' % c['gain_setting']))
        if c['ping_interval_ms'] > 0:
            queue.append((SET_PING_INTERVAL, struct.pack('<H', c['ping_interval_ms']),
                          'ping interval %d ms' % c['ping_interval_ms']))
        queue.append((SET_SPEED_OF_SOUND, struct.pack('<I', self._want_sos_mm),
                       'speed of sound %.1f m/s%s' % (sos, note)))
        queue.append((CONTINUOUS_START, struct.pack('<H', PROFILE), None))
        queue.append((GENERAL_REQUEST, struct.pack('<H', GENERAL_INFO), None))
        self._queue = queue
        self._pending = {}
        self._applied = [d for _, _, d in queue if d]
        self._sent_all_at = None
        self._ack_warned = False
        self._reported = False
        if quiet:   # repeats every STALL_S while the sonar is silent
            self.get_logger().warning('No pings from the sonar; re-sending settings (%s)' % reason,
                                      throttle_duration_sec=30.0)
        else:
            self.get_logger().info('Sending sonar settings (%s)' % reason)

    def _on_set_parameters(self, params):
        updates = {}
        for p in params:
            if p.name not in DEFAULTS:
                continue
            clean, error = check_value(p.name, p.value)
            if error:
                return SetParametersResult(successful=False, reason='%s %s' % (p.name, error))
            updates[p.name] = clean
        self._cfg.update(updates)
        self._nacked.clear()
        if 'device' in updates:
            self._reopen_request = True
        elif any(n in SONAR_SETTINGS for n in updates):
            self._apply_request = 'parameter changed'
        return SetParametersResult(successful=True)

    # ------------------------------------------------------------- messages
    def _handle(self, msg_id, payload, stamp, now):
        if msg_id == PROFILE and len(payload) >= 26:
            distance, confidence, _, ping_number = struct.unpack_from('<IHHI', payload)
            self._last_ping = now
            if self._last_pn is not None and ping_number < self._last_pn:
                self._apply('the sonar restarted')
            self._last_pn = ping_number
            self._publish(stamp, distance / 1000.0, confidence)
            if self._first_ping:
                self._first_ping = False
                self.get_logger().info('Receiving pings: %.2f m at %d%% confidence'
                                       % (distance / 1000.0, confidence))
        elif msg_id == ACK and len(payload) >= 2:
            (acked,) = struct.unpack_from('<H', payload)
            if self._pending.pop(acked, None):
                self._settled()
        elif msg_id == NACK and len(payload) >= 2:
            (nacked,) = struct.unpack_from('<H', payload)
            reason = payload[2:].split(b'\0')[0].decode('ascii', 'replace') or 'no reason given'
            what = self._pending.pop(nacked, None)
            self._nacked.add(nacked)
            if what in self._applied:
                self._applied.remove(what)
            self.get_logger().warning('The sonar rejected %s: %s' % (what or 'message %d' % nacked, reason))
            self._settled()
        elif msg_id == GENERAL_INFO and len(payload) >= 10:
            fw_major, fw_minor, mv, interval, gain, auto = struct.unpack_from('<HHHHBB', payload)
            if not 4500 <= mv <= 5500:
                self.get_logger().warning('Sonar supply is %.2f V (spec 4.5-5.5 V)' % (mv / 1000.0),
                                          throttle_duration_sec=60.0)
            c, rejected = self._cfg, self._nacked
            if not self._queue and not self._pending and (
                    (auto != int(c['mode_auto']) and SET_MODE_AUTO not in rejected)
                    or (c['ping_interval_ms'] and interval != c['ping_interval_ms']
                        and SET_PING_INTERVAL not in rejected)
                    or (not c['mode_auto'] and gain != c['gain_setting']
                        and SET_GAIN_SETTING not in rejected)):
                self._apply('the sonar had different settings')
            self.get_logger().info('Ping2 firmware %d.%d, supply %.2f V' % (fw_major, fw_minor, mv / 1000.0),
                                   once=True)
        elif msg_id == SPEED_OF_SOUND and len(payload) >= 4:
            (sos_mm,) = struct.unpack_from('<I', payload)
            if (not self._queue and not self._pending and sos_mm != self._want_sos_mm
                    and SET_SPEED_OF_SOUND not in self._nacked):
                self._apply('the sonar had a different speed of sound')

    def _settled(self):
        """Log once per round when every setting has been answered."""
        if self._reported or self._pending or any(d for _, _, d in self._queue):
            return
        self._reported = True
        if self._applied:
            self.get_logger().info('Sonar settings applied: ' + ', '.join(self._applied))

    def _watchdog(self, now):
        if now - self._last_rx > DEAD_S:
            self._close('no data from the sonar for %.0f s' % DEAD_S, quiet=True)
            return
        if self._queue:
            return
        sent_ago = now - self._sent_all_at if self._sent_all_at is not None else 0.0
        if self._pending and sent_ago > 2.0 and not self._ack_warned:
            self._ack_warned = True
            self.get_logger().warning('No reply to: ' + ', '.join(self._pending.values()),
                                      throttle_duration_sec=30.0)
        if now - self._last_ping > STALL_S and sent_ago > STALL_S:
            self._last_ping = now
            self._apply('none for %.0f s' % STALL_S, quiet=True)
        elif now - self._last_check > CHECK_S:
            self._last_check = now
            self._queue = [(GENERAL_REQUEST, struct.pack('<H', GENERAL_INFO), None),
                           (GENERAL_REQUEST, struct.pack('<H', SPEED_OF_SOUND), None)]

    def _publish(self, stamp, distance, confidence):
        msg = Range()
        msg.header.stamp = stamp
        msg.header.frame_id = self._cfg['frame_id']
        msg.radiation_type = Range.ULTRASOUND
        msg.field_of_view = FOV_RAD
        msg.min_range = MIN_RANGE_M
        msg.max_range = MAX_RANGE_M
        msg.range = float(distance) if confidence >= self._cfg['min_confidence'] else math.inf
        self._pub_range.publish(msg)
        self._pub_conf.publish(UInt8(data=min(int(confidence), 255)))


def main():
    rclpy.init()
    node = Ping2Node()
    try:
        rclpy.spin(node)
    except (KeyboardInterrupt, ExternalShutdownException):
        pass
    finally:
        node.shutdown()
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()


if __name__ == '__main__':
    main()
