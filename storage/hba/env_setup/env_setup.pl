#!/usr/bin/perl -w
# Copyright (c) 2006 Red Hat, Inc. All rights reserved. This copyrighted
# material is made available to anyone wishing to use, modify, copy, or
# redistribute it subject to the terms and conditions of the GNU General
# Public License v.2.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
# for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301,
# USA.
# # Author: Gris Ge   <fge@redhat.com>
use strict;
use FindBin;

BEGIN { $| = 1 }

my $SCRIPT_ROOT_PATH = $FindBin::Bin;

my $STQE_HOST_FILE = "$SCRIPT_ROOT_PATH/stqe_hosts";
my $BASE_HTTP_URL  = "http://pnate-control-01.lab.bos.redhat.com/stqe";
my $BASE_DOWNLOAD_URL = "http://download-node-02.eng.bos.redhat.com/brewroot/packages/";
if (`hostname` =~ m/pek2.redhat.com/) {
   $BASE_DOWNLOAD_URL = "http://download.eng.pek2.redhat.com/brewroot/packages/";
}

# Use dnf if present, otherwise use yum
my $package_manager = "dnf";
if ( system("$package_manager >/dev/null 2>&1") != 0 ) {
    $package_manager = "yum";
}


my $py_name;
# Using python34 on RHEL-6
if ( rhel_dist() == 6 ) {
    my $url = "http://dl.fedoraproject.org/pub/epel/6/x86_64/epel-release-6-8.noarch.rpm";
    system("$package_manager install -y $url; $package_manager install -y python34 --enablerepo=epel");
    system("yum-config-manager --disable epel >/dev/null 2>&1");
}
# Using python27 on RHEL7
elsif ( rhel_dist() == 7 ) {
    $py_name = "python";
}

# Using python3/python36 on anything else
if ( system("python3 -V >/dev/null 2>&1") == 0 ) {
    $py_name = "python3";
}
else {
    # Assuming it is RHEL8 and python3 module was not installed properly
    if ( system("$package_manager install -y python36") == 0 ) {
        $py_name = "python3";
    }
    else {
        print("WARN: Could not install python3!\n");
    }
}
# Checking if python is working properly
system("$py_name -V");


sub enable_st_repo {
    my $rhel_dist = rhel_dist();
    my $fedora_dist = fedora_dist();
    if (!$rhel_dist && !$fedora_dist) {
        print "FAIL: Storage-QE repo only supports RHEL or Fedora distros\n";
        return 0;
    }

    my $rhel_stqe_repo = "${BASE_HTTP_URL}/rpm_repo/st_qe.repo";
    my $command = "wget $rhel_stqe_repo -O /etc/yum.repos.d/st_qe.repo";
    if ($fedora_dist) {
        my $fedora_stqe_repo = "${BASE_HTTP_URL}/rpm_repo/fedora.repo";
        $command = "wget $fedora_stqe_repo -O /etc/yum.repos.d/st_qe.repo";
    }
    system($command);
    my $rt = $?;

    if ($rhel_dist) {
        my $cmd = "perl -np -i -e 's/\\\$releasever/rhel$rhel_dist/g' /etc/yum.repos.d/st_qe.repo";
        system("$cmd");
    }

    return 1 if $rt eq 0;
    return undef;
}

sub install_beaker_client {
    my $repo_url = "http://download.lab.bos.redhat.com/beakerrepos/beaker-client-RedHatEnterpriseLinux.repo";
    if (fedora_dist()) {
        $repo_url = "http://download-node-02.eng.bos.redhat.com/beakerrepos/beaker-client-Fedora.repo"
    }
    my $command = "wget $repo_url "
      . '-O /etc/yum.repos.d/beaker-client.repo';
    system($command);
    my $rt = $?;
    return undef if $rt ne 0;

    $command = "$package_manager install -y beaker-client";
    system($command);

    my $client_conf = "HUB_URL = \"https://beaker.engineering.redhat.com\"";
    open(my $fh, '>', '/etc/beaker/client.conf');
    print $fh $client_conf;
    close $fh;
    $rt = $?;
    return 1 if $rt eq 0;

    return undef;
}

