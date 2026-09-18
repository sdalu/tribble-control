# frozen_string_literal: true

require_relative 'helper'

# What a hub that only cuts the link changes, and what it does not.
#
# Powering down still works on every path -- the board vanishes from
# the host either way -- so what is asserted is the one line that says
# the board kept its power, and the one step that is skipped because
# it would achieve nothing: the after-flash power cycle.
class TestSwitch < Minitest::Test
    include DevlistHelper

    # Four ports, every switch recorded, and a switch that cuts the
    # link only.
    class LinkHub < TribbleControl::Hub
        attr_reader :log

        def initialize
            super
            @log = []
        end

        def ports = [ 1, 2, 3, 4 ]
        def state = ports.to_h {|p| [ p, true ] }
        def on(*list)  = @log << [ :on,  selection(list) ]
        def off(*list) = @log << [ :off, selection(list) ]
        def vbus? = false
        def to_s  = 'ugen9.9'
    end

    DEVLIST = "A1 { port = 1, serial = 'abc' }\nA2 { port = 2 }\n"

    # The CLI parses against a pty-less ExSYS line and is then handed
    # the link-only hub, which is what a devlist saying hub = usb,
    # switch = link would have given it.
    def cli_with_link_hub(*argv, **kws)
        cli_for(DEVLIST, *argv, **kws).tap {|cli|
            cli.instance_variable_set(:@hub, LinkHub.new)
        }
    end

    def test_usb_off_switches_and_says_the_boards_stay_powered
        cli = cli_with_link_hub
        TribbleControl::CLI::USB.new(cli).run([ 'off', '1' ], force: false)
        assert_equal [ [ :off, [ 1 ] ] ], cli.hub.log
        assert_match(/ugen9\.9 cuts the link, not the power: .*port\(s\) 1 stay powered/,
                     log_of(cli))
    end

    def test_usb_set_names_the_ports_it_took_off
        cli = cli_with_link_hub
        TribbleControl::CLI::USB.new(cli).run([ 'set', '1:on', '2:off' ],
                                              force: false, default: nil)
        assert_match(/port\(s\) 2 stay powered/, log_of(cli))
    end

    def test_the_after_flash_cycle_is_skipped_and_said
        cli = cli_with_link_hub('-W', '0', command: 'flash')
        cli.stub(:openocd, true) do
            ok = TribbleControl::CLI::Flash.new(cli)
                                           .run([ 'fw.hex', 'A1' ],
                                                :'power-cycle' => true,
                                                :method => 'serial',
                                                :'warm-up' => 0, :force => false)
            assert ok
        end
        assert_equal [ [ :on, [ 1 ] ] ], cli.hub.log, 'the cycle was issued anyway'
        assert_match(/A1: NOT power-cycling, ugen9\.9 cuts the link/, log_of(cli))
    end

    # The ExSYS hub cuts power, so nothing is said.
    def test_a_hub_that_cuts_power_says_nothing_extra
        hub = FakeHub.new(state: 0b1111)
        cli = cli_for(DEVLIST, device: hub.path)
        TribbleControl::CLI::USB.new(cli).run([ 'off', '1' ], force: false)
        refute_match(/cuts the link/, log_of(cli))
    ensure
        hub&.close
    end
end
