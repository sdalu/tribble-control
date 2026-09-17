# frozen_string_literal: true

require_relative 'helper'

# types { }: settings a device inherits, and the three things a type
# may not do.
class TestTypes < Minitest::Test
    include DevlistHelper

    TYPES = <<~UCL
        types {
          mdk { interface = cmsis-dap, target = nrf52, baud = 230400 }
          dwm { interface = jlink, baud = 115200, power_cycle = after-flash }
        }
    UCL

    def test_a_device_inherits_its_type
        cli = cli_for(TYPES + "A1 { type = mdk, port = 1 }")
        assert_equal 'cmsis-dap', cli.interface('A1')
        assert_equal 230_400,     cli.baud('A1')
    end

    def test_a_type_may_carry_power_cycle
        cli = cli_for(TYPES + "D1 { type = dwm, port = 1 }")
        assert cli.power_cycle?('D1', 'after-flash')
        assert_equal 'jlink', cli.interface('D1')
    end

    # A type is what a KIND has in common; the entry is about itself.
    def test_the_device_wins_over_its_type
        cli = cli_for(TYPES + "A1 { type = mdk, baud = 9600, port = 1 }")
        assert_equal 9600,        cli.baud('A1')
        assert_equal 'cmsis-dap', cli.interface('A1')
    end

    def test_a_key_in_neither_falls_back_to_the_tool
        cli = cli_for(TYPES + "A1 { type = mdk, port = 1 }")
        assert_equal 'swd', cli.transport('A1')
    end

    def test_a_device_without_a_type_is_untouched
        cli = cli_for(TYPES + "P1 { port = 1 }")
        assert_equal 'cmsis-dap', cli.interface('P1')
        assert_equal 230_400,     cli.baud('P1')
    end

    def test_types_is_not_a_device
        cli = cli_for(TYPES + "A1 { type = mdk, port = 1 }")
        assert_equal [ 'A1' ], cli.declared
    end

    # A board that asked for jlink and silently got cmsis-dap is a
    # flash through the wrong probe, reported as success.
    def test_an_undefined_type_is_refused
        msg = refusal_for(TYPES + "A1 { type = nope, port = 1 }")
        assert_match(/which types does not define/, msg)
        assert_match(/known: dwm, mdk/, msg)
    end

    def test_a_type_may_not_name_one_board
        assert_match(/cannot be shared/,
                     refusal_for("types { m { port = 3 } }\nA1 { type = m, port = 1 }"))
        assert_match(/cannot be shared/,
                     refusal_for("types { m { serial = 'x' } }\nA1 { type = m, port = 1 }"))
    end

    def test_types_do_not_nest
        assert_match(/do not nest/,
                     refusal_for("types { m { type = other } }\nA1 { type = m, port = 1 }"))
    end

    def test_types_must_be_a_block
        assert_match(/block of named definitions/,
                     refusal_for("types = 3\nA1 { port = 1 }"))
    end
end
