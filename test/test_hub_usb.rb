# frozen_string_literal: true

require 'minitest/mock'

require_relative 'helper'
require_relative 'support/fake_usbconfig'
require_relative '../lib/tribble-control/hub/usb'

# The plain-USB hub backend, against a fake FreeBSD host.
#
# Every command the backend runs goes through the runner it is handed,
# so what is exercised here is the whole of it: the sysctl tree it
# picks its candidates out of, the hub-class requests it issues, and
# the text usbconfig answers them with.  Nothing switches a real port,
# and the fake is where the traps live -- the two power bits, the
# doubled payload, the '<ERROR>' that exits 0.
#
# The host below is the bench this was written against: two root hubs,
# a Genesys USB 2 hub and a SuperSpeed one, and two TI TUSB8041s, the
# second behind the first.
class TestHubUSB < Minitest::Test
    USB = TribbleControl::Hub::USB

    ROOTS = [
        { :unit => 0, :parent => 'usbus1' },
        { :unit => 1, :parent => 'usbus0' }
    ].freeze

    # ugen1.3 is at 1-1, ugen0.2 at 0-2, ugen1.4 at 1-1.1 (on port 1 of
    # ugen1.3) and ugen1.5 at 1-1.1.4 (on port 4 of ugen1.4).
    HOST = [
        *ROOTS,
        { :unit => 2, :device => 'ugen1.3', :parent => 'uhub0',
          :bus => 1, :port => 1, :vendor => '0x05e3', :product => '0x0610',
          :chars => 0x00e0 },
        { :unit => 3, :device => 'ugen0.2', :parent => 'uhub1',
          :bus => 0, :port => 2, :vendor => '0x05e3', :product => '0x0626',
          :type => 0x2a, :chars => 0x0000 },
        { :unit => 4, :device => 'ugen1.4', :parent => 'uhub2',
          :bus => 1, :port => 1, :serial => 'AC0528515619', :present => [ 2 ] },
        { :unit => 5, :device => 'ugen1.5', :parent => 'uhub4',
          :bus => 1, :port => 4, :serial => '8C0528515619', :ports => 3 }
    ].freeze

    def fake(hubs = HOST, **kws) = FakeUsbconfig.new(hubs.map(&:dup), **kws)

    # The host check is the one thing here that is about the machine
    # the tests run on rather than the one they describe.
    def open_hub(named = nil, run:, **kws)
        USB.stub(:freebsd?, true) { USB.open(named, run: run, **kws) }
    end

    def argv(device, *args)
        [ '/usr/sbin/usbconfig', '-d', device, 'do_request', *args ]
    end

    ### Discovery #######################################################

    # A root hub has an empty %location and a usbusN for a parent, and
    # none of its ports can be switched: it is the controller.
    def test_root_hubs_are_not_candidates
        found = USB.available(run: fake).map {|c| c[:device] }
        assert_equal %w[ugen1.3 ugen0.2 ugen1.4 ugen1.5], found
    end

    def test_a_candidate_carries_what_a_name_and_a_path_need
        found = USB.available(run: fake).find {|c| c[:device] == 'ugen1.4' }
        assert_equal({ :device    => 'ugen1.4',
                       :serial    => 'AC0528515619',
                       :usb_path  => '1-1.1',
                       :ports     => 4,
                       :switching => :individual,
                       :desc      => 'vendor 0x0451 product 0x8142' }, found)
    end

    # The Genesys parts report no serial at all, which is exactly the
    # case a USB path has to cover.
    def test_a_hub_with_no_serial_reports_none_rather_than_an_empty_one
        found = USB.available(run: fake).find {|c| c[:device] == 'ugen1.3' }
        assert_nil found[:serial]
        assert_equal :ganged, found[:switching]
    end

    ### Naming ##########################################################

    def test_a_hub_is_named_by_its_serial
        assert_equal 'ugen1.4', open_hub('AC0528515619', run: fake).to_s
    end

    def test_a_hub_is_named_by_its_usb_path
        assert_equal 'ugen1.5', open_hub('1-1.1.4', run: fake).to_s
    end

    def test_a_hub_is_named_by_its_ugen_name
        hub = open_hub('ugen0.2', run: fake)
        assert_equal 'ugen0.2', hub.to_s
        # Discovery is still consulted, quietly: the path comes from it.
        assert_equal '0-2.3', hub.usb_path(3)
    end

    def test_two_candidates_are_refused_with_both_listed
        two = [ ROOTS.first, HOST[2], HOST[4] ]
        e   = assert_raises(TribbleControl::Hub::Error) {
                  open_hub(nil, run: fake(two)) }
        assert_match(/2 USB hubs on this host/, e.message)
        assert_match(/ugen1\.3, which reports no serial \[1-1\], 4 ports/,
                     e.message)
        assert_match(/AC0528515619 on ugen1\.4 \[1-1\.1\], 4 ports/, e.message)
    end

    # Discovery is a listing: one hub that answers no descriptor is
    # listed without a port count rather than stopping the others from
    # being named.  Choosing it is what is refused.
    def test_a_hub_answering_no_descriptor_is_listed_not_fatal
        odd  = { :unit => 6, :device => 'ugen1.6', :parent => 'uhub0',
                 :bus => 1, :port => 5, :type => 0x00 }
        host = [ *HOST, odd ]
        found = USB.available(run: fake(host))
        assert_includes found.map {|c| c[:device] }, 'ugen1.6'
        assert_nil found.find {|c| c[:device] == 'ugen1.6' }[:ports]
        e = assert_raises(TribbleControl::Hub::Error) {
                open_hub('ugen1.6', run: fake(host)) }
        assert_match(/ugen1\.6 answers no hub descriptor/, e.message)
        e = assert_raises(TribbleControl::Hub::Error) {
                open_hub(nil, run: fake(host)) }
        assert_match(/ugen1\.6, which reports no serial \[1-5\], an unknown number of ports/,
                     e.message)
    end

    # Each candidate has commas of its own, so the list needs another
    # separator to be read back.
    def test_listed_candidates_are_separated_by_semicolons
        two = [ ROOTS.first, HOST[2], HOST[4] ]
        e   = assert_raises(TribbleControl::Hub::Error) {
                  open_hub(nil, run: fake(two)) }
        assert_match(/4 ports; AC0528515619 on ugen1\.4/, e.message)
    end

    def test_a_host_with_no_switchable_hub_is_refused
        e = assert_raises(TribbleControl::Hub::Error) {
                open_hub(nil, run: fake(ROOTS)) }
        assert_match(/no USB hub below a root hub/, e.message)
    end

    def test_a_name_that_matches_nothing_lists_what_there_is
        e = assert_raises(TribbleControl::Hub::Error) {
                open_hub('NOSUCHSERIAL', run: fake) }
        assert_match(/no USB hub with serial 'NOSUCHSERIAL'/, e.message)
        assert_match(/AC0528515619 on ugen1\.4/, e.message)
    end

    ### The descriptor ##################################################

    def test_ports_come_from_the_descriptor_of_a_usb_2_hub
        assert_equal [ 1, 2, 3 ], open_hub('8C0528515619', run: fake).ports
    end

    def test_ports_come_from_the_descriptor_of_a_superspeed_hub
        assert_equal [ 1, 2, 3, 4 ], open_hub('ugen0.2', run: fake).ports
    end

    # A hub that answers neither descriptor is not one this tool can
    # drive, and '<ERROR>' is how it says so -- with an exit status of
    # 0, which is why the text is what is read.
    def test_a_refused_request_becomes_a_hub_error
        host = [ ROOTS.first,
                 HOST[4].merge(:type => 0x30) ]
        e    = assert_raises(TribbleControl::Hub::Error) {
                   open_hub('ugen1.4', run: fake(host)) }
        assert_match(/answers no hub descriptor/, e.message)
    end

    ### State ###########################################################

    # 0x0100 on a USB 2 hub: port 2 has a board on it and port 3 is cut.
    def test_state_decodes_a_usb_2_hub
        run = fake([ *ROOTS, HOST[4].merge(
                         :powered => { 1 => true, 2 => true,
                                       3 => false, 4 => true }) ])
        assert_equal({ 1 => true, 2 => true, 3 => false, 4 => true },
                     open_hub('ugen1.4', run: run).state)
    end

    # 0x0200 on a SuperSpeed hub, whose empty ports also carry 0x00a0
    # of link state -- read with the USB 2 bit they would all look
    # unpowered.
    def test_state_decodes_a_superspeed_hub
        run = fake([ *ROOTS, HOST[3].merge(
                         :present => [ 1 ],
                         :powered => { 1 => true, 2 => true,
                                       3 => false, 4 => false }) ])
        assert_equal({ 1 => true, 2 => true, 3 => false, 4 => false },
                     open_hub('ugen0.2', run: run).state)
    end

    ### Switching #######################################################

    def test_on_and_off_issue_the_hub_class_requests
        run = fake
        hub = open_hub('ugen1.4', run: run)
        run.log.clear
        hub.off(2)
        assert_equal [ argv('ugen1.4', '0x23', '0x01', '0x0008', '2', '0'),
                       argv('ugen1.4', '0xa3', '0x00', '0x0000', '2', '4') ],
                     run.log
        run.log.clear
        hub.on(2)
        assert_equal [ argv('ugen1.4', '0x23', '0x03', '0x0008', '2', '0'),
                       argv('ugen1.4', '0xa3', '0x00', '0x0000', '2', '4') ],
                     run.log
    end

    def test_off_then_on_reaches_the_hub
        run = fake
        hub = open_hub('ugen1.4', run: run)
        hub.off(1, 3)
        assert_equal({ 1 => false, 2 => true, 3 => false, 4 => true },
                     run.powered('ugen1.4'))
        hub.on(3)
        assert_equal true, run.powered('ugen1.4')[3]
    end

    def test_toggle_inverts_only_what_it_is_given
        run = fake([ *ROOTS, HOST[4].merge(
                         :powered => { 1 => true, 2 => false,
                                       3 => true, 4 => true }) ])
        open_hub('ugen1.4', run: run).toggle(1, 2)
        assert_equal({ 1 => false, 2 => true, 3 => true, 4 => true },
                     run.powered('ugen1.4'))
    end

    # set is the interface's, not this backend's: a plain hub has no
    # request that changes several ports at once.
    def test_set_is_the_inherited_on_and_off
        run = fake
        open_hub('ugen1.4', run: run).set({ 1 => false, 2 => true })
        assert_equal({ 1 => false, 2 => true, 3 => true, 4 => true },
                     run.powered('ugen1.4'))
    end

    # The hub answered OK and switched nothing.  Without the read-back
    # this is what `off` reports as success.
    def test_a_port_that_did_not_follow_is_reported_by_name
        run = fake([ *ROOTS, HOST[4].merge(:honours => false) ])
        hub = open_hub('ugen1.4', run: run)
        e   = assert_raises(TribbleControl::Hub::Error) { hub.off(3) }
        assert_match(/port 3 of ugen1\.4 did not switch off/, e.message)
    end

    ### The guards ######################################################

    def test_an_empty_list_is_refused_before_anything_is_issued
        run = fake
        hub = open_hub('ugen1.4', run: run)
        run.log.clear
        assert_raises(TribbleControl::Hub::Error) { hub.off }
        assert_empty run.log
    end

    def test_a_port_the_hub_has_not_got_is_refused_before_anything_is_issued
        run = fake
        hub = open_hub('8C0528515619', run: run)       # three ports
        run.log.clear
        e = assert_raises(TribbleControl::Hub::Error) { hub.off(1, 4) }
        assert_match(/no such port on this hub: 4/, e.message)
        assert_empty run.log
    end

    ### What the backend is told #########################################

    def test_usb_path_is_the_hubs_own_path_and_the_port
        assert_equal '1-1.1.2', open_hub('AC0528515619', run: fake).usb_path(2)
    end

    # A hub whose walk does not reach a root has no path, and says so
    # rather than answering a shorter one -- 1-1 and 1-1.1 are not the
    # same socket.
    def test_usb_path_is_nil_for_a_hub_the_tree_cannot_place
        orphan = HOST[4].merge(:parent => 'uhub9')
        hub    = open_hub('ugen1.4', run: fake([ *ROOTS, orphan ]))
        assert_nil hub.usb_path(2)
    end

    def test_vbus_is_what_the_switch_says
        assert_equal false, open_hub('ugen1.4', run: fake).vbus?
        assert_equal false, open_hub('ugen1.4', run: fake, switch: :link).vbus?
        assert_equal true,  open_hub('ugen1.4', run: fake, switch: :vbus).vbus?
    end

    def test_an_unknown_switch_is_refused
        e = assert_raises(TribbleControl::Hub::Error) {
                open_hub('ugen1.4', run: fake, switch: :relay) }
        assert_match(/no such switch :relay/, e.message)
    end

    ### The host #########################################################

    def test_ugen_nodes_that_cannot_be_opened_name_the_group
        e = assert_raises(TribbleControl::Hub::Error) {
                open_hub('ugen1.4', run: fake(HOST, denied: true)) }
        assert_match(/group operator/, e.message)
    end

    def test_a_host_that_is_not_freebsd_is_refused
        e = USB.stub(:freebsd?, false) {
                assert_raises(TribbleControl::Hub::Error) {
                    USB.open(nil, run: fake) }
            }
        assert_match(/runs on FreeBSD only for now/, e.message)
    end
end
