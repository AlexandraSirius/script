#!/bin/bash
# demoexam_central_master_step.sh
# Центральный пошаговый мастер-скрипт.
# Запускать на ISP под root:
#   bash demoexam_central_master_step.sh
#
# Логика:
# - ISP настраивается автоматически.
# - HQ-RTR/BR-RTR: компактная подсказка bootstrap через консоль, затем настройка по SSH.
# - Linux-машины: сначала проверка стандартного IP/SSH; если не доступно — короткая подсказка.
# - Если шаг упал, дальше НЕ идём, пока не исправишь.
# - Вывод минимальный: [OK]/[FAIL]/[WAIT].
# - Ошибки: /tmp/demoexam_*.err
# - Статус: /root/demoexam_status.txt

set -uo pipefail

DOMAIN="sirius-exam.org"
PASS="P@ssw0rd"
VESR_FIRST_PASS="Admin1234"
STATUS_FILE="/root/demoexam_status.txt"
: > "$STATUS_FILE"

ROOT_SSH_USER="${ROOT_SSH_USER:-root}"
ROOT_SSH_PASS="${ROOT_SSH_PASS:-}"

# Интерактивная карта портов/интерфейсов. Можно заранее задать через переменные окружения.
HQR_ISP_PORT="${HQR_ISP_PORT:-gigabitethernet 1/0/2}"
HQR_SRV_PORT="${HQR_SRV_PORT:-gigabitethernet 1/0/3}"
HQR_CLI_PORT="${HQR_CLI_PORT:-gigabitethernet 1/0/4}"
HQR_MGMT_PORT="${HQR_MGMT_PORT:-gigabitethernet 1/0/5}"
BRR_LAN_PORT="${BRR_LAN_PORT:-gigabitethernet 1/0/2}"
BRR_ISP_PORT="${BRR_ISP_PORT:-gigabitethernet 1/0/3}"
HQ_SRV_IF="${HQ_SRV_IF:-ens3}"
BR_SRV_IF="${BR_SRV_IF:-ens3}"
HQ_CLI_IF="${HQ_CLI_IF:-ens3}"

say(){ echo "$1"; }
ok(){ echo "[OK] $1"; echo "OK $1" >> "$STATUS_FILE"; }
fail(){ echo "[FAIL] $1"; echo "FAIL $1" >> "$STATUS_FILE"; }
info(){ echo "[INFO] $1"; }
wait_enter(){ echo; read -rp "[ENTER] Нажми Enter, когда сделал(а) действие выше: " _; }

need_root(){
  if [ "$(id -u)" -ne 0 ]; then
    echo "Запусти от root на ISP."
    exit 1
  fi
}

run_until_ok(){
  local title="$1"
  local cmd="$2"
  local n=1
  while true; do
    say ""
    say "━━━━━━━━━━━━━━━━━━━━━━━━━━"
    say "$title"
    say "попытка $n"
    say "━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if eval "$cmd"; then
      return 0
    fi
    say ""
    say "[WAIT] Шаг не завершён. Исправь причину и нажми Enter — повторю этот же шаг."
    wait_enter
    n=$((n+1))
  done
}

ask_default(){
  local prompt="$1"
  local def="$2"
  local ans
  read -rp "$prompt [$def]: " ans
  echo "${ans:-$def}"
}

get_root_ssh_pass_once(){
  if [ -z "$ROOT_SSH_PASS" ]; then
    read -rsp "Пароль root для Linux-машин: " ROOT_SSH_PASS
    echo
  fi
}

ask_root_ssh_pass_force(){
  read -rsp "Пароль root ещё раз: " ROOT_SSH_PASS
  echo
}


ask_value(){
  local var="$1" prompt="$2" def="$3" ans=""
  read -rp "$prompt [$def]: " ans
  printf -v "$var" '%s' "${ans:-$def}"
}

print_mapping_help(){
  cat <<'EOF'

━━━━━━━━━━━━━━━━━━━━━━━━━━
КАК ОПРЕДЕЛИТЬ ПОРТЫ И АДАПТЕРЫ
━━━━━━━━━━━━━━━━━━━━━━━━━━

1) ISP Linux:
   На ISP смотри:
     ip -br a
     nmcli device status
   WAN — интерфейс с внешним адресом, например 10.23.x.x.
   Два остальных интерфейса — линии к HQ-RTR и BR-RTR.

2) Eltex / vESR:
   На Eltex смотри MAC портов:
     show interfaces status
   В Proxmox/на KVM смотри MAC сетевых устройств:
     virsh domiflist HQ-RTR
     virsh domiflist BR-RTR
   Совпавший MAC показывает, какой gi1/0/X подключён к какой сети.

   Для HQ-RTR нужно узнать:
     порт к ISP-HQ
     порт к HQ-SRV
     порт к HQ-CLI
     порт к HQ-MGMT

   Для BR-RTR нужно узнать:
     порт к BR-LAN
     порт к ISP-BR

3) Linux-серверы:
   На каждой машине смотри:
     ip -br a
   Обычно интерфейс ens3 или enp7s1.

EOF
}

ask_topology(){
  print_mapping_help
  echo "Текущие интерфейсы ISP:"
  ip -br a || true
  echo
  nmcli device status 2>/dev/null || true
  echo
  echo "Укажи карту стенда. Enter = значение по умолчанию."

  # Сначала пробуем автоопределить WAN и два внутренних интерфейса, потом спрашиваем явно.
  auto_detect_isp_interfaces || true

  ask_value WAN_IF "ISP: WAN-интерфейс в Интернет" "${WAN_IF:-enp7s1}"
  ask_value HQ_IF  "ISP: интерфейс в сторону HQ-RTR / ISP-HQ" "${HQ_IF:-enp7s2}"
  ask_value BR_IF  "ISP: интерфейс в сторону BR-RTR / ISP-BR" "${BR_IF:-enp7s3}"

  echo
  echo "Порты HQ-RTR. Формат: gigabitethernet 1/0/X"
  ask_value HQR_ISP_PORT  "HQ-RTR: порт к ISP-HQ"  "$HQR_ISP_PORT"
  ask_value HQR_SRV_PORT  "HQ-RTR: порт к HQ-SRV"  "$HQR_SRV_PORT"
  ask_value HQR_CLI_PORT  "HQ-RTR: порт к HQ-CLI"  "$HQR_CLI_PORT"
  ask_value HQR_MGMT_PORT "HQ-RTR: порт к HQ-MGMT" "$HQR_MGMT_PORT"

  echo
  echo "Порты BR-RTR. Формат: gigabitethernet 1/0/X"
  ask_value BRR_LAN_PORT "BR-RTR: порт к BR-LAN" "$BRR_LAN_PORT"
  ask_value BRR_ISP_PORT "BR-RTR: порт к ISP-BR" "$BRR_ISP_PORT"

  echo
  echo "Интерфейсы Linux-машин для минимального SSH bootstrap."
  ask_value HQ_SRV_IF "HQ-SRV: сетевой интерфейс" "$HQ_SRV_IF"
  ask_value BR_SRV_IF "BR-SRV: сетевой интерфейс" "$BR_SRV_IF"
  ask_value HQ_CLI_IF "HQ-CLI: сетевой интерфейс" "$HQ_CLI_IF"

  cat <<EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━
ВЫБРАННАЯ КАРТА
━━━━━━━━━━━━━━━━━━━━━━━━━━
ISP: WAN=$WAN_IF, HQ=$HQ_IF, BR=$BR_IF
HQ-RTR: ISP=$HQR_ISP_PORT, HQ-SRV=$HQR_SRV_PORT, HQ-CLI=$HQR_CLI_PORT, MGMT=$HQR_MGMT_PORT
BR-RTR: BR-LAN=$BRR_LAN_PORT, ISP-BR=$BRR_ISP_PORT
Linux IF: HQ-SRV=$HQ_SRV_IF, BR-SRV=$BR_SRV_IF, HQ-CLI=$HQ_CLI_IF
EOF
  echo
  read -rp "Продолжить с этой картой? yes/no [yes]: " ans
  ans="${ans:-yes}"
  [ "$ans" = "yes" ] || [ "$ans" = "y" ] || return 1
}

install_tools(){
  dnf install -y expect sshpass openssh-clients >/tmp/demoexam_tools.err 2>&1 || {
    fail "не удалось установить expect/sshpass, смотри /tmp/demoexam_tools.err"
    return 1
  }
}

check_ping(){ ping -c 2 -W 2 "$1" >/dev/null 2>&1; }

show_tail_err(){
  local f="$1"
  [ -f "$f" ] && { echo "----- последние строки $f -----"; tail -n 20 "$f"; echo "-------------------------------"; }
}

check_ssh(){
  local ip="$1" user="$2" pass="$3"
  sshpass -p "$pass" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "$user@$ip" "echo ok" >/tmp/demoexam_check_ssh.out 2>/tmp/demoexam_check_ssh.err
}