sub install_rpms {
    my $rpms = "strace sysfsutils iotop "    # system tools.
      . "'perl(IPC::Cmd)' "                  # for ST::Cmd
      . "'perl(IPC::Open3)' "                # for ST::Cmd
      . "'perl(Time::HiRes)' "               # for ST::Misc
      #. "perl-LibSAN perl-LibSAN-redhat "    # storage-qe rpms
      . "setroubleshoot-server "             # detailed selinux info in
                                             # /var/log/messages
      . "redhat-lsb-core "                   # for lsb_release command
      . "perl-YAML-Tiny "                    # for ST::iSCSI::Config
      . "perl-Data-Dumper "                  # for ST::Utils
      . "abrt abrt-cli "
      . "lvm2 "
      . "device-mapper-multipath fcoe-utils "
      . "git "
      . "lrzsz sos sg3_utils screen net-tools ";

    #workaround as the sg3_utils from stqe repo does not deal
    #with this dependency
    $rpms .= "sg3_utils-libs ";
    my $command = "";
    my $fedora_dist = fedora_dist();

    $command = "$package_manager install -y --skip-broken " . $rpms;
    if ($fedora_dist) {
        $command = "$package_manager install -y " . $rpms;
    }
    print "$command\n";
    system($command);
    my $rt         = $?;
    my $dt_command = "$package_manager install -y dt";
    $dt_command = "$package_manager install -y dt.ia64"
      if ( rpm_arch() eq 'ia64' );
    print "$dt_command\n";
    system($dt_command);
    $rt += $?;

    my $rpm_arch = rpm_arch();

    if ( grep { $rpm_arch eq $_ } qw/i386 i686 x86_64/ ) {

        my $sa_rpm_url   = "${BASE_HTTP_URL}/Storage_Array_Mgr_RPM";
        my $emc_navi_rpm = sprintf "%s/EMC/NaviCLI-Linux.%s.rpm",
          $sa_rpm_url, $rpm_arch;
        my $emc_navi_cmd = "$package_manager install -y $emc_navi_rpm";
        print "$emc_navi_cmd\n";
        system($emc_navi_cmd);
        $rt += $?;
    }

    #Set abrtd to save dump even if package is not signed
    $command = "sed -i 's/OpenGPGCheck = yes/OpenGPGCheck = no/' "
       . "/etc/abrt/abrt-action-save-package-data.conf";
    print "$command\n";
    system($command);

    return 1 if $rt eq 0;
    return undef;
}

sub link_2_INC {
    my $inc_path_rhel5 = '/usr/lib/perl5/vendor_perl';
    my $inc_path_rhel6 = '/usr/share/perl5';
    my $inc_path_rhel7 = $inc_path_rhel6;
    my @commands;

    my $inc_path  = $inc_path_rhel6;    # this line is for fedora
    my $rhel_dist = rhel_dist();
    #RHEL uses different path for Perl depending on release
    if ($rhel_dist) {
        $inc_path = $inc_path_rhel7 if $rhel_dist == 7;
        $inc_path = $inc_path_rhel6 if $rhel_dist == 6;
        $inc_path = $inc_path_rhel5 if $rhel_dist == 5;
    }
    return undef unless defined $inc_path;

    push @commands,
        'ln -s '
      . '/mnt/tests/kernel/storage/include/perl_modules '
      . $inc_path . '/ST';

    push @commands,
        'ln -s '
      . '/mnt/tests/kernel/storage/fcoe/include/perl_modules '
      . $inc_path
      . '/ST/FCoE';

    push @commands,
        'ln -s '
      . '/mnt/tests/kernel/storage/iscsi/modules '
      . $inc_path
      . '/ST/iSCSI';

    push @commands,
        'ln -s '
      . '/mnt/tests/kernel/storage/multipath/include/perl_modules '
      . $inc_path
      . '/ST/MP';

    push @commands,
        'ln -s '
      . '/mnt/tests/kernel/storage/lsm/modules '
      . $inc_path
      . '/ST/LSM';

    foreach my $command (@commands) {
        print "$command\n";
        system($command);
    }
}

sub install_pip {
    my $get_pip_url = "https://bootstrap.pypa.io/get-pip.py";
    my $command = "curl --silent --show-error --retry 5 $get_pip_url -o get-pip.py";

    print "$command\n";
    system($command);

    $command = "$py_name get-pip.py setuptools wheel";
    print "$command\n";
    if (system($command) == 0) {
        # pip installed  successfully, setuptools and wheel updated
        return;
    }
}

sub pip_upgrade($) {
    my $package = shift;
    my $command = "pip install $package --upgrade";
        print "$command\n";
        if (system($command) == 0) {
            # upgrade successful
            return;
        }
    }

sub install_perl_libsan {
    if ( rhel_dist() == 8 ) {
        my $perl_expect_rpm = 'http://download.eng.brq.redhat.com/brewroot/packages/perl-Expect/1.35/3.el8+5/noarch/perl-Expect-1.35-3.el8+5.noarch.rpm';
        my $dnf_command = "$package_manager install -y perl perl-YAML-Tiny $perl_expect_rpm perl-IO-stringy --enablerepo RHEL-8-BuildRoot";
        print "$dnf_command\n";
        system($dnf_command);
    }
    my $command = "$package_manager install -y perl-LibSAN";
    print "$command\n";
    if (system($command) == 0) {
        #installed package successfully
        return;
    }

    #Could not install the package, try to build from source
    my $git_url = "git://git.app.eng.bos.redhat.com/perl-libsan";
    $command = "git clone $git_url";
    print "$command\n";
    if (system($command) != 0) {
        print "FAIL: Could not clone $git_url\n";
        return;
    }

    $command = "cd perl-libsan/; perl Makefile.PL; make; make install; cd -";
    print "$command\n";
    if (system($command) != 0) {
        print "FAIL: Could build perl-libsan\n";
        return;
    }

    return;
}

