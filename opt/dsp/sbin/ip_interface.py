#!/usr/bin/env python
"""utility functions for ip address and interfaces"""

import _mypath
from logger import logger
import os
import subprocess
import netifaces

this_dir = os.path.dirname(os.path.abspath(__file__))

def get_nonlocal_interface():
    """get non local interface to be configured"""
    itf = netifaces.interfaces()
    print("interfaces:", itf)
    for i in itf:
        try:
            addr = netifaces.ifaddresses(i)[netifaces.AF_INET][0]['addr']
            if addr == "127.0.0.1":
                continue
            else:
                return i
        except:
            return i
    return None

def configure_interface_ip(intf=None, ip=None):
    """configures ip address for non-local interface"""
    cmd = "/sbin/ifconfig" + " " + intf + " " + ip + " up"
    try:
        os.system(cmd)
    except Exception, e:
        logger.debug(str(e))

def get_ip_address():
    """reads ip address from property file"""
    return "192.168.122.221"

def get_interface_name(ip_addr):
    """given ip address, get the interface name"""
    cmd = str(os.path.join(this_dir, "get_if.out")) + " " + ip_addr
    eth = subprocess.Popen(cmd.split(), stdout=subprocess.PIPE)
    interface = eth.stdout.read().rstrip()
    print('interface:', interface)
    return interface

def get_floating_ip():
    """returns floating ip"""
    return "192.168.122.220"

if __name__ == '__main__':
    ipaddr = get_ip_address()
    non_local_if = get_nonlocal_interface()
    if non_local_if:
        configure_interface_ip(intf=non_local_if, ip=ipaddr)
    else:
        print("ERROR getting nonlocal interface")
