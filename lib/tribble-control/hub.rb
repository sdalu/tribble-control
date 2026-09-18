# frozen_string_literal: true

#
# The hub, as the rest of the program sees it: switchable ports and
# nothing about how they are switched.
#
module TribbleControl

# What every kind of hub has to answer.
#
# The subject of this tool is a USB hub, and for its first releases it
# was one hub in particular: the commands called ExSYS::ManagedUSB
# directly, its sixteen-port constant was the definition of a port,
# and its internal 4-by-4 geometry sat in Platform.  This class is the
# seam that puts another kind of hub behind the same calls.  A backend
# is a subclass answering the methods below, and the commands,
# each_device and the protections talk to nothing else.
#
# Ports are Integers numbered as the hub numbers them, from 1.  A list
# handed to a switching method must be non-empty and name ports the
# hub has: an empty list never means "every port" anywhere in this
# program (see DESIGN.md), and the guard here is the last one rather
# than the first -- every caller checks before it gets this far, and a
# fourth path into the hub that forgets to is stopped here instead of
# powering a bench up or down.
#
# Reaching for a hub's own methods in a command -- anything a backend
# can do that this class does not name -- is the thing this class
# exists to stop.  Add the method here, with a default or as a
# NotImplementedError, and then to the backends.
class Hub
    # Anything the hub layer has to report: a hub that refuses a
    # command, a host that cannot be looked for one on, a name that
    # matches nothing or matches two.  CLI.run prints the message and
    # nothing else, so every one of these must carry one.
    class Error < StandardError
    end

    # The kinds of hub there are, by the name a devlist's 'hub =' line
    # uses, and the class answering for each.  The devlist says what
    # the hub IS -- an ExSYS managed hub, a standard hub with per-port
    # power switching -- and not which tool drives it on this host, so
    # the same line keeps working when another host learns to drive
    # such a hub.  A backend is required when it is asked for, so a
    # host that lacks what one of them needs still runs the others.
    KINDS = { 'exsys' => 'ExSYS', 'usb' => 'USB' }.freeze

    # The class for a kind, loaded.
    def self.backend(kind)
        unless (klass = KINDS[kind.to_s])
            raise Error, "unknown hub kind '#{kind}' (one of" \
                         " #{KINDS.keys.join(', ')})"
        end
        require_relative "hub/#{kind}"
        const_get(klass)
    end

    # Every port this hub has, in order.  Static, and asked before the
    # hub is ever opened: the devlist is checked against it.
    def ports = raise NotImplementedError, "#{self.class}#ports"

    # The hub's own view of what is powered: { port => true/false },
    # for every port in #ports.
    def state = raise NotImplementedError, "#{self.class}#state"

    def on(*)     = raise NotImplementedError, "#{self.class}#on"
    def off(*)    = raise NotImplementedError, "#{self.class}#off"
    def toggle(*) = raise NotImplementedError, "#{self.class}#toggle"

    # Apply { port => true/false } and, unless +default+ is nil, put
    # every port not named to +default+.  A backend that can do the
    # whole thing in one exchange with the hub overrides this; here it
    # is an on and an off.
    def set(changes, default = nil)
        ons  = changes.select {|_, v| v }.keys
        offs = changes.reject {|_, v| v }.keys
        unless default.nil?
            (default ? ons : offs).concat(self.ports - changes.keys)
        end
        self.on(*ons)   unless ons.empty?
        self.off(*offs) unless offs.empty?
    end

    # Where a board on +port+ is in this host's USB tree, as a path in
    # the shape ExSYS::ManagedUSB::USB_PATH describes (1-1.2.4.4), or
    # nil when the hub cannot be placed in the tree.  --method usb
    # needs it; the other two methods need no topology at all.
    def usb_path(port) = raise NotImplementedError, "#{self.class}#usb_path(#{port})"

    # The hub as a message names it.
    def to_s = raise NotImplementedError, "#{self.class}#to_s"

    # Does 'off' remove power from the socket, or only take the port
    # off the bus?  Software cannot tell the two apart -- a hub with no
    # power switch wired still reports the port unpowered and drops the
    # link, and the device on it vanishes and returns either way -- so
    # this is a fact a backend is told, or knows about its hardware.
    # false means a board on a cut port keeps running, which is enough
    # to select it by ('power' identifies a board by being the only
    # one visible) and not enough to reboot it.  The default is the
    # honest one for a hub that was built to switch VBUS.
    def vbus? = true

  private

    # A list a switching method was handed, vetted: non-empty, and
    # every port one the hub has.
    def selection(list)
        raise Error, 'no port named: refusing to switch nothing' if list.empty?
        if (bad = list - self.ports).any?
            raise Error, "no such port on this hub: #{bad.join(' ')}" \
                         " (it has #{self.ports.first}-#{self.ports.last})"
        end
        list
    end
end

end