sub install_python_modules {
    my $extra = "";
    my $pydevel = $py_name;
    if ( $py_name eq "python3" ) {
        # Install with empty prefix with python3
        $extra = "--prefix=";
        # Do not use empty prefix on RHEL-6
        if ( rhel_dist() == 6 ) {
            $extra = "";
        }
    }

    # therefore installing the package here.
    my $command = "$package_manager install -y augeas-libs $py_name-netifaces";
    print "$command\n";
    system($command);

    #libsan should install paramiko module
    #$command = "$package_manager install -y python-paramiko";
    #if (system($command) != 0) {
    #    #need to install pycrypto first
    #    #Not needed for paramiko-2.0
    #    #my $url_dep = 'http://pnate-control-01.lab.bos.redhat.com/stqe/'
    #    #    . 'python_modules/pycrypto-2.6.1.tar.gz';
    #    #$command = "wget $url_dep -O ~/pycrypto-2.6.1.tar.gz";
    #    #print "$command\n";
    #    #system($command);
    #
    #    #$command = "cd ~/; tar xvf pycrypto-2.6.1.tar.gz";
    #    #print "$command\n";
    #    #system($command);
    #
    #
    #    my $url_dep = 'http://pnate-control-01.lab.bos.redhat.com/stqe/'
    #    #    . 'python_modules/paramiko-1.16.0.tar.gz';
    #        . 'python_modules/paramiko-2.0.2.tar.gz';
    #    #$command = "wget $url_dep -O ~/paramiko-1.16.0.tar.gz";
    #    $command = "wget $url_dep -O ~/paramiko-2.0.2.tar.gz";
    #    print "$command\n";
    #    system($command);
    #
    #    $command = "cd ~/; tar xvf paramiko-2.0.2.tar.gz";
    #    print "$command\n";
    #    system($command);
    #
    #    #Disabling rhsmcertd to avoid AVC error when package is being installed
    #    $command = "service rhsmcertd stop";
    #    print "$command\n";
    #    system($command);
    #
    #    $command = "cd ~/paramiko-2.0.2; python setup.py install";
    #    print "$command\n";
    #    system($command);
    #    #Some python files do not have right labels, fix them
    #    $command = "restorecon -R -v /usr/lib/python*/";
    #    print "$command\n";
    #    system($command);
    #
    #    #Enabling rhsmcertd again
    #    $command = "service rhsmcertd start";
    #    print "$command\n";
    #    system($command);
    #}

    $command = "service rhsmcertd stop";
    #Disabling rhsmcertd to avoid AVC error when package is being installed
    print "$command\n";
    system($command);

    print "INFO: Installing python-libsan\n";
    my $libsan_repo = "https://gitlab.com/rh-kernel-stqe/python-libsan.git";
    my $libsan_dir = "/root/python-libsan";
    $command = "git clone $libsan_repo $libsan_dir";
    print "$command\n";
    my $rt = system($command);
    my $count = 0;
    while (($rt != 0) && ($count < 3)) {
        print "INFO: Trying to clone python-libsan again $count/3\n";
        sleep 60;
        $count += 1;
        system("rm -rf $libsan_dir");
        $rt = system($command);
    }
    if ( -d $libsan_dir ){
        $command = "cd $libsan_dir; $py_name setup.py install $extra; cd -";
        print "$command\n";
        system($command);
        print "INFO: python-libsan commit ID:\n";
        $command = "cd $libsan_dir; git rev-parse HEAD; cd -";
        print "$command\n";
        system($command);
    }
    else {
        my $command = "pip install libsan";
        print "$command\n";
        if (system($command) == 0) {
		#libsan installed  successfully
            return;
        }
    }

    print "INFO: Installing storage-qe python modules\n";
    # my $stqe_repo = "git://git.app.eng.bos.redhat.com/python-stqe.git";
    my $stqe_repo = "https://gitlab.cee.redhat.com/stqe/python-stqe.git";
    #$command = "cd ~; git clone $stqe_repo; cd -";
    $command = "git clone $stqe_repo ~/python-stqe";
    print "$command\n";
    $rt = system($command);
    $count = 0;
    while (($rt != 0) && ($count < 5)) {
        print "INFO: Trying to clone python-stqe again $count/5\n";
        sleep 60;
        $count += 1;
        system("rm -rf ~/python-stqe");
        $rt = system($command);
    }
    $command = "cd ~/python-stqe; $py_name setup.py install --force --quiet $extra; cd -";
    print "$command\n";
    system($command);
    print "INFO: python-stqe commit ID:\n";
    $command = "cd ~/python-stqe; git rev-parse HEAD; cd -";
    print "$command\n";
    system($command);

    #Some python files do not have right labels, fix them
    $command = "restorecon -R -v /usr/lib/python*/";
    print "$command\n";
    system($command);

    #Enabling rhsmcertd again
    $command = "service rhsmcertd start";
    print "$command\n";
    system($command);
}

