#!/bin/bash

_usage() {
    _log_ "Usage: $0 <seeRole> <lbRole> <webrtcRole> <clusterId(s)>"
    _log_ "     Where <seeRole> : primary | secondary | simplex | witness | node | dynamicnode "
    _log_ "     Where <lbRole> : primary | secondary "
    _log_ "     Where <webrtcRole> : any combination of signaling-sip-storage "
    _fail_ "$0"
}

erase_bundle() {
    test -f /opt/OC/share/hpoc-see-${SEE_ROLE}/install/configure.sh || return 0
    /opt/OC/share/hpoc-see-${SEE_ROLE}/install/configure.sh --erase ${NIVR_BUNDLE}
    return 0
}

install_see() {
    cd ${nivr_nfv_iso_dir} &&
    SEE_ISO=$(_see_iso) &&
    _log_ "Installing SEE "${SEE_ROLE}" with "${SEE_ISO} &&
    _extract_install_sh ${SEE_ISO} install-see.sh &&
    ./install-see.sh --yes --install --see-${SEE_ROLE} ${SIP_CONNECTIVITY} --iso ${SEE_ISO} &>> ${nivr_nfv_log} &&
    ./install-see.sh --yes --upgrade --iso ${SEE_ISO} &>> ${nivr_nfv_log} &&
    _rp_see &>> ${nivr_nfv_log} ||
    _fail_ "SEE "${SEE_ROLE}" installation"

    # update path
    . /etc/profile
    # avoid ocadmin user early expiration
    chage -E -1 -M -1 ocadmin

    # update cluster.properties, except for simplex
    if [ "${SEE_ROLE}" = "primary" ]; then
        _nivr_see_primary_cluster_properties ||
        _fail_ "SEE "${SEE_ROLE}" update cluster.properties"
    elif [ "${SEE_ROLE}" != "simplex" ]; then
        _log_ "Retrieving cluster.properties from the Primary SEE "${PRIMARY_SEE_NAME} &&
        typeset -i _count=0 &&
        until /opt/OC/share/hpoc-see-${SEE_ROLE}/install/configure.sh \
                --primary ${PRIMARY_SEE_NAME} \
                --interface ${LOCAL_IP} &>> ${nivr_nfv_log}; do
            _log_ "Primary not ready: waiting 20s..." &&
            sleep 20 &&
            _count=${_count}+1 &&
            test ${_count} -le 99 || _fail_ "Retrieve cluster.properties"
        done &&
        _dump_ ${nivr_see_cluster_properties} &&
        _log_ "cluster.properties successfully retrieved" ||
        _fail_ "SEE "${SEE_ROLE}" retrieve cluster.properties"
    fi
    _log_ "SEE "${SEE_ROLE}" installed."
    return 0
}

start_db() {
    # Start and secure the database:
    _log_ "Starting the database service"

    case ${NIVR_DB_TYPE} in
        mysql)start_mysql_db;;
        oracle)start_oracle_db;;
        *) _fail_ "NIVR SEE database type "${NIVR_DB_TYPE}" unknown" ;;
    esac

    _log_ "Database "${NIVR_DB_TYPE}" started."
}

start_mysql_db() {
    # start mysql
    service mysql start &>> ${nivr_nfv_log} || _fail_ "mysql startup failed"
    # Get the temporary password
    MYSQL_CUR_PWD=$(cat /.mysql_secret | awk '{print $NF}')
    if [ "${MYSQL_CUR_PWD}" == "" ]; then
        _log_ "mysql unknown default password, /.mysql_secret not found or empty, moving forward"
        return 0;
    else
        _log_ "Retrieved temporary mysql password "${MYSQL_CUR_PWD}
    fi
    # run mysql_secure_install
    # Set the 3 mysql passwords
    # Secure the database
    _log_ "Securing mysql database"
    export MYSQL_CUR_PWD
    export NIVRDB_ROOT_PASSWORD NIVRDB_OCDBACCESS_PASSWORD NIVRDB_OCDBREP_PASSWORD NIVRDB_CCPS_PASSWORD NIVRDB_CCPS_DS_PASSWORD NIVRDB_REPORT_USER_PASSWORD NIVRDB_EBRS_QRTZ_PASSWORD NIVRDB_EBRS_PASSWORD NIVRDB_EBRS_DS_PASSWORD
    expect -f /opt/OC/sbin/_nivr-nfv-mysql_secure.sh &>> ${nivr_nfv_log} || _fail_ "mysql secure failed"

    # remove the temporary mysql password, so that the next nivr-nfv service run keeps the new password
    rm -f /.mysql_secret

    return 0
}

