# Functions for Kvm

sub type_kvm_desc
{
return $text{'kvm_typedesc'};
}

# type_kvm_parent(&server, [&all-servers])
# Returns the parent system that hosts this kvm
sub type_kvm_parent
{
my ($server, $servers) = @_;
if ($servers) {
	my ($vhost) = grep { $_->{'id'} == $server->{'kvm_on'} } @$servers;
	return $vhost;
	}
else {
	return &get_managed_server($server->{'kvm_on'});
	}
}

sub type_kvm_must_image
{
return 1;			# Xen instances always come from an image
}

sub type_kvm_is_virtual
{
return 1;
}

sub type_kvm_can_transfer
{
my ($server) = @_;
return $server->{'kvm_mount'} && !$server->{'nohost'} ||	# Via host
       $server->{'status'} eq 'nowebmin' ||	# Can transfer if SSH is up
       $server->{'status'} eq 'downwebmin' ||
       $server->{'status'} eq 'nowebminlogin' ||
       $server->{'status'} eq 'novirt' ||
       $server->{'status'} eq 'virt';
}

# Can change the password if totally down, or can SSH in
sub type_kvm_can_password
{
my ($server) = @_;
return $server->{'status'} ne 'nohost' &&
       $server->{'status'} ne 'nossh' &&
       $server->{'status'} ne 'nosshlogin';
}

# Can reset, if the host is up
sub type_kvm_can_reset
{
my ($server) = @_;
return $server->{'status'} ne 'nohost';
}

# Returns links for creating and adding kvms (if this system supports
# them, or remote systems do)
sub type_kvm_create_links
{
my @vhosts = grep { $_->{'kvm_host'} } &list_managed_servers();
my @rv;
if (@vhosts) {
	push(@rv, { 'create' => 0,
		    'desc' => $text{'kvm_addlink'} });
	my @images = &list_server_images('kvm');
	if (@images) {
		push(@rv, { 'create' => 1,
			    'desc' => $text{'kvm_createlink'} });
		}
	}
return @rv;
}

# Returns a link to the page list kvm-capable systems
sub type_kvm_global_links
{
return ( { 'link' => 'list_kvms.cgi',
	   'icon' => 'images/kvms.gif',
	   'title' => $text{'kvms_title'},
	   'cat' => 'hosts' } );
}

# can_host_kvm(&server)
# Returns 1 if some server is of a type that we can do KVM hosting on
sub can_host_kvm
{
my ($server) = @_;
return $server->{'manager'} eq 'this' || $server->{'manager'} eq 'real';
}

# type_kvm_add_form()
# Returns inputs for adding an existing KVM instance. This is just a matter of
# selecting the host and the server.
sub type_kvm_add_form
{
my $rv;

# Hosting system
my @vhosts = grep { $_->{'kvm_host'} } &list_managed_servers();
$rv .= &ui_table_row($text{'add_kvmhost'},
		&ui_select("kvm_on", $vhosts[0]->{'id'},
			[ map { [ $_->{'id'}, $_->{'host'} ] } @vhosts ]));

if (@vhosts == 1) {
	# Can just show a drop-down of existing kvm instances, except those we
	# are already hosting)
	my $instances = &list_kvm_instances($vhosts[0]);
	my %already = map { $_->{'kvm_filesystem'}, $_ }
			     &list_managed_servers();
	$rv .= &ui_table_row($text{'add_kvmpid'},
	    &ui_select("kvm_pid", undef,
		[ map { [ $_->{'pid'}, $_->{'cmd'} ] }
		      grep { !$already{$_->{'filesystem'}} } @$instances] ));
	}
else {
	# Need to show kvm name field, with popup
	$rv .= &ui_table_row($text{'add_kvmpid'},
	     &ui_textbox("kvm_pid", undef, 20)." ".
	     &kvm_instance_chooser_button("kvm_pid", "kvm_on"));
	}

return $rv;
}

# type_kvm_add_parse(&server, &in)
# Parse inputs from type_kvm_add_form
sub type_kvm_add_parse
{
my ($server, $in) = @_;

# Save Xen host
$server->{'kvm_on'} = $in->{'kvm_on'};
my $vhost = &type_kvm_parent($server);

# Check and save KVM instance
my $instances = &list_kvm_instances($vhost);
$in->{'kvm_pid'} || &error($text{'add_ekvminstance'});
my ($got) = grep { $_->{'pid'} eq $in->{'kvm_pid'} } @$instances;
$got || &error(&text('add_ekvminstance2', $vhost->{'host'}));
$server->{'kvm'} = $in->{'kvm_pid'};

# Save KVM root disk
$server->{'kvm_filesystem'} = $got->{'filesystem'};
}


# check_kvm_host_software(&server)
# Checks if some system has the Xen software installed, and the kernel
# patch needed to use it.
sub check_kvm_host_software
{
my ($server) = @_;

# Check if linux
my ($out, $ex, $err) = &execute_command_on_server($server, "uname");
return $text{'kvm_elinux'} if ($out !~ /linux/i);

# Check commands
my $full = &has_command_on_server($server, "qemu-kvm");
if (!$full) {
	$full = &has_command_on_server($server, "kvm");
	}
return &text('kvm_ewhich2', "<tt>qemu-kvm</tt>", "<tt>kvm</tt>") if (!$full);
&has_command_on_server($server, "qemu-img") ||
	return &text('kvm_ewhich', "<tt>qemu-img</tt>");

# Check CPU
my ($out, $ex, $err) = &execute_command_on_server($server,
	"cat /proc/cpuinfo");
if ($out !~ /flags\s*:\s*.*(vmx|svm)/) {
	return $text{'kvm_ecpu'};
	}

# Check kernel
my ($out, $ex, $err) = &execute_command_on_server($server,
				"test -e /dev/kvm");
return $text{'kvm_ekernel'} if ($ex);

return undef;
}