#--------------------------------------------------------------------------#
# enable_mpath ()
# Usage
#   enable_mpath()
# Purpose
#   Enable multipath and make sure multipathd is on boot.
# Parameter
#   N/A
# Returns
#   1
#       or
#   undef
# Exceptions
#   N/A
# See Also
#   N/A
#--------------------------------------------------------------------------#
sub enable_mpath {
    if ( $ENV{NO_MP} ) {
        print "INFO: NO_MP defined, skiping install "
          . "device-mapper-multipath\n";
        return 1;
    }
    my $rhel_dist = rhel_dist();
    my $fedora_dist = fedora_dist();
    if ( $rhel_dist && $rhel_dist <= 5 ) {
        print "INFO: Will not enable device-mapper-multipath for RHEL 5 "
          . "and previous release\n";
        return 1;
    }
##   Multipath config file is now being installed from python-stqe lib
#    my $url                 = "${BASE_HTTP_URL}/rpm_repo/multipath.conf";
#    my $multipath_conf      = `curl $url`;
#    my $multipath_conf_path = '/etc/multipath.conf';
#    open my $fd_mp_conf, ">", $multipath_conf_path;
#    if ($fd_mp_conf) {
#        print $fd_mp_conf $multipath_conf;
#        close($fd_mp_conf);
#    }
    if ( ($rhel_dist && $rhel_dist >= 7) || $fedora_dist ) {
        system("systemctl enable multipathd");
    }
    else {
        system("chkconfig multipathd on");
    }
    system("service multipathd restart");
}
####################### End of functoin enable_mpath()

