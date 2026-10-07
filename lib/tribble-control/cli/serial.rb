require_relative '../cli'

module TribbleControl

class CLI
class Serial < CLI::Command
    DESCRIPTION = "Report a debug probe's serial number"

    # usb first, so it is the default: it reads the USB descriptor of
    # one named board and disturbs nothing else.  Asking a board which
    # serial it has should not black out the bench.
    #
    # power needs no USB topology.  It identifies a board by its being
    # the only one powered -- the probe on it is then the only probe
    # present, and reports its own serial -- at the cost of a power
    # cycle of the whole bench, left off; see DEVICE SELECTION.
    Methods  = [ 'usb', 'power' ]
    Defaults = {}
    Parser   = OptionParser.new do |opts|
        opts.banner = "Usage: #{PROGNAME} serial [options] [PORT|DEVNAME]..."

        opts.separator ''
        opts.separator "#{DESCRIPTION}."
        opts.separator ''
    end

    def get_serial(**hopts)
        return Platform.usb_to_serial(hopts[:usb]) if hopts[:usb]

        # --method power: this board is the only one powered, so the
        # only probe enumerated is its own.  each_device has already
        # refused more than one (CLI#only_probe!); the case below is
        # the same rule kept where the answer is read.
        probes = Platform.probe_consoles.keys
        case probes.size
        when 1 then probes.first
        when 0 then nil
        else
            raise Error, "#{probes.size} probes are powered, so none of" \
                         ' them can be attributed to this board:' \
                         " #{probes.map {|p| p[0, 12] }.join(', ')}." \
                         ' A probe on a port the configuration protects will' \
                         ' do this; read it on Linux with --method usb'
        end
    end

    def run(argv, **_opts)
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
