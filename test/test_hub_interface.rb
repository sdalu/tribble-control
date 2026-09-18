# frozen_string_literal: true

require_relative 'helper'

# The Hub interface itself, apart from any hub.
#
# What a backend inherits and what it is held to: the guard that stops
# an empty or a foreign port list at the last possible place, and the
# default 'set' a backend gets when it cannot do the whole change in
# one exchange.  A recording hub stands in for the hardware so that
# what is asserted is the contract and not a protocol.
class TestHubInterface < Minitest::Test
    # Four ports, a log of every switch, and nothing else.
    class Recorder < TribbleControl::Hub
        attr_reader :log

        def initialize
            super
            @log = []
        end

        def ports = [ 1, 2, 3, 4 ]
        def on(*list)  = @log << [ :on,  selection(list) ]
        def off(*list) = @log << [ :off, selection(list) ]
        def to_s = 'recorder'
    end

    def setup
        @hub = Recorder.new
    end

    def test_an_empty_list_is_refused_not_read_as_every_port
        e = assert_raises(TribbleControl::Hub::Error) { @hub.on }
        assert_match(/refusing to switch nothing/, e.message)
        assert_empty @hub.log
    end

    def test_a_port_the_hub_does_not_have_is_refused
        e = assert_raises(TribbleControl::Hub::Error) { @hub.off(2, 7) }
        assert_match(/no such port on this hub: 7 \(it has 1-4\)/, e.message)
        assert_empty @hub.log
    end

    def test_set_is_an_on_and_an_off
        @hub.set({ 1 => true, 3 => false, 4 => true })
        assert_equal [ [ :on, [ 1, 4 ] ], [ :off, [ 3 ] ] ], @hub.log
    end

    def test_set_with_a_default_covers_the_ports_not_named
        @hub.set({ 2 => true }, false)
        assert_equal [ [ :on, [ 2 ] ], [ :off, [ 1, 3, 4 ] ] ], @hub.log
    end

    def test_set_with_nothing_to_do_on_one_side_skips_that_side
        @hub.set({ 1 => true, 2 => true })
        assert_equal [ [ :on, [ 1, 2 ] ] ], @hub.log
    end

    # A backend answering less than the interface says so by name,
    # rather than as a NoMethodError on an internal.
    def test_a_method_a_backend_did_not_answer_names_itself
        e = assert_raises(NotImplementedError) { @hub.state }
        assert_match(/Recorder#state/, e.message)
    end
end
