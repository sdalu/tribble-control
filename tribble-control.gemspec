require_relative 'lib/tribble-control/version'

Gem::Specification.new do |spec|
    spec.name        = 'tribble-control'
    spec.version     = TribbleControl::VERSION
    spec.authors     = [ "Stephane D'Alu" ]
    spec.email       = [ 'sdalu@sdalu.com' ]

    spec.summary     = 'Power, flash and monitor the boards plugged' \
                       ' into a switchable USB hub'
    spec.description = <<~DESC
        Switches the ports of a USB hub -- an ExSYS 16-port managed hub
        over its internal FT232 line, or any hub that switches its own
        ports, through hub-class requests (FreeBSD for now) -- and for
        the boards on it speaks SWD through openocd and reads their
        consoles over USB CDC.  Which board sits on which port, and
        which ports must never lose power, is read from a
        configuration, so the tool switches the bench it is told about
        and nothing else.  What a console's lines mean is left to a
        tally loaded at run time.
    DESC

    spec.license     = 'MIT'
    spec.homepage    = 'https://github.com/sdalu/tribble-control'

    # Published on rubygems.org, and only there.  A version fetched from
    # a registry names exactly one tree, which a checkout built under
    # the last release's number does not.  The cost is that a release
    # cannot be taken back: a bad one is yanked, and its number is
    # spent.
    spec.metadata['allowed_push_host'] = 'https://rubygems.org'
    spec.metadata['source_code_uri']   = spec.homepage
    spec.metadata['rubygems_mfa_required'] = 'true'

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

    # 1.2 or better, for what this tool relies on: an exclusive lock on
    # the serial line across a whole read-modify-write, an empty port
    # list refused rather than read as every port, `available` (how the
    # hub is found and named, with the USB path --method usb builds on),
    # and the FreeBSD discovery fix -- an adapter whose tty is not named
    # yet must not be reported as '/dev/tty', or `usb off` would write
    # SP frames at the operator's own terminal.  1.2 also bounds the walk
    # up the sysctl tree and gives a silent line an error message.
    #
    # Pinned to the series for the reason given under ucl below -- the
    # failure mode of a quiet change here is a port switched that
    # should not be.
    spec.add_dependency 'exsys', '~> 1.2'   # the hub, over its FT232 line,
                                            #   and finding it on the host
    # One openocd per board at a time, in threads (see each_device).
    # Bounded like the others: 1.28 and 2.3 are the two the suite has
    # run against, 1.x on the workstation and 2.x in the bench's bundle,
    # and a 3.0 that changed what in_threads hands back would change
    # what flash and reset report.
    spec.add_dependency 'parallel', '>= 1.28', '< 3'
    spec.add_dependency 'tty-logger'
    spec.add_dependency 'uart'        # board consoles, in `connect`
    # ucl 0.2.0 vendors libucl 0.9.4 and builds it: no system libucl and
    # no mini_portile2 to install on the bench.  It also carries the
    # use-after-free and parser-leak fixes.
    #
    # Pinned to the 0.2 series rather than '>= 0.2': the configuration
    # layer depends on load_file handing back string keys, and a
    # key-handling default that changed under a pre-1.0 minor bump
    # would not fail -- it would quietly stop finding 'port' on every
    # entry.
    spec.add_dependency 'ucl', '~> 0.2.0'   # the configuration format

    # Pinned to 5: minitest 6 moved minitest/mock out into a gem of its
    # own, which is a trap worth naming even though nothing here mocks.
    spec.add_development_dependency 'minitest', '~> 5'
    spec.add_development_dependency 'rake'
    spec.add_development_dependency 'rubocop'
end
