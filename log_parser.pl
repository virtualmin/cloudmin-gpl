# Describe Cloudmin actions through Webmin's standard action log.
use strict;
use warnings;
use WebminCore;
use File::Basename ();
require(File::Basename::dirname(__FILE__).'/cloudmin-disk-labels.pl');
our %text;
init_config();

# parse_webmin_log(user, script, action, type, object, params, [long]) Formats
# stored identities and outcomes without loading guests or job stores.

sub parse_webmin_log
{
my ($user, $script, $action, $type, $object, $params, $long) = @_;
# Webmin supplies its own localized description for module configuration.
return undef if ($action eq '_config_');
$params ||= { };
my $name = ui_tag('tt', html_escape($params->{'name'} || $object || ''));
# Display generated disk names consistently while preserving raw audit details.
$name = ui_tag('tt', html_escape(storage_volume_label({
	name => $params->{'name'} || $object })))
	if ($type eq 'volume');
my $key = 'log_'.$type.'_'.$action;
if (($type eq 'vm' || $type eq 'pool') && $action eq 'autostart') {
	# The saved target value distinguishes enabling boot from disabling it.
	$key .= $params->{'enabled'} ? '_on' : '_off';
	}
elsif ($type eq 'image') {
	# Failed uploads and deletions must not read as successful changes.
	$key .= '_cancelled' if (($params->{'state'} || '') eq 'deleted' &&
				 ($action eq 'import' || $action eq 'upload'));
	$key .= '_failed' if ($key !~ /_cancelled$/ &&
			      ($params->{'error'} || ($params->{'state'} || '') eq 'failed'));
	}
elsif ($type eq 'catalogue' || $type eq 'template' || $type eq 'plan') {
	# Stored names survive deletion; entries without names fall back to IDs.
	my @names = $params->{'names'}
		? split(/\0/, $params->{'names'})
		: $params->{'name'}
			? ($params->{'name'})
			: split(/,/, $object || '');
	$name = join(', ', map { ui_tag('tt', html_escape($_)) } @names);
	}
# Unknown action types still need a readable, escaped log description.
return html_escape(join(' ', grep { defined } $action, $type, $object))
	if (!$text{$key});
my $description = text($key, $name);
if ($long) {
	# Keep technical identifiers in details, with
	# friendly names in the list.
	$description .= ' '.
			text('log_object', ui_tag('tt', html_escape($object)))
		if (defined($object) && length($object) &&
		    $type ne 'catalogue');
	# Preserve the recorded failure alongside the action description.
	$description .= ' '.text('log_error', html_escape($params->{'error'}))
		if ($params->{'error'});
	# Failed rollback needs attention even after the job has ended.
	$description .= ' '.$text{'log_cleanup'}
		if ($params->{'cleanup_pending'});
	}
return $description;
}

1;
