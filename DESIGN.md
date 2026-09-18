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
      │       usb    : all declared ports on; boards in sequence
      │       power  : one board powered at a time; bench left off
      │
      ├──▸ openocd(*cmds, **hopts)       flash, reset, connect --reset
      ├──▸ Platform.usb_to_tty           connect
      │    Platform.serial_to_tty
      └──▸ hub.on / hub.off / hub.state  every switch, through Hub
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
    platform.rb            Linux/FreeBSD ways of finding the boards
    hub.rb                 what any hub answers: ports, state, on, off
    hub/exsys.rb           the ExSYS hub, over the exsys gem
    hub/usb.rb             any hub that switches its own ports, via usbconfig
    tally.rb               the seam where firmware knowledge goes
    cli.rb                 options, devlist, each_device, openocd
    cli/*.rb               one file per command (usb, flash, ...)
man/man1/tribble-control.1   the manual (mdoc), rendered by --man
examples/devlist.conf      a device list to copy and edit
examples/vbus-check        the LED recipe as a script: cut, hold, restore, ask
test/test_*.rb             minitest: everything that needs no hub
test/support/fake_hub.rb   a pty speaking the ExSYS hub's real frames
test/support/fake_usbconfig.rb  a host answering sysctl and usbconfig
test/test-tribble-control    the regression suite, against a deployed copy
```


## The devlist is the only model of the bench

`CLI#parse` reads the file with UCL, lifts out the five keys that are
not devices — `device`, `reserved`, `undeclared`, `tally`, `types` —
and treats everything else as a device entry.

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
  * **A `device` that is a block or a list.**  A devlist is one bench,
    and one bench is one hub; a file naming two would be a file whose
    port numbers mean two different things.

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


## The hub is an interface, and the ExSYS hub is one of them

Every switch in the program goes through `TribbleControl::Hub`: `ports`,
`state`, `on`, `off`, `toggle`, `set`, `usb_path(port)` and `vbus?`,
plus `to_s` for the messages.  `CLI#hub` holds the one instance, the
commands reach it through the `hub` delegate, and nothing above
`each_device` knows which kind it is.

Two backends answer it.  `Hub::ExSYS` wraps `ExSYS::ManagedUSB`, and
everything in this section that is about the FT232, the gem, or the
4-by-4 geometry lives in that class and not in `CLI`.  `Hub::USB`
(`lib/tribble-control/hub/usb.rb`) drives any hub that switches its own
ports, through `usbconfig` hub-class requests: the hub descriptor says
how many ports there are, `GET_STATUS` says whether one is powered, and
SET_FEATURE/CLEAR_FEATURE of PORT_POWER switches it.  It needs no gem,
because the switching is on the bus itself rather than on a serial line
wired beside it, and it is FreeBSD-only for now — the refusal is in
`Hub::USB.open`, so nothing above it knows about platforms.
`Hub.backend(kind)` maps the devlist's `hub =` word to the class and
requires it on demand, so a host lacking what one backend needs still
runs the other.

Five decisions shape the second backend, and none of them is a fact
about hubs that the first one contradicts:

  * **The kind is declared, never inferred.**  `hub = exsys|usb` says
    what the hub *is*, not which tool drives it on this host, so the
    same devlist line keeps working the day a Linux implementation
    lands.  It cannot be read off `device =`: a USB path such as
    `1-1.1` names an FT232's socket for the ExSYS hub and the hub
    itself for a usb hub.  Inferring the kind from the shape of the
    name was rejected for exactly that, and so were `usbconfig` and
    `freebsd` as names for the key — both name the driver rather than
    the hardware.
  * **`switch = link|vbus` is the operator's to declare.**  Software
    cannot tell whether a hub's power switch is wired to the socket: a
    hub with none still reports the port unpowered and drops the link,
    and the device vanishes and returns either way.  Measured on the
    dock's Genesys hub on 2026-09-18 — a flash drive detached and
    re-enumerated on CLEAR/SET_FEATURE(PORT_POWER), while an
    nRF52840-MDK's LED stayed lit through two five-second cuts, on the
    USB 2 and on the USB 3 side of the same socket.  So the operator
    watches a board's LED through `usb off` and writes the answer down.
    A mode built on `usbconfig power_off` was rejected: on FreeBSD 15
    it only unconfigures the device and clears `PORT_ENABLE` on the
    parent port, keeps VBUS, and needs root — the `USB_RE_ENUM_PWR_OFF`
    branch of /usr/src/sys/dev/usb/usb_hub.c, and the
    `priv_check(PRIV_DRIVER)` in the set-power-mode ioctl of
    /usr/src/sys/dev/usb/usb_generic.c — so the hub-class request does
    strictly more with less privilege.
  * **Link mode works everywhere except where it cannot.**  A board on
    a port taken off the bus vanishes from the host exactly as a power
    cut would, so `usb off/on/toggle/set` behave and `--method power`
    still identifies a board by being the only one visible to openocd.
    What does not happen is the board restarting, so every power-down
    warns once naming the ports that stay powered (`CLI#warn_link_only`)
    and the after-flash cycle is skipped with a warning
    (`lib/tribble-control/cli/flash.rb`).  Doing the cycle silently was
    rejected: the board
    would keep the very state the cycle exists to clear.
  * **The read-back is the only measurement.**  After every SET/CLEAR
    the backend reads the port status back and raises if the power bit
    did not follow.  A hub that switches nothing accepts the request
    and answers OK, so without this `off` would report success on a
    bench it had not touched.  It is also why nothing is refused on
    `wHubCharacteristics`: the dock's Genesys hub declares ganged
    switching and switches per port anyway, and the descriptor is a
    claim where the read-back is a measurement.  Refusing hubs that
    declare ganged or no switching was rejected on that.
  * **Membership of group `operator`, and not root.**  The ugen nodes
    are `root:operator` 0660, and the kernel's `usb_check_request`
    (/usr/src/sys/dev/usb/usb_util.c) demands the driver privilege only for
    SET_ADDRESS, SET_CONFIG and SET_INTERFACE; hub-class port feature
    requests pass.  The backend turns the kernel's "Permission denied"
    into a message naming the group rather than passing it on.

The base class carries the last guard: a switching method handed an
empty list, or a port the hub does not have, raises `Hub::Error` before
a backend sees it.  Every caller checks first — see the invariants —
so this is the net and not the trapeze, but a fourth path into the hub
that forgets is now stopped rather than read as "every port".

A backend answering less than the interface says so by name
(`NotImplementedError` naming the class and method) rather than as a
`NoMethodError` on an internal — the same rule `Platform` has for a
host that cannot implement a lookup.  Its errors are `Hub::Error`,
which `CLI.run` prints as one line; `Hub::ExSYS` translates the gem's
own error class into it so the commands never see the gem's.


## Which hub, and why the devlist names it

`ExSYS::ManagedUSB.available` returns every FTDI 0403:6001 on the host
as `{ device:, serial:, usb_path: }`.  `Hub::ExSYS.open` turns that
plus what was asked for into the one line the gem is handed:

```text
Hub::ExSYS.open(named)    named = -d, else the devlist's `device`, else nil

    named has a '/' in it?          ──yes──▸  the serial line itself,
                   │                          used as given
                   no
                   ▾
    named looks like 1-1.2.4.4?     ──yes──▸  the candidate in that
                   │                          socket, or an error
                   no
                   ▾
    named at all?                   ──yes──▸  the candidate whose serial
                   │                          it is, or an error listing
                   no                         what the host does have
                   ▾
    exactly one candidate?          ──yes──▸  that one
                   │
                   no
                   ▾
               an error
```

The three shapes cannot collide: a serial is never digits and dashes in
the USB-path shape, and neither of those contains a `/`.  The pattern
is the gem's `ExSYS::ManagedUSB::USB_PATH`, published for exactly this
— a caller taking a name from a human should not have to invent it.

Two decisions are load-bearing:

  * **Auto-detection refuses to guess between two.**  That FTDI id is a
    hub's control adapter and equally every other FT232 on the host, so
    picking the first enumerated is a coin toss — and driving the wrong
    hub raises nothing anywhere.  The ports exist, the frames are
    accepted, `usb status` answers, and the boards that go dark are on
    the other bench.  There is no later check that could catch it, which
    is why the guess is refused rather than warned about.
  * **The serial line is what a file should never carry.**  The `1` in
    `ttyUSB1` is neither the hub's number nor the USB device number: it
    is the usbserial layer's index, and it is the lowest one free when
    that adapter is probed.  It therefore depends on what else attached
    first, and it is reused — unplug the adapter holding `ttyUSB0` and
    the next thing to attach takes `ttyUSB0`.  Two hubs can swap names
    across a reboot or while the machine is up, and every devlist
    naming them that way then points at the other bench, silently.
  * **A serial and a USB path are both stable, and not the same
    promise.**  A serial is in the FT232's EEPROM and follows the
    adapter; a USB path is a position in the tree and follows the
    socket, so a replacement hub inherits it.  Naming one particular
    hub is the serial's job and is the default advice.  The path exists
    for the case the serial cannot cover — an adapter whose EEPROM
    carries none, which otherwise has no stable name at all.  Both
    platforms report one: Linux states it, and on FreeBSD the gem walks
    it out of the sysctl tree.  Each host numbers in its own way,
    though, so a path names a socket on the machine that reported it.
    A path named on a host that reports none at all is refused with
    that said, rather than as a path that is merely absent — the two
    send a reader looking in different places.  A value with a `/` in it is taken as a path anyway — the
    same rule `--openocd` uses — because a line reached some other way
    still has to be nameable.

`Hub::USB.open` holds the same policy in its own shapes: a ugen name is
a device used as given, `1-1.1` is a USB path, anything else is a
serial, and the three cannot collide either.  Auto-detection takes a
lone candidate and refuses two or more, listing each with its serial,
its ugen name, its USB path and its port count — the count being what
tells two of the same part apart when neither carries a serial.  Root
hubs are never candidates: they are the controller, their `%location` is
empty and their parent is a usbusN, and a port of one has no PORT_POWER
to clear, so offering one would offer a hub every command against it
then failed on.  Discovery reads `sysctl -e dev.uhub` and asks each
candidate for its hub descriptor, so a hub that will not answer one is
listed all the same with no port count — a listing must not be stopped
by one odd hub — and choosing that hub is what is refused.

The devlist is the place for it because a devlist is already one bench:
the command that says which device list then says which hub, and that
is the only thing it has to say.  `-d` stays for the one-off.

The split with the `exsys` gem is along the same line as everywhere
else: what a hub *is* belongs to the gem, what this bench *wants*
belongs here.

  * The gem reports. `ExSYS::ManagedUSB.available` knows the FTDI id
    because it knows the hub, knows how to ask a Linux or a FreeBSD
    host, and knows that a candidate is not a hub — every FT232 on the
    machine matches, and telling them apart means opening the line and
    writing to it.  So it lists, with serials, and decides nothing.
  * This tool decides. `Hub::ExSYS.open` is where the policy and the
    wording live: what `-d` means against what the devlist says, that
    one candidate may be taken and two may not, and what to print when
    it refuses.  None of that is a fact about hubs; it is a fact about
    this tool's promise not to switch the wrong bench.  It sits in the
    backend rather than in `CLI` because the shapes a name may take —
    an FT232 serial, a socket, a serial line — are this hub's shapes,
    and another kind of hub is named in other ways.

`Platform` keeps only the board-side lookups.  It has its own
`udevadm`/`sysctl` plumbing for the probes and consoles, which is why
the two readings look alike and are nonetheless not shared: one is
about a bench's boards, the other about a product's control adapter,
and the gem must work for callers that have no bench at all.

### The floor is exsys 1.2

The gemspec requires `exsys` as `~> 1.2`, and this tool is exactly the
caller that floor is for.  Under 1.1, a FreeBSD control adapter whose
tty was not named yet came back from `ExSYS::ManagedUSB.available` as
`:device` `/dev/tty` — the string `/dev/tty` plus an empty ttyname —
and `Hub::ExSYS.open` takes a lone candidate without asking, so `usb off`
on such a host would have opened the operator's own controlling
terminal and written SP frames at it.  1.2 reports no candidate at all
for an adapter whose tty is not named.

Two more things come with that floor.  The gem's own walk up the
sysctl tree is bounded, so a `%parent` chain that loops ends the walk
rather than running forever; and only an `Exx` reply is read as a hub
code, so a line that has gone silent no longer raises an `Error`
carrying no message.  The second one matters here because `CLI.run`
prints the message and nothing else: an error without one is the whole
of what the operator is told, at the moment the line went quiet.

The alternative was a guard here — `Hub::ExSYS.open` refusing a candidate
whose device is `/dev/tty` — and it was rejected.  That would paper
over a gem defect inside one caller and leave every other caller of
the gem exposed, and discovery is the gem's half of the split above.

The requirement stays pessimistic on the series (`~> 1.2`, not
`>= 1.2`) for the reason the `ucl` pin gives: the failure mode of a
quiet semantic change in the hub layer is a port switched that should
not be.

The duplication above now runs to those guards as well, and stays
duplicated.  `Platform`'s walk and the gem's discovery grew the same
two independently: an entry with no ttyname, which `probe_consoles`
drops, and a `%parent` chain that loops, which `usb_path` bounds with
a seen-set.  That is the visible price of the split, and it was paid
knowingly — the gem must work for callers with no bench, and
`Platform`'s walk is about a bench's boards rather than about a
product's control adapter.  Nothing merges them.


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

A platform is a module under `Platform` holding three `def self.` methods.
`Platform::Current` is chosen by a `case` on `RbConfig::CONFIG['host_os']`
at the foot of `platform.rb` — `/^linux-/` and `/^freebsd/` today, with
anything else raising — and the module-level `def self.x(...) = Current.x(...)`
forwarders below it are what the rest of the program calls.  Adding a
platform is a module plus a branch in that `case`.

| Method                | Answers                 | Today |
| :-------------------- | :---------------------- | :---- |
| `probe_consoles`      | `{probe serial => tty}` | both  |
| `usb_to_tty(path)`    | USB path → console tty  | both  |
| `usb_to_serial(path)` | USB path → probe serial | both  |

Finding the *hub* is not among them: that is the hub backend's
(`Hub::ExSYS.open`, through the exsys gem).  What is here is finding
the *boards*.

Nor is the hub's geometry — which socket a port is — which used to be
a `Platform.port_to_usb` and is now `Hub#usb_path(port)`.  It walks
nothing: for the ExSYS hub it is four internal banks of four under the
control adapter's own root, so a board on a port is at
`root.bank.slot`, and the root is the adapter's path less its last two
components.  Geometry belongs to the hub, not to the host, and a new
platform module neither defines it nor needs to.

The last two are about USB topology, and the two platforms differ in
where that comes from.  Linux states it: `/sys/bus/usb` has a directory
per device named by its path.  FreeBSD states nothing of the kind, so
the two lookups walk it out of the sysctl tree — `%location` gives the
port a device occupies on its parent, `%parent` names that parent, and
the walk ends at a root hub, whose `%location` is empty.  A walk that
does not *reach* a root answers nil rather than what it collected:
stopping one hub short turns `1-1.2.4.4` into `1-4`, which is not a
broken string but a different socket.

The one asymmetry left is that FreeBSD cannot see a device no driver
claimed — there is no `dev.ugen` — so such a device has no node, no
serial and no path.  Every probe the bench carries attaches something
(a DAPLink is `umodem`, `umass` and `usbhid` at once), but a probe that
enumerates and attaches nothing is invisible there rather than
serial-less.  `Platform.serial_to_tty` is built
on `probe_consoles` alone, needs no USB topology, and is therefore what
lets a host without `/sys` reach a console at all.

Two conventions for a platform that cannot implement all three — both
platforms do today, and FreeBSD did not until its topology was walked
rather than read, so a third is likely to arrive short again:

  * **Stub, do not omit.**  An undefined method arrives as
    `undefined method 'usb_to_tty' for module ...`, which names an
    internal and tells the reader nothing.  Raise a `CLI::Error` that
    says which piece is missing and which commands still work.  Each
    of the two topology methods has a second route to the same board
    — `serial` addresses a probe by its serial and `power` by being
    the only one on — so a platform missing both still runs every
    command.
  * **Use `private_class_method def self.…`** for helpers.  A bare
    `private` does nothing to a `def self.` singleton method, and a
    helper defined as an instance method on a module whose every caller
    is a `def self.` is simply unreachable.

### A new hub backend — a subclass of `Hub`

A backend is a subclass of `Hub` in a file under
`lib/tribble-control/hub/`, listed in `Hub::KINDS` under the word a
devlist's `hub =` line uses, and loaded on demand by
`Hub.backend(kind)`.  What it has to answer:

| Method               | Answers                                          |
| :------------------- | :----------------------------------------------- |
| `ports`              | every port, in order, numbered as the hub does   |
| `state`              | `{ port => true/false }`, for every port         |
| `on` `off` `toggle`  | switch the ports named                           |
| `usb_path(port)`     | where a board on that port is in the USB tree    |
| `to_s`               | the hub as a message names it                    |

Two have defaults in the base class: `set` is an on and an off, which a
backend that can apply a whole configuration in one exchange overrides,
and `vbus?` answers true, the honest answer for a hub built to switch
VBUS.  The rest raise `NotImplementedError` naming the class and the
method, so a backend answering less than the interface says so by name
rather than as a `NoMethodError` on an internal.  Errors are
`Hub::Error` and carry a message, because `CLI.run` prints the message
and nothing else.  The base class also holds the last guard: an empty
port list, or a port the hub has not got, raises before the backend
sees it.

Naming and refusal policy lives in the backend's own `open`, not in
`CLI`: which shapes a name may take, that one candidate may be taken
and two may not, and the wording of each refusal.  None of that is a
fact about hubs — it is this tool's promise not to switch the wrong
bench — and the shapes differ by kind.  A platform refusal belongs
there too; `Hub::USB.open` is where FreeBSD-only is said, so a host that
cannot run one backend still runs the other.

A backend is testable without hardware, and the two show the two ways.
`Hub::USB` takes an injected runner, so `test/support/fake_usbconfig.rb`
*is* the host: it answers `sysctl -e dev.uhub` with a tree in the real
format and each `do_request` with the exact text usbconfig prints,
angle brackets and the trailing ASCII copy included, and a hub built
with `honours: false` accepts a switch and does not switch, which is the
only way to drive the read-back check.  `Hub::ExSYS` goes the other way,
against `test/support/fake_hub.rb` on a pty speaking the real frames.
A new backend picks whichever its transport allows; the policy tests
stand on the fake either way.

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
| `hub`                     | the hub object (a `Hub`; today `Hub::ExSYS`)   |
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
    that has already succeeded.  Nothing calls `@hub.off` with a raw
    port and no gate.
  * **An empty list never means "every port".**  `offable` either
    returns a non-empty list or raises; `usb on` names every port
    outright (`hub.on(*hub.ports)`) rather than passing an "all";
    `each_device` guards its selection.  Those are the three, and
    `Hub#selection` is the net under them: a backend is never handed an
    empty list, whatever a fourth path forgets.
  * **The commands talk to `Hub`, not to a backend.**  A method the
    interface does not name is a method the next backend will not
    have.  Add it to `Hub` first, with a default or as a
    `NotImplementedError`, and then to the backends.
  * **Only `SP` is ever issued.**  Port states are set for the here and
    now, never written to the hub's flash, so nothing the tool does
    survives a hub power cycle.  `FP`, `WP`, `RD` and `RH` are not used
    — the last two drop every port, reserved ones included.
  * **The version lives in `version.rb` alone.**  The gemspec reads it
    from there and `--version` prints the same constant, so a release
    cannot have two numbers.
  * **A guess about which hub is never made when it could be wrong.**
    Reaching the wrong hub is undetectable after the fact — every frame
    is accepted and the boards that go dark are somebody else's — so
    two candidates is an error, not a warning and not a default.
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
  * **The power bit is not the same bit on both kinds of hub.**  A USB
    2 hub (descriptor 0x29) reports it in 0x0100 of wPortStatus; a
    SuperSpeed hub (0x2a) reports it in 0x0200 and puts the link state
    in bits 5-8, so reading a SuperSpeed port with the USB 2 bit
    answers "unpowered" for a port that is fine.  Which descriptor the
    hub *answers* is what decides, and is remembered for that.
  * **`usbconfig` exits 0 for a request the hub refused**, printing
    `REQUEST = <ERROR>`, and exits 0 for a device it could not even
    find.  The printed text is the truth; the status says nothing.
  * **A dock's hub chain may reset on its own.**  The pair of TUSB8041
    hubs on the dock this was written against detached and re-attached
    every few minutes under test, taking every board with them.  A hub
    that flaps is a poor bench hub whatever its descriptor declares.
  * **The LED test is the only proof that a hub switches VBUS.**  The
    read-back proves the hub did what it was told, not that the socket
    lost power: a hub with no switch wired clears the bit, drops the
    link, reports itself unpowered, and leaves the board running.
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

`rake test` covers devlist parsing, types, tallies, hub selection and
the openocd command line, and drives the hub exchange itself against a
pty emulator speaking the real frames.  Hub selection is tested against
a stubbed `ExSYS::ManagedUSB.available` under `Hub::ExSYS`, since what is being asserted
is the policy — which candidate is taken, and when none is — and not
the `udevadm`/`sysctl` reading that finds them, which the gem tests
against captured output of its own.  The usb backend is proved the same
way and with no hub either: an injected runner stands in for the host,
so the descriptor reading, the port numbering, the link-mode warnings
and the read-back that catches a hub which accepts a switch and does
not switch are all asserted against `test/support/fake_usbconfig.rb`.

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
