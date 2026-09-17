tribe-control
=============

Power, flash and monitor the devices plugged into an ExSYS 16-port
managed USB hub.

The hub switches VBUS on each port independently over an FT232 serial
line.  `tribe-control` drives that line, and for the nRF52 boards on the
hub it additionally speaks SWD through openocd/CMSIS-DAP and reads their
console over USB CDC.

    tribe-control -D devlist.conf usb status
    tribe-control -D devlist.conf flash zephyr.hex alpha beta

Documentation
-------------

The full manual (port map, device selection, recipes and traps) is a
man page, `man/man1/tribe-control.1`, and ships inside the gem.

    tribe-control --man          # renders the shipped page, wherever it is
    rake man:install             # PREFIX=/usr/local, for real `man` access
    mandoc man/man1/tribe-control.1

`--man` renders the page with the first of `mandoc`, `groff` or `nroff`
it finds, pages it when the output is a terminal, and hands plain text
to a pipe.  RubyGems installs nothing outside the gem directory, so
`gem install` alone will not make `man tribe-control` work; the page
ships at `man/man1/` inside the gem precisely so that the gem's `man`
directory can be used as a `MANPATH` entry if you would rather not copy
it.

`--help` lists the commands, and `CMD --help` the options of one.

Layout
------

    exe/tribe-control           the executable; it only calls CLI.run
    lib/tribe-control.rb        what `require 'tribe-control'` loads
    lib/tribe-control/         
        version.rb              the one place the version number lives
        platform.rb             Linux/FreeBSD ways of finding hardware
        serialised-hub.rb       the lock serialising the FT232 line
        tally.rb                the seam where firmware knowledge goes
        cli.rb                  options, devlist, each_device, openocd
        cli/*.rb                one file per command (usb, flash, ...)
    man/man1/tribe-control.1    the manual (mdoc), rendered by --man
    examples/devlist.conf       a device list to copy and edit
    test/test-tribe-control     regression tests, run against a deployed copy

Installing it
-------------

`tribe-control` runs on the machine owning the hub, not on a
workstation: it needs the `exsys` gem talking to a local FT232, and
openocd talking to local USB.

It requires, besides the Ruby gems the bundle installs:

  * **Ruby 3.1** or later.
  * **openocd**, which every command that reaches a board over SWD
    (`flash`, `reset`, `connect --reset`) shells out to.  It is not a
    gem and the bundle will not install it: `pkg install openocd`,
    `apt install openocd`.  Expected at `/usr/bin/openocd`; elsewhere,
    pass `--openocd=/usr/local/bin/openocd`, or `--openocd=openocd` to
    have PATH answer.  `flash` and `reset` check for it before they
    switch a single port.

Install it on the hub host as a gem, which brings the Ruby
dependencies with it and needs nothing else:

    rake install                 # from a checkout
    gem install tribe-control-0.1.0.gem   # from `rake build`

Or, on a host that should not gain gems system-wide, deploy the
checkout and vendor the bundle beside it:

    bundle install --path vendor
    bundle binstubs tribe-control
    ./bin/tribe-control --man

The binstub sets that bundle up before loading anything, so it is what
such a bench should call.

What a board's console output MEANS is not in here.  `connect` prints
the lines and hands each to a *tally*, which counts whatever it likes
and writes the SUMMARY.  The built-in one counts lines; anything that
knows a firmware's strings is a block registered by a file named with
`-r/--require` and chosen with `tally =` in the devlist.  See the
manual's TALLIES section.  Likewise the board family: the openocd
target script is the devlist's `target =` (default `nrf52`), not a
constant in the code.

It is driven by a device list saying which device sits on which port,
with which debug probe, at which console speed, and which ports must
never lose power.  That file describes a setup rather than the tool, so
it lives with whatever owns the setup; `examples/devlist.conf` is a
commented one to start from.  Deploy the two together: they are read
together, and a hub with one of them fresh and the other stale switches
the wrong ports.

Tests
-----

    sh test/test-tribe-control [host] [tribe-control-path]
    rake test                        # same, via TRIBE_HOST/TRIBE_PATH

The suite runs against a deployed copy, because the gems are on the hub
host.  Everything it asserts by default is decided during device-list
parsing, before the hub object is built, so those tests never reach the
hub.  The flash and power-cycle tests are behind `TRIBE_TEST_FLASH=1`
because they write flash.

The second argument exists so the suite can be pointed at a
deliberately broken copy: a test that has never been seen to fail is
not evidence.
