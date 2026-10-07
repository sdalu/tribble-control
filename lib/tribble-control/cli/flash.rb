require_relative '../cli'

module TribbleControl

class CLI
class Flash < CLI::Command
    DESCRIPTION = 'Flash devices'

    # Every board goes through openocd: check for it up front.
    OPENOCD     = true

    # 'serial' first, so it is the default (Methods.first): boards stay
    # powered and are flashed in parallel.  It needs serial= on every
    # board, and it was measured on 2026-09-16 rather than assumed: with
    # all four J-Links live, a flash addressed by serial landed on the
    # board whose FICR.DEVICEID matched and left its neighbours' flash
    # byte-for-byte unchanged, and power_cycle = after-flash still
    # fired.  'power' -- every port cut, one board powered at a time,
    # the bench left off -- is for a board whose serial is missing or
    # wrong.
    Methods  = [ 'serial', 'power' ]
    Defaults = {}
    Parser   = OptionParser.new do |opts|
        opts.banner = "Usage: #{PROGNAME} flash [options] FIRMWARE [PORT|DEVNAME]..."

        opts.separator ''
        opts.separator "#{DESCRIPTION}."
        opts.separator ''

        opts.separator 'Options:'
        opts.on '--power-cycle', 'Power the port off and on again after a',
                                 'successful flash, whatever the configuration',
                                 'says (power_cycle = after-flash)'
    end

    def flash(firmware, **hopts)
        openocd('init', 'targets', 'reset init',
                "flash write_image erase #{firmware}",
                'reset run', **hopts)
    end

    def run(argv, **opts)
        firmware = argv.shift
        # Checked before any port is switched, not left to openocd once
        # per board -- under --method power, after the whole bench has
        # been cut.  openocd resolves the path against the current
        # directory, as File.file? does.
        raise Error, 'flash: FIRMWARE missing' if firmware.nil?
        unless File.file?(firmware) && File.readable?(firmware)
            raise Error, "flash: no readable firmware file '#{firmware}'"
        end
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
                # not do it, so only the flash needs the cycle.  The configuration
                # says which boards need it (power_cycle = after-flash), so
                # a flash by hand on the hub gets it right; --power-cycle
                # forces it for any board.
                if ok && (opts[:'power-cycle'] ||
                          @cli.power_cycle?(name, 'after-flash'))
                    _, port = @cli.name_port(name)
                    if !hub.vbus?
                        # Cutting the link would only re-enumerate the
                        # probe; the board would keep the very state
                        # the cycle exists to clear.  Skip it and say
                        # so, in the same words as the protected case.
                        tty&.warn "Device #{name}: NOT power-cycling," \
                                  " #{hub} cuts the link, not the power" \
                                  " (#{CLI::SWITCH_KEY} = link).  The board" \
                                  ' may be in the state power_cycle' \
                                  ' exists to avoid'
                    elsif offable?(port)
                        tty&.info "Device #{name}: power-cycling after flash"
                        hub.off(port); sleep(2); hub.on(port)
                    else
                        # Saying it plainly matters: a DWM1001 that misses
                        # its cycle comes out of the flash with a DW1000
                        # that reports no transmission, which looks like a
                        # radio fault rather than a skipped step.
                        tty&.warn "Device #{name}: NOT power-cycling," \
                                  " the configuration protects port #{port}." \
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
