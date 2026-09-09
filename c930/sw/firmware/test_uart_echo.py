#!/usr/bin/env python3
"""
GRX930 UART Echo Test — Host Side

Sends test commands to the GRX930 UART echo firmware and validates responses.

Usage:
    python3 test_uart_echo.py --port /dev/ttyUSB0 --baud 115200

Commands:
    E <data>  — Echo test (sends data, expects it back)
    P         — Ping test (expects "PONG")
    V         — Version test (expects "GRX930_ECHO_V1")
"""

import serial
import argparse
import time
import sys


class GRX930EchoTest:
    def __init__(self, port, baud=115200, timeout=2.0):
        self.ser = serial.Serial(port, baud, timeout=timeout)
        time.sleep(0.1)  # Wait for connection to settle
        self.ser.reset_input_buffer()

    def send_command(self, cmd, data=None):
        """Send a command and return the response."""
        self.ser.write(cmd.encode())
        if data:
            if isinstance(data, str):
                data = data.encode()
            self.ser.write(bytes([len(data)]))
            self.ser.write(data)

    def read_response(self, expected_terminator='A'):
        """Read until we get the terminator character."""
        response = b''
        while True:
            byte = self.ser.read(1)
            if not byte:
                return None  # Timeout
            if byte == expected_terminator.encode():
                return response.decode('ascii', errors='replace')
            response += byte

    def test_ping(self):
        """Test ping command."""
        print("Test: Ping...", end=" ")
        self.send_command('P')
        response = self.read_response()
        if response == "PONG":
            print(f"PASS (got: {response})")
            return True
        else:
            print(f"FAIL (expected: PONG, got: {response})")
            return False

    def test_version(self):
        """Test version command."""
        print("Test: Version...", end=" ")
        self.send_command('V')
        response = self.read_response()
        if response == "GRX930_ECHO_V1":
            print(f"PASS (got: {response})")
            return True
        else:
            print(f"FAIL (expected: GRX930_ECHO_V1, got: {response})")
            return False

    def test_echo(self, data):
        """Test echo command."""
        print(f"Test: Echo '{data}'...", end=" ")
        self.send_command('E', data)
        response = self.read_response()
        if response == data:
            print(f"PASS")
            return True
        else:
            print(f"FAIL (expected: {data}, got: {response})")
            return False

    def test_echo_binary(self, data_len=16):
        """Test echo with binary data."""
        print(f"Test: Echo binary ({data_len} bytes)...", end=" ")
        data = bytes(range(data_len))
        self.send_command('E', data)
        response = self.ser.read(data_len + 1)  # data + ACK
        if len(response) == data_len + 1 and response[:data_len] == data:
            print("PASS")
            return True
        else:
            print(f"FAIL (got {len(response)} bytes)")
            return False

    def test_large_echo(self, size=128):
        """Test echo with large data."""
        print(f"Test: Large echo ({size} bytes)...", end=" ")
        data = bytes(range(256)) * (size // 256 + 1)
        data = data[:size]
        self.send_command('E', data)
        response = self.ser.read(size + 1)
        if len(response) == size + 1 and response[:size] == data:
            print("PASS")
            return True
        else:
            print(f"FAIL (got {len(response)} bytes)")
            return False

    def test_led_toggle(self):
        """Test LED toggle command."""
        print("Test: LED toggle...", end=" ")
        self.send_command('T')
        response = self.read_response()
        if response == "":
            print("PASS (LED toggled)")
            return True
        else:
            print(f"FAIL (unexpected response: {response})")
            return False

    def run_all_tests(self):
        """Run all tests and report results."""
        print("=" * 50)
        print("GRX930 UART Echo Test Suite")
        print("=" * 50)

        # Clear any pending data
        self.ser.reset_input_buffer()
        time.sleep(0.1)

        # Wait for boot message
        boot_msg = self.ser.read(100).decode('ascii', errors='replace')
        if "GRX930" in boot_msg:
            print(f"Boot detected: {boot_msg.strip()}")
        else:
            print(f"Boot message: {boot_msg.strip()}")

        results = []

        # Run tests
        results.append(self.test_ping())
        results.append(self.test_version())
        results.append(self.test_echo("Hello GRX930!"))
        results.append(self.test_echo("Test 123"))
        results.append(self.test_echo("Special chars: !@#$%^&*()"))
        results.append(self.test_echo_binary(16))
        results.append(self.test_echo_binary(64))
        results.append(self.test_large_echo(128))
        results.append(self.test_led_toggle())

        # Summary
        passed = sum(results)
        total = len(results)
        print("=" * 50)
        print(f"Results: {passed}/{total} passed")
        if passed == total:
            print("ALL TESTS PASSED!")
        else:
            print(f"FAILURES: {total - passed}")
        print("=" * 50)

        return passed == total


def main():
    parser = argparse.ArgumentParser(description='GRX930 UART Echo Test')
    parser.add_argument('--port', '-p', required=True,
                        help='Serial port (e.g., /dev/ttyUSB0, COM3)')
    parser.add_argument('--baud', '-b', type=int, default=115200,
                        help='Baud rate (default: 115200)')
    parser.add_argument('--timeout', '-t', type=float, default=2.0,
                        help='Serial timeout in seconds (default: 2.0)')
    parser.add_argument('--interactive', '-i', action='store_true',
                        help='Interactive mode — type commands manually')

    args = parser.parse_args()

    try:
        test = GRX930EchoTest(args.port, args.baud, args.timeout)
    except serial.SerialException as e:
        print(f"Error opening serial port: {e}")
        sys.exit(1)

    if args.interactive:
        print("Interactive mode — type commands:")
        print("  E <data>  — Echo test")
        print("  P         — Ping test")
        print("  V         — Version test")
        print("  Q         — Quit")
        print()

        while True:
            try:
                cmd = input("> ").strip()
                if not cmd:
                    continue
                if cmd.upper() == 'Q':
                    break
                if cmd.upper().startswith('E '):
                    test.test_echo(cmd[2:])
                elif cmd.upper() == 'P':
                    test.test_ping()
                elif cmd.upper() == 'V':
                    test.test_version()
                else:
                    print(f"Unknown command: {cmd}")
            except KeyboardInterrupt:
                print("\nExiting...")
                break
    else:
        success = test.run_all_tests()
        sys.exit(0 if success else 1)

    test.ser.close()


if __name__ == '__main__':
    main()
