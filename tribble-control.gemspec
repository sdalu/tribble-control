require_relative 'lib/tribble-control/version'

Gem::Specification.new do |spec|
    spec.name        = 'tribble-control'
    spec.version     = TribbleControl::VERSION
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
    spec.homepage    = 'https://github.com/sdalu/tribble-control'

    # This gem drives one bench.  It is installed from a checkout, not
    # fetched, and `gem push` on it would be an accident.
    spec.metadata['allowed_push_host'] = 'none'

    # Class#subclasses, which is how commands are discovered.
    spec.required_ruby_version = '>= 3.1'

    # The manifest is resolved against this file's directory, not the
    # working one, so it says the same thing wherever it is read from.
    #
    # `gem build` must still run with the checkout as its working
    # directory: RubyGems reads the listed paths relative to the cwd,
    # not to the gemspec, so building from elsewhere fails however this
    # list is written.  What the chdir fixes is which failure you get.
    # Without it the globs come back empty and the error names only the
    # literal paths -- a message about README.md and LICENSE for a build
    # that has quietly dropped the entire library.  With it the error
    # names every file, which reads as what it is.
    #
    # man/man1/ keeps its shape inside the installed gem, which makes
    # the gem's man/ a usable MANPATH entry.  See `rake man:install`.
    spec.files       = Dir.chdir(__dir__) {
                           Dir['lib/**/*.rb'] +
                           Dir['man/man1/*.1'] + Dir['examples/*'] +
                           [ 'README.md', 'DESIGN.md', 'LICENSE',
                             'tribble-control.gemspec' ]
                       }
    spec.bindir      = 'exe'
    spec.executables = [ 'tribble-control' ]

    # 1.2 or better.  0.6 gave ManagedUSB an exclusive lock on the
    # serial line across a whole read-modify-write; 1.0 makes that
    # session public, so the lock this program used to keep for itself
    # is the library's job now, and refuses an empty port list instead
    # of reading it as every port.  1.1 added `available`, which is how
    # the hub is found and named here, and the USB path it reports is
    # what --method usb builds a board's path from.
    #
    # The floor is 1.2 for the FreeBSD discovery fix, of which this
    # tool is precisely the caller that gets hurt: before it, an
    # adapter whose tty was not named yet came back as :device
    # '/dev/tty' -- '/dev/tty' + '' -- and #hub_device takes a lone
    # candidate without asking, so `usb off` on such a host would have
    # written SP frames at the operator's own terminal.  1.2 also
    # bounds the walk up the sysctl tree, which unbounded is a command
    # that never returns and never says why, and it stops reporting a
    # silent line as an Error carrying no message -- which is the whole
    # of what CLI.run would print, at the moment the line went quiet.
    #
    # Pinned to the series for the reason given under ucl below -- the
    # failure mode of a quiet change here is a port switched that
    # should not be.
    spec.add_dependency 'exsys', '~> 1.2'   # the hub, over its FT232 line,
                                            #   and finding it on the host
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

    # Pinned to 5: minitest 6 moved minitest/mock out into a gem of its
    # own, which is a trap worth naming even though nothing here mocks.
    spec.add_development_dependency 'minitest', '~> 5'
    spec.add_development_dependency 'rake'
    spec.add_development_dependency 'rubocop'
end
