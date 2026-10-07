require_relative '../cli'
require_relative '../tally'
require 'uart'

module TribbleControl

class CLI
class Connect < CLI::Command
    DESCRIPTION = 'Read board consoles'

    # usb first, so it stays the default where it works.  serial is
    # what reaches a console on a host with no /sys/bus/usb: it needs
    # no topology, only the probe serial the configuration already carries
    # to address the board for flashing.
    Methods  = [ 'usb', 'serial' ]
    Defaults = {}
    Repeatable = [ :tally ]
    Parser   = OptionParser.new do |opts|
        opts.banner = "Usage: #{PROGNAME} connect [options] PORT"

        opts.separator ''
        opts.separator "#{DESCRIPTION}."
        opts.separator ''

        opts.separator 'Options:'
        opts.on '--off', 'Start with all devices off'
        opts.on '--reset', 'Reset each board once its console is open,' \
                           ' so boot output is captured'
        opts.on '--duration=SECONDS', Integer,
                'How long to capture for (default 600)'
        opts.on '--command=CMD', 'Shell command to send to every selected' \
                                 " board's own console once it is up"
        opts.on '--interactive', 'Type at the board: forward this' \
                                 ' standard input to it, and stay until' \
                                 ' end of input rather than for a duration'
        # NAME, not [DEV=]NAME: OptionParser reads brackets after the
        # '=' as an optional argument, which '--tally twr' never fills.
        opts.on '--tally=NAME', Array,
                'Read the consoles with tally NAME for this run,' \
                ' whatever the configuration says; DEV=NAME for one' \
                ' board only (repeatable, comma-separated)'
    end

    # Each selected board's tally, built: { name => tally }.
    #
    # +given+ is what --tally said, in order.  A bare NAME is the run's
    # tally, DEV=NAME is one board's; the configuration answers for
    # whatever neither names.  So, for one board, the first of: DEV=NAME,
    # NAME, the board's own tally key (or its type's), the file's, lines.
    #
    # Built here, all of them, before anything is switched, so an unknown
    # name stops the run before --off cuts the bench or a reader starts.
    # A board later skipped for having no console costs a block call.
    #
    # The run gets the last word because the configuration is about
    # boards, not about what is flashed on them, and the same board
    # carries different firmware from one run to the next.
    def tallies(ids, given)
        names   = (ids.empty? ? devices : ids).map {|id| name_of(id) }
        run     = nil
        boards  = {}

        # '--tally=' stores an empty list and 'a,,b' a nil between a and
        # b.  Taken as no --tally at all, the first would hand every
        # board back to the configuration -- the silent fallback this
        # option exists to prevent.
        if given && (given.empty? || given.any? {|s| s.to_s.empty? })
            raise Error, '--tally: an empty NAME (--tally= or a doubled' \
                         ' comma); give NAME or DEV=NAME'
        end

        Array(given).each do |spec|
            dev, eq, which = spec.rpartition('=')
            if eq.empty?
                if run && run != which
                    raise Error, "--tally gives two tallies for the run" \
                                 " (#{run}, #{which}): use DEV=NAME for" \
                                 ' one board'
                end
                run = which
                next
            end
            if dev.empty? || which.empty?
                raise Error, "--tally #{spec}: expected NAME or DEV=NAME"
            end
            name = name_of(dev)
            unless names.include?(name)
                raise Error, "--tally #{spec}: #{name} is not captured by" \
                             " this run (#{names.join(' ')})"
            end
            if boards[name] && boards[name] != which
                raise Error, "--tally gives #{name} two tallies" \
                             " (#{boards[name]}, #{which})"
            end
            boards[name] = which
        end

        names.to_h {|n| [ n, Tally.build(boards[n] || run || tally(n), n) ] }
    end

    # A device name, from a name or a port number as the command line
    # takes them.  An id the configuration does not know is the user's
    # error, said as one, not a KeyError.
    def name_of(id)
        @cli.name_port(id).first
    rescue KeyError
        raise Error, "no device '#{id}' in the configuration"
    end

    # Where this board's console is.
    #
    # The USB path first, because it names the device itself and is
    # what --method usb went to the trouble of working out.  The probe
    # serial second: it identifies the console just as exactly, needs
    # no USB tree to be walked, and is therefore the only one of the
    # two that a FreeBSD host can answer.  nil means neither found it,
    # which is a board that is not there.
    def console(hopts)
        if hopts[:usb] && (path = Platform.usb_to_tty(hopts[:usb]))
            path
        else
            Platform.serial_to_tty(hopts[:serial])
        end
    end

    def run(argv, **opts)
        # No configuration, no boards to name: each_device says so below,
        # in its own words, before a counter is ever asked for.
        counters = opts.include?(:config) ? tallies(argv, opts[:tally]) : {}

        # Before anything is powered, reset or started.
        if opts[:interactive] && opts.include?(:config) && counters.size != 1
            raise Error, 'connect: --interactive takes a single device' \
                         " (#{counters.size} selected)"
        end
        @failed = []

        if opts[:off]
            off_ports = offable(force: opts[:force])
            tty&.info "Starting from off state: #{off_ports.join(' ')}"
            hub.off(*off_ports)
            warn_link_only(off_ports)
        end

        connected = []
        each_device(argv).each do |name, hopts={}|
          # No tty, no reader.  usb_to_tty returns nil when the glob finds
          # no ttyACM under the port: the board is dead, unplugged, or
          # simply slower to enumerate than --warm-up allowed.  Said, and
          # counted as a failure: a board that cannot be read must not
          # look like one that is up and saying nothing, which is the one
          # question 'connect' exists to answer.
          dev_tty = console(hopts)
          if dev_tty.nil?
            where = hopts[:usb] || "probe #{hopts[:serial] || '(no serial)'}"
            tty&.error "Device #{name}: no console enumerated at" \
                       " #{where}; not capturing it"
            @failed << name
            next
          end
          tty&.info "Connecting to #{name} on #{dev_tty}"
          connected << [ name, hopts ]

            # What the lines MEAN is not this tool's business: the
            # strings worth counting belong to whatever firmware
            # happens to be on the bench this month, and they change
            # without a hub changing.  The tally --tally or the
            # configuration names is handed every line and asked, at the
            # end, for one summary.  See #tallies, TribbleControl::Tally,
            # and --require.
            counter = counters.fetch(name)
            Thread.new { read_console(name, dev_tty, counter) }
        end

        # A board that is already running has usually said everything it
        # had to say before its console was opened: the banner and the
        # driver's init lines are long gone.  Resetting once the readers
        # are attached is the only way to see them.
        if opts[:reset]
            sleep(1)                    # let the reader threads settle
            connected.each do |name, hopts|
                tty&.info "Resetting #{name}"
                unless openocd('init', 'reset run', **hopts)
                    tty&.error "Device #{name}: Reset failed"
                end
            end
        end

        # The interesting output is often below the firmware's compiled-in
        # log level, and spank can be turned up at run time, by typing at
        # the shell.  Written on a second, write-only handle: the reader
        # thread already holds the port, and sharing one IO across threads
        # for opposite directions is a race waiting for a long bench run.
        if (cmd = opts[:command])
            sleep(opts[:reset] ? 2 : 0.5)   # let the shell come up
            connected.each do |name, hopts|
                dev_tty = console(hopts)
                tty&.info "Sending to #{name}: #{cmd}"
                begin
                    File.open(dev_tty, File::WRONLY | File::NOCTTY) do |w|
                        w.sync = true
                        w.write("\r#{cmd}\r")
                    end
                rescue SystemCallError => e
                    tty&.error "Device #{name}: could not send command" \
                               " (#{e.message})"
                end
            end
        end

        # Either we are being watched or we are being typed at.  A
        # duration is what an unattended capture needs; a console is
        # what a question needs, and it ends when the person asking
        # says so, not on a timer they would have to guess in advance.
        if opts[:interactive]
            interact(connected)
        else
            sleep(opts[:duration] || 600)
        end

        # A board that was never read is not a quiet board: exit 1.
        @failed.empty?
    end

    # Read one board's console until the run ends, and say how it went.
    #
    # A console that will not open (permission, busy, gone), a read that
    # fails on unplug, or a tally that raises ends the reader with an
    # ERROR line on stdout, where a capture keeps it, and no SUMMARY: a
    # summary of a board never read would read as one that said
    # nothing.  The run then exits 1.
    def read_console(name, dev_tty, counter)
        failed = false
        UART.open dev_tty, @cli.baud(name) do |serial|
            loop do
              line = serial.readline
              counter << line
              puts "<#{name}> #{line}"
            rescue EOFError
                retry
            end
        end
    rescue StandardError => e
        failed = true
        (@failed ||= []) << name
        puts "<#{name}> ERROR: #{e.message} (#{e.class}); not read past this point"
    ensure
        if !failed && (summary = counter.summary)
            puts "<#{name}> SUMMARY: #{summary}"
        end
    end

    # Stdin to the board, a line at a time.
    #
    # On a second, write-only handle, as --command is.  What comes back
    # is printed by the reader thread, prefixed like everything else, so
    # the answer to what was typed appears where the rest of the board's
    # output does.
    #
    # Lines, not characters: the shell on the far end wants a complete
    # line terminated by \r, and there is nowhere here to run a line
    # editor.  Over ssh -t that is no loss -- the pty at the other end
    # of the connection does the editing and the echo, so what arrives
    # is already the line that was meant.
    def interact(connected)
        # One device was selected (run checked); none here means its
        # console did not enumerate, which run has already reported.
        raise Error, 'connect: no console to type at' if connected.empty?
        name, hopts = connected.first
        dev_tty = console(hopts)
        tty&.info "Typing at #{name} (^D to leave)"
        File.open(dev_tty, File::WRONLY | File::NOCTTY) do |w|
            w.sync = true
            while (line = $stdin.gets)
                w.write("#{line.chomp}\r")
            end
        end
    end
end
end

end
