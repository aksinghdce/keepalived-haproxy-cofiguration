#!/usr/bin/env python
"""Configures keepalived on node to work with peer lb server"""

import _mypath
from logger import logger
import os
import subprocess
from string import Template
import ip_interface
import shutil

this_dir = os.path.dirname(os.path.abspath(__file__))

KEEPALIVED_CONF_FILE = "/etc/keepalived/keepalived.conf"
KEEPALIVED_CONF_BACKUP = "/etc/keepalived/keepalived.conf.bk"
KEEPALIVED_PRE_COMMANDS=None
KEEPALIVED_PRE_COMMANDS_FILE="templates/keepalived_commands"
KEEPALIVED_TEMPL_FILE = "templates/keepalived.conf"

def is_keepalived_installed():
    """checks if keepalived is installed and configurable.
    by configurable we mean the iptables are set for VRRP"""
    if not os.path.exists("/etc/init.d/keepalived"):
        return False
    else:
        return True


def get_keepalived_template():
    """gets the keepalived template file"""
    keepalived_templ_file = os.path.join(this_dir, KEEPALIVED_TEMPL_FILE) 
    ka_templ = None
    try:
        with open(keepalived_templ_file, 'r') as f:
            ka_templ = Template(f.read())
    except:
        logger.debug("keepalived template file NOT read")
    return ka_templ



def configure_template(itf=None, flt=None):
    """configures ip address"""
    template = get_keepalived_template()
    conf = None
    if itf and flt:
        conf = template.substitute(interface=itf, floating_ip=flt)
        print('template:', conf)
    else:
        print('itf is None')
    return conf

def backup_keepalived_conf():
    """backs up the keepalived configuration file"""
    try:
        shutil.copyfile(KEEPALIVED_CONF_FILE, KEEPALIVED_CONF_BACKUP)
        return True
    except:
        raise ValueError

def configure_keepalived(conf=None):
    """configures keepalived by getting vip from haproxy config"""
    if not conf:
        logger.debug("conf is None")
        exit(1)
    with open(KEEPALIVED_CONF_FILE, "w") as f:
        try:
            f.write(conf)
        except:
            logger.debug("ERROR writing keepalived conf file")

def run_pre_configuration_commands(itf=None):
    """runs iptables commands to enable vrrp"""
    command_templ_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), KEEPALIVED_PRE_COMMANDS_FILE)
    cmd_templ=None
    cmds=None
    if os.path.exists(command_templ_file):
        logger.info("command file exists")
    else:
        logger.debug("command file doesn't exist")
        exit(1)
    with open(command_templ_file, "r") as f:
        cmd_templ = Template(f.read())
    if itf:
        cmds = cmd_templ.substitute(interface=itf)
    else:
        logger.debug("Interface is None")
    if cmds:
        cmds = cmds.splitlines()
        for line in cmds:
            line.rstrip()
            try:
                cmd = line.split()
                print('cmd:', cmd)
                subprocess.check_call(cmd)
            except:
                logger.debug("ERROR running iptables command")
    else:
        logger.debug("ERROR getting cmds")

def restart_keepalived():
    """restarts keepalived and checks for success"""
    try:
        subprocess.check_call(["/etc/init.d/keepalived", "restart"])
    except:
        logger.debug("ERROR restarting keepalived")

if __name__ == '__main__':
    if not is_keepalived_installed():
        logger.debug("keepalived not installed")
        exit(1)
    ipaddr = ip_interface.get_ip_address()
    interface = ip_interface.get_interface_name(ipaddr)
    run_pre_configuration_commands(itf=interface)
    floating_ip = ip_interface.get_floating_ip()
    ha_conf = configure_template(itf=interface, flt=floating_ip)
    if not ha_conf:
        logger.debug("ha_conf is None returned")
    if os.path.exists(KEEPALIVED_CONF_FILE):
        try:
            try:
                backup_keepalived_conf()
            except:
                logger.debug("ERROR backing up haproxy conf")
            configure_keepalived(conf=ha_conf)
        except:
            logger.debug("haproxy write problem")
    else:
        logger.debug("conf file not found")
        configure_keepalived(conf=ha_conf)
    restart_keepalived()
