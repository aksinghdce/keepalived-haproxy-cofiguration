#! /bin/bash
# dsp utility script
#
# description: DSP installation and configuration utility script


_log_() {
    echo $(date) ${1}
    echo $(date) ${1} &>> ${dsp_nfv_log}
    return 0
}

_fail_() {
    _log_ "FATAL ERROR: ${1}. Now exiting..."
    exit 1
}

_service_() {
    [[ $# != 1 ]] && _fail_ "Usage: _service_ name"

    service ${1} status &> /dev/null && service ${1} stop &>> ${dsp_nfv_log} || :
    _log_ "Starting service "${1} &&
    service ${1} start &>> ${dsp_nfv_log} &&
    _log_ "Service "${1}" started" ||
    _fail_ "Service "${1}
    return 0
}

# Get the ip address attached to a specific interface; default to hostname -i
_getIpAddress() {
    if [ "$1" == "" ]; then 
    	ipAddress=$(hostname -i)
    else 
		ipAddress=$(/sbin/ifconfig $1 | grep "inet addr" | awk -F: '{print $2}' | awk '{print $1}')
	fi
	echo ${ipAddress}
	return 0
}

# Get the netmask attached to a specific interface
_getNetmask() {
	_netmask=$(/sbin/ifconfig $1 | grep "inet addr" | awk -F: '{print $4}')
	echo ${_netmask}
	return 0
}

# add a new entry in /etc/hosts, passed as 1st parameter as fqdn
# ensuring that it is not a duplicate and it includes a short name alias 
# The ip address is passed as the second parameter
add_host_entry() {
    [[ $# != 0 ]] || return 0
    [[ $# != 2 ]] && _fail_ "Adding host $1 with address $2 failed: usage: add_unique_host hostname ip_address"

    NEW_HOST=$1
    NEW_HOST_SHORT=$(echo ${NEW_HOST} | /usr/bin/awk -F. '{print $1}')
    NEW_IP_ADDR=$2
    sed -i /${NEW_HOST}/d /etc/hosts &&
    echo ${NEW_IP_ADDR} ${NEW_HOST} ${NEW_HOST_SHORT} >> /etc/hosts || _ret=1
    
    return ${_ret:-0}
}

_get_dsp_nfv_props() {
	# Check for Heat meta data
	# identify the block device that corresponds to the configuration drive.
	_heat_config_vol=$(blkid -t LABEL="config-2" -odevice)

	if [ "${_heat_config_vol}" != "" ]; then
		umount /mnt/config_heat/ &> /dev/null
		_log_ "Using Heat user data to build VNF descriptor." && 
		mkdir -p /mnt/config_heat && 
		mount ${_heat_config_vol} /mnt/config_heat &>> ${dsp_nfv_log} &&
		_VNF_DESCRIPTOR=$(cat /mnt/config_heat/openstack/latest/user_data) &&
		export $_VNF_DESCRIPTOR && 
		echo $_VNF_DESCRIPTOR &>> ${dsp_nfv_log} || _fail_ "Getting Heat user data for cluster description"
		
		MGMT_DEVICE=$Dev
		# The cluster name is used to decorate some names in lower case
		_name=$(echo $NAME | awk '{print tolower($0)}')
		_check_dsp_host_name 
		
	        _log_ "Building VNF descriptor for HP DSP HA Setup"
	        lb1_name=$(echo ${LB1_NAME} | awk '{print tolower($0)}')
	        lb2_name=$(echo ${LB2_NAME} | awk '{print tolower($0)}')
	        cp -f /opt/dsp/config/dsp-nfv.properties.template ${dsp_nfv_properties}
	        sed -i "s/@app1_name@/${DSP1_NAME}/"  ${dsp_nfv_properties}
	        sed -i "s/@app1_ip@/${DSP1_IP_ADDR}/"  ${dsp_nfv_properties}
	        sed -i "s/@app2_name@/${DSP2_NAME}/"  ${dsp_nfv_properties}
	        sed -i "s/@app2_ip@/${DSP2_IP_ADDR}/"  ${dsp_nfv_properties}
	        sed -i "s/@lb1_name@/${PRIMARY_LB_NAME}/"  ${dsp_nfv_properties}
	        sed -i "s/@lb1_ip@/${PRIMARY_LB_IP_ADDR}/"  ${dsp_nfv_properties}
	        sed -i "s/@lb2_name@/${SECONDARY_LB_NAME}/"  ${dsp_nfv_properties}
	        sed -i "s/@lb2_ip@/${SECONDARY_LB_IP_ADDR}/"  ${dsp_nfv_properties}
	        sed -i "s/@http_vip@/${HTTP_LB_VIP_ADDR}/"  ${dsp_nfv_properties}
	        sed -i "s/@http_name@/${HTTP_LB_VIP_NAME}/"  ${dsp_nfv_properties}
	        sed -i "s/@db-host@/${ORACLE_HOST}/"  ${dsp_nfv_properties}
	        sed -i "s/@db-ip@/${ORACLE_IP_ADDR}/"  ${dsp_nfv_properties}
	        sed -i "s/@db-instance@/${ORACLE_SID}/"  ${dsp_nfv_properties}
	        sed -i "s/@db-port@/${ORACLE_PORT}/"  ${dsp_nfv_properties}
	        sed -i "s/@db-password@/${DSPDB_SYSDBA_PASSWORD}/"  ${dsp_nfv_properties}
	fi
	
    typeset -i _count=0 &&
    until grep -q '+++ EOF +++' ${dsp_nfv_properties} &> /dev/null; do
        _log_ "Waiting 10s for cluster definition file "${dsp_nfv_properties} &&
        sleep 10 &&
        _count=${_count}+1 &&
        test ${_count} -le 99 || _fail_ "DSP cluster definition "${dsp_nfv_properties}
    done &&
    dos2unix ${dsp_nfv_properties} &>> ${dsp_nfv_log} ||
    _fail_ "DSP cluster definition "${dsp_nfv_properties}
    return 0
}


# Retrieve install script for DSP,HPSA and Oracle
_extract_install_sh() {

    [[ $# != 2 ]] && _fail_ "Usage _extract_install_sh <iso image> <install.sh>"

    mkdir -p  /media/cdrom &&
    mount -o loop ${dsp_nfv_iso_dir}/${1} /media/cdrom &&
    rm -f ${dsp_nfv_iso_dir}/${2} &&
    cp /media/cdrom/utils/${2} ${dsp_nfv_iso_dir}/${2} &&
    umount /media/cdrom &&
    chmod a+x ${dsp_nfv_iso_dir}/${2} || return 1
    return 0
}

_dsp_iso() {
    echo $(ls DSP-*iso 2>/dev/null)
}

#TBV
_hpsa_iso() {
    echo $(ls HPSA-base-*iso 2>/dev/null)
}

_dsp_base() {
    cd ${dsp_nfv_iso_dir} &&
    DSP_ISO=$(_dsp_iso) &&
    test -f "${DSP_ISO}" || return 0

    pextract_install_sh ${DSP_ISO} install-see.sh &&
    ./install-dsp.sh -u --iso ${DSP_ISO} --yes || return 1
    return 0
}

_hpsa_base() {
    cd ${dsp_nfv_iso_dir} &&
    HPSA_ISO=$(_hpsa_iso) &&
    test -f "${HPSA_ISO}" || return 0

    _extract_install_sh ${HPSA_ISO} install-mse.sh &&
    ./install-mse.sh -u --iso ${HPSA_ISO} --yes || return 1
    return 0
}

_check_dsp_host_name() {
	if [ ! $(hostname -i) ]; then
		# no known ip address, 
		# checking fqdn in /etc/sysconfig/network from eth0
		add_host_entry $(grep HOSTNAME /etc/sysconfig/network | awk -F= '{print $2}') $(_getIpAddress eth0)
	fi
    return 0
}


# Patch ${dsp_lb_properties} from the cluster definition
_dsp_http_lb_properties() {
    _ret=0
    _suffix=_$$
    _properties=${dsp_lb_properties}
    _temp=${_properties}_${_suffix}

    _see_server_fqdn=${PRIMARY_SEE_NAME}@@${SECONDARY_SEE_NAME}
    _see_server_rip_address=${PRIMARY_SEE_IP_ADDR_APP_DEVICE}@@${SECONDARY_SEE_IP_ADDR_APP_DEVICE}
    _see_server_port_0="9443@@9443"
    _see_server_port_1="8080@@8080"
    _see_server_port_2="8451@@8451"
    typeset -i _server_index=1
    _see_name=NODE_SEE_NAME${_server_index}
    _see_ip_addr=NODE_SEE_IP_ADDR${_server_index}_APP_DEVICE
    _see_node_name=${!_see_name}
    _see_node_ip_addr=${!_see_ip_addr}
    until test x${_see_node_name} = x; do
        _see_server_fqdn=${_see_server_fqdn}@@${_see_node_name}
        _see_server_rip_address=${_see_server_rip_address}@@${_see_node_ip_addr}
        _see_server_port_0=${_see_server_port_0}"@@9443"
        _see_server_port_1=${_see_server_port_1}"@@8080"
        _see_server_port_2=${_see_server_port_2}"@@8451"
        _server_index=${_server_index}+1
	_see_name=NODE_SEE_NAME${_server_index}
	_see_ip_addr=NODE_SEE_IP_ADDR${_server_index}_APP_DEVICE
	_see_node_name=${!_see_name}
	_see_node_ip_addr=${!_see_ip_addr}
    done

    test -f ${_properties} &&
    sed -e s%^primary_fqdn=.*%primary_fqdn=${PRIMARY_LB_NAME}% \
        -e s%^primary_ip_address=.*%primary_ip_address=${PRIMARY_LB_IP_ADDR}% \
        -e s%^backup_fqdn=.*%backup_fqdn=${SECONDARY_LB_NAME}% \
        -e s%^backup_ip_address=.*%backup_ip_address=${SECONDARY_LB_IP_ADDR}% \
        -e s%^ha_device=.*%ha_device=${HA_DEVICE}% \
        -e s%^ping_ip_addr=.*%ping_ip_addr=${HA_PING_IP_ADDR}% \
        -e s%^snmp_trap_destination=.*%snmp_trap_destination=\(${SNMP_TRAP_DESTINATION}\)% \
        -e s%^vip_address=.*%vip_address=\(${HTTP_LB_VIP_ADDRESS}\)% \
        -e s%^vip_broadcast=.*%vip_broadcast=\($(_broadcast ${HTTP_LB_VIP_ADDRESS} ${APP_NETMASK})\)% \
        -e s%^vip_device=.*%vip_device=\(${APP_DEVICE}\)% \
        -e s%^vip_mask=.*%vip_mask=\($(_mask ${APP_NETMASK})\)% \
        -e s%^vip_nmask=.*%vip_nmask=\(${APP_NETMASK}\)% \
        -e s%^port_0=.*%port_0=\(9443\ 8080\ 8451\)% \
        -e s%^send_program_0=.*%send_program_0=\(\${ccps_program}\ \${see_program}\ \${see_program}\)% \
        -e s%^server_fqdn_00=.*%server_fqdn_00=\(${_see_server_fqdn}\)% \
        -e s%^server_rip_address_00=.*%server_rip_address_00=\(${_see_server_rip_address}\)% \
        -e s%^server_port_00=.*%server_port_00=\(${_see_server_port_0}\)% \
        -e s%^server_fqdn_01=.*%server_fqdn_01=\(${_see_server_fqdn}\)% \
        -e s%^server_rip_address_01=.*%server_rip_address_01=\(${_see_server_rip_address}\)% \
        -e s%^server_port_01=.*%server_port_01=\(${_see_server_port_1}\)% \
        -e s%^server_fqdn_02=.*%server_fqdn_02=\(${_see_server_fqdn}\)% \
        -e s%^server_rip_address_02=.*%server_rip_address_02=\(${_see_server_rip_address}\)% \
        -e s%^server_port_02=.*%server_port_02=\(${_see_server_port_2}\)% \
        ${_properties} >${_temp} && sed -i -e s%@@%\ %g ${_temp} || _ret=1
    test x${_ret} = x0 && cat ${_temp} > ${_properties} && rm ${_temp} || _ret=1
    _dump_ ${_properties}
    return ${_ret}
}

# Patch ${dsp_see_cluster_properties} from the cluster definition
_dsp_see_primary_cluster_properties() {
    _ret=0
    _suffix=_$$
    _properties=${dsp_see_cluster_properties}
    _temp=${_properties}_${_suffix}
    test -f ${_properties} &&
    sed -e '/^LOCAL_BIND_ADDRESS=/ c\LOCAL_BIND_ADDRESS='${PRIMARY_SEE_IP_ADDR} \
        -e '/^CLUSTER_BIND_ADDRESS_PRIMARY=/ c\CLUSTER_BIND_ADDRESS_PRIMARY='${PRIMARY_SEE_NAME} \
        -e '/^CLUSTER_BIND_ADDRESS_SECONDARY=/ c\CLUSTER_BIND_ADDRESS_SECONDARY='${SECONDARY_SEE_NAME} \
        -e '/^CLUSTER_BIND_ADDRESS_WITNESS=/ c\CLUSTER_BIND_ADDRESS_WITNESS='${WITNESS_SEE_NAME} \
        -e '/^CLUSTER_MCAST_ADDRESS=/ c\CLUSTER_MCAST_ADDRESS='$(_create_mcast_address see) \
        ${_properties} >${_temp} || _ret=1
    test x${_ret} = x0 && cat ${_temp} > ${_properties} && rm ${_temp} || _ret=1
    _dump_ ${_properties}
    return ${_ret}
}

# Add password
_add_password() {
    [[ $# != 2 ]] && _fail_ "Usage: _add_password name password"

    _ret=0
    _properties=${dsp_properties}
    grep -q '^'$1'=' ${_properties} &&
    sed -i -e 's:^'$1'=.*:'$1'='$2':' ${_properties} ||
    echo $1=$2 >> ${_properties} || _ret=1
    return ${_ret}
}

# SCP a file to a remote node and wait for success
_scp_with_retry() {
    _SOURCE_FILE=$1
	_TARGET_NODE=$2
	_RETRY_NB=${3:-1}
	# Silently reject copy to nowhere
	if [ "${_TARGET_NODE}" == "" ]; then
		return 0;
	fi
	
	test -f ${_SOURCE_FILE} || _fail_ "Usage: _scp_with_retry SOURCE_FILE(${_SOURCE_FILE}) TARGET_NODE(${_TARGET_NODE}) RETRY_NB(${_RETRY_NB}): source file ${_SOURCE_FILE} does not exist"
	
    typeset -i _count=0 &&
    	until ${OpenSCPcmd} ${_SOURCE_FILE} ${_TARGET_NODE}:${_SOURCE_FILE} &>> ${dsp_nfv_log}; do
            _log_ "Cannot copy ${_SOURCE_FILE} to ${_TARGET_NODE}: waiting 20s..." &&
            sleep 20 &&
            _count=${_count}+1 &&
            test ${_count} -le ${_RETRY_NB} || return 1
        done
        
        return 0
}

# Patch ${dsp_properties} from the cluster definition
_dsp_properties() {
    _ret=0
    _suffix=_$$
    _properties=${dsp_properties}
    _temp=${_properties}_${_suffix}
    test -f ${_properties} &&
    sed -e '/^DSPDB_ADMIN=/ c\DSPDB_ADMIN='${DSPDB_ADMIN} \
        -e '/^DSPDB_APP=/ c\DSPDB_APP='${DSPDB_APP} \
        -e '/^DSPDB_OPER=/ c\DSPDB_OPER='${DSPDB_OPER} \
        -e '/^TPDM_TABLESPACE=/ c\TPDM_TABLESPACE='${TPDM_TABLESPACE} \
        -e '/^AAA_TABLESPACE=/ c\AAA_TABLESPACE='${AAA_TABLESPACE} \
        -e '/^MCM_TABLESPACE=/ c\MCM_TABLESPACE='${MCM_TABLESPACE} \
        -e '/^MCS_TABLESPACE=/ c\MCS_TABLESPACE='${MCS_TABLESPACE} \
        -e '/^SMB_TABLESPACE=/ c\SMB_TABLESPACE='${SMB_TABLESPACE} \
        -e '/^MCS_HOST=/ c\MCS_HOST='$(hostname) \
        -e '/^MCS_IVR_RESOURCES_HOST=/ c\MCS_IVR_RESOURCES_HOST='${SNS_VIP_ADDRESS}':5060' \
        -e '/^MCS_CONF_RESOURCES_HOST=/ c\MCS_CONF_RESOURCES_HOST='${SNS_VIP_ADDRESS}':5060' \
        -e '/^MCS_PLAY_RESOURCES_HOST=/ c\MCS_PLAY_RESOURCES_HOST='${SNS_VIP_ADDRESS}':5060' \
        -e '/^MCS_DIALOG_RESOURCES_HOST=/ c\MCS_DIALOG_RESOURCES_HOST='${SNS_VIP_ADDRESS}':5060' \
        ${_properties} >${_temp} || _ret=1
    test x${_ret} = x0 && cat ${_temp} > ${_properties} && rm ${_temp} || _ret=1

    # Add passwords
    test x${_ret} = x0 &&
    _add_password DSPDB_APP_PASSWORD ${DSPDB_APP_PASSWORD} &&
    _add_password DSPDB_CCPS_DS_PASSWORD ${DSPDB_CCPS_DS_PASSWORD} &&
    _add_password DSPDB_CCPS_PASSWORD ${DSPDB_CCPS_PASSWORD} &&
    _add_password DSPDB_CCXML_PASSWORD ${DSPDB_CCXML_PASSWORD} &&
    _add_password DSPDB_EBRS_DS_PASSWORD ${DSPDB_EBRS_DS_PASSWORD} &&
    _add_password DSPDB_EBRS_PASSWORD ${DSPDB_EBRS_PASSWORD} &&
    _add_password DSPDB_EBRS_QRTZ_DS_PASSWORD ${DSPDB_EBRS_QRTZ_DS_PASSWORD} &&
    _add_password DSPDB_EBRS_QRTZ_PASSWORD ${DSPDB_EBRS_QRTZ_PASSWORD} &&
    _add_password DSPDB_JBOSS_JMS_PASSWORD ${DSPDB_JBOSS_JMS_PASSWORD} &&
    _add_password DSPDB_MSCML_PASSWORD ${DSPDB_MSCML_PASSWORD} &&
    _add_password DSPDB_OPER_PASSWORD ${DSPDB_OPER_PASSWORD} &&
    _add_password DSPDB_REPORT_USER_PASSWORD ${DSPDB_REPORT_USER_PASSWORD} &&
    _add_password DSPDB_VXML_PASSWORD ${DSPDB_VXML_PASSWORD} &&
    _add_password DBPASSWORD ${DSPDB_OCDBACCESS_PASSWORD} &&
    _add_password DBREPPASSWORD ${DSPDB_OCDBREP_PASSWORD}  || _ret=1
    _dump_ ${_properties}
    return ${_ret}
}

# global properties files and directories
dsp_lb_properties=/etc/opt/OC/hpoc-dsp-lb/dsp-lb.properties
dsp_nfv_properties=/etc/opt/OC/hpoc-dsp-nfv/dsp-cluster-nfv.properties
dsp_nfv_node_xml_description=/etc/opt/OC/hpoc-dsp-nfv/vm.xml
dsp_nfv_iso_dir=/var/opt/OC/iso
dsp_nfv_log=/var/log/dsp-setup.log
dsp_properties=/etc/opt/OC/hpoc-dsp/dsp.properties
dsp_see_cluster_properties=/etc/opt/OC/hpoc-see/cluster.properties
dsp_sns_properties=/etc/opt/OC/hpoc-dsp-sns/dsp-sns.properties
dsp_sns_provdata=/etc/opt/OC/gmf/provdata/ocsns.prov
ocmp_customized_properties=/etc/opt/OC/ocmp/customized_properties
ocmp_properties=/etc/opt/OC/ocmp/OCMP.properties

SNTS_DIR=/etc/opt/OC/hpoc-dsp-nfv/snts

# common commands
OpenSSHcmd="ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
OpenSCPcmd="scp -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

# Certificates
CCPS_KEYSTORE=/etc/opt/OC/ccps/security/hpoc-ccps.keystore
SEE_KEYSTORE=/etc/opt/OC/see/security/see.keystore
OCMP_KEYSTORE=/etc/opt/OC/ocmp/security/oam.ocmp.keystore
OCMP_TRUSTSTORE=/etc/opt/OC/ocmp/security/ocmp.truststore
OCMP_CERT=/etc/opt/OC/ocmp/security/oam_ocmp.cer
CERT_AUTH_DIRECTORY=/etc/opt/OC/hpoc-dsp-nfv/certAuth/
CERT_VALIDITY=3650
DSP_SECURITY=/etc/opt/OC/security/