#--------------------------------------------------------------------------#
# upgrade_package ()
# Usage
#   upgrade_package($pkg)
# Purpose
#   Upgrade package like device-mapper-multipath, etc
# Parameter
#   $pkg            # like "device-mapper-multipath-0.4.9-56.el6_3.1"
# Returns
#   1
#       or
#   undef
# Exceptions
#   We die when we are old enough.
# See Also
#   fooc()
#--------------------------------------------------------------------------#
sub upgrade_package {
    my @pkgs     = split( " ", shift );
    my $arch     = rpm_arch();
    my @rpm_urls = ();
    my @post_commands;
    foreach my $pkg (@pkgs) {
        my $pkg_name;
        my $pkg_ver;
        my $pkg_rel;
        if ( $pkg =~ m/^(.+)-([^-]+)-([^-]+.+)/ ) {
            $pkg_name = $1;
            $pkg_ver  = $2;
            $pkg_rel  = $3;
        }
        else {
            print "FAIL: upgrade_package() failed to parse $pkg for name and "
              . "version\n";
            return undef;
        }

        # install rpm
        if ( $pkg_name eq "device-mapper-multipath" ) {
            my $lib_pkg = "device-mapper-multipath-libs-$pkg_ver-$pkg_rel";
            my $kpx_pkg = "kpartx-$pkg_ver-$pkg_rel";
            push @rpm_urls, _url_of_rpm( $pkg,     $arch );
            push @rpm_urls, _url_of_rpm( $lib_pkg, $arch, $pkg_name );
            push @rpm_urls, _url_of_rpm( $kpx_pkg, $arch, $pkg_name );
            push @post_commands, "service multipathd start";
            push @post_commands, "service multipathd reload";
        }
        elsif ( ($pkg_name eq "kernel") or ($pkg_name eq "kernel-pegas") or ($pkg_name eq "kernel-alt") ) {
            my $rhel_distnum = rhel_dist();
            if (!$rhel_distnum) {
                print "FAIL: At moment we only support install of kernel for RHEL\n";
                return undef;
            }
            my @kr_rpm_urls  = ();
            my $kr_pkg_url = _url_of_rpm( $pkg, $arch );
            push @kr_rpm_urls, $kr_pkg_url;
            #Install also debuginfo package, it is useful we we want to analize crash dump
            #or run /kernel/kdump/analyse-crash
            my $dbginfo_pkg = "kernel-debuginfo-$pkg_ver-$pkg_rel";
            my $kr_dbginfo_pkg_url = _url_of_rpm( $dbginfo_pkg, $arch, $pkg_name );

            my $dbginfo_common_pkg = "kernel-debuginfo-common-$arch-$pkg_ver-$pkg_rel";
            my $kr_dbginfo_common_pkg_url = _url_of_rpm( $dbginfo_common_pkg, $arch, $pkg_name );
            my $kernel_core_pkg = "kernel-core-$pkg_ver-$pkg_rel";
            my $kernel_core_url = _url_of_rpm( $kernel_core_pkg, $arch, $pkg_name );
            my $kernel_modules_pkg = "kernel-modules-$pkg_ver-$pkg_rel";
            my $kernel_modules_url =  _url_of_rpm( $kernel_modules_pkg, $arch, $pkg_name );
            #Do not install these package in pek2 server as they take way too long
            if (`hostname` !~ m/pek2.redhat.com/) {
                push @kr_rpm_urls, $kr_dbginfo_pkg_url;
                push @kr_rpm_urls, $kr_dbginfo_common_pkg_url;
            }

            my @kr_dependencies = rpm_dep($kr_pkg_url);
            #search for kernel firmware dependency
            #for example on RHEL-6 it is called kernel-firmware
            #and on RHEL-7 it is called linux-firmware and they are located
            #on different directory in brew
            my $kr_firm_pkg = undef;
            my $kr_firm_url = undef;
            #Workaround for BZ#1333088
            if (  rhel_release() eq "7.2" ) {
                push @kr_dependencies, "xfsprogs-4.5.0-3.el7";
            }
            foreach my $dep (@kr_dependencies) {
                if ($dep =~ m/kernel-firmware/) {
                    $kr_firm_pkg = "kernel-firmware-$pkg_ver-$pkg_rel";
                    $kr_firm_url = _url_of_rpm( $kr_firm_pkg, "noarch", $pkg_name );
                    push @kr_rpm_urls, $kr_firm_url;
                }
                elsif ($dep =~ m/linux-firmware-(.*)/) {
                    #get linux firmware release version
                    my $package = "linux-firmware";
                    my $version = $1;
                    #remove sub version if exists
                    $version =~ s/-.*//;
                    my $firm_path =  $BASE_DOWNLOAD_URL . "$package/$version";
                    my $release_file = "firm_release";
                    #save relase list
                    `wget $firm_path -O $release_file`;
                    #get latest release of this version
                    my $kr_firm_rel_cmd = "cat $release_file | grep \".el$rhel_distnum\" | tail -1 | awk '{print\$5}' | cut -d '\"' -f  2";
                    my $kr_firm_rel = `$kr_firm_rel_cmd`;
                    chomp ($kr_firm_rel);
                    #remove trail "/"
                    $kr_firm_rel =~ s/\/$//;
                    my $kr_firm_pkg = "$package-$version-$kr_firm_rel";

                    $kr_firm_url = _url_of_rpm( $kr_firm_pkg, "noarch" );
                    push @kr_rpm_urls, $kr_firm_url;
                }
                elsif ($dep =~ m/xfsprogs-(.*)/) {
                    push @kr_rpm_urls, _url_of_rpm( $dep, $arch );
                }
            }

            #if could not install kernel package then it should fail
            if ( $rhel_distnum <= 5 ) {
                map { system("wget $_ -q") == 0 or return undef; } @kr_rpm_urls;
                system("$package_manager localinstall -y --nogpgcheck ./*.rpm") == 0
                  or return undef;
                #remove all kernel related rpm to not install later at generic package installation
                system("rm -f ./kernel*.rpm");
            }

            else {
                if ( $rhel_distnum == 8 ) {
                    push @kr_rpm_urls, $kernel_core_url;
                    push @kr_rpm_urls, $kernel_modules_url;

                }
                my $cmd = "$package_manager install -y --nogpgcheck " . "@kr_rpm_urls";
                print "$cmd\n";
                if (system( $cmd ) != 0) {
                    return undef;
                }
            }
        }
        elsif ( $pkg_name eq "iscsi-initiator-utils" ) {
            push @rpm_urls, _url_of_rpm( $pkg, $arch );
            #On RHEL-7 and RHEL-6.6 iscsi-initiator is shipping iscsiuio
            #separately on different package
            my $dep_pkg = "iscsi-initiator-utils-iscsiuio-$pkg_ver-$pkg_rel";
            push @rpm_urls, _url_of_rpm( $dep_pkg, $arch, $pkg_name );
            push @post_commands, "service iscsi restart";
            push @post_commands, "service iscsid restart";
        }
        elsif ( $pkg_name eq "fcoe-utils" ) {
            my $rhel_distnum = rhel_dist();
            my @kr_rpm_urls  = ();
            my $kr_pkg_url = _url_of_rpm( $pkg, $arch );
            push @kr_rpm_urls, $kr_pkg_url;

            my @kr_dependencies = rpm_dep($kr_pkg_url);
            my $dep_pkg = undef;
            my $dep_url = undef;
            foreach my $dep (@kr_dependencies) {
                if ($dep =~ m/libhbalinux/) {
                    #get linux firmware release version
                    #save relase list
                    my $dep_path = $BASE_DOWNLOAD_URL . "$dep";
                    $dep_path =~ s/linux-firmware-/linux-firmware\//;
                    my $release_file = "firm_release";
                    `wget $dep_path -O $release_file`;
                    #Try to find out the latest release of the dependency package
                    my $dep_rel_cmd = "cat $release_file | grep \".el$rhel_distnum\" | tail -1 | awk '{print\$5}' | cut -d '\"' -f  2";
                    my $dep_rel = `$dep_rel_cmd`;
                    chomp ($dep_rel);
                    #remove trail "/"
                    $dep_rel =~ s/\/$//;
                    my $dep_pkg = "$dep-$dep_rel";

                    $dep_url = _url_of_rpm( $dep_pkg, $arch );
                }
            }
        }
        elsif ( $pkg_name eq "scsi-target-utils" ) {
            push @rpm_urls, _url_of_rpm( $pkg, $arch );
            push @post_commands, "service tgtd restart";
        }
        elsif ( $pkg_name eq "libstoragemgmt" ) {
            push @rpm_urls, _url_of_rpm( $pkg, $arch );
            #install dependencies
            push @rpm_urls, _url_of_rpm( "libstoragemgmt-udev-$pkg_ver-$pkg_rel", $arch, "libstoragemgmt" );
            push @rpm_urls, _url_of_rpm( "libstoragemgmt-hpsa-plugin-$pkg_ver-$pkg_rel", "noarch", "libstoragemgmt");
            push @rpm_urls, _url_of_rpm( "libstoragemgmt-megaraid-plugin-$pkg_ver-$pkg_rel", "noarch", "libstoragemgmt");
            push @rpm_urls, _url_of_rpm( "libstoragemgmt-netapp-plugin-$pkg_ver-$pkg_rel", "noarch", "libstoragemgmt");
            push @rpm_urls, _url_of_rpm( "libstoragemgmt-nstor-plugin-$pkg_ver-$pkg_rel", "noarch", "libstoragemgmt");
            push @rpm_urls, _url_of_rpm( "libstoragemgmt-python-$pkg_ver-$pkg_rel", "noarch", "libstoragemgmt");
            push @rpm_urls, _url_of_rpm( "libstoragemgmt-python-clibs-$pkg_ver-$pkg_rel", $arch, "libstoragemgmt");
            push @rpm_urls, _url_of_rpm( "libstoragemgmt-smis-plugin-$pkg_ver-$pkg_rel", "noarch", "libstoragemgmt");
            push @rpm_urls, _url_of_rpm( "libstoragemgmt-targetd-plugin-$pkg_ver-$pkg_rel", "noarch", "libstoragemgmt");
        }
        elsif ( $pkg_name eq "lvm2" ) {
            push @rpm_urls, _url_of_rpm( $pkg, $arch );
            #install dependencies
            my @lvm2_dependencies = rpm_dep( _url_of_rpm( $pkg, $arch) );
            foreach my $dep (@lvm2_dependencies) {
                if ($dep =~ m/device-mapper-persistent-data-(.*)/) {
                    my $rhel_distnum = rhel_dist();
                    my $package = "device-mapper-persistent-data";
                    my $version = $1;
                    my $dep_pkg = undef;
                    my $dep_url = undef;
                    #remove sub version if exists
                    $version =~ s/-.*//;
                    my $dep_path = $BASE_DOWNLOAD_URL . "$package/$version";
                    #get linux firmware release version
                    #save relase list
                    my $release_file = "device-mapper-persistent-data_release";
                    `wget $dep_path -O $release_file`;
                    #Try to find out the latest release of the dependency package
                    my $dep_rel_cmd = "cat $release_file | grep \".el$rhel_distnum\" | tail -1 | awk '{print\$5}' | cut -d '\"' -f  2";
                    my $dep_rel = `$dep_rel_cmd`;
                    chomp ($dep_rel);
                    #remove trail "/"
                    $dep_rel =~ s/\/$//;
                    $dep_pkg = "$package-$version-$dep_rel";
                    $dep_url = _url_of_rpm( $dep_pkg, $arch );
                    push @rpm_urls, $dep_url;

                }
            }
            push @rpm_urls, _url_of_rpm( "lvm2-libs-$pkg_ver-$pkg_rel", $arch, "lvm2" );
            #It depends on device-mapper packages that are on same path as lvm2, but version number is different
            #just download all of them and let yum install what is needed
            my $dev_mapp_path = $BASE_DOWNLOAD_URL . "$pkg_name/$pkg_ver/$pkg_rel/$arch/";
            print "dev_mapper: $dev_mapp_path\n";
            `wget -r -nH -nd -np -R index.html* $dev_mapp_path 2>&1 > /dev/null`;
            push @rpm_urls, "./device-mapper-*";
        }
        else {
            my $rpm_url = _url_of_rpm( $pkg, $arch );
            push @rpm_urls, $rpm_url if $rpm_url;
        }
    }
    my $rhel_dist = rhel_dist();
    #generic package installation
    if ( $rhel_dist && $rhel_dist <= 5 ) {
        map { system("wget $_ -q"); } @rpm_urls;
        system("$package_manager localinstall -y --nogpgcheck ./*.rpm") == 0
          or return undef;
    }
    else {
        if ( scalar @rpm_urls > 0 ) {
            my $cmd = "$package_manager localinstall -y --nogpgcheck " . "@rpm_urls";
            print "$cmd\n";
            if (system( $cmd ) != 0) {
                return undef;
            }
        }
    }
    map { system($_) } @post_commands;
    1;
}
####################### End of functoin upgrade_package()

