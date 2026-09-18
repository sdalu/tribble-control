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

    def test_protect_is_not_a_device
        cli = cli_for("protect { ports = [ 16 ], undeclared = no }\nA1 { port = 1 }")
        assert_equal [ 'A1' ], cli.declared
    end

    # The block is what keeps a power feed out of reach.
    def test_switchable_respects_protected_ports
        cli = cli_for("protect { ports = [ 2 ] }\nA1 { port = 1 }\nA2 { port = 2 }")
        assert_equal [ 1 ], cli.switchable
        refute cli.offable?(2, force: false)
        assert cli.offable?(2, force: true)
    end

    # A node protects the port its own entry gives, so the number is
    # written once and the protection follows a board that moves.
    def test_a_protected_node_protects_the_port_it_is_on
        cli = cli_for("protect { nodes = [ A2 ] }\nA1 { port = 1 }\nA2 { port = 2 }")
        assert_equal [ 1 ], cli.switchable
        refute cli.offable?(2, force: false)
    end

    # A typo here would read as protection and be none.
    def test_a_protected_node_nothing_declares_is_refused
        assert_match(/does not declare/,
                     refusal_for("protect { nodes = [ A9 ] }\nA1 { port = 1 }"))
    end

    # A retired board keeps its entry; protecting its name stays legal
    # and protects nothing, there being no port to keep powered.
    def test_a_protected_node_with_no_port_protects_nothing
        cli = cli_for("protect { nodes = [ Old ] }\nA1 { port = 1 }\nOld { port = none }")
        assert_equal [ 1 ], cli.switchable
    end

    def test_undeclared_no_opens_every_port
        cli = cli_for("protect { undeclared = no }\nA1 { port = 1 }")
        assert_equal (1..16).to_a, cli.switchable
    end

    def test_a_bad_undeclared_value_is_refused
        assert_match(/must be yes or no/,
                     refusal_for("protect { undeclared = maybe }\nA1 { port = 1 }"))
    end

    # 'port' for 'ports' was silently ignored, which reads in the file
    # exactly like protection and is none.
    def test_an_unknown_key_in_the_block_is_refused
        assert_match(/has no port key/,
                     refusal_for("protect { port = [ 13 ] }\nA1 { port = 1 }"))
    end

    def test_protect_must_be_a_block
        assert_match(/must be a block/,
                     refusal_for("protect = [ 13 ]\nA1 { port = 1 }"))
    end

    # The two keys the block replaced are met by name: left to the
    # device pass they would be refused as entries with no port.
    def test_the_former_keys_say_what_to_write_instead
        assert_match(/'reserved' is no longer a devlist key/,
                     refusal_for("reserved = [ 16 ]\nA1 { port = 1 }"))
        assert_match(/'undeclared' is no longer a devlist key/,
                     refusal_for("undeclared = switch\nA1 { port = 1 }"))
    end

    # An empty list means "every port we may touch", never "all 16".
    def test_offable_refuses_a_protected_port_by_name
        cli = cli_for("protect { ports = [ 2 ] }\nA1 { port = 1 }\nA2 { port = 2 }")
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
