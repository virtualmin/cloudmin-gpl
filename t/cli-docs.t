use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use lib "$Bin/../lib";
use Cloudmin::CLI;
use Test::More;
use File::Temp qw(tempdir);
# Command definitions, manuals and generated docs must cover the same commands.
my $cli = Cloudmin::CLI->new();
my ($pod, $sections) = $cli->pod_sections();
is_deeply([ sort keys %$sections ],
	  [ sort map { $_->{name} } @{Cloudmin::CLI::commands()} ],
	  'POD and table cover the same commands');
my $docs = $cli->docs();
# Help must present review as an alternative to destructive confirmation.
like($cli->synopsis($cli->command('delete-volume')), qr/\(--review \| --yes\)/,
     'storage review syntax does not require deletion confirmation');
like($cli->synopsis($cli->command('unregister-pool')),
     qr/\(--review \| --yes\)/,
     'pool review syntax does not require unregistration confirmation');
is_deeply([ sort $docs =~ /^## ([a-z-]+)$/mg ], [ sort keys %$sections ],
	  'Markdown has one section per command');
unlike($docs, qr/^=(?:head|over|back|item|cut)/m, 'no POD directives remain');
unlike($docs, qr/[BC]</, 'inline POD converted to Markdown');
# Long help starts with the manual title and derives option text from the table.
my $manual = $cli->help('list-systems');
like($manual, qr/^list-systems\n    Lists the virtual machines on this host\./,
     'manual starts with the command and summary');
unlike($manual, qr/^cloudmin list-systems \[/m,
       'manual does not repeat the short syntax');
like($manual, qr/"--name name"\n\s+Exact virtual machine name/,
     'option details use the manual layout');
# Redirection must bypass the pager without changing the rendered manual.
my $redirected = qx{$^X "$Bin/../cli.pl" help list-systems};
is($? >> 8, 0, 'redirected help succeeds without a pager');
is($redirected, $manual, 'redirected help is the complete plain-text manual');
# Check each command and every declared option, not a sample of manual sections.
foreach my $command (@{Cloudmin::CLI::commands()}) {
	my $help = $cli->help($command->{name});
	like($help, qr/\Qcloudmin $command->{name}\E/,
	     "$command->{name} long help has syntax/example");
	my $options = Cloudmin::CLI::options($command);
	foreach my $name (keys %$options) {
		like($help, qr/\Q--$name\E/,
		     "$command->{name} documents --$name");
		}
	}

# Catch newly added API branches that were not added to the command table.
open(my $fh, '<', "$Bin/../cloudmin-lib.pl") ||
	die $!; local $/; my $controller = <$fh>; close($fh);
$controller =~ s/^.*?sub call_vm_api\n//s;
$controller =~ s/\n# get_api_machines.*\z//s;
my %actions = map { $_ => 1 } $controller =~ /\$action eq '([a-z_]+)'/g;
while ($controller =~ /\$action =~ \/\\A\(\?:([a-z_|\s]+)\)\\z\/[x]?/g) {
	my $group = $1; $group =~ s/\s//g; $actions{$_} = 1 for split(/\|/,
								      $group);
	}
# Include preflight and alternate actions when comparing dispatcher coverage.
my %mapped;
foreach my $c (@{Cloudmin::CLI::commands()}) {
	$mapped{$_} =
		1 for grep { defined($_) } ( $c->{action}, $c->{prepare},
					     $c->{summary_action},
					     @{$c->{additional_actions} ||
				[ ]},
					     map { $_->{action} } values %{$c->{options}} );
	}
is_deeply([ sort keys %mapped ], [ sort keys %actions ],
	  'dispatcher branches and CLI action coverage agree');

# Syntax and docs run offline without loading the installed module.
my $output = qx{$^X "$Bin/../cli.pl" --docs};
is($? >> 8, 0, 'cli.pl --docs succeeds offline');
is($output, $docs, 'entry point generates the same Markdown');

# Load installer hooks with a stub library; never write the workstation wrapper.

BEGIN
{
$INC{'server-manager-lib.pl'} = 1;
}
require "$Bin/../postinstall.pl";
my $wrapper =
	main::cloudmin_cli_wrapper('/etc/web min', "/var/web'min",
				   '/usr/share/webmin',
				   '/usr/share/webmin/server-manager',
				   '/usr/bin/perl');
like($wrapper, qr/^#!\/bin\/sh/, 'POSIX shell wrapper');
like($wrapper, qr/WEBMIN_VAR='\/var\/web'"'"'min'/, 'shell paths are quoted');
like($wrapper, qr/exec '\/usr\/bin\/perl' cli\.pl "\$\@"/,
     'all arguments are forwarded');
like($wrapper, qr/id -u.*?exit 2/s, 'wrapper rejects nonroot');
# Parse a temporary wrapper as shell syntax without executing installation.
my $tmp = tempdir(CLEANUP => 1);
open(my $sh, '>', "$tmp/cloudmin") || die $!; print $sh $wrapper; close($sh);
is(system('sh', '-n', "$tmp/cloudmin"), 0, 'wrapper shell syntax');

# Site pages: an overview plus one grouped page per command, stable on rerun.
# read_page(path) returns a generated page's text.

sub read_page
{
open(my $fh, '<', $_[0]) || die "$_[0]: $!"; local $/; my $text =
	<$fh>; close($fh); return $text;
}
my $site = tempdir(CLEANUP => 1);
my @pages = $cli->docs_pages($site);
my @commands = @{Cloudmin::CLI::commands()};
is(scalar(@pages), scalar(@commands) + 1, 'overview plus one page per command');
my $overview = read_page("$site/command-line.md");
like($overview,
     qr/\A---\ntitle: "Command Line API"\ndate: \d{4}-\d\d-\d\d\nweight: 2820000\n---\n/, 'overview front matter');
my %seen_group;
# These commands require Pro; the website badge must survive regeneration.
my %pro_commands = map { $_ => 1 } qw(list-ssh-keys create-ssh-key
    modify-ssh-key download-ssh-key delete-ssh-key list-system-keys
    add-system-key remove-system-key);
foreach my $command (@commands) {
	my $name = $command->{name};
	my $page = read_page("$site/API Programs/$name.md");
	# The sidebar shows a group heading for every page
	# that names a subSection.
	my $group = $seen_group{$command->{group}}++
		? ''
		: "subSection: \"\Q$command->{group}\E\"\n";
	my $edition = $pro_commands{$name} ? 'edition: "pro"\n' : '';
	like($page,
	     qr/\A---\ntitle: "\Q$name\E"\n${group}${edition}date: \d{4}-\d\d-\d\d\nweight: \d+\n---\n\n### /, "$name page front matter and heading");
	unlike($page, qr/^### .*\(Pro\)/m,
	       "$name heading leaves the edition to its title badge");
	like($page, qr/```text\ncloudmin \Q$name\E/, "$name page has syntax");
	like($page, qr/```sh\n/, "$name page has examples");
	unlike($page, qr/^=(?:head|over|back|item|cut)|[BC]</m,
	       "$name page has no POD");
	like($overview,
	     qr{^- \[\Q$name\E\]\(/docs/development/api-programs/\Q$name\E/\): }m, "overview links $name");
	}
# Regeneration keeps publication dates and authors and reports stale pages.
my $edited = read_page("$site/API Programs/list-systems.md");
$edited =~ s/^date: \S+\n/date: 2026-01-02\nauthor: "Tester"\n/m;
open(my $save, '>', "$site/API Programs/list-systems.md") ||
	die $!; print $save $edited; close($save);
open(my $old, '>', "$site/API Programs/old-command.md") ||
	die $!; print $old "---\ntitle: \"old\"\n---\n"; close($old);
my $warnings = '';
open(my $errfh, '>', \$warnings) || die $!;
Cloudmin::CLI->new(err => $errfh)->docs_pages($site);
like(read_page("$site/API Programs/list-systems.md"),
     qr/^date: 2026-01-02\nauthor: "Tester"\nweight: \d+\n/m,
     'date and author kept on regeneration');
like(read_page("$site/API Programs/download-ssh-key.md"),
     qr/^edition: "pro"$/m, 'Pro title badge survives regeneration');
like($cli->help('download-ssh-key'), qr/\(Pro\)/,
     'CLI help retains the Pro label');
like($warnings, qr/^Stale page: .*old-command\.md$/m, 'stale page reported');
ok(-f "$site/API Programs/old-command.md", 'stale page is not deleted');
my $dir = tempdir(CLEANUP => 1);
my $written = qx{$^X "$Bin/../cli.pl" --docs-dir "$dir"};
is($? >> 8, 0, 'cli.pl --docs-dir succeeds offline');
ok(-f "$dir/command-line.md" && -f "$dir/API Programs/api.md",
   'entry point writes the pages');
done_testing();
