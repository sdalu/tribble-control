require_relative '../cli'

module TribeControl

class CLI
class Flash < CLI::Command
    DESCRIPTION = 'Flash devices'

    # Every board goes through openocd: check for it up front.
    OPENOCD     = true

    # 'serial' first, so it is the default (Methods.first).  'power'
    # was, and it cuts every port and re-powers one board at a time: the
    # whole bench in sequential rounds, left powered down at the end.
    # Selecting by adapter serial needs serial= on every board, which the
    # devlist now has, and it was measured on 2026-09-16 rather than
    # assumed: with all four J-Links live, a flash addressed by serial
    # landed on the board whose FICR.DEVICEID matched and left its
    # neighbours' flash byte-for-byte unchanged, and the devlist's
    # power_cycle = after-flash still fired.  'power' stays for a board
    # whose serial is missing or wrong.
    Methods  = [ 'serial', 'power' ]
    Defaults = { }
    Parser   = OptionParser.new do |opts|
        # Usage
        opts.banner = "Usage: #{PROGNAME} flash [options] FIRMWARE [PORT|DEVNAME]..."

        # Description
        opts.separator ''
        opts.separator "#{DESCRIPTION}."
        opts.separator ''

        # Options
        opts.separator 'Options:'
        opts.on '--power-cycle', 'Power the port off and on again after a',
                                 'successful flash, whatever the devlist',
                                 'says (power_cycle = after-flash)'
    end

    def flash(firmware, **hopts, &block)
        openocd('init', 'targets', 'reset init',
                "flash write_image erase #{firmware}",
                'reset run', **hopts)
    end
    
    def run(argv, **opts)
        firmware = argv.shift
        tty&.info "Firmware: #{firmware}"

        each_device(argv).map do |name, hopts={}|
            flash(firmware, **hopts).tap do |ok|
                if ok
                then tty&.success "Device #{name}: Flashed"
                else tty&.error   "Device #{name}: Flashed failed"
                end
                # A DWM1001-DEV comes out of the openocd flash sequence
                # (reset init, write, reset run) in a state where its DW1000
                # never reports a transmission again until the module is
                # power-cycled: it receives, resolves nothing, and logs
                # "our TX timestamps are missing".  An SWD reset alone does
                # not do it, so only the flash needs the cycle.  The devlist
                # says which boards need it (power_cycle = after-flash), so
                # a flash by hand on the hub gets it right; --power-cycle
                # forces it for any board.
                if ok && (opts[:'power-cycle'] ||
                          @cli.power_cycle?(name, 'after-flash'))
                    _, port = @cli.name_port(name)
                    if offable?(port)
                        tty&.info "Device #{name}: power-cycling after flash"
                        exsys.off(port); sleep(2); exsys.on(port)
                    else
                        # Saying it plainly matters: a DWM1001 that misses
                        # its cycle comes out of the flash with a DW1000
                        # that reports no transmission, which looks like a
                        # radio fault rather than a skipped step.
                        tty&.warn "Device #{name}: NOT power-cycling," \
                                  " the devlist protects port #{port}." \
                                  ' The board may be in the state' \
                                  ' power_cycle exists to avoid'
                    end
                end
            end
        end.all?(&:itself)
    end
end
end

end
