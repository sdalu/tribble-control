# frozen_string_literal: true

# One FreeBSD host's USB hubs, as sysctl and usbconfig report them.
#
# This is what lets the USB hub backend be tested without a hub: it is
# callable, so it IS the runner the backend is handed, and it answers
# the two commands the backend runs -- `sysctl -e dev.uhub` with a
# tree in the real format, and `usbconfig -d ugenX.Y do_request ...`
# with the exact text usbconfig prints, angle brackets, trailing ASCII
# copy and all.
#
# Three things about that text are easy to get wrong, and getting them
# wrong here is the point of writing them down:
#
#   * the payload is printed TWICE, once as bytes and once as whatever
#     those bytes spell -- '<0x09 0x29 ...><)>' -- so a parser that
#     takes the last bracketed group parses ')'.
#   * the power bit is not the same bit on both kinds of hub: a USB 2
#     hub reports it in 0x0100, a SuperSpeed hub in 0x0200, and a
#     SuperSpeed port that is merely empty already has 0x00a0 set for
#     its link state.
#   * a refused request -- an unknown descriptor, a port the hub has
#     not got -- prints '<ERROR>' and still exits 0.
#
# +honours+ false is a hub that accepts a switch and does not switch:
# ganged, or with no power switch wired.  It answers OK and leaves the
# port as it was, which is the only way to drive the backend's
# read-back check.
class FakeUsbconfig
    # One hub on the fake host.  A root hub is one with no +device+:
    # sysctl gives it an empty %location and a usbusN for a parent,
    # which is how a walk knows it has reached the top.
    DEFAULTS = {
        :unit    => 0,      :device  => nil,   :parent  => 'usbus1',
        :bus     => 1,      :port    => 1,     :serial  => '',
        :vendor  => '0x0451', :product => '0x8142',
        :type    => 0x29,   :ports   => 4,     :chars   => 0x000d,
        :powered => nil,    :present => [],    :honours => true
    }.freeze

    # Printable ASCII, which is the only part of a payload usbconfig
    # repeats after the bytes.
    PRINTABLE = (0x20..0x7e)

    attr_reader :log

    # +denied+ makes every usbconfig call answer as it does for an
    # operator who is not in group operator.
    def initialize(hubs, denied: false)
        @hubs   = hubs.map {|h| DEFAULTS.merge(h) }
        @denied = denied
        @log    = []
        @hubs.each {|h|
            h[:powered] ||= (1..h[:ports]).to_h {|p| [ p, true ] }
        }
    end

    # The runner the backend is handed.
    def call(*argv)
        @log << argv
        case File.basename(argv.first)
        when 'sysctl'    then sysctl
        when 'usbconfig' then usbconfig(argv)
        else raise ArgumentError, "FakeUsbconfig: nothing runs #{argv.first}"
        end
    end

    # Which ports of a hub are powered, for a test to assert on.
    def powered(device) = hub(device)[:powered]

    def hub(device) = @hubs.find {|h| h[:device] == device }

  private

    def sysctl
        @hubs.map {|h| lines_for(h) }.join + "dev.uhub.%parent=\n"
    end

    def lines_for(h)
        at = "dev.uhub.#{h[:unit]}"
        [ "#{at}.%parent=#{h[:parent]}\n",
          "#{at}.%pnpinfo=#{pnpinfo(h)}\n",
          "#{at}.%location=#{location(h)}\n",
          "#{at}.%desc=vendor #{h[:vendor]} product #{h[:product]}," \
          " class 9/0, rev 2.10/1.00, addr #{h[:unit]}\n" ].join
    end

    # A root hub states neither of these, which is what a walk up the
    # tree stops at.
    def location(h)
        return '' unless h[:device]
        [ "bus=#{h[:bus]}", 'hubaddr=1', "port=#{h[:port]}", 'devaddr=2',
          'interface=0', "ugen=#{h[:device]}" ].join(' ')
    end

    def pnpinfo(h)
        return '' unless h[:device]
        [ "vendor=#{h[:vendor]}", "product=#{h[:product]}",
          'devclass=0x09', 'devsubclass=0x00', 'devproto=0x02',
          %(sernum="#{h[:serial]}"), 'release=0x0100', 'mode=host',
          'intclass=0x09', 'intsubclass=0x00', 'intprotocol=0x02' ].join(' ')
    end

    def usbconfig(argv)
        _bin, _d, device, _do, type, request, value, index, _len = argv
        return "usbconfig: #{device}: Permission denied\n" if @denied
        h = hub(device)
        return "No device match or lack of permissions.\n" if h.nil?
        case [ type, request ]
        when %w[0xa0 0x06] then descriptor(h, value)
        when %w[0xa3 0x00] then status(h, index.to_i)
        when %w[0x23 0x01] then feature(h, value, index.to_i, false)
        when %w[0x23 0x03] then feature(h, value, index.to_i, true)
        else                    reply('ERROR')
        end
    end

    # A hub answers its own descriptor type and refuses the other one,
    # which is how the backend finds out which kind of hub it is.
    def descriptor(h, value)
        return reply('ERROR') unless value == format('0x%04x', h[:type] << 8)
        bytes = if h[:type] == 0x29
                then [ 0x09, 0x29, h[:ports], h[:chars] & 0xff, h[:chars] >> 8,
                       0x00, 0x00, 0x10, 0xff ]
                else [ 0x0c, 0x2a, h[:ports], h[:chars] & 0xff, h[:chars] >> 8,
                       0x32, 0x90, 0x04, 0x5e, 0x01, 0x00, 0x00 ]
                end
        payload(bytes)
    end

    # wPortStatus and wPortChange, as the two kinds of hub report them.
    # A port that is not powered shows no device: the hub cannot see
    # one it is not feeding.
    def status(h, port)
        return reply('ERROR') unless (1..h[:ports]).cover?(port)
        on   = h[:powered][port]
        here = on && h[:present].include?(port)
        word = if h[:type] == 0x29
               then (here ? 0x0003 | 0x0400 : 0x0000) | (on ? 0x0100 : 0x0000)
               else (here ? 0x0003 : 0x00a0) | (on ? 0x0200 : 0x0000)
               end
        payload([ word & 0xff, word >> 8, 0x00, 0x00 ])
    end

    def feature(h, value, port, on)
        return reply('ERROR') unless value == '0x0008'
        return reply('ERROR') unless (1..h[:ports]).cover?(port)
        h[:powered][port] = on if h[:honours]
        reply('OK')
    end

    def payload(bytes)
        hex = bytes.map {|b| format('0x%02x', b) }.join(' ')
        "REQUEST = <#{hex}><#{bytes.select {|b| PRINTABLE.cover?(b) }.pack('C*')}>\n"
    end

    def reply(text) = "REQUEST = <#{text}>\n"
end
