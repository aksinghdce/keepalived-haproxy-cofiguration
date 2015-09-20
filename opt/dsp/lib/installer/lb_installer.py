#!/usr/bin/env python
"""
install load balancer RPMs if the hostname has "*lb*" in it
"""
import socket
import os.path
import re
import subprocess
import _mypath
from logger import logger

logger.info("logging in lb_installer")

RPM_PATH = "/var/opt/dsp/images/lb/"
KEEPALIVED_DEPS_PATH = RPM_PATH + "keepalived_deps/"
PYTHON_DEPS_PATH = RPM_PATH + "python_deps/"
DEP_RPMS = ["net-snmp-5.5-54.el6.x86_64.rpm",
             "net-snmp-libs-5.5-54.el6.x86_64.rpm",
             "lm_sensors-3.1.1-17.el6.x86_64.rpm",
              "lm_sensors-libs-3.1.1-17.el6.x86_64.rpm"]
PYTHON_RPMS = ["python-netifaces-0.5-1.el6.x86_64.rpm"]
RPMS = ['haproxy-1.5.2-2.el6.x86_64.rpm', 'keepalived-1.2.13-4.el6.x86_64.rpm']

DEP_RPMS_PATH = [KEEPALIVED_DEPS_PATH + deps for deps in DEP_RPMS]
DEP_RPMS_PATH.extend([PYTHON_DEPS_PATH + deps for deps in PYTHON_RPMS])
RPMS_PATH = [RPM_PATH + rpm for rpm in RPMS]

ALL_RPMS_PATH = list()

HOSTNAME_KEY = r"-lb[0-9]+$"

def get_rpms_list():
    DEP_RPMS_PATH.extend(RPMS_PATH)
    ALL_RPMS_PATH = DEP_RPMS_PATH
    return ALL_RPMS_PATH

class InstallLoadBalancer:
    """
    installs load balancer rpms idempotently if the hostname has "*lb*"
    """
    def __init__(self, all_rpms_path=""):
        if not all_rpms_path:
            raise ValueError
        self.all_rpms_path = all_rpms_path
        
    def check_hostname(self):
        """
        check is the hostname is suitable to install the load balancer rpms
        """
        try:
            self.hostname = socket.gethostname()
            print("hostname:", self.hostname, "all_rpms_path:", self.all_rpms_path)
        except:
            raise Exception("problem with getting hostname")
        
        try:
            match_pattern = re.compile(r"\S+" + HOSTNAME_KEY)
            proceed = match_pattern.match(self.hostname)
            if not proceed:
                raise Exception("its not a load balancer machine")
            return True
        except:
            raise Exception("not a load balancer machine")
        
        return False
        
    def check_rpms(self):
        """
        check is rpms exist and if they are already installed.
        If already installed, then nothing needs to be done.
        """
        try:
            for files in self.all_rpms_path:
                if not os.path.exists(files):
                    raise IOError
            return True
        except:
            raise Exception("RPMs do not exist")
        
        return False
        
    def install_rpms(self):
        """
        install rpms
        """
        if self.check_hostname() and self.check_rpms():
            for name in self.all_rpms_path:
                try:
                    subprocess.check_call(["rpm", "-q", name[:-4]])
                except:
                    print(name, "is not installed, instlling now")
                    try:
                        subprocess.check_call(["rpm", "-ivh", name])
                    except:
                        print("rpm:", name, " could not be installed")
            print("rpms installed")

def install():
    """installs all the dependencies"""
    installer = InstallLoadBalancer(all_rpms_path = get_rpms_list())
    installer.install_rpms()
    
if __name__ == '__main__':
    install()
