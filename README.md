# tribble-control

Power, flash and monitor the boards plugged into an ExSYS 16-port
managed USB hub, from the host that owns the hub.

The hub switches VBUS on each of its sixteen sockets independently,
driven over an FT232 serial line internal to the hub.  `tribble-control`
drives that line.  For a socket carrying a board with a debug probe it
also speaks SWD through openocd and reads the board's console over USB
CDC.  Everything else on the hub is a load it can switch and nothing
more.

```text
                host owning the hub
                         │
         ┌───────────────┴───────────────┐
         │                               │
  FT232 control line        USB data: the SWD probe
  9600 8N1, internal        and the CDC console
  to the hub
         │                               │
         ▾                               ▾
┌───────────────────────────────────────────────┐
│         ExSYS 16-port managed USB hub         │
│        VBUS switched per port, 1 to 16        │
└───┬───────┬───────┬───────┬─────────┬─────────┘
    │       │       │       │         │
    ▾       ▾       ▾       ▾         ▾
  board   board   board    ...  load the hub
                                 only powers
```

A file you write — the **device list** — says which board sits on which
port, how to reach it, and which ports must never lose power.  The tool
switches the bench it is told about and nothing else.

```sh
tribble-control -D devlist.conf usb status
tribble-control -D devlist.conf flash zephyr.hex alpha beta
tribble-control -D devlist.conf connect --off gamma | tee run.log
```

The full manual — every option, every devlist key, the hub protocol,
recipes and traps — is the man page.  This file is the short way in.


## Requirements

`tribble-control` runs on the machine owning the hub, not on a
workstation: it needs a local FT232 to reach the hub, and a local
openocd to reach a board.

  * **Ruby 3.1** or later.
  * **openocd**, for every command that reaches a board over SWD:
    `flash`, `reset` and `connect --reset`.  It is not a gem and
    installing the gem will not bring it — `pkg install openocd`,
    `apt install openocd`.  It is expected at `/usr/bin/openocd`;
    elsewhere pass `--openocd=/usr/local/bin/openocd`, or
    `--openocd=openocd` to have `PATH` answer.  `flash` and `reset`
    check for it before they switch a single port.
  * **Linux or FreeBSD.**  Every command works on both, by every
    selection method.  The two hosts answer "where is this board
    plugged in" differently — Linux states it in `/sys/bus/usb`, and
    FreeBSD is asked to walk its sysctl tree instead — and the one
    thing FreeBSD cannot do is see a device that no driver claimed,
    there being no node for it at all.  A probe that enumerates and
    attaches nothing is invisible there rather than serial-less.


## Installing it

Install it on the hub host as a gem, which brings the Ruby
dependencies with it and needs nothing else:

```sh
rake install                             # from a checkout
gem install pkg/tribble-control-*.gem    # from `rake build`
```

Or, on a host that should not gain gems system-wide, deploy the
checkout and vendor the bundle beside it:

```sh
bundle install --path vendor
bundle binstubs tribble-control
./bin/tribble-control --man
```

The binstub sets that bundle up before loading anything, so it is what
such a host should call.


## The device list

Nearly every command needs one, given with `-D`/`--devlist`.  It
describes a setup rather than the tool, so it lives with whatever owns
the setup; `examples/devlist.conf` is a commented file to start from.
Deploy the two together — they are read together, and a hub with one of
them fresh and the other stale switches the wrong ports.

If the two must move separately, move the **tool first**.  Every
top-level key this tool does not know is taken for a board, and a board
must declare a port, so a devlist carrying a newer key meets an older
tool as `devlist entry 'device' has no port`.  That is a refusal before
anything is switched rather than a bench in the wrong state — but the
command does not run, so upgrade in that order.

```text
# Which hub these ports are on: its FT232's serial number.
device = AL03GD7X

# Ports that must never be powered down.
reserved = [ 13, 14, 15, 16 ]

# What a KIND of board is, said once instead of on every board.
types {
  nrf52840-mdk {
    interface = cmsis-dap      # openocd interface script: which probe
    target    = nrf52          # openocd target script: which chip
    baud      = 230400         # console speed
  }
}

# Every other key is a device.  `port` is required.
alpha {
  type   = nrf52840-mdk
  serial = '102636...97969902' # the PROBE's serial, pasted whole
  port   = 1
}

# No serial: still switchable, still has a console, but it cannot be
# reset or flashed in parallel.
gamma {
  port = 2
}

# `port = none` keeps the record of a board that has left the bench.
# It is never selected, switched or flashed, and its serial survives.
retired {
  serial = '102636...97969902'
  port   = none
}
```

A device's own keys win over the type's.  Read a probe serial off a
powered board with `tribble-control serial <name>` and paste it whole:
48 hex characters for CMSIS-DAP, 12 for J-Link.


