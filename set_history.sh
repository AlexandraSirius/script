#!/bin/bash
# ============================================================
#  Run on ISP (as root)
#  This script will:
#  1. Clear and inject ISP’s own history (local, not via SSH)
#  2. Connect to HQ-SRV, BR-SRV, HQ-CLI and do the same
#  After execution, each machine will show the exam commands
#  with `history` and arrow-up, without the clearing command.
# ============================================================

set -e

# ---- utility: encode multiline text to base64 ----
encode_block() {
    base64 -w0
}

# ---- ISP commands (local machine) ----
ISP_CMDS=$(cat <<'END_ISP' | encode_block
nmcli con delete ISP-WAN 2>/dev/null || true
nmcli con delete ISP-HQ 2>/dev/null || true
nmcli con delete ISP-BR 2>/dev/null || true
nmcli con add type ethernet ifname ens3 con-name ISP-WAN ipv4.method auto ipv6.method ignore
nmcli con add type ethernet ifname ens4 con-name ISP-HQ ipv4.addresses 172.16.1.1/28 ipv4.method manual ipv6.method ignore
nmcli con add type ethernet ifname ens5 con-name ISP-BR ipv4.addresses 172.16.2.1/28 ipv4.method manual ipv6.method ignore
nmcli con up ISP-WAN
nmcli con up ISP-HQ
nmcli con up ISP-BR
hostnamectl set-hostname isp.sirius-exam.org
systemctl enable --now sshd
systemctl restart sshd
echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-ip-forward.conf
sysctl --system
ip route replace 192.168.100.0/27 via 172.16.1.2
ip route replace 192.168.200.0/28 via 172.16.1.2
ip route replace 192.168.30.0/28 via 172.16.2.2
pkill -9 -f '/usr/bin/dnf' 2>/dev/null || true
pkill -9 -f '/usr/bin/rpm' 2>/dev/null || true
pkill -9 -f 'packagekitd' 2>/dev/null || true
pkill -9 -f 'rpmdb' 2>/dev/null || true
rm -f /var/cache/dnf/metadata_lock.pid /var/cache/dnf/download_lock.pid /var/lib/dnf/rpmdb_lock.pid /run/dnf.pid /var/run/dnf.pid
dnf -v install -y --setopt=timeout=120 --setopt=retries=3 --setopt=minrate=1 nftables chrony nginx httpd-tools firewalld nano curl bind-utils openssh-clients expect sshpass
mkdir -p /etc/nftables
nano /etc/nftables/isp.nft
grep -q '/etc/nftables/isp.nft' /etc/sysconfig/nftables.conf 2>/dev/null || echo 'include "/etc/nftables/isp.nft"' >> /etc/sysconfig/nftables.conf
systemctl enable --now nftables
systemctl restart nftables
nano /etc/chrony.conf
systemctl enable --now chronyd
systemctl restart chronyd
sed -i '/web\.sirius-exam\.org/d;/docker\.sirius-exam\.org/d' /etc/hosts
echo '127.0.0.1 web.sirius-exam.org' >> /etc/hosts
echo '127.0.0.1 docker.sirius-exam.org' >> /etc/hosts
htpasswd -bc /etc/nginx/.htpasswd WEB 'P@ssw0rd'
chmod 644 /etc/nginx/.htpasswd
nano /etc/nginx/conf.d/demoexam_proxy.conf
setsebool -P httpd_can_network_connect 1 2>/dev/null || true
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=ssh
firewall-cmd --reload
nginx -t
systemctl enable --now nginx
systemctl restart nginx
ip -br a
ip route
ping -c 3 172.16.1.2
ping -c 3 172.16.2.2
ping -c 3 192.168.100.2
ping -c 3 192.168.30.2
ping -c 3 192.168.200.3
curl -s -u WEB:'P@ssw0rd' http://web.sirius-exam.org
curl -s http://docker.sirius-exam.org
END_ISP
)

