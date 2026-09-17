require_relative '../cli'

module TribeControl

class CLI
class Serial < CLI::Command
    DESCRIPTION = 'Serial device'

    # 'usb' only, and that is the point of the rewrite.  This command
    # used to run openocd, which cannot choose between several adapters
    # ("Multiple devices found, specify the desired device"), so it had
    # to select with 'power': every port off, one back on, for each
    # board in turn.  Asking a board which serial it has should not
    # black out the bench, and reading the USB descriptor does not.
    # usb first, so it stays the default where it works: it reads the
    # descriptor of one named board and disturbs nothing else.
    #
    # power is the one that needs no USB topology, and so the one a
    # FreeBSD host can use.  It identifies a board by being the only
    # one powered, which is what this command needs and all it needs --
    # the probe on that board is then the only probe present, and it
    # reports its own serial.  It costs a power cycle of the whole
    # bench and leaves it off; see DEVICE SELECTION.
    Methods  = [ 'usb', 'power' ]
    Defaults = { }
    Parser   = OptionParser.new do |opts|
        # Usage
        opts.banner = "Usage: #{PROGNAME} serial [options] [PORT|DEVNAME]..."

        # Description
        opts.separator ''
        opts.separator "#{DESCRIPTION}."
        opts.separator ''
    end

    def get_serial(**hopts)
        return Platform.usb_to_serial(hopts[:usb]) if hopts[:usb]

        # --method power: this board is the only one powered, so the
        # only probe enumerated is its own.  More than one means the
        # premise is false -- a probe on a port the devlist protects
        # stays powered whatever we do -- and the honest answer is to
        # say so rather than pick one and call it this board's.
        probes = Platform.probe_consoles.keys
        case probes.size
        when 1 then probes.first
        when 0 then nil
        else
            raise Error, "#{probes.size} probes are powered, so none of" \
                         ' them can be attributed to this board:' \
                         " #{probes.map {|p| p[0, 12] }.join(', ')}." \
                         ' A probe on a port the devlist protects will' \
                         ' do this; read it on Linux with --method usb'
        end
    end
    
    def run(argv, **opts)
      each_device(argv).map do |name, hopts={}|
            case serial = get_serial(**hopts)
            when String then tty&.success "Serial for #{name}: #{serial}"
            when nil    then tty&.warn    "No serial for #{name}"
            else             tty&.error   "Accessing #{name} failed"
            end
            serial.is_a?(String)
        end.all?(&:itself)
    end
end
end

end
