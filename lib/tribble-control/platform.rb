#
# Host-specific ways of finding the boards: their probes, their
# consoles, and their place in the USB tree.  Finding the HUB is the
# exsys gem's (ExSYS::ManagedUSB.available).
#
require 'rbconfig'
require 'shellwords'
require 'exsys/managed-usb'

module TribbleControl

#
# Sysctl quick parsing
#
module Platform

# Vendor ids of the debug probes a bench carries: NXP/mbed for DAPLink
# (as on an nRF52840-MDK), SEGGER for a J-Link OB (as on a DWM1001-DEV).
# Both present their console as a CDC interface reporting the PROBE's
# own serial, which is what makes a serial the key to a console.
PROBE_VENDORS = %w[0d28 1366].freeze

# Finding the HUB is not here: it is ExSYS::ManagedUSB.available, in
# the exsys gem, which knows what a hub's control adapter is because it
# knows the hub.  What is here is finding the BOARDS -- their probes,
# their consoles, their place in the USB tree -- which is this tool's
# own business and no gem's.

module FreeBSD
    # The sysctl branches that describe the USB bus.
    #
    # Not the whole dev tree: that is 78K of text here against 5K for
    # these, and it is read afresh on every lookup rather than
    # remembered, because --method power switches ports off and on
    # underneath us and a remembered tree would describe a bench that
    # has since changed.
    #
    #   uftdi     the hub's control adapter
    #   uhub      every hub, which is what the walk up to the bus
    #             passes through and nothing else
    #   umodem    a probe's CDC console -- the tty, and the serial
    #   usbhid    a DAPLink's HID interface, and umass its drive:
    #   umass     the same device under another driver, carrying the
    #             same serial, so a probe whose CDC did not attach is
    #             still answerable for
    USB_OIDS = %w[dev.uftdi dev.uhub dev.umodem
                  dev.usbhid dev.umass].freeze

    # Every debug probe's console, keyed by the probe's serial.
    #
    # The probe reports its own serial, the devlist already carries
    # that serial to address the board for flashing, and umodem says
    # which tty the probe's CDC interface became.  No topology at all,
    # which is what lets `connect --method serial` work anywhere.
    def self.probe_consoles
        self.usb_tree.filter_map {|name, dev|
            next unless name.start_with?('umodem')
            next unless self.probe?(dev)
            # No ttyname, no console.  '/dev/tty' + '' is /dev/tty --
            # the controlling terminal -- so an entry whose tty is not
            # named yet used to map a probe's serial to the operator's
            # own screen, which connect would then open and read as if
            # it were a board.
            next if dev[:ttyname].to_s.empty?
            [ dev.dig(:'%pnpinfo', :sernum), '/dev/tty' + dev[:ttyname].to_s ]
        }.to_h
    end

    # The console of whatever is at that USB path, or nil.
    #
    # At the path or below it: an nRF52840-MDK puts its own hub on the
    # socket and its DAPLink one level down, so the port leads to the
    # hub and the tty belongs to the child.
    def self.usb_to_tty(path, tree: nil)
        raise ArgumentError if path.nil?
        tree ||= self.usb_tree
        dev   = self.devices_at(path, tree).find {|_n, d| d[:ttyname] }&.last
        dev && ('/dev/tty' + dev[:ttyname].to_s)
    end

    # The probe serial of whatever is at that USB path, or nil.
    #
    # Read from the descriptor the kernel already has, as on Linux, so
    # it needs no SWD session and no powering the rest of the bench
    # down.  Several drivers may claim one probe -- an MDK's DAPLink is
    # umodem, usbhid and umass at once -- and all of them report the
    # device's serial, so the first that is a probe with one answers.
    #
    # The limit here that Linux does not have: a device NO driver
    # claimed has no sysctl node at all, there being no dev.ugen, so it
    # cannot be seen.  A probe that enumerates and attaches nothing is
    # invisible rather than serial-less.
    def self.usb_to_serial(path, tree: nil)
        raise ArgumentError if path.nil?
        tree ||= self.usb_tree
        self.devices_at(path, tree).each do |_name, dev|
            next unless self.probe?(dev)
            serial = dev.dig(:'%pnpinfo', :sernum).to_s
            return serial unless serial.empty?
        end
        nil
    end

    # Is this one of the debug probes a bench carries?
    private_class_method def self.probe?(dev)
        vendor = dev.dig(:'%pnpinfo', :vendor).to_s.delete_prefix('0x')
        PROBE_VENDORS.include?(vendor)
    end

    # Everything sitting at that USB path, or below it, shallowest
    # first and then by name so that the answer does not depend on the
    # order sysctl happened to print.
    private_class_method def self.devices_at(path, tree)
        tree.filter_map {|name, dev|
            p = self.usb_path(dev, tree)
            next unless p == path || p&.start_with?("#{path}.")
            [ p, name, dev ]
        }.sort_by {|p, name, _| [ p.count('.'), p, name ] }
         .map     {|_p, name, dev| [ name, dev ] }
    end

    # Where a device sits in the USB tree, as Linux would write it.
    #
    # FreeBSD states no such path, but every piece of one is in the
    # sysctl tree: %location gives the bus and the port the device
    # occupies on its parent, and %parent names that parent -- always a
    # uhub, up to the root hub, whose own %location is empty.
    #
    # A walk that does not REACH the root answers nil rather than what
    # it collected on the way: stopping one hub short turns 1-1.2.4.4
    # into 1-4, which is not a broken string but a different socket.
    #
    # The exsys gem walks the same tree for its own device, and this is
    # deliberately not that code: its walker is a documented internal
    # of a gem that must stand alone, and a tool reaching into one is a
    # tool that breaks on the next release.
    private_class_method def self.usb_path(dev, tree)
        bus    = nil
        ports  = []
        rooted = false
        seen   = {}
        while dev
            loc = dev[:'%location']
            unless loc.is_a?(Hash) && loc[:port]
                rooted = true          # a root hub occupies no port
                break
            end
            bus ||= loc[:bus]
            ports.unshift(loc[:port])
            parent = dev[:'%parent'].to_s
            # A %parent chain that returns to a device already on the
            # way up is not a tree.  No kernel prints one, but this
            # parses whatever it is handed, and without the guard the
            # answer is not a wrong path but an unbounded loop: a
            # command that never returns and never says why.
            break if seen[parent]
            seen[parent] = true
            dev = tree[parent]
        end
        return nil unless rooted && bus && !ports.empty?
        "#{bus}-#{ports.join('.')}"
    end

    # Parse a sysctl -e dump into the shape below.  Split from the
    # reading of it so that the tests can feed a capture in and run on
    # a host with no bench, no probe, and no sysctl at all.
    def self.parse_usb_tree(output)
        output.lines.reduce({}) {|acc, l|
            k, v       = l.chomp.split('=', 2)
            next acc if k.nil?
            dev, i, sk = k.split('.')[1..]
            # No unit number in it -- dev.uhub.%parent -- so it
            # describes the driver and not a device.
            next acc if sk.nil? || i !~ /\A\d+\z/
            if [ '%pnpinfo', '%location' ].include?(sk)
                # Not every token in one of these is a pair: some
                # drivers write a bare word, and a parser that died on
                # one of them would take the whole bench with it.
                v = Shellwords.shellsplit(v.to_s).filter_map {|e|
                        k2, v2 = e.split('=', 2)
                        [ k2.to_sym, v2 ] if v2
                    }.to_h
            end
            acc.merge("#{dev}#{i}" => { sk.to_sym => v }) {|_k, o, n|
                o.merge(n)
            }
        }
    end

    # The USB branches of the sysctl tree, as
    #
    #     { 'umodem0' => { :ttyname => 'U0', :'%parent' => 'uhub6',
    #                      :'%location' => { :bus => '1', ... } } }
    #
    # Keyed by device name and not by unit number: several branches are
    # read at once, %parent names a parent that way, and unit numbers
    # repeat across drivers.
    private_class_method def self.usb_tree
        oids = USB_OIDS.map {|o| Shellwords.escape(o) }.join(' ')
        self.parse_usb_tree(`/sbin/sysctl -e #{oids} 2>/dev/null`)
    end
