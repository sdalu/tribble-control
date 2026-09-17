# tribble-control — design notes

For someone changing `tribble-control`: adding a board family, a debug
probe, a host platform, a command or a tally.  The man page says what
the tool does and README.md says how to run it; this file says how the
pieces fit and where they are meant to give.

The one sentence the rest of this file elaborates: **the subject is a
USB hub.**  Anything that is knowledge of a particular chip, a
particular probe or a particular firmware is pushed out of the code and
into the device list, or into a file the device list names.


## The shape of a run

```text
exe/tribble-control     argv in; one rescue turns an exception into a line
      │
      ▾
CLI#parse             -r files, then the devlist, then the hub object
      │
      ▾
CLI#run               resolves openocd if the command declares OPENOCD
      │
      ▾
Command#run(argv, **opts)
      │
      ├──▸ each_device(ids) {|name, **hopts| ... }
      │       serial : all declared ports on; boards in parallel
      │       usb    : all declared ports on; boards in sequence  (Linux)
      │       power  : one board powered at a time; bench left off
      │
      ├──▸ openocd(*cmds, **hopts)       flash, reset, connect --reset
      └──▸ Platform.usb_to_tty           connect
           Platform.serial_to_tty
```

Everything that touches hardware is below `each_device`.  Everything
that decides *which* hardware is above it, in the devlist layer, and is
settled before the hub object exists — which is why most of the test
suite never reaches a hub.


## Layout

```text
exe/tribble-control          the executable; it only calls CLI.run
lib/tribble-control.rb       what `require 'tribble-control'` loads
lib/tribble-control/
    version.rb             the one place the version number lives
    platform.rb            Linux/FreeBSD ways of finding hardware
    tally.rb               the seam where firmware knowledge goes
    cli.rb                 options, devlist, each_device, openocd
    cli/*.rb               one file per command (usb, flash, ...)
man/man1/tribble-control.1   the manual (mdoc), rendered by --man
examples/devlist.conf      a device list to copy and edit
test/test_*.rb             minitest: everything that needs no hub
test/support/fake_hub.rb   a pty speaking the hub's real frames
test/test-tribble-control    the regression suite, against a deployed copy
```


## The devlist is the only model of the bench

`CLI#parse` reads the file with UCL, lifts out the four keys that are
not devices — `reserved`, `undeclared`, `tally`, `types` — and treats
everything else as a device entry.

A setting is then resolved by `attribute(id, key, default)`:

```text
attribute(id, key, default)

    the device's own entry has the key?  ──yes──▸  its value
                   │
                   no
                   ▾
    the entry names a type, and that
    type has the key?                    ──yes──▸  the type's value
                   │
                   no
                   ▾
    the default written in the code
```

Three rules hold this up, and each exists because its absence produced
a wrong flash reported as a success:

  * **Present means present.**  The lookup tests `key?`, not
    truthiness, so a key explicitly set to `false` is not the same as a
    key that is missing.
  * **The entry wins.**  A type is what a *kind* of board has in
    common; a device that says otherwise is saying it about itself.
  * **One level.**  A type is a block of settings, not a thing that can
    itself have a type, and it may not set `port` or `serial` — both
    name one particular board.

What is refused at load rather than discovered later:

  * **An entry with no `port` key.**  Deleting that line is exactly what
    reassigning a port to another board does, so reading "gone" into a
    line somebody forgot would drop a live board silently.
  * **Two entries on the same port.**  The tool would reach whichever it
    found first, under the other one's interface and baud.
  * **A `type =` nothing defines.**  A board that asked for jlink and
    silently got cmsis-dap is a flash through the wrong probe, reported
    as a success.
  * **A type setting `port` or `serial`.**  Both name one particular
    board, so a type that set either would be saying that every board of
    that kind is the same board.
  * **A tally name nothing registered.**  A run that forgot its `-r`
    would otherwise capture a whole bench and report nothing but line
    counts, which reads as a firmware saying nothing.
  * **`undeclared` set to anything but `protect` or `switch`.**  It
    decides what may be powered down.

`port` is normalised to an Integer, or to `nil` for `none`, once at
load — `port_of` is the only place that has to know what a port may
look like.  Write a devlist with `port = '8'` and it is an Integer by
the time anything reads it.

`port = none` is how an entry says it is a record rather than a board:
its serial is worth keeping, and so is the comment saying when it left.
Such an entry is dropped from `#devices`, which is the single filter
every walk of the bench goes through, so it is never selected, never
switched, never flashed, and never counted among the ports that may be
powered down.  `#declared` is the unfiltered list, for looking a serial
up — which is the reason the entry is in the file at all.


