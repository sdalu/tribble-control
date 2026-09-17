# frozen_string_literal: true

require_relative 'helper'

# The devlist layer: what a device list means, and what it refuses.
#
# Every one of these was a live defect or a rule the tool now depends
# on, and all of them were decided before the hub object is used, so
# none of them needs a hub.
class TestDevlist < Minitest::Test
    include DevlistHelper

    def test_a_port_is_required
        assert_match(/has no port/, refusal_for("A1 { serial = '01' }"))
    end

    def test_port_none_is_declared_but_not_present
        cli = cli_for("A1 { port = 1 }\nOld { port = none }")
        assert_equal [ 'A1' ], cli.devices
        assert_equal [ 'A1', 'Old' ], cli.declared
        refute cli.present?('Old')
    end

    def test_two_boards_on_one_port_are_refused
        assert_match(/same port more than once/,
                     refusal_for("A1 { port = 1 }\nA2 { port = 1 }"))
    end

    def test_several_entries_may_declare_no_port
        assert_nil refusal_for("A1 { port = none }\nA2 { port = none }")
    end

    # port = '8' loaded, counted as present, and then left the board
    # unswitchable with "port out of range" and unnamed in usb status.
    def test_a_quoted_port_is_normalised
        cli = cli_for("A1 { port = '8' }")
        assert_equal 8, cli.attribute('A1', 'port')
        assert_equal [ 8 ], cli.port_list([ 'A1' ])
    end

    def test_a_port_that_is_neither_a_number_nor_none_is_refused
        assert_match(/neither a port number nor none/,
                     refusal_for("A1 { port = wherever }"))
    end

    # attribute() returned its default for a key set to false, so
    # 'power_cycle = false' read as absent.
    def test_a_key_set_to_false_is_present
        cli = cli_for("A1 { port = 1, power_cycle = false }")
        assert_equal false, cli.attribute('A1', 'power_cycle', 'DEFAULT')
    end

    def test_defaults_when_a_key_is_absent
        cli = cli_for("A1 { port = 1 }")
        assert_equal 'cmsis-dap', cli.interface('A1')
        assert_equal 'nrf52',     cli.target('A1')
        assert_equal 'swd',       cli.transport('A1')
        assert_equal 0x4000,      cli.work_area('A1')
        assert_equal 230_400,     cli.baud('A1')
        assert_equal 'lines',     cli.tally('A1')
    end

    def test_work_area_takes_hex_or_none_and_refuses_the_rest
        assert_equal 0x800, cli_for("A1 { port = 1, work_area = 0x800 }").work_area('A1')
        assert_nil          cli_for("A1 { port = 1, work_area = none }").work_area('A1')
        e = assert_raises(TribbleControl::CLI::Error) {
            cli_for("A1 { port = 1, work_area = plenty }").work_area('A1') }
        assert_match(/neither a size nor none/, e.message)
    end

    def test_reserved_and_undeclared_are_not_devices
        cli = cli_for("reserved = [ 16 ]\nundeclared = switch\nA1 { port = 1 }")
        assert_equal [ 'A1' ], cli.declared
    end

    # 'undeclared = protect' is what keeps a power feed out of reach.
    def test_switchable_respects_reserved_and_undeclared
        cli = cli_for("reserved = [ 2 ]\nA1 { port = 1 }\nA2 { port = 2 }")
        assert_equal [ 1 ], cli.switchable
        refute cli.offable?(2, force: false)
        assert cli.offable?(2, force: true)
    end

    def test_undeclared_switch_opens_every_port
        cli = cli_for("undeclared = switch\nA1 { port = 1 }")
        assert_equal (1..16).to_a, cli.switchable
    end

    def test_a_bad_undeclared_value_is_refused
        assert_match(/must be one of/,
                     refusal_for("undeclared = maybe\nA1 { port = 1 }"))
    end

    # An empty list means "every port we may touch", never "all 16".
    def test_offable_refuses_a_protected_port_by_name
        cli = cli_for("reserved = [ 2 ]\nA1 { port = 1 }\nA2 { port = 2 }")
        assert_equal [ 1 ], cli.offable([])
        e = assert_raises(TribbleControl::CLI::Error) { cli.offable([ 2 ]) }
        assert_match(/refusing to power down port\(s\) 2/, e.message)
    end

    def test_a_port_out_of_range_is_refused
        cli = cli_for("A1 { port = 1 }")
        assert_raises(TribbleControl::CLI::Error) { cli.port_list([ '17' ]) }
    end

    def test_naming_an_absent_board_says_which
        cli = cli_for("A1 { port = 1 }\nOld { port = none }")
        e = assert_raises(TribbleControl::CLI::Error) { cli.name_port('Old') }
        assert_match(/is not on the bench/, e.message)
    end
end
