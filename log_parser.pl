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