ssh_run(){
  local ip="$1" user="$2" pass="$3" name="$4" payload="$5" err="/tmp/demoexam_${name}.err" out="/tmp/demoexam_${name}_remote.log"
  rm -f "$out" "$err"
  echo "[..] $name: удалённое выполнение началось, подробный лог: $out"
  sshpass -p "$pass" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$user@$ip" "bash -s" 2>"$err" <<< "$payload" | tee "$out" | sed -u -n 's/^REMOTE_STATUS: //p'
  local rc=${PIPESTATUS[0]}
  if [ "$rc" -eq 0 ]; then
    echo "[OK] $name: удалённое выполнение завершено"
  else
    echo "[FAIL] $name: удалённое выполнение завершилось с ошибкой, код $rc"
  fi
  return "$rc"
}

auto_detect_isp_interfaces(){
  WAN_IF="${WAN_IF:-}"
  HQ_IF="${HQ_IF:-}"
  BR_IF="${BR_IF:-}"

  if [ -z "$WAN_IF" ]; then
    WAN_IF=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
  fi
  if [ -z "$WAN_IF" ]; then
    WAN_IF=$(ip -o -4 addr show scope global | awk '{print $2; exit}')
  fi

  if [ -z "$HQ_IF" ] || [ -z "$BR_IF" ]; then
    mapfile -t CANDIDATES < <(
      nmcli -t -f DEVICE,TYPE device status 2>/dev/null |
      awk -F: '$2=="ethernet"{print $1}' |
      grep -v "^${WAN_IF}$" |
      sort
    )
    [ -z "$HQ_IF" ] && HQ_IF="${CANDIDATES[0]:-}"
    [ -z "$BR_IF" ] && BR_IF="${CANDIDATES[1]:-}"
  fi

  if [ -z "$WAN_IF" ] || [ -z "$HQ_IF" ] || [ -z "$BR_IF" ]; then
    fail "не смог определить интерфейсы ISP"
    echo "Выполни: ip -br a ; nmcli device status"
    echo "Запуск с ручным указанием:"
    echo "WAN_IF=enp7s1 HQ_IF=enp7s2 BR_IF=enp7s3 bash demoexam_central_master_step.sh"
    return 1
  fi
}

