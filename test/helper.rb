# frozen_string_literal: true

# The tests that need no hub.
#
# Everything here runs on a workstation: the devlist layer, the tally
# registry, the openocd command line, and -- through test/support's pty
# emulator -- the hub exchange itself. test/test-tribble-control is the
# other half, and needs the bench.

require 'minitest/autorun'
require_relative '../lib/tribble-control'
require_relative 'support/fake_hub'

module DevlistHelper
    # A CLI parsed against a devlist written for this one test.
    #
    # -d names a path nothing opens: ManagedUSB's constructor stores
    # the line and opens it on first use, so a CLI can be built and
    # its devlist interrogated without a hub existing.
    # +argv+ are global options; +command+ is the one parse insists on
    # having, and 'usb' is the one that reaches the hub for nothing.
    # <tt>device: nil</tt> leaves -d off altogether, which is how the
    # tests of the other two answers -- the devlist's own line, and the
    # host -- get parse to look for one.
    def cli_for(devlist, *argv, command: 'usb', device: File::NULL)
        file = File.join(Dir.mktmpdir('tribble-test'), 'devlist.conf')
        File.write(file, devlist)
        @tmpdirs = (@tmpdirs || []) << File.dirname(file)
        named    = device.nil? ? [] : [ '-d', device ]
        TribbleControl::CLI.new
                         .parse([ *named, '-D', file, *argv, command ])
                         .tap {|cli| quieten(cli) }
    end

    # The log goes to a buffer, not the terminal: a test run should say
    # what failed and nothing else. #log_of reads it back for a test
    # that cares what was reported.
    def quieten(cli)
        @logs ||= {}
        @logs[cli] = StringIO.new
        cli.instance_variable_set(:@tty, TTY::Logger.new {|c|
            c.output = @logs[cli]
            c.level  = :debug
        })
        cli
    end

    def log_of(cli) = @logs.fetch(cli).string

    # The error a devlist is refused with, or nil if it loads.  Hub
    # selection refuses as Hub::Error, the devlist itself as CLI::Error.
    def refusal_for(devlist, *argv, **kws)
        cli_for(devlist, *argv, **kws)
        nil
    rescue TribbleControl::CLI::Error, TribbleControl::Hub::Error => e
        e.message
    end

    def teardown
        Array(@tmpdirs).each {|d| FileUtils.remove_entry(d) }
        super
    end
end

require 'tmpdir'
require 'fileutils'
require 'stringio'