## each_device: the one path to a board

`each_device(ids) {|name, **hopts| ... }` resolves a selection into
boards, arranges for them to be reachable, and yields each one with the
keyword arguments that say how to reach it.  What is in `hopts` depends
on the method:

| Method   | `hopts` carries                         |
| :------- | :-------------------------------------- |
| `serial` | `serial:` plus the openocd four         |
| `usb`    | `usb:`, `serial:` plus the openocd four |
| `power`  | the openocd four only                   |

The openocd four are `interface:`, `target:`, `transport:` and
`work_area:` — all devlist keys, all with defaults, none of them a
constant anywhere in the code.  That is what makes a board of another
family a devlist edit rather than a patch.

`power` carries neither a serial nor a path because it does not need
one: it cuts every switchable port and brings up one board at a time,
so the board being addressed is the only board there is.  That is also
why it is the fallback when a `serial =` is missing or wrong, and why
it leaves the bench powered off.

Two things about this method are load-bearing:

  * **An empty selection is refused, never carried through.**  It is
    reachable — a devlist whose every entry says `port = none`, with no
    board named on the command line — and each of the three branches
    would otherwise do something worse than nothing with it: an empty
    splat into the hub reads as *every port*, so selecting no board
    would power all sixteen up and report success for the nought
    boards it flashed, and `power` would cut the bench and leave it off.
  * **`Parallel.map` runs `in_threads:`, not in processes.**  The
    default forks, and a forked child pushes its result into its own
    copy of the accumulator; the parent's stays empty, and `[].all?` is
    `true`, so `flash` and `reset` would exit 0 however many boards had
    failed.  The work is `Open3.capture2e` on openocd, which releases
    the GVL for its whole duration, so threads keep the parallelism and
    keep the results where they can be seen.


## The openocd command line

`CLI#openocd` builds one invocation per board, in this order:

```sh
openocd \
  -c 'set WORKAREASIZE 0x<work_area>'          # unless work_area = none
  -c 'source [find interface/<interface>.cfg]' \
  -c 'transport select <transport>' \          # unless transport = none
  -c 'source [find target/<target>.cfg]' \
  -c 'adapter usb location <usb>' \            # --method usb only
  -c 'adapter serial <serial>' \               # whenever the devlist has one
  -c '<each command the caller passed>' \
  -c shutdown
```

`adapter usb location` is documentation of intent, not a selector:
openocd 0.12 reaches the same adapter whichever path it is given,
including one that does not exist.  `adapter serial` is what actually
selects, which is why `--method usb` passes it too whenever the devlist
has one.  A board with no `serial =`, on a bench with more than one
adapter powered, is a board chosen at random.

The binary is resolved once, by `openocd_path`, before any port is
switched.  A command that always needs it says so with `OPENOCD =
true`; `connect` does not, and checks when it reaches for it under
`--reset`.


## Extension points

### A new board family or probe — the devlist first

Add the keys to the devlist, or to a `types` block.  `interface` and
`target` are independent: the first is the openocd interface script
(which probe), the second its target script (which chip).  Either is
any name openocd can find, without the `.cfg`.

| Key         | Default     | Meaning                                       |
| :---------- | :---------- | :-------------------------------------------- |
| `interface` | `cmsis-dap` | openocd interface script                      |
| `target`    | `nrf52`     | openocd target script                         |
| `transport` | `swd`       | `jtag`, or `none` to let the interface decide |
| `work_area` | `0x4000`    | target RAM for flash algorithms, or `none`    |
| `baud`      | `230400`    | console speed                                 |

A chip and a probe openocd already knows need no code at all.  The one
exception is a probe from a vendor this tool has never seen: add its USB
vendor id to `Platform::PROBE_VENDORS`.  That list is what makes a serial
the key to a console: both probe families the tool knows — DAPLink
(`0d28`) and J-Link OB (`1366`) — present their console as a CDC
interface reporting the *probe's* own serial.  Matching on the vendor
rather than on one probe firmware is deliberate.

### A new tally — a file, loaded with `-r`

What a board's console output *means* is not this tool's business: the
strings worth counting belong to whatever firmware happens to be on the
bench this month, and they change without a hub changing.  So `connect`
knows only how to open a console, prefix its lines and print them, and
hands every line to a tally.

```ruby
TribbleControl::Tally.register(:twr) do |device|
    MyTally.new(device)
end
```

