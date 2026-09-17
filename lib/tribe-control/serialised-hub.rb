module TribeControl

# Serialise access to the hub's control line.
#
# The 16 ports are switched over a single FT232, so two tribe-control
# processes touching it at once both die with ExSYS::ManagedUSB::Error.
# That is easy to hit the moment anything drives several boards at once
# -- an orchestrator starting a board per process, or simply two people
# at the bench -- and the failure gives no hint of the cause.
#
# Every call is taken under an exclusive lock instead, so concurrent
# users queue for the line rather than corrupting each other. The lock
# is held for one call, which is the granularity the hub itself has:
# each command is a complete request/response exchange.
#
# exsys 0.6 took the same problem on itself: ManagedUSB now opens the
# line once per call and flocks it for the whole read-modify-write, so
# on a host where that works this class is a second lock around a
# guarantee already made -- and a weaker one, since it only ever knew
# about other tribe-control processes, while the device lock also
# covers exsys-usb and anything else driving the same hub.
#
# It stays because the device lock is best-effort: exsys catches the
# platforms that refuse to lock a character device and carries on
# unlocked, saying so on the debug output and nowhere else. This lock
# is on a regular file in /tmp, which locks everywhere, and it costs
# one open per hub call. The two are always taken in this order --
# this one, then the device -- so they cannot deadlock.
class SerialisedHub
    LOCKFILE = '/tmp/tribe-control.hub.lock'.freeze

    def initialize(hub)
        @hub = hub
    end

    def method_missing(name, ...)
        return super unless @hub.respond_to?(name)

        File.open(LOCKFILE, File::CREAT | File::RDWR, 0o600) do |f|
            f.flock(File::LOCK_EX)
            @hub.public_send(name, ...)
        end
    end

    def respond_to_missing?(name, include_private = false)
        @hub.respond_to?(name, include_private) || super
    end
end

end
