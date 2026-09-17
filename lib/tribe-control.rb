#
# tribe-control -- power, flash and monitor the devices plugged into an
# ExSYS 16-port managed USB hub.
#
#     tribe-control -D devlist.conf flash zephyr.hex A1 A3
#     tribe-control -D devlist.conf connect --off C2 B2 | tee twr.log
#
# Ports 13 to 16 feed Raspberry Pis and must stay powered.  tribe-control
# refuses to switch off any port the devlist does not declare; -F/--force
# lifts that rule.
#
# Full documentation -- port map, device selection, recipes and traps --
# is in man/tribe-control.txt, and is displayed by
# `tribe-control --man`.
#
require_relative 'tribe-control/version'
require_relative 'tribe-control/platform'
require_relative 'tribe-control/serialised-hub'
require_relative 'tribe-control/cli'
require_relative 'tribe-control/tally'

# The commands, loaded for their side effect: CLI.commands finds them by
# asking CLI::Command for its subclasses, so a command file that is
# never required is a command the tool does not have.
require_relative 'tribe-control/cli/usb'
require_relative 'tribe-control/cli/serial'
require_relative 'tribe-control/cli/flash'
require_relative 'tribe-control/cli/reset'
require_relative 'tribe-control/cli/connect'
