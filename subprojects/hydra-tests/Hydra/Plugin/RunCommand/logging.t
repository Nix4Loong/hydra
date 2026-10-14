use strict;
use warnings;
use Test2::V0;
use File::Temp qw(tempdir);
use Hydra::Plugin::RunCommand;

{
    package Test::RunCommandBuild;
    sub id { 1; }
    sub get_column { 1; }

    package Test::RunCommandLog;
    sub started { }
    sub uuid { 'test-runlog'; }
    sub completed_with_child_error {
        my ($self, $status, $errno) = @_;
        $self->{status} = $status;
        $self->{errno} = $errno;
    }

    package Test::RunCommandDB;
    sub resultset { $_[0]; }
    sub create { $_[0]->{runlog}; }
}

my $tmp = tempdir(CLEANUP => 1);
my $build = bless({}, 'Test::RunCommandBuild');
my @cases = (
    ['success', "$^X -e 'exit 0'", 0, 1],
    ['nonzero exit', "$^X -e 'exit 7'", 7 << 8, 0],
    ['signal', "$^X -e 'kill 15, \$\$'", 15, 0],
    ['exec failure', "$tmp/no-such-command", -1, 0],
);

for my $case (@cases) {
    my ($label, $command, $expected_status, $success) = @$case;
    subtest $label => sub {
        my $runlog = bless({}, 'Test::RunCommandLog');
        my $db = bless({runlog => $runlog}, 'Test::RunCommandDB');
        my $plugin = Hydra::Plugin::RunCommand->new(db => $db, config => {});
        my $stderr_path = "$tmp/stderr.log";
        {
            no warnings 'redefine';
            local *Hydra::Plugin::RunCommand::showJobName = sub { 'test:jobset:job'; };
            local *Hydra::Plugin::RunCommand::fanoutToCommands = sub {
                [{matcher => '*:*:*', command => $command}];
            };
            local *Hydra::Plugin::RunCommand::makeJsonPayload = sub { {}; };
            local *Hydra::Helper::Nix::constructRunCommandLogPath = sub { "$tmp/command.log"; };
            # IPC::Run3 redirects/restores real file descriptors. A scalar
            # Perl handle loses output after run3, so capture to a real file.
            open(local *STDERR, '>', $stderr_path) or die $!;
            $plugin->buildFinished($build, []);
        }
        open(my $stderr_file, '<', $stderr_path) or die $!;
        my $stderr = do { local $/; <$stderr_file>; };
        close $stderr_file;
        is($runlog->{status}, $expected_status, 'database receives original child status');
        if ($success) {
            like($stderr, qr/Command completed successfully/, 'successful child is logged as successful');
            unlike($stderr, qr/Command failed|notification command .* failed/, 'successful child has no failure log');
        } else {
            unlike($stderr, qr/Command completed successfully/, 'failed child is never logged as successful');
            like($stderr, qr/Command failed with exit status \Q$expected_status\E /,
                'failure log retains original child status');
            like($stderr, qr/notification command .* failed with exit status \Q$expected_status\E /,
                'notification warning retains original child status');
        }
        is($runlog->{errno}, 2, 'exec failure errno survives logging and file cleanup')
            if $label eq 'exec failure';
    };
}

done_testing;
