#!/bin/bash
# init file for dsp setup
#
# description: DSP installation and configuration setup script

_usage() {
    _log_ "Usage: $0 </etc/sysconfig/dsp-nfv>"
    _fail_ "$0"
}

# Add new entries in /etc/hosts, parameters: hostname variable and ip address variable
# example: add_host_entry PRIMARY_DB_SERVER PRIMARY_DB_IP_ADDR
populate_etc_hosts() {
    _log_ "Populating /etc/hosts"

    # Need to self know
    add_host_entry ${LOCAL_NAME} ${LOCAL_IP}
	  
    typeset -i COUNTER=1
    NODE_DSP_IP_ADDR=NODE_DSP_IP_ADDR${COUNTER}
    NODE_DSP_NAME=NODE_DSP_NAME${COUNTER}
    until [ "${!NODE_DSP_IP_ADDR}" = "" ] ; do
        add_host_entry ${NODE_DSP_NAME} ${NODE_DSP_IP_ADDR} || _ret=1
        COUNTER=${COUNTER}+1
        NODE_DSP_IP_ADDR=NODE_DSP_IP_ADDR${COUNTER}
        NODE_DSP_NAME=NODE_DSP_NAME${COUNTER}
    done

    add_host_entry ORACLE_HOST ORACLE_IP_ADDR &&
    add_host_entry PRIMARY_LB_NAME PRIMARY_LB_IP_ADDR &&
    add_host_entry MSE_HOST MSE_IP_ADDR  || _ret=1
    return ${_ret:-0}
}

