#!/bin/bash
set -e

# set defaults
tmp="/root/"

clear

# check for root privilege
if [ "$(id -u)" != "0" ]; then
   echo " this script must be run as root" 1>&2
   echo
   exit 1
fi

# define download function
# courtesy of http://fitnr.com/showing-file-download-progress-using-wget.html
download()
{
    local url=$1
    echo -n "    "
    wget --progress=dot $url 2>&1 | grep --line-buffered "%" | \
        sed -u -e "s,\.,,g" | awk '{printf("\b\b\b\b%4s", $2)}'
    echo -ne "\b\b\b\b"
    echo " DONE"
}

# determine ubuntu version
ubuntu_version=$(lsb_release -cs)

# check for interactive shell

# print status message
echo " preparing your server; this may take a few minutes ..."

# set fqdn
fqdn="$hostname.$domain"

# update hostname
echo "$hostname" > /etc/hostname
sed -i "s@ubuntu.ubuntu@$fqdn@g" /etc/hosts
sed -i "s@ubuntu@$hostname@g" /etc/hosts
hostname "$hostname"

# update repos
apt-get -y update
apt-get -y upgrade
apt-get -y dist-upgrade
apt-get -y autoremove
apt-get -y purge

# INSTALL K8S
apt-get install apt-transport-https ca-certificates curl software-properties-common

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

apt-get update && apt-get install docker-ce=18.06.2~ce~3-0~ubuntu

cat > /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF

mkdir -p /etc/systemd/system/docker.service.d

# Restart docker.
systemctl daemon-reload
systemctl restart docker

# Install prerequisites
cat > /etc/sysctl.d/99-kubernetes-cri.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

sysctl --system
apt-get install software-properties-common

add-apt-repository ppa:projectatomic/ppa
apt-get update

# Install CRI-O
apt-get install cri-o-1.12

systemctl start crio

# Install K8S
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
deb https://apt.kubernetes.io/ kubernetes-xenial main
EOF

apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

sudo swapoff -a


# remove myself to prevent any unintended changes at a later stage
rm $0

# finish
echo " DONE; rebooting ... "

# reboot
reboot