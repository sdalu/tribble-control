#
# What a board's console output means.
#
require_relative 'cli'

module TribbleControl

# A running count of what a board printed, and one line saying so.
#
# `connect` knows how to open a board's console, prefix its lines and
# print them.  What a line MEANS -- a completed exchange, a failure, a
# banner, noise -- is the firmware's business, and firmware is not what
# this tool is about: the strings to look for change with every build
# of every project that ever sits on this hub, and none of them belong
# in a program whose subject is a USB hub.
#
# So they are not here.  A tally is the seam: `connect` hands it every
# line it prints and asks it, once, for a summary.  The one below
# counts lines, which is all a tool that knows nothing about the
# firmware can honestly say.  Anything that knows more is a block,
# registered from a file loaded with -r/--require:
#
#     TribbleControl::Tally.register(:twr) do |device|
#         MyTally.new(device)
#     end
#
# and chosen with `tally = twr` in the devlist, for the whole bench or
# for one board.  The block is called once per board per run, so a
# tally may keep whatever state it likes without sharing it.
class Tally
    @registry = {}

    class << self
        # Register a tally builder under +name+.  The block is given a
        # device name and must return an object answering #<<, which
        # receives every line, and #summary, which returns the text of
        # the SUMMARY line or nil for no summary at all.
        def register(name, &block)
            raise ArgumentError, 'a tally needs a block' if block.nil?
            @registry[name.to_s] = block
        end

        def registered = @registry.keys.sort

        # Build the tally called +name+ for the device +device+.
        #
        # An unknown name is an error rather than a silent fallback to
        # counting lines: a devlist asking for 'twr' on a run that
        # forgot -r would otherwise capture a whole bench and report
        # nothing but line counts, which reads as a firmware saying
        # nothing rather than as a missing file.
        def build(name, device)
            builder = @registry[name.to_s]
            if builder.nil?
                raise CLI::Error, "unknown tally '#{name}'" \
                                  " (known: #{self.registered.join(', ')})." \
                                  ' A tally other than the built-in ones' \
                                  ' comes from a file given with --require'
            end
            builder.call(device)
        end
    end

    def initialize(device)
        @device = device
        @lines  = 0
    end

    def <<(_line)
        @lines += 1
        self
    end

    def summary = "lines=#{@lines}"
end

# The default, and the only one this tool ships: a board printed this
# many lines.
Tally.register(:lines) {|device| Tally.new(device) }

# Counts nothing, says nothing: for a capture that wants the lines and
# no SUMMARY at all.  A null object rather than nil, so that `connect`
# has one kind of thing to talk to.
class NullTally
    def initialize(device) ; @device = device ; end
    def <<(_line)          = self
    def summary            = nil
end

Tally.register(:none) {|device| NullTally.new(device) }

end