`tally =` at the top of the devlist sets the bench's default and
`tally =` inside a device entry overrides it for that board, so one
capture can read two firmwares.  The block is called once per board per
run, so a tally may keep whatever state it likes without sharing it.
What it returns must answer two messages:

| Message    | Receives / returns                                |
| :--------- | :------------------------------------------------ |
| `#<<`      | every line `connect` prints                       |
| `#summary` | the text of the `SUMMARY` line, or `nil` for none |

Two ship: `lines` counts lines, which is all a tool that knows nothing
about the firmware can honestly say, and `none` is a null object for a
capture that wants no summary at all — a null object rather than `nil`,
so `connect` has one kind of thing to talk to.

A name nothing registered is an error, not a silent fall back to
counting lines: a devlist asking for `twr` on a run that forgot `-r`
would otherwise capture a whole bench and report nothing but line
counts, which reads as a firmware saying nothing.

### A new host platform — a module under `Platform`

A platform is a module under `Platform` holding five `def self.` methods.
`Platform::Current` is chosen by a `case` on `RbConfig::CONFIG['host_os']`
at the foot of `platform.rb` — `/^linux-/` and `/^freebsd/` today, with
anything else raising — and the module-level `def self.x(...) = Current.x(...)`
forwarders below it are what the rest of the program calls.  Adding a
platform is a module plus a branch in that `case`.

| Method                     | Answers                 | Today |
| :------------------------- | :---------------------- | :---- |
| `exsys_ctrl`               | the hub's control ttys  | both  |
| `probe_consoles`           | `{probe serial => tty}` | both  |
| `port_to_usb(port, root:)` | hub port → USB path     | Linux |
| `usb_to_tty(path)`         | USB path → console tty  | Linux |
| `usb_to_serial(path)`      | USB path → probe serial | Linux |

The last three read `/sys/bus/usb`.  `Platform.serial_to_tty` is built
on `probe_consoles` alone, needs no USB topology, and is therefore what
lets a host without `/sys` reach a console at all.

Two conventions for a platform that cannot implement all five:

  * **Stub, do not omit.**  An undefined method arrives as
    `undefined method 'port_to_usb' for module ...`, which names an
    internal and tells the reader nothing.  Raise a `CLI::Error` that
    says which piece is missing and which commands still work.
  * **Use `private_class_method def self.…`** for helpers.  A bare
    `private` does nothing to a `def self.` singleton method, and a
    helper defined as an instance method on a module whose every caller
    is a `def self.` is simply unreachable.

### A new command — a class under `CLI`

Subclass `CLI::Command` in a file under `lib/tribble-control/cli/`, and
**require it from `lib/tribble-control.rb`**: `CLI.commands` finds
commands by asking `CLI::Command` for its subclasses, so a command file
that is never required is a command the tool does not have.  (That is
also where the Ruby 3.1 floor comes from — `Class#subclasses`.)

| Constant      |          | What it does                                 |
| :------------ | :------- | :------------------------------------------- |
| `DESCRIPTION` | required | the line `--help` prints                     |
| `NAME`        | optional | overrides the name derived from the class    |
| `Parser`      | optional | `OptionParser` for its own options           |
| `Defaults`    | optional | fills options not already set                |
| `Methods`     | optional | accepted `--method` values; first is default |
| `OPENOCD`     | optional | truthy → resolve openocd up front            |

The name is derived from the class name unless `NAME` overrides it:
`CLI::BarBaz` becomes `bar-baz`.  A `--method` the command does not list
is refused rather than ignored.

The instance gets `@cli`, and delegates the whole bench vocabulary to it:

| Call                      | Gives back                                     |
| :------------------------ | :--------------------------------------------- |
| `exsys`                   | the hub object (`ExSYS::ManagedUSB`)           |
| `tty`                     | the logger (`TTY::Logger`), or `nil`           |
| `openocd(*cmds, **hopts)` | `true` on success; a block gets `(ok, output)` |
| `each_device(ids, &b)`    | as above; with no block, an Enumerator         |
| `port_list(ids)`          | names or numbers → port Integers               |
| `devices`                 | every declared board that is on the bench      |
| `switchable`              | the ports that may be powered down             |
| `offable(ports, force:)`  | the vetted list, or raises                     |
| `offable?(port, force:)`  | `true` or `false`                              |
| `tally(id)`               | this board's tally name                        |

`conf` is delegated too and is vestigial: `@conf` is never assigned, so
it always answers `nil`.  Do not build on it.

A command that reports per-device success returns `false` if any device
failed, which `CLI.run` turns into exit status 1.


