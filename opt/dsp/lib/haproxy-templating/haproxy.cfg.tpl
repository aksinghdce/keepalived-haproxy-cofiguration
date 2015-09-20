global
    daemon
    maxconn 256

defaults
    mode http
    timeout connect 5000ms
    timeout client 50000ms
    timeout server 50000ms

frontend http-in
    bind *:80
    default_backend servers

backend servers
    server server1 192.168.122.221:8000 maxconn 32
    server server2 192.168.122.221:8001 maxconn 32
