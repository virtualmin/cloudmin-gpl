use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
use WebminCore;
our ($module_root_directory, $module_var_directory, $root_directory, %text);
# Load real rendering helpers against isolated module state, without host cron.
$module_root_directory = "$Bin/..";
$module_var_directory = tempdir(CLEANUP => 1);
$root_directory = $CloudminTest::webmin_root;
require "$Bin/../cloudmin-backups-lib.pl";
require "$Bin/../cloudmin-backup-pages.pl";
open(my $lang, '<', "$Bin/../lang/en") or die $!;
while (<$lang>) { chomp; $text{$1} = $2 if /^([^=]+)=(.*)$/; }
close($lang);

# Each recurrence maps to one cron rule, without combining date and weekday.
my %time = ( minute => 17, hour => 2, weekday => 0, day => 31, month => 12 );
my %expected = (
	hourly => [ 17, '*', '*', '*', '*' ],
	daily => [ 17, 2, '*', '*', '*' ],
	weekly => [ 17, 2, '*', '*', 0 ],
	monthly => [ 17, 2, 31, '*', '*' ],
	yearly => [ 17, 2, 31, 12, '*' ],
);
foreach my $frequency (sort keys %expected) {
	my $when = backup_schedule_time({ %time, frequency => $frequency });
	my $cron = backup_schedule_cron($when);
	is_deeply([ @{$cron}{qw(mins hours days months weekdays)} ],
		  $expected{$frequency}, "$frequency cron fields");
	my %form =
		( frequency => $frequency,
		  map { ('schedule_'.$frequency.'_'.$_) =>
				$time{$_} } keys %time );
	$form{'schedule_unused_minute'} = 'invalid';
	is_deeply(backup_schedule_time(parse_backup_time(\%form)), $when,
		  "$frequency form reads only its own fields");
	like(backup_schedule_label($when), qr/17/,
	     "$frequency summary includes the chosen time");
	}

# Reject malformed times and impossible yearly dates, but allow leap-day runs.
foreach my $bad (
	{ frequency => 'invalid' }, { minute => 60 }, { hour => 24 },
	{ hour => -1 },
	{ minute => '*/5' }, { minute => [ ] },
	{ frequency => 'weekly', weekday => 7 },
	{ frequency => 'monthly', day => 0 }, { frequency => 'monthly',
						day => 32 },
	{ frequency => 'yearly', month => 13 },
	{ frequency => 'yearly', month => 2, day => 30 },
	{ frequency => 'yearly', month => 4, day => 31 } ) {
	ok(!eval { backup_schedule_time({ %time, frequency => 'daily',
					  %$bad }); 1 },
	   'invalid schedule rejected');
	}
ok(eval { backup_schedule_time({ %time, frequency => 'yearly', month => 2,
				 day =>
					 29 }); 1 },
   'February 29 is a valid yearly run');
is(backup_schedule_time({ frequency => 'hourly', minute => 0, hour =>
								      'unused' })->{minute}, 0, 'hourly schedules ignore hidden hours');

# Retention is a grouped selector, with one unambiguous selection per value.
foreach my $days ( 0, 1, 7, 30, 365, 3650 ) {
	my $html = show_backup_retention($days);
	my @selected = $html =~ /(<option\b[^>]*\bselected[^>]*>)/g;
	is(scalar(@selected), 1, 'one retention choice is selected');
	like($selected[0], qr/\bvalue="$days"/,
	     "retention preserves $days days");
	is(scalar(() = $html =~ /<optgroup\b/g), 4,
	   'retention groups days, weeks, months and years');
	unlike($html, qr/<input|keeps all|newest successful/,
	       'retention has no textbox or inline explanation');
	}

# Render both form stages and check every contextual link, including Pro fields.
{
	no warnings qw(redefine once);
	my @topics;
	local *main::hlink =
		sub { push(@topics,
			   $_[1]); return "<a href=\"$_[1]\">$_[0]</a>" };
	local *Cloudmin::BackupTransport::has_pro_providers = sub { 1 };
	local *main::backup_schedules = sub { [ ] };
	local *main::backup_host_script = sub { '' };
	local *main::submission_script = sub { '' };
	local *main::get_libvirt = sub { bless({ }, 'BackupHelpFixture') };
	local *BackupHelpFixture::list_domains = sub { [ ] };
	local *BackupHelpFixture::list_storage_pools = sub { [ ] };
	local *main::get_vm_jobs = sub { bless({ }, 'BackupHelpFixture') };
	local *BackupHelpFixture::get =
		sub { { id => 'a' x 32, state => 'complete', request =>
								     { operation => 'backup_inspect' },
			resources =>
				{ manifest =>
					  { name => 'fixture',
					    uuid => 'fixture',
					    disks =>
						    [ ] } } } };
	my $form = show_backup_form({ new => 1 }, 'token');
	unlike($form,
	       qr/Guest-agent preparation keeps|Full backups need extra space|newest successful backup/, 'long explanations are absent from the form');
	like($form, qr/name="frequency"/, 'schedule has a recurrence selector');
	# Display preferences change expansion, not the
	# submitted schedule options.
	my @sections;
	my $hidden_start = \&ui_hidden_table_start;
	# ui_hidden_table_start(@args) records section IDs and
	# expansion, then renders.
	local *main::ui_hidden_table_start =
		sub { push(@sections, [ @_[3, 4] ]); $hidden_start->(@_) };
	local $main::config{'backup_sections'} = 'opts,sched';
	show_backup_form({ new => 1 }, 'token');
	is_deeply(\@sections,
		  [ [ doms => 0 ], [ dest => 0 ], [ opts => 1 ],
		    [ sched => 1 ] ],
		  'configured sections open on the schedule form');
	# Manual backups share expansion preferences but have
	# no schedule controls.
	@sections = ();
	show_backup_form({ }, 'token');
	is_deeply(\@sections, [ [ doms => 0 ], [ dest => 0 ], [ opts => 1 ] ],
		  'manual backup omits the schedule section');
	show_restore_form({ }, 'token');
	show_restore_form({ inspection => 'a' x 32 }, 'token');
	my %topics = map { $_ => 1 } @topics;
	foreach my $topic (sort keys %topics) {
		ok(-f "$Bin/../help/$topic.html", "$topic has contextual help");
		}
	}
done_testing();
