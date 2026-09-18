require_relative '../cli'

module TribbleControl

class CLI
class USB < CLI::Command
    DESCRIPTION = 'USB hub control'

    # What 'set' accepts on the right of the colon.  The hub does not
    # see these words: they are read here into true and false.
    ON_WORDS  = %w[1 on ON true TRUE t T].freeze
    OFF_WORDS = %w[0 off OFF false FALSE f F].freeze

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
            # tribble-control is allowed to switch before you switch it.
            state = hub.state
            named = devices.to_h {|n| [ port_list([ n ]).first, n ] }
            safe  = begin
                        switchable
                    rescue Error
                        []
            end
            state.each do |port, on|
                puts format('%2d  %-6s %-3s %s', port, named[port] || '-', on ? 'on' : 'off',
safe.include?(port) ? '' : '(protected)')
            end
        when 'on'
            # Powering up is always safe: no guard.
            ports = port_list(argv)
            # Every port, named outright: an empty list never reaches
            # the hub meaning "all".
            if ports.empty?
            then tty&.info "Turning on all ports"
                 hub.on(*hub.ports)
            else tty&.info "Turning on ports: #{ports.join(' ')}"
                 hub.on(*ports)
            end
        when 'off'
            ports = offable(port_list(argv), force: force)
            tty&.info "Turning off ports: #{ports.join(' ')}"
            hub.off(*ports)
            warn_link_only(ports)
        when 'toggle'
            # Toggle can power a port down, so it is guarded like 'off'.
            ports = offable(port_list(argv), force: force)
            tty&.info "Toggling ports: #{ports.join(' ')}"
            hub.toggle(*ports)
            warn_link_only(ports)
        when 'set'
            words = (ON_WORDS + OFF_WORDS).map {|w| Regexp.escape(w) }
            a = argv.to_h {|e|
                unless e =~ /^([^:]+):(#{words.join('|')})$/
                    raise Error, "invalid argument (#{e})"
                end
                [ port_list([ $1 ]).first, ON_WORDS.include?($2) ]
            }

            # Vet the ports being powered down.
            offable(a.reject {|_,on| on }.keys, force: force)

            # A false default would sweep every unnamed port off, the
            # protected ones included.  Expand it over the switchable
            # ports instead, and leave the rest as they are.
            default = opts[:default]
            if (default == false) && !force
                (switchable - a.keys).each {|p| a[p] = false }
                default = nil
            end

            tty&.info "Applying port configuration:" \
                      " #{a.map {|p, on| "#{p}:#{on ? 'on' : 'off'}" }.join(' ')}" \
                      " (default=#{default&.to_s || 'current'})"
            hub.set(a, default)
            offs = a.reject {|_, on| on }.keys
            offs = hub.ports - a.keys + offs if default == false
            warn_link_only(offs.sort) unless offs.empty?
        when nil   then raise Error, 'usb: action missing'
        else            raise Error, "usb: unknown action (#{action})"
        end
    end
end
end

end