start_oracle_db() {
    # Configure the database only if the SYSDBA account password is defined
    if [ "${NIVRDB_SYSDBA_PASSWORD}" == "" ]; then
        _log_ "NIVRDB_SYSDBA_PASSWORD undefined, skipping Oracle database tables and users creation"
        return 0;
    fi

    _log_ "Creating oracle tables and users with NIVRDB_SYSDBA account"
    export NIVRDB_ORACLE_PATH NIVRDB_SYSDBA NIVRDB_SYSDBA_PASSWORD NIVRDB_ADMIN_PASSWORD
    expect -f /opt/OC/sbin/_nivr-nfv-oracle-create-all.sh &>> ${nivr_nfv_log} || _fail_ "oracle tables and users creation failed"

    return 0
}

init_db() {
    # Initialize the database: mysql only; other db are configured out of NFV
    if [ "${NIVR_DB_TYPE}" != "mysql" ]; then
        return 0;
    fi
    _log_ "Initializing the database"
    export NIVRDB_ROOT_PASSWORD
    expect -f /opt/OC/sbin/_nivr-nfv-mysql_init.sh &>> ${nivr_nfv_log} || _fail_ "mysql initialization failed"

    # Provisioning the RS database
	SMB_OPTION=
    if [ "${ACTIVATE_APPLI_CAASIVR}" = "yes" ]; then
		SMB_OPTION="--smb" 
	fi
	_log_ "Provisioning the RS database with log_bin_trust_function_creators=1"
    sed -i "/event_scheduler/a log_bin_trust_function_creators=1" /etc/my.cnf &&
    service mysql restart &&
    echo Y|ccps-mysql-install.sh --drop-and-create-databases &>> ${nivr_nfv_log} &&
    ccps-mysql-install.sh --drop-and-create-users &>> ${nivr_nfv_log} &&
    ccps-mysql-install.sh --create-tables ${SMB_OPTION} &>> ${nivr_nfv_log} &&
    echo Y|ebrs-mysql-install.sh --drop-and-create-databases &>> ${nivr_nfv_log} &&
    ebrs-mysql-install.sh --drop-and-create-users &>> ${nivr_nfv_log} &&
    ebrs-mysql-install.sh --create-tables &>> ${nivr_nfv_log} || _fail_ "RS database provisionning failed"

    _log_ "Database "${NIVR_DB_TYPE}" initialized."
    return 0
}