## Invariants a change must not break

  * **Powering down goes through the gate.**  `offable(ports)` raises,
    which is what an explicit `usb off` wants — the user named a port
    and deserves to be told it is protected.  `offable?(port)` answers
    yes or no, which is what a step *inside* something else wants: the
    turn-by-turn off of `--method power`, the cycle a board's
    `power_cycle` key asks for after a flash.  A protected port there
    is a reason to skip the step and say so, not to abort an operation
    that has already succeeded.  Nothing calls `@exsys.off` with a raw
    port and no gate.
  * **An empty list never means "every port".**  `offable` either
    returns a non-empty list or raises; `usb on` tests for empty itself
    before choosing between `on()` and `on(*ports)`; `each_device`
    guards its selection.  Those are the three, and a fourth path into
    the hub needs the same care.
  * **Only `SP` is ever issued.**  Port states are set for the here and
    now, never written to the hub's flash, so nothing the tool does
    survives a hub power cycle.  `FP`, `WP`, `RD` and `RH` are not used
    — the last two drop every port, reserved ones included.
  * **The version lives in `version.rb` alone.**  The gemspec reads it
    from there and `--version` prints the same constant, so a release
    cannot have two numbers.
  * **Failure is reported before the bench is disturbed.**  A missing
    openocd, an unwritable `--debug` file and an unreadable devlist are
    all found before a port is switched.  Finding out that a path is
    unwritable after a bench has been powered down is finding out too
    late.


## Traps

  * **Port 16 is an ordinary socket, but do not use it.**  The FT232
    control adapter is wired inside the hub and enumerates at the last
    position of the hub's internal tree, so `--method usb` would
    compute that path for a board on port 16 and address the FT232.
  * **An MDK puts its own hub in front of its DAPLink.**  The probe
    sits one level below the hub port there, while a J-Link sits on it;
    `usb_to_serial` looks at both and takes the first that is a probe
    with a serial.
  * **openocd no longer prints a probe serial.**  Neither the CMSIS-DAP
    `Serial# =` line nor a J-Link `S/N`, at any debug level.  The
    serial comes from the USB descriptor the kernel already has, which
    needs no SWD session and no powering the rest of the bench down.
  * **`tty-logger` builds its handlers at construction.**  `#configure`
    does not revisit the level, so `--debug` replaces the logger rather
    than reconfiguring it.
  * **A DWM1001-DEV may need a power cycle after a flash.**  It comes
    out of the openocd sequence in a state where its DW1000 never
    reports a transmission again; an SWD reset alone does not clear it.
    That is what `power_cycle = after-flash` is for, and why a board
    whose port is protected gets a warning saying plainly that it
    missed the cycle — the symptom otherwise reads as a radio fault.


## Tests

Two suites, layered the way the code is:

| Suite             | Covers                                 | Needs     |
| :---------------- | :------------------------------------- | :-------- |
| `rake test`       | the devlist layer and the hub exchange | nothing   |
| `rake test:bench` | the whole tool, deployed               | the bench |

`rake test` covers devlist parsing, types, tallies and the openocd
command line, and drives the hub exchange itself against a pty emulator
speaking the real frames.

The split is not an accident of history: nearly everything worth
asserting is decided during devlist parsing, which happens before the
hub object is constructed, so it can be proved on the machine where the
code is written.  A project whose only proof requires a lab in another
city cannot be checked by whoever is holding it.

The bench suite takes a second argument naming a different copy of the
tool, so it can be pointed at a deliberately broken one: a test that
has never been seen to fail is not evidence.  What stays baked into it
is that bench's inventory — board names, a probe serial, a USB path,
the flash page the gate writes — and pointing the suite at another
bench means editing them.

`rake lint` gates at zero rubocop offences and runs with `rake`.  A
linter at zero is a gate; at several hundred it is a wall nobody reads.


## Releasing

  * Bump `VERSION` in `lib/tribble-control/version.rb`.  Nothing else
    carries a number.
  * `gem build` must run with the checkout as its working directory:
    RubyGems resolves the manifest's paths against the cwd, not against
    the gemspec.
  * The manifest keeps the page at `man/man1/` inside the gem, which
    makes the gem's `man/` a usable `MANPATH` entry with nothing copied
    anywhere.  See `rake man:install`.
  * `allowed_push_host` is `none`.  This gem drives a bench; it is
    installed from a checkout, not fetched, and `gem push` on it would
    be an accident.
  * `Gemfile.lock` is not committed.  This is a library, and the bench
    installs the built gem rather than a vendored bundle, so nothing
    reads a lock.