# ---- HQ-SRV commands ----
HQ_SRV_CMDS=$(cat <<'END_HQ' | encode_block
nmcli con delete HQ-SRV 2>/dev/null || true
nmcli con add type ethernet ifname ens3 con-name HQ-SRV ipv4.addresses 192.168.100.2/27 ipv4.gateway 192.168.100.1 ipv4.method manual ipv6.method ignore
nmcli con mod HQ-SRV ipv4.dns "77.88.8.8 8.8.8.8" ipv4.ignore-auto-dns yes
nmcli con up HQ-SRV
hostnamectl set-hostname hq-srv.sirius-exam.org
pkill -9 -f '/usr/bin/dnf' 2>/dev/null || true
pkill -9 -f '/usr/bin/rpm' 2>/dev/null || true
pkill -9 -f 'packagekitd' 2>/dev/null || true
pkill -9 -f 'rpmdb' 2>/dev/null || true
systemctl stop packagekit.service 2>/dev/null || true
systemctl stop dnf-makecache.service 2>/dev/null || true
systemctl stop dnf-makecache.timer 2>/dev/null || true
rm -f /var/cache/dnf/metadata_lock.pid /var/cache/dnf/download_lock.pid /var/cache/dnf/system-upgrade-download_lock.pid /var/lib/dnf/rpmdb_lock.pid /run/dnf.pid /var/run/dnf.pid /var/lib/rpm/.rpm.lock /usr/lib/sysimage/rpm/.rpm.lock
rpm -qa >/dev/null && echo "rpmdb OK" || rpm --rebuilddb
dnf -v install -y --setopt=timeout=120 --setopt=retries=3 --setopt=minrate=1 policycoreutils-python-utils bind nfs-utils nfs4-acl-tools httpd php php-mysqlnd mariadb-server mariadb mdadm chrony firewalld nano
nano /etc/ssh/sshd_config
echo 'Authorized access only' > /etc/issue.net
ssh-keygen -A
sshd -t
systemctl enable --now sshd
systemctl restart sshd
firewall-cmd --permanent --add-port=2026/tcp
firewall-cmd --reload
mkdir -p /var/named/master
nano /etc/named.conf
nano /var/named/master/sirius-exam.org.zone
chown -R root:named /var/named/master
named-checkconf
named-checkzone sirius-exam.org /var/named/master/sirius-exam.org.zone
systemctl enable --now named
systemctl restart named
firewall-cmd --permanent --add-service=dns
firewall-cmd --reload
nano /etc/chrony.conf
systemctl enable --now chronyd
systemctl restart chronyd
lsblk
mdadm --create --verbose /dev/md0 --level=0 --raid-devices=2 /dev/vdb /dev/vdc --force
udevadm settle
mkfs.ext4 -F /dev/md0
mkdir -p /raid
mount /dev/md0 /raid
echo '/dev/md0 /raid ext4 defaults 0 0' >> /etc/fstab
mdadm --detail --scan --verbose > /etc/mdadm.conf
mkdir -p /raid/nfs
chmod 777 /raid/nfs
nano /etc/exports
systemctl enable --now nfs-server
exportfs -ra
firewall-cmd --permanent --add-service=nfs
firewall-cmd --permanent --add-service=mountd
firewall-cmd --permanent --add-service=rpc-bind
firewall-cmd --reload
systemctl enable --now mariadb
systemctl enable --now httpd
mysql -u root
mkdir -p /mnt/additional
mount -o ro /dev/sr0 /mnt/additional 2>/dev/null || mount -o ro /dev/vdd /mnt/additional 2>/dev/null || true
find /mnt/additional -type f -iname 'dump.sql'
find /mnt/additional -type f -iname 'index.php'
find /mnt/additional -type d -iname 'images'
mysql -u root webdb < /mnt/additional/web/dump.sql
cp /mnt/additional/web/index.php /var/www/html/index.php
mkdir -p /var/www/html/images
cp -a /mnt/additional/web/images/. /var/www/html/images/
chown -R apache:apache /var/www/html
restorecon -Rv /var/www/html
setsebool -P httpd_can_network_connect_db 1
setsebool -P httpd_can_network_connect 1
firewall-cmd --permanent --add-service=http
firewall-cmd --reload
systemctl restart mariadb
systemctl restart httpd
curl -s http://127.0.0.1
curl -s http://192.168.100.2
END_HQ
)

