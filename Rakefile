require 'bundler/gem_tasks'

# Two suites, and `rake test` is the one that runs anywhere.
#
# The minitest half needs no hub: the devlist layer, types, tallies and
# the openocd command line are all decided before hardware is touched,
# and the hub exchange itself is tested against a pty emulator
# speaking the real frames. The shell half drives a DEPLOYED copy over
# ssh and needs the bench, so it is not what `rake` does by default --
# a project whose only proof requires a lab in another city cannot be
# checked by whoever is holding it.
require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
    t.libs       << 'test' << 'lib'
    t.test_files  = FileList['test/test_*.rb']
    t.warning     = false
end

namespace :test do
    desc 'Run the regression suite against the copy deployed on a hub host'
    task :bench do
        # It refuses to start without a host: one lab's address does not
        # belong in the repository.  TRIBE_HOST or the first argument.
        sh 'sh', 'test/test-tribe-control',
           ENV.fetch('TRIBE_HOST', ''), ENV.fetch('TRIBE_PATH', ''),
           ENV.fetch('TRIBE_TALLY', '')
    end

    desc 'Both: what runs anywhere, then what needs the bench'
    task :all => [ :test, :'test:bench' ]
end

# RubyGems has no notion of a man page: `gem install` copies the file
# into the gem directory and stops there, so nothing makes `man
# tribe-control` work by itself.  Two ways out, neither of them magic:
#
#   * `tribe-control --man` renders the shipped page in place, needing
#     no install and no privileges.  That is the one the bench uses.
#   * this task, for a host that wants the real thing.
#
# A third, for a one-off: the page ships at man/man1/ inside the gem, so
#
#     MANPATH=$(gem contents tribe-control | sed -n 's,/man/man1/.*,/man,p' | head -1) \
#         man tribe-control
#
# works with nothing copied anywhere.
namespace :man do
    desc 'Install the man page under PREFIX (default /usr/local)'
    task :install do
        prefix = ENV.fetch('PREFIX', '/usr/local')
        dir    = File.join(prefix, 'share', 'man', 'man1')
        mkdir_p dir
        install 'man/man1/tribe-control.1', dir, :mode => 0o644
    end

    desc 'Render the man page as it will be read'
    task :show do
        sh 'mandoc', '-Tutf8', 'man/man1/tribe-control.1'
    end

    desc 'Check the man page for roff errors'
    task :lint do
        sh 'mandoc', '-Tlint', 'man/man1/tribe-control.1'
    end
end

# A linter at zero is a gate; at 979 it was a wall nobody read. It runs
# with the tests by default so that the next offence is the only one on
# the screen.
desc 'Check style against .rubocop.yml'
task :lint do
    sh 'rubocop', '--format', 'quiet'
end

task :default => [ :test, :lint ]