## Which hub

A host with one hub needs to be told nothing: the tool looks for the
FTDI 0403:6001 that is a hub's control adapter and drives the one it
finds.

A host with two is two benches, and it refuses to guess — that FTDI id
is every FT232 on the machine, so the first one enumerated is a coin
toss, and a command that reaches the wrong hub is not an error
anywhere: the ports exist, the frames are accepted, and the boards that
go dark are on the other bench.  It lists what it found instead, with
serials:

```text
tribble-control: unable to auto-detect the hub control line: 2 FTDI
0403:6001 adapters on this host (found: A50285BI on /dev/ttyUSB0,
AL03GD7X on /dev/ttyUSB1).  Name the one to drive with -d, or with a
'device =' line in the devlist.
```

`exsys-usb discover`, from the exsys gem, lists them the same way
without switching anything:

```text
/dev/ttyUSB0 A50285BI 1-1.2.4.4
/dev/ttyUSB1 AL03GD7X 1-1.3.4.4
```

Put that serial in the devlist, as `device =` at the top, and `-D`
alone selects a bench — which is already the thing every command has
to say.  `-d` overrides it for the one-off.

Either takes three shapes, told apart by what they look like:

| Written        | Means                        | Stays with   |
| :------------- | :--------------------------- | :----------- |
| `AL03GD7X`     | the FT232's serial number    | the adapter  |
| `1-1.2.4.4`    | a USB path on this host      | the socket   |
| `/dev/ttyUSB1` | the serial line itself       | nothing      |

The last is the one not to write down.  The `1` in `/dev/ttyUSB1` is
not the hub's number, and not the USB device number either — it is the
usbserial layer's index, and it is the lowest one free when that
adapter is probed.  So it depends on what else attached first, and it
is reused: unplug whatever holds `ttyUSB0` and the next thing to attach
takes `ttyUSB0`.  Two hubs can swap names across a reboot, or while the
machine is up.

Between the other two: a serial names *this particular hub* and follows
it to another socket or another machine, which is usually what a bench
wants.  A USB path names *whatever is plugged into that socket*, a
replacement hub included.  Reach for the path when the hub's EEPROM
carries no serial — then it is the only stable name it has — or when
the socket is the fixed thing.  Both platforms report one, by different
means: Linux states it in `/sys`, and on FreeBSD it is walked out of
the sysctl tree.  The numbering is each host's own, so a path names a
socket on the machine that reported it and does not travel.


## Protected ports

A hub port carries whatever is plugged into it, and cutting VBUS on a
single-board computer reboots it mid-write.  So powering a port *down*
is guarded, and powering one *up* is not:

  * Ports the devlist does not mention are protected.  `undeclared =
    switch` at the top of the file lifts that for the unmentioned ones.
  * Ports named by `reserved` are protected whichever mode is in force.
  * `-F`/`--force` lifts both.  Without a devlist at all,
    `tribble-control` refuses to power anything down.

`usb status` prints the hub's own view next to the devlist's, so you
can see what is on and what may be switched before switching it.  The
protection is only ever as current as the file: a stale devlist guards
the ports it used to know about.


## Commands

| Command   | What it does                                        |
| :-------- | :-------------------------------------------------- |
| `usb`     | Port power: `status`, `on`, `off`, `toggle`, `set`. |
| `serial`  | Print a board's debug-probe serial number.          |
| `flash`   | Write a firmware image to one or more boards.       |
| `reset`   | Reboot boards over SWD.                             |
| `connect` | Open board consoles, print their lines, summarise.  |

Every command takes device names or port numbers interchangeably, and
acts on all declared devices when given neither.  Note that `serial`
prints a probe's identifying number, not console text — reading a
board's console is `connect`.

Naming a board is not the same as telling openocd which one to talk
to, and `-m`/`--method` is how that is decided.  Each command accepts
only the methods that make sense for it and uses the first as its
default:

| Method   | Addresses a board by       | Needs              |
| :------- | :------------------------- | :----------------- |
| `serial` | its debug probe's serial   | `serial =` on each |
| `usb`    | its USB path under the hub | a visible topology |
| `power`  | being the only one powered | nothing            |

| Command   | Methods accepted        | Default  |
| :-------- | :---------------------- | :------- |
| `usb`     | none — it acts on ports | —        |
| `serial`  | `usb`, `power`          | `usb`    |
| `flash`   | `serial`, `power`       | `serial` |
| `reset`   | `serial`                | `serial` |
| `connect` | `usb`, `serial`         | `usb`    |

`serial` is the default for `flash` and `reset` because it is the fast
one: every board stays powered and they are done at the same time, one
openocd apiece.  It needs a `serial =` on each selected board, and
aborts if one is missing.