end

module Linux
    # See FreeBSD.probe_consoles.  Matched on the probe's vendor, not
    # on one probe firmware: an MDK's DAPLink and a DWM1001-DEV's
    # J-Link OB both report a serial and both become a ttyACM.
    def self.probe_consoles
        Dir['/sys/class/tty/ttyACM*']
            .map    {|path| self.udevadm_query(path) }
            .select {|dev| PROBE_VENDORS.include?(dev[:ID_VENDOR_ID]) }
            .to_h   {|dev| [ dev[:ID_SERIAL_SHORT], dev[:DEVNAME] ] }
    end

    def self.usb_to_tty(path)
        raise ArgumentError if path.nil?
        if (dev_path = Dir["/sys/bus/usb/devices/#{path}/**/tty/ttyACM*"]&.first)
            File.join('/dev', File.basename(dev_path))
        end
    end

    # The probe's serial, from the USB descriptor the kernel already has.
    #
    # This used to be asked of openocd, which no longer answers. 0.12.0
    # prints neither the CMSIS-DAP "Serial# =" line nor a J-Link "S/N",
    # at any debug level, and 0.12.0 is still the current release, so
    # there is no version to upgrade to. Reading the descriptor needs no
    # SWD session, no openocd, and above all no powering the rest of the
    # bench down to leave one adapter for openocd to find.
    #
    # An MDK puts its own hub in front of its DAPLink, so the probe sits
    # one level below the hub port there while a J-Link sits on it; look
    # at both, and take the first that is a probe with a serial.
    def self.usb_to_serial(path)
        raise ArgumentError if path.nil?
        base = "/sys/bus/usb/devices/#{path}"
        [ base, *Dir["#{base}.*"].sort ].each do |dev|
            next unless File.file?("#{dev}/idVendor")
            next unless PROBE_VENDORS.include?(File.read("#{dev}/idVendor").chomp)
            next unless File.file?("#{dev}/serial")
            serial = File.read("#{dev}/serial").chomp
            return serial unless serial.empty?
        end
        nil
    end

    # private on its own does nothing here: this module has no instance
    # methods, and it never applied to a def self. singleton method.
    # udevadm_query was public for as long as it has existed.
    private_class_method def self.udevadm_query(path)
        `/usr/bin/udevadm info -q property --export #{Shellwords.escape(path)}`
          .lines.to_h {|l| l.split('=', 2) }
          .transform_keys(&:to_sym)
          .transform_values {|v| Shellwords.split(v).join(' ') }
    end
