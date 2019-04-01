#!/bin/bash
modinfo scsi_debug 1>/dev/null 2>/dev/null
if [ $? -ne 0 ];then
    check_pae="$(uname -r|grep PAE)"
        url="http://lacrosse.corp.redhat.com/~fge"
        url="${url}/scsi_debug"
    if [ "CHK${check_pae}" == "CHK" ];then
        url="${url}/scsi_debug_`uname -m`.ko"
    else
        url="${url}/scsi_debug_`uname -m`PAE.ko"
    fi
    echo "INFO: Downloading scsi_debug module for RHEL5:"
    wget_option="-O /lib/modules/`uname -r`"
    wget_option="${wget_option}/kernel/drivers/scsi/scsi_debug.ko -q"
    echo "wget $url $wget_option"
    wget $url $wget_option
    depmod -a
fi
