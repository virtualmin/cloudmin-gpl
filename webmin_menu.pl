# Functions to generate the left menu

require 'server-manager-lib.pl';

# list_webmin_menu(&data, &in)
# Returns items for the Cloudmin left menu
sub list_webmin_menu
{
my ($data, $in) = @_;
my @rv;

# Preferred title
push(@rv, { 'type' => 'title',
	    'id' => 'title',
	    'icon' => '/'.$module_name.'/images/vm2.png',
	    'desc' => $text{'left_vm2'} });

# Reseller's logo
my (undef, $image, $link, $alt) = &get_provider_link();
if ($image) {
	my $html = "";
        $html .= "<a href='".&html_escape($link)."' target='_new'>" if ($link);
        $html .= "<center><img src='".&html_escape($image)."' ".
                 "alt='".&html_escape($alt)."'></center>";
        $html .= "</a><br>\n" if ($link);
	push(@rv, { 'type' => 'html',
		    'html' => $html });
	}

# Login and level
push(@rv, { 'type' => 'text',
	    'desc' => &text('left_login', $remote_user) });
push(@rv, { 'type' => 'text',
	    'desc' => $access{'owner'} ? $text{'left_owner'}
				       : $text{'left_master2'} });
push(@rv, { 'type' => 'hr' });

# Get and sort managed servers
my @servers = &list_available_managed_servers_sorted();
my @allservers = &list_managed_servers();
my ($server) = grep { $_->{'id'} eq $in->{'sid'} } @servers;
if (!$server && $data && $data->{'server'} ne '') {
	($server) = grep { $_->{'id'} eq $sects->{'server'} } @servers;
	}
$server ||= $servers[0];
my $sid = $server ? $server->{'id'} : undef;

if (@servers) {
	# Show managed servers
	my @slist = map { [ $_->{'id'}, ("&nbsp;&nbsp;" x $_->{'indent'}).
		        &shorten_hostname($_) ] } @servers;
	my $smenu = { 'type' => 'menu',
		      'cgi' => '',
		      'name' => 'sid',
		      'icon' => '/'.$module_name.'/images/ok.png',
		      'value' => $sid,
		      'menu' => \@slist };
	push(@rv, $smenu);
	}
else {
	# No servers!
	push(@rv, { 'type' => 'text',
		    'desc' => @allservers ? $text{'left_novm2access'}
					  : $text{'left_novm2'} });
	}

if ($server) {
	my $status = $server->{'status'};
        my $t = $server->{'manager'};

	# Show status of current server
	my $statusmsg = &describe_status($server, 1, 0);
	push(@rv, { 'type' => 'html',
		    'html' => &text('left_vm2status', $statusmsg) });

	# Get actions for this system
	my @actions = grep { $_ && keys(%$_) > 0 }
                           &get_server_actions($server);
	# XXX leftvm2_ text?

	# Work out action categories, and show those under each
	my @cats = sort { $a cmp $b } &unique(map { $_->{'cat'} } @actions);
	foreach my $c (@cats) {
                my @incat = grep { $_->{'cat'} eq $c } @actions;
		my @citems;
		foreach my $b (@incat) {
			my $url;
			if ($b->{'link'} =~ /\//) {
                                $url = $b->{'link'};
                                }
                        elsif ($b->{'link'}) {
                                $url = '/'.$module_name.'/'.$b->{'link'};
                                }
                        else {
                                $url = '/'.$module_name.'/save_serv.cgi?id='.
				       $server->{'id'}.'&'.$b->{'id'}.'=1';
				}
			push(@citems, { 'type' => 'item',
					'desc' => $b->{'title'} || $b->{'desc'},
					'link' => $url });
			}
		if ($c) {
			push(@rv, { 'type' => 'cat',
				    'id' => 'cat_'.$c,
				    'desc' => $text{'cat_'.$c} ||
					      $incat[0]->{'catname'},
				    'members' => \@citems });
			}
		else {
			push(@rv, @citems);
			}
		}
	}

return @rv;
}

sub shorten_hostname
{
my ($server) = @_;
return $server->{'short_host'} if ($server->{'short_host'});
my $show = $server->{'host'};
my $rv;
my $name_max = 20;
if (length($show) > $name_max) {
	# Show first and last max/2 chars, with ... between
	my $s = int($name_max / 2);
        $rv = substr($show, 0, $s)."...".substr($show, -$s);
        }
else {
        $rv = $show;
        }
$rv =~ s/ /&nbsp;/g;
return $rv;
}

1;
