#
# Host-specific ways of finding the hub, the probes and the consoles.
#
require 'rbconfig'
require 'shellwords'
require 'exsys/managed-usb'

module TribeControl

#
# Sysctl quick parsing
#
module Platform
module FreeBSD
    def self.exsys_ctrl
        self.sysctl('dev.uftdi').select {|k, v|
            v.dig(:'%pnpinfo') in { vendor: "0x0403", product: "0x6001" }
        }.map { |k, dev| '/dev/tty' + dev.dig(:ttyname) }
    end

    # The three that are Linux-only, and why they are stubbed rather
    # than absent.
    #
    # All three read /sys/bus/usb, which FreeBSD does not have, so
    # --method usb -- and therefore 'connect', which has no other
    # method -- has never worked on a FreeBSD host.  Leaving them
    # undefined made that arrive as
    #
    #     undefined method 'port_to_usb' for module
    #     TribeControl::Platform::FreeBSD
    #
    # which names an internal and tells the reader nothing about what
    # to do.  Only usb_to_serial used to be stubbed, while the comment
    # above it claimed all three were; observed on FreeBSD 15 on
    # 2026-09-17, 'connect' still died with the NoMethodError.  Each
    # one now says which piece is missing and what still works.
    # Which commands that leaves: the two that select with --method
    # usb are out, and they are 'serial' and 'connect'.  Not 'serial
    # works here', which the manual claimed until this was run on a
    # FreeBSD host: 'serial' accepts the usb method and no other, so it
    # reaches the same dead end 'connect' does.
    LINUX_ONLY = 'is implemented for Linux only: it reads /sys/bus/usb,' \
                 ' which this host does not have.  usb, flash and reset' \
                 ' work here; serial and connect do not, both selecting' \
                 ' devices with --method usb'

    def self.port_to_usb(_port, root: nil)
        raise CLI::Error, "deriving a board's USB path from its hub port" \
                          " #{LINUX_ONLY}"
    end

    def self.usb_to_tty(_path)
        raise CLI::Error, "finding a board's console from its USB path" \
                          " #{LINUX_ONLY}"
    end

    def self.usb_to_serial(_path)
        raise CLI::Error, 'reading a probe serial from the USB descriptor' \
                          " #{LINUX_ONLY}"
    end

    def self.daplink_mapping
        self.sysctl('dev.umodem').select {|k, v|
            v.dig(:'%pnpinfo') in { vendor: "0x0d28", product: "0x0204" }
        }.to_h {|k, dev|
            [ dev.dig(:'%pnpinfo', :sernum), '/dev/tty' + dev.dig(:ttyname) ] 
        }
    end

    # Defined on the module, not as an instance method: every caller is
    # a def self. above, so an instance method was unreachable and hub
    # auto-detection died with NoMethodError before reading a single
    # sysctl. private_class_method keeps it internal, which is what the
    # bare private was reaching for and could not express.
    private_class_method def self.sysctl(key)
        `/sbin/sysctl -e -a #{key}`.lines.map(&:chomp).reduce({}) {|acc, l|
            k, v  = l.split('=', 2)
            i, sk = k.split('.')[2..]
            next acc if sk.nil?
            if [ '%pnpinfo', '%location' ].include?(sk)
                v = Shellwords.shellsplit(v).to_h {|e| e.split('=', 2) }
                              .transform_keys(&:to_sym)
            end
                
            acc.merge(Integer(i) => {sk.to_sym => v}) {|k,o,n| o.merge(n) }
        }
    end
end


module Linux
    def self.exsys_ctrl
        Dir['/sys/class/tty/ttyUSB*']
            .map    {|path| self.udevadm_query(path) }
            .select {|dev| dev in {ID_VENDOR_ID: '0403', ID_MODEL_ID: '6001'} }
            .map    {|dev| dev[:DEVNAME] }
    end

    # DAPLink consoles by probe serial.  Matched on the mbed VID:PID
    # (0d28:0204), which is the probe firmware's and not any one board
    # family's -- an MDK and anything else carrying DAPLink both answer
    # to it.
    def self.daplink_mapping
        Dir['/sys/class/tty/ttyACM*']
            .map    {|path| self.udevadm_query(path) }
            .select {|dev| dev in {ID_VENDOR_ID: '0d28', ID_MODEL_ID: '0204'} }
            .to_h   {|dev| [ dev[:ID_SERIAL_SHORT], dev[:DEVNAME] ] }
    end

    def self.port_to_usb(port, root:)
        # USB ExSYS hub path
        case root
        when %r{^/dev/(\w+)}
            tty = $1
            unless self.udevadm_query(root)[:DEVPATH]
                       .split(File::SEPARATOR) in [ *, root, _, _, _, ^tty, 'tty', ^tty]
                raise CLI::Error, "unable to identify USB path for #{root}"
            end
        when %r{^\d+-\d+(?:\.\d+)*$} # USB path root
        else raise CLI::Error, "unhandled USB root (#{root})"
        end

        # ExSYS USB hub is a 4x4 ports
        port_i = (port-1) / 4 + 1
        port_j = (port-1) % 4 + 1
        
        # Path
        "#{root}.#{port_i}.#{port_j}"
    end
    
    def self.usb_to_tty(path)
        raise ArgumentError if path.nil?
        if dev_path = Dir["/sys/bus/usb/devices/#{path}/**/tty/ttyACM*"]&.first
            File.join('/dev', File.basename(dev_path))
        end
    end

    # Vendor ids of the debug probes this bench carries: NXP/mbed for the
    # DAPLink (as carried by the bench's nRF52840-MDKs), SEGGER for a
    # J-Link OB (as on a DWM1001-DEV).
    PROBE_VENDORS = %w[0d28 1366].freeze

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


def self.exsys_ctrl(...)       = Current.exsys_ctrl(...)
def self.daplink_mapping(...) = Current.daplink_mapping(...)
def self.port_to_usb(...)      = Current.port_to_usb(...)
def self.usb_to_tty(...)       = Current.usb_to_tty(...)
def self.usb_to_serial(...)    = Current.usb_to_serial(...)

end

end
