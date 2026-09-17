tribe-control
=============

Power, flash and monitor the devices plugged into an ExSYS 16-port
managed USB hub.

The hub switches VBUS on each port independently over an FT232 serial
line.  `tribe-control` drives that line, and for the nRF52 boards on the
hub it additionally speaks SWD through openocd/CMSIS-DAP and reads their
console over USB CDC.

    ./tribe-control -D devlist.conf usb status
    ./tribe-control -D devlist.conf flash zephyr.hex alpha beta

Documentation
-------------

The full manual (port map, device selection, recipes and traps) is
embedded in the program and displayed by:

    ./tribe-control --man

`--help` lists the commands, and `CMD --help` the options of one.

Layout
------

    tribe-control        the program; the manual is after its __END__
    devlist.conf.example a device list to copy and edit
    test-tribe-control   regression tests, run against a deployed copy

Running it
----------

`tribe-control` runs on the machine owning the hub, not on a
workstation: it needs the `exsys` gem talking to a local FT232, and
openocd talking to local USB.  It requires `bundler/setup` at startup,
so it needs this `Gemfile` and a bundle installed under `./vendor` in
its working directory.

It is driven by a device list saying which device sits on which port,
with which debug probe, at which console speed, and which ports must
never lose power.  That file describes a setup rather than the tool, so
it lives with whatever owns the setup; `devlist.conf.example` is a
commented one to start from.  Deploy the two together: they are read
together, and a hub with one of them fresh and the other stale switches
the wrong ports.

Tests
-----

    sh test-tribe-control [host] [tribe-control-path]

The suite runs against a deployed copy, because the gems are on the hub
host.  Everything it asserts by default is decided during device-list
parsing, before the hub object is built, so those tests never reach the
hub.  The flash and power-cycle tests are behind `TRIBE_TEST_FLASH=1`
because they write flash.

The second argument exists so the suite can be pointed at a
deliberately broken copy: a test that has never been seen to fail is
not evidence.
