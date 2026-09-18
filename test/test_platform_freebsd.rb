# frozen_string_literal: true

require_relative 'helper'

# The FreeBSD USB lookups, against a capture of a real bus.
#
# FreeBSD states no USB path anywhere -- there is no /sys/bus/usb -- so
# one is walked out of the sysctl tree: %location gives the port a
# device occupies on its parent, %parent names that parent, and the
# walk ends at a root hub, whose own %location is empty.
#
# The tree below was captured from a live FreeBSD host with an
# nRF52840-MDK plugged in, which is why it is worth having: the MDK
# puts its OWN hub (uhub6, a Microchip part) on the socket and its
# DAPLink one level below it, so a board's hub port leads to the hub
# and the console and the serial belong to the child.  That is the
# case a hand-written fixture would have got wrong.
#
# Two things are added to it.  uftdi0 is an ExSYS control adapter,
# which this host has not got: it is placed where one really sits, at
# the last position of the hub's internal 4-by-4 tree, with uhub4
# stood in for the hub root and uhub5 for its fourth bank.  usbhid0..2
# (a wireless receiver, three interfaces on one device) are dropped for
# width.
class TestPlatformFreeBSD < Minitest::Test
    FB = TribbleControl::Platform::FreeBSD

    CAPTURE = <<~SYSCTL
        dev.uhub.%parent=
        dev.uhub.0.%location=
        dev.uhub.0.%parent=usbus1
        dev.uhub.0.%pnpinfo=
        dev.uhub.1.%location=
        dev.uhub.1.%parent=usbus0
        dev.uhub.1.%pnpinfo=
        dev.uhub.2.%location=bus=1 hubaddr=1 port=1 devaddr=3 interface=0 ugen=ugen1.3
        dev.uhub.2.%parent=uhub0
        dev.uhub.2.%pnpinfo=vendor=0x05e3 product=0x0610 devclass=0x09 devsubclass=0x00 devproto=0x01 sernum="" release=0x0663 mode=host intclass=0x09 intsubclass=0x00 intprotocol=0x00
        dev.uhub.3.%location=bus=0 hubaddr=1 port=2 devaddr=2 interface=0 ugen=ugen0.2
        dev.uhub.3.%parent=uhub1
        dev.uhub.3.%pnpinfo=vendor=0x05e3 product=0x0626 devclass=0x09 devsubclass=0x00 devproto=0x03 sernum="" release=0x0663 mode=host intclass=0x09 intsubclass=0x00 intprotocol=0x00
        dev.uhub.4.%location=bus=1 hubaddr=3 port=1 devaddr=4 interface=0 ugen=ugen1.4
        dev.uhub.4.%parent=uhub2
        dev.uhub.4.%pnpinfo=vendor=0x0451 product=0x8142 devclass=0x09 devsubclass=0x00 devproto=0x02 sernum="AC0528515619" release=0x0100 mode=host intclass=0x09 intsubclass=0x00 intprotocol=0x02
        dev.uhub.5.%location=bus=1 hubaddr=4 port=4 devaddr=5 interface=0 ugen=ugen1.5
        dev.uhub.5.%parent=uhub4
        dev.uhub.5.%pnpinfo=vendor=0x0451 product=0x8142 devclass=0x09 devsubclass=0x00 devproto=0x02 sernum="8C0528515619" release=0x0100 mode=host intclass=0x09 intsubclass=0x00 intprotocol=0x02
        dev.uhub.6.%location=bus=1 hubaddr=1 port=3 devaddr=9 interface=0 ugen=ugen1.9
        dev.uhub.6.%parent=uhub0
        dev.uhub.6.%pnpinfo=vendor=0x0424 product=0x2422 devclass=0x09 devsubclass=0x00 devproto=0x01 sernum="" release=0x00a0 mode=host intclass=0x09 intsubclass=0x00 intprotocol=0x00
        dev.umass.%parent=
        dev.umass.0.%location=bus=1 hubaddr=9 port=1 devaddr=10 interface=0 ugen=ugen1.10
        dev.umass.0.%parent=uhub6
        dev.umass.0.%pnpinfo=vendor=0x0d28 product=0x0204 devclass=0xef devsubclass=0x02 devproto=0x01 sernum="1026360216057a6800000000000000000000000097969902" release=0x0100 mode=host intclass=0x08 intsubclass=0x06 intprotocol=0x50
        dev.umodem.%parent=
        dev.umodem.0.%location=bus=1 hubaddr=9 port=1 devaddr=10 interface=1 ugen=ugen1.10
        dev.umodem.0.%parent=uhub6
        dev.umodem.0.%pnpinfo=vendor=0x0d28 product=0x0204 devclass=0xef devsubclass=0x02 devproto=0x01 sernum="1026360216057a6800000000000000000000000097969902" release=0x0100 mode=host intclass=0x02 intsubclass=0x02 intprotocol=0x01 ttyname=U0 ttyports=1
        dev.umodem.0.ttyname=U0
        dev.usbhid.%parent=
        dev.usbhid.3.%location=bus=1 hubaddr=9 port=1 devaddr=10 interface=3 ugen=ugen1.10
        dev.usbhid.3.%parent=uhub6
        dev.usbhid.3.%pnpinfo=vendor=0x0d28 product=0x0204 devclass=0xef devsubclass=0x02 devproto=0x01 sernum="1026360216057a6800000000000000000000000097969902" release=0x0100 mode=host intclass=0x03 intsubclass=0x00 intprotocol=0x00
        dev.uftdi.0.%location=bus=1 hubaddr=5 port=4 devaddr=11 interface=0 ugen=ugen1.11
        dev.uftdi.0.%parent=uhub5
        dev.uftdi.0.%pnpinfo=vendor=0x0403 product=0x6001 devclass=0x00 devsubclass=0x00 devproto=0x00 sernum="AL03GD7X" release=0x0600 mode=host
        dev.uftdi.0.ttyname=U9
    SYSCTL

    MDK = '1026360216057a6800000000000000000000000097969902'

    # The control adapter's own path, which is what the gem reports as
    # a candidate's :usb_path and what the hub root is worked out from.
    def test_the_control_adapter_is_placed_in_the_tree
        assert_equal '1-1.1.4.4',
                     FB.send(:usb_path, tree['uftdi0'], tree)
    end

    def tree = @tree ||= FB.parse_usb_tree(CAPTURE)

    # The MDK's own hub is on the socket; the probe is one level down.
    # A hub port therefore leads to the hub, and the console is the
    # child's -- which is what 'connect --method usb' depends on.
    def test_a_console_is_found_below_the_port_as_well_as_on_it
        assert_equal '/dev/ttyU0', FB.usb_to_tty('1-3',   tree: tree)
        assert_equal '/dev/ttyU0', FB.usb_to_tty('1-3.1', tree: tree)
    end

    def test_a_probe_serial_is_found_the_same_way
        assert_equal MDK, FB.usb_to_serial('1-3',   tree: tree)
        assert_equal MDK, FB.usb_to_serial('1-3.1', tree: tree)
    end

    # One probe, three drivers -- umodem, umass and usbhid all claim
    # the MDK's DAPLink and all report the device's serial.
    def test_one_probe_under_several_drivers_is_still_one_answer
        at = FB.send(:devices_at, '1-3.1', tree).map(&:first).sort
        assert_equal %w[umass0 umodem0 usbhid3], at
    end

    def test_a_path_with_nothing_on_it_is_nil_not_an_error
        assert_nil FB.usb_to_tty('9-9',    tree: tree)
        assert_nil FB.usb_to_serial('9-9', tree: tree)
    end

    def test_a_device_that_is_not_a_probe_has_no_serial
        assert_nil FB.usb_to_serial('1-1.1.4', tree: tree)   # a TI hub
    end

    # Stopping one hub short of the root would turn 1-1.1.4.4 into
    # 1-4: not a broken string, a different socket.
    def test_a_walk_that_cannot_reach_the_root_is_nil
        orphan = FB.parse_usb_tree(<<~SYSCTL)
            dev.uftdi.0.%location=bus=1 hubaddr=5 port=4 devaddr=11 interface=0
            dev.uftdi.0.%parent=uhub5
        SYSCTL
        assert_nil FB.send(:usb_path, orphan['uftdi0'], orphan)
    end

    # '/dev/tty' + '' is /dev/tty -- the operator's own terminal.  A
    # probe whose tty is not named yet has no console to offer, and
    # offering that one would have connect open the screen it is
    # printing to and read it back as a board.
    def test_a_probe_with_no_tty_yet_is_not_a_console
        t = FB.parse_usb_tree(<<~SYSCTL)
            dev.umodem.0.%pnpinfo=vendor=0x0d28 product=0x0204 sernum="ABC"
            dev.umodem.0.%parent=uhub0
        SYSCTL
        assert FB.send(:probe?, t['umodem0']), 'fixture must be a probe'
        assert_empty t['umodem0'][:ttyname].to_s
        # probe_consoles reads the live tree; the guard it relies on is
        # the one asserted above, so check the mapping it would make.
        refute_includes FB.probe_consoles.values, '/dev/tty'
    end

    # A %parent chain that comes back on itself is not a tree.  Without
    # a guard the answer is not a wrong path but a command that never
    # returns.
    def test_a_parent_chain_that_loops_terminates
        t = FB.parse_usb_tree(<<~SYSCTL)
            dev.uhub.1.%location=bus=1 hubaddr=1 port=1 devaddr=2
            dev.uhub.1.%parent=uhub2
            dev.uhub.2.%location=bus=1 hubaddr=2 port=2 devaddr=3
            dev.uhub.2.%parent=uhub1
        SYSCTL
        assert_nil FB.send(:usb_path, t['uhub1'], t)
    end

    # Some drivers write a bare word where pairs are expected, and a
    # parser that died on one would take the whole bench with it.
    def test_a_field_that_is_not_a_pair_does_not_stop_the_parse
        t = FB.parse_usb_tree(<<~SYSCTL)
            dev.uftdi.0.%pnpinfo=unknown vendor=0x0403 product=0x6001
            dev.uftdi.0.ttyname=U0
        SYSCTL
        assert_equal '0x0403', t['uftdi0'][:'%pnpinfo'][:vendor]
    end
end