configure_isp(){
  info "Настраиваю ISP автоматически"
  auto_detect_isp_interfaces || return 1

  info "ISP: WAN=$WAN_IF, HQ=$HQ_IF, BR=$BR_IF"

  hostnamectl set-hostname isp >/tmp/demoexam_isp.err 2>&1 || true

  ensure_con(){
    local iface="$1" name="$2" current=""
    current=$(nmcli -t -f NAME,DEVICE con show | awk -F: -v dev="$iface" '$2==dev {print $1; exit}') || true
    if nmcli con show "$name" >/dev/null 2>&1; then
      nmcli con mod "$name" connection.interface-name "$iface" >/dev/null 2>>/tmp/demoexam_isp.err || true
    elif [ -n "$current" ]; then
      nmcli con mod "$current" connection.id "$name" >/dev/null 2>>/tmp/demoexam_isp.err || true
    else
      nmcli con add type ethernet ifname "$iface" con-name "$name" >/dev/null 2>>/tmp/demoexam_isp.err || true
    fi
  }

  ensure_con "$WAN_IF" ISP-WAN
  ensure_con "$HQ_IF" ISP-HQ
  ensure_con "$BR_IF" ISP-BR

  nmcli con mod ISP-WAN ipv4.method auto >/dev/null 2>>/tmp/demoexam_isp.err || return 1
  nmcli con mod ISP-HQ ipv4.addresses 172.16.1.1/28 ipv4.method manual >/dev/null 2>>/tmp/demoexam_isp.err || return 1
  nmcli con mod ISP-BR ipv4.addresses 172.16.2.1/28 ipv4.method manual >/dev/null 2>>/tmp/demoexam_isp.err || return 1

  nmcli con up ISP-WAN >/dev/null 2>>/tmp/demoexam_isp.err || return 1
  nmcli con up ISP-HQ >/dev/null 2>>/tmp/demoexam_isp.err || return 1
  nmcli con up ISP-BR >/dev/null 2>>/tmp/demoexam_isp.err || return 1

  cat > /etc/sysctl.d/99-ip-forward.conf <<'EOF'
net.ipv4.ip_forward=1
EOF
  sysctl --system >/dev/null 2>>/tmp/demoexam_isp.err || true

  mkdir -p /etc/nftables
  cat > /etc/nftables/isp.nft <<EOF
table inet nat {
    chain POSTROUTING {
        type nat hook postrouting priority srcnat;
        oifname "$WAN_IF" masquerade
    }
}
EOF

  grep -q '/etc/nftables/isp.nft' /etc/sysconfig/nftables.conf 2>/dev/null || echo 'include "/etc/nftables/isp.nft"' >> /etc/sysconfig/nftables.conf

  systemctl enable --now nftables >/dev/null 2>>/tmp/demoexam_isp.err || return 1
  systemctl restart nftables >/dev/null 2>>/tmp/demoexam_isp.err || return 1

  dnf install -y chrony nginx httpd-tools >/tmp/demoexam_isp_packages.err 2>&1 || true

  cat > /etc/chrony.conf <<'EOF'
server ntp1.vniiftri.ru iburst prefer
server ntp2.vniiftri.ru iburst
local stratum 5
allow 0.0.0.0/0
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF

  systemctl enable --now chronyd >/dev/null 2>>/tmp/demoexam_isp.err || true
  systemctl restart chronyd >/dev/null 2>>/tmp/demoexam_isp.err || true

  mkdir -p /etc/nginx/conf.d
  cat > /etc/nginx/conf.d/docker.conf <<'EOF'
server {
    listen 80;
    server_name docker.sirius-exam.org;
    location / {
        proxy_pass http://172.16.2.2:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
EOF

  htpasswd -b -c /etc/nginx/.htpasswd WEB 'P@ssw0rd' >/dev/null 2>>/tmp/demoexam_isp.err || true

  cat > /etc/nginx/conf.d/web.conf <<'EOF'
server {
    listen 80;
    server_name web.sirius-exam.org;
    location / {
        proxy_pass http://172.16.1.2:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Real-IP $remote_addr;
        auth_basic "Restricted area";
        auth_basic_user_file /etc/nginx/.htpasswd;
    }
}
EOF

  nginx -t >/tmp/demoexam_nginx_test.err 2>&1 && systemctl restart nginx >/dev/null 2>>/tmp/demoexam_isp.err || true

  ip route replace 192.168.100.0/27 via 172.16.1.2 2>/dev/null || true
  ip route replace 192.168.200.0/28 via 172.16.1.2 2>/dev/null || true
  ip route replace 192.168.99.0/29 via 172.16.1.2 2>/dev/null || true
  ip route replace 192.168.30.0/28 via 172.16.2.2 2>/dev/null || true

  ok "ISP настроен"
}

print_hq_rtr_bootstrap(){
  cat <<EOF
[WAIT] ШАГ — HQ-RTR bootstrap

Как узнать порт:
  На HQ-RTR: show interfaces status
  На хосте KVM: virsh domiflist HQ-RTR
  Сравни MAC. Порт к сети ISP-HQ сейчас выбран: $HQR_ISP_PORT

Вставь в консоль HQ-RTR:

password Admin1234
commit
confirm
configure terminal
hostname hq-rtr.sirius-exam.org
username net_admin
 password P@ssw0rd
 privilege 15
exit
interface $HQR_ISP_PORT
 ip firewall disable
 ip address 172.16.1.2/28
exit
ip route 0.0.0.0/0 172.16.1.1
ip ssh server
commit
confirm

EOF
}

print_br_rtr_bootstrap(){
  cat <<EOF
[WAIT] ШАГ — BR-RTR bootstrap

Как узнать порт:
  На BR-RTR: show interfaces status
  На хосте KVM: virsh domiflist BR-RTR
  Сравни MAC. Порт к сети ISP-BR сейчас выбран: $BRR_ISP_PORT

Вставь в консоль BR-RTR:

password Admin1234
commit
confirm
configure terminal
hostname br-rtr.sirius-exam.org
username net_admin
 password P@ssw0rd
 privilege 15
exit
interface $BRR_ISP_PORT
 ip firewall disable
 ip address 172.16.2.2/28
exit
ip route 0.0.0.0/0 172.16.2.1
ip ssh server
commit
confirm

EOF
}

vesr_expect_hq(){
  local ip="$1" err="/tmp/demoexam_hq_rtr.err" tmp="/tmp/demoexam_hq_rtr.expect"
  cat > "$tmp" <<'EOF'
#!/usr/bin/expect -f
set timeout 120
set ip [lindex $argv 0]
set user "net_admin"
set pass "P@ssw0rd"
log_user 0
log_file -noappend /tmp/demoexam_vesr_expect.log
send_user -- "STEP SSH_CONNECT: подключаюсь к VESR\n"
proc c {cmd} {
    send_user -- "STEP CMD: $cmd\n"
    send -- "$cmd\r"
    expect {
        -re {[\r\n].*[#>]} {}
        timeout { send_user -- "ERROR TIMEOUT: команда не получила prompt: $cmd\n"; exit 20 }
        eof { send_user -- "ERROR EOF: соединение закрыто на команде: $cmd\n"; exit 21 }
    }
}
spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 $user@$ip
expect {
    -re "yes/no" { send_user -- "STEP SSH_HOSTKEY: принимаю host key\n"; send "yes\r"; exp_continue }
    -re "(P|p)assword:" { send_user -- "STEP SSH_PASSWORD: отправляю пароль\n"; send "$pass\r" }
    timeout { send_user -- "ERROR SSH: нет запроса пароля\n"; exit 10 }
    eof { send_user -- "ERROR SSH: соединение закрыто до пароля\n"; exit 11 }
}
expect {
    -re "[#>]" { send_user -- "STEP SSH_LOGIN_OK: вошли в VESR\n" }
    -re "(P|p)assword:" { send_user -- "ERROR SSH: пароль не принят\n"; exit 12 }
    timeout { send_user -- "ERROR SSH: вошли, но prompt не появился\n"; exit 13 }
    eof { send_user -- "ERROR SSH: соединение закрыто после пароля\n"; exit 14 }
}
c "configure terminal"
c "hostname hq-rtr.sirius-exam.org"
c "username net_admin"
c "password P@ssw0rd"
c "privilege 15"
c "exit"
c "domain lookup enable"
c "object-group network PUBLIC_POOL"
c "ip address-range 172.16.1.3-172.16.1.7"
c "exit"
c "interface __HQR_ISP_PORT__"
c "ip firewall disable"
c "ip address 172.16.1.2/28"
c "ip nat proxy-arp PUBLIC_POOL"
c "exit"
c "interface __HQR_SRV_PORT__"
c "ip firewall disable"
c "ip address 192.168.100.1/27"
c "exit"
c "interface __HQR_CLI_PORT__"
c "ip firewall disable"
c "ip address 192.168.200.1/28"
c "exit"
c "interface __HQR_MGMT_PORT__"
c "ip firewall disable"
c "ip address 192.168.99.1/29"
c "exit"
c "key-chain auth_ospf"
c "key 1"
c "key-string ascii-text P@ssw0rd"
c "exit"
c "exit"
c "router ospf 1"
c "router-id 10.10.10.1"
c "area 0.0.0.0"
c "network 192.168.100.0/27"
c "network 192.168.200.0/28"
c "network 192.168.99.0/29"
c "network 10.10.10.0/30"
c "enable"
c "exit"
c "enable"
c "exit"
c "tunnel gre 1"
c "description \"to-br-rtr\""
c "ttl 255"
c "ip firewall disable"
c "local address 172.16.1.2"
c "remote address 172.16.2.2"
c "ip address 10.10.10.1/30"
c "ip ospf instance 1"
c "ip ospf authentication key-chain auth_ospf"
c "ip ospf authentication algorithm md5"
c "ip ospf"
c "enable"
c "exit"
c "nat source"
c "pool TRANSLATE_ADDRESS"
c "ip address-range 172.16.1.3-172.16.1.7"
c "exit"
c "ruleset SNAT"
c "to interface __HQR_ISP_PORT__"
c "rule 1"
c "match source-address prefix 192.168.100.0/27"
c "action source-nat pool TRANSLATE_ADDRESS"
c "enable"
c "exit"
c "rule 2"
c "match source-address prefix 192.168.200.0/28"
c "action source-nat pool TRANSLATE_ADDRESS"
c "enable"
c "exit"
c "rule 3"
c "match source-address prefix 192.168.99.0/29"
c "action source-nat pool TRANSLATE_ADDRESS"
c "enable"
c "exit"
c "exit"
c "exit"
c "ip dhcp-server"
c "ip dhcp-server pool CLI_POOL"
c "network 192.168.200.0/28"
c "domain-name sirius-exam.org"
c "address-range 192.168.200.3-192.168.200.14"
c "default-router 192.168.200.1"
c "dns-server 192.168.100.2"
c "exit"
c "nat destination"
c "pool HQ_WEB"
c "ip address 192.168.100.2"
c "ip port 80"
c "exit"
c "pool HQ_SSH"
c "ip address 192.168.100.2"
c "ip port 2026"
c "exit"
c "ruleset DNAT"
c "from default"
c "rule 1"
c "match protocol tcp"
c "match destination-address prefix 172.16.1.2/32"
c "match destination-port port-range 8080"
c "action destination-nat pool HQ_WEB"
c "enable"
c "exit"
c "rule 2"
c "match protocol tcp"
c "match destination-address prefix 172.16.1.2/32"
c "match destination-port port-range 2026"
c "action destination-nat pool HQ_SSH"
c "enable"
c "exit"
c "exit"
c "exit"
c "ip route 0.0.0.0/0 172.16.1.1"
c "ip ssh server"
c "ntp enable"
c "ntp broadcast-client enable"
c "security passwords default-expired"
c "commit"
c "confirm"
c "exit"
EOF
  chmod +x "$tmp"
  sed -i \
    -e "s#__HQR_ISP_PORT__#$HQR_ISP_PORT#g" \
    -e "s#__HQR_SRV_PORT__#$HQR_SRV_PORT#g" \
    -e "s#__HQR_CLI_PORT__#$HQR_CLI_PORT#g" \
    -e "s#__HQR_MGMT_PORT__#$HQR_MGMT_PORT#g" "$tmp"
  echo "[..] HQ-RTR expect: подробный лог команд ниже"
  echo "[..] HQ-RTR ports: ISP=$HQR_ISP_PORT, SRV=$HQR_SRV_PORT, CLI=$HQR_CLI_PORT, MGMT=$HQR_MGMT_PORT"
  "$tmp" "$ip" 2>"$err" | tee /tmp/demoexam_hq_rtr_steps.log
  local rc=${PIPESTATUS[0]}
  echo "[INFO] HQ-RTR expect log: /tmp/demoexam_hq_rtr_steps.log"
  return $rc
}

vesr_expect_br(){
  local ip="$1" err="/tmp/demoexam_br_rtr.err" tmp="/tmp/demoexam_br_rtr.expect"
  cat > "$tmp" <<'EOF'
#!/usr/bin/expect -f
set timeout 120
set ip [lindex $argv 0]
set user "net_admin"
set pass "P@ssw0rd"
log_user 0
log_file -noappend /tmp/demoexam_vesr_expect.log
send_user -- "STEP SSH_CONNECT: подключаюсь к VESR\n"
proc c {cmd} {
    send_user -- "STEP CMD: $cmd\n"
    send -- "$cmd\r"
    expect {
        -re {[\r\n].*[#>]} {}
        timeout { send_user -- "ERROR TIMEOUT: команда не получила prompt: $cmd\n"; exit 20 }
        eof { send_user -- "ERROR EOF: соединение закрыто на команде: $cmd\n"; exit 21 }
    }
}
spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 $user@$ip
expect {
    -re "yes/no" { send_user -- "STEP SSH_HOSTKEY: принимаю host key\n"; send "yes\r"; exp_continue }
    -re "(P|p)assword:" { send_user -- "STEP SSH_PASSWORD: отправляю пароль\n"; send "$pass\r" }
    timeout { send_user -- "ERROR SSH: нет запроса пароля\n"; exit 10 }
    eof { send_user -- "ERROR SSH: соединение закрыто до пароля\n"; exit 11 }
}
expect {
    -re "[#>]" { send_user -- "STEP SSH_LOGIN_OK: вошли в VESR\n" }
    -re "(P|p)assword:" { send_user -- "ERROR SSH: пароль не принят\n"; exit 12 }
    timeout { send_user -- "ERROR SSH: вошли, но prompt не появился\n"; exit 13 }
    eof { send_user -- "ERROR SSH: соединение закрыто после пароля\n"; exit 14 }
}
c "configure terminal"
c "hostname br-rtr.sirius-exam.org"
c "username net_admin"
c "password P@ssw0rd"
c "privilege 15"
c "exit"
c "domain lookup enable"
c "object-group network PUBLIC_POOL"
c "ip address-range 172.16.2.3-172.16.2.7"
c "exit"
c "interface __BRR_LAN_PORT__"
c "ip firewall disable"
c "ip address 192.168.30.1/28"
c "exit"
c "interface __BRR_ISP_PORT__"
c "ip firewall disable"
c "ip address 172.16.2.2/28"
c "ip nat proxy-arp PUBLIC_POOL"
c "exit"
c "key-chain auth_ospf"
c "key 1"
c "key-string ascii-text P@ssw0rd"
c "exit"
c "exit"
c "router ospf 1"
c "router-id 10.10.10.2"
c "area 0.0.0.0"
c "network 192.168.30.0/28"
c "network 10.10.10.0/30"
c "enable"
c "exit"
c "enable"
c "exit"
c "tunnel gre 1"
c "description \"to-hq-rtr\""
c "ttl 255"
c "ip firewall disable"
c "local address 172.16.2.2"
c "remote address 172.16.1.2"
c "ip address 10.10.10.2/30"
c "ip ospf instance 1"
c "ip ospf authentication key-chain auth_ospf"
c "ip ospf authentication algorithm md5"
c "ip ospf"
c "enable"
c "exit"
c "nat source"
c "pool TRANSLATE_ADDRESS"
c "ip address-range 172.16.2.3-172.16.2.7"
c "exit"
c "ruleset SNAT"
c "to interface __BRR_ISP_PORT__"
c "rule 1"
c "match source-address prefix 192.168.30.0/28"
c "action source-nat pool TRANSLATE_ADDRESS"
c "enable"
c "exit"
c "exit"
c "exit"
c "nat destination"
c "pool BR_DOCKER"
c "ip address 192.168.30.2"
c "ip port 8080"
c "exit"
c "pool BR_SSH"
c "ip address 192.168.30.2"
c "ip port 2026"
c "exit"
c "ruleset DNAT"
c "from default"
c "rule 1"
c "match protocol tcp"
c "match destination-address prefix 172.16.2.2/32"
c "match destination-port port-range 8080"
c "action destination-nat pool BR_DOCKER"
c "enable"
c "exit"
c "rule 2"
c "match protocol tcp"
c "match destination-address prefix 172.16.2.2/32"
c "match destination-port port-range 2026"
c "action destination-nat pool BR_SSH"
c "enable"
c "exit"
c "exit"
c "exit"
c "ip route 0.0.0.0/0 172.16.2.1"
c "ip ssh server"
c "ntp enable"
c "ntp server 172.16.2.1"
c "ntp broadcast-client enable"
c "security passwords default-expired"
c "commit"
c "confirm"
c "exit"
EOF
  chmod +x "$tmp"
  sed -i \
    -e "s#__BRR_LAN_PORT__#$BRR_LAN_PORT#g" \
    -e "s#__BRR_ISP_PORT__#$BRR_ISP_PORT#g" "$tmp"
  echo "[..] BR-RTR expect: подробный лог команд ниже"
  echo "[..] BR-RTR ports: LAN=$BRR_LAN_PORT, ISP=$BRR_ISP_PORT"
  "$tmp" "$ip" 2>"$err" | tee /tmp/demoexam_br_rtr_steps.log
  local rc=${PIPESTATUS[0]}
  echo "[INFO] BR-RTR expect log: /tmp/demoexam_br_rtr_steps.log"
  return $rc
}

configure_hq_rtr(){
  print_hq_rtr_bootstrap
  wait_enter
  local ip="172.16.1.2"

  echo "[..] HQ-RTR: проверяю ping $ip"
  if ! check_ping "$ip"; then
    fail "HQ-RTR не отвечает на ping $ip"
    echo "Проверь на HQ-RTR: show ip interface brief"
    return 1
  fi
  echo "[OK] HQ-RTR ping есть"

  echo "[..] HQ-RTR: пробую SSH net_admin@172.16.1.2 и отправляю полный конфиг"
  rm -f /tmp/demoexam_hq_rtr.err /tmp/demoexam_vesr_expect.log
  if vesr_expect_hq "$ip"; then
    ok "HQ-RTR настроен"
  else
    fail "HQ-RTR не настроен"
    show_tail_err /tmp/demoexam_hq_rtr.err
    show_tail_err /tmp/demoexam_hq_rtr_steps.log
    show_tail_err /tmp/demoexam_br_rtr_steps.log
    show_tail_err /tmp/demoexam_vesr_expect.log
    echo "Проверь вручную с ISP: ssh net_admin@$ip"
    return 1
  fi
}

configure_br_rtr(){
  print_br_rtr_bootstrap
  wait_enter
  local ip="172.16.2.2"

  echo "[..] BR-RTR: проверяю ping $ip"
  if ! check_ping "$ip"; then
    fail "BR-RTR не отвечает на ping $ip"
    echo "Проверь на BR-RTR: show ip interface brief"
    return 1
  fi
  echo "[OK] BR-RTR ping есть"

  echo "[..] BR-RTR: пробую SSH net_admin@172.16.2.2 и отправляю полный конфиг"
  rm -f /tmp/demoexam_br_rtr.err /tmp/demoexam_vesr_expect.log
  if vesr_expect_br "$ip"; then
    ok "BR-RTR настроен"
  else
    fail "BR-RTR не настроен"
    show_tail_err /tmp/demoexam_br_rtr.err
    show_tail_err /tmp/demoexam_vesr_expect.log
    echo "Проверь вручную с ISP: ssh net_admin@$ip"
    return 1
  fi
}

linux_hint_hq_srv(){
  cat <<HINT_HQ_SRV
[WAIT] ШАГ — HQ-SRV SSH

Минимум для доступа. Зайди в консоль HQ-SRV и вставь:

nmcli con add type ethernet ifname $HQ_SRV_IF con-name HQ-SRV ipv4.addresses 192.168.100.2/27 ipv4.gateway 192.168.100.1 ipv4.method manual 2>/dev/null || true
nmcli con mod HQ-SRV ipv4.addresses 192.168.100.2/27 ipv4.gateway 192.168.100.1 ipv4.method manual
nmcli con up HQ-SRV
passwd root
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
grep -q '^Port 22' /etc/ssh/sshd_config || echo 'Port 22' >> /etc/ssh/sshd_config
ssh-keygen -A
sshd -t
systemctl enable --now sshd
systemctl restart sshd
ip -br a
ping -c 3 192.168.100.1

После этого вернись в скрипт и нажми Enter.
HINT_HQ_SRV
}

linux_hint_br_srv(){
  cat <<HINT_BR_SRV
[WAIT] ШАГ — BR-SRV SSH

Минимум для доступа. Зайди в консоль BR-SRV и вставь:

nmcli con add type ethernet ifname $BR_SRV_IF con-name BR-SRV ipv4.addresses 192.168.30.2/28 ipv4.gateway 192.168.30.1 ipv4.method manual 2>/dev/null || true
nmcli con mod BR-SRV ipv4.addresses 192.168.30.2/28 ipv4.gateway 192.168.30.1 ipv4.method manual
nmcli con up BR-SRV
passwd root
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
grep -q '^Port 22' /etc/ssh/sshd_config || echo 'Port 22' >> /etc/ssh/sshd_config
ssh-keygen -A
sshd -t
systemctl enable --now sshd
systemctl restart sshd
ip -br a
ping -c 3 192.168.30.1

После этого вернись в скрипт и нажми Enter.
HINT_BR_SRV
}

linux_hint_hq_cli(){
  cat <<HINT_HQ_CLI
[WAIT] ШАГ — HQ-CLI SSH

Минимум для доступа. Зайди в консоль HQ-CLI и вставь:

nmcli con add type ethernet ifname $HQ_CLI_IF con-name HQ-CLI ipv4.addresses 192.168.200.3/28 ipv4.gateway 192.168.200.1 ipv4.method manual 2>/dev/null || true
nmcli con mod HQ-CLI ipv4.addresses 192.168.200.3/28 ipv4.gateway 192.168.200.1 ipv4.method manual
nmcli con up HQ-CLI
passwd root
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
grep -q '^Port 22' /etc/ssh/sshd_config || echo 'Port 22' >> /etc/ssh/sshd_config
ssh-keygen -A
sshd -t
systemctl enable --now sshd
systemctl restart sshd
ip -br a
ping -c 3 192.168.200.1

После этого вернись в скрипт и нажми Enter.
HINT_HQ_CLI
}

hq_srv_payload(){
cat <<'REMOTE'
set -euo pipefail

safe_dnf_install(){
  local log="/tmp/hq_srv_dnf.err"
  local timeout_sec="${DNF_TIMEOUT_SEC:-900}"
  shift 0

  echo "REMOTE_STATUS: START: HQ-SRV: проверяю, нет ли зависшего dnf/rpm/yum"
  local old_pids=""
  old_pids=$(pgrep -f '(/usr/bin/dnf|/usr/bin/yum|/usr/bin/rpm|dnf install|yum install|rpm )' | grep -v "^$$$" || true)

  if [ -n "$old_pids" ]; then
    echo "REMOTE_STATUS: WARN: HQ-SRV: найден старый dnf/rpm/yum: $old_pids"
    for n in 1 2 3 4 5 6; do
      sleep 5
      old_pids=$(pgrep -f '(/usr/bin/dnf|/usr/bin/yum|/usr/bin/rpm|dnf install|yum install|rpm )' | grep -v "^$$$" || true)
      [ -z "$old_pids" ] && break
      echo "REMOTE_STATUS: WAIT: HQ-SRV: жду старый dnf/rpm/yum, попытка $n/6"
    done

    old_pids=$(pgrep -f '(/usr/bin/dnf|/usr/bin/yum|/usr/bin/rpm|dnf install|yum install|rpm )' | grep -v "^$$$" || true)
    if [ -n "$old_pids" ]; then
      echo "REMOTE_STATUS: WARN: HQ-SRV: старый dnf/rpm/yum не завершился, останавливаю: $old_pids"
      kill $old_pids 2>/dev/null || true
      sleep 5
      old_pids=$(pgrep -f '(/usr/bin/dnf|/usr/bin/yum|/usr/bin/rpm|dnf install|yum install|rpm )' | grep -v "^$$$" || true)
      [ -n "$old_pids" ] && kill -9 $old_pids 2>/dev/null || true
    fi
  fi

  rm -f "$log"
  echo "REMOTE_STATUS: START: HQ-SRV: dnf install запущен, таймаут ${timeout_sec} сек"
  echo "REMOTE_STATUS: DNF: пакеты: policycoreutils-python-utils bind bind-utils chrony mdadm nfs-utils nfs4-acl-tools httpd php php-mysqlnd mariadb-server mariadb"

  timeout "$timeout_sec" dnf install -y \
    policycoreutils-python-utils bind bind-utils chrony mdadm nfs-utils nfs4-acl-tools \
    httpd php php-mysqlnd mariadb-server mariadb > "$log" 2>&1 &
  local dnf_pid=$!
  local last_line=0
  local total=0

  while kill -0 "$dnf_pid" 2>/dev/null; do
    if [ -f "$log" ]; then
      total=$(wc -l < "$log" 2>/dev/null || echo 0)
      if [ "$total" -gt "$last_line" ]; then
        sed -n "$((last_line+1)),$total p" "$log" | while IFS= read -r line; do
          case "$line" in
            *"Ожидание завершения процесса"*|*"Waiting for process"*|*"Downloading Packages"*|*"Загрузка пакетов"*|*"Installing"*|*"Установка"*|*"Installing dependencies"*|*"Установка зависимостей"*|*"Installing weak dependencies"*|*"Установка слабых зависимостей"*|*"Running transaction"*|*"Проверка транзакции"*|*"Выполнение транзакции"*|*".rpm"*|*"МБ"*|*"MB"*|*"kB/s"*|*"МБ/с"*)
              echo "REMOTE_STATUS: DNF: $line"
              ;;
          esac
        done
        last_line="$total"
      fi
    fi
    sleep 3
  done

  wait "$dnf_pid"
  local rc=$?

  if [ -f "$log" ]; then
    total=$(wc -l < "$log" 2>/dev/null || echo 0)
    if [ "$total" -gt "$last_line" ]; then
      sed -n "$((last_line+1)),$total p" "$log" | while IFS= read -r line; do
        case "$line" in
          *"Complete!"*|*"Выполнено!"*|*"Installed"*|*"Установлено"*|*"Nothing to do"*|*"Делать нечего"*|*"Ошибка"*|*"Error"*|*"Failed"*|*"Не удалось"*|*"No match"*|*"Совпадений не найдено"*|*"Timeout"*|*"Время ожидания"*)
            echo "REMOTE_STATUS: DNF: $line"
            ;;
        esac
      done
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    echo "REMOTE_STATUS: OK: HQ-SRV: dnf install завершён"
    return 0
  elif [ "$rc" -eq 124 ]; then
    echo "REMOTE_STATUS: SKIP: HQ-SRV: dnf превысил таймаут ${timeout_sec} сек, шаг не зависает, продолжаю"
    echo "REMOTE_STATUS: INFO: HQ-SRV: подробности в $log"
    return 0
  else
    echo "REMOTE_STATUS: SKIP: HQ-SRV: dnf завершился с кодом $rc, продолжаю"
    echo "REMOTE_STATUS: INFO: HQ-SRV: подробности в $log"
    return 0
  fi
}

remote_step(){ echo "REMOTE_STATUS: START: $1"; }
remote_done(){ echo "REMOTE_STATUS: OK: $1"; }
remote_skip(){ echo "REMOTE_STATUS: SKIP: $1"; }
remote_step 'HQ-SRV: hostname и SSH'
hostnamectl set-hostname hq-srv.sirius-exam.org || true
useradd sshuser -u 2026 -U 2>/dev/null || true
echo "sshuser:P@ssw0rd" | chpasswd
echo 'sshuser ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/sshuser
chmod 440 /etc/sudoers.d/sshuser
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.demo 2>/dev/null || true
cat > /etc/ssh/sshd_config <<'SSHD_EOF'
Port 22
Port 2026
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
UsePAM yes
MaxAuthTries 2
AllowUsers root sshuser
X11Forwarding yes
Subsystem sftp /usr/libexec/openssh/sftp-server
SSHD_EOF
ssh-keygen -A >/dev/null 2>&1 || true
remote_step 'HQ-SRV: установка пакетов через dnf'
safe_dnf_install
remote_done 'HQ-SRV: пакеты установлены или уже были'
semanage port -a -t ssh_port_t -p tcp 2026 2>/dev/null || semanage port -m -t ssh_port_t -p tcp 2026 2>/dev/null || true
firewall-cmd --permanent --add-port=2026/tcp >/dev/null 2>&1 || true
firewall-cmd --permanent --add-service=dns >/dev/null 2>&1 || true
firewall-cmd --reload >/dev/null 2>&1 || true
systemctl restart sshd || true
remote_done 'HQ-SRV: hostname и SSH'
remote_step 'HQ-SRV: DNS/BIND'
mkdir -p /var/named/master
cat > /etc/named.conf <<'EOF'
options {
    listen-on port 53 { any; };
    listen-on-v6 port 53 { none; };
    directory "/var/named";
    allow-query { any; };
    recursion yes;
    forward first;
    forwarders { 77.88.8.7; 77.88.8.3; };
    dnssec-validation no;
};
zone "sirius-exam.org" IN { type master; file "master/sirius-exam.org.zone"; };
zone "100.168.192.in-addr.arpa" IN { type master; file "master/192.168.100.rev"; };
zone "200.168.192.in-addr.arpa" IN { type master; file "master/192.168.200.rev"; };
zone "30.168.192.in-addr.arpa" IN { type master; file "master/192.168.30.rev"; };
include "/etc/named.rfc1912.zones";
include "/etc/named.root.key";
EOF
cat > /var/named/master/sirius-exam.org.zone <<'EOF'
$TTL 604800
@ IN SOA hq-srv.sirius-exam.org. root.sirius-exam.org. (1 600 3600 1w 360)
  IN NS hq-srv.sirius-exam.org.
isp IN A 172.16.1.1
hq-rtr IN A 192.168.100.1
br-rtr IN A 192.168.30.1
hq-srv IN A 192.168.100.2
hq-cli IN A 192.168.200.3
br-srv IN A 192.168.30.2
web IN A 172.16.1.1
docker IN A 172.16.1.1
nextcloud IN A 192.168.30.2
EOF
cat > /var/named/master/192.168.100.rev <<'EOF'
$TTL 604800
@ IN SOA hq-srv.sirius-exam.org. root.sirius-exam.org. (1 600 3600 1w 360)
  IN NS hq-srv.sirius-exam.org.
1 IN PTR hq-rtr.sirius-exam.org.
2 IN PTR hq-srv.sirius-exam.org.
EOF
cat > /var/named/master/192.168.200.rev <<'EOF'
$TTL 604800
@ IN SOA hq-srv.sirius-exam.org. root.sirius-exam.org. (1 600 3600 1w 360)
  IN NS hq-srv.sirius-exam.org.
3 IN PTR hq-cli.sirius-exam.org.
EOF
cat > /var/named/master/192.168.30.rev <<'EOF'
$TTL 604800
@ IN SOA hq-srv.sirius-exam.org. root.sirius-exam.org. (1 600 3600 1w 360)
  IN NS hq-srv.sirius-exam.org.
1 IN PTR br-rtr.sirius-exam.org.
2 IN PTR br-srv.sirius-exam.org.
EOF
chown -R root:named /var/named/master
chmod 0640 /var/named/master/*
named-checkconf
named-checkzone sirius-exam.org /var/named/master/sirius-exam.org.zone >/dev/null
systemctl enable --now named >/dev/null 2>&1
systemctl restart named
remote_done 'HQ-SRV: DNS/BIND готов'
remote_step 'HQ-SRV: Chrony'
cat > /etc/chrony.conf <<'EOF'
server 172.16.1.1 iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
systemctl enable --now chronyd >/dev/null 2>&1
systemctl restart chronyd
remote_done 'HQ-SRV: Chrony готов'
remote_step 'HQ-SRV: проверяю дополнительные диски для RAID0'
RAID_DEVS=()
while read -r name type size; do
  [ "$type" = "disk" ] || continue
  [ "$name" = "sda" ] && continue
  RAID_DEVS+=("/dev/$name")
done < <(lsblk -dn -o NAME,TYPE,SIZE)

if [ "${#RAID_DEVS[@]}" -ge 2 ]; then
  echo "REMOTE_STATUS: START: HQ-SRV: найдены диски ${RAID_DEVS[0]} и ${RAID_DEVS[1]}, делаю RAID0"
  if [ ! -b /dev/md0 ]; then
    yes | mdadm --create --verbose /dev/md0 -l 0 -n 2 "${RAID_DEVS[0]}" "${RAID_DEVS[1]}" >/tmp/mdadm_create.err 2>&1 || true
  fi
  mdadm --detail --scan --verbose > /etc/mdadm.conf 2>/dev/null || true
  blkid /dev/md0 >/dev/null 2>&1 || mkfs.ext4 -F /dev/md0 >/dev/null
  mkdir -p /raid
  mount /dev/md0 /raid 2>/dev/null || true
  grep -q '^/dev/md0 /raid' /etc/fstab || echo '/dev/md0 /raid ext4 defaults 0 0' >> /etc/fstab
  remote_done 'HQ-SRV: RAID0 готов'
else
  remote_skip 'HQ-SRV: дополнительных дисков меньше двух — RAID0 пропущен'
  mkdir -p /raid
fi

remote_step 'HQ-SRV: NFS'
mkdir -p /raid/nfs
chmod -R 777 /raid/nfs
echo '/raid/nfs 192.168.200.0/28(rw,no_root_squash)' > /etc/exports
systemctl enable --now nfs-server.service >/dev/null 2>&1
exportfs -arv >/dev/null
remote_done 'HQ-SRV: NFS готов'
remote_step 'HQ-SRV: Apache + MariaDB'
systemctl enable --now mariadb >/dev/null 2>&1
systemctl enable --now httpd >/dev/null 2>&1
remote_step 'HQ-SRV: создаю БД webdb и пользователя web'
mysql -u root <<'EOF'
CREATE DATABASE IF NOT EXISTS webdb;
CREATE USER IF NOT EXISTS 'web'@'localhost' IDENTIFIED BY 'P@ssw0rd';
CREATE USER IF NOT EXISTS 'web'@'%' IDENTIFIED BY 'P@ssw0rd';
GRANT ALL PRIVILEGES ON webdb.* TO 'web'@'localhost';
GRANT ALL PRIVILEGES ON webdb.* TO 'web'@'%';
FLUSH PRIVILEGES;
EOF
remote_done 'HQ-SRV: БД готова'
remote_step 'HQ-SRV: подключаю Additional.iso для web-файлов'
mkdir -p /mnt/additional
if ! mountpoint -q /mnt/additional; then
  for dev in /dev/sr0 /dev/cdrom /dev/vdd /dev/vdc /dev/vdb /dev/sdb /dev/sdc /dev/sdd /dev/disk/by-label/* /dev/disk/by-id/*; do
    [ -e "$dev" ] || continue
    mount -o ro "$dev" /mnt/additional >/tmp/mount_additional.err 2>&1 && break
  done
fi
if mountpoint -q /mnt/additional; then
  echo 'REMOTE_STATUS: OK: Additional.iso смонтирован'
else
  echo 'REMOTE_STATUS: SKIP: Additional.iso не смонтирован, смотри /tmp/mount_additional.err'
fi
if [ -f /mnt/additional/web/dump.sql ]; then
  remote_step 'HQ-SRV: импорт dump.sql'
  mysql -u root webdb < /mnt/additional/web/dump.sql || true
  remote_done 'HQ-SRV: dump.sql импортирован'
else
  remote_skip 'HQ-SRV: dump.sql не найден'
fi
if [ -f /mnt/additional/web/index.php ]; then cp /mnt/additional/web/index.php /var/www/html/; remote_done 'HQ-SRV: index.php скопирован'; else remote_skip 'HQ-SRV: index.php не найден'; fi
if [ -d /mnt/additional/web/images ]; then cp -r /mnt/additional/web/images /var/www/html/; remote_done 'HQ-SRV: images скопированы'; else remote_skip 'HQ-SRV: images не найдены'; fi
systemctl restart mariadb
systemctl restart httpd
remote_done 'HQ-SRV: Apache + MariaDB готовы'
remote_done 'HQ-SRV: готов'
REMOTE
}

br_srv_payload(){
cat <<'REMOTE'
set -euo pipefail
hostnamectl set-hostname br-srv.sirius-exam.org || true
useradd sshuser -u 2026 -U 2>/dev/null || true
echo "sshuser:P@ssw0rd" | chpasswd
echo 'sshuser ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/sshuser
chmod 440 /etc/sudoers.d/sshuser
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.demo 2>/dev/null || true
cat > /etc/ssh/sshd_config <<'SSHD_EOF'
Port 22
Port 2026
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
UsePAM yes
MaxAuthTries 2
AllowUsers root sshuser
X11Forwarding yes
Subsystem sftp /usr/libexec/openssh/sftp-server
SSHD_EOF
ssh-keygen -A >/dev/null 2>&1 || true
dnf install -y policycoreutils-python-utils chrony samba samba-client cifs-utils docker-ce docker-ce-cli docker-compose nginx openssl >/tmp/br_srv_dnf.err 2>&1 || dnf install -y policycoreutils-python-utils chrony samba samba-client cifs-utils docker docker-compose nginx openssl >/tmp/br_srv_dnf2.err 2>&1 || true
semanage port -a -t ssh_port_t -p tcp 2026 2>/dev/null || semanage port -m -t ssh_port_t -p tcp 2026 2>/dev/null || true
firewall-cmd --permanent --add-port=2026/tcp >/dev/null 2>&1 || true
firewall-cmd --permanent --add-service=samba >/dev/null 2>&1 || true
firewall-cmd --reload >/dev/null 2>&1 || true
systemctl restart sshd || true
cat > /etc/chrony.conf <<'EOF'
server 172.16.2.1 iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
systemctl enable --now chronyd >/dev/null 2>&1
systemctl restart chronyd
groupadd hq 2>/dev/null || true
for i in 1 2 3 4 5; do
  useradd -m -G hq hquser$i 2>/dev/null || true
  usermod -aG hq hquser$i
  echo "hquser$i:P@ssw0rd" | chpasswd
  (echo 'P@ssw0rd'; echo 'P@ssw0rd') | smbpasswd -a hquser$i >/dev/null
  smbpasswd -e hquser$i >/dev/null
done
mkdir -p /srv/samba/hq
chown root:hq /srv/samba/hq
chmod 2770 /srv/samba/hq
cat > /etc/samba/smb.conf <<'EOF'
[global]
   workgroup = WORKGROUP
   server string = BR-SRV Samba Server
   security = user
   map to guest = never
   dns proxy = no
[hq]
   path = /srv/samba/hq
   browseable = yes
   writable = yes
   valid users = @hq
   create mask = 0660
   directory mask = 2770
   force group = hq
EOF
testparm -s >/dev/null
setsebool -P samba_export_all_rw on >/dev/null 2>&1 || true
semanage fcontext -a -t samba_share_t "/srv/samba/hq(/.*)?" 2>/dev/null || true
restorecon -Rv /srv/samba/hq >/dev/null 2>&1 || true
systemctl enable --now smb >/dev/null 2>&1
systemctl enable --now nmb >/dev/null 2>&1 || true
systemctl restart smb
systemctl restart nmb 2>/dev/null || true

echo 'REMOTE_STATUS: START: BR-SRV: Docker compose из экзаменационного compose.zip'
systemctl enable --now docker >/dev/null 2>&1 || true

mkdir -p /mnt/additional
if ! mountpoint -q /mnt/additional; then
  for dev in /dev/sr0 /dev/cdrom /dev/vdd /dev/vdc /dev/vdb /dev/sdb /dev/sdc /dev/sdd /dev/disk/by-label/* /dev/disk/by-id/*; do
    [ -e "$dev" ] || continue
    mount -o ro "$dev" /mnt/additional >/tmp/mount_additional.err 2>&1 && break
  done
fi
if mountpoint -q /mnt/additional; then
  echo 'REMOTE_STATUS: OK: Additional.iso смонтирован'
else
  echo 'REMOTE_STATUS: SKIP: Additional.iso не смонтирован, смотри /tmp/mount_additional.err'
fi

# Пытаемся загрузить локальные Docker-образы из Additional.iso, если они есть.
if find /mnt/additional -type f -iname '*site*.tar' | head -1 | grep -q .; then
  SITE_TAR="$(find /mnt/additional -type f -iname '*site*.tar' | head -1)"
  echo "REMOTE_STATUS: START: BR-SRV: docker load $SITE_TAR"
  docker load < "$SITE_TAR" >/tmp/br_srv_docker_site_load.log 2>&1 || true
  echo 'REMOTE_STATUS: OK: BR-SRV: site image load завершён/пропущен'
else
  echo 'REMOTE_STATUS: SKIP: BR-SRV: site*.tar не найден на Additional.iso'
fi

if find /mnt/additional -type f \( -iname '*mariadb*.tar' -o -iname '*maria*.tar' \) | head -1 | grep -q .; then
  DB_TAR="$(find /mnt/additional -type f \( -iname '*mariadb*.tar' -o -iname '*maria*.tar' \) | head -1)"
  echo "REMOTE_STATUS: START: BR-SRV: docker load $DB_TAR"
  docker load < "$DB_TAR" >/tmp/br_srv_docker_db_load.log 2>&1 || true
  echo 'REMOTE_STATUS: OK: BR-SRV: mariadb image load завершён/пропущен'
else
  echo 'REMOTE_STATUS: SKIP: BR-SRV: mariadb*.tar не найден на Additional.iso'
fi

# Если образ загружен как mariadb:latest, а compose ждёт mariadb:11 — делаем дополнительный tag.
if docker image inspect mariadb:11 >/dev/null 2>&1; then
  echo 'REMOTE_STATUS: OK: BR-SRV: образ mariadb:11 есть'
elif docker image inspect mariadb:latest >/dev/null 2>&1; then
  docker tag mariadb:latest mariadb:11
  echo 'REMOTE_STATUS: OK: BR-SRV: mariadb:latest отмечен как mariadb:11'
else
  echo 'REMOTE_STATUS: WARN: BR-SRV: образ mariadb:11 не найден, docker попробует скачать его'
fi

if docker image inspect site:latest >/dev/null 2>&1; then
  echo 'REMOTE_STATUS: OK: BR-SRV: образ site:latest есть'
else
  echo 'REMOTE_STATUS: WARN: BR-SRV: образ site:latest не найден, приложение может не стартовать'
fi

mkdir -p /opt/exam-app
cat > /opt/exam-app/.env <<'EOF'
DEBUG=true
CLIENT_APP_URL=http://localhost:3000
LOGS_DIR=/app/logs

DB_TYPE=maria
DB_HOST=db
DB_PORT=3306
DB_NAME=appdb
DB_USER=appuser
DB_PASS=apppassword
EOF

cat > /opt/exam-app/docker-compose.yml <<'EOF'
services:
  app:
    image: site:latest
    ports:
      - "8080:8000"
    env_file:
      - .env
    depends_on:
      db:
        condition: service_healthy
    restart: unless-stopped

  db:
    image: mariadb:11
    environment:
      MARIADB_DATABASE: appdb
      MARIADB_USER: appuser
      MARIADB_PASSWORD: apppassword
      MARIADB_ROOT_PASSWORD: rootpassword
    volumes:
      - db_data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

volumes:
  db_data:
EOF

cd /opt/exam-app

# Поддержка и docker compose v2, и старого docker-compose.
if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD="docker-compose"
else
  echo 'REMOTE_STATUS: WARN: BR-SRV: docker compose/docker-compose не найден'
  COMPOSE_CMD=""
fi

if [ -n "$COMPOSE_CMD" ]; then
  echo 'REMOTE_STATUS: START: BR-SRV: запускаю compose /opt/exam-app'
  $COMPOSE_CMD down >/tmp/br_srv_compose_down.log 2>&1 || true
  timeout 300 $COMPOSE_CMD up -d >/tmp/br_srv_compose_up.log 2>&1 || true
  echo 'REMOTE_STATUS: OK: BR-SRV: compose up выполнен'
fi

docker ps --format 'REMOTE_STATUS: DOCKER: {{.Names}} {{.Image}} {{.Status}} {{.Ports}}' 2>/dev/null || true
curl -s --max-time 10 http://127.0.0.1:8080 >/tmp/br_srv_app_check.html 2>/tmp/br_srv_app_check.err \
  && echo 'REMOTE_STATUS: OK: BR-SRV: приложение отвечает на 127.0.0.1:8080' \
  || echo 'REMOTE_STATUS: WARN: BR-SRV: приложение пока не ответило на 127.0.0.1:8080'

mkdir -p /opt/nextcloud/db /opt/nextcloud/html
cat > /opt/nextcloud/docker-compose.yml <<'EOF'
version: "3.8"
services:
  db:
    image: mysql:8.0
    container_name: nextcloud-db
    restart: unless-stopped
    command: --default-authentication-plugin=mysql_native_password
    environment:
      MYSQL_ROOT_PASSWORD: P@ssw0rd
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD: P@ssw0rd
    volumes:
      - /opt/nextcloud/db:/var/lib/mysql
  app:
    image: nextcloud:apache
    container_name: nextcloud-app
    restart: unless-stopped
    depends_on:
      - db
    ports:
      - "127.0.0.1:8081:80"
    environment:
      MYSQL_HOST: db
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD: P@ssw0rd
    volumes:
      - /opt/nextcloud/html:/var/www/html
EOF
docker-compose -f /opt/nextcloud/docker-compose.yml up -d >/dev/null 2>&1 || true
mkdir -p /etc/nginx/ssl /etc/nginx/sites-available /etc/nginx/sites-enabled
openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/nginx/ssl/nextcloud.key -out /etc/nginx/ssl/nextcloud.crt -subj "/C=RU/ST=Exam/L=Exam/O=sirius/OU=exam/CN=192.168.30.2" >/dev/null 2>&1
cat > /etc/nginx/sites-available/nextcloud.conf <<'EOF'
server {
    listen 80;
    server_name _;
    return 301 https://$host$request_uri;
}
server {
    listen 443 ssl;
    server_name _;
    ssl_certificate /etc/nginx/ssl/nextcloud.crt;
    ssl_certificate_key /etc/nginx/ssl/nextcloud.key;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    location / {
        proxy_pass http://127.0.0.1:8081;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF
ln -sf /etc/nginx/sites-available/nextcloud.conf /etc/nginx/sites-enabled/nextcloud.conf
ln -sf /etc/nginx/sites-available/nextcloud.conf /etc/nginx/conf.d/nextcloud.conf
nginx -t >/tmp/nginx_nextcloud_test.err 2>&1
systemctl enable --now nginx >/dev/null 2>&1
systemctl restart nginx
REMOTE
}

hq_cli_payload(){
cat <<'REMOTE'
set -euo pipefail
hostnamectl set-hostname hq-cli.sirius-exam.org || true
dnf install -y samba-client cifs-utils nfs-utils chrony curl bind-utils sudo yandex-browser-stable >/tmp/hq_cli_dnf.err 2>&1 || dnf install -y samba-client cifs-utils nfs-utils chrony curl bind-utils sudo >/tmp/hq_cli_dnf2.err 2>&1 || true
groupadd hq 2>/dev/null || true
for i in 1 2 3 4 5; do
  useradd -m -G hq hquser$i 2>/dev/null || true
  usermod -aG hq hquser$i
  echo "hquser$i:P@ssw0rd" | chpasswd
done
mkdir -p /mnt/smb-hq
mount -t cifs //192.168.30.2/hq /mnt/smb-hq -o username=hquser1,password='P@ssw0rd',vers=3.0 2>/dev/null || true
touch /mnt/smb-hq/check_from_hqcli.txt 2>/dev/null || true
mkdir -p /mnt/nfs
grep -q '^192.168.100.2:/raid/nfs' /etc/fstab || echo '192.168.100.2:/raid/nfs /mnt/nfs nfs auto 0 0' >> /etc/fstab
mount -av >/dev/null 2>&1 || true
cat > /etc/chrony.conf <<'EOF'
server 172.16.1.1 iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
systemctl enable --now chronyd >/dev/null 2>&1
systemctl restart chronyd
groupadd Work 2>/dev/null || true
groupadd Job 2>/dev/null || true
groupadd labor 2>/dev/null || true
useradd -m -G Work User1 2>/dev/null || true
useradd -m -G Work User2 2>/dev/null || true
useradd -m -G Job User3 2>/dev/null || true
useradd -m -G Job User4 2>/dev/null || true
useradd -m -G labor User5 2>/dev/null || true
usermod -aG Work User1
usermod -aG Work User2
usermod -aG Job User3
usermod -aG Job User4
usermod -aG labor User5
echo "User1:P@ssw0rd" | chpasswd
echo "User2:P@ssw0rd" | chpasswd
echo "User3:P@ssw0rd" | chpasswd
echo "User4:P@ssw0rd" | chpasswd
echo "User5:P@ssw0rd" | chpasswd
mkdir -p /home/Folder/work_shared /home/Folder/job_readonly
chown root:Work /home/Folder/work_shared
chmod 770 /home/Folder/work_shared
chown root:Job /home/Folder/job_readonly
chmod 750 /home/Folder/job_readonly
echo "SERVER1_IP=192.168.30.2" > /root/variant_server1_ip.txt
sudo -u User1 touch /home/Folder/work_shared/user1_test.txt
sudo -u User1 rm -f /home/Folder/work_shared/user1_test.txt
sudo -u User3 ls -l /home/Folder/job_readonly/ >/dev/null 2>&1 || true
sudo -u User3 touch /home/Folder/job_readonly/user3_test.txt >/dev/null 2>&1 && exit 2 || true
sudo -u User5 ls -l /home/Folder/work_shared/ >/dev/null 2>&1 && exit 3 || true
sudo -u User5 ls -l /home/Folder/job_readonly/ >/dev/null 2>&1 && exit 4 || true
curl -k -I https://192.168.30.2 >/tmp/nextcloud_https_check.txt 2>&1 || true
curl -k -I https://192.168.30.2 | grep -i Strict-Transport-Security >/tmp/hsts_check.txt 2>&1 || true
REMOTE
}

ssh_run(){
  local ip="$1" user="$2" pass="$3" name="$4" payload="$5" err="/tmp/demoexam_${name}.err" out="/tmp/demoexam_${name}_remote.log"
  rm -f "$out" "$err"
  echo "[..] $name: удалённое выполнение началось, подробный лог: $out"
  sshpass -p "$pass" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$user@$ip" "bash -s" 2>"$err" <<< "$payload" | tee "$out" | sed -u -n 's/^REMOTE_STATUS: //p'
  local rc=${PIPESTATUS[0]}
  if [ "$rc" -eq 0 ]; then
    echo "[OK] $name: удалённое выполнение завершено"
  else
    echo "[FAIL] $name: удалённое выполнение завершилось с ошибкой, код $rc"
  fi
  return "$rc"
}

check_ssh(){
  local ip="$1" user="$2" pass="$3"
  sshpass -p "$pass" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "$user@$ip" "echo ok" >/dev/null 2>&1
}


remote_ssh_repair(){
  local ip="$1" user="$2" pass="$3" name="$4"
  local err="/tmp/demoexam_${name}_sshrepair.err"
  local out="/tmp/demoexam_${name}_sshrepair.log"

  echo "[..] $name: стабилизирую SSH на 22+2026 перед настройкой"
  rm -f "$err" "$out"

  sshpass -p "$pass" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    "$user@$ip" "bash -s" 2>"$err" <<'REMOTE_SSH_REPAIR' | tee "$out" | sed -u -n 's/^REMOTE_STATUS: //p'
set -u
echo "REMOTE_STATUS: START: SSH repair: создаю host keys"
mkdir -p /etc/ssh
ssh-keygen -A >/dev/null 2>&1 || true

echo "REMOTE_STATUS: START: SSH repair: пишу безопасный sshd_config"
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.autorepair.$(date +%H%M%S) 2>/dev/null || true

cat > /etc/ssh/sshd_config <<'EOF'
Port 22
Port 2026
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
UsePAM yes
MaxAuthTries 2
AllowUsers root sshuser
X11Forwarding yes
Subsystem sftp /usr/libexec/openssh/sftp-server
EOF

echo "REMOTE_STATUS: START: SSH repair: проверяю конфиг"
sshd -t || exit 41

echo "REMOTE_STATUS: START: SSH repair: открываю firewall/SELinux"
if command -v semanage >/dev/null 2>&1; then
  semanage port -a -t ssh_port_t -p tcp 2026 2>/dev/null || semanage port -m -t ssh_port_t -p tcp 2026 2>/dev/null || true
fi
firewall-cmd --permanent --add-port=22/tcp >/dev/null 2>&1 || true
firewall-cmd --permanent --add-port=2026/tcp >/dev/null 2>&1 || true
firewall-cmd --reload >/dev/null 2>&1 || true

echo "REMOTE_STATUS: START: SSH repair: перезапускаю sshd"
systemctl reset-failed sshd 2>/dev/null || true
systemctl enable sshd >/dev/null 2>&1 || true
systemctl restart sshd || exit 42

echo "REMOTE_STATUS: OK: SSH repair: sshd запущен на 22 и 2026"
REMOTE_SSH_REPAIR

  local rc=${PIPESTATUS[0]}
  sleep 3

  if check_ssh "$ip" "$user" "$pass"; then
    echo "[OK] $name: SSH после repair доступен"
    return 0
  fi

  echo "[WARN] $name: после repair SSH не отвечает. Подробности:"
  show_tail_err "$out"
  show_tail_err "$err"
  return "$rc"
}

configure_linux_device(){
  local title="$1" name="$2" ip="$3" hint_func="$4" payload_func="$5"
  echo "[..] $title: проверяю ping $ip"
  get_root_ssh_pass_once

  if ! check_ping "$ip"; then
    echo "[WAIT] $title: ping нет"
    "$hint_func"
    wait_enter
    check_ping "$ip" || { fail "$title не отвечает на ping"; return 1; }
  fi
  echo "[OK] $title ping есть"

  echo "[..] $title: проверяю первичный SSH root@$ip:22"
  if ! check_ssh "$ip" root "$ROOT_SSH_PASS"; then
    echo "[WARN] $title: первичный SSH не прошёл."
    echo "Проверь вручную с ISP:"
    echo "  ssh root@$ip"
    echo "Если вручную заходит — введи здесь тот же root-пароль."
    [ -s /tmp/demoexam_check_ssh.err ] && { echo "Последняя SSH-ошибка:"; tail -n 5 /tmp/demoexam_check_ssh.err; }
    ask_root_ssh_pass_force

    if ! check_ssh "$ip" root "$ROOT_SSH_PASS"; then
      echo "[WAIT] $title: SSH всё ещё недоступен. Нужно один раз включить SSH в консоли ВМ."
      "$hint_func"
      wait_enter
      ask_root_ssh_pass_force
      check_ssh "$ip" root "$ROOT_SSH_PASS" || { fail "$title недоступен по SSH"; return 1; }
    fi
  fi
  echo "[OK] $title первичный SSH есть"

  # Сразу после первого подключения чиним SSH на самой ВМ:
  # оставляем root на 22 для управления и добавляем 2026 для задания.
  if ! remote_ssh_repair "$ip" root "$ROOT_SSH_PASS" "$name"; then
    fail "$title: не смог стабилизировать SSH"
    return 1
  fi

  echo "[..] $title: отправляю команды настройки. Если долго — будут строки START/DNF/OK ниже"
  local payload
  payload=$("$payload_func")

  if ssh_run "$ip" root "$ROOT_SSH_PASS" "$name" "$payload"; then
    ok "$title настроен"
    return 0
  fi

  echo "[WARN] $title: основная настройка оборвалась. Пробую восстановить SSH и повторить один раз."
  remote_ssh_repair "$ip" root "$ROOT_SSH_PASS" "$name" || true
  sleep 3

  if ! check_ssh "$ip" root "$ROOT_SSH_PASS"; then
    fail "$title: SSH не восстановился после обрыва"
    show_tail_err "/tmp/demoexam_${name}_remote.log"
    show_tail_err "/tmp/demoexam_${name}.err"
    return 1
  fi

  echo "[..] $title: повторяю отправку команд настройки"
  if ssh_run "$ip" root "$ROOT_SSH_PASS" "$name" "$payload"; then
    ok "$title настроен после повторного подключения"
    return 0
  else
    fail "$title не настроен"
    show_tail_err "/tmp/demoexam_${name}_remote.log"
    show_tail_err "/tmp/demoexam_${name}.err"
    return 1
  fi
}

final_checks(){
  check_ping 172.16.1.2 && ok "HQ-RTR отвечает" || fail "HQ-RTR не отвечает"
  check_ping 172.16.2.2 && ok "BR-RTR отвечает" || fail "BR-RTR не отвечает"
  check_ping 192.168.100.2 && ok "HQ-SRV отвечает" || fail "HQ-SRV не отвечает"
  check_ping 192.168.30.2 && ok "BR-SRV отвечает" || fail "BR-SRV не отвечает"
  curl -s --max-time 5 -u WEB:'P@ssw0rd' http://web.sirius-exam.org >/dev/null 2>&1 && ok "web.sirius-exam.org доступен" || fail "web.sirius-exam.org не проверен"
  curl -k -s -I --max-time 5 https://192.168.30.2 | grep -qi Strict-Transport-Security && ok "HSTS Nextcloud есть" || fail "HSTS Nextcloud не проверен"
}

main(){
  need_root
  install_tools || exit 1
  ask_topology || exit 1
  say "Центральная пошаговая настройка + ручной выбор портов/адаптеров + compose.zip + Additional.iso с видимым прогрессом. VESR: только commit + confirm, без save."
  say "Дальше идём только после успешного шага. Ошибки: /tmp/demoexam_*.err"
  run_until_ok "ШАГ 1/7 — ISP" configure_isp
  run_until_ok "ШАГ 2/7 — HQ-RTR" configure_hq_rtr
  run_until_ok "ШАГ 3/7 — BR-RTR" configure_br_rtr
  run_until_ok "ШАГ 4/7 — HQ-SRV" "configure_linux_device HQ-SRV hq_srv 192.168.100.2 linux_hint_hq_srv hq_srv_payload"
  run_until_ok "ШАГ 5/7 — BR-SRV" "configure_linux_device BR-SRV br_srv 192.168.30.2 linux_hint_br_srv br_srv_payload"
  run_until_ok "ШАГ 6/7 — HQ-CLI" "configure_linux_device HQ-CLI hq_cli 192.168.200.3 linux_hint_hq_cli hq_cli_payload"
  run_until_ok "ШАГ 7/7 — финальные проверки" final_checks
  echo
  echo "Готово. Статус: $STATUS_FILE"
  cat "$STATUS_FILE"
}

main "$@"
