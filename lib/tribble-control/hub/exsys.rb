# frozen_string_literal: true

#
# The ExSYS 16-port managed hub, over the FT232 serial line wired
# inside it.  The exsys gem speaks the frames; this class says which
# hub, and answers the Hub interface with it.
#
require 'exsys'
require 'exsys/managed-usb'

require_relative '../hub'

module TribbleControl
class Hub

class ExSYS < Hub
    # The gem's class, named once.  Inside this class the bare
    # constant ExSYS is this class, not the gem's module.
    GEM = ::ExSYS::ManagedUSB

    # The USB id of a hub's control adapter, for the messages that name
    # it.  Asked of the gem rather than written out: it is a fact about
    # the hardware, the gem is what knows it, and a literal here would
    # go on saying 0403:6001 after the gem had stopped looking for that.
    CTRL_ID = "#{GEM::CTRL_VENDOR}:#{GEM::CTRL_PRODUCT}".freeze

    # Every FTDI 0403:6001 the host has, as the gem reports them:
    # { device:, serial:, usb_path: }.  Reports; decides nothing.  The
    # gem's own errors -- a host it cannot look on -- become ours.
    def self.available = guard { GEM.available }

    # The hub +named+ names, or the one hub the host has.
    #
    # Three shapes of name, told apart by what they look like, no two
    # of which can be confused:
    #
    #   /dev/ttyUSB1   a '/' in it, so a device node, used as given --
    #                  the same rule --openocd uses to tell a path from
    #                  a name to look up
    #   1-1.2.4.4      the USB path shape (GEM::USB_PATH), so the
    #                  adapter in that socket
    #   AL03GD7X       anything else, so an FT232 serial number
    #
    # The node is the worst of the three to write down.  The number in
    # /dev/ttyUSB1 is not the hub's, and not the USB device number
    # either: it is the usbserial layer's own index, and it is the
    # LOWEST ONE FREE when the adapter is probed (ttyU on FreeBSD,
    # allocated the same way).  So it depends on what else was attached
    # first, and it is reused -- unplug the adapter holding ttyUSB0 and
    # the next thing to attach becomes ttyUSB0.  Two hubs can therefore
    # swap names across a reboot, or while the machine is up, and every
    # devlist naming them that way is then pointed at the other bench.
    #
    # The other two are both stable, and they answer different
    # questions.  A serial stays with the ADAPTER: move the hub to
    # another socket or another machine and its serial goes with it.  A
    # USB path stays with the SOCKET: whatever is plugged in there
    # answers to it, a replacement hub included.  Naming one particular
    # hub is the serial's job and is the usual want.  The path is for
    # the hub whose EEPROM carries no serial to be named by -- its only
    # stable name -- and for a bench where the socket is the fixed
    # thing.  Both platforms report one, but each in its own numbering,
    # so a path names a socket on the host that reported it and does
    # not travel to another.
    #
    # Auto-detection is a guess, and it is only a safe guess while
    # there is one candidate.  The gem reports every FTDI 0403:6001 on
    # the host, which is a hub's control adapter and also every other
    # FT232 attached -- the gem says so itself, and deliberately
    # reports rather than decides, because telling them apart means
    # opening the line and writing to it.  Two of them used to make
    # this a coin toss decided by enumeration order, settled silently,
    # on a command that then switched somebody else's ports.  It
    # refuses instead, and lists what it found with the serials to
    # choose between them.
    def self.open(named, password: nil)
        if named&.include?(File::SEPARATOR)
            # A line named outright is used as given, and discovery is
            # not required to succeed for that to work -- naming it is
            # the escape hatch for a host discovery cannot answer on.
            # It is still ASKED, quietly, because a line that IS a
            # known candidate brings its USB path with it, and that is
            # what --method usb needs; see #usb_path.
            return new(named, ctrl: candidate_for(named), password: password)
        end

        found = available
        ctrl  = if named
                then match(named, found)
                else lone(found)
                end
        new(ctrl[:device], ctrl: ctrl, password: password)
    end

    # The one candidate +named+ names among +found+, or an error.
    def self.match(named, found)
        key, what = if GEM::USB_PATH.match?(named)
                    then [ :usb_path, 'at USB path' ]
                    else [ :serial,   'with serial'  ]
                    end
        match = found.select {|c| c[key] == named }
        case match.size
        when 1 then match.first
        when 0
            # A path that matched nothing on a host reporting no
            # paths at all is a different mistake from a path that
            # is simply not this one, and saying "not found" would
            # send the reader hunting for a socket.
            if key == :usb_path && found.none? {|c| c[:usb_path] }
                raise Error, "no FTDI #{CTRL_ID} at USB path '#{named}':" \
                             ' this host reports no USB path for any of' \
                             ' its serial lines, so none can be named' \
                             ' that way.  Name the hub by the serial of' \
                             " its FT232 instead (#{seen(found)})"
            end
            raise Error, "no FTDI #{CTRL_ID} #{what} '#{named}' on this" \
                         " host (#{seen(found)}).  A name with a '/' in" \
                         ' it is taken as the path of a serial line, one' \
                         ' shaped 1-1.2.4.4 as a USB path, and anything' \
                         ' else as an FT232 serial number'
        else
            raise Error, "#{match.size} FTDI #{CTRL_ID} are #{what}" \
                         " '#{named}' (#{seen(found)}): name the line by" \
                         ' path instead'
        end
    end

    # The one candidate the host has, when it has exactly one.
    def self.lone(found)
        case found.size
        when 1 then found.first
        when 0
            raise Error, 'unable to auto-detect the hub control line:' \
                         " no FTDI #{CTRL_ID} on this host.  Name it" \
                         " with -d, or with a 'device =' line in the" \
                         ' devlist'
        else
            raise Error, 'unable to auto-detect the hub control line:' \
                         " #{found.size} FTDI #{CTRL_ID} adapters on this" \
                         " host (#{seen(found)}).  Name the one to drive" \
                         " with -d, or with a 'device =' line in the" \
                         ' devlist'
        end
    end

    # The candidate the host reports for a line named outright, or nil.
    #
    # Quietly: naming a line is the escape hatch for a host discovery
    # cannot answer on -- a pty under test, a node discovery does not
    # know -- so a discovery that fails here must not take the run with
    # it.  What is lost when it does is the USB path, and with it
    # --method usb, which says so at the point it needs one.
    def self.candidate_for(line)
        available.find {|c| c[:device] == line }
    rescue Error
        nil
    end

    # What the host has, as a refusal lists it.
    def self.seen(found)
        return 'none found' if found.empty?
        "found: #{found.map {|c| describe(c) }.join(', ')}"
    end

    # One candidate, as an error message names it.
    #
    # The serial leads, that being what the reader is meant to copy
    # into a devlist, and the USB path follows it in brackets where the
    # host reports one -- for the adapter with no serial it is the only
    # stable name there is, and a refusal is where somebody goes
    # looking for it.
    def self.describe(ctrl)
        name = if ctrl[:serial]
               then "#{ctrl[:serial]} on #{ctrl[:device]}"
               else "#{ctrl[:device]}, which reports no serial"
               end
        ctrl[:usb_path] ? "#{name} [#{ctrl[:usb_path]}]" : name
    end

    # The gem's errors are the hub layer's to report, not to leak: it
    # raises both for a hub that refuses a command (E01 on a wrong
    # password) and for a host it cannot look for a hub on.  Both are
    # operator errors with nothing to debug, so both become Hub::Error
    # carrying the same words.
    def self.guard
        yield
    rescue GEM::Error => e
        raise Error, e.message
    end

    private_class_method :match, :lone, :seen, :describe

    # +line+ is the serial line; +ctrl+ the candidate it was chosen
    # from, when discovery knew it, which is where the USB path comes
    # from.  The line is not opened here: the gem opens it on first
    # use and locks it for the duration of each call.
    def initialize(line, ctrl: nil, password: nil)
        super()
        @line = line
        @ctrl = ctrl
        @gem  = GEM.new(line, password)
    end

    # The serial line, as it was named or found.
    attr_reader :line

    def to_s  = @line
    def ports = GEM::PORTS
    def state = guard { @gem.get(:ports) }

    def on(*list)     = guard { @gem.on(*selection(list)) }
    def off(*list)    = guard { @gem.off(*selection(list)) }
    def toggle(*list) = guard { @gem.toggle(*selection(list)) }

    # One exchange: the gem reads the port word, applies the whole
    # change and writes it back under a single hold of the line.
    def set(changes, default = nil) = guard { @gem.set(changes, default) }

    # Four internal banks of four, so a board on +port+ is at
    # <root>.bank.slot.  The root is the control adapter's own path
    # less its last two components: the FT232 is wired at the last
    # position of that internal tree, <root>.4.4, which is also why a
    # board must never be put on port 16 -- --method usb would compute
    # the adapter's own path for it.  See THE HUB in the manual.
    #
    # nil when there is nothing to work it out from -- a line named
    # outright that discovery does not know, a host that reports no
    # USB path for it, or an adapter plugged straight into a root port
    # and therefore not inside a hub at all.
    def usb_path(port)
        return nil unless (root = self.usb_root)
        bank = ((port - 1) / 4) + 1
        slot = ((port - 1) % 4) + 1
        "#{root}.#{bank}.#{slot}"
    end

  private

    def guard(&) = self.class.guard(&)

    def usb_root
        parts = @ctrl&.dig(:usb_path)&.split('.')
        return nil if parts.nil? || parts.size < 3
        parts[0..-3].join('.')
    end
end

end
end
