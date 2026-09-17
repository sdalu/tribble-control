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
    Methods  = [ 'usb' ]
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
        Platform.usb_to_serial(hopts[:usb])
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
