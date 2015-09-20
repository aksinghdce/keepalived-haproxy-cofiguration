#!/usr/env/bin bash
LD_LIBRARY_PATH="/usr/lib/oracle/11.2/client64/lib:${LD_LIBRARY_PATH}"
export LD_LIBRARY_PATH
TNS_ADMIN="/etc/oracle"
export TNS_ADMIN
ORACLE_HOME="/usr/lib/oracle/11.2/client64"
export ORACLE_HOME