end


Current = case RbConfig::CONFIG['host_os']
          when /^linux-/  then Platform::Linux
          when /^freebsd/ then Platform::FreeBSD
          else raise 'Unsupported platform'
          end


def self.probe_consoles(...)   = Current.probe_consoles(...)

# The console of the board whose probe carries this serial, or nil.
#
# Works on both platforms and needs no USB topology, which is what lets
# `connect --method serial` reach a console on a host with no
# /sys/bus/usb.
def self.serial_to_tty(serial)
    return nil if serial.nil?
    self.probe_consoles[serial.to_s]
end
# A board's USB path, from the hub port it is plugged into.
#
# +root+ is the hub's own place in the USB tree -- the node its
# sixteen sockets hang off -- which CLI#hub_usb_root works out from
# the control adapter the exsys gem reports.
#
# Nothing here is platform-specific any more, and that is the point.
# Both platforms used to derive the root themselves from the control
# LINE: Linux by pattern-matching udevadm's DEVPATH, FreeBSD by
# finding the uftdi node and walking the sysctl tree up from it.  The
# gem now reports the adapter's USB path as a public field of the
# candidate it was chosen from, so the derivation was two
# reimplementations of a thing already in hand.  What is left is the
# geometry, which belongs to the hub and not to the host.
#
# The hub is four internal banks of four, so port 16 lands on
# <root>.4.4 -- which is where the control adapter itself sits, and
# why a board must never be put on port 16.  See THE HUB in the
# manual.
def self.port_to_usb(port, root:)
    unless root.to_s.match?(ExSYS::ManagedUSB::USB_PATH)
        raise CLI::Error, "unhandled USB root (#{root})"
    end
    port_i = ((port - 1) / 4) + 1
    port_j = ((port - 1) % 4) + 1
    "#{root}.#{port_i}.#{port_j}"
end
def self.usb_to_tty(...)       = Current.usb_to_tty(...)
def self.usb_to_serial(...)    = Current.usb_to_serial(...)

end

end
