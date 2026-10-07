# frozen_string_literal: true

require_relative 'helper'

# The seam where firmware knowledge goes, and stays out of the tool.
class TestTally < Minitest::Test
    include ConfigHelper

    def teardown
        TribbleControl::Tally.instance_variable_get(:@registry).delete('probe')
        super
    end

    def test_the_default_counts_lines
        t = TribbleControl::Tally.build('lines', 'A1')
        t << "one\n" ; t << "two\n"
        assert_equal 'lines=2', t.summary
    end

    def test_none_says_nothing
        t = TribbleControl::Tally.build('none', 'A1')
        t << "one\n"
        assert_nil t.summary
    end

    def test_a_registered_block_is_built_per_device
        seen = []
        TribbleControl::Tally.register(:probe) {|device| seen << device ; Object.new }
        TribbleControl::Tally.build('probe', 'A1')
        TribbleControl::Tally.build('probe', 'A2')
        assert_equal %w[A1 A2], seen
    end

    # Never a quiet fall back to counting lines: that reads exactly
    # like a bench that has gone silent.
    def test_an_unregistered_tally_is_an_error
        e = assert_raises(TribbleControl::CLI::Error) {
            TribbleControl::Tally.build('twr', 'A1') }
        assert_match(/unknown tally 'twr'/, e.message)
        assert_match(/--require/, e.message)
    end

    def test_register_wants_a_block
        assert_raises(ArgumentError) { TribbleControl::Tally.register(:probe) }
    end

    def test_the_config_chooses_it_per_bench_and_per_board
        cli = cli_for("tally = none\nA1 { port = 1 }\nA2 { port = 2, tally = lines }")
        assert_equal 'none',  cli.tally('A1')
        assert_equal 'lines', cli.tally('A2')
    end

    def test_a_type_can_carry_the_tally
        cli = cli_for("types { k { tally = none } }\nA1 { type = k, port = 1 }")
        assert_equal 'none', cli.tally('A1')
    end

    # --tally: the run's choice, over the configuration's.

    CONF = "tally = lines\n" \
           "types { k { tally = none } }\n" \
           "A1 { port = 1 }\nA2 { port = 2, tally = none }\n" \
           "A3 { port = 3, type = k }"

    def setup
        super
        TribbleControl::Tally.register(:probe) {|device| [ :probe, device ] }
    end

    # The connect command line, parsed: its options as stored, and the
    # command that would run with them.
    def connect_for(*args, config: CONF)
        file = File.join(Dir.mktmpdir('tribble-test'), 'tribble.conf')
        File.write(file, config)
        @tmpdirs = (@tmpdirs || []) << File.dirname(file)
        cli  = quieten(TribbleControl::CLI.new
                           .parse([ '-d', File::NULL, '-C', file,
                                    'connect', *args ]))
        [ TribbleControl::CLI::Connect.new(cli),
          cli.instance_variable_get(:@opts) ]
    end

    def chosen(*args, ids: [])
        connect, opts = connect_for(*args)
        connect.tallies(ids, opts[:tally])
               .transform_values {|t| t.is_a?(Array) ? 'probe' : t.class.name }
    end

    def test_without_it_the_configuration_decides
        assert_equal({ 'A1' => 'TribbleControl::Tally',
                       'A2' => 'TribbleControl::NullTally',
                       'A3' => 'TribbleControl::NullTally' }, chosen)
    end

    def test_a_bare_name_is_every_board_s
        assert_equal %w[probe probe probe], chosen('--tally', 'probe').values
    end

    def test_dev_name_is_one_board_s_over_the_run_s
        assert_equal({ 'A1' => 'probe', 'A2' => 'TribbleControl::Tally',
                       'A3' => 'probe' },
                     chosen('--tally', 'probe', '--tally', 'A2=lines'))
    end

    # Given twice, both count: dropping the first would change every
    # other board's tally without a word.
    def test_repeated_and_comma_separated_mean_the_same
        assert_equal chosen('--tally', 'probe,A1=none'),
                     chosen('--tally', 'A1=none', '--tally', 'probe')
        _, opts = connect_for('--tally', 'probe', '--tally', 'A1=none,A2=lines')
        assert_equal %w[probe A1=none A2=lines], opts[:tally]
    end

    def test_dev_may_be_a_port_as_on_the_command_line
        assert_equal 'probe', chosen('--tally', '1=probe')['A1']
    end

    def test_only_the_selected_boards_are_built
        assert_equal %w[A2], chosen(ids: %w[A2]).keys
    end

    def refusal(*args, ids: [])
        connect, opts = connect_for(*args)
        connect.tallies(ids, opts[:tally])
        nil
    rescue TribbleControl::CLI::Error => e
        e.message
    end

    def test_two_run_tallies_are_refused
        assert_match(/two tallies for the run/,
                     refusal('--tally', 'probe', '--tally', 'lines'))
    end

    def test_two_tallies_for_one_board_are_refused
        assert_match(/A1 two tallies/,
                     refusal('--tally', 'A1=probe,A1=lines'))
    end

    def test_a_board_this_run_does_not_capture_is_refused
        assert_match(/A1 is not captured by this run \(A2\)/,
                     refusal('--tally', 'A1=probe', ids: %w[A2]))
    end

    def test_a_board_the_configuration_does_not_know_is_refused
        assert_match(/no device 'Z9'/, refusal('--tally', 'Z9=probe'))
    end

    def test_a_malformed_spec_is_refused
        assert_match(/expected NAME or DEV=NAME/, refusal('--tally', 'A1='))
        assert_match(/expected NAME or DEV=NAME/, refusal('--tally', '=none'))
    end

    # Before anything is switched: the name is checked when the tallies
    # are built, which run does first.
    def test_an_unknown_name_is_refused_whoever_names_it
        assert_match(/unknown tally 'twr'/, refusal('--tally', 'twr'))
        assert_match(/unknown tally 'twr'/, refusal('--tally', 'A3=twr'))
    end

    # -r given twice loads both, as a comma list does: a second -r that
    # replaced the first would surface only as an unknown tally.
    def test_every_require_is_loaded
        dir      = Dir.mktmpdir('tribble-test')
        @tmpdirs = (@tmpdirs || []) << dir
        files    = %w[ra rb].map {|n|
            File.join(dir, "#{n}.rb").tap {|f|
                File.write(f, "TribbleControl::Tally.register(:#{n}) {|d| d }\n")
            }
        }
        cli_for('', '-r', files[0], '-r', files[1])
        assert_equal %w[ra rb], %w[ra rb] & TribbleControl::Tally.registered
    ensure
        %w[ra rb].each {|n|
            TribbleControl::Tally.instance_variable_get(:@registry).delete(n)
        }
    end

    # An empty --tally used to mean no --tally, so every board fell back
    # to the configuration without a word: the very fallback the option
    # exists to prevent.
    def test_an_empty_tally_is_refused
        assert_match(/--tally: an empty NAME/, refusal('--tally='))
        assert_match(/--tally: an empty NAME/, refusal('--tally', 'lines,,A1=none'))
    end

    def test_an_empty_require_is_refused
        e = assert_raises(TribbleControl::CLI::Error) {
            cli_for('', '-r', "#{__FILE__},,#{__FILE__}") }
        assert_match(/-r: an empty file name/, e.message)
        e = assert_raises(TribbleControl::CLI::Error) {
            cli_for('', '--require=') }
        assert_match(/-r: an empty file name/, e.message)
    end
end
