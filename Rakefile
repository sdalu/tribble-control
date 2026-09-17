require 'bundler/gem_tasks'

# The suite runs against a DEPLOYED copy over ssh -- the gems it needs
# live on the bench host, not here -- so this task only passes the two
# things that change: which host, and where the binstub is on it.
desc 'Run the regression suite against the deployed copy'
task :test do
    sh 'sh', 'test/test-tribe-control',
       ENV.fetch('TRIBE_HOST', ''), ENV.fetch('TRIBE_PATH', '')
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

task :default => :test