#--------------------------------------------------------------------------#
# _url_of_rpm ()
# Usage
#   _url_of_rpm($pkg,$arch,$base_pkg)
# Purpose
#   The brewroot http url for certain rpm
# Parameter
#   $pkg            # like "device-mapper-multipath-0.4.9-56.el6_3.1"
#   $arch           # like "x86_64"
#   $base_pkg       # like "device-mapper-multipath" when need kpartx
# Returns
#   1
#       or
#   undef
# Exceptions
#   N/A
# See Also
#   N/A
#--------------------------------------------------------------------------#
sub _url_of_rpm($$) {
    my $pkg      = shift;
    my $arch     = shift;
    my $base_pkg = shift;
    my $pkg_name;
    my $pkg_ver;
    my $pkg_rel;
    if ( $pkg =~ m/^(.+)-([^-]+)-([^-]+.+)/ ) {
        $pkg_name = $1;
        $pkg_ver  = $2;
        $pkg_rel  = $3;
        $base_pkg = $pkg_name unless defined $base_pkg;
        $base_pkg = "kernel-aarch64" if ( ($pkg_name eq "kernel") && ($arch eq "aarch64") );
        if ($pkg_name eq "kernel-pegas") {
            $pkg =~ s/kernel-pegas/kernel/;
        }
        if ($pkg_name eq "kernel-alt") {
            $pkg =~ s/kernel-alt/kernel/;
        }
    }
    else {
        print "FAIL: _url_of_rpm() failed to parse $pkg for name and "
          . "version\n";
        return undef;
    }
    #my $rpm_url = "http://download.devel.redhat.com/brewroot/packages/"
    my $rpm_url = $BASE_DOWNLOAD_URL . "$base_pkg/$pkg_ver/$pkg_rel/$arch/$pkg.$arch.rpm";
    return $rpm_url;
}
####################### End of functoin _url_of_rpm()