install_nivr() {
    cd ${nivr_nfv_iso_dir} &&
    MSE_BASE_ISO=$(_mse_base_iso) &&
    MSE_CONNECTORS_ISO=$(_mse_connectors_iso) &&
    SMB_ISO=$(_smb_iso) &&
    _log_ "Installing NIVR on SEE "${SEE_ROLE}" with "${MSE_BASE_ISO}" using "${DB_DRIVER}/${RS_DB_DRIVER} &&
    if [ "${ACTIVATE_APPLI_CAASIVR}" = "yes" ]; then
		_log_ "Installing CaaSIVR applications on NIVR "${SMB_ISO} 
	fi &&
    _extract_install_sh ${MSE_BASE_ISO} install-mse.sh &&
    _extract_install_sh ${MSE_CONNECTORS_ISO} install-mse_connectors.sh &&
    if [ "${ACTIVATE_APPLI_CAASIVR}" = "yes" ]; then
		_extract_install_sh ${SMB_ISO} install-smb.sh 
	fi &&
    _log_ "./install-mse.sh --yes --install "${DB_DRIVER}" --iso "${MSE_BASE_ISO} &&
    ./install-mse.sh --yes --install ${DB_DRIVER} --iso ${MSE_BASE_ISO} &>> ${nivr_nfv_log} &&
    _log_ "./install-mse.sh --yes --install --rs-lmf --rs-orf "${RS_DB_DRIVER}" --iso "${MSE_BASE_ISO} &&
    ./install-mse.sh --yes --install --rs-lmf --rs-orf ${RS_DB_DRIVER} --iso ${MSE_BASE_ISO} &>> ${nivr_nfv_log} &&
    _log_ "./install-mse.sh --yes --upgrade --iso "${MSE_BASE_ISO} &&
    ./install-mse.sh --yes --upgrade --iso ${MSE_BASE_ISO} &>> ${nivr_nfv_log} &&
    _log_ "./install-mse_connectors.sh --yes --install --nivr-jdbc --nivr-scif --iso "${MSE_CONNECTORS_ISO} &&
    ./install-mse_connectors.sh --yes --install --nivr-jdbc --nivr-scif --iso ${MSE_CONNECTORS_ISO} &>> ${nivr_nfv_log} &&
    _log_ "./install-mse_connectors.sh --yes --upgrade --iso "${MSE_CONNECTORS_ISO} &&
    ./install-mse_connectors.sh --yes --upgrade --iso ${MSE_CONNECTORS_ISO} &>> ${nivr_nfv_log} &&
    if [ "${ACTIVATE_APPLI_CAASIVR}" = "yes" ]; then
		_log_ "./install-smb.sh --yes --install "${DB_DRIVER}" --iso "${SMB_ISO} &&
		./install-smb.sh --yes --install ${DB_DRIVER} --iso ${SMB_ISO} &>> ${nivr_nfv_log} &&
		_log_ "./install-smb.sh --yes --upgrade --iso "${SMB_ISO} &&
		./install-smb.sh --yes --upgrade --iso ${SMB_ISO} &>> ${nivr_nfv_log} &&
		_log_ "./install-mse.sh --yes --install --smb-reports --iso "${MSE_BASE_ISO} &&
		./install-mse.sh --yes --install --smb-reports --iso ${MSE_BASE_ISO} &>> ${nivr_nfv_log} &&
		_log_ "./install-smb.sh --yes --install --message-store --iso "${SMB_ISO} &&
		./install-smb.sh --yes --install --message-store --iso ${SMB_ISO} &>> ${nivr_nfv_log} 
	fi &&
    _rp_base &>> ${nivr_nfv_log} &&
    _rp_connectors &>> ${nivr_nfv_log} &&
    if [ "${ACTIVATE_APPLI_CAASIVR}" = "yes" ]; then
		_rp_smb &>> ${nivr_nfv_log} 
	fi ||
    _fail_ "NIVR on "${SEE_ROLE}" installation"

    # install additional prompts if any (is this CaaSIVR specific or more generic and to be kept?) 
    if [ "${ACTIVATE_APPLI_CAASIVR}" = "yes" ]; then
		for _prompts in ${APP_PROMPTS}; do
			if [ -f ${_prompts} ]; then
				_log_ "Loading specific application prompts: "${_prompts}
				rpm -Uvh ${_prompts} &>> ${nivr_nfv_log} ||
				_fail_ "Load specific application prompts"
			else
				_log_ "Specific application prompts file ${_prompts} not found: ignored, using default prompts."
			fi
		done
	fi

    # update path
    . /etc/profile
    # avoid ocadmin user early expiration
    chage -E -1 -M -1 ocadmin

    # prepare NIVR configuration
    case ${NIVR_DB_TYPE} in
        mysql)
        	PREPARE_DB_NIVR="--sip-address ${SIP_IP}"
        	PREPARE_DB_RS=
        	;;
        oracle)
        	PREPARE_DB_NIVR="--sip-address ${SIP_IP} \
	        	--nivr-db-host ${ORACLE_HOST} \
	        	--nivr-db-port ${ORACLE_PORT} \
	        	--nivr-db-service ${ORACLE_SERVICE}"
	    	PREPARE_DB_RS="--rs-db-host ${ORACLE_HOST} \
	        	--rs-db-port ${ORACLE_PORT} \
	        	--rs-db-service ${ORACLE_SERVICE}"
	        ;;
        *) _fail_ "NIVR SEE database type "${NIVR_DB_TYPE}" unknown" ;;
    esac
    
    if [ "${SEE_ROLE}" == "simplex" ]; then
    _log_ "Preparing nivr-db-config, ccps, ebrs" &&
    	nivr-db-config --prepare ${PREPARE_DB_NIVR} &&
	    ccps --prepare ${PREPARE_DB_RS} &&
	    ebrs --prepare ${PREPARE_DB_RS} ||
	    _fail_ "Prepare nivr, ccps, ebrs"
    else
	    _log_ "Preparing cluster.properties: --sip-address "${SIP_IP} &&
	    _log_ "Preparing cluster.properties: --nivr-db-host "${ORACLE_HOST} &&
	    _log_ "Preparing cluster.properties: --nivr-db-port "${ORACLE_PORT} &&
	    _log_ "Preparing cluster.properties: --nivr-db-service "${ORACLE_SERVICE} &&
	    nivr-db-config --prepare ${PREPARE_DB_NIVR} &>> ${nivr_nfv_log} &&
	    ccps --prepare \
	        --partition 'CCPS_'${PRIMARY_SEE_NAME} \
	        --mcast-address $(_create_mcast_address ccps) \
	        --server-peer-id ${RSLMF_ID} \
	        --bind-address ${LOCAL_IP} \
	        ${PREPARE_DB_RS} &>> ${nivr_nfv_log} &&
	    ebrs --prepare \
	        --partition 'EBRS_'${PRIMARY_SEE_NAME} \
	        --mcast-address $(_create_mcast_address ebrs) \
	        --server-peer-id ${RSORF_ID} \
	        --bind-address ${LOCAL_IP} \
	        ${PREPARE_DB_RS} &>> ${nivr_nfv_log} &&
	    _dump_ /etc/opt/OC/hpoc-nivr-db/tnsnames.ora ||
	    _fail_ "Prepare cluster.properties"
    fi

    _nivr_properties &&
    _log_ "NIVR installed on SEE "${SEE_ROLE} ||
    _fail_ "NIVR installed on SEE "${SEE_ROLE}

	# Install webrtc if any
	if [ "${WEBRTC_ROLE}" != "-" ]; then
		_log_ "Webrtc role ${WEBRTC_ROLE} installation on SEE "${SEE_ROLE}
		/opt/OC/sbin/_nivr-nfv-webrtcSetup.sh ${WEBRTC_ROLE} install || _fail_ "Webrtc ${WEBRTC_ROLE} role installation on SEE "${SEE_ROLE}
	fi

    return 0
}

