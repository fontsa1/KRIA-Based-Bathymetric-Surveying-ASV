#!/usr/bin/env python3
"""pwm_test.py - drive the two AXI Timer PWM outputs of the kr260_pwm design on the KR260.

Run ON THE BOARD as root, after `bash install_on_board.sh` has loaded the kr260_pwm app:
  sudo python3 pwm_test.py                          # 1 kHz: PWM_0 25 %, PWM_1 75 %, enable pin high
  sudo python3 pwm_test.py --freq 20000 --duty0 10 --duty1 90
  sudo python3 pwm_test.py --stop                   # stop both PWMs, enable pin low
  python3 pwm_test.py --dry-run                     # print the register values only (no hardware)

Design facts (from the Vivado block design):
  PWM_0  = axi_timer_1/pwm0 @ 0xA003_0000 -> package pin H12 (PMOD1, pin 1)
  PWM_1  = axi_timer_0/pwm0 @ 0xA002_0000 -> package pin E10 (PMOD1, next pin in the same row)
  enable = axi_gpio_0 bit 0 @ 0xA001_0000  -> package pin B10 (PMOD1, other row, beside pin 1)
  The timers are clocked by clk_wiz_0/clk_out4 = 300 MHz.
AXI Timer PWM mode (PG079), down-counting: period = (TLR0 + 2) clocks, high time = (TLR1 + 2) clocks.
"""
import argparse
import mmap
import os
import subprocess
import sys

APP = "kr260_pwm"
CLK_HZ = 300_000_000
TIMERS = (("PWM_0", 0xA0030000, "H12"), ("PWM_1", 0xA0020000, "E10"))
GPIO_BASE = 0xA0010000
SPAN = 0x10000
TCSR0, TLR0, TCR0, TCSR1, TLR1, TCR1 = 0x00, 0x04, 0x08, 0x10, 0x14, 0x18
UDT, GENT, ARHT, LOAD, ENT, PWMA, ENALL = 1 << 1, 1 << 2, 1 << 4, 1 << 5, 1 << 7, 1 << 9, 1 << 10
GPIO_DATA = 0x00


class Regs:
    """32-bit register window through /dev/mem."""

    def __init__(self, fd, base):
        self.base = base
        self.mm = mmap.mmap(fd, SPAN, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=base)
        self.words = memoryview(self.mm).cast("I")

    def rd(self, off):
        return self.words[off // 4]

    def wr(self, off, val):
        self.words[off // 4] = val & 0xFFFFFFFF

    def close(self):
        self.words.release()
        self.mm.close()


class DryRegs:
    def __init__(self, base):
        self.base, self.mem = base, {}

    def rd(self, off):
        return self.mem.get(off, 0)

    def wr(self, off, val):
        self.mem[off] = val & 0xFFFFFFFF
        print("    write 0x%08X <- 0x%08X" % (self.base + off, val & 0xFFFFFFFF))

    def close(self):
        pass


def app_is_active():
    """True if xmutil reports the kr260_pwm app in an active slot."""
    try:
        out = subprocess.run(["xmutil", "listapps"], capture_output=True, text=True, timeout=60).stdout
    except (OSError, subprocess.TimeoutExpired):
        return False, "(could not run xmutil)"
    for line in out.splitlines():
        tok = line.split()
        if tok and tok[0] == APP:
            return tok[-1].rstrip(",") != "-1", out
    return False, out


def pwm_start(r, period, high):
    r.wr(TCSR0, 0)
    r.wr(TCSR1, 0)                                         # stop both counters
    r.wr(TLR0, period - 2)                                 # period    = (TLR0 + 2) clocks
    r.wr(TLR1, high - 2)                                   # high time = (TLR1 + 2) clocks
    r.wr(TCSR0, LOAD)
    r.wr(TCSR1, LOAD)                                      # copy TLR -> counters
    r.wr(TCSR0, UDT | GENT | ARHT | PWMA)
    r.wr(TCSR1, UDT | GENT | ARHT | PWMA | ENT | ENALL)    # ENALL starts both counters together


def pwm_stop(r):
    r.wr(TCSR0, 0)
    r.wr(TCSR1, 0)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--freq", type=float, default=1000.0, help="PWM frequency in Hz (default 1000)")
    ap.add_argument("--duty0", type=float, default=25.0, help="PWM_0 duty cycle in %% (default 25)")
    ap.add_argument("--duty1", type=float, default=75.0, help="PWM_1 duty cycle in %% (default 75)")
    ap.add_argument("--no-enable", action="store_true", help="leave the enable pin (B10) low")
    ap.add_argument("--stop", action="store_true", help="stop both PWMs and drive the enable pin low")
    ap.add_argument("--clk-hz", type=float, default=CLK_HZ, help="timer clock in Hz (default 300e6)")
    ap.add_argument("--dry-run", action="store_true", help="print register writes, touch no hardware")
    ap.add_argument("--force", action="store_true", help="skip the 'is kr260_pwm loaded?' check")
    a = ap.parse_args()

    period = round(a.clk_hz / a.freq)
    if not a.stop:
        if not 4 <= period <= 0xFFFFFFFF:
            sys.exit("frequency out of range for a %.0f Hz timer clock" % a.clk_hz)
        for name, d in (("--duty0", a.duty0), ("--duty1", a.duty1)):
            if not 0 < d < 100:
                sys.exit("%s must be between 0 and 100 (exclusive)" % name)

    if a.dry_run:
        fd = None
    else:
        if os.geteuid() != 0:
            sys.exit("run it with sudo (it maps the PL registers through /dev/mem)")
        active, listing = app_is_active()
        if not active and not a.force:
            print(listing)
            sys.exit("the %s app is not loaded - run: bash install_on_board.sh   (refusing to touch PL "
                     "addresses that may not exist; --force overrides)" % APP)
        fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)

    def regs(base):
        return DryRegs(base) if fd is None else Regs(fd, base)

    gpio = regs(GPIO_BASE)
    try:
        for (name, base, pin), duty in zip(TIMERS, (a.duty0, a.duty1)):
            r = regs(base)
            try:
                if a.stop:
                    pwm_stop(r)
                    print("%s (pin %s): stopped" % (name, pin))
                    continue
                if fd is not None:
                    r.wr(TLR0, 0x12345678)                 # quick check that the AXI path answers
                    if r.rd(TLR0) != 0x12345678:
                        sys.exit("%s @ 0x%08X: register read-back failed - is the right bitstream loaded?"
                                 % (name, base))
                high = max(2, min(period - 1, round(period * duty / 100.0)))
                print("%s (pin %s) @ 0x%08X: %.3f Hz, %.2f %% duty (period %d clocks, high %d clocks)"
                      % (name, pin, base, a.clk_hz / period, 100.0 * high / period, period, high))
                pwm_start(r, period, high)
                if fd is not None:
                    c1, c2 = r.rd(TCR0), r.rd(TCR0)
                    print("    TCSR0=0x%03X TCSR1=0x%03X TLR0=%d TLR1=%d counter %s"
                          % (r.rd(TCSR0), r.rd(TCSR1), r.rd(TLR0), r.rd(TLR1),
                             "running" if c1 != c2 else "NOT changing (no clock?)"))
            finally:
                r.close()
        on = 0 if (a.stop or a.no_enable) else 1
        gpio.wr(GPIO_DATA, on)
        print("enable (pin B10): %s" % ("high" if on else "low"))
    finally:
        gpio.close()
        if fd is not None:
            os.close(fd)


if __name__ == "__main__":
    main()