# type_kvm_open_shell(&server)
# Runs SSH to connect to a remote system. Returns an error message
# (or undef if OK), and a file handle.
sub type_kvm_open_shell
{
my ($server) = @_;
my ($out, $ex, $err, $status, $fh, $fpid) =
	&execute_command_on_server($server, "/bin/sh", 0, 1);
return $err ? ($err, undef) : $ex ? ($out, undef) : (undef, $fh);
}

# type_kvm_get_dns_name(&server)
# Returns a system's DNS name and zone name
sub type_kvm_get_dns_name
{
my $vhost = &get_parent_server($server);
return ( $server->{'kvm_dns'}, $vhost->{'kvm_zone'} );
}

# list_kvm_host_bridges(&vhost)
# Returns the list of names of bridges on some Xen host system. Tries brctl 
# show first, then ifconfig
sub list_kvm_host_bridges
{
my ($vhost) = @_;
my @rv;
my ($out, $ex, $err) = &execute_command_on_server($vhost, "brctl show");
if (!$ex && !$err) {
	foreach my $l (split(/\r?\n/, $out)) {
		if ($l !~ /^bridge\s+name/ && $l =~ /^(\S+)/) {
			push(@rv, $1);
			}
		}
	}
if (!@rv) {
	my $ifaces = &list_active_server_interfaces($vhost);
	if (ref($ifaces)) {
		@rv = map { $_->{'fullname'} }
			  grep { $_->{'fullname'} =~ /^br/ &&
				 $_->{'virtual'} eq '' } @$ifaces;
		}
	}
return @rv;
}

# list_kvm_instances(&vhost)
# Returns a list of running KVM processes as an array ref, or an error message
sub list_kvm_instances
{
my ($vhost) = @_;
my $procs = &list_processes_on_server($vhost);
return $procs if (!ref($procs));
my @rv;
foreach my $p (@$procs) {
	if ($p->{'args'} =~ /^(\S+\/|)(qemu-kvm|kvm)\s+(.*)/) {
		# Found a candidate .. parse the args
		my ($cmd, $args) = ($2, $3);
		my @w = &split_quoted_string($args);
		my $ah = { };
		my $kvm = { 'pid' => $p->{'pid'},
			    'args' => $ah,
			    'cmd' => $p->{'args'} };
		my $lastarg;
		while(@w) {
			my $a = shift(@w);
			if ($a =~ /^\-+(\S+)$/) {
				# Start of a new arg
				$lastarg = $1;
				if ($ah->{$lastarg}) {
					# Already seen .. convert to array
					$ah->{$lastarg} = [ $ah->{$lastarg} ];
					}
				if (ref($ah->{$lastarg})) {
					# Add to array
					push(@{$ah->{$lastarg}}, "");
					}
				else {
					# Start of a single value
					$ah->{$lastarg} = "";
					}
				}
			else {
				# Value for an arg
				if (ref($ah->{$lastarg})) {
					# Add to end of list
					my $v = $ah->{$lastarg};
					$v[@$v-1] .= " " if ($v[@$v-1]);
					$v[@$v-1] .= $a;
					}
				else {
					# Add to single value
					$ah->{$lastarg} .= " "
						if ($ah->{$lastarg});
					$ah->{$lastarg} .= $a;
					}
				}
			}

		# Work out main drive
		if ($ah->{'hda'}) {
			$kvm->{'filesystem'} = $ah->{'hda'};
			}
		elsif ($ah->{'drive'}) {
			# Lowest-index disk set with -drive flag
			my @d = ref($ah->{'drive'}) ? @{$ah->{'drive'}}
						    : ( $ah->{'drive'} );
			my $lowindex = 9999;
			foreach my $d (@d) {
				my %dinfo = map { split(/=/, $_) }
						split(/,/, $d);
				if ($dinfo{'file'} &&
				    $dinfo{'media'} ne 'cdrom' &&
				    $dinfo{'index'} < $lowindex) {
					$kvm->{'filesystem'} = $dinfo{'file'};
					$lowindex = $dinfo{'index'};
					}
				}
			}

		if ($kvm->{'filesystem'} && $kvm->{'filesystem'} !~ /^\//) {
			# Relative path used .. normalize
			my $cwd = &get_kvm_process_dir($vhost, $p->{'pid'});
			if ($cwd) {
				$kvm->{'filesystem'} =
					$cwd."/".$kvm->{'filesystem'};
				}
			}
		push(@rv, $kvm);
		}
	}
return \@rv;
}

# get_kvm_process_dir(&vhost, pid)
# Find the curent directory of some kvm process, useful for resolving relative
# disk paths.
sub get_kvm_process_dir
{
my ($vhost, $pid) = @_;
my ($out, $ex, $err) = &execute_command_on_server($vhost,
				"readlink /proc/$pid/cwd");
if (!$ex && !$err) {
	$out =~ s/\r|\n//g;
	return $out;
	}
return undef;
}

# kvm_instance_chooser_button(instance-field, host-field)
# Returns HTML for a popup window for selecting a running KVM instance
sub kvm_instance_chooser_button
{
my ($ifield, $hfield) = @_;
return "<input type=button onClick='ifield = form.$ifield; chooser = window.open(\"kvm_chooser.cgi?host=\"+escape(form.$hfield.value), \"chooser\", \"toolbar=no,menubar=no,scrollbar=no,width=600,height=300\"); chooser.ifield = ifield; window.ifield = ifield' value=\"...\">\n";
}

1;

