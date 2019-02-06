FROM fedora:26

RUN dnf update -y
RUN dnf install -y openvpn
RUN dnf install -y net-tools
RUN dnf install -y iptables iproute
RUN dnf install -y wget
COPY server.conf /etc/openvpn/
COPY client-connect /usr/local/bin/

CMD \
  /usr/sbin/openvpn \
    --status /run/openvpn/server.status 10 \
    --cd /etc/openvpn \
    --config /etc/openvpn/server.conf

