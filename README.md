# tribble-control

Power, flash and monitor the boards plugged into a switchable USB hub,
from the host that owns the hub.

Two kinds of hub.  The ExSYS 16-port managed hub, the default, switches
VBUS on each of its sixteen sockets independently, over an FT232 serial
line internal to the hub; `tribble-control` drives that line.  Any
standard USB hub with per-port power switching is the other (`hub =
usb`), switched on the bus itself with hub-class requests through
`usbconfig`, and so on FreeBSD only for now.  For a socket carrying a
board with a debug probe the tool also speaks SWD through openocd and
reads the board's console over USB CDC.  Everything else on the hub is a
load it can switch and nothing more.

```text
                host owning the hub
                         │
         ┌───────────────┴───────────────┐
         │                               │
  the control path:         USB data: the SWD probe
  an FT232 line inside      and the CDC console
  the hub, or the bus itself
         │                               │
         ▾                               ▾
┌───────────────────────────────────────────────┐
│     ExSYS 16-port managed hub, or any hub     │
│      that switches its own ports, 1 to N      │
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
workstation: it reaches the hub over something plugged into that
machine — an FT232 line, or the USB bus itself — and needs a local
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
  * **For `hub = usb`: FreeBSD, and membership of group `operator`.**
    That hub is switched with `usbconfig` hub-class requests, which is
    FreeBSD's command — Linux has none that issues an arbitrary control
    request to a hub — so the backend refuses to open on any other host.
    Root is not required: the ugen nodes are `root:operator` 0660, and
    the kernel demands the driver privilege only for SET_ADDRESS,
    SET_CONFIG and SET_INTERFACE, so a hub-class port feature request
    passes.  `pw groupmod operator -m <user>`, then log in again.


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
# Which kind of hub, and which one.  'exsys' is the default: an ExSYS
# hub, named by its FT232's serial number.  'usb' is any hub with
# per-port power switching, named by its own serial, and only that kind
# takes a 'switch' line.
hub    = exsys
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

Two things to settle: which *kind* of hub, and which hub of that kind.

The kind is `hub =` at the top of the devlist, or `--hub` on the command
line: `exsys` (the default) or `usb`.  It names what the hub **is**, not
which tool drives it on this host, so the same devlist line keeps
working the day a Linux implementation lands.  It cannot be read off the
`device =` value, either — a USB path such as `1-1.1` names an FT232's
socket for an ExSYS hub and the hub itself for a usb hub — so it has to
be said.

An ExSYS hub on a host with one hub needs to be told nothing: the tool
looks for the FTDI 0403:6001 that is a hub's control adapter and drives
the one it finds.

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

A `hub = usb` is named the same three ways, in its own shapes:

| Written        | Means                       | Stays with  |
| :------------- | :-------------------------- | :---------- |
| `AC0528515619` | the hub's own serial number | the hub     |
| `1-1.1`        | a USB path on this host     | the socket  |
| ugen1.4        | that device, used as given  | nothing     |

A ugen name is this kind's `/dev/ttyUSB1` and carries the same warning:
the number is enumeration order — ugen1.4 is the fourth device the
second controller attached — so a replug renumbers it, and a devlist
naming a hub that way points at whatever attached in its place.  Keep it
for the one-off; write the serial, or the path when the socket is the
fixed thing.

Auto-detection refuses the same way: one candidate is taken, two or more
are listed and the command stops, each candidate with its serial, its
ugen name, its USB path and its port count — the count being the only
thing that tells two of the same part apart when neither has a serial.
Root hubs are never candidates.  They are the controller a host's own
sockets hang off, and a port of one has no `PORT_POWER` to clear, so
offering one would offer a hub every command against it then failed on.

The ports are the hub's own: 1 to the `bNbrPorts` its hub descriptor
reports, read once when the hub is opened.  The fixed sixteen is the
ExSYS hub's alone, and `undeclared = protect` earns its keep here — on a
dock, one hub port feeds the next hub in the chain and another feeds the
Ethernet adapter, and neither is a port to sweep off.


## What "off" does

The ExSYS hub cuts VBUS: `usb off` takes the power away from the socket
and the board on it stops.  A standard hub may do that, or may only take
the port off the bus, depending on whether a power switch is wired to
the socket at all — and no software can tell the two apart, because a
hub with none still reports the port unpowered and drops the link, so
the device vanishes from the host and comes back either way.  The
operator says which, with `switch =` at the top of a `hub = usb`
devlist:

| Written         | Means                                            |
| :-------------- | :----------------------------------------------- |
| `switch = link` | the default: `off` takes the port off the bus    |
| `switch = vbus` | `off` cuts the socket's power                    |

On an ExSYS hub the key is refused rather than ignored: that hub always
cuts power, and a line that changes nothing is a line somebody will
trust.

Find out which yours is by watching a board's LED.  Put a board that
lights up on a port, run `usb off` for that port, and look: an LED that
goes out means `vbus`, an LED that stays lit while the board disappears
from the host means `link`.  Test the socket you will actually use — the
USB 2 and USB 3 sides of one socket are different ports on different
hubs, and a hub may switch neither.
`examples/vbus-check` runs the recipe: give it the options you would
give `tribble-control` and the port, it cuts the port for five seconds,
restores it even on Ctrl-C, and prints the `switch =` line your answer
implies.

Under `switch = link` everything that powers down still works.  `usb
off`, `toggle` and `set` behave, the board vanishes from the host
exactly as a power cut would, and `--method power` still identifies a
board by being the only one openocd can see.  What does not happen is
the board restarting.  So every power-down warns once, naming the ports
that stay powered:

```text
ugen1.4 cuts the link, not the power: the board(s) on port(s) 1 2 stay
powered (switch = link)
```

and the after-flash power cycle (`power_cycle = after-flash`, the
DWM1001's trap) is skipped with a warning rather than pretended — a
cycle that only re-enumerates the probe leaves the board in the very
state the cycle exists to clear.

After every switch the port's status is read back, and the command fails
if the power bit did not follow.  That read-back is the tool's only
measurement of whether a hub switches at all: a hub that accepts
`CLEAR_FEATURE(PORT_POWER)`, answers OK and leaves the port up would
otherwise have `usb off` report success on a bench it never touched.
Nothing is refused on what a hub *declares* about its switching, for the
same reason — the dock's Genesys hub declares ganged and switches per
port anyway.


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
                #   openocd command line, the ExSYS hub exchange against
                #   a pty emulator and the usb one against a fake
                #   usbconfig
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
