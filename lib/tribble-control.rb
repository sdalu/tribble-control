#
# tribble-control -- power, flash and monitor the devices plugged into an
# ExSYS 16-port managed USB hub.
#
#     tribble-control -D devlist.conf flash zephyr.hex A1 A3
#     tribble-control -D devlist.conf connect --off C2 B2 | tee twr.log
#
# A hub port may feed something that must never lose power, so
# tribble-control refuses to switch off any port the devlist does not
# declare, and any port it marks reserved; -F/--force lifts both rules.
#
# Full documentation -- port map, device selection, recipes and traps --
# is in man/man1/tribble-control.1, and is displayed by
# `tribble-control --man`.
#
require_relative 'tribble-control/version'
require_relative 'tribble-control/platform'
require_relative 'tribble-control/cli'
require_relative 'tribble-control/tally'

# The commands, loaded for their side effect: CLI.commands finds them by
# asking CLI::Command for its subclasses, so a command file that is
# never required is a command the tool does not have.
require_relative 'tribble-control/cli/usb'
require_relative 'tribble-control/cli/serial'
require_relative 'tribble-control/cli/flash'
require_relative 'tribble-control/cli/reset'
require_relative 'tribble-control/cli/connect'
