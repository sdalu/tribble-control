require_relative '../cli'

module TribeControl

class CLI
class USB < CLI::Command
    DESCRIPTION = 'USB hub control'

    Defaults = { :default => nil }
    Parser   = OptionParser.new do |opts|
        # Usage
        opts.banner = "Usage: #{PROGNAME} usb [options]" \
                      " status|on|off|toggle|set [PORTS...]"

        # Description
        opts.separator ''
        opts.separator "#{DESCRIPTION}."
        opts.separator ''

        # Options
        opts.separator 'Options:'
        opts.on '-D', '--default=BOOLEAN', TrueClass,
                      'Default state if not specified'
    end

    def run(argv, **opts)
        force = opts[:force]

        case action = argv.shift
        when 'status'
            # Read-only: asks the hub for its port mask and prints it
            # next to the devlist, so you can see what is on and what
            # tribe-control is allowed to switch before you switch it.
            state = exsys.get(:ports)
            named = devices.to_h {|n| [ port_list([ n ]).first, n ] }
            safe  = begin
                        switchable
                    rescue Error
                        []
                    end
            state.each do |port, on|
                puts '%2d  %-6s %-3s %s' % [
                    port, named[port] || '-', on ? 'on' : 'off',
                    safe.include?(port) ? '' : '(protected)' ]
            end
        when 'on'
            # Powering up is always safe: no guard.
            ports = port_list(argv)
            if ports.empty?
            then tty&.info "Turning on all ports"
                 exsys.on
            else tty&.info "Turning on ports: #{ports.join(' ')}"
                 exsys.on(*ports)
            end
        when 'off'
            ports = offable(port_list(argv), force: force)
            tty&.info "Turning off ports: #{ports.join(' ')}"
            exsys.off(*ports)
        when 'toggle'
            # Toggle can power a port down, so it is guarded like 'off'.
            ports = offable(port_list(argv), force: force)
            tty&.info "Toggling ports: #{ports.join(' ')}"
            exsys.toggle(*ports)
        when 'set'
            tl = ExSYS::ManagedUSB::TRUE_LIST
            fl = ExSYS::ManagedUSB::FALSE_LIST
            t  = tl.to_h {|e| [ e.to_s, e ]}
            f  = fl.to_h {|e| [ e.to_s, e ]}
            tf = t.merge(f) { raise "true/false conflict (internal error)" }
            r  = tf.keys.map {|e| Regexp.escape(e)}
            a = argv.to_h {|e|
                unless e =~ /^([^:]+):(#{r.join('|')})$/
                    raise Error, "invalid argument (#{e})"
                end
                [ port_list([$1]).first, tl.include?(tf[$2]) ? :on : :off ]
            }

            # Vet the ports being powered down.
            offable(a.select {|_,s| s == :off }.keys, force: force)

            # A false default would sweep every unnamed port off, the
            # reserved ones included.  Expand it over the switchable
            # ports instead, and leave the rest as they are.
            default = opts[:default]
            if (default == false) && !force
                (switchable - a.keys).each {|p| a[p] = :off }
                default = nil
            end

            tty&.info "Applying port configuration:" \
                      " #{a.map { _1.join(':') }.join(' ')}" \
                      " (default=#{default&.to_s || 'current'})"
            exsys.set(a, default)
        when nil   then raise Error, 'usb: action missing'
        else            raise Error, "usb: unknown action (#{action})"
        end
    end
end
end

end