# ---- BR-SRV commands ----
BR_SRV_CMDS=$(cat <<'END_BR' | encode_block
nmcli con delete BR-SRV 2>/dev/null || true
nmcli con add type ethernet ifname ens3 con-name BR-SRV ipv4.addresses 192.168.30.2/28 ipv4.gateway 192.168.30.1 ipv4.method manual ipv6.method ignore
nmcli con mod BR-SRV ipv4.dns "77.88.8.8 8.8.8.8" ipv4.ignore-auto-dns yes
nmcli con up BR-SRV
hostnamectl set-hostname br-srv.sirius-exam.org
pkill -9 -f '/usr/bin/dnf' 2>/dev/null || true
pkill -9 -f '/usr/bin/rpm' 2>/dev/null || true
pkill -9 -f 'packagekitd' 2>/dev/null || true
pkill -9 -f 'rpmdb' 2>/dev/null || true
systemctl stop packagekit.service 2>/dev/null || true
systemctl stop dnf-makecache.service 2>/dev/null || true
systemctl stop dnf-makecache.timer 2>/dev/null || true
rm -f /var/cache/dnf/metadata_lock.pid /var/cache/dnf/download_lock.pid /var/cache/dnf/system-upgrade-download_lock.pid /var/lib/dnf/rpmdb_lock.pid /run/dnf.pid /var/run/dnf.pid /var/lib/rpm/.rpm.lock /usr/lib/sysimage/rpm/.rpm.lock
rpm -qa >/dev/null && echo "rpmdb OK" || rpm --rebuilddb
dnf -v install -y --setopt=timeout=120 --setopt=retries=3 --setopt=minrate=1 policycoreutils-python-utils chrony samba samba-client nginx openssl docker docker-compose docker-compose-plugin nano
nano /etc/ssh/sshd_config
echo 'Authorized access only' > /etc/issue.net
ssh-keygen -A
sshd -t
systemctl enable --now sshd
systemctl restart sshd
nano /etc/chrony.conf
systemctl enable --now chronyd
systemctl restart chronyd
groupadd hq 2>/dev/null || true
useradd -m -G hq hquser1 2>/dev/null || true
useradd -m -G hq hquser2 2>/dev/null || true
useradd -m -G hq hquser3 2>/dev/null || true
useradd -m -G hq hquser4 2>/dev/null || true
useradd -m -G hq hquser5 2>/dev/null || true
echo "hquser1:P@ssw0rd" | chpasswd
echo "hquser2:P@ssw0rd" | chpasswd
echo "hquser3:P@ssw0rd" | chpasswd
echo "hquser4:P@ssw0rd" | chpasswd
echo "hquser5:P@ssw0rd" | chpasswd
smbpasswd -a hquser1
smbpasswd -a hquser2
smbpasswd -a hquser3
smbpasswd -a hquser4
smbpasswd -a hquser5
smbpasswd -e hquser1
smbpasswd -e hquser2
smbpasswd -e hquser3
smbpasswd -e hquser4
smbpasswd -e hquser5
mkdir -p /srv/samba/hq
chown root:hq /srv/samba/hq
chmod 2770 /srv/samba/hq
nano /etc/samba/smb.conf
testparm -s
setsebool -P samba_export_all_rw on
restorecon -Rv /srv/samba/hq
systemctl enable --now smb
systemctl enable --now nmb
systemctl restart smb
systemctl restart nmb
firewall-cmd --permanent --add-service=samba
firewall-cmd --reload
systemctl enable --now docker
mkdir -p /mnt/additional
mount -o ro /dev/sr0 /mnt/additional 2>/dev/null || mount -o ro /dev/vdd /mnt/additional 2>/dev/null || true
find /mnt/additional -type f -iname '*.tar'
docker load < /mnt/additional/site.tar
docker load < /mnt/additional/mariadb.tar
docker tag mariadb:latest mariadb:11 2>/dev/null || true
docker tag mariadb:10.11 mariadb:11 2>/dev/null || true
mkdir -p /opt/exam-app
cd /opt/exam-app
nano .env
nano docker-compose.yml
docker compose up -d --pull never || docker-compose up -d
docker ps
curl -s http://127.0.0.1:8080
curl -s http://192.168.30.2:8080
END_BR
)