sub rpm_arch {
    my $rpm_arch = `rpm --eval "%_arch"`;
    chomp $rpm_arch;
    my $rhel_dist = rhel_dist();
    if ($rhel_dist) {
        $rpm_arch = 'i686' if ( $rpm_arch eq 'i386' && $rhel_dist == 6 );
    }
    return $rpm_arch;
}

sub uniq {
  my %seen;
  return grep { !$seen{$_}++ } @_;
}

sub rpm_dep {
    my $pkg = shift;

    #get the package it the version that it depends
    my $dep_cmd = "$package_manager deplist $pkg | grep \"dependency:\" | awk '{print\$2\"-\"\$4}'";
    print "$dep_cmd\n";
    #system($dep_cmd);
    my $dep_pkg = `$dep_cmd`;
    my @dep_list = split("\n", $dep_pkg);

    return uniq(@dep_list);
}

sub rhel_dist {
    system("$package_manager install -y redhat-rpm-config 1>/dev/null 2>/dev/null");
    my $distnum = `/usr/lib/rpm/redhat/dist.sh --el`;
    chomp $distnum;
    if ($distnum eq "") {
        #Not a rhel dist
        return undef;
    }
    return $distnum;
}

sub fedora_dist {
    system("$package_manager install -y redhat-rpm-config 1>/dev/null 2>/dev/null");
    my $distnum = `/usr/lib/rpm/redhat/dist.sh --fc`;
    chomp $distnum;
    if ($distnum eq "") {
        #Not a Fedora dist
        return undef;
    }
    return $distnum;
}

sub rhel_release {
    my $release = `lsb_release --release --short`;
    chomp($release);
    return $release;
}

sub enable_stcli {
    my $url = 'http://pkgs.devel.redhat.com/cgit/tests/kernel'
      . '/plain/storage/misc/toolbox/stcli';
    my $command = "wget $url -O /usr/bin/stcli";
    print "$command\n";
    system($command);
    system("chmod +x /usr/bin/stcli");
}

sub enable_sttools {
    my $url = 'http://pkgs.devel.redhat.com/cgit/tests/kernel'
      . '/plain/storage/misc/toolbox/stlio';
    my $command = "wget $url -O /usr/bin/stlio";
    print "$command\n";
    system($command);
    system("chmod +x /usr/bin/stlio");

    $url = 'http://pkgs.devel.redhat.com/cgit/tests/kernel'
      . '/plain/storage/misc/toolbox/check_san_switch';
    $command = "wget $url -O /usr/bin/check_san_switch";
    print "$command\n";
    system($command);
    system("chmod +x /usr/bin/check_san_switch");
}

sub enable_stilo {
    my $url = 'http://pkgs.devel.redhat.com/cgit/tests/kernel'
      . '/plain/storage/misc/toolbox/stilo';
    my $url_cfg = 'http://pkgs.devel.redhat.com/cgit/tests/kernel'
      . '/plain/storage/misc/toolbox/ilo_top.conf';
    my $command = "wget $url -O /usr/bin/stilo";
    print "$command\n";
    system($command);
    system("chmod +x /usr/bin/stilo");
    $command = "wget $url_cfg -O /etc/ilo_top.conf";
    print "$command\n";
    system($command);


}

