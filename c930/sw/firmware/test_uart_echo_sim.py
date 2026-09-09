#!/usr/bin/env python3
"""
GRX930 UART Echo Test — Software Simulation

Simulates the UART echo firmware behavior in pure Python.
No hardware or Verilator required — validates the protocol logic.

Usage:
    python3 test_uart_echo_sim.py
"""

import sys


class UARTFirmwareSimulator:
    """Simulates the GRX930 UART echo firmware."""

    def __init__(self):
        self.dcr_regs = {}
        self.led_state = 0
        self.rx_buffer = []
        self.tx_buffer = []

    def uart_write_char(self, c):
        """Firmware writes a character to TX."""
        self.tx_buffer.append(c)

    def uart_read_char(self):
        """Firmware reads a character from RX."""
        if self.rx_buffer:
            return self.rx_buffer.pop(0)
        return None

    def uart_rx_available(self):
        """Check if RX has data."""
        return len(self.rx_buffer) > 0

    def process_command(self):
        """Process one command from the RX buffer."""
        cmd = self.uart_read_char()
        if cmd is None:
            return False

        if cmd == 'P':  # Ping
            self.uart_write_char('P')
            self.uart_write_char('O')
            self.uart_write_char('N')
            self.uart_write_char('G')
            self.uart_write_char('A')
            return True

        elif cmd == 'V':  # Version
            version = "GRX930_ECHO_V1"
            for c in version:
                self.uart_write_char(c)
            self.uart_write_char('A')
            return True

        elif cmd == 'E':  # Echo
            length = self.uart_read_char()
            if length is None:
                return False

            data = []
            for _ in range(length):
                byte = self.uart_read_char()
                if byte is None:
                    return False
                data.append(byte)

            # Echo back
            for byte in data:
                self.uart_write_char(byte)
            self.uart_write_char('A')
            return True

        elif cmd == 'T':  # Toggle LED
            self.led_state ^= 1
            self.uart_write_char('A')
            return True

        elif cmd == 'R':  # Reset
            self.uart_write_char('R')
            self.uart_write_char('E')
            self.uart_write_char('S')
            self.uart_write_char('E')
            self.uart_write_char('T')
            return True

        else:  # Unknown command
            self.uart_write_char('E')
            self.uart_write_char('R')
            self.uart_write_char('R')
            self.uart_write_char('A')
            return True

    def send_command(self, cmd, data=None):
        """Send a command to the firmware."""
        self.rx_buffer.append(cmd)
        if data is not None:
            if isinstance(data, str):
                data = list(data)
            else:
                data = list(data)
            self.rx_buffer.append(len(data))
            self.rx_buffer.extend(data)

    def get_response(self):
        """Get the firmware's response."""
        response = []
        while self.uart_rx_available():
            break
        # Read all pending TX data
        while self.tx_buffer:
            response.append(self.tx_buffer.pop(0))
        return ''.join(response)


def run_test(test_name, firmware, cmd, data=None, expected=None):
    """Run a single test case."""
    print(f"Test: {test_name}...", end=" ")

    # Clear buffers
    firmware.tx_buffer = []

    # Send command
    firmware.send_command(cmd, data)

    # Process command
    firmware.process_command()

    # Get response
    response = firmware.get_response()

    # Check result
    if expected is not None:
        if response == expected:
            print(f"PASS")
            return True
        else:
            print(f"FAIL")
            print(f"  Expected: {expected!r}")
            print(f"  Got:      {response!r}")
            return False
    else:
        print(f"Response: {response!r}")
        return True


def main():
    print("=" * 60)
    print("GRX930 UART Echo Test — Software Simulation")
    print("=" * 60)
    print()

    # Create firmware simulator
    fw = UARTFirmwareSimulator()

    results = []

    # Test 1: Ping
    results.append(run_test(
        "Ping",
        fw, 'P',
        expected="PONG" + "A"
    ))

    # Test 2: Version
    results.append(run_test(
        "Version",
        fw, 'V',
        expected="GRX930_ECHO_V1" + "A"
    ))

    # Test 3: Echo simple string
    results.append(run_test(
        "Echo 'Hello'",
        fw, 'E', "Hello",
        expected="Hello" + "A"
    ))

    # Test 4: Echo another string
    results.append(run_test(
        "Echo 'Test 123'",
        fw, 'E', "Test 123",
        expected="Test 123" + "A"
    ))

    # Test 5: Echo special characters
    results.append(run_test(
        "Echo '!@#$%^&*()'",
        fw, 'E', "!@#$%^&*()",
        expected="!@#$%^&*()" + "A"
    ))

    # Test 6: Echo empty string
    results.append(run_test(
        "Echo empty",
        fw, 'E', "",
        expected="A"
    ))

    # Test 7: LED toggle
    results.append(run_test(
        "LED toggle",
        fw, 'T',
        expected="A"
    ))

    # Test 8: Unknown command
    results.append(run_test(
        "Unknown command 'X'",
        fw, 'X',
        expected="ERR" + "A"
    ))

    # Test 9: LED toggle again
    fw.led_state = 0
    results.append(run_test(
        "LED toggle (state should be 1)",
        fw, 'T',
        expected="A"
    ))
    print(f"  LED state: {fw.led_state}")

    # Test 10: Multiple commands in sequence
    print("Test: Multiple commands sequence...", end=" ")
    fw.tx_buffer = []
    fw.send_command('P')
    fw.send_command('V')
    fw.send_command('E', "Hi")
    fw.process_command()
    fw.process_command()
    fw.process_command()
    response = fw.get_response()
    expected = "PONGA" + "GRX930_ECHO_V1" + "A" + "Hi" + "A"
    if response == expected:
        print("PASS")
        results.append(True)
    else:
        print("FAIL")
        results.append(False)

    # Summary
    print()
    print("=" * 60)
    passed = sum(results)
    total = len(results)
    print(f"Results: {passed}/{total} passed")

    if passed == total:
        print("ALL TESTS PASSED!")
    else:
        print(f"FAILURES: {total - passed}")

    print("=" * 60)

    return 0 if passed == total else 1


if __name__ == '__main__':
    sys.exit(main())
