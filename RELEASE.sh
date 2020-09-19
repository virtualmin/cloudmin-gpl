 #!/bin/sh

mode=$1
ver=$2
oldver=$3
if [ "$mode" = "" -o "$ver" = "" -o "$oldver" = "" ]; then
	echo "usage: RELEASE.sh cloudmin|webmin|theme version old-version"
	exit 1
fi
cd /usr/local/webadmin

if [ "$mode" = "cloudmin" ]; then
        ssh root@fudu "cd /usr/local/webadmin ; ./makemodulerpm.pl --sign --dir server-manager server-manager-kvm"
        scp /root/rpmbuild/RPMS/noarch/wbm-server-manager-$ver.kvm-1.noarch.rpm cloudmin@cloudmin.virtualmin.com:public_html/kvm/universal/
        ssh cloudmin@cloudmin.virtualmin.com "cd public_html/kvm/universal ; createrepo -s sha ."

	./create-module.pl --dir server-manager --sign virtualmin/server-manager-$ver.kvm.wbm.gz server-manager-kvm
	scp virtualmin/server-manager-$ver.kvm.wbm.gz* cloudmin@cloudmin.virtualmin.com:public_html/kvm/wbm/
        ssh cloudmin@cloudmin.virtualmin.com "sed -e 's/$oldver/$ver/' -i public_html/kvm/wbm/updates.txt"

	ssh -4 builder "cd /usr/local/webadmin ; ./makemoduledeb.pl --dir server-manager server-manager-kvm ; cp /tmp/webmin-server-manager_${ver}.kvm_all.deb /usr/local/download/deb/cloudmin-kvm/binary"
	ssh -4 builder "cd /usr/local/download/deb/cloudmin-kvm ; ./make-repo.sh"
	( cd /usr/local/download/deb/cloudmin-kvm ; rsync --rsh=ssh -r -v * cloudmin@cloudmin.virtualmin.com:public_html/kvm/debian/ )
fi

if [ "$mode" = "webmin" ]; then
	scp /usr/local/webadmin/rpm/webmin-$ver-1.noarch.rpm cloudmin@cloudmin.virtualmin.com:public_html/kvm/universal/
	ssh cloudmin@cloudmin.virtualmin.com "cd public_html/kvm/universal ; createrepo -s sha ."

	scp /usr/local/webadmin/tarballs/webmin-$ver.tar.gz cloudmin@cloudmin.virtualmin.com:public_html/kvm/wbm/
	ssh cloudmin@cloudmin.virtualmin.com "cd public_html/kvm/wbm ; rm webmin-current.tar.gz ; ln -s webmin-$ver.tar.gz webmin-current.tar.gz ; echo $ver > webmin-version"

	cp /usr/local/webadmin/deb/webmin_${ver}_all.deb /usr/local/download/deb/cloudmin-kvm/binary
	ssh -4 builder "cd /usr/local/download/deb/cloudmin-kvm ; ./make-repo.sh"
        ( cd /usr/local/download/deb/cloudmin-kvm ; rsync --rsh=ssh -r -v * cloudmin@cloudmin.virtualmin.com:public_html/kvm/debian/ )
fi

if [ "$mode" = "theme" ]; then
        scp /root/rpmbuild/RPMS/noarch/wbt-virtual-server-theme-$ver-1.noarch.rpm cloudmin@cloudmin.virtualmin.com:public_html/kvm/universal/
        ssh cloudmin@cloudmin.virtualmin.com "cd public_html/kvm/universal ; createrepo -s sha ."

        scp /usr/local/webadmin/virtualmin/virtual-server-theme-$ver.wbt.gz* cloudmin@cloudmin.virtualmin.com:public_html/kvm/wbm/
        ssh cloudmin@cloudmin.virtualmin.com "sed -e 's/$oldver/$ver/' -i public_html/kvm/wbm/updates.txt"

        ssh -4 builder "cp /tmp/webmin-virtual-server-theme_${ver}_all.deb /usr/local/download/deb/cloudmin-kvm/binary"
        ssh -4 builder "cd /usr/local/download/deb/cloudmin-kvm ; ./make-repo.sh"
        ( cd /usr/local/download/deb/cloudmin-kvm ; rsync --rsh=ssh -r -v * cloudmin@cloudmin.virtualmin.com:public_html/kvm/debian/ )
fi

if [ "$mode" = "security" ]; then
        ssh root@fudu "cd /usr/local/webadmin ; ./makemodulerpm.pl --sign --epoch 2 security-updates"
        scp /root/rpmbuild/RPMS/noarch/wbm-security-updates-$ver-1.noarch.rpm cloudmin@cloudmin.virtualmin.com:public_html/kvm/universal/
        ssh cloudmin@cloudmin.virtualmin.com "cd public_html/kvm/universal ; createrepo -s sha ."

        ./create-module.pl --sign virtualmin/security-updates-$ver.wbm.gz security-updates
        scp virtualmin/security-updates-$ver.wbm.gz* cloudmin@cloudmin.virtualmin.com:public_html/kvm/wbm/
        ssh cloudmin@cloudmin.virtualmin.com "sed -e 's/$oldver/$ver/g' -i public_html/kvm/wbm/updates.txt"

        ssh -4 builder "cd /usr/local/webadmin ; ./makemoduledeb.pl security-updates ; cp /tmp/webmin-security-updates_${ver}_all.deb /usr/local/download/deb/cloudmin-kvm/binary"
        ssh -4 builder "cd /usr/local/download/deb/cloudmin-kvm ; ./make-repo.sh"
        ( cd /usr/local/download/deb/cloudmin-kvm ; rsync --rsh=ssh -r -v * cloudmin@cloudmin.virtualmin.com:public_html/kvm/debian/ )
fi
