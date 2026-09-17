# frozen_string_literal: true

require 'pty'

# A 16-port ExSYS hub, on a pty, speaking the frames the real one does.
#
# This is what lets the hub layer be tested without a hub: the exsys
# gem talks to it over a real tty with real framing -- GP to read the
# port state, SP to write it, ?Q to identify itself -- so what is
# exercised is the actual serial exchange and not a stub standing in
# for it.
#
# The state word goes out low byte first, which is the one thing about
# this protocol that is easy to get backwards: C4FFFFFF is ports 3 and
# 7 upward, not 0xC4FFFFFF read left to right. Writing this emulator
# big-endian was caught immediately by the real gem refusing to agree
# with it, which is the sort of thing an emulator is for.
class FakeHub
    attr_reader :path, :log

    def initialize(state: 0x0000, password: 'pass')
        @master, @slave = PTY.open
        @path     = @slave.path
        @state    = state
        @password = password
        @log      = []
        @thread   = Thread.new { serve }
        @thread.abort_on_exception = true
    end

    # Which ports the hub currently has powered.
    def ports_on = (1..16).select {|p| @state[p - 1] == 1 }

    def close
        @thread&.kill
        @master&.close
        @slave&.close
    end

  private

    def serve
        buf = +''
        loop do
            buf << @master.readpartial(256)
            handle(buf.slice!(0..buf.index("\r")).chomp("\r")) while buf.index("\r")
        end
    rescue IOError, Errno::EIO          # IOError covers EOFError
        # the other end went away
    end

    def handle(cmd)
        @log << cmd
        case cmd
        when '?Q' then reply 'CENTOS000516v02'
        when 'GP' then reply encode(@state)
        when /\A(?:SP|FP)(.{8})(\h+)\z/
            return reply 'E01' unless $1 == @password.ljust(8)
            @state = decode($2)
            reply 'G'
        when /\A(?:WP|RD|CP|RH)/ then reply 'G'
        else                          reply 'E01'
        end
    end

    def encode(word) = 4.times.map {|i| format('%02X', (word >> (8 * i)) & 0xff) }.join
    def decode(hex) = hex.scan(/\h\h/).each_with_index.sum {|byte, i| byte.to_i(16) << (8 * i) }

    def reply(text) = @master.write("#{text}\r\n")
end