`power` is the fallback that needs no configuration: it identifies a
board by being the only one powered.  It costs a power cycle per board
and **leaves the bench powered off** when it finishes — every declared
board whose port may be switched, that is; one the devlist protects
stays powered and says so.  Run `usb on` afterwards to bring the bench
back up.


## Reading a console

`connect` opens the console of each selected board, prefixes every line
with the board's name, and prints it.  What those lines *mean* is not
this tool's business — the strings worth counting belong to whatever
firmware is on the bench this month.  So `connect` hands each line to a
**tally**, which counts whatever it likes and writes the `SUMMARY`
line.

Two tallies ship: `lines` counts lines, and `none` writes no summary at
all.  Anything that knows a firmware's strings is a block registered by
a Ruby file named with `-r`/`--require` and chosen with `tally =` in
the devlist, for the whole bench or for one board.  See DESIGN.md and
the manual's TALLIES section.


## The manual

The full manual is a man page, `man/man1/tribble-control.1`, and ships
inside the gem.

```sh
tribble-control --man          # renders the shipped page, wherever it is
rake man:install             # PREFIX=/usr/local, for real `man` access
mandoc man/man1/tribble-control.1
```

`--man` renders the page with the first of `mandoc`, `groff` or `nroff`
it finds, pages it when the output is a terminal, and hands plain text
to a pipe.  RubyGems installs nothing outside the gem directory, so
`gem install` alone will not make `man tribble-control` work; the page
ships at `man/man1/` inside the gem precisely so the gem's `man`
directory can serve as a `MANPATH` entry if you would rather not copy
it anywhere.

`--help` lists the commands, and `CMD --help` the options of one.


## Tests

```sh
rake            # everything that needs no hub, and the linter
rake test       # the minitest suite: devlist, types, tallies, the
                #   openocd command line, and the hub exchange itself
                #   against a pty emulator
rake lint       # rubocop, gating at zero offences
rake test:bench # the regression suite, which needs the bench
```

The bench suite drives a **deployed** copy over ssh, because that is
the machine with the hub on the end of a serial line.  There is no
default host — one lab's address does not belong in a tool meant to
drive any ExSYS hub — so it refuses to start without one:

```sh
sh test/test-tribble-control HOST [tribble-control-path] [tally-path]
TRIBBLE_HOST=<host> rake test:bench        # also TRIBBLE_PATH, TRIBBLE_TALLY
```

It is written to be safe to run on a live bench: nothing writes flash
or switches a port off unless `TRIBBLE_TEST_FLASH=1` asks for the
power-cycle gate.  One test resets a board deliberately, as a positive
control, and the `connect` and `flash` tests power the ports of the
boards they name up, which is the benign direction.

The second argument points the suite at a different copy of the tool —
a deliberately broken one, say, since a test that has never been seen
to fail is not evidence.  The third names the tally, which any command
that opens a console needs when the devlist asks for one by name.


## Hacking on it

DESIGN.md is the companion to this file: how the pieces fit, and where
the seams are for a new board family, a new probe, a new host platform,
a new command or a new tally.


## The name

Tribbles are the small, furry, gentle and extremely numerous creatures
of ["The Trouble with Tribbles"][episode] (*Star Trek*, 1967, written by
David Gerrold).  McCoy works out why there are so many: they are born
pregnant, and spend over half their metabolism reproducing.  By the end
of the episode they have filled the ship, and Kirk is [shoulder-deep in
them][kirk].

A bench fills up the same way.  One board becomes three, three become
eleven, they are identical, every one of them wants power, and not one
of them will tell you which socket it is sitting in.  That last part is
what the device list is for.

![Tribble props from the Star Trek exhibit at the Henry Ford Museum][photo]

Photo by Joe Ross, [CC BY-SA 2.0][licence], via [Wikimedia Commons][page].

[episode]: https://en.wikipedia.org/wiki/The_Trouble_with_Tribbles
[kirk]: https://en.wikipedia.org/wiki/Tribble#/media/File:ST_TroubleWithTribbles.jpg
[photo]: https://commons.wikimedia.org/wiki/Special:FilePath/Tribbles!_-_Star_Trek_-_Exploring_New_Worlds_Exhibit_at_the_Henry_Ford_Museum.jpg?width=480
[page]: https://commons.wikimedia.org/wiki/File:Tribbles!_-_Star_Trek_-_Exploring_New_Worlds_Exhibit_at_the_Henry_Ford_Museum.jpg
[licence]: https://creativecommons.org/licenses/by-sa/2.0/


## License

MIT.  See LICENSE.  The photograph above is not mine and is not MIT; it
carries the CC BY-SA 2.0 licence credited with it.
