# frozen_string_literal: true

require_relative 'helper'

# The hub layer, against an emulated hub on a pty.
#
# Real framing through the real exsys gem, so what is tested is the
# exchange rather than a stand-in for it: GP to read the port state, SP
# to write it back, and the protections that decide which ports may be
# in that word.
class TestHub < Minitest::Test
    include DevlistHelper

    DEVLIST = "reserved = [ 16 ]\nA1 { port = 1 }\nA2 { port = 2 }\nA3 { port = 3 }\n"

    def setup
        @hub = FakeHub.new(state: 0b0110)          # ports 2 and 3 on
        @cli = cli_for(DEVLIST, device: @hub.path)
    end

    def teardown
        @hub.close
        super
    end

    def usb(*argv) = TribeControl::CLI::USB.new(@cli).run(argv, force: false)

    def test_status_reads_the_real_port_state
        assert_equal [ 2, 3 ], @hub.ports_on
        assert_equal [ 2, 3 ], @cli.exsys.get(:on)
    end

    def test_on_names_every_port_outright
        usb('on')
        assert_equal (1..16).to_a, @hub.ports_on
    end

    def test_on_and_off_of_one_port
        usb('on', '1')
        assert_includes @hub.ports_on, 1
        usb('off', '1')
        refute_includes @hub.ports_on, 1
    end

    def test_a_bare_off_means_every_switchable_port_not_all_sixteen
        usb('off')
        assert_equal [ 16 ].select {|p| @hub.ports_on.include?(p) },
                     @hub.ports_on & [ 16 ]
        assert_empty @hub.ports_on & [ 1, 2, 3 ]
    end

    def test_a_reserved_port_is_refused_by_name
        usb('on')
        e = assert_raises(TribeControl::CLI::Error) { usb('off', '16') }
        assert_match(/refusing to power down port\(s\) 16/, e.message)
        assert_includes @hub.ports_on, 16, 'the reserved port was cut anyway'
    end

    def test_an_undeclared_port_is_protected_too
        usb('on')
        assert_raises(TribeControl::CLI::Error) { usb('off', '9') }
        assert_includes @hub.ports_on, 9
    end

    def test_toggle_inverts_only_what_it_is_given
        before = @hub.ports_on
        usb('toggle', '1')
        assert_equal before.include?(1), !@hub.ports_on.include?(1)
        assert_equal before.include?(2), @hub.ports_on.include?(2)
    end

    def test_set_takes_pairs
        usb('set', '1:on', '2:off')
        assert_includes @hub.ports_on, 1
        refute_includes @hub.ports_on, 2
    end

    # The read-modify-write is one session: exsys holds the line across
    # the GP and the SP so two processes cannot lose each other's work.
    def test_one_port_change_is_a_read_then_a_write
        @hub.log.clear
        usb('on', '1')
        assert_equal %w[GP], @hub.log.grep(/\AGP/)
        assert_equal 1, @hub.log.grep(/\ASP/).size
    end

    # Only SP, never FP or WP: nothing this tool does survives a hub
    # power cycle.
    def test_nothing_is_written_to_the_hub_flash
        usb('on') ; usb('off', '1') ; usb('toggle', '2') ; usb('set', '3:on')
        assert_empty @hub.log.grep(/\A(?:FP|WP)/)
    end

    def test_a_wrong_password_is_reported_not_swallowed
        hub = FakeHub.new(state: 0, password: 'other')
        cli = cli_for(DEVLIST, '-p', 'pass', device: hub.path)
        assert_raises(ExSYS::ManagedUSB::Error) {
            TribeControl::CLI::USB.new(cli).run([ 'on', '1' ], force: false) }
    ensure
        hub&.close
    end
end
