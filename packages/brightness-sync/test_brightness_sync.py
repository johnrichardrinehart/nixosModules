#!/usr/bin/env python3

import unittest

from brightness_sync import ddc_target, parse_detect, parse_level, parse_vcp


class ParseTests(unittest.TestCase):
    def test_level_rounds_to_brightness_notify_grid(self) -> None:
        self.assertEqual(parse_level("intel_backlight,backlight,3840,4%,96000\n"), 4)
        self.assertEqual(parse_level("intel_backlight,backlight,4800,5%,96000\n"), 4)
        self.assertEqual(parse_level("intel_backlight,backlight,5760,6%,96000\n"), 8)
        self.assertEqual(parse_level("intel_backlight,backlight,0,0%,96000\n"), 0)
        self.assertEqual(
            parse_level("intel_backlight,backlight,96000,100%,96000\n"), 100
        )

    def test_detect_skips_laptop_and_phantom_displays(self) -> None:
        output = """Invalid display
   I2C bus:          /dev/i2c-9
   DRM connector:    card1-eDP-1
   Monitor:          BOE::

Display 1
   I2C bus:          /dev/i2c-18
   DRM connector:    card1-DP-5
   Monitor:          DEL:DELL U3225QE:ABC

Phantom display
   I2C bus:          /dev/i2c-10
   DRM connector:    card1-DP-1
   Monitor:          DEL:DELL U3225QE:ABC

Display 2
   I2C bus:          /dev/i2c-19
   DRM connector:    card1-DP-6
   Monitor:          DEL:DELL U2520D:DEF
"""
        self.assertEqual(parse_detect(output), [18, 19])

    def test_vcp_brightness_is_scaled_to_monitor_maximum(self) -> None:
        self.assertEqual(parse_vcp("VCP 10 C 75 100\n"), (75, 100))
        self.assertEqual(ddc_target(36, 100), 36)
        self.assertEqual(ddc_target(36, 255), 92)
        with self.assertRaises(ValueError):
            parse_vcp("VCP 10 ERR\n")


if __name__ == "__main__":
    unittest.main()
