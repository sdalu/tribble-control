# frozen_string_literal: true

require_relative 'helper'

# Guards that each have one input that shows them: a second probe under
# --method power, a zero-padded port, an unreadable console, a missing
# firmware, --interactive with two boards.
class TestHunt < Minitest::Test
    include ConfigHelper

    # Sixteen ports that record what is done to them, and cut power.
    class RecordingHub < TribbleControl::Hub
        attr_reader :log

        def initialize
            super
            @log = []
        end

        def ports = (1..16).to_a
        def state = ports.to_h {|p| [ p, true ] }
        def on(*list)  = @log << [ :on,  selection(list) ]
        def off(*list) = @log << [ :off, selection(list) ]
        def to_s  = 'test-hub'
    end

    def cli_with(config, *argv, **kws)
        cli_for(config, *argv, **kws).tap {|cli|
            cli.instance_variable_set(:@hub, RecordingHub.new)
        }
    end

    # --method power, with a probe on a protected port still up: openocd
    # would choose between two adapters itself, so nothing is flashed.
    def test_power_refuses_when_another_probe_is_powered
        cli = cli_with("protect { nodes = [ P ] }\nA1 { port = 1 }\nP { port = 2 }",
                       '-W', '0', '-m', 'power', command: 'flash')
        cli.instance_variable_set(:@tty, nil)          # no 5 s countdown
        flashed = false
        two = { 'aaaa' => '/dev/ttyACM0', 'bbbb' => '/dev/ttyACM1' }
        TribbleControl::Platform.stub(:probe_consoles, two) do
            cli.stub(:sleep, nil) do
                e = assert_raises(TribbleControl::CLI::Error) {
                    cli.each_device([ 'A1' ]) { flashed = true }
                }
                assert_match(/2 probes are powered with only A1's port/, e.message)
            end
        end
        refute flashed, 'openocd ran with two probes in front of it'
        assert_equal [ :off, [ 1 ] ], cli.hub.log.last, 'A1 was not powered back down'
    end

    def test_power_proceeds_with_one_probe
        cli = cli_with("A1 { port = 1 }", '-W', '0', '-m', 'power', command: 'flash')
        cli.instance_variable_set(:@tty, nil)
        seen = []
        TribbleControl::Platform.stub(:probe_consoles, { 'aaaa' => '/dev/ttyACM0' }) do
            cli.stub(:sleep, nil) { cli.each_device([ 'A1' ]) {|n, **| seen << n } }
        end
        assert_equal %w[A1], seen
    end

    # Integer() reads a leading 0 as octal: '010' would be port 8.
    def test_ports_are_decimal_even_with_a_leading_zero
        cli = cli_with("A8 { port = 8 }\nA10 { port = 10 }\nprotect { ports = [ \"010\" ] }")
        assert_equal [ 10 ], cli.port_list([ '010' ])
        assert_equal [ 8 ],  cli.port_list([ '08' ])
        assert_equal [ 'A10', 10 ], cli.name_port('010')
        assert_equal [ 10 ], cli.instance_variable_get(:@protect_ports)
        assert_equal 12, cli_with("B { port = \"012\" }").port_of('B')
    end

    # A console that cannot be opened says ERROR, gives no SUMMARY,
    # and fails the run.
    def test_a_reader_that_cannot_open_says_so
        cli     = cli_with("A1 { port = 1 }", command: 'connect')
        connect = TribbleControl::CLI::Connect.new(cli)
        counter = TribbleControl::Tally.build('lines', 'A1')
        out, = capture_io { connect.read_console('A1', '/dev/does-not-exist', counter) }
        assert_match(/<A1> ERROR: .*Errno::ENOENT/, out)
        refute_match(/SUMMARY/, out)
        assert_equal %w[A1], connect.instance_variable_get(:@failed)
    end

    def test_a_tally_that_raises_says_so
        cli     = cli_with("A1 { port = 1 }", command: 'connect')
        connect = TribbleControl::CLI::Connect.new(cli)
        bad     = Object.new
        def bad.<<(_) = raise('tally broke')
        def bad.summary = 'should not print'
        serial = Object.new
        def serial.readline = "hello\n"
        UART.stub(:open, ->(*, &b) { b.call(serial) }) do
            out, = capture_io { connect.read_console('A1', '/dev/x', bad) }
            assert_match(/<A1> ERROR: tally broke/, out)
            refute_match(/should not print/, out)
        end
    end

    # A missing firmware is refused before a port is switched.
    def test_a_missing_firmware_is_refused_before_anything_is_switched
        cli = cli_with("A1 { port = 1 }", command: 'flash')
        flash = TribbleControl::CLI::Flash.new(cli)
        e = assert_raises(TribbleControl::CLI::Error) { flash.run([ 'nosuch.hex', 'A1' ]) }
        assert_match(/no readable firmware file 'nosuch.hex'/, e.message)
        e = assert_raises(TribbleControl::CLI::Error) { flash.run([]) }
        assert_match(/FIRMWARE missing/, e.message)
        assert_empty cli.hub.log
    end

    # --interactive with two boards is refused before anything runs.
    def test_interactive_with_two_boards_is_refused_first
        cli = cli_with("A1 { port = 1 }\nA2 { port = 2 }", command: 'connect')
        connect = TribbleControl::CLI::Connect.new(cli)
        e = assert_raises(TribbleControl::CLI::Error) {
            connect.run([ 'A1', 'A2' ], interactive: true, config: 'x', method: 'usb')
        }
        assert_match(/takes a single device \(2 selected\)/, e.message)
        assert_empty cli.hub.log
    end
end
