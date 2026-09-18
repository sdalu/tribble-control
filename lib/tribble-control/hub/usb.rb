# frozen_string_literal: true

#
# Any USB hub that switches its own ports, driven through usbconfig(8).
#
# Nothing here is an agreement with one manufacturer: what is spoken is
# USB chapter 11, the hub class, which every hub answers -- the hub
# descriptor says how many ports there are, GET_STATUS says whether one
# is powered, and SET_FEATURE/CLEAR_FEATURE(PORT_POWER) switches it.
# The ExSYS backend needs a gem because the ExSYS hub is switched over
# a serial line wired beside the bus; this one needs none, because the
# switching is on the bus itself.
#
# FreeBSD only for now: usbconfig(8) is FreeBSD's, and Linux has no
# command that issues an arbitrary control request to a hub.
#
require 'open3'
require 'rbconfig'

require_relative '../hub'
require_relative '../platform'

module TribbleControl
class Hub

class USB < Hub
    # Both by absolute path: this program switches benches, and what it
    # runs must not depend on whoever's PATH it was started with.
    USBCONFIG = '/usr/sbin/usbconfig'
    SYSCTL    = '/sbin/sysctl'

    # The two names that are not a serial.  A ugen name is what
    # usbconfig -d takes; a USB path is what the devlist already uses
    # to place a board.
    UGEN     = /\Augen\d+\.\d+\z/
    USB_PATH = /\A\d+-\d+(?:\.\d+)*\z/

    # The hub descriptor, by bDescriptorType: the wValue that asks for
    # it, how many bytes it is, and -- THE TRAP -- which bit of
    # wPortStatus then means "powered".  A USB 2 hub (0x29) reports
    # power in 0x0100; a SuperSpeed hub (0x2a) reports it in 0x0200 and
    # puts the link state in bits 5-8, so reading a SuperSpeed port
    # with the USB 2 bit answers "unpowered" for a port that is fine.
    # Which descriptor the hub ANSWERS is therefore what decides how
    # its status word is read, and is remembered for that.
    DESCRIPTORS = {
        0x29 => { :value => '0x2900', :length => '9',  :power => 0x0100 },
        0x2a => { :value => '0x2a00', :length => '12', :power => 0x0200 }
    }.freeze

    # wHubCharacteristics bits 1:0, as the candidate reports them.
    # Reported and never acted on: a hub that says ganged may still
    # switch per port (the Genesys part on this bench does), and a hub
    # that says individual may still switch nothing.  The read-back
    # after a switch is what knows, so nothing is refused on this.
    SWITCHING = [ :ganged, :individual, :none, :none ].freeze

    # PORT_POWER, the only port feature this backend touches.
    PORT_POWER = '0x0008'

    # What 'off' does to the socket, which the hub cannot be asked.
    # See Hub#vbus?: a plain hub takes the port off the bus, and only
    # one with a power switch wired to VBUS cuts the supply.
    SWITCHES = { :link => false, :vbus => true }.freeze

    # A class method so that a test can stand on another host, and
    # because this is the one fact about the platform the backend has.
    def self.freebsd? = RbConfig::CONFIG['host_os'].match?(/^freebsd/)

    # How a command is run: a callable (*argv) -> merged stdout+stderr.
    #
    # Everything this class runs goes through one of these, so a test
    # hands it a fake host instead of a real one, and nothing in the
    # methods below has to know what Open3 is.
    def self.runner
        lambda do |*argv|
            Open3.capture2e(*argv).first
        rescue Errno::ENOENT
            raise Error, "cannot run #{argv.first}: it is not installed" \
                         ' on this host, so no USB hub can be switched here'
        end
    end

    # Every hub on this host that is not a root hub, as
    #
    #     { device: 'ugen1.4', serial: 'AC0528515619', usb_path: '1-1.1',
    #       ports: 4, switching: :individual,
    #       desc: 'vendor 0x0451 product 0x8142' }
    #
    # Root hubs are left out because they are the controller: their
    # %location is empty and their parent is a usbusN, and a port of
    # theirs has no PORT_POWER to clear.  Offering one as a candidate
    # would offer a hub every command against it then failed on.
    #
    # The descriptor is read per hub rather than guessed, because it is
    # what says how many ports a candidate has -- and the port count is
    # half of what a refusal has to print for the reader to tell two
    # identical hubs apart.  A hub that will not answer one is listed
    # all the same, with no port count: discovery is a listing, and one
    # odd hub must not stop the others from being named.  Choosing that
    # hub is what is refused, in #initialize, where the descriptor is
    # read for real.
    def self.available(run: nil)
        run ||= self.runner
        tree  = Platform::FreeBSD.parse_usb_tree(run.call(SYSCTL, '-e', 'dev.uhub'))
        tree.filter_map {|name, dev|
            next unless name.start_with?('uhub')
            loc = dev[:'%location']
            next unless loc.is_a?(Hash) && (ugen = loc[:ugen])
            desc   = begin
                self.descriptor(ugen, run)
            rescue Error
                { :ports => nil, :switching => :unknown }
            end
            serial = dev.dig(:'%pnpinfo', :sernum).to_s
            { :device    => ugen,
              :serial    => serial.empty? ? nil : serial,
              :usb_path  => Platform::FreeBSD.usb_path(dev, tree),
              :ports     => desc[:ports],
              :switching => desc[:switching],
              # The tail of %desc is the class, the revision and the
              # bus address, and the address changes on every replug:
              # only the head names the part.
              :desc      => dev[:'%desc'].to_s.split(',').first }
        }
    end

    # The hub +named+ names, or the one switchable hub the host has.
    #
    # Three shapes of name, told apart by what they look like, no two
    # of which can be confused:
    #
    #   ugen1.4        the ugen shape, so that device, used as given
    #   1-1.1          the USB path shape, so the hub in that socket
    #   AC0528515619   anything else, so the hub's serial number
    #
    # The ugen name is the worst of the three to write down, and it is
    # here for the same reason /dev/ttyUSB1 is in Hub::ExSYS.open: it
    # is the escape hatch for a hub discovery cannot answer for.  The
    # number in it is enumeration order -- ugen1.4 is the fourth device
    # the second controller attached -- so a replug renumbers it, and a
    # devlist naming a hub that way points at whatever attached in its
    # place.  The other two are stable: a serial follows the HUB, a USB
    # path follows the SOCKET, and each names one host's numbering.
    #
    # Auto-detection is only safe while there is one candidate.  Two
    # hubs on a host and no name is a coin toss decided by enumeration
    # order, and driving the wrong one raises nothing anywhere: the
    # ports exist, the requests succeed, and the boards that go dark
    # are on the other bench.  It refuses and lists them instead.
    def self.open(named, switch: :link, run: nil)
        unless self.freebsd?
            raise Error, 'the usb hub backend runs on FreeBSD only for now:' \
                         ' it switches ports with usbconfig(8) hub-class' \
                         ' requests, and no other host here has usbconfig'
        end
        run ||= self.runner
        if named && UGEN.match?(named)
            # Used as given, and discovery is not required to succeed
            # for that to work.  It is still ASKED, quietly, because a
            # device that IS a known candidate brings its USB path and
            # its serial with it, and the path is what --method usb
            # needs; see #usb_path.
            return new(named, hub: self.candidate_for(named, run),
                              switch: switch, run: run)
        end
        found = self.available(run: run)
        hub   = named ? self.match(named, found) : self.lone(found)
        new(hub[:device], hub: hub, switch: switch, run: run)
    end

    # The one candidate +named+ names among +found+, or an error.
    def self.match(named, found)
        key, what = if USB_PATH.match?(named)
                    then [ :usb_path, 'at USB path' ]
                    else [ :serial,   'with serial'  ]
                    end
        match = found.select {|c| c[key] == named }
        case match.size
        when 1 then match.first
        when 0
            raise Error, "no USB hub #{what} '#{named}' on this host" \
                         " (#{seen(found)}).  A name shaped ugen1.4 is" \
                         ' taken as a device, one shaped 1-1.1 as a USB' \
                         ' path, and anything else as a hub serial number'
        else
            raise Error, "#{match.size} USB hubs are #{what} '#{named}'" \
                         " (#{seen(found)}): name the hub by its ugen" \
                         ' name instead'
        end
    end

    # The one switchable hub the host has, when it has exactly one.
    def self.lone(found)
        case found.size
        when 1 then found.first
        when 0
            raise Error, 'unable to auto-detect the hub: this host has no' \
                         ' USB hub below a root hub, and a root hub has no' \
                         " switchable port.  Name the hub with -d, or with" \
                         " a 'device =' line in the devlist"
        else
            raise Error, 'unable to auto-detect the hub:' \
                         " #{found.size} USB hubs on this host" \
                         " (#{seen(found)}).  Name the one to drive with" \
                         " -d, or with a 'device =' line in the devlist"
        end
    end

    # The candidate the host reports for a device named outright, or nil.
    #
    # Quietly, as in Hub::ExSYS.candidate_for: naming a device is the
    # escape hatch for a host discovery cannot answer on, so a
    # discovery that fails here must not take the run with it.  What is
    # lost when it does is the USB path, and with it --method usb,
    # which says so at the point it needs one.
    def self.candidate_for(device, run)
        self.available(run: run).find {|c| c[:device] == device }
    rescue Error
        nil
    end

    # What the host has, as a refusal lists it.  Semicolons between
    # candidates, because each one has commas of its own.
    def self.seen(found)
        return 'none found' if found.empty?
        "found: #{found.map {|c| describe(c) }.join('; ')}"
    end

    # One candidate, as an error message names it: the serial leads,
    # being what the reader is meant to copy into a devlist, then the
    # device, the socket, and the port count -- which is the only thing
    # that tells two of the same part apart when neither has a serial.
    def self.describe(hub)
        name = if hub[:serial]
               then "#{hub[:serial]} on #{hub[:device]}"
               else "#{hub[:device]}, which reports no serial"
               end
        name += " [#{hub[:usb_path]}]" if hub[:usb_path]
        "#{name}, #{hub[:ports] || 'an unknown number of'} ports"
    end

    # The hub descriptor of +device+: which kind of hub it is, how many
    # ports it has, and what it says about switching them.
    #
    # Two requests and not one, because the descriptor TYPE is half the
    # answer and there is no way to ask which type a hub has: a USB 2
    # hub answers 0x2900 and refuses 0x2a00, a SuperSpeed hub does the
    # reverse.  Whichever answered decides how the port status word is
    # read from then on (see DESCRIPTORS).
    def self.descriptor(device, run)
        DESCRIPTORS.each do |type, d|
            bytes = self.bytes(device,
                               self.request(device, run, '0xa0', '0x06',
                                            d[:value], '0', d[:length]))
            next if bytes.nil?
            return { :type      => type,
                     :ports     => bytes[2],
                     :switching => SWITCHING[bytes[3] & 0x03] }
        end
        raise Error, "#{device} answers no hub descriptor, neither USB 2" \
                     ' nor SuperSpeed, so it is not a hub this tool can' \
                     ' switch'
    end

    # One usbconfig request, as the text between its angle brackets:
    # 'OK', 'ERROR', or the bytes that came back.
    #
    # Only the first bracketed group: usbconfig prints the payload
    # again as ASCII after it, and that copy contains whatever the
    # bytes happened to spell -- '<0x09 0x29 ...><)>' for a descriptor.
    # A pattern that reached for the last group would parse that.
    #
    # The exit status is not consulted because it is not the answer:
    # usbconfig exits 0 for a request the hub refused, and 0 for a
    # device it could not even find.  The printed text is the truth.
    def self.request(device, run, *args)
        out = run.call(USBCONFIG, '-d', device, 'do_request', *args)
        if out.match?(/Permission denied|Operation not permitted/)
            raise Error, "not allowed to drive #{device}: the ugen nodes" \
                         ' are root:operator 0660, so switching a port' \
                         ' needs membership of group operator (pw groupmod' \
                         ' operator -m <user>, then log in again)'
        end
        payload = out[/REQUEST = <([^>]*)>/, 1]
        if payload.nil?
            raise Error, "#{device} answered no usbconfig request" \
                         " (#{out.to_s.lines.first.to_s.strip}): it is not" \
                         ' a device this host can be asked about'
        end
        payload
    end

    # The bytes of an answer, or nil for a request the hub refused.
    def self.bytes(device, payload)
        return nil if payload == 'ERROR'
        payload.split.map {|b| Integer(b, 16) }
    rescue ArgumentError
        raise Error, "#{device} answered '#{payload}' where a usbconfig" \
                     ' request should have brought bytes back'
    end

    private_class_method :match, :lone, :seen, :describe

    # +device+ is the ugen name usbconfig is given; +hub+ the candidate
    # it was chosen from, when discovery knew it, which is where the
    # USB path comes from.  The descriptor is read here and not per
    # call: the port count is asked before the hub is opened for real
    # (the devlist is checked against it) and it cannot change under
    # us, while the port STATE can and is never remembered.
    def initialize(device, hub: nil, switch: :link, run: nil)
        super()
        @device = device
        @hub    = hub || {}
        @run    = run || self.class.runner
        @vbus   = SWITCHES.fetch(switch) {
            raise Error, "no such switch #{switch.inspect}: a hub's 'off'" \
                         ' either takes the port off the bus (:link,' \
                         " the default) or cuts the socket (:vbus), and" \
                         ' software cannot tell which this hub is' \
                         ' wired for'
        }
        @desc   = self.class.descriptor(@device, @run)
        @ports  = (1..@desc[:ports]).to_a
    end

    # The ugen name, as it was named or found, and the ports the hub's
    # descriptor says it has.
    attr_reader :device
    attr_reader :ports

    def to_s  = @device
    def vbus? = @vbus

    # One GET_STATUS per port: the hub has no request that reports them
    # all, so a status of a 16-port hub is 16 exchanges.
    def state = @ports.to_h {|port| [ port, powered?(port) ] }

    def on(*list)  = apply(selection(list), true)
    def off(*list) = apply(selection(list), false)

    # Read then invert, port by port, because there is no request that
    # flips one: a port's own current state is the only thing that says
    # what toggling it means.
    def toggle(*list)
        selection(list).each {|port| apply([ port ], !powered?(port)) }
    end

    # Where a board on +port+ is in this host's USB tree.  A plain hub
    # has no internal geometry to account for -- the ExSYS hub's 4-by-4
    # tree is a fact about that hub and not about hubs -- so a port is
    # one component below the hub's own path.
    #
    # nil when there is nothing to work it out from: a device named
    # outright that discovery does not know, or a host that reports no
    # path for it.
    def usb_path(port)
        root = @hub[:usb_path]
        root && "#{root}.#{port}"
    end

  private

    # Switch every port in +list+, and check that the hub did it.
    #
    # The read-back is not belt and braces, it is the only thing that
    # knows.  A hub that switches nothing -- ganged, or with no switch
    # wired -- accepts CLEAR_FEATURE(PORT_POWER) and answers OK, and
    # the port stays up.  Without this, `off` would report success on a
    # bench it had not touched, and a board would be flashed live.  It
    # is also why nothing is refused on wHubCharacteristics: the
    # descriptor is a claim, this is the measurement.
    def apply(list, powered)
        list.each do |port|
            feature(powered ? '0x03' : '0x01', port)
            next if powered?(port) == powered
            raise Error, "port #{port} of #{@device} did not switch" \
                         " #{powered ? 'on' : 'off'}: the hub accepted the" \
                         ' request and the port still reports itself' \
                         " #{powered ? 'unpowered' : 'powered'}, so this" \
                         ' hub does not switch that port'
        end
    end

    # SET_FEATURE (0x03) or CLEAR_FEATURE (0x01) of PORT_POWER.
    def feature(request, port)
        answer = self.class.request(@device, @run, '0x23', request,
                                    PORT_POWER, port.to_s, '0')
        return if answer == 'OK'
        raise Error, "#{@device} refused to switch port #{port}:" \
                     " usbconfig answered '#{answer}'"
    end

    # Is the port powered, by the bit this kind of hub reports it in?
    def powered?(port)
        port_status(port).anybits?(DESCRIPTORS.fetch(@desc[:type])[:power])
    end

    # wPortStatus, the first two of the four bytes GET_STATUS brings
    # back, little-endian.  The other two are wPortChange, which this
    # backend never reads: it says what has happened since the last
    # time somebody cleared it, and nothing here clears it.
    def port_status(port)
        bytes = self.class.bytes(@device,
                                 self.class.request(@device, @run, '0xa3',
                                                    '0x00', '0x0000',
                                                    port.to_s, '4'))
        if bytes.nil? || bytes.size < 2
            raise Error, "#{@device} reports no status for port #{port}:" \
                         ' the hub refused the request, which is what it' \
                         ' answers for a port it has not got'
        end
        bytes[0] | (bytes[1] << 8)
    end
end

end
end
