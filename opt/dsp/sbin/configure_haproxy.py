#!/usr/bin/env python
""" Configures and runs haproxy
    for testign purposed "dsp-lb1" is being configured
    as app server listening on 192.168.122.221:8000/8001   
"""

import _mypath
import socket
import os
import re
import subprocess
import ip_interface
from string import Template
from logger import logger
import shutil

HOSTNAME_KEY = r"-lb1$"
HAPROXY_PRE_COMMANDS_FILE="templates/haproxy_commands"
this_dir = os.path.dirname(os.path.abspath(__file__))
command_templ_file = os.path.join(this_dir, HAPROXY_PRE_COMMANDS_FILE)

SERVER_TEMPL="templates/backend_server"
HAPROXYCONF_TEMPL="templates/haproxy.cfg"
HAPROXYCONF_TEMPL_UPDATED="templates/haproxy.cfg.u"
HAPROXYCONF_FILE="/etc/haproxy/haproxy.cfg"
HAPROXYCONF_BACKUP="/etc/haproxy/haproxy.cfg.bk"

APP_SERVER1="simple_http_server1/server1.py"
APP_SERVER2="simple_http_server2/server2.py"

this_dir = os.path.dirname(os.path.abspath(__file__))
haproxy_templ_file = os.path.join(this_dir, HAPROXYCONF_TEMPL)
haproxy_templ_updated = os.path.join(this_dir, HAPROXYCONF_TEMPL_UPDATED)
haproxy_file = os.path.join(this_dir, HAPROXYCONF_FILE)
haproxy_backup = os.path.join(this_dir, HAPROXYCONF_BACKUP)
server_templ_file = os.path.join(this_dir, SERVER_TEMPL)
app1= os.path.join(this_dir, APP_SERVER1)
app2 = os.path.join(this_dir, APP_SERVER2)


def get_host_port():
    """a generator of (host, port) tuple
    we are configuring 192.168.122.221 as app server for testing"""
    yield "192.168.122.221", "8000"
    yield "192.168.122.221", "8001"

def backup_haproxy():
    """ backsup haproxy conf file"""
    try:
        shutil.copyfile(haproxy_file, haproxy_backup)
        return True
    except:
        return False

def haproxy_templ_copy_for_update():
    """copies the template file for updating with server info"""
    try:
        shutil.copyfile(haproxy_templ_file, haproxy_templ_updated) 
        return True
    except:
        logger.debug("ERROR copying template file for updating")
        return False

def get_template_updated(ho=None, po=None):
    """updates the template with (host, port)
    and returns server config string"""
    templ=None
    server_string=None
    with open(server_templ_file, "r") as f:
        templ = Template(f.read())
    if templ:
        server_string = templ.substitute(host=ho, port=po)
    if server_string:
        return server_string
    else:
        logger.debug("ERROR server string None") 
        return None

def append_server_string(ss=None):
    """update server string in the configuration file"""
    if ss:
        with open(haproxy_templ_updated, "a") as f:
            f.write("    " + ss)
    else:
        logger.debug("ERROR: server string None")


def copy_updated_file():
    """copies updated file"""
    try:
        shutil.copyfile(haproxy_templ_updated, haproxy_file)
        return True
    except:
        return False

def restart_haproxy():
    """restarts haproxy to update conf file"""
    try:
        subprocess.check_call(["/etc/init.d/haproxy", "restart"])
    except:
        logger.debug("ERROR restarting haproxy")


def run_apps():
    """runs dummy http servers on app server"""
    try:
        os.system(app1+" &")
    except Exception, e:
        pass
    try:
        os.system(app2+" &")
    except Exception, e:
        pass


def enable_iptables(itf=None):
    """runs iptables commands to enable vrrp"""
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


    

if __name__ == '__main__':
    """ runs two dummy http servers on *-lb1 
    configures these servers in haproxy.cfg
    runs haproxy iptables commands to enable 
    access to port 80
    runs haproxy given keepalived running"""

    ipaddr = ip_interface.get_ip_address()
    interface = ip_interface.get_interface_name(ipaddr)

    proceed=None
    try:
        match_pattern = re.compile(r"\S+" + HOSTNAME_KEY)
        proceed = match_pattern.match(socket.gethostname())
    except Exception, e:
        print('stack trace:', str(e))
        raise Exception("error accessing app server machine")

    if not proceed:
        logger.debug("its not an app server")
    else:
        run_apps()
        enable_iptables(itf=interface)


    if not backup_haproxy():
        logger.debug("ERROR backing up haproxy conf file")
        exit(1)
    if not haproxy_templ_copy_for_update():
        logger.debug("ERROR backing up haproxy TEMPL file")
        exit(1)
    for host, port in get_host_port():
        print("host:", host, "port:", port)
        server_string = get_template_updated(ho=host, po=port)
        print("server string:", server_string)
        append_server_string(ss=server_string)
    if not copy_updated_file():
        logger.debug("ERROR copying updated templ file to conf")
        exit(1)
    restart_haproxy()
