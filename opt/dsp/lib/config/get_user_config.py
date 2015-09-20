#!/usr/bin/env python
"""
author: aks
get user data from heat template. This data is available in a device that has 
LABEL='config-2'
"""

import _mypath
from logger import logger
import os
import subprocess
from sys import stdout
from subprocess import CalledProcessError

MOUNT_POINT = '/mnt/config_heat'
PROPERTY_FILE = 'openstack/latest/user_data'

def get_user_data():
    """
    runs blkid command and gets the device to be mounted.
    this device has the user-data coming from heat template
    """
    logger.info('get user-config device')
    dev = None
    try:
        #cmd = 'blkid -t LABEL="config-2" -odevice'
        cmd = 'blkid -t TYPE="ext4" -odevice'
        proc = subprocess.Popen(cmd.split(), stdout=subprocess.PIPE)
        dev = proc.stdout.readlines()
    except CalledProcessError:
        print("error running blkid")

    if dev:
        dev = dev[0].rstrip()
    else:
        print('no such device')
    return dev

def mount_user_config_device(dev=None):
    """ mounts the supplied device. Returns False if not mounted"""
    result = subprocess.Popen(['mkdir', '-p', MOUNT_POINT], stdout=subprocess.PIPE)
    subprocess.Popen(['umount', MOUNT_POINT], stdout=subprocess.PIPE)
    result2 = result and subprocess.Popen(['mount', dev, MOUNT_POINT], stdout=subprocess.PIPE)
    return result

def get_property(subpath=None):
    '''
    Get properties populated in dictionary. Returns the populated dictionary
    '''
    properties_list = None
    properties_dict = dict()
    if os.path.exists(subpath):
        with open(subpath, 'r') as f:
            properties_list = f.read().split(';')
            for entry in properties_list:
                k, v = entry.split('=', 1)
                properties_dict[k] = v
    else:
        logger.debug("ERROR: path doesn't exist")
    return properties_dict

def update_property_file(properties=None):
    """update the property file with contents from heat-template-user-metadata"""
    pass
        
if __name__ == '__main__':
    device = get_user_data()
    try:
        result = mount_user_config_device(dev=device)
        if result:
            logger.info('heat meta-data mounted')
        else:
            logger.info('heat meta-data NOT mounted')
    except:
        logger.debug('ERROR: loading user-config metadata block device')

    logger.info('heat meta-data available')
    properties = get_property(subpath=os.path.join(MOUNT_POINT,PROPERTY_FILE))
