# frozen_string_literal: true

require_relative 'helper'

# Which hub the tool drives.
#
# Three answers, in the order parse trusts them: -d, the devlist's own
# 'device' line, and the host.  The last one is a guess, and the point
# of these is that it is only made when there is nothing to guess
# between -- a host with two hubs on it must be told which.
#
# What the host has is the exsys gem's to report and is stubbed here:
# these assert the policy -- which candidate is taken, and what is said
# when none can be -- not the udevadm and sysctl reading behind it,
# which the gem tests against captured output of its own.
class TestDevice < Minitest::Test
    include DevlistHelper

    DEVLIST = "A1 { port = 1 }\n"

    # Two hubs and a USB-serial cable, in the order a host might well
    # enumerate them: the one wanted is not the first.  The third has
    # no serial, which is what leaves its USB path the only stable name
    # it has.
    HOST = [ { :device => '/dev/ttyUSB0', :serial => 'A50285BI',
               :usb_path => '1-1.2.4.4' },
             { :device => '/dev/ttyUSB1', :serial => 'AL03GD7X',
               :usb_path => '1-1.3.4.4' },
             { :device => '/dev/ttyUSB2', :serial => nil,
               :usb_path => '1-2' } ].freeze

    # The same bench on a host that cannot place anything in the USB
    # tree.  Both platforms do report a path -- Linux states it, and
    # FreeBSD's is walked out of its sysctl tree -- but a walk that
    # cannot reach a root hub answers nil rather than guess, and a
    # devlist naming a socket has then to be told so.
    PATHLESS_HOST = HOST.map {|c| c.merge(:usb_path => nil) }.freeze

    def with_host(ctrls = HOST, &)
        ExSYS::ManagedUSB.stub(:available, ctrls, &)
    end

    # The devlist names its hub, so -D alone selects a bench.
    def test_the_devlist_names_the_hub_by_serial
        with_host do
            cli = cli_for("device = AL03GD7X\n#{DEVLIST}", device: nil)
            assert_equal '/dev/ttyUSB1', cli.device
        end
    end

    # The third form: the socket rather than the adapter.
    def test_the_devlist_names_the_hub_by_usb_path
        with_host do
            cli = cli_for("device = 1-1.3.4.4\n#{DEVLIST}", device: nil)
            assert_equal '/dev/ttyUSB1', cli.device
        end
    end

    # The case the path exists for: an adapter with no serial to be
    # named by, whose only other name is the one that moves.
    def test_a_hub_with_no_serial_is_reachable_by_path
        with_host do
            cli = cli_for("device = 1-2\n#{DEVLIST}", device: nil)
            assert_equal '/dev/ttyUSB2', cli.device
        end
    end

    def test_the_command_line_takes_a_usb_path_too
        with_host do
            assert_equal '/dev/ttyUSB1',
                         cli_for(DEVLIST, device: '1-1.3.4.4').device
        end
    end

    # Naming a socket on a host that cannot say where anything is
    # plugged in is a different mistake from naming the wrong socket,
    # and "not found" would send the reader hunting for one.
    def test_a_usb_path_on_a_host_that_reports_none_says_why
        with_host(PATHLESS_HOST) do
            msg = refusal_for("device = 1-1.3.4.4\n#{DEVLIST}", device: nil)
            assert_match(/reports no USB path for any/, msg)
            assert_match(/Name the hub by the serial/,  msg)
            assert_match(/A50285BI/,                    msg)
        end
    end

    def test_an_unknown_usb_path_says_path_not_serial
        with_host do
            assert_match(/no FTDI 0403:6001 at USB path '9-9'/,
                         refusal_for("device = 9-9\n#{DEVLIST}", device: nil))
        end
    end

    # A '/' ANYWHERE in it means it is a serial line, used as given --
    # the same rule --openocd uses to tell a path from a name to look
    # up, and the reason a bare name is not a path (see below).
    def test_a_path_is_taken_as_written
        cli = cli_for("device = /dev/ttyUSB1\n#{DEVLIST}", device: nil)
        assert_equal '/dev/ttyUSB1', cli.device
    end

    # The by-id symlink is the useful absolute form on Linux, and it
    # is a path like any other: nothing here parses what is in it.
    def test_a_by_id_symlink_is_a_path
        line = '/dev/serial/by-id/usb-FTDI_FT232R_B0035JKX-if00-port0'
        assert_equal line, cli_for(DEVLIST, device: line).device
    end

    # Anywhere, not just at the front: a relative path is still a
    # path.  Neither a serial nor a USB path can contain a '/', so
    # this cannot take one for the other -- it only decides what a
    # socat pty in the working directory means.
    def test_a_relative_path_is_still_a_path
        with_host do
            assert_equal './hub', cli_for(DEVLIST, device: './hub').device
        end
    end

    # But a bare name is NOT a path, under that same rule: with no '/'
    # in it, it names a hub rather than a file.
    def test_a_bare_name_is_a_serial_not_a_filename
        with_host do
            assert_match(/no FTDI 0403:6001 with serial 'hub'/,
                         refusal_for(DEVLIST, device: 'hub'))
        end
    end

    # The one-off: a hub reached through some other node.
    def test_the_command_line_wins_over_the_devlist
        cli = cli_for("device = /dev/ttyUSB1\n#{DEVLIST}",
                      device: '/dev/ttyUSB9')
        assert_equal '/dev/ttyUSB9', cli.device
    end

    def test_the_command_line_takes_a_serial_too
        with_host do
            assert_equal '/dev/ttyUSB1',
                         cli_for(DEVLIST, device: 'AL03GD7X').device
        end
    end

    # A serial nothing on the host reports is a devlist deployed to the
    # wrong machine, or a hub that is not plugged in.  Both are worth a
    # message listing what IS there.
    def test_an_unknown_serial_lists_what_the_host_has
        with_host do
            msg = refusal_for("device = NOSUCH\n#{DEVLIST}", device: nil)
            assert_match(/no FTDI 0403:6001 with serial 'NOSUCH'/, msg)
            assert_match(%r{A50285BI on /dev/ttyUSB0},             msg)
            assert_match(%r{/dev/ttyUSB2, which reports no serial}, msg)
            # The path is in the listing too: for the one with no
            # serial it is the only name worth copying out.
            assert_match(/\[1-2\]/, msg)
        end
    end

    # 'device' is a setting, not a board: it must not turn into an
    # entry with no port, nor be selectable by name.
    def test_the_device_key_is_not_a_device
        cli = cli_for("device = /dev/ttyUSB1\n#{DEVLIST}", device: nil)
        assert_equal [ 'A1' ], cli.declared
        assert_equal [ 'A1' ], cli.devices
    end

    # UCL hands back an Integer for an unquoted all-digit serial, and
    # that used to be refused as "must name one hub" -- a poor answer
    # to a file that had named one.  J-Link serials are all digits, so
    # the shape is not hypothetical.
    def test_an_unquoted_all_digit_serial_is_a_serial
        with_host([ { :device => '/dev/ttyUSB4', :serial => '12345678',
                      :usb_path => '1-4' } ]) do
            cli = cli_for("device = 12345678\n#{DEVLIST}", device: nil)
            assert_equal '/dev/ttyUSB4', cli.device
        end
    end

    # But leading zeros cannot survive: UCL has parsed 00760040233 as
    # the number 760040233 before anything here sees it, so the lookup
    # is for a serial the file did not write.  It cannot be fixed at
    # this end -- what it CAN do is fail, and list what the host has,
    # rather than match something else.  Quote such a serial.
    def test_a_leading_zero_serial_loses_its_zeros_and_says_so
        with_host([ { :device => '/dev/ttyUSB4', :serial => '00760040233',
                      :usb_path => '1-4' } ]) do
            msg = refusal_for("device = 00760040233\n#{DEVLIST}", device: nil)
            assert_match(/with serial '760040233'/, msg)
            assert_match(%r{00760040233 on /dev/ttyUSB4}, msg)
        end
    end

    def test_quoting_it_keeps_the_zeros
        with_host([ { :device => '/dev/ttyUSB4', :serial => '00760040233',
                      :usb_path => '1-4' } ]) do
            cli = cli_for("device = '00760040233'\n#{DEVLIST}", device: nil)
            assert_equal '/dev/ttyUSB4', cli.device
        end
    end

    def test_a_device_block_is_refused
        assert_match(/must name one hub/,
                     refusal_for("device { line = /dev/ttyUSB1 }\n#{DEVLIST}",
                                 device: nil))
    end

    # One candidate is still auto-detected: a bench with one hub needs
    # no ceremony.
    def test_one_candidate_is_taken
        with_host([ HOST.first ]) do
            assert_equal '/dev/ttyUSB0', cli_for(DEVLIST, device: nil).device
        end
    end

    # The silent coin toss: three FTDI adapters, and the tool used to
    # take whichever the host enumerated first and switch its ports.
    def test_several_candidates_are_refused_by_name
        with_host do
            msg = refusal_for(DEVLIST, device: nil)
            assert_match(/3 FTDI 0403:6001 adapters/, msg)
            assert_match(%r{A50285BI on /dev/ttyUSB0}, msg)
            assert_match(%r{AL03GD7X on /dev/ttyUSB1}, msg)
            assert_match(/-d/,                         msg)
            assert_match(/'device =' line/,            msg)
        end
    end

    # ... and the devlist's line settles it without -d, which is the
    # whole point: the bench command says which device list, and that
    # is already the thing it has to say.
    def test_the_devlist_settles_an_ambiguous_host
        with_host do
            cli = cli_for("device = AL03GD7X\n#{DEVLIST}", device: nil)
            assert_equal '/dev/ttyUSB1', cli.device
        end
    end

    # The hub layer's own errors are ours to report, not to leak: the
    # gem raises for a host it cannot look on (no udevadm, a platform
    # with no reader) as well as for a hub that refuses a command.
    # exe/tribble-control's catch-all would have printed the same line,
    # but CLI.run is the documented place an exception becomes one.
    def test_a_hub_layer_error_becomes_a_line_not_a_backtrace
        raiser = proc {
            raise ExSYS::ManagedUSB::Error, 'cannot look for a hub: nope'
        }
        ExSYS::ManagedUSB.stub(:available, raiser) do
            out, err = capture_io do
                assert_raises(SystemExit) {
                    TribbleControl::CLI.run([ 'usb', 'status' ])
                }
            end
            assert_empty out
            # Prefixed with the program name, whatever is running it,
            # and one line -- no backtrace.
            assert_match(/\A\S+: cannot look for a hub: nope\n\z/, err)
        end
    end

    # The hub's place in the tree comes from the candidate the gem
    # reported, not from the serial line.  The FT232 is wired at the
    # last position of the internal 4-by-4 tree, so its own path is
    # <root>.4.4 and the root is that less two.
    def test_the_hub_root_comes_from_the_candidate
        with_host do
            cli = cli_for("device = A50285BI\n#{DEVLIST}", device: nil)
            assert_equal '1-1.2', cli.hub_usb_root
        end
    end

    # A line named outright still brings its USB path, when discovery
    # knows it: -d is an escape hatch, not a reason to lose --method usb.
    def test_a_named_line_still_picks_up_its_usb_path
        with_host do
            assert_equal '1-1.2',
                         cli_for(DEVLIST, device: '/dev/ttyUSB0').hub_usb_root
        end
    end

    # ... and a line discovery does not know has no root, rather than
    # a guessed one.
    def test_a_line_discovery_does_not_know_has_no_root
        with_host do
            assert_nil cli_for(DEVLIST, device: '/dev/pts/7').hub_usb_root
        end
    end

    # A candidate whose topology could not be established (a FreeBSD
    # walk that never reached a root hub) is the same case.
    def test_a_candidate_with_no_usb_path_has_no_root
        with_host([ HOST.first.merge(:usb_path => nil) ]) do
            assert_nil cli_for(DEVLIST, device: nil).hub_usb_root
        end
    end

    # An adapter plugged straight into a root port is not inside a hub,
    # so there is no root to take two levels off.
    def test_an_adapter_too_shallow_to_be_in_a_hub_has_no_root
        with_host([ HOST.first.merge(:usb_path => '1-4') ]) do
            assert_nil cli_for(DEVLIST, device: nil).hub_usb_root
        end
    end

    # The geometry, which belongs to the hub and not to either host.
    def test_a_port_resolves_by_the_four_by_four_geometry
        plat = TribbleControl::Platform
        assert_equal '1-1.2.1.1', plat.port_to_usb(1,  root: '1-1.2')
        assert_equal '1-1.2.2.1', plat.port_to_usb(5,  root: '1-1.2')
        assert_equal '1-1.2.4.3', plat.port_to_usb(15, root: '1-1.2')
    end

    # The documented trap: port 16 lands where the FT232 itself sits.
    def test_port_16_resolves_to_the_control_adapter
        with_host do
            cli = cli_for("device = A50285BI\n#{DEVLIST}", device: nil)
            assert_equal HOST.first[:usb_path],
                         TribbleControl::Platform.port_to_usb(
                             16, root: cli.hub_usb_root)
        end
    end

    def test_a_root_that_is_not_a_usb_path_is_refused
        assert_raises(TribbleControl::CLI::Error) {
            TribbleControl::Platform.port_to_usb(1, root: '/dev/ttyUSB0')
        }
    end

    def test_no_candidate_at_all_says_so
        with_host([]) do
            assert_match(/no FTDI 0403:6001 on this host/,
                         refusal_for(DEVLIST, device: nil))
        end
    end
end