#   / \  / \  / \  / \
#  ( M )( A )( I )( N )
#   \_/  \_/  \_/  \_/
. /opt/dsp/sbin/dsp-nfv-util.sh
[[ $# != 0 ]] && [[ $# != 1 ]] && _usage

sysconfig_file=${1:-/etc/sysconfig/dsp-nfv}

_log_ "Starting DSP setup from description file "${dsp_nfv_properties}

_get_dsp_nfv_props &&
source ${dsp_nfv_properties} ||
_fail_ "Missing "${dsp_nfv_properties}" file"

# Source again the cluster properties file after fixing the local hostname, to allow references to $(hostname) in the cluster description
_check_dsp_host_name && source ${dsp_nfv_properties}

LOCAL_IP=$(_getIpAddress)
LOCAL_NAME=$(hostname)

populate_etc_hosts || _fail_ "Populate /etc/hosts"

DSPEMS_ROLE=-
OCMP_ROLE=-
SEE_ROLE=-
SNS_ROLE=-
LB_ROLE=-
WEBRTC_ROLE=-
DB_ROLE=-
typeset -i RS_ID

if [ "${LOCAL_IP}" = "${DSP_EMS_IP_ADDR}" ]; then
    DSPEMS_ROLE=dspems &&
    /opt/OC/sbin/_dsp-nfv-dspclusterEmsSetup.sh ||
    _fail_ "DSP EMS "${DSPEMS_ROLE}" setup"
fi

# http load balancer will be hosted either by the SEE nodes or by the SNS nodes
if [ "${LOCAL_IP}" = "${PRIMARY_LB_IP_ADDR}" ]; then
    LB_ROLE=primary
fi
if [ "${LOCAL_IP}" = "${SECONDARY_LB_IP_ADDR}" ]; then
    LB_ROLE=secondary 
fi

# WEBRTC functions are hosted by nodes like SEE (SIP gateway) or any other (ISF, redis)
# The Media, Signaling and SIP functions need connectivity to the SIP network
if [ "${LOCAL_IP}" = "${WEBRTC_SIGNALING_IP_ADDR}" ]; then
    add_network_interface ${SIP_DEVICE} ${WEBRTC_SIGNALING_IP_ADDR_SIP_DEVICE} ${SIP_NETMASK}
    WEBRTC_ROLE=${WEBRTC_ROLE}signaling-
fi
if [ "${LOCAL_IP}" = "${WEBRTC_MEDIA_IP_ADDR}" ]; then
    add_network_interface ${SIP_DEVICE} ${WEBRTC_MEDIA_IP_ADDR_SIP_DEVICE} ${SIP_NETMASK}
    WEBRTC_ROLE=${WEBRTC_ROLE}media-
fi
if [ "${LOCAL_IP}" = "${WEBRTC_SIPGATEWAY_IP_ADDR}" ]; then
	add_network_interface ${SIP_DEVICE} ${WEBRTC_SIPGATEWAY_IP_ADDR_SIP_DEVICE} ${SIP_NETMASK}
    WEBRTC_ROLE=${WEBRTC_ROLE}sip-
fi
if [ "${LOCAL_IP}" = "${WEBRTC_STORAGE_IP_ADDR}" ]; then
    WEBRTC_ROLE=${WEBRTC_ROLE}storage- 
fi

if [ "${LOCAL_IP}" = "${WEBRTC_SIPPROXY_IP_ADDR}" ]; then
    WEBRTC_ROLE=${WEBRTC_ROLE}proxyregistrar-
fi

if [ "${LOCAL_IP}" = "${ORACLE_IP_ADDR}" ]; then
    DB_ROLE=oracle
    /opt/OC/sbin/_dsp-nfv-oracleSetup.sh ||
    _fail_ "Oracle database setup"
else
	# free space in /var FSL to make sure RS is able to start/process correctly
	rm -rf /var/opt/OC/iso/oracle-zips
fi

if [ "${LOCAL_IP}" = "${SIMPLEX_SEE_IP_ADDR}" ]; then
    SEE_ROLE=simplex &&
    RS_ID=1 &&
    DB_ROLE=${DSP_DB_TYPE} &&
    _check_memory_size &&
    /opt/OC/sbin/_dsp-nfv-seeSetup.sh ${SEE_ROLE} ${LB_ROLE} ${WEBRTC_ROLE}  ${RS_ID} ||
    _fail_ "DSP SEE "${SEE_ROLE}" setup"
fi

if [ "${LOCAL_IP}" = "${PRIMARY_SEE_IP_ADDR}" ]; then
    SEE_ROLE=primary &&
    RS_ID=1 &&
    _check_memory_size &&
   	add_network_interface ${APP_DEVICE} ${PRIMARY_SEE_IP_ADDR_APP_DEVICE} ${APP_NETMASK} &&
    add_network_interface ${SIP_DEVICE} ${PRIMARY_SEE_IP_ADDR_SIP_DEVICE} ${SIP_NETMASK} &&
    /opt/OC/sbin/_dsp-nfv-seeSetup.sh ${SEE_ROLE} ${LB_ROLE} ${WEBRTC_ROLE}  ${RS_ID} ||
    _fail_ "DSP SEE "${SEE_ROLE}" setup"
fi

if [ "${LOCAL_IP}" = "${SECONDARY_SEE_IP_ADDR}" ]; then
    SEE_ROLE=secondary &&
    RS_ID=2 &&
    _check_memory_size &&
   	add_network_interface ${APP_DEVICE} ${SECONDARY_SEE_IP_ADDR_APP_DEVICE} ${APP_NETMASK} &&
    add_network_interface ${SIP_DEVICE} ${SECONDARY_SEE_IP_ADDR_SIP_DEVICE} ${SIP_NETMASK} &&
    /opt/OC/sbin/_dsp-nfv-seeSetup.sh ${SEE_ROLE} ${LB_ROLE} ${WEBRTC_ROLE}  ${RS_ID} ||
    _fail_ "DSP SEE "${SEE_ROLE}" setup"
fi

if [ "${LOCAL_IP}" = "${WITNESS_SEE_IP_ADDR}" ]; then
    SEE_ROLE=witness &&
    /opt/OC/sbin/_dsp-nfv-seeSetup.sh ${SEE_ROLE} ${LB_ROLE} ${WEBRTC_ROLE}  "" ||
    _fail_ "DSP SEE "${SEE_ROLE}" setup"
fi



# Additional nodes are named NODE_SEE_IP_ADDRx, where x is numeric starting at 1
typeset -i COUNTER=1
NODE_SEE_IP_ADDR=NODE_SEE_IP_ADDR${COUNTER}
NODE_SEE_IP_ADDR_APP_DEVICE=NODE_SEE_IP_ADDR${COUNTER}_APP_DEVICE
NODE_SEE_IP_ADDR_SIP_DEVICE=NODE_SEE_IP_ADDR${COUNTER}_SIP_DEVICE
NODE_SEE_NAME=NODE_SEE_NAME${COUNTER}
until [ "${!NODE_SEE_IP_ADDR}" = "" ] ; do
    if [ "${LOCAL_IP}" = "${!NODE_SEE_IP_ADDR}" ]; then
        SEE_ROLE=node &&
	RS_ID=${COUNTER}+2 &&
	_check_memory_size &&
	add_network_interface ${APP_DEVICE} ${!NODE_SEE_IP_ADDR_APP_DEVICE} ${APP_NETMASK} &&
    add_network_interface ${SIP_DEVICE} ${!NODE_SEE_IP_ADDR_SIP_DEVICE} ${SIP_NETMASK} &&
    /opt/OC/sbin/_dsp-nfv-seeSetup.sh ${SEE_ROLE} ${LB_ROLE} ${WEBRTC_ROLE}  ${RS_ID} ||
	_fail_ "DSP SEE "${SEE_ROLE}" setup"
        break
    fi
    COUNTER=${COUNTER}+1
    NODE_SEE_IP_ADDR=NODE_SEE_IP_ADDR${COUNTER}
    NODE_SEE_NAME=NODE_SEE_NAME${COUNTER}
	NODE_SEE_IP_ADDR_APP_DEVICE=NODE_SEE_IP_ADDR${COUNTER}_APP_DEVICE
	NODE_SEE_IP_ADDR_SIP_DEVICE=NODE_SEE_IP_ADDR${COUNTER}_SIP_DEVICE
done

# optionally  install OCCP SNTS service
if [ "${ACTIVATE_OCCP_SNTS}" = "yes" ]; then
	/opt/OC/sbin/_dsp-nfv-occpSntsSetup.sh || 
	_fail_ "DSP OCCP SNTS service setup"
fi

if [ "${LOCAL_IP}" = "${PRIMARY_SNS_IP_ADDR}" ]; then
	# The SIP load balancer can also host the HTTP load balancer
	if [ "${LB_ROLE}" != "-" ]; then
		add_network_interface ${APP_DEVICE} ${PRIMARY_LB_IP_ADDR_APP_DEVICE} ${APP_NETMASK}
    fi
    SNS_ROLE=primary &&
    add_network_interface ${SIP_DEVICE} ${PRIMARY_SNS_IP_ADDR_SIP_DEVICE} ${SIP_NETMASK} &&
    /opt/OC/sbin/_dsp-nfv-http-lbSetup.sh ${LB_ROLE} &&
    /opt/OC/sbin/_dsp-nfv-snsSetup.sh ||
    _fail_ "DSP SNS "${SNS_ROLE}" setup"
fi
if [ "${LOCAL_IP}" = "${SECONDARY_SNS_IP_ADDR}" ]; then
	# The SIP load balancer can also host the HTTP load balancer
	if [ "${LB_ROLE}" != "-" ]; then
    	add_network_interface ${APP_DEVICE} ${SECONDARY_LB_IP_ADDR_APP_DEVICE} ${APP_NETMASK}
    fi
    SNS_ROLE=secondary &&
    add_network_interface ${SIP_DEVICE} ${SECONDARY_SNS_IP_ADDR_SIP_DEVICE} ${SIP_NETMASK} &&
    /opt/OC/sbin/_dsp-nfv-http-lbSetup.sh ${LB_ROLE} &&
    /opt/OC/sbin/_dsp-nfv-snsSetup.sh ||
    _fail_ "DSP SNS "${SNS_ROLE}" setup"
fi

if [ "${LOCAL_IP}" = "${PRIMARY_OCMP_IP_ADDR}" ]; then
    OCMP_ROLE=primary && 
    _check_memory_size &&
    add_network_interface ${APP_DEVICE} ${PRIMARY_OCMP_IP_ADDR_APP_DEVICE} ${APP_NETMASK} &&
    add_network_interface ${SIP_DEVICE} ${PRIMARY_OCMP_IP_ADDR_SIP_DEVICE} ${SIP_NETMASK} &&
    /opt/OC/sbin/_dsp-nfv-ocmpSetup.sh ${OCMP_ROLE} ${PRIMARY_OCMP_IP_NAT_ADDR} ||
    _fail_ "OCMP "${OCMP_ROLE}" setup"
fi
if [ "${LOCAL_IP}" = "${SECONDARY_OCMP_IP_ADDR}" ]; then
    OCMP_ROLE=secondary &&
    _check_memory_size &&
    add_network_interface ${APP_DEVICE} ${SECONDARY_OCMP_IP_ADDR_APP_DEVICE} ${APP_NETMASK} &&
    add_network_interface ${SIP_DEVICE} ${SECONDARY_OCMP_IP_ADDR_SIP_DEVICE} ${SIP_NETMASK} &&
    /opt/OC/sbin/_dsp-nfv-ocmpSetup.sh ${OCMP_ROLE} ${SECONDARY_OCMP_IP_NAT_ADDR} ||
    _fail_ "OCMP "${OCMP_ROLE}" setup"
fi

# Additional OCMP nodes are named NODE_OCMP_IP_ADDRx, where x is numeric starting at 1
typeset -i COUNTER=1
NODE_OCMP_IP_ADDR=NODE_OCMP_IP_ADDR${COUNTER}
NODE_OCMP_IP_NAT_ADDR=NODE_OCMP_IP_NAT_ADDR${COUNTER}
NODE_OCMP_IP_ADDR_APP_DEVICE=NODE_OCMP_IP_ADDR${COUNTER}_APP_DEVICE
NODE_OCMP_IP_ADDR_SIP_DEVICE=NODE_OCMP_IP_ADDR${COUNTER}_SIP_DEVICE
NODE_OCMP_NAME=NODE_OCMP_NAME${COUNTER}
until [ "${!NODE_OCMP_IP_ADDR}" = "" ] ; do
    if [ "${LOCAL_IP}" = "${!NODE_OCMP_IP_ADDR}" ]; then
        OCMP_ROLE=node &&
		_check_memory_size &&
		add_network_interface ${APP_DEVICE} ${!NODE_OCMP_IP_ADDR_APP_DEVICE} ${APP_NETMASK} &&
    	add_network_interface ${SIP_DEVICE} ${!NODE_OCMP_IP_ADDR_SIP_DEVICE} ${SIP_NETMASK} &&
        /opt/OC/sbin/_dsp-nfv-ocmpSetup.sh ${OCMP_ROLE} ${!NODE_OCMP_IP_NAT_ADDR} ||
		_fail_ "OCMP "${OCMP_ROLE}" setup"
        break
    fi
    COUNTER=${COUNTER}+1
    NODE_OCMP_IP_ADDR=NODE_OCMP_IP_ADDR${COUNTER}
    NODE_OCMP_NAME=NODE_OCMP_NAME${COUNTER}
	NODE_OCMP_IP_NAT_ADDR=NODE_OCMP_IP_NAT_ADDR${COUNTER}
	NODE_OCMP_IP_ADDR_APP_DEVICE=NODE_OCMP_IP_ADDR${COUNTER}_APP_DEVICE
	NODE_OCMP_IP_ADDR_SIP_DEVICE=NODE_OCMP_IP_ADDR${COUNTER}_SIP_DEVICE
done

# no role found : case of OCMP dynamic elasticity.
# TODO enhance to support all kind of elasticity
if [ "${SEE_ROLE}" = "-" ] && [  "${SNS_ROLE}" = "-" ] && [ "${OCMP_ROLE}" = "-" ] && [ "${DSPEMS_ROLE}" = "-" ] && [ "${WEBRTC_ROLE}" = "-" ] && [ "${DB_ROLE}" = "-" ]  ; then
    # Try to get a public address in the VM xml description made available by the infrastructure
    if [ -f ${dsp_nfv_node_xml_description} ];
    then
    	DYNNODE_OCMP_IP_NAT_ADDR=`xsltproc /opt/OC/share/hpoc-dsp-nfv/xsl/getNatIP.xsl ${dsp_nfv_node_xml_description}`
    	_log_ "Setting the public IP address to "${DYNNODE_OCMP_IP_NAT_ADDR}
    fi
    if [ "${DYNNODE_OCMP_IP_NAT_ADDR}" = "" ];
    then
    	_log_ "OCMP public IP address defaulting to "${LOCAL_IP}
    fi
    
    OCMP_ROLE=dynamicnode &&
    _check_memory_size &&
    /opt/OC/sbin/_dsp-nfv-ocmpSetup.sh ${OCMP_ROLE} ${DYNNODE_OCMP_IP_NAT_ADDR} ||
    _fail_ "OCMP "${OCMP_ROLE}" setup"
fi

# WebRTC role
if [ "${SEE_ROLE}" = "-" ] && [ "${WEBRTC_ROLE}" != "-" ]; then
	# If we are not on an SEE node, configure the webrtc role if any
	# (if we are on an SEE node, the webrtc role has been installed, configured and started as part of the SEE configuration, including the certificate)
	_log_ "Webrtc configuration and setup for role "${WEBRTC_ROLE}
	_webrtc_certificates
	/opt/OC/sbin/_dsp-nfv-webrtcSetup.sh ${WEBRTC_ROLE} all ||	_fail_ "Webrtc configuration and setup for role "${WEBRTC_ROLE} 
fi
	
# PROXY ROLE (setup to run after webrtc setup)
if echo ${WEBRTC_ROLE} | grep proxyregistrar &> /dev/null; then
	/opt/OC/sbin/_dsp-nfv-webrtcSipproxySetup.sh  ||
    _fail_ "DSP Webrtc SIP proxy registrar setup"
fi

_log_ "SEE:"${SEE_ROLE}" / SNS:"${SNS_ROLE}" / LB:"${LB_ROLE}" / WEBRTC:"${WEBRTC_ROLE}" / OCMP:"${OCMP_ROLE}" / DSP-EMS:"${DSPEMS_ROLE}" / DATABASE:"${DB_ROLE}
_log_ "DSP setup done: see ${dsp_nfv_log}"

# run only once: disable automatic run.
echo "RUN_DSP_NFV=NO" >${sysconfig_file}
_log_ "Disabling DSP setup for further run."
/sbin/chkconfig dsp-nfv off

exit 0
