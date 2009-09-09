# log_parser.pl
# Functions for parsing this module's logs

do 'server-manager-lib.pl';

# parse_webmin_log(user, script, action, type, object, &params)
# Converts logged information from this module into human-readable form
sub parse_webmin_log
{
my ($user, $script, $action, $type, $object, $p, $long) = @_;
if ($type eq "server") {
	# Operation on one server
	return &text('log_'.$action.'_server', $object,
		     &html_escape(&un_urlize($p->{'cmd'})));
	}
elsif ($type eq "servers") {
	# Operation on multiple servers
	my @hosts = split(/\0/, $p->{'hosts'});
	if ($object == 1) {
		return &text('log_'.$action.'_server', $hosts[0]);
		}
	return &text('log_'.$action.'_servers'.($long ? '_l' : ''),
		     $object, join(" ", @hosts),
		     &html_escape(&un_urlize($p->{'cmd'})));
	}
elsif ($type eq "file") {
	# File upload / download
	return &text('log_'.$action.'_file', $object,
		     &html_escape($p->{'file'}),
		     &html_escape($p->{'dest'}));
	}
elsif ($type eq "disk") {
	# Disk operation
	return &text('log_'.$action.'_disk', $object,
		     &html_escape($p->{'real'}));
	}
elsif ($type eq "disks") {
	# Multi-disk operation
	my @reals = split(/\0/, $p->{'real'});
	return &text('log_'.$action.'_disks', $object,
		     &html_escape(join(" ", @reals)));
	}
elsif ($type eq "iface") {
	# Network interface operation
	return &text('log_'.$action.'_iface', $object,
		     $p->{'address'});
	}
elsif ($type eq "key") {
	# SSH key
	return &text('log_'.$action.'_key',
		     "<i>".&html_escape($p->{'desc'})."</i>");
	}
elsif ($type eq "keys") {
	# Multiple SSH keys
	return &text('log_'.$action.'_keys', $object);
	}
elsif ($type eq "image") {
	# System image
	return &text('log_'.$action.'_image', &html_escape($object));
	}
elsif ($type eq "images") {
	# Multiple system images
	return &text('log_'.$action.'_images', $object);
	}
elsif ($type eq "owner") {
	# One system owner
	return &text('log_'.$action.'_owner', &html_escape($object));
	}
elsif ($type eq "owners") {
	# Multiple system owners
	return &text('log_'.$action.'_owners', $object);
	}
elsif ($type eq "plan") {
	# One account plan
	return &text('log_'.$action.'_plan', &html_escape($p->{'desc'}));
	}
elsif ($type eq "plans") {
	# Multiple account plans
	return &text('log_'.$action.'_plans', $object);
	}
elsif ($action eq "cmd" || $action eq "remote") {
	# Local or remote API call
	return &text('log_'.$action.($long ? '_l' : ''),
		     "<tt>$type</tt>",
		     "<tt>".&un_urlize($p->{'argv'})."</tt>");
	}
else {
	return $text{'log_'.$action};
	}
return undef;
}