configure_see() {
    _log_ "Configuring SEE "${SEE_ROLE}" with ${NIVR_BUNDLE}" &&
    /opt/OC/share/hpoc-see-${SEE_ROLE}/install/configure.sh ${NIVR_BUNDLE} &>> ${nivr_nfv_log} &&
    _log_ "SEE "${SEE_ROLE}" configured" ||
    _fail_ "Configure SEE "${SEE_ROLE}

    return 0
}

configure_corosync() {
	# if requested in the cluster description file
	if [ "${COROSYNC_UNICAST}" != "yes" ]; then 
		return 0
	fi
	
	_log_ "Build the corosync ring description as the list of SEE nodes"
	_COROSYNC_CLUSTER='member { \n\t\t\tmemberaddr: '${PRIMARY_SEE_IP_ADDR}'\n\t\t}'
	_COROSYNC_CLUSTER=${_COROSYNC_CLUSTER}'\n\t\tmember {\n\t\t\tmemberaddr: '${SECONDARY_SEE_IP_ADDR}'\n\t\t}'
	_COROSYNC_CLUSTER=${_COROSYNC_CLUSTER}'\n\t\tmember {\n\t\t\tmemberaddr: '${WITNESS_SEE_IP_ADDR}'\n\t\t}'
	typeset -i COUNTER=1
    NODE_SEE_IP_ADDR=NODE_SEE_IP_ADDR${COUNTER}
    NODE_SEE_NAME=NODE_SEE_NAME${COUNTER}
    until [ "${!NODE_SEE_IP_ADDR}" = "" ] ; do
        _COROSYNC_CLUSTER=${_COROSYNC_CLUSTER}'\n\t\tmember {\n\t\t\tmemberaddr: '${!NODE_SEE_IP_ADDR}'\n\t\t}'
        COUNTER=${COUNTER}+1
        NODE_SEE_IP_ADDR=NODE_SEE_IP_ADDR${COUNTER}
        NODE_SEE_NAME=NODE_SEE_NAME${COUNTER}
    done
    
	_log_ "Patch corosync configuration with an udpu transport and the list of nodes part of the cluster" && 	
	sed -i "s/ttl: .*$/${_COROSYNC_CLUSTER}/" /opt/OC/share/hpoc-config-tools/framework/modules/ntf/templates/template-corosync.conf &&
	sed -i "s/{{{nodeid}}}/{{{nodeid}}}\n\ttransport: udpu/" /opt/OC/share/hpoc-config-tools/framework/modules/ntf/templates/template-corosync.conf &&
	cat /opt/OC/share/hpoc-config-tools/framework/modules/ntf/templates/template-corosync.conf >> ${nivr_nfv_log} &&
    _log_ "SEE "${SEE_ROLE}" configured" ||
    _fail_ "Configure corosync"${SEE_ROLE}

    return 0
}

