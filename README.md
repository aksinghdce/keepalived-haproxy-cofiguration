# keepalived-haproxy-cofiguration
The code to install keepalived and haproxy on RHEL 6. The code also configures the duo.

The scripts are invoked by etc/init.d/haproxy-keepalived init script. This script is invoked in run level 3.
The script works in KVM VM with redhat linux installed.

The set of scripts install haproxy and keepalived. The dependencies get installed from /var/opt/dsp/images/lb.