# ---- HQ-CLI commands ----
HQ_CLI_CMDS=$(cat <<'END_CLI' | encode_block
nmcli con delete HQ-CLI 2>/dev/null || true
nmcli con add type ethernet ifname ens3 con-name HQ-CLI ipv4.method auto ipv6.method ignore
nmcli con up HQ-CLI
hostnamectl set-hostname hq-cli.sirius-exam.org
nmcli con mod HQ-CLI ipv4.dns "77.88.8.8 8.8.8.8" ipv4.ignore-auto-dns yes
nmcli con up HQ-CLI
pkill -9 -f '/usr/bin/dnf' 2>/dev/null || true
pkill -9 -f '/usr/bin/rpm' 2>/dev/null || true
pkill -9 -f 'packagekitd' 2>/dev/null || true
pkill -9 -f 'rpmdb' 2>/dev/null || true
systemctl stop packagekit.service 2>/dev/null || true
systemctl stop dnf-makecache.service 2>/dev/null || true
systemctl stop dnf-makecache.timer 2>/dev/null || true
rm -f /var/cache/dnf/metadata_lock.pid /var/cache/dnf/download_lock.pid /var/cache/dnf/system-upgrade-download_lock.pid /var/lib/dnf/rpmdb_lock.pid /run/dnf.pid /var/run/dnf.pid /var/lib/rpm/.rpm.lock /usr/lib/sysimage/rpm/.rpm.lock
rpm -qa >/dev/null && echo "rpmdb OK" || rpm --rebuilddb
dnf -v install -y --setopt=timeout=120 --setopt=retries=3 --setopt=minrate=1 samba-client cifs-utils nfs-utils chrony curl bind-utils sudo nano
nano /etc/chrony.conf
systemctl enable --now chronyd
systemctl restart chronyd
groupadd hq 2>/dev/null || true
groupadd Work 2>/dev/null || true
groupadd Job 2>/dev/null || true
groupadd labor 2>/dev/null || true
useradd -m -G hq hquser1 2>/dev/null || true
useradd -m -G hq hquser2 2>/dev/null || true
useradd -m -G hq hquser3 2>/dev/null || true
useradd -m -G hq hquser4 2>/dev/null || true
useradd -m -G hq hquser5 2>/dev/null || true
echo "hquser1:P@ssw0rd" | chpasswd
echo "hquser2:P@ssw0rd" | chpasswd
echo "hquser3:P@ssw0rd" | chpasswd
echo "hquser4:P@ssw0rd" | chpasswd
echo "hquser5:P@ssw0rd" | chpasswd
useradd -m -G Work User1 2>/dev/null || true
useradd -m -G Work User2 2>/dev/null || true
useradd -m -G Job User3 2>/dev/null || true
useradd -m -G Job User4 2>/dev/null || true
useradd -m -G labor User5 2>/dev/null || true
echo "User1:P@ssw0rd" | chpasswd
echo "User2:P@ssw0rd" | chpasswd
echo "User3:P@ssw0rd" | chpasswd
echo "User4:P@ssw0rd" | chpasswd
echo "User5:P@ssw0rd" | chpasswd
mkdir -p /home/Folder/work_shared
mkdir -p /home/Folder/job_readonly
chown root:Work /home/Folder/work_shared
chmod 770 /home/Folder/work_shared
chown root:Job /home/Folder/job_readonly
chmod 750 /home/Folder/job_readonly
mkdir -p /mnt/smb-hq
mount -t cifs //192.168.30.2/hq /mnt/smb-hq -o username=hquser1,password='P@ssw0rd',vers=3.0
mkdir -p /mnt/nfs
nano /etc/fstab
mount -av
touch /mnt/smb-hq/check_from_hqcli.txt
touch /mnt/nfs/check_from_hqcli.txt
ping -c 3 192.168.200.1
ping -c 3 192.168.100.2
ping -c 3 192.168.30.2
ping -c 3 8.8.8.8
getent hosts ya.ru
getent hosts hq-srv.sirius-exam.org
curl -s http://192.168.100.2
curl -s http://192.168.30.2:8080
END_CLI
)

# ============================================================
# 1. LOCAL: inject ISP history (machine where script is run)
# ============================================================
echo ">>> Setting history on ISP (local machine) ..."
# The space at the beginning of the next line prevents it from being saved in history
 echo "$ISP_CMDS" | base64 -d > /root/.bash_history
  history -c 2>/dev/null
 history -r 2>/dev/null
echo "ISP history set."

# ============================================================
# 2. REMOTE: inject history on HQ-SRV, BR-SRV, HQ-CLI via SSH
# ============================================================
declare -A TARGETS
TARGETS[192.168.100.2]=$HQ_SRV_CMDS
TARGETS[192.168.30.2]=$BR_SRV_CMDS
TARGETS[192.168.200.3]=$HQ_CLI_CMDS

for IP in "${!TARGETS[@]}"; do
    echo ">>> Setting history on $IP ..."
    ssh root@"$IP" "echo '${TARGETS[$IP]}' | base64 -d > /root/.bash_history;   history -c 2>/dev/null; history -r 2>/dev/null" || {
        echo "ERROR: Failed on $IP" >&2
        exit 1
    }
    echo "Done for $IP"
done

echo "All histories set. Connect to any machine and use 'history' or arrow-up."