configure_http_lb() {
    _log_ "Configuring the HTTP load balancer on SEE node "${SEE_ROLE}" with role "${LB_ROLE} &&
    _nivr_http_lb_properties &&
    nivr-lb-real-server-config --setup &>> ${nivr_nfv_log} &&
    _log_ "HTTP load balancer status:" &&
    nivr-lb-real-server-status &>> ${nivr_nfv_log} &&
    /opt/OC/sbin/_nivr-nfv-http-lbSetup.sh ${LB_ROLE} &&
    _log_ "HTTP load balancer configured" ||
    _fail_ "HTTP Load Balancer configuration"

    return 0
}

configure_applications() {
    _ems_opt="--ems-user ocadmin --ems-passwd ocadmin"
    if [ "${NIVR_DB_TYPE}" == "oracle" ]; then
        _db_app_opt="--db-oracle-app-passwd "${NIVRDB_APP_PASSWORD}
        _db_oper_opt="--db-oracle-oper-passwd "${NIVRDB_OPER_PASSWORD}
    else
        _db_ocdbacces="--db-mysql-passwd "${NIVRDB_OCDBACCESS_PASSWORD}
    fi

    if [ "${SEE_ROLE}" = "simplex" ] || [ "${SEE_ROLE}" = "primary" ] || [ "${SEE_ROLE}" = "secondary" ]; then
        _log_ "Configuring the applications on SEE "${SEE_ROLE} &&
        # AS creation
        see-app-configure.sh --as-create --as-name $(hostname) --ccps --ebrs ${_ems_opt} &>> ${nivr_nfv_log} &&
        # SEE services loading and deployment
        see-app-load.sh --ccps --ebrs --as-name $(hostname) ${_ems_opt} ${_db_app_opt} ${_db_oper_opt} ${_db_ocdbacces} &>> ${nivr_nfv_log} &&
        # SMBIVR configuration
        see-app-configure.sh --as-create --as-name $(hostname) ${_ems_opt} &>> ${nivr_nfv_log} &&
        see-app-load.sh --as-name $(hostname) ${_ems_opt} ${_db_app_opt} ${_db_oper_opt} ${_db_ocdbacces} &>> ${nivr_nfv_log} ||
        _fail_ "Configure applications"
    fi

    if [ "${SEE_ROLE}" = "node" ]; then
        ssh_cmd=${OpenSSHcmd}" "${PRIMARY_SEE_IP_ADDR} &&
        _cmd="set \$(see -H ${PRIMARY_SEE_NAME} status|grep '^see-[13]'); echo \${2}-\${5}" &&
        _state=$(${ssh_cmd} "${_cmd}") &&
        typeset -i _count=0 &&
        until [ "${_state}" = "RUNNING-RUNNING" ]; do
            _log_ "Primary SEE not ready: waiting 10s..." &&
            sleep 10 &&
            _state=$(${ssh_cmd} "${_cmd}") &&
            _count=${_count}+1 &&
            test ${_count} -le 99 || _fail_ "Configure applications"
        done &&
        ssh_cmd=${OpenSSHcmd}" "${SECONDARY_SEE_IP_ADDR} &&
        _cmd="set \$(see -H ${SECONDARY_SEE_NAME} status|grep '^see-[13]'); echo \${2}-\${5}" &&
        _state=$(${ssh_cmd} "${_cmd}") &&
        typeset -i _count=0 &&
        until [ "${_state}" = "RUNNING-RUNNING" ]; do
            _log_ "Secondary SEE not ready: waiting 10s..." &&
            sleep 10 &&
            _state=$(${ssh_cmd} "${_cmd}") &&
            _count=${_count}+1 &&
            test ${_count} -le 99 || _fail_ "Configure applications"
        done &&
        _log_ "Configuring the applications on SEE "${SEE_ROLE} &&
        # prepare...
        # Cluster properties
        _cmd="nivr-db-config" &&
        _cmd=${_cmd}" --prepare "$(hostname) &&
        _cmd=${_cmd}" --nivr-db-host "${ORACLE_HOST} &&
        _cmd=${_cmd}" --nivr-db-port "${ORACLE_PORT} &&
        _cmd=${_cmd}" --nivr-db-service "${ORACLE_SERVICE} &&
        _cmd=${_cmd}" --sip-address "${SIP_IP} &&
        ${ssh_cmd} "${_cmd}" &>> ${nivr_nfv_log} &&
        # AS creation
        _cmd=" see-app-configure.sh --as-create --as-name "$(hostname)" --ccps --ebrs ${_ems_opt}" &&
        ${ssh_cmd} "${_cmd}" &>> ${nivr_nfv_log} &&
        # SEE services loading and deployment
        _cmd=" see-app-load.sh --ccps --ebrs --as-name "$(hostname)" ${_ems_opt} ${_db_app_opt} ${_db_oper_opt}" &&
        ${ssh_cmd} "${_cmd}" &>> ${nivr_nfv_log} &&
        # SMBIVR configuration
        _cmd=" see-app-configure.sh --as-create --as-name "$(hostname)" ${_ems_opt}" &&
        ${ssh_cmd} "${_cmd}" &>> ${nivr_nfv_log} &&
        _cmd=" see-app-load.sh --as-name "$(hostname)" ${_ems_opt} ${_db_app_opt} ${_db_oper_opt}" &&
        ${ssh_cmd} "${_cmd}" &>> ${nivr_nfv_log} ||
        _fail_ "Configure applications"
    fi
    
    _log_ "Build or retrieve the CCPS certificate" && 
   	_log_ "Build the CCPS certificate" &&
   	_ccps_certificate || _fail_ "Build the CCPS certificate"
	
	#in case OCMP of the cluster is not patched for TLS
	typeset -i _ocmp_patch_version=$(_ocmp_rp_iso | awk -F '008853.' '{print $2}' | awk -F '.' '{print $1}')
	if [ ${_ocmp_patch_version} -lt 010328 ]; then
		_log_ "patch CCPS SSL version for OCMP compatibility" &&
		sed -i -e s%TLSv1,TLSv1.1,TLSv1.2%TLS%g /var/opt/OC/hpoc-see/jboss/server/see-3/deploy/jbossweb.sar/server.xml
	fi
	
	# Configure the webrtc role if any
	if [ "${WEBRTC_ROLE}" != "-" ]; then
		_log_ "Webrtc role ${WEBRTC_ROLE} configuration on SEE "${SEE_ROLE}
		/opt/OC/sbin/_nivr-nfv-webrtcSetup.sh ${WEBRTC_ROLE} configure || _fail_ "Webrtc ${WEBRTC_ROLE} role configuration on SEE "${SEE_ROLE}
	fi
	
    _log_ "Applications configured on SEE "${SEE_ROLE}
    return 0
}

