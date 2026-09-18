# frozen_string_literal: true

require 'minitest/mock'

require_relative 'helper'
require_relative 'support/fake_usbconfig'
require_relative '../lib/tribble-control/hub/usb'

# Which KIND of hub a devlist describes, and the settings that go with
# each kind.
#
# 'hub =' picks the backend and 'switch =' says what a usb hub's
# switch does; -p is the ExSYS hub's password.  What is asserted here
# is that a setting for the wrong kind is refused at load rather than
# dropped -- a line that changes nothing is a line somebody will trust
# -- and that the default is the ExSYS hub, so every devlist written
# before the key existed still means what it meant.
class TestHubKind < Minitest::Test
    include DevlistHelper

    DEVLIST = "A1 { port = 1 }\n"

    def test_the_default_kind_is_the_exsys_hub
        cli = cli_for(DEVLIST)
        assert_instance_of TribbleControl::Hub::ExSYS, cli.hub
    end

    def test_the_devlist_may_say_exsys_outright
        cli = cli_for("hub = exsys\n#{DEVLIST}")
        assert_instance_of TribbleControl::Hub::ExSYS, cli.hub
    end

    def test_an_unknown_kind_is_refused_at_load
        assert_match(/hub must be one of exsys, usb/,
                     refusal_for("hub = fnord\n#{DEVLIST}"))
    end

    def test_an_unknown_switch_is_refused_at_load
        assert_match(/switch must be one of link, vbus/,
                     refusal_for("switch = maybe\n#{DEVLIST}"))
    end

    # The ExSYS hub always cuts power, so a switch line on it would be
    # a line that changes nothing.
    def test_a_switch_on_the_exsys_hub_is_refused_not_ignored
        assert_match(/switch = vbus applies to hub = usb/,
                     refusal_for("switch = vbus\n#{DEVLIST}"))
    end

    def test_a_password_on_a_usb_hub_is_refused
        assert_match(/a usb hub has no password/,
                     refusal_for("hub = usb\n#{DEVLIST}", '-p', 'secret'))
    end

    def test_the_option_overrides_the_devlist
        assert_match(/a usb hub has no password/,
                     refusal_for("hub = exsys\n#{DEVLIST}",
                                 '--hub', 'usb', '-p', 'secret'))
    end

    def test_the_option_takes_only_known_kinds
        assert_raises(OptionParser::InvalidArgument) {
            cli_for(DEVLIST, '--hub', 'fnord')
        }
    end

    ### hub = usb, end to end against a fake host #######################

    USB = TribbleControl::Hub::USB

    # One root hub and one TUSB8041 with a board on its port 2.
    USB_HOST = [ { :unit => 0, :parent => 'usbus1' },
                 { :unit => 4, :device => 'ugen1.4', :parent => 'uhub0',
                   :bus => 1, :port => 1, :serial => 'AC0528515619',
                   :present => [ 2 ] } ].freeze

    # The backend's runner and its host check are the two things that
    # are about this machine; both are stood in for.  The fake is
    # callable, and minitest CALLS a callable stub value in place of
    # the method, so it goes in wrapped: runner must return the fake,
    # not run it.
    def on_usb_host(fake, &)
        USB.stub(:freebsd?, true) { USB.stub(:runner, -> { fake }, &) }
    end

    def test_a_usb_hub_is_reached_through_the_devlist
        fake = FakeUsbconfig.new(USB_HOST.map(&:dup))
        on_usb_host(fake) do
            cli = cli_for("hub = usb\ndevice = 'AC0528515619'\nA1 { port = 2 }\n",
                          device: nil)
            assert_instance_of USB, cli.hub
            assert_equal 'ugen1.4', cli.device
            refute cli.hub.vbus?, 'link is the default'
            TribbleControl::CLI::USB.new(cli).run([ 'off', '2' ], force: false)
            refute fake.powered('ugen1.4')[2], 'the port was not cut'
            assert fake.powered('ugen1.4')[1], 'another port was cut'
            assert_match(/ugen1\.4 cuts the link, not the power/, log_of(cli))
        end
    end

    def test_switch_vbus_reaches_the_usb_hub_and_quietens_the_warning
        fake = FakeUsbconfig.new(USB_HOST.map(&:dup))
        on_usb_host(fake) do
            cli = cli_for("hub = usb\nswitch = vbus\ndevice = '1-1'\nA1 { port = 2 }\n",
                          device: nil)
            assert cli.hub.vbus?
            TribbleControl::CLI::USB.new(cli).run([ 'off', '2' ], force: false)
            refute_match(/cuts the link/, log_of(cli))
        end
    end

    def test_a_usb_hub_port_out_of_range_is_refused_by_the_devlist_check
        fake = FakeUsbconfig.new(USB_HOST.map(&:dup))
        on_usb_host(fake) do
            cli = cli_for("hub = usb\ndevice = 'AC0528515619'\nA1 { port = 7 }\n",
                          device: nil)
            e = assert_raises(TribbleControl::CLI::Error) {
                    TribbleControl::CLI::USB.new(cli).run([ 'off', 'A1' ], force: true) }
            assert_match(/port out of range \(7\)/, e.message)
        end
    end
end
