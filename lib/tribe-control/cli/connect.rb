require_relative '../cli'
require_relative '../tally'
require 'uart'

module TribeControl

class CLI
class Connect < CLI::Command
    DESCRIPTION = 'Connect to device'

    Methods  = [ 'usb' ]
    Defaults = { }
    Parser   = OptionParser.new do |opts|
        # Usage
        opts.banner = "Usage: #{PROGNAME} connect [options] PORT"

        # Description
        opts.separator ''
        opts.separator "#{DESCRIPTION}."
        opts.separator ''

        # Options
        opts.separator 'Options:'
        opts.on '--off', 'Start with all devices off'
        opts.on '--reset', 'Reset each board once its console is open,' \
                           ' so boot output is captured'
        opts.on '--duration=SECONDS', Integer,
                'How long to capture for (default 600)'
        opts.on '--command=CMD', 'Shell command to send to every selected' \
                                 ' board once it is up (eg. spank syslog info)'
        opts.on '--interactive', 'Type at the board: forward this' \
                                 ' standard input to it, and stay until' \
                                 ' end of input rather than for a duration'
        
    end

    def run(argv, **opts)
        if opts[:off]
            off_ports = offable(force: opts[:force])
            tty&.info "Starting from off state: #{off_ports.join(' ')}"
            exsys.off(*off_ports)
        end
      
        connected = []
        each_device(argv).each do |name, hopts={}|
          # No tty, no reader.  usb_to_tty returns nil when the glob finds
          # no ttyACM under the port: the board is dead, unplugged, or
          # simply slower to enumerate than --warm-up allowed.  This used
          # to carry the nil onward, print "Connecting to C2 on " with an
          # empty path, count the board as connected, and build a reader
          # thread around nil.  The thread died in UART.open, nothing
          # joined it, and the run went its full duration and reported
          # "ok=0 ... tx-rate=NaN" -- indistinguishable from a board that
          # is up and saying nothing, which is the one question 'connect'
          # exists to answer.
          dev_tty = Platform.usb_to_tty(hopts[:usb])
          if dev_tty.nil?
            tty&.error "Device #{name}: no console enumerated at" \
                       " #{hopts[:usb]}; not capturing it"
            next
          end
          tty&.info "Connecting to #{name} on #{dev_tty}"
          connected << [ name, hopts ]

            # What the lines MEAN is not this tool's business: the
            # strings worth counting belong to whatever firmware
            # happens to be on the bench this month, and they change
            # without a hub changing.  The tally named by the devlist
            # is handed every line and asked, at the end, for one
            # summary.  See TribeControl::Tally, and --require.
            counter = Tally.build(tally(name), name)
            Thread.new do
                UART.open dev_tty, @cli.baud(name) do |serial|
                    loop do
                      line = serial.readline
                      counter << line
                      puts "<#{name}> #{line}"
                    rescue EOFError
                        retry
                    end
                end
            ensure
              if summary = counter.summary
                  puts "<#{name}> SUMMARY: #{summary}"
              end
            end
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
        # log level, and spank can be turned up at run time -- but only by
        # someone who can type at the shell, which until now nothing here
        # could do.  Written on a second, write-only handle: the reader
        # thread already holds the port, and sharing one IO across threads
        # for opposite directions is a race waiting for a long bench run.
        if cmd = opts[:command]
            sleep(opts[:reset] ? 2 : 0.5)   # let the shell come up
            connected.each do |name, hopts|
                dev_tty = Platform.usb_to_tty(hopts[:usb])
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
    end

    # Stdin to the board, a line at a time.
    #
    # On a second, write-only handle for the same reason --command
    # uses one: the reader thread holds the port, and one IO shared
    # across two threads for opposite directions is a race waiting for
    # a long bench run.  What comes back is printed by that thread,
    # prefixed like everything else, so the answer to what was typed
    # appears where the rest of the board's output does.
    #
    # Lines, not characters: the shell on the far end wants a complete
    # line terminated by \r, and there is nowhere here to run a line
    # editor.  Over ssh -t that is no loss -- the pty at the other end
    # of the connection does the editing and the echo, so what arrives
    # is already the line that was meant.
    def interact(connected)
        unless connected.size == 1
            raise Error, 'connect: --interactive takes a single device'
        end
        name, hopts = connected.first
        dev_tty = Platform.usb_to_tty(hopts[:usb])
        tty&.info "Typing at #{name} (^D to leave)"
        File.open(dev_tty, File::WRONLY | File::NOCTTY) do |w|
            w.sync = true
            while line = $stdin.gets
                w.write("#{line.chomp}\r")
            end
        end
    end
end
end

end
