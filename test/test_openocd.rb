# frozen_string_literal: true

require_relative 'helper'

# The openocd command line, which is where every board-specific devlist
# key ends up and the only place they can be seen to have arrived.
class TestOpenocd < Minitest::Test
    include DevlistHelper

    # The command a run would have executed, without executing it.
    def issued(cli, **hopts)
        captured = nil
        fake = lambda do |*cmd|
            captured = cmd
            [ '', Struct.new(:exitstatus).new(0) ]
        end
        Open3.stub(:capture2e, fake) { cli.openocd('init', **hopts) }
        captured
    end

    def cli
        @cli ||= cli_for("A1 { port = 1 }", '--openocd=/usr/bin/true')
    end

    def test_the_defaults_are_what_the_constants_used_to_be
        c = issued(cli).join(' ')
        assert_includes c, 'set WORKAREASIZE 0x4000'
        assert_includes c, 'source [find interface/cmsis-dap.cfg]'
        assert_includes c, 'transport select swd'
        assert_includes c, 'source [find target/nrf52.cfg]'
    end

    def test_every_key_reaches_the_command_line
        c = issued(cli, interface: 'jlink', target: 'nrf53',
                        transport: 'jtag', work_area: 0x800).join(' ')
        assert_includes c, 'source [find interface/jlink.cfg]'
        assert_includes c, 'source [find target/nrf53.cfg]'
        assert_includes c, 'transport select jtag'
        assert_includes c, 'set WORKAREASIZE 0x800'
    end

    # 'none' leaves the choice to the scripts rather than asserting one.
    def test_none_omits_the_line_entirely
        c = issued(cli, transport: 'none', work_area: nil).join(' ')
        refute_includes c, 'transport select'
        refute_includes c, 'WORKAREASIZE'
    end

    def test_a_serial_selects_and_a_usb_path_documents
        c = issued(cli, serial: '01', usb: '1-1.2.1.1').join(' ')
        assert_includes c, 'adapter serial 01'
        assert_includes c, 'adapter usb location 1-1.2.1.1'
    end

    def test_neither_is_passed_when_neither_is_known
        c = issued(cli).join(' ')
        refute_includes c, 'adapter serial'
        refute_includes c, 'adapter usb location'
    end

    def test_it_always_shuts_the_session_down
        assert_equal 'shutdown', issued(cli).last
    end

    # Errno::ENOENT once per board from inside the thread pool, after
    # the ports were up and the warm-up slept through, is what this
    # replaced.
    def test_a_missing_openocd_is_named_before_anything_runs
        c = cli_for("A1 { port = 1 }", '--openocd=/nonexistent/openocd')
        e = assert_raises(TribbleControl::CLI::Error) { c.openocd_path }
        assert_match(%r{openocd not found at '/nonexistent/openocd'}, e.message)
    end

    # A name with no separator goes through PATH, which is how to
    # reach openocd on a host that keeps it somewhere other than
    # /usr/bin -- FreeBSD puts it under /usr/local.
    def test_a_bare_name_is_looked_up_in_path
        path = cli_for("A1 { port = 1 }", '--openocd=ls').openocd_path
        assert_match(%r{/ls\z}, path)
        assert File.executable?(path), "#{path} is not executable"
        refute_equal 'ls', path, 'the bare name was not resolved'
    end
end