start_applications() {
    _log_ "Starting the applications on SEE "${SEE_ROLE} &&
	if [ "${ACTIVATE_APPLI_CAASIVR}" = "yes" ]; then
		smb-install-policies.sh &>> ${nivr_nfv_log} 
	fi &&
    if [ "${SIP_CONNECTIVITY}" != "" ]; then
        _log_ "Configuring SIP licence" &&
        _license_setup ${SEE_SIP_SERIAL} ${SEE_SIP_CODEWORD} &>> ${nivr_nfv_log} ||
        _fail_ "SIP license configuration"
    fi &&
    see start &>> ${nivr_nfv_log} &&
    if [ "${SEE_ROLE}" = "simplex" ] || [ "${SEE_ROLE}" = "primary" ]; then
        _log_ "Provisioning database with applications data" &&
        typeset -i _count=0 &&
        until nivr-data-provisioning.sh &>> ${nivr_nfv_log}; do
            _log_ "Data provisionning not ready: waiting 20s..." &&
            sleep 20 &&
            _count=${_count}+1 &&
            test ${_count} -le 99 || _fail_ "Data provisionning"
        done &&
        _log_ "Data successfully provisionned"
        _log_ "Provision topology data" 
        /opt/OC/sbin/_nivr-nfv-cluster-topology-update.sh ${SEE_ROLE} &>> ${nivr_nfv_log}
        # provision GUI of NIVR-EMS
        _cmd="http://"${LOCAL_IP}":8080/mcm/resources/_nivr/gui/topology/nivr-ems-alarms.html?followindirection=false&_type=data"
        curl -F submit=@/opt/OC/share/hpoc-nivr-nfv/ems/nivr-ems-alarms.html -X PUT $_cmd &>> ${nivr_nfv_log}
        _cmd="http://"${LOCAL_IP}":8080/mcm/resources/_nivr/gui/topology/nivr-alarm-history.xml?followindirection=false&_type=data"
        curl -F submit=@/opt/OC/share/hpoc-nivr-nfv/ems/nivr-alarm-history.xml -X PUT $_cmd &>> ${nivr_nfv_log}
        _log_ "Additional data (PoC specific) provisionned"
    fi &&
    _log_ "Starting CCPS on SEE "${SEE_ROLE} &&
    ccps start &>> ${nivr_nfv_log} &&
    _log_ "Starting EBRS on SEE "${SEE_ROLE} &&
    ebrs start &>> ${nivr_nfv_log} &&
    _log_ "Applications started on SEE "${SEE_ROLE} ||
    _fail_ "Start applications"

	# Start the webrtc role if any
	if [ "${WEBRTC_ROLE}" != "-" ]; then
		_log_ "Webrtc role ${WEBRTC_ROLE} startup on SEE "${SEE_ROLE}
		/opt/OC/sbin/_nivr-nfv-webrtcSetup.sh ${WEBRTC_ROLE} start || _fail_ "Webrtc ${WEBRTC_ROLE} role startup on SEE "${SEE_ROLE}
	fi
	
    return 0
}

