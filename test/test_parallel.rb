# frozen_string_literal: true

require_relative 'helper'

# What each_device relies on from the parallel gem, checked against
# whichever version is installed: the gemspec allows 1.28 to 2.x, and
# the two differ in nothing this tool may notice.
class TestParallel < Minitest::Test
    # in_threads runs the block in this process and hands its results
    # back in order.  The default, in_processes, ran it in forked
    # children whose results never reached the parent, which made a
    # failed flash report success (see each_device).
    def test_in_threads_returns_every_result_in_order_from_this_process
        pid  = Process.pid
        got  = Parallel.map(%w[A1 A2 A3], in_threads: 3) {|n|
            sleep(0.01 * (3 - n[-1].to_i))      # finish out of order
            [ n, Process.pid ]
        }
        assert_equal %w[A1 A2 A3], got.map(&:first)
        assert_equal [ pid ] * 3,  got.map(&:last)
    end

    def test_a_false_result_is_kept
        refute Parallel.map([ 1, 2 ], in_threads: 2) {|i| i == 1 }.all?
    end
end
