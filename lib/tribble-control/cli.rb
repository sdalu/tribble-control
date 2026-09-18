#
# The command line: global options, the device list, and the machinery
# every command uses to reach a board (each_device, openocd).
#
require 'optparse'
require 'shellwords'
require 'forwardable'
require 'open3'
require 'ucl'
require 'tty/logger'
require 'parallel'

require_relative 'version'
require_relative 'platform'
require_relative 'hub/exsys'

module TribbleControl

class CLI
    # Command line error reporting
    class Error < StandardError
    end

    # Command class inheritance
    class Command
        extend Forwardable

        def_delegators :@cli, :hub, :tty, :conf, :openocd, :each_device,
                              :port_list, :switchable, :offable, :offable?,
                              :devices, :tally, :warn_link_only

        # Derive command name from class
        def self.cmdname
            if self.const_defined?(:NAME)
                self::NAME
            else
                self.name.split('::')[-1]
                    .gsub(/([A-Z]+)([A-Z][a-z])/, '\1-\2')
                    .gsub(/([a-z\d])([A-Z])/,     '\1-\2')
                    .downcase
            end
        end

        # Initializer
        def initialize(cli)
            @cli  = cli
        end
    end

    # devlist block gathering everything that keeps a port powered.
    #
    # Two rules, one key.  'undeclared' says whether a port the file
    # does not mention is protected -- yes, the default, is what keeps
    # a power feed out of reach of a bare 'usb off' -- and 'ports' and
    # 'nodes' name the ones protected whichever way that falls, which
    # is how a port that IS declared is kept powered anyway.
    #
    # 'ports' takes port numbers and 'nodes' the names of devlist
    # entries, which is the same protection said two ways.  A name is
    # the better one where there is an entry to name: it survives the
    # board moving socket, and it cannot go on protecting port 12 after
    # port 12 became something else.  'ports' remains for what has no
    # entry -- a power feed nothing drives, which is most of what ends
    # up here.
    #
    # They were two top-level keys, 'undeclared' and 'reserved', which
    # left 'protected' -- the word 'usb status' prints, and the one the
    # manual gives a section to -- naming neither of them.  One key is
    # what the docs already called the pair, and the whole policy is
    # then read in one place rather than in two lines that have to be
    # found first.
    PROTECT_KEY            = 'protect'
    PROTECT_UNDECLARED_KEY = 'undeclared'
    PROTECT_PORTS_KEY      = 'ports'
    PROTECT_NODES_KEY      = 'nodes'
    PROTECT_KEYS           = [ PROTECT_UNDECLARED_KEY, PROTECT_PORTS_KEY,
                               PROTECT_NODES_KEY ].freeze

    # What the block replaced, and how each is written now.
    #
    # A devlist from before the change is met with its new spelling.
    # Without this 'reserved' falls through to the device pass and is
    # refused as "devlist entry 'reserved' has no port" -- true, and no
    # help at all, since the port line it asks for would load the file
    # and leave every port it named switchable.
    PROTECT_FORMER = {
        'reserved'   => "#{PROTECT_KEY} { #{PROTECT_PORTS_KEY} = [ ... ] }",
        'undeclared' => "#{PROTECT_KEY} { #{PROTECT_UNDECLARED_KEY} = yes|no }"
    }.freeze

    # Shared settings a device can inherit, and the key that asks for
    # them.
    #
    # A bench is usually a handful of boards of two or three kinds, and
    # what a kind is -- which probe, which chip, which transport, what
    # speed its console runs at -- is the same on every one of them.
    # Written per device that is four identical lines eleven times, and
    # the reader has to compare them to find the one that differs.  A
    # type says it once.
    #
    # One level only: a type is a block of settings, not a thing that
    # can itself have a type.  Identity is not inheritable either --
    # see TYPE_FORBIDDEN.
    TYPES_KEY      = 'types'
    TYPE_KEY       = 'type'

    # What a type may not carry.  Both name one particular board: a
    # port is where a single board is plugged in, and a serial is one
    # physical probe.  A type that set either would be saying that
    # every board of that kind is the same board.
    TYPE_FORBIDDEN = [ 'port', 'serial' ].freeze

    # Top-of-file devlist key: the serial line of the hub this file
    # describes.
    #
    # A devlist is one bench, and a bench is one hub, so the file that
    # says which board is on which port is the right place to say which
    # hub those ports belong to.  Without it, a host with two hubs
    # plugged in has to be told twice -- -d for the line, -D for the
    # map -- and the two are then free to disagree: -D says bench two
    # and -d, or the auto-detection, says the first FTDI adapter the
    # host happens to enumerate.  With it, -D alone selects a bench.
    #
    # -d still wins, for the one-off: a hub that has moved, or a line
    # reached through something other than the usual node.
    #
    # The value is an FT232 serial, a USB path (1-1.2.4.4), or a device
    # node when it has a '/' in it.  See Hub::ExSYS.open for which to
    # write in a file that gets deployed, and why the node is the wrong
    # one.
    DEVICE_KEY     = 'device'

    # Top-of-file devlist key: which KIND of hub the file describes.
    #
    # 'exsys', the default, is the ExSYS managed hub over its FT232
    # line; 'usb' is a standard hub with per-port power switching,
    # reached through the host's own USB stack.  See Hub::KINDS.  The
    # kind cannot be read off the DEVICE_KEY value -- a USB path names
    # an FT232's socket for the one and the hub itself for the other --
    # so it has to be said.
    HUB_KEY        = 'hub'
    HUB_DEFAULT    = 'exsys'

    # Top-of-file devlist key, for hub = usb only: what that hub's
    # switch does.  'link', the default, takes the port off the bus and
    # leaves the board powered; 'vbus' cuts the socket's power.
    # Software cannot tell the two apart -- the device vanishes and
    # returns either way -- so the operator says which, having watched
    # a board's LED during 'usb off'.  See Hub#vbus?.  The ExSYS hub
    # always cuts power, so the key is refused with it rather than
    # ignored: a line that changes nothing is a line somebody will
    # trust.
    SWITCH_KEY     = 'switch'
    SWITCHES       = [ :link, :vbus ].freeze

    # Which tally reads the consoles.  Recognised at the top of the
    # file, where it sets the bench's default, and inside a device,
    # where it overrides it for that board.  See Tally.
    TALLY_KEY      = 'tally'
    TALLY_DEFAULT  = 'lines'

    # Per-device devlist key: which hub port the board is on.
    #
    # Required on every device entry, and 'port = none' is how an entry
    # says it is a record rather than a board on the bench.  Such an
    # entry stays in the file -- its serial is worth keeping, and so is
    # the comment saying when it stopped enumerating -- but tribble-control
    # leaves it out of #devices, so it is never selected, never switched
    # and never flashed.
    #
    # The port is the whole of it, deliberately: there is no separate
    # 'present' or 'enabled' key.  Everything this tool can do to a board
    # it does by hub port, so an entry without one is not addressable by
    # definition, and a second key saying the same thing is a second key
    # to disagree with the first.  'enabled' in particular would have
    # read as "leave this port off", which is a different thing and one
    # 'usb off' already does.
    #
    # Missing is an error rather than a synonym for none.  Deleting the
    # port line is exactly what happens when a port is reassigned to
    # another board, and inferring "gone" from a line somebody forgot
    # would drop a live board silently.
    PORT_KEY       = 'port'
    PORT_NONE      = [ nil, 'none', 'null', '-' ].freeze

    # Parser
    Defaults     = { :'warm-up' => 5,
                     :openocd   => '/usr/bin/openocd' }
    GlobalParser = OptionParser.new do |opts|
        opts.banner = "Usage: #{opts.program_name} ACTION"

        opts.separator ''
        opts.separator 'Global options:'

        opts.on '-d', '--device=DEV',   'Which hub: its serial number, a',
                                        '  USB path, or its device node if',
                                        '  it has a / in it'
        opts.on       '--hub=KIND', Hub::KINDS.keys,
                'Which kind of hub: exsys (default) or usb'
        opts.on '-p', '--password=STRING', 'ExSYS hub password'
        opts.on '-D', '--devlist=FILE',    'Device list file'
        opts.on '-m', '--method=TYPE', [ 'power', 'usb', 'serial' ],
                'Device selection method',
                '  Available: power, usb, serial'
        opts.on '-W', '--warm-up=SECONDS', Integer,
                'Warm-up delay after power on'
        opts.on       '--openocd=PATH',    'openocd path'
        opts.on '-r', '--require=FILE', Array,
                'Ruby file(s) to load first, for the tallies',
                '  they register (comma-separated)'
        opts.on '-F', '--force',           'Switch protected ports too'
        opts.on       '--debug[=FILE]', 'Show debug output, and copy',
                                       'the whole log to FILE if given'
        opts.on '-v', '--[no-]verbose',    'Run verbosely'
        opts.on '-V', '--version',         'Version' do
            puts "tribble-control : #{TribbleControl::VERSION}"
            puts "ExSYS library : #{ExSYS::VERSION}"
            exit
        end


        # Options
        opts.separator ''
        opts.separator 'Informative options:'
        opts.on '-h', '--help',         "Show this message" do
            puts opts
            puts ''
            puts 'Commands:'
            CLI.commands.each_value {|klass|
                puts format('    %-12s %s', klass.cmdname, klass::DESCRIPTION)
            }
            puts ''
            puts "See '#{opts.program_name} CMD --help'"                \
                 " for more information on a specific command"
            puts "See '#{opts.program_name} --man'"                     \
                 " for the manual"
            puts ''
            exit
        end
        opts.on '--man',                "Show the manual" do
            CLI.show_manual
            exit
        end
    end

    # Where the manual lives.  It sat after __END__ while tribble-control
    # was a single script; lib/ is required rather than run, so DATA is
    # not defined there and the page is a file shipped beside the code.
    #
    # man/man1/ rather than man/: that shape is a MANPATH entry as it
    # stands, so `MANPATH=<gem>/man man tribble-control` works on an
    # installed gem without anything having to be copied anywhere.
    MANUAL = File.expand_path('../../man/man1/tribble-control.1', __dir__)

    # How to turn that page into text, in the order they are tried.
    # mandoc first: it reads the UTF-8 the diagrams are drawn in without
    # being told to, and it is what the BSDs ship.  groff needs -Kutf8
    # to do the same, and a bare nroff is the last resort -- on a host
    # whose locale is not UTF-8 it will mangle the box drawing, which is
    # still better than refusing to print the manual.
    RENDERERS = [ %w[mandoc -Tutf8],
                  %w[groff -Kutf8 -Tutf8 -mandoc],
                  %w[nroff -mandoc] ].freeze

    # groff and nroff mark bold with ANSI colour escapes by default,
    # mandoc with backspace overstrike.  Overstrike is the one a bare
    # `less` renders as bold rather than printing raw, and the one that
    # strips back to plain text in a single substitution, so ask the
    # groff family for it and keep all three renderers alike.
    RENDER_ENV = { 'GROFF_NO_SGR' => '1' }.freeze

    # The rendered page, or nil when nothing on this host can render it.
    def self.render_manual
        RENDERERS.each do |cmd|
            begin
                out, status = Open3.capture2(RENDER_ENV, *cmd, MANUAL)
            rescue Errno::ENOENT
                next            # that renderer is not installed
            end
            return out if status.success? && !out.empty?
        end
        nil
    end

    # Display the manual, paging it when the output is a terminal.  A
    # missing file or a host with no renderer says so, rather than dying
    # on Errno::ENOENT from somewhere inside the pager.
    def self.show_manual
        unless File.readable?(MANUAL)
            raise CLI::Error, "no manual found (#{MANUAL})"
        end
        unless (text = self.render_manual)
            raise CLI::Error, 'no manual page renderer found (tried' \
                              " #{RENDERERS.map(&:first).join(', ')}):" \
                              " read #{MANUAL} directly"
        end
        pager = ENV['PAGER'] || 'less'
        if $stdout.tty? && !pager.empty?
            begin
                IO.popen(pager, 'w') {|io| io.write(text) }
                return
            rescue Errno::ENOENT, Errno::EPIPE
                # No such pager, or the reader quit early: fall through.
            end
        end
        # Not a terminal: strip the backspace overstrike nroff uses for
        # bold and underline, so that a pipe, a file or a grep sees the
        # words themselves.  A pager gets it unstripped, above, because
        # that is what it renders as bold.
        $stdout.write(text.gsub(/.\x08/, '').gsub(/\e\[[0-9;]*m/, ''))
    rescue Errno::EPIPE
        # Output closed (head, a quit pager): nothing left to say.
    end

    PROGNAME = GlobalParser.program_name

    # Command list
    def self.commands
        CLI::Command.subclasses.to_h {|k| [ k.cmdname, k ] }
    end

    # Find the command class corresponding to the name.
    def self.find_command_class(name)
        self.commands.find {|n,_k| n == name }&.last
    end

    # Run the command line
    #
    # Commands that report per-device success (flash, reset, serial)
    # return false if any device failed; that becomes exit status 1.
    # Hub::Error is in the list because the hub layer is ours to report
    # on, not to leak: a backend raises it both for a hub that refuses
    # a command (E01 on a wrong password) and for a host it cannot look
    # for a hub on (no udevadm, an unsupported platform).  Both are
    # operator errors with nothing to debug, and both used to reach
    # exe/tribble-control's catch-all instead -- which prints the same
    # line, so nothing was visibly wrong, but it is the net under the
    # trapeze and not the trapeze.  A library caller of CLI.run got the
    # backtrace.
    def self.run(argv = ARGV)
        self.new.parse(argv).run.tap {|ok| exit 1 if ok == false }
    rescue OptionParser::InvalidArgument, CLI::Error, Hub::Error => e
        warn "#{PROGNAME}: #{e}"
        exit 1
    end

    # The hub, once parse has settled which one: the object every
    # command switches ports through.  See Hub.
    attr_reader :hub
    attr_reader :tty
    attr_reader :conf

    # The hub's control line, once parse has settled which it is: what
    # -d named, or what the devlist's 'device' line named, or the one
    # the host was found to have.
    attr_reader :device

    # Initializer
    def initialize
        @device             = nil
        @hub_kind           = HUB_DEFAULT
        @switch             = nil
        @devlist            = nil
        @protect_ports      = []
        @protect_nodes      = []
        @protect_undeclared = true
        @tally_default      = TALLY_DEFAULT
        @types              = {}
        # :info, not :debug.  This was built at :debug, which made
        # --debug a flag that changed nothing -- the openocd command
        # lines it is supposed to reveal were printed on every run
        # whether it was given or not.
        @tty     = TTY::Logger.new do |config|
            config.level = :info
        end
    end

    # Translate a port/name to a port identier
    def name_port(id)
        case id
        when /^\d+$/
            port = Integer(id)
            if (name = @devlist.find {|_k,v| v.dig('port') == port }&.first)
                [ name, port ]
            end
        else
            name = id
            # Say which of the two it is.  "id not found" for a name that
            # is in the file, and deliberately so, sends the reader to
            # look for a typo that is not there.
            if @devlist&.key?(id) && !self.present?(id)
                raise Error, "device '#{id}' is not on the bench: the" \
                             " devlist gives it #{PORT_KEY} = none"
            end
            if (port = @devlist.find {|k,_v| k == id }&.last&.dig('port'))
                [ name, port ]
            end
        end.tap do |v|
            raise KeyError, "id not found (#{id}:#{id.class})" if v.nil?
        end
    end

    # Translate a port/name to a device serial number
    def serial(id)
        return nil if @devlist.nil?
        case id
        when Integer
            @devlist.find {|_k,v| v.dig('port') == id }&.last&.dig('serial')
        when String
            @devlist.find {|k,_v| k == id }&.last&.dig('serial')
        else raise "unsupported id (#{id})"
        end
    end

    # Read an arbitrary key of a device (by port number or name)
    #
    # The default applies when the key is ABSENT, not when it is falsey.
    # This used to end `entry&.dig(key) || default`, which handed back
    # the default for a key explicitly set to false: 'present = false'
    # read as present, and so would 'power_cycle = false'. A key that is
    # there means what it says.
    def attribute(id, key, default = nil)
        return default if @devlist.nil?
        entry = case id
                when Integer then @devlist.find {|_k,v| v.dig('port') == id }&.last
                when String  then @devlist.find {|k,_v| k == id }&.last
                else raise "unsupported id (#{id})"
                end
        return default if entry.nil?
        return entry[key] if entry.key?(key)

        # Then the type, if it named one.  The entry wins: a type is
        # what a kind of board has in common, and a device that says
        # otherwise is saying it about itself.
        if (name = entry[TYPE_KEY])
            type = @types[name.to_s]
            return type[key] if type&.key?(key)
        end

        default
    end

    # openocd interface script for a board, without the .cfg: cmsis-dap
    # (a DAPLink probe, the default) or jlink (a J-Link OB, as on the
    # DWM1001-DEV)
    def interface(id)
        self.attribute(id, 'interface', 'cmsis-dap').to_s
    end

    # openocd target script for a board, without the .cfg.
    #
    # The whole bench is nRF52 today, which is why that is the default
    # and no existing devlist has to say so.  It is a key rather than a
    # constant because a board of another family is a devlist edit, not
    # a patch: openocd ships a target script for each, and which one a
    # board needs is a property of the board, exactly like interface=.
    def target(id)
        self.attribute(id, 'target', 'nrf52').to_s
    end

    # The SWD/JTAG transport openocd selects, or 'none' to select
    # nothing and let the interface script decide.
    #
    # Making target= a key and leaving this one a constant would have
    # been half a fix: a chip reached over JTAG takes the right target
    # script and then fails on a transport it does not have.
    def transport(id)
        self.attribute(id, 'transport', 'swd').to_s
    end

    # Target RAM openocd may borrow for its flash algorithms, or 'none'
    # to say nothing and let the target script choose.
    #
    # 16 KB is nothing to an nRF52840 and more than some parts have in
    # total, so it is a property of the chip rather than of this tool.
    # Written as openocd wants it, in hex.
    def work_area(id)
        v = self.attribute(id, 'work_area', 0x4000)
        return nil if PORT_NONE.include?(v.is_a?(String) ? v.downcase : v)
        begin
            Integer(v)
        rescue TypeError, ArgumentError
            raise Error, "devlist entry '#{id}' has work_area = #{v.inspect}," \
                         ' which is neither a size nor none'
        end
    end

    # Console baud rate of a board (230400 on the bench's MDK firmware,
    # 115200 on the stock DWM1001-DEV devicetree)
    def baud(id)
        Integer(self.attribute(id, 'baud', 230_400))
    end

    # Which tally reads this board's console: the devlist's key for the
    # board, else the file's own default, else counting lines.
    def tally(id)
        self.attribute(id, TALLY_KEY, @tally_default).to_s
    end

    # Does the devlist ask for a power cycle of this board at +moment+?
    # The power_cycle key names one moment or a list of them, e.g.
    # after-flash (the only one anything acts on today).
    def power_cycle?(id, moment)
        Array(self.attribute(id, 'power_cycle', [])).map(&:to_s)
             .include?(moment.to_s)
    end

    # The hub port of an entry, or nil when it declares none.
    def port_of(id)
        v = self.attribute(id, PORT_KEY)
        v = v.downcase if v.is_a?(String)
        return nil if PORT_NONE.include?(v)
        begin
            Integer(v)
        rescue TypeError, ArgumentError
            raise Error, "devlist entry '#{id}' has #{PORT_KEY} = #{v.inspect}," \
                         " which is neither a port number nor none"
        end
    end

    # Is there a board on the bench at this entry?  See PORT_KEY.
    def present?(id)
        !self.port_of(id).nil?
    end

    # List of registered devices, absent ones left out.
    #
    # Everything that walks the bench goes through here, so leaving an
    # absent board out in one place keeps it out of all of them: it is
    # not switched, not flashed, not connected to, and not counted among
    # the ports #switchable may power down.  That last one used to raise
    # KeyError instead: an entry with no port, which is the natural way
    # to write down a board that is gone, made name_port() fail and took
    # every 'usb off' with it.
    def devices
        (@devlist&.keys || []).select {|n| self.present?(n) }
    end

    # Every entry, present or not.  For looking a serial up, which is the
    # reason an absent board is kept in the file at all.
    def declared
        @devlist&.keys || []
    end

    # Translate a list of ids (port numbers or device names) to ports
    def port_list(ids)
        ids.map {|id|
            port = case id
                   when /^\d+$/ then Integer(id)
                   else
                       if @devlist.nil?
                           raise Error, "device name '#{id}' needs a devlist"
                       end
                       self.name_port(id).last
                   end
            unless @hub.ports.include?(port)
                raise Error, "port out of range (#{port})"
            end
            port
        }
    end

    # The ports 'protect' names, by number and through its nodes.
    #
    # A node with 'port = none' contributes nothing -- there is no port
    # to keep powered -- rather than raising.  A retired board left in
    # the file is what 'port = none' is for, and the devlist does not
    # become broken because that board's name is also protected.
    def protected_ports
        @protect_ports + @protect_nodes.filter_map {|n|
            self.name_port(n).last if self.present?(n)
        }
    end

    # Ports tribble-control may power down.  Ports the devlist does not
    # mention are protected unless 'protect { undeclared = no }' says
    # otherwise, and the ports 'protect' names are protected either
    # way.  That is what keeps the Raspberry Pi power feeds out of reach.
    def switchable
        if @devlist.nil?
            raise Error, 'no devlist: refusing to power down any port' \
                         ' (use -D FILE, or --force)'
        end
        base = if @protect_undeclared
               then self.devices.map {|n| name_port(n).last }
               else @hub.ports
               end
        (base - self.protected_ports).tap {|l|
            raise Error, 'devlist leaves no switchable port' if l.empty?
        }
    end

    # May this one port be powered down?
    #
    # offable() raises, which is what an explicit 'usb off' wants: the
    # user named a port and deserves to be told it is protected.  The
    # two internal paths that switch a single port are not that.  They
    # cut a port as a STEP of something else the user asked for -- the
    # turn-by-turn off of --method power, the cycle a board's
    # power_cycle key asks for after a flash -- so a protected port is a
    # reason to skip the step and say so, not to abort an operation that
    # has already succeeded.  Both used to call @hub.off() with a raw
    # port and no gate at all, which made them the two paths where the
    # manual's "never one the devlist reserves" was not true.
    def offable?(port, force: @opts[:force])
        force || self.switchable.include?(port)
    end

    # Vet a set of ports about to be powered down.  An empty list means
    # "every port we are allowed to touch", never "all 16".
    def offable(ports = [], force: false)
        if force
            return ports.empty? ? @hub.ports : ports
        end
        allowed = self.switchable
        return allowed if ports.empty?
        if (bad = ports - allowed).any?
            raise Error, "refusing to power down port(s) #{bad.join(' ')}:" \
                         ' protected by the devlist' \
                         ' (use --force)'
        end
        ports
    end

    # Say so when powering down takes ports off the bus and no more.
    #
    # A hub whose switch cuts the link (switch = link, the default for
    # hub = usb) makes a board vanish from the host exactly as a power
    # cut would, so every command that powers down still works --
    # selection by 'power' included, since openocd sees one probe
    # either way.  What does not happen is the board restarting.  Said
    # once per command, next to the ports, because the symptom of not
    # knowing is a board that "was power-cycled" and kept its state.
    def warn_link_only(ports)
        return if @hub.vbus?

        @tty&.warn "#{@hub} cuts the link, not the power: the board(s)" \
                   " on port(s) #{Array(ports).join(' ')} stay powered" \
                   " (#{SWITCH_KEY} = link)"
    end

    def each_device(ids, &block)
        return to_enum(:each_device, ids) unless block

        unless @opts.include?(:devlist)
            raise Error, "devlist is required"
        end

        name_port_list = (ids.empty? ? self.devices : ids)
                           .to_h {|id| self.name_port(id) }

        # An empty selection is refused, not carried through.
        #
        # It is reachable: naming no device on a devlist whose every
        # entry says 'port = none' selects nothing, and each of the
        # three methods below then did something worse than nothing
        # with it.  --method serial splatted the empty list into
        # @hub.on(), and on/off/toggle read "no ports named" as
        # "every port", so selecting no board powered all sixteen up
        # and then reported success for the nought boards it flashed.
        # --method power was worse: it powered the whole bench DOWN,
        # looped over nothing, and left it off.
        #
        # Every other splat into the hub in this program is safe by
        # construction -- offable() either returns a non-empty list or
        # raises, and 'usb on' tests for empty itself before choosing
        # between on() and on(*ports) -- so this is the one place that
        # needed the guard.
        if name_port_list.empty?
            raise Error, if ids.empty?
                             'no device selected: the devlist declares' \
                               ' none that is on the bench (every entry' \
                               " says #{PORT_KEY} = none)"
                         else
                             'no device selected'
                         end
        end

        @tty&.info "Devices : #{name_port_list.keys.join(' ')}"

        case @opts[:method]
        when 'serial'
          unless name_port_list.all? {|_n,p| self.serial(p) }
            raise 'Device without serial' \
                  ' (select another method)'
          end

          @tty&.info 'Ensuring ports are powered up'
          @hub.on(*name_port_list.values)
          sleep(@opts[:'warm-up'])

          @tty&.info "Parallelizing jobs"
          # in_threads, not the default.  Parallel.map with no option
          # runs in_processes: the children fork, run this block, and
          # push their results into their OWN copy of the accumulator
          # that Enumerable#map made in the parent.  The parent's copy
          # stays empty, so every caller that folds over the result --
          # Flash#run and Reset#run both end with .all?(&:itself) -- was
          # folding over [], which is true, and the command exited 0
          # however many boards had failed.  The work here is
          # Open3.capture2e on openocd, which releases the GVL for its
          # whole duration, so threads keep the parallelism and keep the
          # block in the parent's memory where its results can be seen.
          Parallel.map(name_port_list.keys,
                       in_threads: [ name_port_list.size, 1 ].max) do |name|
              block.call(name, serial: self.serial(name),
                               interface: self.interface(name),
                               target: self.target(name),
                               transport: self.transport(name),
                               work_area: self.work_area(name))
          end

        when 'usb'
          @tty&.info 'Ensuring ports are powered up'

          # @hub.on(*name_port_list.values)
          name_port_list.each_value do |port|
             @hub.on(port)
          end
          sleep(@opts[:'warm-up'])

          name_port_list.map do |name, port|
            unless (usb = @hub.usb_path(port))
                raise Error, 'cannot place the hub in the USB tree, so' \
                             " --method usb cannot address a board:" \
                             " this host reports no USB path for" \
                             " #{@hub}.  Use --method serial, or" \
                             ' --method power'
            end
            # The serial goes too, when the devlist has one.
            #
            # 'adapter usb location' does not select anything: measured
            # on 2026-09-16 against openocd 0.12.0, the only release
            # there is, with two CMSIS-DAP boards powered.  Asked for
            # A2's probe path, A1's probe path, either of their hub
            # paths, and a location that does not exist at all, it
            # answered with the same chip every time (FICR.DEVICEID
            # 5765c939, A2).  So this method disambiguated nothing, and
            # 'connect --reset' with several MDKs powered reset whichever
            # board openocd enumerated first while reporting success for
            # each.  'adapter serial' does work -- that is what 'flash'
            # relies on -- so pass it and let the location stand as the
            # documentation of intent it has turned out to be.  A board
            # with no serial= behaves exactly as before.
            block.call(name, usb: usb, serial: self.serial(name),
                             interface: self.interface(name),
                             target: self.target(name),
                             transport: self.transport(name),
                             work_area: self.work_area(name))
          end

        when 'power'
          off_ports = self.offable(force: @opts[:force])

          if @tty
            @tty.warn "Ports #{off_ports.join(' ')} will be turned off" \
                      ' (hit Ctrl-C to abort)'
            sleep(5)
          end

          @tty&.info "Turning off ports: #{off_ports.join(' ')}"
          @hub.off(*off_ports)
          self.warn_link_only(off_ports)
          sleep(1)

          name_port_list.map do |name, port|
            @tty&.info "Selectively turning on device #{name}"
            @hub.on(port)
            sleep(@opts[:'warm-up'])
            block.call(name, interface: self.interface(name),
                             target: self.target(name),
                             transport: self.transport(name),
                             work_area: self.work_area(name))
          ensure
            if self.offable?(port)
              @hub.off(port)
            else
              @tty&.warn "#{name}: leaving port #{port} powered, the" \
                         ' devlist protects it'
            end
          end

        else raise 'unsupported flashing method'
        end
    end

    # The openocd binary, resolved and checked once.
    #
    # Without this the first sign of a missing or mistyped --openocd is
    # Errno::ENOENT out of Open3 -- once per board, raised from inside
    # the thread pool, after the ports have been powered up and the
    # warm-up slept through.  A name with no separator in it is looked
    # up in PATH, which is what makes --openocd=openocd work on a host
    # that keeps it somewhere other than /usr/bin (FreeBSD: it is under
    # /usr/local).
    def openocd_path
        @openocd_path ||= begin
            path  = @opts[:openocd].to_s
            found = if path.include?(File::SEPARATOR)
                        path
                    else
                        ENV.fetch('PATH', '').split(File::PATH_SEPARATOR)
                           .map {|dir| File.join(dir, path) }
                           .find {|p| File.file?(p) && File.executable?(p) }
                    end
            unless found && File.file?(found) && File.executable?(found)
                raise Error, "openocd not found at '#{path}'" \
                             ' (give it with --openocd=PATH)'
            end
            found
        end
    end

    def openocd(*commands, usb: nil, serial: nil,
                interface: 'cmsis-dap', target: 'nrf52',
                transport: 'swd', work_area: 0x4000, &block)
      cmd  = [ self.openocd_path ]
      if work_area
          cmd += [ '-c', format('set WORKAREASIZE 0x%x', work_area) ]
      end
      cmd += [ '-c', "source [find interface/#{interface}.cfg]" ]
      unless transport.nil? || PORT_NONE.include?(transport)
          cmd += [ '-c', "transport select #{transport}"     ]
      end
      cmd += [ '-c', "source [find target/#{target}.cfg]"    ]
      cmd += [ '-c', "adapter usb location #{usb}"           ] if usb
      cmd += [ '-c', "adapter serial #{serial}"              ] if serial
      cmd += commands.flat_map {|c| [ '-c', c ] }
      cmd += [ '-c', 'shutdown'                              ]

      @tty&.debug Shellwords.shelljoin(cmd)

      output, pstatus = Open3.capture2e(*cmd)
      ok              = pstatus.exitstatus.zero?

      block.call(ok, output) if block
      ok
    end

    # The hub's control line, from what -d or the devlist named, or
    # from the host when neither named anything.
    #
    # Argument parsing
    def parse(argv)
        # Parsed option holder
        opts = {}.merge(Defaults)

        # Parse global options
        GlobalParser.order!(argv, into: opts)

        # Before anything else: a tally the devlist names has to be
        # registered by the time the devlist is read, and a file that
        # will not load should say so before a port is touched.
        Array(opts[:require]).each do |file|
            path = File.expand_path(file)
            raise Error, "no such file to require: #{file}" \
                unless File.file?(path)
            begin
                require path
            rescue ScriptError, StandardError => e
                raise Error, "loading #{file}: #{e.message}"
            end
        end

        # Check for command processor class
        cmdname = argv.shift
        raise Error, "command missing" if cmdname.nil?
        cmdk    = CLI.find_command_class(cmdname)
        raise Error, "command '#{cmdname}' is not recognized" if cmdk.nil?

        # Parse command, and run it
        if cmdk.const_defined?(:Defaults)
            opts.merge!(cmdk::Defaults) {|_k, o, _n| o }
        end
        if cmdk.const_defined?(:Parser)
            cmdk::Parser.order!(argv, into: opts)
        end

        if cmdk.const_defined?(:Methods)
            if opts.include?(:method)
                unless cmdk::Methods.include?(opts[:method])
                    raise "#{cmdname} only support the #{cmdk::Methods.join(', ')} selection"
                end
            else
                opts[:method] = cmdk::Methods.first
            end
        end


        # Config
        if opts.include?(:devlist)
            file = opts[:devlist]
            raise Error, "file #{file} doesn't exist" unless File.exist?(file)
            raw = UCL.load_file(file)

            # The keys the 'protect' block replaced, caught before the
            # device pass can take them for boards.
            if (former = raw.keys & PROTECT_FORMER.keys).any?
                raise Error, former.map {|k|
                    "'#{k}' is no longer a devlist key:" \
                      " write #{PROTECT_FORMER[k]}"
                }.join('; ')
            end

            # What may never lose power.  Checked key by key because
            # the whole point of the block is that a port listed in it
            # stays on: a misspelled 'port = [ 13 ]' that was silently
            # ignored would read as protection and be none, which is
            # the one failure mode this file exists to prevent.
            if raw.include?(PROTECT_KEY)
                protect = raw[PROTECT_KEY]
                unless protect.is_a?(Hash)
                    raise Error, "#{PROTECT_KEY} must be a block:" \
                                 " #{PROTECT_KEY} { #{PROTECT_PORTS_KEY}" \
                                 ' = [ 13, 14 ] }'
                end
                if (bad = protect.keys - PROTECT_KEYS).any?
                    raise Error, "#{PROTECT_KEY} has no" \
                                 " #{bad.join(', ')} key; it takes" \
                                 " #{PROTECT_KEYS.join(', ')}"
                end
                if protect.include?(PROTECT_UNDECLARED_KEY)
                    undeclared = protect[PROTECT_UNDECLARED_KEY]
                    unless [ true, false ].include?(undeclared)
                        raise Error, "#{PROTECT_KEY}." \
                                     "#{PROTECT_UNDECLARED_KEY} must be" \
                                     ' yes or no'
                    end
                    @protect_undeclared = undeclared
                end
                # flatten: UCL turns a key written twice in one block
                # into an array of its values, so a file with two
                # 'ports' lines means both, not a nested list nothing
                # can compare against a port number.
                @protect_ports = Array(protect[PROTECT_PORTS_KEY])
                                     .flatten.map do |p|
                    Integer(p)
                rescue ArgumentError, TypeError
                    raise Error, "#{PROTECT_KEY}.#{PROTECT_PORTS_KEY} takes" \
                                 " port numbers; '#{p}' is not one"
                end
                @protect_nodes = Array(protect[PROTECT_NODES_KEY])
                                     .flatten.map(&:to_s)
            end

            if raw.include?(TALLY_KEY)
                @tally_default = raw[TALLY_KEY].to_s
            end

            # Which hub this file describes.  A block or a list here is
            # a file saying one devlist covers two benches, which it
            # cannot: every port number in it belongs to one hub.
            #
            # Integer is accepted because UCL hands one back for an
            # unquoted all-digit serial, which is a serial like any
            # other and was refused as "must name one hub" -- a poor
            # answer to a file that had named one.
            #
            # It is accepted and not fixed, because it CANNOT be fixed
            # here: UCL has already parsed 00760040233 as the number
            # 760040233 and the leading zeros are gone before this sees
            # it.  Such a serial is looked up as written in the file
            # minus its zeros, fails, and the refusal lists what the
            # host really has -- which is the moment to quote it.  The
            # docs say to quote a serial for this reason.
            if raw.include?(DEVICE_KEY)
                dev = raw[DEVICE_KEY]
                unless [ String, Symbol, Integer ].any? {|k| dev.is_a?(k) }
                    raise Error, "#{DEVICE_KEY} must name one hub: its" \
                                 " serial number, such as A50285BI, a USB" \
                                 " path, such as 1-1.2.4.4, or its device" \
                                 ' node, such as /dev/ttyUSB0.  Quote a' \
                                 ' serial that is all digits'
                end
                @device = dev.to_s
            end

            # Which kind of hub, and what its switch does.  Both are
            # checked here against what exists, so a typo is refused
            # at load rather than met as a missing backend later.
            if raw.include?(HUB_KEY)
                @hub_kind = raw[HUB_KEY].to_s.downcase
                unless Hub::KINDS.key?(@hub_kind)
                    raise Error, "#{HUB_KEY} must be one of" \
                                 " #{Hub::KINDS.keys.join(', ')}"
                end
            end

            if raw.include?(SWITCH_KEY)
                @switch = raw[SWITCH_KEY].to_s.downcase.to_sym
                unless SWITCHES.include?(@switch)
                    raise Error, "#{SWITCH_KEY} must be one of" \
                                 " #{SWITCHES.join(', ')}"
                end
            end

            # The type definitions, lifted out before anything is
            # taken for a device.
            if raw.include?(TYPES_KEY)
                @types = raw[TYPES_KEY]
                unless @types.is_a?(Hash)
                    raise Error, "#{TYPES_KEY} must be a block of named" \
                                 ' definitions'
                end
                @types.each do |name, defn|
                    unless defn.is_a?(Hash)
                        raise Error, "type '#{name}' is not a block of settings"
                    end
                    # A type that named a port or a serial would be
                    # saying every board of its kind is one board.
                    if (bad = defn.keys & TYPE_FORBIDDEN).any?
                        raise Error, "type '#{name}' sets #{bad.join(', ')}," \
                                     ' which names one particular board and' \
                                     ' cannot be shared'
                    end
                    # One level: a type is settings, not a thing with a
                    # type of its own.
                    if defn.key?(TYPE_KEY)
                        raise Error, "type '#{name}' has a #{TYPE_KEY} of" \
                                     ' its own; types do not nest'
                    end
                end
            end

            @devlist  = raw.reject {|k,_|
                [ PROTECT_KEY, TALLY_KEY,
                  TYPES_KEY, DEVICE_KEY, HUB_KEY, SWITCH_KEY ].include?(k)
            }

            # Every device says which port it is on, or says none. A
            # forgotten port line is a mistake worth a message, not a
            # board quietly dropped off the bench.
            @devlist.each do |name, entry|
                unless entry.is_a?(Hash) && entry.key?(PORT_KEY)
                    raise Error, "devlist entry '#{name}' has no #{PORT_KEY}." \
                                 " Give it the hub port, or" \
                                 " '#{PORT_KEY} = none' if the board is no" \
                                 ' longer on the bench'
                end
                # Normalise it here, once, so port_of() is the only place
                # that has to know what a port may look like.  It accepts
                # a string, deliberately, but name_port(), serial() and
                # attribute() all compare the RAW value against an
                # integer id, so a devlist written port = '7' used to
                # load, count as present, and then leave the board
                # unswitchable with "port out of range (7)" and unnamed
                # in 'usb status'.  nil here means none, which is what
                # PORT_NONE already says.
                entry[PORT_KEY] = self.port_of(name)
            end

            # A type nothing defines is an error rather than an entry
            # quietly falling back to the tool's defaults: a board that
            # asked for jlink and silently got cmsis-dap is a flash
            # through the wrong probe, reported as success.
            @devlist.each do |name, entry|
                next unless (t = entry[TYPE_KEY])
                next if @types.key?(t.to_s)
                known = @types.keys.sort
                raise Error, "devlist entry '#{name}' has #{TYPE_KEY} =" \
                             " #{t}, which #{TYPES_KEY} does not define" \
                             " (known: #{known.empty? ? 'none' : known.join(', ')})"
            end

            # Two boards on one port is a devlist that cannot be right,
            # and it is what a reassigned port leaves behind when the old
            # entry keeps its number: the tool would then flash, power or
            # connect to whichever of the two it happened to find first,
            # under the other one's interface and baud. Caught here, at
            # load, rather than by a board behaving oddly later.
            #
            # 'none' is exempt, that being its whole purpose: any number
            # of entries may declare no port.
            seen = Hash.new {|h, k| h[k] = [] }
            @devlist.each_key {|name|
                port = self.port_of(name)
                seen[port] << name unless port.nil?
            }
            clash = seen.select {|_, names| names.size > 1 }
            unless clash.empty?
                detail = clash.sort.map {|port, names|
                    "#{port} (#{names.map {|n| "'#{n}'" }.join(', ')})"
                }.join('; ')
                raise Error, "devlist assigns the same #{PORT_KEY} more" \
                             " than once: #{detail}"
            end

            # Every protected node names an entry.  A name that matches
            # nothing is a typo, and a typo here protects nothing while
            # reading, in the file, exactly like protection.
            if (unknown = @protect_nodes - @devlist.keys).any?
                raise Error, "#{PROTECT_KEY}.#{PROTECT_NODES_KEY} names" \
                             " #{unknown.map {|n| "'#{n}'" }.join(', ')}," \
                             ' which the devlist does not declare'
            end
        end


        # Which hub to drive.  The kind first: --hub, else the devlist's
        # HUB_KEY line, else exsys.  Then the name, in the order they
        # are trusted: -d on the command line, the devlist's own
        # DEVICE_KEY line, and only then the host.  The backend's open
        # holds the policy -- one candidate may be taken, two may not
        # -- and the wording of each refusal; what is settled here is
        # only which name it is handed, and which settings.  A setting
        # for the other kind of hub is refused rather than dropped.
        #
        # No lock of ours around the ExSYS hub: exsys holds an exclusive lock on the
        # serial line for the whole of each call, the read-modify-write
        # of an on/off included, and that covers every process touching
        # the hub rather than only the tribble-control ones a lock file of
        # ours could know about.  SerialisedHub did this job from the
        # outside until exsys 1.0; nothing here needs a lock spanning
        # two calls, and the one candidate -- the turn-by-turn cycling
        # of --method power -- must not hold the line across its sleeps.
        kind     = opts.fetch(:hub, @hub_kind)
        settings = {}
        if opts.include?(:password)
            unless kind == 'exsys'
                raise Error, "-p/--password: a #{kind} hub has no password"
            end
            settings[:password] = opts[:password]
        end
        if @switch
            unless kind == 'usb'
                raise Error, "#{SWITCH_KEY} = #{@switch} applies to" \
                             " #{HUB_KEY} = usb; the #{kind} hub always" \
                             ' cuts power'
            end
            settings[:switch] = @switch
        end
        @hub    = Hub.backend(kind).open(opts.fetch(:device, @device),
                                         **settings)
        @device = opts[:device] = @hub.to_s

        # Debug, and the FILE it was documented to take.
        #
        # --debug[=FILE] accepted a filename and dropped it: the manual
        # said so under TRAPS and nobody had made it true either way.
        # It is honoured now -- the log goes to the terminal as before
        # AND to the file, so a capture can be kept without watching it
        # go past.  Opened before anything is switched, because finding
        # out that a path is unwritable after a bench has been powered
        # down is finding out too late.
        if opts.include?(:debug)
            outputs = [ $stderr ]
            if (file = opts[:debug])
                begin
                    @debug_io = File.open(file, 'a')
                    @debug_io.sync = true
                rescue SystemCallError => e
                    raise Error, "cannot write the debug log to #{file}:" \
                                 " #{e.message}"
                end
                outputs << @debug_io
            end
            # A new logger, not configure() on the old one: tty-logger
            # 0.6 builds its handlers when the logger is constructed
            # and #configure does not revisit the level, so the call
            # that used to be here changed nothing whatever.
            @tty = TTY::Logger.new do |config|
                config.level  = :debug
                config.output = outputs
            end
        end

        # Save parsing results
        @argv = argv
        @opts = opts
        @cmdk = cmdk

        # Chainable
        self
    end

    # Run command line
    def run
        return nil if @cmdk.nil?

        # Only commands that select devices power anything on, so only
        # they have a selection method and a warm-up delay to report.
        # Before a port is switched, not from inside the thread pool
        # with every board already powered.  Commands that only
        # sometimes need openocd -- connect, and only under --reset --
        # do not declare it, and check when they reach for it.
        self.openocd_path if @cmdk.const_defined?(:OPENOCD) && @cmdk::OPENOCD

        if @cmdk.const_defined?(:Methods)
            tty&.info "Device selection using #{@opts[:method]}"
            tty&.info "A #{@opts[:'warm-up']} sec warm-up delay" \
                      " will be applied after device power-on"
        end

        @cmdk.new(self).run(@argv, **@opts)
    end

end

end