sub enable_ipv6_dhcp() {
    my $sysconf_path         = '/etc/sysconfig/network-scripts';
    my $enable_ipv6_dhcp_str = 'DHCPV6C="yes"';
    my $fd_sysconf;
    unless ( opendir $fd_sysconf, $sysconf_path ) {
        print "FAIL: enable_ipv6_dhcp(): Failed to open dir $sysconf_path:$!";
        return undef;
    }
    foreach my $file_name ( readdir $fd_sysconf ) {
        next if $file_name eq '.';
        next if $file_name eq '..';
        next if $file_name eq 'ifcfg-lo';
        my $full_path = "$sysconf_path/$file_name";
        if ( $file_name =~ /^ifcfg-/ ) {
            my $cmd;

            # Add IPV6INIT=yes into it if not found
            unless (`egrep '^IPV6INIT=' "$full_path"`) {
                $cmd = "echo \"IPV6INIT=yes\" >> \"$full_path\"";
                print $cmd, "\n";
                system($cmd);
            }

            # Add DHCPV6C=yes into it if not found
            unless (`egrep '^DHCPV6C=' "$full_path"`) {
                $cmd = "echo \"DHCPV6C=yes\" >> \"$full_path\"";
                print $cmd, "\n";
                system($cmd);
            }

            # change IPV6INIT=no to IPV6INIT=yes
            $cmd =
              "sed -i -e 's/^IPV6INIT=.*/IPV6INIT=yes/' " . "\"$full_path\"";
            print $cmd, "\n";
            system($cmd);

            # change DHCPV6C=no to  DHCPV6C=yes
            $cmd = "sed -i -e 's/^DHCPV6C=.*/DHCPV6C=yes/' " . "\"$full_path\"";
            print $cmd, "\n";
            system($cmd);
        }
    }
}

sub enable_lsm_daemon {
    my $rhel_dist = rhel_dist();
    unless ( rhel_dist && $rhel_dist == 7 ) {
        print "INFO: Enabling libstoragemgmt\n";
        my $cmd = "$package_manager install -y libstoragemgmt";
        print "$cmd\n";
        system($cmd);
        $cmd = 'systemctl enable libstoragemgmt.service';
        print "$cmd\n";
        system($cmd);
        $cmd = 'systemctl start libstoragemgmt.service';
        print "$cmd\n";
        system($cmd);
        return 1;
    }
    return undef;
}

sub abort_recipe {
    my $recipeid = $ENV{RECIPEID};

    print "FAIL: cannot setup enviroment for Storage-QE\n";
    if ($recipeid) {
        print "INFO: Aborting recipe: $recipeid\n";
        #don't use capital letter for type, because rhts-abort does not accept it
        my $cmd = "rhts-abort -t recipe -r $recipeid";
        print "$cmd\n";
        system($cmd);
    }
    exit 1;
}

sub enable_stdev_san_top {
    my $san_top_url =
      'http://pnate-control-01.lab.bos.redhat.com/stdev/san_top_stdev.conf';
    my $host_name = `hostname`;
    chomp $host_name;
    if (( $host_name =~ /^rhel-storage-/ ) || ($ENV{FORCE_ST_DEV_ENV}) ) {
        unlink('/etc/san_top.conf');
        my $cmd = "wget $san_top_url -O /etc/san_top_stdev.conf";
        print $cmd;
        unless ( system($cmd) == 0 ) {
            print "FAIL: Failed to download the san_top.conf for "
              . "storage dev\n";
            return undef;
        }
        $cmd = 'ln -sf /etc/san_top_stdev.conf /etc/san_top.conf';
        print $cmd;
         system($cmd);
        return 1;
    }
    else { return undef }
}

sub install_rht_certificates {
    #Install Red Hat certificates, it is needed to:
    #    use 'yum' on RHEL
    #    run bkr command on RHEL-7.4
    my $cert1_url = "https://password.corp.redhat.com/legacy.crt";
    my $cert2_url = "https://password.corp.redhat.com/RH-IT-Root-CA.crt";
    my $cert_path = "/etc/pki/ca-trust/source/anchors";

    my $cmd = "wget $cert1_url -P $cert_path --no-check-certificate";
    print "$cmd\n";
    system("$cmd");
    $cmd = "wget $cert2_url -P $cert_path --no-check-certificate";
    print "$cmd\n";
    system("$cmd");
    $cmd = "update-ca-trust enable";
    print "$cmd\n";
    system($cmd);
    $cmd = "update-ca-trust extract";
    print "$cmd\n";
    system($cmd);

}


sub create_reboot_link {
    # sets reboot link to rths-reboot if is present on system
    my $rhts_reboot_file = "/usr/bin/rhts-reboot";
    my $reboot_file = "/usr/local/bin/reboot";
    if ( -e $rhts_reboot_file ) {
        my $cmd = "ln -s $rhts_reboot_file $reboot_file";
        print "$cmd\n";
        system($cmd);
    }
}

sub main {
    # We need to install rh certificates first
    install_rht_certificates();
    enable_ipv6_dhcp();
    if ( exists $ENV{INSTALLPKGS} && $ENV{INSTALLPKGS} ) {
        abort_recipe() if ( !upgrade_package( $ENV{INSTALLPKGS} ) );
    }
    abort_recipe() if ( !enable_st_repo() );
    print "INFO: st_repo enabled\n";
    install_beaker_client();
    install_rpms();
    install_pip();
    install_perl_libsan();
    link_2_INC();
    install_python_modules();
    enable_mpath();
    enable_stcli();
    enable_stilo();
    enable_sttools();
    if ( -f "$STQE_HOST_FILE" ) {
        print "INFO: Adding these info into /etc/hosts\n";
        system("cat $STQE_HOST_FILE | tee -a /etc/hosts");
    }
    enable_stdev_san_top();
    create_reboot_link();

# setup scsi_debug for rhel5
    system("/mnt/tests/kernel/storage/misc/env_setup/setup_scsi_debug.sh");
    1;
}

main();
