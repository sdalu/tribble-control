require_relative 'lib/tribe-control/version'

Gem::Specification.new do |spec|
    spec.name        = 'tribe-control'
    spec.version     = TribeControl::VERSION
    spec.authors     = [ "Stephane D'Alu" ]
    spec.email       = [ 'sdalu@sdalu.com' ]

    spec.summary     = 'Power, flash and monitor the devices plugged' \
                       ' into an ExSYS 16-port managed USB hub'
    spec.description = <<~DESC
        Drives the FT232 control line of an ExSYS 16-port managed USB
        hub, and for the nRF52 boards on it speaks SWD through
        openocd/CMSIS-DAP and reads their console over USB CDC.  Which
        board sits on which port -- and which ports must never lose
        power -- is read from a device list, so the tool switches the
        bench it is told about and nothing else.
    DESC

    spec.license     = 'MIT'
    spec.homepage    = 'https://github.com/sdalu/trible-control'

    # This gem drives one bench.  It is installed from a checkout, not
    # fetched, and `gem push` on it would be an accident.
    spec.metadata['allowed_push_host'] = 'none'

    # Class#subclasses, which is how commands are discovered.
    spec.required_ruby_version = '>= 3.1'

    # man/man1/ keeps its shape inside the installed gem, which makes
    # the gem's man/ a usable MANPATH entry.  See `rake man:install`.
    spec.files       = Dir['lib/**/*.rb'] +
                       Dir['man/man1/*.1'] + Dir['examples/*'] +
                       [ 'README.md', 'LICENSE', 'tribe-control.gemspec' ]
    spec.bindir      = 'exe'
    spec.executables = [ 'tribe-control' ]

    # 0.6 or better: that is where ManagedUSB started holding an
    # exclusive lock on the serial line across a whole read-modify-write,
    # and where it began refusing a port outside 1..16 instead of
    # shifting a bit off the end of the state word.  Pinned to the
    # series for the reason given under ucl below -- the failure mode
    # of a quiet change here is a port switched that should not be.
    spec.add_dependency 'exsys', '~> 0.6.0' # the hub, over its FT232 line
    spec.add_dependency 'parallel'    # one openocd per board at a time
    spec.add_dependency 'tty-logger'
    spec.add_dependency 'uart'        # board consoles, in `connect`
    # ucl 0.2.0 vendors libucl 0.9.4 and builds it: no system libucl to
    # install on the bench, and no mini_portile2 either, which 0.1.4
    # needed.  It also carries the use-after-free and parser-leak fixes.
    #
    # Pinned to the 0.2 series rather than '>= 0.2': the devlist layer
    # depends on load_file handing back string keys, and a key-handling
    # default that changed under a pre-1.0 minor bump would not fail --
    # it would quietly stop finding 'port' on every entry.
    spec.add_dependency 'ucl', '~> 0.2.0'   # the device list format
end
