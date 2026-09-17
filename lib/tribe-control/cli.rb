#
# The command line: global options, the device list, and the machinery
# every command uses to reach a board (each_device, openocd).
#
require 'optparse'
require 'shellwords'
require 'forwardable'
require 'open3'
require 'exsys'
require 'exsys/managed-usb'
require 'ucl'
require 'tty/logger'
require 'parallel'

require_relative 'version'
require_relative 'platform'

module TribeControl

class CLI
    # Command line error reporting 
    class Error < StandardError
    end

    # Command class inheritance
    class Command
        extend Forwardable
        def_delegators :@cli, :exsys, :tty, :conf, :openocd, :each_device,
                              :port_list, :switchable, :offable, :offable?,
                              :devices, :tally

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

    # devlist key listing ports that must never be powered down
    RESERVED_KEY   = 'reserved'

    # devlist key deciding the fate of ports the file does not mention
    UNDECLARED_KEY = 'undeclared'
    UNDECLARED     = [ :protect, :switch ].freeze

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
    # the comment saying when it stopped enumerating -- but tribe-control
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
        
        opts.on '-d', '--device=DEV',      'Serial line to USB hub'
        opts.on '-p', '--password=STRING', 'USB hub password'
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
        opts.on '-F', '--force',           'Switch undeclared ports too'
        opts.on       '--debug[=FILE]',    'Debug output file'
        opts.on '-v', '--[no-]verbose',    'Run verbosely'
        opts.on '-V', '--version',         'Version' do
            puts "tribe-control : #{TribeControl::VERSION}"
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
            CLI.commands.each { |name, klass|
                puts '    %-12s %s' % [ klass.cmdname, klass::DESCRIPTION ]
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

    # Where the manual lives.  It sat after __END__ while tribe-control
    # was a single script; lib/ is required rather than run, so DATA is
    # not defined there and the page is a file shipped beside the code.
    #
    # man/man1/ rather than man/: that shape is a MANPATH entry as it
    # stands, so `MANPATH=<gem>/man man tribe-control` works on an
    # installed gem without anything having to be copied anywhere.
    MANUAL = File.expand_path('../../man/man1/tribe-control.1', __dir__)

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
        unless text = self.render_manual
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
        self.commands.find {|n,k| n == name }&.last
    end

    # Run the command line
    #
    # Commands that report per-device success (flash, reset, serial)
    # return false if any device failed; that becomes exit status 1.
    def self.run(argv = ARGV)
        self.new.parse(argv).run.tap {|ok| exit 1 if ok == false }
    rescue OptionParser::InvalidArgument, CLI::Error => e
        warn "#{PROGNAME}: #{e}"
        exit 1
    end

    # Attribut reader
    attr_reader :exsys
    attr_reader :tty
    attr_reader :conf

    # Initializer
    def initialize
        @devlist       = nil
        @reserved      = []
        @undeclared    = :protect
        @tally_default = TALLY_DEFAULT
        @tty     = TTY::Logger.new do |config|
            config.level = :debug
        end
    end

    # Translate a port/name to a port identier
    def name_port(id)
        case id
        when /^\d+$/
            port = Integer(id)
            if name = @devlist.find {|k,v| v.dig('port') == port }&.first
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
            if port = @devlist.find {|k,v| k == id }&.last&.dig('port')
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
            @devlist.find {|k,v| v.dig('port') == id }&.last&.dig('serial')
        when String
            @devlist.find {|k,v| k == id }&.last&.dig('serial')
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
                when Integer then @devlist.find {|k,v| v.dig('port') == id }&.last
                when String  then @devlist.find {|k,v| k == id }&.last
                else raise "unsupported id (#{id})"
                end
        return default if entry.nil? || !entry.key?(key)
        entry[key]
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
        Integer(self.attribute(id, 'baud', 230400))
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
            unless ExSYS::ManagedUSB::PORTS.include?(port)
                raise Error, "port out of range (#{port})"
            end
            port
        }
    end

    # Ports tribe-control may power down.  Ports the devlist does not
    # mention are protected unless 'undeclared' says otherwise, and ports
    # named by 'reserved' are protected either way.  That is what keeps
    # the Raspberry Pi power feeds out of reach.
    def switchable
        if @devlist.nil?
            raise Error, 'no devlist: refusing to power down any port' \
                         ' (use -D FILE, or --force)'
        end
        base = case @undeclared
               when :protect then self.devices.map {|n| name_port(n).last }
               when :switch  then ExSYS::ManagedUSB::PORTS.to_a
               end
        (base - @reserved).tap {|l|
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
    # has already succeeded.  Both used to call @exsys.off() with a raw
    # port and no gate at all, which made them the two paths where the
    # manual's "never one the devlist reserves" was not true.
    def offable?(port, force: @opts[:force])
        force || self.switchable.include?(port)
    end

    # Vet a set of ports about to be powered down.  An empty list means
    # "every port we are allowed to touch", never "all 16".
    def offable(ports = [], force: false)
        if force
            return ports.empty? ? ExSYS::ManagedUSB::PORTS : ports
        end
        allowed = self.switchable
        return allowed if ports.empty?
        if (bad = ports - allowed).any?
            raise Error, "refusing to power down port(s) #{bad.join(' ')}:" \
                         ' not switchable, being undeclared or reserved' \
                         ' (use --force)'
        end
        ports
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
        # @exsys.on(), and on/off/toggle read "no ports named" as
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
            raise Error, ids.empty? \
                ? 'no device selected: the devlist declares none that' \
                  ' is on the bench (every entry says' \
                  " #{PORT_KEY} = none)"                                \
                : 'no device selected'
        end

        @tty&.info "Devices : #{name_port_list.keys.join(' ')}"

        case @opts[:method]
        when 'serial'
          unless name_port_list.all? {|n,p| self.serial(p) }
            raise 'Device without serial' \
                  ' (select another method)'
          end

          @tty&.info 'Ensuring ports are powered up'
          @exsys.on(*name_port_list.values)
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

          # @exsys.on(*name_port_list.values)
          name_port_list.values.each do |port|
             @exsys.on(port)
          end
          sleep(@opts[:'warm-up'])

          name_port_list.map do |name, port|
            usb = Platform.port_to_usb(port, root: @opts[:device])
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
          @exsys.off(*off_ports)
          sleep(1)
          
          name_port_list.map do |name, port|
            @tty&.info "Selectively turning on device #{name}"
            @exsys.on(port) 
            sleep(@opts[:'warm-up'])
            block.call(name, interface: self.interface(name),
                             target: self.target(name),
                             transport: self.transport(name),
                             work_area: self.work_area(name))
          ensure
            if self.offable?(port)
              @exsys.off(port)
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

        # Argument parsing
    def parse(argv)
        # Parsed option holder
        opts = { }.merge(Defaults)
        
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
        raise Error, "command \'#{cmdname}\' is not recognized" if cmdk.nil?

        # Parse command, and run it
        if cmdk.const_defined?(:Defaults)
            opts.merge!(cmdk::Defaults) {|k, o, n| o }
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
        
        
        # ExSYS USB hub
        if ! opts.include?(:device)
            unless opts[:device] = Platform.exsys_ctrl.first
                raise Error, "Unable to auto-detect ExSYS hub device"
            end
        end

        # Config
        if opts.include?(:devlist)
            file = opts[:devlist]
            raise Error, "file #{file} doesn't exist" unless File.exist?(file)
            raw       = UCL.load_file(file)
            @reserved = Array(raw[RESERVED_KEY]).map {|p| Integer(p) }

            if raw.include?(UNDECLARED_KEY)
                @undeclared = raw[UNDECLARED_KEY].to_s.downcase.to_sym
                unless UNDECLARED.include?(@undeclared)
                    raise Error, "#{UNDECLARED_KEY} must be one of" \
                                 " #{UNDECLARED.join(', ')}"
                end
            end

            if raw.include?(TALLY_KEY)
                @tally_default = raw[TALLY_KEY].to_s
            end

            @devlist  = raw.reject {|k,_|
                [ RESERVED_KEY, UNDECLARED_KEY, TALLY_KEY ].include?(k)
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
        end

        
        # Instanciate USB hub control
        #
        # No wrapper of ours: exsys holds an exclusive lock on the
        # serial line for the whole of each call, the read-modify-write
        # of an on/off included, and that covers every process touching
        # the hub rather than only the tribe-control ones a lock file of
        # ours could know about.  SerialisedHub did this job from the
        # outside until exsys 1.0; nothing here needs a lock spanning
        # two calls, and the one candidate -- the turn-by-turn cycling
        # of --method power -- must not hold the line across its sleeps.
        @exsys = ExSYS::ManagedUSB.new(opts[:device], opts[:password])

        # Debug
        if opts.include?(:debug)
            @tty.configure do |config|
                config.level = :debug
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

        @cmdk::new(self).run(@argv, **@opts)
    end
    
end

end