#   / \  / \  / \  / \
#  ( M )( A )( I )( N )
#   \_/  \_/  \_/  \_/
. /opt/OC/sbin/nivr-nfv-util.sh
_check_nivr_host_name

[[ $# != 4 ]] && [[ $# != 5 ]] && _usage

. ${nivr_nfv_cluster_properties} ||
_fail_ "Missing "${nivr_nfv_cluster_properties}" file"

LOCAL_NAME=$(hostname)
LOCAL_IP=$(_getIpAddress)
SIP_IP=$(_getIpAddress ${SIP_DEVICE})
SIP_CONNECTIVITY=--sip
NIVR_BUNDLE='--bundle nivr-all'

_log_ "Applications to activate on top of NIVR:"
test x"${ACTIVATE_APPLI_CAASIVR}" = xyes && _log_ "  - CaaSIVR 		: yes " || _log_ "  - CaaSIVR 		: no "
test x"${ACTIVATE_OCCP_SNTS}" = xyes && 	_log_ "  - OCCP SNTS 	: yes " || _log_ "  - OCCP SNTS 	: no "


# identify SEE role :
#    simplex = see simplex
#   primary = see located on primary cloudmap
#   secondary = see located on secondary cloudmap
#   witness = see located on witness cloudmap
#   node = additionnal see node (3rd and more)
#   dynamicnode = additionnal see node added dynamicaly in case of elasticity scaleout
# identify LB role :
#   primary = http load balancer located on primary cloudmap
#   secondary = http load balancer located on secondary cloudmap
# identify WEBRTC role:
#   any combination of signaling-sip-storage

SEE_ROLE=${1}
LB_ROLE=${2}
WEBRTC_ROLE=${3}
RSLMF_ID=${4}
RSORF_ID=${5:-${RSLMF_ID}}
case ${NIVR_DB_TYPE} in
    mysql)
	DB_DRIVER=--nivr-mysql
	;;
    oracle)
	DB_DRIVER=--nivr-ojdbc
	;;
    *)
	_fail_ "NIVR SEE database type "${NIVR_DB_TYPE}" unknown"
	;;
