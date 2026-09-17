# frozen_string_literal: true

require_relative 'helper'

# The seam where firmware knowledge goes, and stays out of the tool.
class TestTally < Minitest::Test
    include DevlistHelper

    def teardown
        TribeControl::Tally.instance_variable_get(:@registry).delete('probe')
        super
    end

    def test_the_default_counts_lines
        t = TribeControl::Tally.build('lines', 'A1')
        t << "one\n" ; t << "two\n"
        assert_equal 'lines=2', t.summary
    end

    def test_none_says_nothing
        t = TribeControl::Tally.build('none', 'A1')
        t << "one\n"
        assert_nil t.summary
    end

    def test_a_registered_block_is_built_per_device
        seen = []
        TribeControl::Tally.register(:probe) {|device| seen << device ; Object.new }
        TribeControl::Tally.build('probe', 'A1')
        TribeControl::Tally.build('probe', 'A2')
        assert_equal %w[A1 A2], seen
    end

    # Never a quiet fall back to counting lines: that reads exactly
    # like a bench that has gone silent.
    def test_an_unregistered_tally_is_an_error
        e = assert_raises(TribeControl::CLI::Error) {
            TribeControl::Tally.build('twr', 'A1') }
        assert_match(/unknown tally 'twr'/, e.message)
        assert_match(/--require/, e.message)
    end

    def test_register_wants_a_block
        assert_raises(ArgumentError) { TribeControl::Tally.register(:probe) }
    end

    def test_the_devlist_chooses_it_per_bench_and_per_board
        cli = cli_for("tally = none\nA1 { port = 1 }\nA2 { port = 2, tally = lines }")
        assert_equal 'none',  cli.tally('A1')
        assert_equal 'lines', cli.tally('A2')
    end

    def test_a_type_can_carry_the_tally
        cli = cli_for("types { k { tally = none } }\nA1 { type = k, port = 1 }")
        assert_equal 'none', cli.tally('A1')
    end
end
