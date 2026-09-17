require_relative '../cli'

module TribeControl

class CLI
class Reset < CLI::Command
    DESCRIPTION = 'reset devices'

    # Every board goes through openocd: check for it up front.
    OPENOCD     = true

    Methods  = [ 'serial' ]
    Defaults = {}
    Parser   = OptionParser.new do |opts|
        # Usage
        opts.banner = "Usage: #{PROGNAME} reset [options] [PORT|DEVNAME]..."

        # Description
        opts.separator ''
        opts.separator "#{DESCRIPTION}."
        opts.separator ''
    end

    def reset(**hopts)
        openocd('init', 'targets', 'reset run', **hopts)
    end

    def run(argv, **_opts)
        each_device(argv).map do |name, hopts={}|
            reset(**hopts).tap do |ok|
                if ok
                then tty&.success "Device #{name}: Reseted"
                else tty&.error   "Device #{name}: Reset failed"
                end
            end
        end.all?(&:itself)
    end
end
end

end