esac
case ${RS_DB_TYPE} in
    mysql)
	RS_DB_DRIVER=--rs-mysql
	;;
    oracle)
	RS_DB_DRIVER=--rs-ojdbc
	;;
    *)
	_fail_ "NIVR SEE RS database type "${RS_DB_TYPE}" unknown"
	;;
esac

case ${SEE_ROLE} in
	simplex)
	erase_bundle &&
	install_see &&
	install_nivr &&
	start_db &&
	configure_see &&
	configure_applications &&
	init_db && sudo /opt/OC/sbin/_nivr-nfv-data-provisioning.sh &&
	start_applications ||
	_fail_ "NIVR SEE "${SEE_ROLE}" setup"
	;;

    primary)
	erase_bundle &&
	install_see &&
	install_nivr &&
	start_db &&
	configure_corosync &&
	configure_see &&
	configure_applications &&
	configure_http_lb &&
	init_db && sudo /opt/OC/sbin/_nivr-nfv-data-provisioning.sh &&
	start_applications ||
	_fail_ "NIVR SEE "${SEE_ROLE}" setup"
	;;

    secondary)
	erase_bundle &&
	install_see &&
	install_nivr &&
	configure_corosync &&
	configure_see &&
	configure_applications &&
	configure_http_lb &&
	start_applications ||
	_fail_ "NIVR SEE "${SEE_ROLE}" setup"
	;;

    witness)
	SIP_CONNECTIVITY= &&
	NIVR_BUNDLE= &&
	erase_bundle &&
	install_see &&
	configure_corosync &&
	configure_see ||
	_fail_ "NIVR SEE "${SEE_ROLE}" setup"
	;;

    node)
	erase_bundle &&
	install_see &&
	install_nivr &&
	configure_corosync &&
	configure_see &&
	configure_applications &&
	configure_http_lb &&
	start_applications ||
	_fail_ "NIVR SEE "${SEE_ROLE}" setup"
	;;

    *)
	echo _fail_ "NIVR SEE role "${SEE_ROLE}" unknown"
	;;
esac

exit 0
