#!/bin/bash
# demoexam_central_master_step.sh
# PATCH v26-hostkey: SSH host-key prompts yes/no/[fingerprint] are accepted automatically.
# PATCH v26-hostkey: SSH uses StrictHostKeyChecking=no and /dev/null known_hosts.
# PATCH v27-dns: before any Linux dnf install, force working public DNS on active/default interface.
# PATCH v28-dnf-live-log: stream dnf output to console with REMOTE_STATUS prefix and save the same log file.
# PATCH v29-dnf-clean-timeout: dnf clean all also has live log and timeout, so script does not appear frozen.
# PATCH v30-dnf-lock-kill: before dnf clean/install, kill stuck old dnf/rpm processes that block the package manager.
# PATCH v31-clean-newline-fix: fix broken dnf clean command line and show clean/install logs correctly.
# PATCH v32-stale-dnf-lock: remove stale dnf lock pid files when dnf waits for a dead PID.
# PATCH v33-dnf-heartbeat: run dnf with heartbeat every 20 seconds, show PID, elapsed time and last log lines.
# PATCH v34-dnf-empty-log-retry: if dnf log is empty for 60 seconds, kill dnf, remove stale locks, rebuild rpmdb and retry once.
# PATCH v35-no-dnf-clean: do not run dnf clean all before installs, because RedOS metadata is huge and slow to re-download.
# PATCH v36-hard-dnf: hard-kill all old dnf/rpm/packagekit locks before install; rebuild rpmdb only if rpm query is broken.
# PATCH v37-parallel-linux: HQ-SRV, BR-SRV and HQ-CLI run in parallel; failed Linux node does not stop other nodes.
# PATCH v38-safe-raid: do not use zram or root disk for RAID; if no two real extra disks, fallback to /raid directory and continue.
# PATCH v39-skip-on-error: on failed step ask retry yes/no; default no skips to next device. Linux nodes run in parallel.
# PATCH v40-step-purpose: before every major step, print what device is being configured and what will be done.
# PATCH v41-podman-docker: RedOS docker package may install podman-docker; accept docker command/podman socket and podman-compose.
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

# Proxmox bridge labels. Можно переопределить переменными окружения перед запуском.
WAN_BRIDGE="${WAN_BRIDGE:-vmbr0}"
ISP_HQ_BRIDGE="${ISP_HQ_BRIDGE:-vmbr1041}"
ISP_BR_BRIDGE="${ISP_BR_BRIDGE:-vmbr1042}"
HQ_SRV_BRIDGE="${HQ_SRV_BRIDGE:-vmbr1043}"
HQ_CLI_BRIDGE="${HQ_CLI_BRIDGE:-vmbr1044}"
BR_LAN_BRIDGE="${BR_LAN_BRIDGE:-vmbr1045}"


ROOT_SSH_USER="${ROOT_SSH_USER:-root}"
ROOT_SSH_PASS="${ROOT_SSH_PASS:-}"

# Интерактивная карта портов/интерфейсов. Можно заранее задать через переменные окружения.
HQR_ISP_PORT="${HQR_ISP_PORT:-gigabitethernet 1/0/2}"
HQR_SRV_PORT="${HQR_SRV_PORT:-gigabitethernet 1/0/3}"
HQR_CLI_PORT="${HQR_CLI_PORT:-gigabitethernet 1/0/4}"
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

print_step_purpose(){
  local title="$1"

  echo "+"
  echo "+ Что сейчас будет выполняться:"
  case "$title" in
    *"утилиты ISP"*)
      echo "+ Подготовить ISP: проверить/установить expect, sshpass и ssh-клиент."
      echo "+ Это нужно, чтобы ISP мог автоматически подключаться к Eltex и Linux-ВМ."
      ;;
    *"автоопределение топологии"*)
      echo "+ Определить фактическую топологию стенда."
      echo "+ ISP: найти WAN, ISP-HQ и ISP-BR."
      echo "+ Eltex: прочитать show running-config и определить порты HQ-RTR/BR-RTR."
      ;;
    *"ШАГ 1/7 — ISP"*)
      echo "+ Настроить машину ISP."
      echo "+ Будет настроено: IP на ISP-HQ/ISP-BR, маршрутизация, NAT, nftables, базовые сервисы ISP."
      ;;
    *"ШАГ 2/7 — HQ-RTR"*)
      echo "+ Настроить роутер HQ-RTR."
      echo "+ Будет настроено: интерфейсы ISP-HQ/HQ-SRV/HQ-CLI, маршруты, SSH, базовая маршрутизация HQ."
      ;;
    *"ШАГ 3/7 — BR-RTR"*)
      echo "+ Настроить роутер BR-RTR."
      echo "+ Будет настроено: интерфейсы BR-LAN/ISP-BR, маршруты, SSH, базовая маршрутизация филиала."
      ;;
    *"ШАГ 4-6/7 — Linux-узлы параллельно"*)
      echo "+ Настроить Linux-узлы параллельно: HQ-SRV, BR-SRV и HQ-CLI."
      echo "+ Пока один узел ставит пакеты, остальные не ждут и тоже настраиваются."
      echo "+ Если один узел упадёт, остальные продолжат работу."
      ;;
    *"ШАГ 4/7 — HQ-SRV"*)
      echo "+ Настроить сервер HQ-SRV."
      echo "+ Будет настроено: hostname, SSH, DNS/BIND, Chrony, NFS/RAID или /raid, Apache/PHP/MariaDB."
      ;;
    *"ШАГ 5/7 — BR-SRV"*)
      echo "+ Настроить сервер BR-SRV."
      echo "+ Будет настроено: hostname, SSH, Docker/Compose, сервисы филиала и web-контейнер."
      ;;
    *"ШАГ 6/7 — HQ-CLI"*)
      echo "+ Настроить клиент HQ-CLI."
      echo "+ Будет настроено: hostname, SSH, сеть/DHCP-клиент, DNS-проверки и клиентские параметры."
      ;;
    *"ШАГ 7/7 — финальные проверки"*)
      echo "+ Выполнить финальные проверки стенда."
      echo "+ Будут проверены: ping, SSH, DNS, web/proxy, Docker/NAT и доступность основных сервисов."
      ;;
    *)
      echo "+ Выполнить шаг: $title"
      ;;
  esac
  echo "+"
}


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
  local ans=""
  while true; do
    say ""
    say "━━━━━━━━━━━━━━━━━━━━━━━━━━"
    say "$title"
    say "попытка $n"
    say "━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_step_purpose "$title"

    if eval "$cmd"; then
      ok "$title завершён"
      return 0
    fi

    say ""
    fail "$title завершился с ошибкой"
    say "[CHOICE] Повторить этот шаг?"
    say "  yes/y/да  = повторить"
    say "  no/n/нет или Enter = пропустить и перейти к следующему устройству"
    read -rp "Повторить? yes/no [no]: " ans
    ans="${ans:-no}"

    case "$ans" in
      yes|y|Y|да|ДА|д|Д)
        n=$((n+1))
        ;;
      *)
        say "[SKIP] $title пропущен по выбору пользователя. Иду дальше."
        echo "SKIP $title" >> "$STATUS_FILE"
        return 0
        ;;
    esac
  done
}


normalize_vesr_port(){
  local x="$1"
  x="${x//[$'\t\r\n ']}"
  if [[ "$x" =~ ^[0-9]+$ ]]; then
    echo "gigabitethernet 1/0/$x"
  elif [[ "$x" =~ ^gi([0-9]+)$ ]]; then
    echo "gigabitethernet 1/0/${BASH_REMATCH[1]}"
  elif [[ "$x" =~ ^1/0/([0-9]+)$ ]]; then
    echo "gigabitethernet 1/0/${BASH_REMATCH[1]}"
  elif [[ "$x" =~ ^gigabitethernet ]]; then
    echo "$x"
  else
    echo "$x"
  fi
}

ask_port_num(){
  local prompt="$1"
  local def_num="$2"
  local ans
  read -rp "$prompt [$def_num]: " ans
  ans="${ans:-$def_num}"
  normalize_vesr_port "$ans"
}

print_bridge_map_hint(){
  cat <<EOF

Как понять порт Eltex:
1. В Proxmox открой ВМ → Оборудование.
2. У каждого "Сетевое устройство" смотри:
   bridge/vmbr и MAC-адрес.
3. На Eltex выполни:
   show interfaces status
4. Сравни MAC из Proxmox с MAC в Eltex.
5. В скрипт вводи ТОЛЬКО последнюю цифру порта:
   2 = gigabitethernet 1/0/2
   3 = gigabitethernet 1/0/3

Карта мостов Proxmox для этого стенда:
  $WAN_BRIDGE    = WAN / Интернет
  $ISP_HQ_BRIDGE = ISP-HQ
  $ISP_BR_BRIDGE = ISP-BR
  $HQ_SRV_BRIDGE = HQ-SRV-Net
  $HQ_CLI_BRIDGE = HQ-CLI-Net
  $BR_LAN_BRIDGE = BR-Net / BR-LAN

Что это значит:
  HQ-RTR порт с bridge $ISP_HQ_BRIDGE = порт к ISP-HQ
  HQ-RTR порт с bridge $HQ_SRV_BRIDGE = порт к HQ-SRV
  HQ-RTR порт с bridge $HQ_CLI_BRIDGE = порт к HQ-CLI

  BR-RTR порт с bridge $BR_LAN_BRIDGE = порт к BR-Net / BR-LAN
  BR-RTR порт с bridge $ISP_BR_BRIDGE = порт к ISP-BR

EOF
}

ask_default(){
  local prompt="$1"
  local def="$2"
  local ans
  read -rp "$prompt [$def]: " ans
  echo "${ans:-$def}"
}

ask_set(){
  local varname="$1"
  local prompt="$2"
  local def="$3"
  local ans=""
  printf "\n%s\n" "$prompt"
  printf "Enter = оставить [%s]\n> " "$def"
  read -r ans
  ans="${ans:-$def}"
  printf -v "$varname" '%s' "$ans"
}

ask_port_set(){
  local varname="$1"
  local prompt="$2"
  local def_num="$3"
  local ans=""
  printf "\n%s\n" "$prompt"
  printf "Введи только цифру порта. Например: 2 = gigabitethernet 1/0/2\n"
  printf "Enter = оставить [%s]\n> " "$def_num"
  read -r ans
  ans="${ans:-$def_num}"
  ans="$(normalize_vesr_port "$ans")"
  printf -v "$varname" '%s' "$ans"
}

ask_optional_port_set(){
  local varname="$1"
  local prompt="$2"
  local def_num="$3"
  local ans=""
  printf "\n%s\n" "$prompt"
  printf "Введи только цифру порта. Например: 2 = gigabitethernet 1/0/2\n"
  printf "Если такого адаптера НЕТ — введи 0 или skip.\n"
  printf "Enter = [%s]\n> " "$def_num"
  read -r ans
  ans="${ans:-$def_num}"
  if [[ "$ans" =~ ^(0|none|NONE|skip|SKIP|-)$ ]]; then
    ans: # HQ-MGMT removed
  else
    ans="$(normalize_vesr_port "$ans")"
  fi
  printf -v "$varname" '%s' "$ans"
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
  say ""
  say "============================================================"
  say "КАРТА СЕТЕЙ И ПОРТОВ"
  say "============================================================"
  say "Скрипт сейчас спросит, какая сеть куда подключена."
  say "Если у тебя как на скрине Proxmox, почти везде можно нажимать Enter."
  say ""
  say "Твоя типовая карта Proxmox:"
  say "  vmbr0    = WAN / Интернет"
  say "  vmbr1041 = ISP-HQ"
  say "  vmbr1042 = ISP-BR"
  say "  vmbr1043 = HQ-SRV-Net"
  say "  vmbr1044 = HQ-CLI-Net"
  say "  vmbr1045 = BR-Net"
  say ""

  ask_set WAN_BRIDGE "1/6. Bridge WAN / Интернет" "$WAN_BRIDGE"
  ask_set ISP_HQ_BRIDGE "2/6. Bridge ISP-HQ, сеть между ISP и HQ-RTR" "$ISP_HQ_BRIDGE"
  ask_set ISP_BR_BRIDGE "3/6. Bridge ISP-BR, сеть между ISP и BR-RTR" "$ISP_BR_BRIDGE"
  ask_set HQ_SRV_BRIDGE "4/6. Bridge HQ-SRV-Net, сеть между HQ-RTR и HQ-SRV" "$HQ_SRV_BRIDGE"
  ask_set HQ_CLI_BRIDGE "5/6. Bridge HQ-CLI-Net, сеть между HQ-RTR и HQ-CLI" "$HQ_CLI_BRIDGE"
  ask_set BR_LAN_BRIDGE "6/6. Bridge BR-Net, сеть между BR-RTR и BR-SRV" "$BR_LAN_BRIDGE"

  say ""
  say "============================================================"
  say "ИНТЕРФЕЙСЫ ISP"
  say "============================================================"
  say "Это имена внутри Linux ISP: enp7s1, enp7s2, enp7s3."
  say "Как проверить на ISP:"
  say "  ip -br a"
  say ""
  say "Обычно:"
  say "  enp7s1 = $WAN_BRIDGE / WAN"
  say "  enp7s2 = $ISP_HQ_BRIDGE / ISP-HQ"
  say "  enp7s3 = $ISP_BR_BRIDGE / ISP-BR"
  say ""

  ask_set WAN_IF "ISP: интерфейс WAN / $WAN_BRIDGE" "${WAN_IF:-enp7s1}"
  ask_set HQ_IF "ISP: интерфейс к HQ-RTR / $ISP_HQ_BRIDGE" "${HQ_IF:-enp7s2}"
  ask_set BR_IF "ISP: интерфейс к BR-RTR / $ISP_BR_BRIDGE" "${BR_IF:-enp7s3}"

  say ""
  say "============================================================"
  say "ПОРТЫ HQ-RTR"
  say "============================================================"
  say "Это порты внутри Eltex: gigabitethernet 1/0/X."
  say "Вводить нужно только последнюю цифру X."
  say ""
  say "Как узнать:"
  say "  1) В Proxmox открой HQ-RTR → Оборудование."
  say "  2) Найди сетевое устройство с нужным bridge, например $HQ_SRV_BRIDGE."
  say "  3) Запомни его MAC."
  say "  4) В консоли HQ-RTR выполни:"
  say "       show interfaces status"
  say "  5) Найди такой же MAC и посмотри gi1/0/X."
  say ""
  say "Если порядок как на твоём скрине:"
  say "  net6 / $ISP_HQ_BRIDGE = порт 2"
  say "  net7 / $HQ_SRV_BRIDGE = порт 3"
  say "  net8 / $HQ_CLI_BRIDGE = порт 4
  отдельного HQ-MGMT адаптера на твоём скрине нет → для HQ-MGMT вводи 0 или просто Enter"
  say ""

  ask_port_set HQ_RTR_ISP_PORT "HQ-RTR: порт к ISP-HQ / $ISP_HQ_BRIDGE" "${HQ_RTR_ISP_NUM:-2}"
  ask_port_set HQ_RTR_SRV_PORT "HQ-RTR: порт к HQ-SRV-Net / $HQ_SRV_BRIDGE" "${HQ_RTR_SRV_NUM:-3}"
  ask_port_set HQ_RTR_CLI_PORT "HQ-RTR: порт к HQ-CLI-Net / $HQ_CLI_BRIDGE" "${HQ_RTR_CLI_NUM:-4}"
  ask_optional_port_set "HQ-RTR: порт к HQ-MGMT. В твоём Proxmox отдельного HQ-MGMT адаптера нет, поэтому жми Enter/0/skip" "${HQ_RTR_MGMT_NUM:-skip}"

  say ""
  say "============================================================"
  say "ПОРТЫ BR-RTR"
  say "============================================================"
  say "BR-Net и BR-LAN — это одно и то же для нашего стенда."
  say "BR-Net = $BR_LAN_BRIDGE."
  say ""
  say "Как узнать порт:"
  say "  Proxmox BR-RTR → Оборудование → смотри bridge и MAC."
  say "  Eltex BR-RTR → show interfaces status → ищи такой же MAC."
  say ""
  say "Обычно:"
  say "  $BR_LAN_BRIDGE / BR-Net = порт 2"
  say "  $ISP_BR_BRIDGE / ISP-BR = порт 3"
  say ""

  ask_port_set BR_RTR_LAN_PORT "BR-RTR: порт к BR-Net / BR-LAN / $BR_LAN_BRIDGE" "${BR_RTR_LAN_NUM:-2}"
  ask_port_set BR_RTR_ISP_PORT "BR-RTR: порт к ISP-BR / $ISP_BR_BRIDGE" "${BR_RTR_ISP_NUM:-3}"

  say ""
  say "============================================================"
  say "LINUX-ИНТЕРФЕЙСЫ НА HQ-SRV / BR-SRV / HQ-CLI"
  say "============================================================"
  say "Это имя сетевой карты внутри Linux-машины."
  say "Как проверить на каждой машине:"
  say "  ip -br a"
  say "На этом стенде QEMU/KVM обычно это ens3."
  say ""

  ask_set HQ_SRV_IF "HQ-SRV: интерфейс в $HQ_SRV_BRIDGE / HQ-SRV-Net" "${HQ_SRV_IF:-enp7s1}"
  ask_set BR_SRV_IF "BR-SRV: интерфейс в $BR_LAN_BRIDGE / BR-Net" "${BR_SRV_IF:-enp7s1}"
  ask_set HQ_CLI_IF "HQ-CLI: интерфейс в $HQ_CLI_BRIDGE / HQ-CLI-Net" "${HQ_CLI_IF:-enp7s1}"

  say ""
  say "============================================================"
  say "ИТОГОВАЯ КАРТА"
  say "============================================================"
  say "  $WAN_BRIDGE    WAN          -> ISP $WAN_IF"
  say "  $ISP_HQ_BRIDGE ISP-HQ       -> ISP $HQ_IF, HQ-RTR $HQ_RTR_ISP_PORT"
  say "  $ISP_BR_BRIDGE ISP-BR       -> ISP $BR_IF, BR-RTR $BR_RTR_ISP_PORT"
  say "  $HQ_SRV_BRIDGE HQ-SRV-Net   -> HQ-RTR $HQ_RTR_SRV_PORT, HQ-SRV $HQ_SRV_IF"
  say "  $HQ_CLI_BRIDGE HQ-CLI-Net   -> HQ-RTR $HQ_RTR_CLI_PORT, HQ-CLI $HQ_CLI_IF"
  say "  $BR_LAN_BRIDGE BR-Net       -> BR-RTR $BR_RTR_LAN_PORT, BR-SRV $BR_SRV_IF"
  say "  HQ-MGMT                  -> HQ-RTR $HQ_RTR_MGMT_PORT"
  say ""
  say "Если всё похоже на твою схему — напиши yes или просто нажми Enter."
  read -rp "Продолжить? yes/no [yes]: " okmap
  okmap="${okmap:-yes}"
  [ "$okmap" = "yes" ] || return 1
}


install_tools(){
  local miss=""

  command -v expect >/dev/null 2>&1 || miss="$miss expect"
  command -v sshpass >/dev/null 2>&1 || miss="$miss sshpass"
  command -v ssh >/dev/null 2>&1 || miss="$miss openssh-clients"

  if [ -n "$miss" ]; then
    echo "[WARN] на ISP нет нужных утилит:$miss"
    echo "[..] Пробую установить только отсутствующие пакеты через dnf. dnf update НЕ запускаю."
    echo "[..] Лог установки: /tmp/demoexam_isp_tools_dnf.log"

    # Иногда после прошлых запусков остаётся lock. Ждём немного, но не бесконечно.
    for i in 1 2 3 4 5 6; do
      if pgrep -f "dnf|yum|rpm" >/dev/null 2>&1; then
        echo "[WAIT] rpm/dnf занят, жду 10 секунд ($i/6)"
        sleep 10
      else
        break
      fi
    done

    timeout 900 dnf install -y --setopt=timeout=20 --setopt=retries=1 $miss 2>&1 | tee /tmp/demoexam_isp_tools_dnf.log || true
  fi

  local still=""
  command -v expect >/dev/null 2>&1 || still="$still expect"
  command -v sshpass >/dev/null 2>&1 || still="$still sshpass"
  command -v ssh >/dev/null 2>&1 || still="$still openssh-clients"

  if [ -n "$still" ]; then
    fail "на ISP всё ещё нет утилит:$still"
    echo "Смотри лог:"
    echo "  cat /tmp/demoexam_isp_tools_dnf.log"
    echo
    echo "Можно попробовать вручную:"
    echo "  dnf install -y$still"
    return 1
  fi

  ok "ISP tools: expect/sshpass/ssh готовы"
}

check_ping(){ ping -c 2 -W 2 "$1" >/dev/null 2>&1; }

show_tail_err(){
  local f="$1"
  [ -f "$f" ] && { echo "----- последние строки $f -----"; tail -n 20 "$f"; echo "-------------------------------"; }
}

check_ssh(){
  local ip="$1" user="$2" pass="$3"
  sshpass -p "$pass" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o UpdateHostKeys=no -o LogLevel=ERROR -o ConnectTimeout=8 -o PubkeyAuthentication=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 "$user@$ip" "echo ok" >/tmp/demoexam_check_ssh.out 2>/tmp/demoexam_check_ssh.err
}

ssh_run(){
  local ip="$1"
  local user="$2"
  local pass="$3"
  local name="$4"
  local payload="$5"
  local err="/tmp/demoexam_${name}.err"
  local out="/tmp/demoexam_${name}_remote.log"
  rm -f "$out" "$err"
  echo "[..] $name: удалённое выполнение началось, подробный лог: $out"
  sshpass -p "$pass" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o UpdateHostKeys=no -o LogLevel=ERROR -o ConnectTimeout=10 -o PubkeyAuthentication=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 "$user@$ip" "bash -s" 2>"$err" <<< "$payload" | tee "$out" | sed -u -n 's/^REMOTE_STATUS: //p'
  local rc=${PIPESTATUS[0]}
  if [ "$rc" -eq 0 ]; then
    echo "[OK] $name: удалённое выполнение завершено"
  else
    echo "[FAIL] $name: удалённое выполнение завершилось с ошибкой, код $rc"
  fi
  return "$rc"
}

auto_detect_isp_interfaces(){
  WAN_IF="${WAN_IF:-$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')}"
  [ -n "$WAN_IF" ] || WAN_IF="$(ip -o -4 addr show scope global | awk '{print $2; exit}')"

  # Если ISP уже настроен, берём интерфейсы по адресам.
  HQ_IF="${HQ_IF:-$(ip -o -4 addr show | awk '$4 ~ /^172\.16\.1\.1\/28$/ {print $2; exit}')}"
  BR_IF="${BR_IF:-$(ip -o -4 addr show | awk '$4 ~ /^172\.16\.2\.1\/28$/ {print $2; exit}')}"

  mapfile -t CANDIDATES < <(
    nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null |
    awk -F: '$2=="ethernet"{print $1}' |
    grep -v "^${WAN_IF}$" |
    sort
  )

  probe_l2(){
    local iface="$1" local_ip="$2" peer_ip="$3"
    ip link set "$iface" up >/dev/null 2>&1 || true
    ip addr flush dev "$iface" 2>/dev/null || true
    ip addr add "$local_ip" dev "$iface" 2>/dev/null || true
    sleep 1
    ping -c 1 -W 1 "$peer_ip" >/dev/null 2>&1
  }

  # Если интерфейс HQ неизвестен, ищем тот, на котором отвечает HQ-RTR 172.16.1.2.
  if [ -z "$HQ_IF" ]; then
    for cand in "${CANDIDATES[@]}"; do
      [ "$cand" = "$BR_IF" ] && continue
      echo "[..] ISP detect: проверяю $cand как ISP-HQ через ping 172.16.1.2"
      if probe_l2 "$cand" "172.16.1.1/28" "172.16.1.2"; then
        HQ_IF="$cand"
        echo "[OK] ISP detect: $HQ_IF = ISP-HQ"
        break
      fi
    done
  fi

  # Если интерфейс BR неизвестен, ищем тот, на котором отвечает BR-RTR 172.16.2.2.
  if [ -z "$BR_IF" ]; then
    for cand in "${CANDIDATES[@]}"; do
      [ "$cand" = "$HQ_IF" ] && continue
      echo "[..] ISP detect: проверяю $cand как ISP-BR через ping 172.16.2.2"
      if probe_l2 "$cand" "172.16.2.1/28" "172.16.2.2"; then
        BR_IF="$cand"
        echo "[OK] ISP detect: $BR_IF = ISP-BR"
        break
      fi
    done
  fi

  if [ -z "$WAN_IF" ] || [ -z "$HQ_IF" ] || [ -z "$BR_IF" ]; then
    fail "не смог определить интерфейсы ISP автоматически"
    echo "Что проверяет скрипт:"
    echo "  WAN = интерфейс из default route"
    echo "  ISP-HQ = интерфейс, где пингуется 172.16.1.2"
    echo "  ISP-BR = интерфейс, где пингуется 172.16.2.2"
    echo "Проверь:"
    echo "  ip -br a"
    echo "  nmcli device status"
    echo "  ping -c 3 172.16.1.2"
    echo "  ping -c 3 172.16.2.2"
    return 1
  fi
}


auto_from_bootstrap(){
  echo
  echo "============================================================"
  echo "АВТООПРЕДЕЛЕНИЕ ПО ФАКТУ, БЕЗ СТАНДАРТНОЙ КАРТЫ"
  echo "============================================================"
  echo "Скрипт не спрашивает порты и не верит порядку адаптеров."
  echo "Логика:"
  echo "  ISP: через nmcli/ip + пробный ping до 172.16.1.2 и 172.16.2.2"
  echo "  Eltex: через SSH и show running-config; если LAN-порты не найдены — AUTO-PROBE перебором gigabitethernet 1/0/1..8"
  echo "  Linux: если доступен по SSH, интерфейс берётся по IP; если недоступен — будет короткая подсказка."
  echo

  auto_detect_isp_interfaces || return 1

  # Начальные значения пустые: их должен заполнить show running-config.
  HQ_RTR_ISP_PORT=""
  HQ_RTR_SRV_PORT=""
  HQ_RTR_CLI_PORT=""
  BR_RTR_ISP_PORT=""
  BR_RTR_LAN_PORT=""

  detect_router_ports_from_bootstrap || return 1

  HQR_ISP_PORT="$HQ_RTR_ISP_PORT"
  HQR_SRV_PORT="$HQ_RTR_SRV_PORT"
  HQR_CLI_PORT="$HQ_RTR_CLI_PORT"
  BRR_LAN_PORT="$BR_RTR_LAN_PORT"
  BRR_ISP_PORT="$BR_RTR_ISP_PORT"

  HQ_SRV_IF="${HQ_SRV_IF:-ens3}"
  BR_SRV_IF="${BR_SRV_IF:-ens3}"
  HQ_CLI_IF="${HQ_CLI_IF:-ens3}"

  echo "Итог автоопределения:"
  echo "  ISP: WAN=$WAN_IF, ISP-HQ=$HQ_IF, ISP-BR=$BR_IF"
  echo "  HQ-RTR: ISP=$HQR_ISP_PORT, HQ-SRV=$HQR_SRV_PORT, HQ-CLI=$HQR_CLI_PORT"
  echo "  BR-RTR: ISP=$BRR_ISP_PORT, BR-Net=$BRR_LAN_PORT"
  echo "  Linux fallback IF для подсказок: HQ-SRV=$HQ_SRV_IF, BR-SRV=$BR_SRV_IF, HQ-CLI=$HQ_CLI_IF"
  echo
}


vesr_running_config_to_file(){
  local ip="$1"
  local out="$2"
  local tmp="/tmp/demoexam_showrun_${ip//./_}.expect"

  cat > "$tmp" <<'EOF'
#!/usr/bin/expect -f
set timeout 180
set ip [lindex $argv 0]
set user "net_admin"
set pass "P@ssw0rd"
log_user 1

spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o UpdateHostKeys=no -o LogLevel=ERROR -o ConnectTimeout=10 -o PubkeyAuthentication=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 $user@$ip
expect {
    -re {Are you sure you want to continue connecting.*} { send "yes\r"; exp_continue }
    -re {yes/no} { send "yes\r"; exp_continue }
    -re {fingerprint} { send "yes\r"; exp_continue }
    -re "(P|p)assword:" { send "$pass\r" }
    timeout { exit 10 }
    eof { exit 11 }
}
expect {
    -re {[#>]} {}
    timeout { exit 12 }
}

send "terminal datadump\r"
expect {
    -re {[#>]} {}
    timeout {}
}

send "show running-config\r"
expect {
    -re {More\?.*} { send " "; exp_continue }
    -re {--More--.*} { send " "; exp_continue }
    -re {[#>]} {}
    timeout { exit 13 }
}

send "exit\r"
expect {
    -re {Do you still want to log out\?.*} { send "y\r"; exp_continue }
    eof {}
    timeout { exit 14 }
}
EOF

  chmod +x "$tmp"
  "$tmp" "$ip" > "$out" 2>&1
}

port_by_ip_in_run(){
  local file="$1"
  local ipcidr="$2"
  awk -v want="$ipcidr" '
    /^interface gigabitethernet / {iface=$2" "$3}
    index($0, "ip address " want) > 0 {print iface; exit}
  ' "$file"
}

detect_router_ports_from_bootstrap(){
  echo "[..] Eltex detect: читаю show running-config и ищу IP на интерфейсах"

  local hqrun="/tmp/demoexam_hq_rtr_showrun.log"
  if ! check_ping 172.16.1.2; then
    fail "HQ-RTR 172.16.1.2 не пингуется, невозможно определить порты"
    return 1
  fi
  if ! vesr_running_config_to_file 172.16.1.2 "$hqrun"; then
    fail "HQ-RTR: не смог прочитать show running-config"
    echo "Лог: $hqrun"
    tail -40 "$hqrun" 2>/dev/null || true
    return 1
  fi

  HQ_RTR_ISP_PORT="$(port_by_ip_in_run "$hqrun" "172.16.1.2/28" | tr -d '\r' | xargs)"
  HQ_RTR_SRV_PORT="$(port_by_ip_in_run "$hqrun" "192.168.100.1/27" | tr -d '\r' | xargs)"
  HQ_RTR_CLI_PORT="$(port_by_ip_in_run "$hqrun" "192.168.200.1/28" | tr -d '\r' | xargs)"

  if [ -z "$HQ_RTR_ISP_PORT" ]; then
    fail "HQ-RTR: не нашёл 172.16.1.2/28 в show running-config. Первый порт к ISP-HQ всё ещё нужно поднять вручную."
    echo "Лог: $hqrun"
    grep -n "interface gigabitethernet\\|ip address" "$hqrun" | tail -80 || true
    return 1
  fi

  if [ -z "$HQ_RTR_SRV_PORT" ]; then
    echo "[WARN] HQ-RTR: порт к HQ-SRV не найден в show running-config — включу AUTO-PROBE"
  fi
  if [ -z "$HQ_RTR_CLI_PORT" ]; then
    echo "[WARN] HQ-RTR: порт к HQ-CLI не найден в show running-config — включу AUTO-PROBE"
  fi

  local brrun="/tmp/demoexam_br_rtr_showrun.log"
  if ! check_ping 172.16.2.2; then
    fail "BR-RTR 172.16.2.2 не пингуется, невозможно определить порты"
    return 1
  fi
  if ! vesr_running_config_to_file 172.16.2.2 "$brrun"; then
    fail "BR-RTR: не смог прочитать show running-config"
    echo "Лог: $brrun"
    tail -40 "$brrun" 2>/dev/null || true
    return 1
  fi

  BR_RTR_ISP_PORT="$(port_by_ip_in_run "$brrun" "172.16.2.2/28" | tr -d '\r' | xargs)"
  BR_RTR_LAN_PORT="$(port_by_ip_in_run "$brrun" "192.168.30.1/28" | tr -d '\r' | xargs)"

  if [ -z "$BR_RTR_ISP_PORT" ]; then
    fail "BR-RTR: не нашёл 172.16.2.2/28 в show running-config. Первый порт к ISP-BR всё ещё нужно поднять вручную."
    echo "Лог: $brrun"
    grep -n "interface gigabitethernet\\|ip address" "$brrun" | tail -80 || true
    return 1
  fi

  if [ -z "$BR_RTR_LAN_PORT" ]; then
    echo "[WARN] BR-RTR: порт к BR-SRV/BR-LAN не найден в show running-config — включу AUTO-PROBE"
  fi

  echo "[OK] Eltex detect:"
  echo "  HQ-RTR: $HQ_RTR_ISP_PORT=172.16.1.2, $HQ_RTR_SRV_PORT=192.168.100.1, $HQ_RTR_CLI_PORT=192.168.200.1"
  echo "  BR-RTR: $BR_RTR_ISP_PORT=172.16.2.2, $BR_RTR_LAN_PORT=192.168.30.1"
}


port_eq(){
  [ "$1" = "$2" ]
}

port_is_protected(){
  local p="$1"
  shift
  local x
  for x in "$@"; do
    [ -n "$x" ] && [ "$p" = "$x" ] && return 0
  done
  return 1
}

all_gi_ports(){
  local n
  for n in 1 2 3 4 5 6 7 8; do
    echo "gigabitethernet 1/0/$n"
  done
}

vesr_config_port_ip(){
  local ip="$1"
  local port="$2"
  local addr="$3"
  local log="/tmp/demoexam_probe_${ip//./_}_${port//[ \/]/_}.log"
  local tmp="/tmp/demoexam_probe_${ip//./_}.expect"

  cat > "$tmp" <<'EOF'
#!/usr/bin/expect -f
set timeout 90
set ip [lindex $argv 0]
set port [lindex $argv 1]
set addr [lindex $argv 2]
set user "net_admin"
set pass "P@ssw0rd"
log_user 1
proc c {cmd} {
    send_user -- "STEP CMD: $cmd\n"
    send -- "$cmd\r"
    expect {
        -re {More\?.*} { send " "; exp_continue }
        -re {[#>]} {}
        timeout { send_user -- "ERROR TIMEOUT: $cmd\n"; exit 20 }
        eof { send_user -- "ERROR EOF: $cmd\n"; exit 21 }
    }
}
spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o UpdateHostKeys=no -o LogLevel=ERROR -o ConnectTimeout=10 -o PubkeyAuthentication=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 $user@$ip
expect {
    -re {Are you sure you want to continue connecting.*} { send "yes\r"; exp_continue }
    -re {yes/no} { send "yes\r"; exp_continue }
    -re {fingerprint} { send "yes\r"; exp_continue }
    -re "(P|p)assword:" { send "$pass\r" }
    timeout { exit 10 }
    eof { exit 11 }
}
expect -re {[#>]}
c "configure terminal"
c "interface $port"
c "ip firewall disable"
c "no ip address"
c "ip address $addr"
c "exit"
c "do commit"
c "do confirm"
c "exit"
expect {
    -re {Do you still want to log out\?.*} { send "y\r"; exp_continue }
    eof {}
    timeout {}
}
EOF
  chmod +x "$tmp"
  "$tmp" "$ip" "$port" "$addr" > "$log" 2>&1
}

vesr_clear_ports(){
  local ip="$1"; shift
  local protected=("$@")
  local tmp="/tmp/demoexam_clear_${ip//./_}.expect"
  local cmdfile="/tmp/demoexam_clear_${ip//./_}.cmds"
  : > "$cmdfile"

  local p
  for p in $(all_gi_ports); do
    # all_gi_ports prints spaces in port names, so this for loop cannot be used directly.
    :
  done

  for n in 1 2 3 4 5 6 7 8; do
    p="gigabitethernet 1/0/$n"
    port_is_protected "$p" "${protected[@]}" && continue
    {
      echo "interface $p"
      echo "no ip address"
      echo "exit"
    } >> "$cmdfile"
  done

  cat > "$tmp" <<'EOF'
#!/usr/bin/expect -f
set timeout 120
set ip [lindex $argv 0]
set cmdfile [lindex $argv 1]
set user "net_admin"
set pass "P@ssw0rd"
log_user 0
proc c {cmd} {
    send -- "$cmd\r"
    expect {
        -re {More\?.*} { send " "; exp_continue }
        -re {[#>]} {}
        timeout { exit 20 }
        eof { exit 21 }
    }
}
spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o UpdateHostKeys=no -o LogLevel=ERROR -o ConnectTimeout=10 -o PubkeyAuthentication=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 $user@$ip
expect {
    -re {Are you sure you want to continue connecting.*} { send "yes\r"; exp_continue }
    -re {yes/no} { send "yes\r"; exp_continue }
    -re {fingerprint} { send "yes\r"; exp_continue }
    -re "(P|p)assword:" { send "$pass\r" }
    timeout { exit 10 }
    eof { exit 11 }
}
expect -re {[#>]}
c "configure terminal"
set fh [open $cmdfile r]
while {[gets $fh line] >= 0} {
    if {$line ne ""} { c $line }
}
close $fh
c "do commit"
c "do confirm"
c "exit"
expect {
    -re {Do you still want to log out\?.*} { send "y\r"; exp_continue }
    eof {}
    timeout {}
}
EOF
  chmod +x "$tmp"
  "$tmp" "$ip" "$cmdfile" >/tmp/demoexam_clear_${ip//./_}.log 2>&1 || true
}

probe_one_router_port(){
  local router_ip="$1" target_ip="$2" addr="$3" result_var="$4" label="$5"
  shift 5
  local protected=("$@")
  local p n

  echo "[..] AUTO-PROBE $label: ищу порт. Цель ping: $target_ip, адрес шлюза: $addr"
  echo "[..] AUTO-PROBE $label: защищённые порты не трогаю: ${protected[*]}"

  for n in 1 2 3 4 5 6 7 8; do
    p="gigabitethernet 1/0/$n"
    port_is_protected "$p" "${protected[@]}" && continue

    echo "[..] AUTO-PROBE $label: пробую $p"
    # Чистим только текущий кандидат и ставим на него нужный IP.
    vesr_config_port_ip "$router_ip" "$p" "$addr" || {
      echo "[WARN] AUTO-PROBE $label: не смог назначить $addr на $p"
      continue
    }

    sleep 3
    if check_ping "$target_ip"; then
      printf -v "$result_var" '%s' "$p"
      echo "[OK] AUTO-PROBE $label: найден порт $p"
      return 0
    fi

    echo "[MISS] AUTO-PROBE $label: через $p пинга до $target_ip нет"
  done

  echo "[FAIL] AUTO-PROBE $label: порт не найден"
  echo "Проверь, что целевая Linux-машина уже имеет IP и включена:"
  echo "  HQ-SRV: 192.168.100.2/27"
  echo "  HQ-CLI: 192.168.200.3/28"
  echo "  BR-SRV: 192.168.30.2/28"
  return 1
}

autoprobe_hq_ports_if_needed(){
  # Требуется рабочий SSH на HQ-RTR через 172.16.1.2.
  [ -n "$HQ_RTR_ISP_PORT" ] || { echo "[FAIL] HQ-RTR ISP-port неизвестен, AUTO-PROBE невозможен"; return 1; }

  ip route replace 192.168.100.0/27 via 172.16.1.2 2>/dev/null || true
  ip route replace 192.168.200.0/28 via 172.16.1.2 2>/dev/null || true

  if [ -z "${HQ_RTR_SRV_PORT:-}" ] || ! check_ping 192.168.100.2; then
    probe_one_router_port 172.16.1.2 192.168.100.2 192.168.100.1/27 HQ_RTR_SRV_PORT "HQ-RTR -> HQ-SRV" "$HQ_RTR_ISP_PORT" "$HQ_RTR_CLI_PORT" || return 1
  fi

  if [ -z "${HQ_RTR_CLI_PORT:-}" ] || ! check_ping 192.168.200.3; then
    probe_one_router_port 172.16.1.2 192.168.200.3 192.168.200.1/28 HQ_RTR_CLI_PORT "HQ-RTR -> HQ-CLI" "$HQ_RTR_ISP_PORT" "$HQ_RTR_SRV_PORT" || return 1
  fi

  HQR_ISP_PORT="$HQ_RTR_ISP_PORT"
  HQR_SRV_PORT="$HQ_RTR_SRV_PORT"
  HQR_CLI_PORT="$HQ_RTR_CLI_PORT"
  echo "[OK] AUTO-PROBE HQ-RTR итог: ISP=$HQR_ISP_PORT, HQ-SRV=$HQR_SRV_PORT, HQ-CLI=$HQR_CLI_PORT"
}

autoprobe_br_ports_if_needed(){
  [ -n "$BR_RTR_ISP_PORT" ] || { echo "[FAIL] BR-RTR ISP-port неизвестен, AUTO-PROBE невозможен"; return 1; }

  ip route replace 192.168.30.0/28 via 172.16.2.2 2>/dev/null || true

  if [ -z "${BR_RTR_LAN_PORT:-}" ] || ! check_ping 192.168.30.2; then
    probe_one_router_port 172.16.2.2 192.168.30.2 192.168.30.1/28 BR_RTR_LAN_PORT "BR-RTR -> BR-SRV" "$BR_RTR_ISP_PORT" || return 1
  fi

  BRR_ISP_PORT="$BR_RTR_ISP_PORT"
  BRR_LAN_PORT="$BR_RTR_LAN_PORT"
  echo "[OK] AUTO-PROBE BR-RTR итог: ISP=$BRR_ISP_PORT, BR-Net=$BRR_LAN_PORT"
}





repair_hq_web_from_isp(){
  echo "[..] HQ-SRV: чиню Apache/PHP/MariaDB приложение через SSH"
  local log="/tmp/demoexam_hq_web_repair_from_isp.log"

  # repair может вызваться рано, ещё до вопроса "Пароль root для Linux-машин".
  # Поэтому при set -u нельзя обращаться к незаданному ROOT_PASS напрямую.
  if [ -z "${ROOT_PASS:-}" ]; then
    read -rsp "Пароль root для Linux-машин: " ROOT_PASS
    echo
  fi

  if ! check_ping 192.168.100.2; then
    echo "[WARN] HQ-SRV 192.168.100.2 не пингуется — web repair пока пропускаю до шага HQ-SRV"
    return 1
  fi

  if ! sshpass -p "$ROOT_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o UpdateHostKeys=no -o LogLevel=ERROR -o ConnectTimeout=10 -o PreferredAuthentications=password -o PubkeyAuthentication=no root@192.168.100.2 'true' >/dev/null 2>&1; then
    echo "[WARN] HQ-SRV SSH root@192.168.100.2 пока недоступен — web repair будет после настройки HQ-SRV"
    return 1
  fi

  sshpass -p "$ROOT_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o UpdateHostKeys=no -o LogLevel=ERROR -o ConnectTimeout=10 -o PreferredAuthentications=password -o PubkeyAuthentication=no root@192.168.100.2 'bash -s' >"$log" 2>&1 <<'REMOTE'
set -euo pipefail
remote_fail(){ echo "REMOTE_STATUS: FAIL: $1"; exit 60; }

repair_hq_web_app_local(){
  echo "REMOTE_STATUS: START: HQ-SRV: чиню Apache/PHP/MariaDB приложение"
  systemctl enable --now mariadb >/dev/null 2>&1 || true
  systemctl enable --now httpd >/dev/null 2>&1 || true

  mysql -u root <<'SQL_EOF'
CREATE DATABASE IF NOT EXISTS webdb CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Полностью пересоздаём web, потому что старый пароль мог остаться от прошлых запусков/dump.sql.
DROP USER IF EXISTS 'web'@'localhost';
DROP USER IF EXISTS 'web'@'%';
DROP USER IF EXISTS 'user'@'localhost';
DROP USER IF EXISTS 'user'@'%';

CREATE USER 'web'@'localhost' IDENTIFIED BY 'P@ssw0rd';
CREATE USER 'web'@'%' IDENTIFIED BY 'P@ssw0rd';

-- На всякий случай создаём совместимого пользователя user: старые index.php иногда используют user.
CREATE USER 'user'@'localhost' IDENTIFIED BY 'P@ssw0rd';
CREATE USER 'user'@'%' IDENTIFIED BY 'P@ssw0rd';

GRANT ALL PRIVILEGES ON webdb.* TO 'web'@'localhost';
GRANT ALL PRIVILEGES ON webdb.* TO 'web'@'%';
GRANT ALL PRIVILEGES ON webdb.* TO 'user'@'localhost';
GRANT ALL PRIVILEGES ON webdb.* TO 'user'@'%';

FLUSH PRIVILEGES;
SQL_EOF

  # Если dump.sql есть — импортируем повторно. Это безопаснее, чем оставить пустую/битую БД.
  DUMP_SQL="/mnt/additional/web/dump.sql"
  [ -f "$DUMP_SQL" ] || DUMP_SQL="$(find /mnt/additional -type f -iname 'dump.sql' 2>/dev/null | head -1 || true)"
  if [ -n "$DUMP_SQL" ] && [ -f "$DUMP_SQL" ]; then
    mysql -u root webdb < "$DUMP_SQL" >/tmp/hq_web_dump_reimport.log 2>&1 || echo "REMOTE_STATUS: WARN: HQ-SRV: повторный импорт dump.sql не прошёл, смотри /tmp/hq_web_dump_reimport.log"

    # После dump.sql ещё раз фиксируем пользователей: dump мог их перезаписать/сломать.
    mysql -u root <<'SQL_EOF'
DROP USER IF EXISTS 'web'@'localhost';
DROP USER IF EXISTS 'web'@'%';
DROP USER IF EXISTS 'user'@'localhost';
DROP USER IF EXISTS 'user'@'%';
CREATE USER 'web'@'localhost' IDENTIFIED BY 'P@ssw0rd';
CREATE USER 'web'@'%' IDENTIFIED BY 'P@ssw0rd';
CREATE USER 'user'@'localhost' IDENTIFIED BY 'P@ssw0rd';
CREATE USER 'user'@'%' IDENTIFIED BY 'P@ssw0rd';
GRANT ALL PRIVILEGES ON webdb.* TO 'web'@'localhost';
GRANT ALL PRIVILEGES ON webdb.* TO 'web'@'%';
GRANT ALL PRIVILEGES ON webdb.* TO 'user'@'localhost';
GRANT ALL PRIVILEGES ON webdb.* TO 'user'@'%';
FLUSH PRIVILEGES;
SQL_EOF
  fi

  if [ -f /var/www/html/index.php ]; then
    cp -a /var/www/html/index.php /var/www/html/index.php.bak.demo 2>/dev/null || true

    # Чиним самые частые варианты переменных подключения.
    perl -0pi -e 's/\$servername\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$servername = "localhost";/g;
                 s/\$server\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$server = "localhost";/g;
                 s/\$host\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$host = "localhost";/g;
                 s/\$dbhost\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$dbhost = "localhost";/g;
                 s/\$db_host\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$db_host = "localhost";/g;
                 s/\$username\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$username = "web";/g;
                 s/\$user\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$user = "web";/g;
                 s/\$dbuser\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$dbuser = "web";/g;
                 s/\$db_user\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$db_user = "web";/g;
                 s/\$password\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$password = "P@ssw0rd";/g;
                 s/\$pass\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$pass = "P@ssw0rd";/g;
                 s/\$dbpass\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$dbpass = "P@ssw0rd";/g;
                 s/\$db_pass\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$db_pass = "P@ssw0rd";/g;
                 s/\$dbname\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$dbname = "webdb";/g;
                 s/\$database\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$database = "webdb";/g;
                 s/\$db\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$db = "webdb";/g;
                 s/\$db_name\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$db_name = "webdb";/g;' /var/www/html/index.php 2>/tmp/hq_web_index_perl.err || true

    # Принудительно чиним типовые конструкторы подключения даже если там переменные.
    perl -0pi -e 's/new\s+mysqli\s*\([^;]*?\)/new mysqli("localhost", "web", "P@ssw0rd", "webdb")/gs;
                 s/mysqli_connect\s*\([^;]*?\)/mysqli_connect("localhost", "web", "P@ssw0rd", "webdb")/gs;' /var/www/html/index.php 2>/tmp/hq_web_mysqli_perl.err || true

    # Дополнительные частые имена переменных.
    perl -0pi -e 's/\$login\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$login = "web";/g;
                 s/\$db_login\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$db_login = "web";/g;
                 s/\$dbusername\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$dbusername = "web";/g;
                 s/\$db_username\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$db_username = "web";/g;
                 s/\$mysql_user\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$mysql_user = "web";/g;
                 s/\$passwd\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$passwd = "P@ssw0rd";/g;
                 s/\$pwd\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$pwd = "P@ssw0rd";/g;
                 s/\$dbpassword\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$dbpassword = "P@ssw0rd";/g;
                 s/\$db_password\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$db_password = "P@ssw0rd";/g;
                 s/\$mysql_password\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$mysql_password = "P@ssw0rd";/g;' /var/www/html/index.php 2>/tmp/hq_web_more_vars_perl.err || true

    # Для PDO mysql:host=...;dbname=... и логин/пароль PDO.
    perl -0pi -e 's/mysql:host=[^;"'\'']+/mysql:host=localhost/g;
                 s/dbname=[^;"'\'']+/dbname=webdb/g;
                 s/new\s+PDO\s*\(\s*["'\'']mysql:[^"'\'']*["'\'']\s*,\s*["'\''][^"'\'']*["'\'']\s*,\s*["'\''][^"'\'']*["'\'']\s*\)/new PDO("mysql:host=localhost;dbname=webdb;charset=utf8mb4", "web", "P@ssw0rd")/gs;' /var/www/html/index.php 2>/tmp/hq_web_pdo_perl.err || true

    # ВАЖНО: в perl replacement символ @ интерпретируется как массив.
    # Поэтому финально фиксируем index.php через Python простыми заменами, чтобы пароль точно был P@ssw0rd, а не P.
    python3 - <<'PY_FIX' >/tmp/hq_web_python_index_fix.log 2>&1 || {
      echo "REMOTE_STATUS: FAIL: HQ-SRV: Python-fix index.php не выполнился"
      cat /tmp/hq_web_python_index_fix.log
      exit 64
    }
from pathlib import Path

p = Path("/var/www/html/index.php")
s = p.read_text(encoding="utf-8", errors="ignore")

# Исправляем самый опасный результат perl: P@ssw0rd мог превратиться в P.
s = s.replace('"P"', '"P@ssw0rd"')
s = s.replace("'P'", "'P@ssw0rd'")

# Жёстко фиксируем самые частые переменные.
repls = {
    '$servername =': '$servername = "localhost";',
    '$username =': '$username = "web";',
    '$password =': '$password = "P@ssw0rd";',
    '$dbname =': '$dbname = "webdb";',
}
lines = []
for line in s.splitlines():
    stripped = line.strip()
    done = False
    for prefix, fixed in repls.items():
        if stripped.startswith(prefix):
            indent = line[:len(line) - len(line.lstrip())]
            lines.append(indent + fixed)
            done = True
            break
    if not done:
        lines.append(line)
s = "\n".join(lines) + "\n"

# Жёстко фиксируем прямые вызовы.
import re
s = re.sub(r'new\s+mysqli\s*\([^;]*?\)', 'new mysqli("localhost", "web", "P@ssw0rd", "webdb")', s, flags=re.S)
s = re.sub(r'mysqli_connect\s*\([^;]*?\)', 'mysqli_connect("localhost", "web", "P@ssw0rd", "webdb")', s, flags=re.S)

p.write_text(s, encoding="utf-8")
PY_FIX

    # Последний простой фикс без regex/perl: если где-то остался пароль "P", заменяем на полный пароль.
    # Именно это сейчас ломало PHP: index.php получал "P" вместо "P@ssw0rd".
    sed -i \
      -e 's/"P"/"P@ssw0rd"/g' \
      -e "s/'P'/'P@ssw0rd'/g" \
      /var/www/html/index.php

    echo "REMOTE_STATUS: INFO: HQ-SRV: index.php после финального password-fix"
    nl -ba /var/www/html/index.php | sed -n '1,12p' | sed 's/^/REMOTE_STATUS: INDEX: /'

    # ФИНАЛЬНЫЙ ФИКС ПАРОЛЯ.
    # Без regex/perl: если Perl превратил P@ssw0rd в P, возвращаем полный пароль.
    sed -i \
      -e 's/"P"/"P@ssw0rd"/g' \
      -e "s/'P'/'P@ssw0rd'/g" \
      /var/www/html/index.php

    echo "REMOTE_STATUS: INFO: HQ-SRV: index.php после финального password-fix"
    nl -ba /var/www/html/index.php | sed -n '1,12p' | sed 's/^/REMOTE_STATUS: INDEX: /'

  else
    echo "REMOTE_STATUS: FAIL: HQ-SRV: /var/www/html/index.php отсутствует"
    exit 61
  fi

  chown -R apache:apache /var/www/html 2>/dev/null || chown -R nginx:nginx /var/www/html 2>/dev/null || true
  find /var/www/html -type d -exec chmod 755 {} \; 2>/dev/null || true
  find /var/www/html -type f -exec chmod 644 {} \; 2>/dev/null || true
  restorecon -Rv /var/www/html >/dev/null 2>&1 || true
  setsebool -P httpd_can_network_connect_db 1 >/dev/null 2>&1 || true
  setsebool -P httpd_can_network_connect 1 >/dev/null 2>&1 || true
  firewall-cmd --permanent --add-service=http >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true

  systemctl restart mariadb >/dev/null 2>&1 || true
  systemctl restart httpd >/dev/null 2>&1 || true

  if mysql -u web -p'P@ssw0rd' webdb -e 'SELECT 1;' >/tmp/hq_web_mysql_web_check.log 2>&1; then
    echo "REMOTE_STATUS: OK: HQ-SRV: пользователь web подключается к webdb"
  else
    echo "REMOTE_STATUS: FAIL: HQ-SRV: пользователь web НЕ подключается к webdb"
    cat /tmp/hq_web_mysql_web_check.log || true
    mysql -u root -e "SELECT User,Host,plugin FROM mysql.user WHERE User IN ('web','user');" 2>/dev/null || true
    exit 63
  fi

  echo "REMOTE_STATUS: INFO: HQ-SRV: первые строки index.php после фикса"
  nl -ba /var/www/html/index.php | sed -n '1,25p' || true

  if curl -s --max-time 8 http://127.0.0.1 | grep -qiE 'html|php|сайт|студент|таблиц|mysql|<!doctype|Задание 7|База данных'; then
    echo "REMOTE_STATUS: OK: HQ-SRV: Apache/PHP приложение отвечает локально"
  else
    echo "REMOTE_STATUS: FAIL: HQ-SRV: Apache/PHP всё ещё отдаёт ошибку"
    echo "REMOTE_STATUS: FAIL: текущие первые строки index.php:"
    nl -ba /var/www/html/index.php | sed -n '1,15p' 2>/dev/null || true
    echo "REMOTE_STATUS: FAIL: последние логи:"
    tail -n 80 /var/log/httpd/error_log 2>/dev/null || true
    tail -n 80 /var/log/php-fpm/www-error.log 2>/dev/null || true
    exit 62
  fi
}

repair_hq_web_app_local
REMOTE
  local rc=$?
  cat "$log" | tail -n 80
  return "$rc"
}

repair_isp_proxy(){
  echo "[..] ISP: чиню Nginx reverse proxy для web.sirius-exam.org и docker.sirius-exam.org"

  # Нужны nginx и утилита htpasswd. Если их нет — ставим только отсутствующие пакеты, без update.
  ISP_MISSING=""
  timeout 5 rpm -q nginx >/dev/null 2>&1 || ISP_MISSING="$ISP_MISSING nginx"
  timeout 5 rpm -q httpd-tools >/dev/null 2>&1 || ISP_MISSING="$ISP_MISSING httpd-tools"
  timeout 5 rpm -q openssl >/dev/null 2>&1 || true
  if [ -n "$ISP_MISSING" ]; then
    echo "[..] ISP: отсутствуют пакеты:$ISP_MISSING — пробую dnf install только их"
    timeout 900 dnf install -y --setopt=timeout=20 --setopt=retries=1 $ISP_MISSING 2>&1 | tee /tmp/demoexam_isp_proxy_dnf.log || true
  fi

  command -v nginx >/dev/null 2>&1 || { fail "ISP: nginx не установлен, смотри /tmp/demoexam_isp_proxy_dnf.log"; return 1; }

  # Чтобы проверка curl http://web.sirius-exam.org работала прямо на ISP.
  sed -i '/web\.sirius-exam\.org/d;/docker\.sirius-exam\.org/d' /etc/hosts 2>/dev/null || true
  cat >> /etc/hosts <<'EOF'
127.0.0.1 web.sirius-exam.org
127.0.0.1 docker.sirius-exam.org
EOF

  mkdir -p /etc/nginx/conf.d

  # Убираем старые конфликтующие файлы из предыдущих запусков.
  rm -f /etc/nginx/conf.d/web.conf /etc/nginx/conf.d/docker.conf /etc/nginx/conf.d/demoexam_proxy.conf

  if command -v htpasswd >/dev/null 2>&1; then
    htpasswd -bc /etc/nginx/.htpasswd WEB 'P@ssw0rd' >/tmp/demoexam_htpasswd.log 2>&1 || return 1
  else
    command -v openssl >/dev/null 2>&1 || { fail "ISP: нет ни htpasswd, ни openssl для .htpasswd"; return 1; }
    printf 'WEB:%s\n' "$(openssl passwd -apr1 'P@ssw0rd')" > /etc/nginx/.htpasswd
  fi
  # Nginx worker должен читать .htpasswd. Иначе после ввода WEB/P@ssw0rd будет 500 Internal Server Error.
  if getent group nginx >/dev/null 2>&1; then
    chown root:nginx /etc/nginx/.htpasswd 2>/dev/null || true
    chmod 640 /etc/nginx/.htpasswd 2>/dev/null || true
  else
    chmod 644 /etc/nginx/.htpasswd 2>/dev/null || true
  fi
  restorecon -v /etc/nginx/.htpasswd >/dev/null 2>&1 || true

  cat > /etc/nginx/conf.d/demoexam_proxy.conf <<'EOF'
server {
    listen 80;
    server_name web.sirius-exam.org;

    auth_basic "Authorized access only";
    auth_basic_user_file /etc/nginx/.htpasswd;

    location / {
        proxy_pass http://172.16.1.2:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

server {
    listen 80;
    server_name docker.sirius-exam.org;

    location / {
        proxy_pass http://172.16.2.2:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF

  setsebool -P httpd_can_network_connect 1 >/tmp/demoexam_setsebool.err 2>&1 || true
  firewall-cmd --permanent --add-service=http >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true

  nginx -t >/tmp/demoexam_nginx_test.err 2>&1 || {
    fail "ISP: nginx -t не прошёл"
    cat /tmp/demoexam_nginx_test.err
    return 1
  }

  systemctl enable --now nginx >/dev/null 2>>/tmp/demoexam_isp.err || true
  systemctl restart nginx >/dev/null 2>>/tmp/demoexam_isp.err || {
    fail "ISP: nginx не перезапустился"
    systemctl status nginx --no-pager || true
    return 1
  }

  # Быстрая диагностика upstream'ов.
  if ! curl -s --max-time 8 http://172.16.1.2:8080 | grep -qiE 'html|php|сайт|студент|таблиц|<!doctype'; then
    echo "[WARN] ISP: upstream HQ-SRV http://172.16.1.2:8080 не отвечает корректно"
    echo "[INFO] Если HQ-SRV ещё не настроен/не пингуется — починка web будет позже на шаге HQ-SRV и в финальной проверке"
    repair_hq_web_from_isp || true
  fi
  curl -s --max-time 5 http://172.16.1.2:8080 >/tmp/demoexam_hq_web_direct.html 2>/tmp/demoexam_hq_web_direct.err || true
  curl -s --max-time 5 http://172.16.2.2:8080 >/tmp/demoexam_br_docker_direct.html 2>/tmp/demoexam_br_docker_direct.err || true

  if curl -s --max-time 8 -u WEB:'P@ssw0rd' http://web.sirius-exam.org | grep -qiE 'html|php|сайт|студент|таблиц|<!doctype'; then
    ok "ISP reverse proxy web.sirius-exam.org работает"
  else
    fail "ISP reverse proxy web.sirius-exam.org пока не проверен"
    echo "Проверь:"
    echo "  curl -v http://172.16.1.2:8080"
    echo "  curl -v -u WEB:'P@ssw0rd' http://web.sirius-exam.org"
    echo "  tail -n 80 /var/log/nginx/error.log"
    echo "  ls -lZ /etc/nginx/.htpasswd"
    echo "  cat /tmp/demoexam_nginx_test.err"
    tail -n 40 /var/log/nginx/error.log 2>/dev/null || true
    return 1
  fi

  if curl -s --max-time 8 http://docker.sirius-exam.org | grep -qiE 'студент|html|сайт'; then
    ok "ISP reverse proxy docker.sirius-exam.org работает"
  else
    echo "[WARN] ISP reverse proxy docker.sirius-exam.org не подтвердился, но BR DNAT проверяется отдельно"
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

  echo "[..] ISP: проверяю/доустанавливаю пакеты chrony nginx httpd-tools"
  ISP_MISSING=""
  for p in chrony nginx httpd-tools; do
    timeout 5 rpm -q "$p" >/dev/null 2>&1 || ISP_MISSING="$ISP_MISSING $p"
  done
  if [ -n "$ISP_MISSING" ]; then
    echo "[..] ISP: отсутствуют пакеты:$ISP_MISSING — пробую dnf install только их"
    timeout 900 dnf install -y --setopt=timeout=20 --setopt=retries=1 $ISP_MISSING 2>&1 | tee /tmp/demoexam_isp_packages_dnf.log || true
  fi
  timeout 10 rpm -q chrony nginx httpd-tools >/tmp/demoexam_isp_packages_check.log 2>&1 || {
    echo "[WARN] ISP: не все пакеты найдены. Лог: /tmp/demoexam_isp_packages_check.log"
    cat /tmp/demoexam_isp_packages_check.log
  }

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

  repair_isp_proxy || {
    echo "[WARN] ISP: reverse proxy пока не прошёл проверку, финальный шаг попробует ещё раз"
  }

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

# Если пароль admin уже менялся раньше, первые 3 строки можно пропустить.
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
do commit
do confirm

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

# Если пароль admin уже менялся раньше, первые 3 строки можно пропустить.
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
do commit
do confirm

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
        -re {More\?.*} { send " "; exp_continue }
        -re {[#>]} {}
        timeout { send_user -- "ERROR TIMEOUT: команда не получила prompt: $cmd\n"; exit 20 }
        eof { send_user -- "ERROR EOF: соединение закрыто на команде: $cmd\n"; exit 21 }
    }
}
spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o UpdateHostKeys=no -o LogLevel=ERROR -o ConnectTimeout=10 -o PubkeyAuthentication=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 $user@$ip
expect {
    -re {Are you sure you want to continue connecting.*} { send_user -- "STEP SSH_HOSTKEY: принимаю host key\n"; send "yes\r"; exp_continue }
    -re {yes/no} { send_user -- "STEP SSH_HOSTKEY: принимаю host key\n"; send "yes\r"; exp_continue }
    -re {fingerprint} { send_user -- "STEP SSH_HOSTKEY: принимаю host key\n"; send "yes\r"; exp_continue }
    -re "(P|p)assword:" { send_user -- "STEP SSH_PASSWORD: отправляю пароль\n"; send "$pass\r" }
    timeout { send_user -- "ERROR SSH: нет запроса пароля\n"; exit 10 }
    eof { send_user -- "ERROR SSH: соединение закрыто до пароля\n"; exit 11 }
}
expect {
    -re {[#>]} { send_user -- "STEP SSH_LOGIN_OK: вошли в VESR\n" }
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
send_user -- "STEP INFO: HQ-MGMT отсутствует, интерфейс не настраиваю\n"
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
send_user -- "STEP INFO: HQ-MGMT OSPF network не нужен
"
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
send_user -- "STEP INFO: HQ-MGMT SNAT rule не нужен
"
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
c "do commit"
c "do confirm"
c "exit"
EOF
  chmod +x "$tmp"
  sed -i \
    -e "s#__HQR_ISP_PORT__#$HQR_ISP_PORT#g" \
    -e "s#__HQR_SRV_PORT__#$HQR_SRV_PORT#g" \
    -e "s#__HQR_CLI_PORT__#$HQR_CLI_PORT#g" "$tmp"
  echo "[..] HQ-RTR expect: подробный лог команд ниже"
  echo "[..] HQ-RTR ports: ISP=$HQR_ISP_PORT, SRV=$HQR_SRV_PORT, CLI=$HQR_CLI_PORT"
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
        -re {More\?.*} { send " "; exp_continue }
        -re {[#>]} {}
        timeout { send_user -- "ERROR TIMEOUT: команда не получила prompt: $cmd\n"; exit 20 }
        eof { send_user -- "ERROR EOF: соединение закрыто на команде: $cmd\n"; exit 21 }
    }
}
spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o UpdateHostKeys=no -o LogLevel=ERROR -o ConnectTimeout=10 -o PubkeyAuthentication=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 $user@$ip
expect {
    -re {Are you sure you want to continue connecting.*} { send_user -- "STEP SSH_HOSTKEY: принимаю host key\n"; send "yes\r"; exp_continue }
    -re {yes/no} { send_user -- "STEP SSH_HOSTKEY: принимаю host key\n"; send "yes\r"; exp_continue }
    -re {fingerprint} { send_user -- "STEP SSH_HOSTKEY: принимаю host key\n"; send "yes\r"; exp_continue }
    -re "(P|p)assword:" { send_user -- "STEP SSH_PASSWORD: отправляю пароль\n"; send "$pass\r" }
    timeout { send_user -- "ERROR SSH: нет запроса пароля\n"; exit 10 }
    eof { send_user -- "ERROR SSH: соединение закрыто до пароля\n"; exit 11 }
}
expect {
    -re {[#>]} { send_user -- "STEP SSH_LOGIN_OK: вошли в VESR\n" }
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
c "do commit"
c "do confirm"
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


vesr_check_hq_ips(){
  local ip="$1"
  local tmp="/tmp/demoexam_hq_rtr_check.expect"
  local out="/tmp/demoexam_hq_rtr_check.log"
  cat > "$tmp" <<'EOF'
#!/usr/bin/expect -f
set timeout 60
set ip [lindex $argv 0]
set user "net_admin"
set pass "P@ssw0rd"
set isp_port $env(HQ_RTR_ISP_PORT)
set srv_port $env(HQ_RTR_SRV_PORT)
set cli_port $env(HQ_RTR_CLI_PORT)
log_user 1
spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o UpdateHostKeys=no -o LogLevel=ERROR -o ConnectTimeout=10 -o PubkeyAuthentication=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 $user@$ip
expect {
    -re {Are you sure you want to continue connecting.*} { send "yes\r"; exp_continue }
    -re {yes/no} { send "yes\r"; exp_continue }
    -re {fingerprint} { send "yes\r"; exp_continue }
    -re "(P|p)assword:" { send "$pass\r" }
    timeout { exit 10 }
    eof { exit 11 }
}
expect -re {[#>]}
send "show ip interfaces $isp_port\r"
expect -re {[#>]}
send "show ip interfaces $srv_port\r"
expect -re {[#>]}
send "show ip interfaces $cli_port\r"
expect -re {[#>]}
send "exit\r"
EOF
  chmod +x "$tmp"
  "$tmp" "$ip" > "$out" 2>&1 || return 1

  grep -q "172.16.1.2/28" "$out" || { echo "[FAIL] HQ-RTR check: нет 172.16.1.2/28 на $HQ_RTR_ISP_PORT"; tail -40 "$out"; return 1; }
  grep -q "192.168.100.1/27" "$out" || { echo "[FAIL] HQ-RTR check: нет 192.168.100.1/27 на $HQ_RTR_SRV_PORT"; tail -40 "$out"; return 1; }
  grep -q "192.168.200.1/28" "$out" || { echo "[FAIL] HQ-RTR check: нет 192.168.200.1/28 на $HQ_RTR_CLI_PORT"; tail -40 "$out"; return 1; }
  echo "[OK] HQ-RTR check: адреса на ISP/SRV/CLI портах есть"
}

configure_hq_rtr(){
  local ip="172.16.1.2"
  export HQ_RTR_ISP_PORT HQ_RTR_SRV_PORT HQ_RTR_CLI_PORT

  echo "[..] HQ-RTR: проверяю ping $ip"
  if ! check_ping "$ip"; then
    print_hq_rtr_bootstrap
    wait_enter
    echo "[..] HQ-RTR: повторно проверяю ping $ip"
    if ! check_ping "$ip"; then
      fail "HQ-RTR не отвечает на ping $ip"
      echo "Проверь на HQ-RTR: show ip interfaces $HQ_RTR_ISP_PORT"
      return 1
    fi
  fi
  echo "[OK] HQ-RTR ping есть"

  if [ -z "${HQ_RTR_SRV_PORT:-}" ] || [ -z "${HQ_RTR_CLI_PORT:-}" ]; then
    echo "[WARN] HQ-RTR: не все LAN-порты известны, запускаю AUTO-PROBE перед полным конфигом"
    autoprobe_hq_ports_if_needed || {
      fail "HQ-RTR AUTO-PROBE не смог найти LAN-порты"
      return 1
    }
  fi

  echo "[..] HQ-RTR: пробую SSH net_admin@172.16.1.2 и отправляю полный конфиг"
  rm -f /tmp/demoexam_hq_rtr.err /tmp/demoexam_vesr_expect.log
  if vesr_expect_hq "$ip"; then
    vesr_check_hq_ips "$ip" || echo "[WARN] HQ-RTR: post-check не прошёл, но конфиг отправлен. Дальше проверит ping HQ-SRV."
    ok "HQ-RTR настроен"
  else
    fail "HQ-RTR не настроен"
    show_tail_err /tmp/demoexam_hq_rtr.err
    show_tail_err /tmp/demoexam_hq_rtr_steps.log
    show_tail_err /tmp/demoexam_hq_rtr_check.log
    show_tail_err /tmp/demoexam_br_rtr_steps.log
    show_tail_err /tmp/demoexam_vesr_expect.log
    echo "Проверь вручную с ISP: ssh net_admin@$ip"
    return 1
  fi
}


vesr_check_br_ips(){
  local ip="$1"
  local tmp="/tmp/demoexam_br_rtr_check.expect"
  local out="/tmp/demoexam_br_rtr_check.log"
  cat > "$tmp" <<'EOF'
#!/usr/bin/expect -f
set timeout 60
set ip [lindex $argv 0]
set user "net_admin"
set pass "P@ssw0rd"
set lan_port $env(BR_RTR_LAN_PORT)
set isp_port $env(BR_RTR_ISP_PORT)
log_user 1
spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o UpdateHostKeys=no -o LogLevel=ERROR -o ConnectTimeout=10 -o PubkeyAuthentication=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 $user@$ip
expect {
    -re {Are you sure you want to continue connecting.*} { send "yes\r"; exp_continue }
    -re {yes/no} { send "yes\r"; exp_continue }
    -re {fingerprint} { send "yes\r"; exp_continue }
    -re "(P|p)assword:" { send "$pass\r" }
    timeout { exit 10 }
    eof { exit 11 }
}
expect -re {[#>]}
send "show ip interfaces $lan_port\r"
expect -re {[#>]}
send "show ip interfaces $isp_port\r"
expect -re {[#>]}
send "exit\r"
EOF
  chmod +x "$tmp"
  "$tmp" "$ip" > "$out" 2>&1 || return 1

  grep -q "192.168.30.1/28" "$out" || { echo "[FAIL] BR-RTR check: нет 192.168.30.1/28 на $BR_RTR_LAN_PORT"; tail -40 "$out"; return 1; }
  grep -q "172.16.2.2/28" "$out" || { echo "[FAIL] BR-RTR check: нет 172.16.2.2/28 на $BR_RTR_ISP_PORT"; tail -40 "$out"; return 1; }
  echo "[OK] BR-RTR check: адреса на LAN/ISP портах есть"
}

configure_br_rtr(){
  local ip="172.16.2.2"
  export BR_RTR_LAN_PORT BR_RTR_ISP_PORT

  echo "[..] BR-RTR: проверяю ping $ip"
  if ! check_ping "$ip"; then
    print_br_rtr_bootstrap
    wait_enter
    echo "[..] BR-RTR: повторно проверяю ping $ip"
    if ! check_ping "$ip"; then
      fail "BR-RTR не отвечает на ping $ip"
      echo "Проверь на BR-RTR: show ip interfaces $BR_RTR_ISP_PORT"
      return 1
    fi
  fi
  echo "[OK] BR-RTR ping есть"

  if [ -z "${BR_RTR_LAN_PORT:-}" ]; then
    echo "[WARN] BR-RTR: LAN-порт неизвестен, запускаю AUTO-PROBE перед полным конфигом"
    autoprobe_br_ports_if_needed || {
      fail "BR-RTR AUTO-PROBE не смог найти LAN-порт"
      return 1
    }
  fi

  echo "[..] BR-RTR: пробую SSH net_admin@172.16.2.2 и отправляю полный конфиг"
  rm -f /tmp/demoexam_br_rtr.err /tmp/demoexam_vesr_expect.log
  if vesr_expect_br "$ip"; then
    vesr_check_br_ips "$ip" || echo "[WARN] BR-RTR: post-check не прошёл, но конфиг отправлен. Дальше проверит ping BR-SRV."
    ok "BR-RTR настроен"
  else
    fail "BR-RTR не настроен"
    show_tail_err /tmp/demoexam_br_rtr.err
    show_tail_err /tmp/demoexam_br_rtr_check.log
    show_tail_err /tmp/demoexam_vesr_expect.log
    echo "Проверь вручную с ISP: ssh net_admin@$ip"
    return 1
  fi
}

linux_hint_hq_srv(){
  cat <<HINT_HQ_SRV
[WAIT] ШАГ — HQ-SRV SSH

Минимум для доступа. На HQ-SRV вставь.
Интерфейс: ens3

nmcli con add type ethernet ifname ens3 con-name HQ-SRV ipv4.addresses 192.168.100.2/27 ipv4.gateway 192.168.100.1 ipv4.method manual 2>/dev/null || true
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

После этого с ISP проверь:
ping -c 3 192.168.100.2
ssh root@192.168.100.2

Потом вернись в скрипт и нажми Enter.
HINT_HQ_SRV
}


linux_hint_br_srv(){
  cat <<HINT_BR_SRV
[WAIT] ШАГ — BR-SRV SSH

Минимум для доступа. На BR-SRV вставь.
Интерфейс: ens3

nmcli con add type ethernet ifname ens3 con-name BR-SRV ipv4.addresses 192.168.30.2/28 ipv4.gateway 192.168.30.1 ipv4.method manual 2>/dev/null || true
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

После этого с ISP проверь:
ping -c 3 192.168.30.2
ssh root@192.168.30.2

Потом вернись в скрипт и нажми Enter.
HINT_BR_SRV
}


linux_hint_hq_cli(){
  cat <<HINT_HQ_CLI
[WAIT] ШАГ — HQ-CLI SSH

Минимум для доступа. На HQ-CLI вставь.
Интерфейс: ens3

nmcli con add type ethernet ifname ens3 con-name HQ-CLI ipv4.addresses 192.168.200.3/28 ipv4.gateway 192.168.200.1 ipv4.method manual 2>/dev/null || true
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

После этого с ISP проверь:
ping -c 3 192.168.200.3
ssh root@192.168.200.3

Потом вернись в скрипт и нажми Enter.
HINT_HQ_CLI
}


hq_srv_payload(){
cat <<'REMOTE'
set -euo pipefail

remote_step(){ echo "REMOTE_STATUS: START: $1"; }
remote_done(){ echo "REMOTE_STATUS: OK: $1"; }
remote_fail(){ echo "REMOTE_STATUS: FAIL: $1"; exit 50; }
remote_skip(){ remote_fail "$1"; }


ensure_rpm_pkgs(){
  local label="$1"
  shift

  kill_blocking_dnf_rpm(){
    echo "REMOTE_STATUS: START: DNF-HARD: жёстко очищаю старые dnf/rpm/packagekit процессы"

    echo "REMOTE_STATUS: DNF-HARD: процессы до очистки:"
    ps -eo pid,ppid,stat,etime,cmd | grep -E '/usr/bin/dnf|/usr/bin/rpm|dnf |rpm |packagekitd|rpmdb' | grep -v grep | sed -u "s/^/REMOTE_STATUS: DNF-HARD-PROC: /" || true

    systemctl stop packagekit.service >/dev/null 2>&1 || true
    systemctl stop dnf-makecache.service >/dev/null 2>&1 || true
    systemctl stop dnf-makecache.timer >/dev/null 2>&1 || true

    pkill -9 -f '/usr/bin/dnf' >/dev/null 2>&1 || true
    pkill -9 -f '/usr/bin/rpm' >/dev/null 2>&1 || true
    pkill -9 -f 'packagekitd' >/dev/null 2>&1 || true
    pkill -9 -f 'rpmdb' >/dev/null 2>&1 || true

    sleep 2

    rm -f /var/cache/dnf/metadata_lock.pid \
          /var/cache/dnf/download_lock.pid \
          /var/cache/dnf/system-upgrade-download_lock.pid \
          /var/lib/dnf/rpmdb_lock.pid \
          /run/dnf.pid \
          /var/run/dnf.pid \
          /var/lib/rpm/.rpm.lock \
          /usr/lib/sysimage/rpm/.rpm.lock >/dev/null 2>&1 || true

    echo "REMOTE_STATUS: DNF-HARD: процессы после очистки:"
    ps -eo pid,ppid,stat,etime,cmd | grep -E '/usr/bin/dnf|/usr/bin/rpm|dnf |rpm |packagekitd|rpmdb' | grep -v grep | sed -u "s/^/REMOTE_STATUS: DNF-HARD-PROC: /" || true

    if rpm -qa >/dev/null 2>&1; then
      echo "REMOTE_STATUS: OK: DNF-HARD: rpmdb читается, rpm --rebuilddb пропускаю"
    else
      echo "REMOTE_STATUS: WARN: DNF-HARD: rpmdb не читается, выполняю rpm --rebuilddb максимум 180 секунд"
      timeout 180 rpm --rebuilddb >/tmp/${label//[^A-Za-z0-9_]/_}_rpm_rebuilddb.log 2>&1 || true
    fi

    echo "REMOTE_STATUS: OK: DNF-HARD: жёсткая очистка завершена"
  }

  fix_dns_for_dnf(){
    echo "REMOTE_STATUS: START: DNS: проверяю резолвинг для dnf"

    if getent hosts repo.red-soft.ru >/dev/null 2>&1 || getent hosts mirror.yandex.ru >/dev/null 2>&1; then
      echo "REMOTE_STATUS: OK: DNS: имена репозиториев уже резолвятся"
      return 0
    fi

    echo "REMOTE_STATUS: WARN: DNS: репозитории не резолвятся, применяю 77.88.8.8 и 8.8.8.8"

    # Прописываем DNS во все активные nmcli-подключения.
    if command -v nmcli >/dev/null 2>&1; then
      nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | while IFS=: read -r con dev; do
        [ -n "$con" ] || continue
        [ "$dev" = "lo" ] && continue
        nmcli con mod "$con" ipv4.dns "77.88.8.8 8.8.8.8" ipv4.ignore-auto-dns yes >/dev/null 2>&1 || true
        nmcli con up "$con" >/dev/null 2>&1 || true
      done
    fi

    # Если работает systemd-resolved, задаём DNS на default-интерфейс.
    local defdev=""
    defdev="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
    if [ -n "$defdev" ] && command -v resolvectl >/dev/null 2>&1; then
      resolvectl dns "$defdev" 77.88.8.8 8.8.8.8 >/dev/null 2>&1 || true
      resolvectl domain "$defdev" "~." >/dev/null 2>&1 || true
    fi
    systemctl restart systemd-resolved >/dev/null 2>&1 || true

    sleep 2

    if getent hosts repo.red-soft.ru >/dev/null 2>&1 || getent hosts mirror.yandex.ru >/dev/null 2>&1; then
      echo "REMOTE_STATUS: OK: DNS: резолвинг восстановлен через NetworkManager/systemd-resolved"
      return 0
    fi

    # Жёсткий fallback: статический /etc/resolv.conf.
    if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 || ping -c 1 -W 2 77.88.8.8 >/dev/null 2>&1; then
      echo "REMOTE_STATUS: WARN: DNS: интернет по IP есть, пишу статический /etc/resolv.conf"
      rm -f /etc/resolv.conf
      cat > /etc/resolv.conf <<'DNS_EOF'
nameserver 77.88.8.8
nameserver 8.8.8.8
DNS_EOF
      sleep 1
    fi

    if getent hosts repo.red-soft.ru >/dev/null 2>&1 || getent hosts mirror.yandex.ru >/dev/null 2>&1; then
      echo "REMOTE_STATUS: OK: DNS: резолвинг восстановлен через /etc/resolv.conf"
      return 0
    fi

    echo "REMOTE_STATUS: WARN: DNS: всё ещё не резолвится. dnf попробует установку, лог покажет причину."
    return 0
  }

  local missing=""
  for p in "$@"; do
    timeout 5 rpm -q "$p" >/dev/null 2>&1 || missing="$missing $p"
  done
  if [ -n "$missing" ]; then
    fix_dns_for_dnf
    kill_blocking_dnf_rpm
    echo "REMOTE_STATUS: START: $label: отсутствуют пакеты:$missing"
    echo "REMOTE_STATUS: INFO: $label: dnf clean all пропускаю, чтобы не перекачивать огромные метаданные RedOS"
    kill_blocking_dnf_rpm
    echo "REMOTE_STATUS: INFO: $label: активные dnf/rpm процессы перед установкой:"
    ps -eo pid,ppid,stat,cmd | grep -E "[d]nf|[r]pm" | sed -u "s/^/REMOTE_STATUS: PROC: /" || true
    echo "REMOTE_STATUS: START: $label: запускаю dnf install только для отсутствующих пакетов, без dnf update"
    dnf_log="/tmp/${label//[^A-Za-z0-9_]/_}_dnf_install.log"
    dnf_rc=99

    run_dnf_install_once(){
      local attempt="$1"
      : > "$dnf_log"
      echo "REMOTE_STATUS: DNF-START: $label: попытка $attempt/2"
      echo "REMOTE_STATUS: DNF-START: $label: лог установки: $dnf_log"
      echo "REMOTE_STATUS: DNF-START: $label: команда: dnf -v install -y $missing"

      dnf -v install -y --setopt=timeout=120 --setopt=retries=3 --setopt=minrate=1 $missing >"$dnf_log" 2>&1 &
      dnf_pid=$!
      dnf_started="$(date +%s)"
      empty_log_killed=0
      echo "REMOTE_STATUS: DNF-START: $label: PID=$dnf_pid"

      while kill -0 "$dnf_pid" >/dev/null 2>&1; do
        now="$(date +%s)"
        elapsed=$((now - dnf_started))
        echo "REMOTE_STATUS: DNF-WAIT: $label: PID=$dnf_pid, прошло ${elapsed} сек, установка ещё идёт"

        echo "REMOTE_STATUS: DNF-WAIT: $label: дерево процесса dnf:"
        ps -o pid,ppid,stat,etime,cmd --forest -g "$(ps -o sid= -p "$dnf_pid" 2>/dev/null | tr -d ' ')" 2>/dev/null | sed -u "s/^/REMOTE_STATUS: DNF-PS: /" || ps -fp "$dnf_pid" 2>/dev/null | sed -u "s/^/REMOTE_STATUS: DNF-PS: /" || true

        if [ -s "$dnf_log" ]; then
          echo "REMOTE_STATUS: DNF-WAIT: $label: последние строки dnf-лога:"
          tail -n 12 "$dnf_log" | sed -u "s/^/REMOTE_STATUS: DNF-LOG: /"
        else
          echo "REMOTE_STATUS: DNF-WAIT: $label: dnf-лог пока пустой"
          if [ "$elapsed" -ge 120 ]; then
            echo "REMOTE_STATUS: WARN: $label: dnf-лог пустой уже ${elapsed} сек — считаю, что dnf застрял до вывода"
            echo "REMOTE_STATUS: WARN: $label: убиваю dnf PID=$dnf_pid и очищаю lock"
            kill "$dnf_pid" >/dev/null 2>&1 || true
            sleep 3
            kill -9 "$dnf_pid" >/dev/null 2>&1 || true
            empty_log_killed=1
            break
          fi
        fi

        if [ "$elapsed" -ge 900 ]; then
          echo "REMOTE_STATUS: WARN: $label: dnf install идёт дольше 900 сек, убиваю PID=$dnf_pid"
          kill "$dnf_pid" >/dev/null 2>&1 || true
          sleep 5
          kill -9 "$dnf_pid" >/dev/null 2>&1 || true
          break
        fi

        sleep 20
      done

      wait "$dnf_pid" >/tmp/${label//[^A-Za-z0-9_]/_}_dnf_wait_rc.log 2>&1
      dnf_rc=$?

      if [ "$empty_log_killed" = "1" ]; then
        echo "REMOTE_STATUS: WARN: $label: dnf был убит из-за пустого лога, код wait=$dnf_rc"
        return 88
      fi

      echo "REMOTE_STATUS: DNF-END: $label: dnf завершился с кодом $dnf_rc"
      echo "REMOTE_STATUS: DNF-END: $label: финальные строки dnf-лога:"
      tail -n 40 "$dnf_log" | sed -u "s/^/REMOTE_STATUS: DNF-LOG: /" || true
      return "$dnf_rc"
    }

    run_dnf_install_once 1 || dnf_rc=$?
    if [ "${dnf_rc:-99}" = "88" ]; then
      echo "REMOTE_STATUS: START: $label: повтор после пустого dnf-лога: hard kill locks"
      kill_blocking_dnf_rpm
      run_dnf_install_once 2 || dnf_rc=$?
    fi
  fi

  local still_missing=""
  for p in "$@"; do
    timeout 5 rpm -q "$p" >/dev/null 2>&1 || still_missing="$still_missing $p"
  done
  if [ -n "$still_missing" ]; then
    echo "REMOTE_STATUS: FAIL: $label: пакеты всё ещё не установлены:$still_missing"
    echo "REMOTE_STATUS: FAIL: смотри /tmp/${label//[^A-Za-z0-9_]/_}_dnf_install.log"
    exit 31
  fi
  echo "REMOTE_STATUS: OK: $label: нужные пакеты установлены"
}

try_rpm_pkgs(){
  local label="$1"
  shift
  local missing=""
  for p in "$@"; do
    timeout 5 rpm -q "$p" >/dev/null 2>&1 || missing="$missing $p"
  done
  if [ -n "$missing" ]; then
    echo "REMOTE_STATUS: START: $label: пробую поставить необязательные пакеты:$missing"
    if declare -f fix_dns_for_dnf >/dev/null 2>&1; then fix_dns_for_dnf; fi
    if declare -f kill_blocking_dnf_rpm >/dev/null 2>&1; then kill_blocking_dnf_rpm; fi
    timeout 600 dnf install -y --setopt=timeout=20 --setopt=retries=1 $missing >/tmp/${label//[^A-Za-z0-9_]/_}_dnf_optional.log 2>&1 || true
  fi
}



repair_hq_web_app_local(){
  echo "REMOTE_STATUS: START: HQ-SRV: чиню Apache/PHP/MariaDB приложение"
  systemctl enable --now mariadb >/dev/null 2>&1 || true
  systemctl enable --now httpd >/dev/null 2>&1 || true

  mysql -u root <<'SQL_EOF'
CREATE DATABASE IF NOT EXISTS webdb CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Полностью пересоздаём web, потому что старый пароль мог остаться от прошлых запусков/dump.sql.
DROP USER IF EXISTS 'web'@'localhost';
DROP USER IF EXISTS 'web'@'%';
DROP USER IF EXISTS 'user'@'localhost';
DROP USER IF EXISTS 'user'@'%';

CREATE USER 'web'@'localhost' IDENTIFIED BY 'P@ssw0rd';
CREATE USER 'web'@'%' IDENTIFIED BY 'P@ssw0rd';

-- На всякий случай создаём совместимого пользователя user: старые index.php иногда используют user.
CREATE USER 'user'@'localhost' IDENTIFIED BY 'P@ssw0rd';
CREATE USER 'user'@'%' IDENTIFIED BY 'P@ssw0rd';

GRANT ALL PRIVILEGES ON webdb.* TO 'web'@'localhost';
GRANT ALL PRIVILEGES ON webdb.* TO 'web'@'%';
GRANT ALL PRIVILEGES ON webdb.* TO 'user'@'localhost';
GRANT ALL PRIVILEGES ON webdb.* TO 'user'@'%';

FLUSH PRIVILEGES;
SQL_EOF

  # Если dump.sql есть — импортируем повторно. Это безопаснее, чем оставить пустую/битую БД.
  DUMP_SQL="/mnt/additional/web/dump.sql"
  [ -f "$DUMP_SQL" ] || DUMP_SQL="$(find /mnt/additional -type f -iname 'dump.sql' 2>/dev/null | head -1 || true)"
  if [ -n "$DUMP_SQL" ] && [ -f "$DUMP_SQL" ]; then
    mysql -u root webdb < "$DUMP_SQL" >/tmp/hq_web_dump_reimport.log 2>&1 || echo "REMOTE_STATUS: WARN: HQ-SRV: повторный импорт dump.sql не прошёл, смотри /tmp/hq_web_dump_reimport.log"

    # После dump.sql ещё раз фиксируем пользователей: dump мог их перезаписать/сломать.
    mysql -u root <<'SQL_EOF'
DROP USER IF EXISTS 'web'@'localhost';
DROP USER IF EXISTS 'web'@'%';
DROP USER IF EXISTS 'user'@'localhost';
DROP USER IF EXISTS 'user'@'%';
CREATE USER 'web'@'localhost' IDENTIFIED BY 'P@ssw0rd';
CREATE USER 'web'@'%' IDENTIFIED BY 'P@ssw0rd';
CREATE USER 'user'@'localhost' IDENTIFIED BY 'P@ssw0rd';
CREATE USER 'user'@'%' IDENTIFIED BY 'P@ssw0rd';
GRANT ALL PRIVILEGES ON webdb.* TO 'web'@'localhost';
GRANT ALL PRIVILEGES ON webdb.* TO 'web'@'%';
GRANT ALL PRIVILEGES ON webdb.* TO 'user'@'localhost';
GRANT ALL PRIVILEGES ON webdb.* TO 'user'@'%';
FLUSH PRIVILEGES;
SQL_EOF
  fi

  if [ -f /var/www/html/index.php ]; then
    cp -a /var/www/html/index.php /var/www/html/index.php.bak.demo 2>/dev/null || true

    # Чиним самые частые варианты переменных подключения.
    perl -0pi -e 's/\$servername\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$servername = "localhost";/g;
                 s/\$server\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$server = "localhost";/g;
                 s/\$host\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$host = "localhost";/g;
                 s/\$dbhost\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$dbhost = "localhost";/g;
                 s/\$db_host\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$db_host = "localhost";/g;
                 s/\$username\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$username = "web";/g;
                 s/\$user\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$user = "web";/g;
                 s/\$dbuser\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$dbuser = "web";/g;
                 s/\$db_user\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$db_user = "web";/g;
                 s/\$password\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$password = "P@ssw0rd";/g;
                 s/\$pass\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$pass = "P@ssw0rd";/g;
                 s/\$dbpass\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$dbpass = "P@ssw0rd";/g;
                 s/\$db_pass\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$db_pass = "P@ssw0rd";/g;
                 s/\$dbname\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$dbname = "webdb";/g;
                 s/\$database\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$database = "webdb";/g;
                 s/\$db\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$db = "webdb";/g;
                 s/\$db_name\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$db_name = "webdb";/g;' /var/www/html/index.php 2>/tmp/hq_web_index_perl.err || true

    # Принудительно чиним типовые конструкторы подключения даже если там переменные.
    perl -0pi -e 's/new\s+mysqli\s*\([^;]*?\)/new mysqli("localhost", "web", "P@ssw0rd", "webdb")/gs;
                 s/mysqli_connect\s*\([^;]*?\)/mysqli_connect("localhost", "web", "P@ssw0rd", "webdb")/gs;' /var/www/html/index.php 2>/tmp/hq_web_mysqli_perl.err || true

    # Дополнительные частые имена переменных.
    perl -0pi -e 's/\$login\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$login = "web";/g;
                 s/\$db_login\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$db_login = "web";/g;
                 s/\$dbusername\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$dbusername = "web";/g;
                 s/\$db_username\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$db_username = "web";/g;
                 s/\$mysql_user\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$mysql_user = "web";/g;
                 s/\$passwd\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$passwd = "P@ssw0rd";/g;
                 s/\$pwd\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$pwd = "P@ssw0rd";/g;
                 s/\$dbpassword\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$dbpassword = "P@ssw0rd";/g;
                 s/\$db_password\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$db_password = "P@ssw0rd";/g;
                 s/\$mysql_password\s*=\s*["'\''][^"'\'']*["'\'']\s*;/\$mysql_password = "P@ssw0rd";/g;' /var/www/html/index.php 2>/tmp/hq_web_more_vars_perl.err || true

    # Для PDO mysql:host=...;dbname=... и логин/пароль PDO.
    perl -0pi -e 's/mysql:host=[^;"'\'']+/mysql:host=localhost/g;
                 s/dbname=[^;"'\'']+/dbname=webdb/g;
                 s/new\s+PDO\s*\(\s*["'\'']mysql:[^"'\'']*["'\'']\s*,\s*["'\''][^"'\'']*["'\'']\s*,\s*["'\''][^"'\'']*["'\'']\s*\)/new PDO("mysql:host=localhost;dbname=webdb;charset=utf8mb4", "web", "P@ssw0rd")/gs;' /var/www/html/index.php 2>/tmp/hq_web_pdo_perl.err || true
    # ФИНАЛЬНЫЙ ФИКС ПАРОЛЯ.
    # Без regex/perl: если Perl превратил P@ssw0rd в P, возвращаем полный пароль.
    sed -i \
      -e 's/"P"/"P@ssw0rd"/g' \
      -e "s/'P'/'P@ssw0rd'/g" \
      /var/www/html/index.php

    echo "REMOTE_STATUS: INFO: HQ-SRV: index.php после финального password-fix"
    nl -ba /var/www/html/index.php | sed -n '1,12p' | sed 's/^/REMOTE_STATUS: INDEX: /'

  else
    echo "REMOTE_STATUS: FAIL: HQ-SRV: /var/www/html/index.php отсутствует"
    exit 61
  fi

  chown -R apache:apache /var/www/html 2>/dev/null || chown -R nginx:nginx /var/www/html 2>/dev/null || true
  find /var/www/html -type d -exec chmod 755 {} \; 2>/dev/null || true
  find /var/www/html -type f -exec chmod 644 {} \; 2>/dev/null || true
  restorecon -Rv /var/www/html >/dev/null 2>&1 || true
  setsebool -P httpd_can_network_connect_db 1 >/dev/null 2>&1 || true
  setsebool -P httpd_can_network_connect 1 >/dev/null 2>&1 || true
  firewall-cmd --permanent --add-service=http >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true

  systemctl restart mariadb >/dev/null 2>&1 || true
  systemctl restart httpd >/dev/null 2>&1 || true

  if mysql -u web -p'P@ssw0rd' webdb -e 'SELECT 1;' >/tmp/hq_web_mysql_web_check.log 2>&1; then
    echo "REMOTE_STATUS: OK: HQ-SRV: пользователь web подключается к webdb"
  else
    echo "REMOTE_STATUS: FAIL: HQ-SRV: пользователь web НЕ подключается к webdb"
    cat /tmp/hq_web_mysql_web_check.log || true
    mysql -u root -e "SELECT User,Host,plugin FROM mysql.user WHERE User IN ('web','user');" 2>/dev/null || true
    exit 63
  fi

  echo "REMOTE_STATUS: INFO: HQ-SRV: первые строки index.php после фикса"
  nl -ba /var/www/html/index.php | sed -n '1,25p' || true

  if curl -s --max-time 8 http://127.0.0.1 | grep -qiE 'html|php|сайт|студент|таблиц|mysql|<!doctype|Задание 7|База данных'; then
    echo "REMOTE_STATUS: OK: HQ-SRV: Apache/PHP приложение отвечает локально"
  else
    echo "REMOTE_STATUS: FAIL: HQ-SRV: Apache/PHP всё ещё отдаёт ошибку"
    echo "REMOTE_STATUS: FAIL: текущие первые строки index.php:"
    nl -ba /var/www/html/index.php | sed -n '1,15p' 2>/dev/null || true
    echo "REMOTE_STATUS: FAIL: последние логи:"
    tail -n 80 /var/log/httpd/error_log 2>/dev/null || true
    tail -n 80 /var/log/php-fpm/www-error.log 2>/dev/null || true
    exit 62
  fi
}

safe_dnf_install(){
  echo "REMOTE_STATUS: START: HQ-SRV: проверяю/доустанавливаю пакеты"
  ensure_rpm_pkgs "HQ_SRV_PACKAGES" \
    policycoreutils-python-utils bind bind-utils chrony mdadm nfs-utils nfs4-acl-tools httpd php php-mysqlnd mariadb-server mariadb
}

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
remote_step 'HQ-SRV: проверка пакетов без установки'
safe_dnf_install
remote_done 'HQ-SRV: проверка пакетов завершена'
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

ROOT_SRC="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
ROOT_PK=""
if [ -n "$ROOT_SRC" ] && [ -b "$ROOT_SRC" ]; then
  ROOT_PK="$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -1 || true)"
  [ -n "$ROOT_PK" ] || ROOT_PK="$(basename "$ROOT_SRC" | sed -E 's/p?[0-9]+$//')"
fi

echo "REMOTE_STATUS: INFO: HQ-SRV: root filesystem source: ${ROOT_SRC:-unknown}, root parent disk: ${ROOT_PK:-unknown}"
echo "REMOTE_STATUS: INFO: HQ-SRV: lsblk перед RAID:"
lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS | sed 's/^/REMOTE_STATUS: LSBLK: /'

while read -r dev type size; do
  [ "$type" = "disk" ] || continue

  name="$(basename "$dev")"

  case "$name" in
    zram*|loop*|sr*|fd*|ram*) 
      echo "REMOTE_STATUS: INFO: HQ-SRV: пропускаю $dev ($name не является реальным диском для RAID)"
      continue
      ;;
  esac

  if [ -n "$ROOT_PK" ] && [ "$name" = "$ROOT_PK" ]; then
    echo "REMOTE_STATUS: INFO: HQ-SRV: пропускаю $dev — это системный диск с root"
    continue
  fi

  if lsblk -nrpo MOUNTPOINTS "$dev" 2>/dev/null | grep -q '/'; then
    echo "REMOTE_STATUS: INFO: HQ-SRV: пропускаю $dev — на диске/разделах есть mountpoint"
    continue
  fi

  # Если диск уже содержит ФС/RAID-сигнатуры, не берём его молча.
  if blkid "$dev" >/dev/null 2>&1; then
    echo "REMOTE_STATUS: INFO: HQ-SRV: пропускаю $dev — на нём уже есть сигнатуры blkid"
    continue
  fi

  RAID_DEVS+=("$dev")
done < <(lsblk -dnpo NAME,TYPE,SIZE)

if [ "${#RAID_DEVS[@]}" -ge 2 ]; then
  echo "REMOTE_STATUS: START: HQ-SRV: найдены реальные дополнительные диски ${RAID_DEVS[0]} и ${RAID_DEVS[1]}, делаю RAID0"

  if [ ! -b /dev/md0 ]; then
    mdadm --create --verbose /dev/md0 --level=0 --raid-devices=2 "${RAID_DEVS[0]}" "${RAID_DEVS[1]}" --force >/tmp/mdadm_create.err 2>&1 || {
      echo "REMOTE_STATUS: WARN: HQ-SRV: mdadm не смог создать /dev/md0, смотри /tmp/mdadm_create.err"
      cat /tmp/mdadm_create.err | tail -40 | sed 's/^/REMOTE_STATUS: MDADM: /'
    }
    udevadm settle >/dev/null 2>&1 || true
    sleep 2
  fi

  if [ -b /dev/md0 ]; then
    mdadm --detail --scan --verbose > /etc/mdadm.conf 2>/dev/null || true
    blkid /dev/md0 >/dev/null 2>&1 || mkfs.ext4 -F /dev/md0 >/tmp/mkfs_md0.err 2>&1 || {
      echo "REMOTE_STATUS: WARN: HQ-SRV: mkfs.ext4 /dev/md0 не прошёл, смотри /tmp/mkfs_md0.err"
      cat /tmp/mkfs_md0.err | tail -40 | sed 's/^/REMOTE_STATUS: MKFS: /'
    }
    mkdir -p /raid
    mount /dev/md0 /raid 2>/dev/null || true
    grep -q '^/dev/md0 /raid' /etc/fstab || echo '/dev/md0 /raid ext4 defaults 0 0' >> /etc/fstab
    remote_done 'HQ-SRV: RAID0 готов'
  else
    echo "REMOTE_STATUS: WARN: HQ-SRV: /dev/md0 не создан. Продолжаю без RAID, использую обычную директорию /raid"
    mkdir -p /raid
    remote_done 'HQ-SRV: RAID0 пропущен, /raid создан как обычная директория'
  fi
else
  echo "REMOTE_STATUS: WARN: HQ-SRV: реальных дополнительных дисков меньше двух. Не использую zram и системный диск."
  echo "REMOTE_STATUS: WARN: HQ-SRV: RAID0 пропущен, чтобы не сломать систему. Для настоящего RAID добавь два отдельных диска к HQ-SRV."
  mkdir -p /raid
  remote_done 'HQ-SRV: RAID0 пропущен, /raid создан как обычная директория'
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

# Если сайт уже работает, не перезатираем index.php из ISO при повторном запуске.
if curl -s --max-time 5 http://127.0.0.1 | grep -qiE 'Задание 7|База данных|html|<!doctype'; then
  echo "REMOTE_STATUS: OK: HQ-SRV: Apache/PHP уже работает, index.php не перезатираю"
  remote_done 'HQ-SRV: Apache + MariaDB готовы'
  remote_done 'HQ-SRV: готов'
  exit 0
fi
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
  remote_fail 'HQ-SRV: Additional.iso не смонтирован, смотри /tmp/mount_additional.err'
fi

DUMP_SQL="/mnt/additional/web/dump.sql"
[ -f "$DUMP_SQL" ] || DUMP_SQL="$(find /mnt/additional -type f -iname 'dump.sql' | head -1 || true)"
if [ -n "$DUMP_SQL" ] && [ -f "$DUMP_SQL" ]; then
  remote_step "HQ-SRV: импорт dump.sql ($DUMP_SQL)"
  mysql -u root webdb < "$DUMP_SQL" || remote_fail "HQ-SRV: ошибка импорта $DUMP_SQL"
  remote_done 'HQ-SRV: dump.sql импортирован'
else
  remote_fail 'HQ-SRV: dump.sql не найден на Additional.iso'
fi

INDEX_PHP="/mnt/additional/web/index.php"
[ -f "$INDEX_PHP" ] || INDEX_PHP="$(find /mnt/additional -type f -iname 'index.php' | head -1 || true)"
if [ -n "$INDEX_PHP" ] && [ -f "$INDEX_PHP" ]; then
  cp "$INDEX_PHP" /var/www/html/index.php
  remote_done "HQ-SRV: index.php скопирован из $INDEX_PHP"
else
  remote_fail 'HQ-SRV: index.php не найден на Additional.iso'
fi

IMG_DIR="/mnt/additional/web/images"
[ -d "$IMG_DIR" ] || IMG_DIR="$(find /mnt/additional -type d \( -iname 'images' -o -iname 'img' \) | head -1 || true)"
mkdir -p /var/www/html/images
if [ -n "$IMG_DIR" ] && [ -d "$IMG_DIR" ]; then
  cp -a "$IMG_DIR"/. /var/www/html/images/ 2>/tmp/hq_srv_images_copy.err || remote_fail "HQ-SRV: не смог скопировать images из $IMG_DIR"
  remote_done "HQ-SRV: images скопированы из $IMG_DIR"
else
  IMG_COUNT="$(find /mnt/additional -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.gif' -o -iname '*.webp' -o -iname '*.svg' \) | wc -l)"
  if [ "$IMG_COUNT" -gt 0 ]; then
    find /mnt/additional -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.gif' -o -iname '*.webp' -o -iname '*.svg' \) -exec cp -n {} /var/www/html/images/ \; 2>/tmp/hq_srv_images_find_copy.err || true
    remote_done "HQ-SRV: отдельные image-файлы найдены и скопированы в /var/www/html/images"
  else
    echo "REMOTE_STATUS: INFO: HQ-SRV: image-файлов на Additional.iso нет; создана пустая /var/www/html/images"
    remote_done 'HQ-SRV: images обработаны'
  fi
fi
systemctl restart mariadb
systemctl restart httpd
repair_hq_web_app_local
remote_done 'HQ-SRV: Apache + MariaDB готовы'
remote_done 'HQ-SRV: готов'
REMOTE
}

br_srv_payload(){
cat <<'REMOTE'
set -euo pipefail

remote_step(){ echo "REMOTE_STATUS: START: $1"; }
remote_done(){ echo "REMOTE_STATUS: OK: $1"; }
remote_fail(){ echo "REMOTE_STATUS: FAIL: $1"; exit 50; }
remote_skip(){ remote_fail "$1"; }


ensure_rpm_pkgs(){
  local label="$1"
  shift

  kill_blocking_dnf_rpm(){
    echo "REMOTE_STATUS: START: DNF-HARD: жёстко очищаю старые dnf/rpm/packagekit процессы"

    echo "REMOTE_STATUS: DNF-HARD: процессы до очистки:"
    ps -eo pid,ppid,stat,etime,cmd | grep -E '/usr/bin/dnf|/usr/bin/rpm|dnf |rpm |packagekitd|rpmdb' | grep -v grep | sed -u "s/^/REMOTE_STATUS: DNF-HARD-PROC: /" || true

    systemctl stop packagekit.service >/dev/null 2>&1 || true
    systemctl stop dnf-makecache.service >/dev/null 2>&1 || true
    systemctl stop dnf-makecache.timer >/dev/null 2>&1 || true

    pkill -9 -f '/usr/bin/dnf' >/dev/null 2>&1 || true
    pkill -9 -f '/usr/bin/rpm' >/dev/null 2>&1 || true
    pkill -9 -f 'packagekitd' >/dev/null 2>&1 || true
    pkill -9 -f 'rpmdb' >/dev/null 2>&1 || true

    sleep 2

    rm -f /var/cache/dnf/metadata_lock.pid \
          /var/cache/dnf/download_lock.pid \
          /var/cache/dnf/system-upgrade-download_lock.pid \
          /var/lib/dnf/rpmdb_lock.pid \
          /run/dnf.pid \
          /var/run/dnf.pid \
          /var/lib/rpm/.rpm.lock \
          /usr/lib/sysimage/rpm/.rpm.lock >/dev/null 2>&1 || true

    echo "REMOTE_STATUS: DNF-HARD: процессы после очистки:"
    ps -eo pid,ppid,stat,etime,cmd | grep -E '/usr/bin/dnf|/usr/bin/rpm|dnf |rpm |packagekitd|rpmdb' | grep -v grep | sed -u "s/^/REMOTE_STATUS: DNF-HARD-PROC: /" || true

    if rpm -qa >/dev/null 2>&1; then
      echo "REMOTE_STATUS: OK: DNF-HARD: rpmdb читается, rpm --rebuilddb пропускаю"
    else
      echo "REMOTE_STATUS: WARN: DNF-HARD: rpmdb не читается, выполняю rpm --rebuilddb максимум 180 секунд"
      timeout 180 rpm --rebuilddb >/tmp/${label//[^A-Za-z0-9_]/_}_rpm_rebuilddb.log 2>&1 || true
    fi

    echo "REMOTE_STATUS: OK: DNF-HARD: жёсткая очистка завершена"
  }

  fix_dns_for_dnf(){
    echo "REMOTE_STATUS: START: DNS: проверяю резолвинг для dnf"

    if getent hosts repo.red-soft.ru >/dev/null 2>&1 || getent hosts mirror.yandex.ru >/dev/null 2>&1; then
      echo "REMOTE_STATUS: OK: DNS: имена репозиториев уже резолвятся"
      return 0
    fi

    echo "REMOTE_STATUS: WARN: DNS: репозитории не резолвятся, применяю 77.88.8.8 и 8.8.8.8"

    # Прописываем DNS во все активные nmcli-подключения.
    if command -v nmcli >/dev/null 2>&1; then
      nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | while IFS=: read -r con dev; do
        [ -n "$con" ] || continue
        [ "$dev" = "lo" ] && continue
        nmcli con mod "$con" ipv4.dns "77.88.8.8 8.8.8.8" ipv4.ignore-auto-dns yes >/dev/null 2>&1 || true
        nmcli con up "$con" >/dev/null 2>&1 || true
      done
    fi

    # Если работает systemd-resolved, задаём DNS на default-интерфейс.
    local defdev=""
    defdev="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
    if [ -n "$defdev" ] && command -v resolvectl >/dev/null 2>&1; then
      resolvectl dns "$defdev" 77.88.8.8 8.8.8.8 >/dev/null 2>&1 || true
      resolvectl domain "$defdev" "~." >/dev/null 2>&1 || true
    fi
    systemctl restart systemd-resolved >/dev/null 2>&1 || true

    sleep 2

    if getent hosts repo.red-soft.ru >/dev/null 2>&1 || getent hosts mirror.yandex.ru >/dev/null 2>&1; then
      echo "REMOTE_STATUS: OK: DNS: резолвинг восстановлен через NetworkManager/systemd-resolved"
      return 0
    fi

    # Жёсткий fallback: статический /etc/resolv.conf.
    if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 || ping -c 1 -W 2 77.88.8.8 >/dev/null 2>&1; then
      echo "REMOTE_STATUS: WARN: DNS: интернет по IP есть, пишу статический /etc/resolv.conf"
      rm -f /etc/resolv.conf
      cat > /etc/resolv.conf <<'DNS_EOF'
nameserver 77.88.8.8
nameserver 8.8.8.8
DNS_EOF
      sleep 1
    fi

    if getent hosts repo.red-soft.ru >/dev/null 2>&1 || getent hosts mirror.yandex.ru >/dev/null 2>&1; then
      echo "REMOTE_STATUS: OK: DNS: резолвинг восстановлен через /etc/resolv.conf"
      return 0
    fi

    echo "REMOTE_STATUS: WARN: DNS: всё ещё не резолвится. dnf попробует установку, лог покажет причину."
    return 0
  }

  local missing=""
  for p in "$@"; do
    timeout 5 rpm -q "$p" >/dev/null 2>&1 || missing="$missing $p"
  done
  if [ -n "$missing" ]; then
    fix_dns_for_dnf
    kill_blocking_dnf_rpm
    echo "REMOTE_STATUS: START: $label: отсутствуют пакеты:$missing"
    echo "REMOTE_STATUS: INFO: $label: dnf clean all пропускаю, чтобы не перекачивать огромные метаданные RedOS"
    kill_blocking_dnf_rpm
    echo "REMOTE_STATUS: INFO: $label: активные dnf/rpm процессы перед установкой:"
    ps -eo pid,ppid,stat,cmd | grep -E "[d]nf|[r]pm" | sed -u "s/^/REMOTE_STATUS: PROC: /" || true
    echo "REMOTE_STATUS: START: $label: запускаю dnf install только для отсутствующих пакетов, без dnf update"
    dnf_log="/tmp/${label//[^A-Za-z0-9_]/_}_dnf_install.log"
    dnf_rc=99

    run_dnf_install_once(){
      local attempt="$1"
      : > "$dnf_log"
      echo "REMOTE_STATUS: DNF-START: $label: попытка $attempt/2"
      echo "REMOTE_STATUS: DNF-START: $label: лог установки: $dnf_log"
      echo "REMOTE_STATUS: DNF-START: $label: команда: dnf -v install -y $missing"

      dnf -v install -y --setopt=timeout=120 --setopt=retries=3 --setopt=minrate=1 $missing >"$dnf_log" 2>&1 &
      dnf_pid=$!
      dnf_started="$(date +%s)"
      empty_log_killed=0
      echo "REMOTE_STATUS: DNF-START: $label: PID=$dnf_pid"

      while kill -0 "$dnf_pid" >/dev/null 2>&1; do
        now="$(date +%s)"
        elapsed=$((now - dnf_started))
        echo "REMOTE_STATUS: DNF-WAIT: $label: PID=$dnf_pid, прошло ${elapsed} сек, установка ещё идёт"

        echo "REMOTE_STATUS: DNF-WAIT: $label: дерево процесса dnf:"
        ps -o pid,ppid,stat,etime,cmd --forest -g "$(ps -o sid= -p "$dnf_pid" 2>/dev/null | tr -d ' ')" 2>/dev/null | sed -u "s/^/REMOTE_STATUS: DNF-PS: /" || ps -fp "$dnf_pid" 2>/dev/null | sed -u "s/^/REMOTE_STATUS: DNF-PS: /" || true

        if [ -s "$dnf_log" ]; then
          echo "REMOTE_STATUS: DNF-WAIT: $label: последние строки dnf-лога:"
          tail -n 12 "$dnf_log" | sed -u "s/^/REMOTE_STATUS: DNF-LOG: /"
        else
          echo "REMOTE_STATUS: DNF-WAIT: $label: dnf-лог пока пустой"
          if [ "$elapsed" -ge 120 ]; then
            echo "REMOTE_STATUS: WARN: $label: dnf-лог пустой уже ${elapsed} сек — считаю, что dnf застрял до вывода"
            echo "REMOTE_STATUS: WARN: $label: убиваю dnf PID=$dnf_pid и очищаю lock"
            kill "$dnf_pid" >/dev/null 2>&1 || true
            sleep 3
            kill -9 "$dnf_pid" >/dev/null 2>&1 || true
            empty_log_killed=1
            break
          fi
        fi

        if [ "$elapsed" -ge 900 ]; then
          echo "REMOTE_STATUS: WARN: $label: dnf install идёт дольше 900 сек, убиваю PID=$dnf_pid"
          kill "$dnf_pid" >/dev/null 2>&1 || true
          sleep 5
          kill -9 "$dnf_pid" >/dev/null 2>&1 || true
          break
        fi

        sleep 20
      done

      wait "$dnf_pid" >/tmp/${label//[^A-Za-z0-9_]/_}_dnf_wait_rc.log 2>&1
      dnf_rc=$?

      if [ "$empty_log_killed" = "1" ]; then
        echo "REMOTE_STATUS: WARN: $label: dnf был убит из-за пустого лога, код wait=$dnf_rc"
        return 88
      fi

      echo "REMOTE_STATUS: DNF-END: $label: dnf завершился с кодом $dnf_rc"
      echo "REMOTE_STATUS: DNF-END: $label: финальные строки dnf-лога:"
      tail -n 40 "$dnf_log" | sed -u "s/^/REMOTE_STATUS: DNF-LOG: /" || true
      return "$dnf_rc"
    }

    run_dnf_install_once 1 || dnf_rc=$?
    if [ "${dnf_rc:-99}" = "88" ]; then
      echo "REMOTE_STATUS: START: $label: повтор после пустого dnf-лога: hard kill locks"
      kill_blocking_dnf_rpm
      run_dnf_install_once 2 || dnf_rc=$?
    fi
  fi

  local still_missing=""
  for p in "$@"; do
    timeout 5 rpm -q "$p" >/dev/null 2>&1 || still_missing="$still_missing $p"
  done
  if [ -n "$still_missing" ]; then
    echo "REMOTE_STATUS: FAIL: $label: пакеты всё ещё не установлены:$still_missing"
    echo "REMOTE_STATUS: FAIL: смотри /tmp/${label//[^A-Za-z0-9_]/_}_dnf_install.log"
    exit 31
  fi
  echo "REMOTE_STATUS: OK: $label: нужные пакеты установлены"
}

try_rpm_pkgs(){
  local label="$1"
  shift
  local missing=""
  for p in "$@"; do
    timeout 5 rpm -q "$p" >/dev/null 2>&1 || missing="$missing $p"
  done
  if [ -n "$missing" ]; then
    echo "REMOTE_STATUS: START: $label: пробую поставить необязательные пакеты:$missing"
    if declare -f fix_dns_for_dnf >/dev/null 2>&1; then fix_dns_for_dnf; fi
    if declare -f kill_blocking_dnf_rpm >/dev/null 2>&1; then kill_blocking_dnf_rpm; fi
    timeout 600 dnf install -y --setopt=timeout=20 --setopt=retries=1 $missing >/tmp/${label//[^A-Za-z0-9_]/_}_dnf_optional.log 2>&1 || true
  fi
}

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
echo "REMOTE_STATUS: START: BR-SRV: проверяю/доустанавливаю пакеты"
# Для BR-SRV cifs-utils НЕ блокер: это клиентский пакет для mount -t cifs.
# Серверная часть Samba оценивается через доступ HQ-CLI к BR-SRV, пользователей hquser1-5 и группу hq.
ensure_rpm_pkgs "BR_SRV_BASE_PACKAGES" policycoreutils-python-utils chrony samba samba-client nginx openssl

docker_cmd_ok(){
  command -v docker >/dev/null 2>&1 && docker --version >/dev/null 2>&1
}

if ! docker_cmd_ok; then
  echo "REMOTE_STATUS: START: BR-SRV: Docker не найден, пробую docker-ce/docker/podman-docker"
  timeout 900 dnf install -y --setopt=timeout=120 --setopt=retries=5 --setopt=minrate=1 docker-ce docker-ce-cli >/tmp/br_srv_dnf_docker_ce.log 2>&1 || true
fi

if ! docker_cmd_ok; then
  echo "REMOTE_STATUS: WARN: BR-SRV: docker-ce не поставился, пробую пакет docker"
  timeout 900 dnf install -y --setopt=timeout=120 --setopt=retries=5 --setopt=minrate=1 docker >/tmp/br_srv_dnf_docker.log 2>&1 || true
fi

if ! docker_cmd_ok; then
  echo "REMOTE_STATUS: WARN: BR-SRV: docker не дал рабочую команду, пробую podman podman-docker"
  timeout 900 dnf install -y --setopt=timeout=120 --setopt=retries=5 --setopt=minrate=1 podman podman-docker >/tmp/br_srv_dnf_podman_docker.log 2>&1 || true
fi

if docker_cmd_ok; then
  echo "REMOTE_STATUS: OK: BR-SRV: команда docker доступна: $(docker --version 2>/dev/null || true)"
else
  echo "REMOTE_STATUS: FAIL: BR-SRV: Docker/podman-docker всё ещё не установлен"
  echo "REMOTE_STATUS: FAIL: смотри /tmp/br_srv_dnf_docker_ce.log, /tmp/br_srv_dnf_docker.log, /tmp/br_srv_dnf_podman_docker.log"
  exit 31
fi

if systemctl list-unit-files docker.service >/dev/null 2>&1; then
  systemctl enable --now docker >/dev/null 2>&1 || true
else
  systemctl enable --now podman.socket >/dev/null 2>&1 || true
  mkdir -p /var/run
  ln -sf /run/podman/podman.sock /var/run/docker.sock 2>/dev/null || true
fi

compose_cmd_ok(){
  docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1 || command -v podman-compose >/dev/null 2>&1
}

if ! compose_cmd_ok; then
  echo "REMOTE_STATUS: START: BR-SRV: compose не найден, ставлю docker-compose/docker-compose-plugin"
  timeout 900 dnf install -y --setopt=timeout=120 --setopt=retries=5 --setopt=minrate=1 docker-compose docker-compose-plugin >/tmp/br_srv_dnf_compose.log 2>&1 || true
fi

if ! compose_cmd_ok; then
  echo "REMOTE_STATUS: WARN: BR-SRV: docker-compose не поставился, пробую podman-compose"
  timeout 900 dnf install -y --setopt=timeout=120 --setopt=retries=5 --setopt=minrate=1 podman-compose >/tmp/br_srv_dnf_podman_compose.log 2>&1 || true
fi

if compose_cmd_ok; then
  echo "REMOTE_STATUS: OK: BR-SRV: compose доступен"
else
  echo "REMOTE_STATUS: FAIL: BR-SRV: compose всё ещё не установлен"
  echo "REMOTE_STATUS: FAIL: смотри /tmp/br_srv_dnf_compose.log или /tmp/br_srv_dnf_podman_compose.log"
  exit 31
fi

# Необязательная попытка: если пакет есть в репозитории, поставим, но BR-SRV не должен падать из-за отсутствия cifs-utils.
try_rpm_pkgs "BR_SRV_OPTIONAL_CIFS" cifs-utils
echo "REMOTE_STATUS: OK: BR-SRV: обязательные пакеты установлены"
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
if systemctl list-unit-files docker.service >/dev/null 2>&1; then
  systemctl enable --now docker >/dev/null 2>&1 || true
else
  systemctl enable --now podman.socket >/dev/null 2>&1 || true
  mkdir -p /var/run
  ln -sf /run/podman/podman.sock /var/run/docker.sock 2>/dev/null || true
fi

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
  if docker image inspect site:latest >/dev/null 2>&1 && (docker image inspect mariadb:11 >/dev/null 2>&1 || docker image inspect mariadb:10.11 >/dev/null 2>&1 || docker image inspect mariadb:latest >/dev/null 2>&1); then
    echo 'REMOTE_STATUS: OK: Additional.iso не смонтирован, но нужные Docker images уже есть локально'
  else
    remote_fail 'BR-SRV: Additional.iso не смонтирован и Docker images отсутствуют'
  fi
fi

# Пытаемся загрузить локальные Docker-образы из Additional.iso, если они есть.
if find /mnt/additional -type f -iname '*site*.tar' | head -1 | grep -q .; then
  SITE_TAR="$(find /mnt/additional -type f -iname '*site*.tar' | head -1)"
  echo "REMOTE_STATUS: START: BR-SRV: docker load $SITE_TAR"
  docker load < "$SITE_TAR" >/tmp/br_srv_docker_site_load.log 2>&1 || true
  echo 'REMOTE_STATUS: OK: BR-SRV: site image load завершён/пропущен'
else
  if docker image inspect site:latest >/dev/null 2>&1; then
    echo 'REMOTE_STATUS: OK: BR-SRV: site*.tar не найден, но site:latest уже есть локально'
  else
    remote_fail 'BR-SRV: site*.tar не найден на Additional.iso и site:latest отсутствует'
  fi
fi

if find /mnt/additional -type f \( -iname '*mariadb*.tar' -o -iname '*maria*.tar' \) | head -1 | grep -q .; then
  DB_TAR="$(find /mnt/additional -type f \( -iname '*mariadb*.tar' -o -iname '*maria*.tar' \) | head -1)"
  echo "REMOTE_STATUS: START: BR-SRV: docker load $DB_TAR"
  docker load < "$DB_TAR" >/tmp/br_srv_docker_db_load.log 2>&1 || true
  echo 'REMOTE_STATUS: OK: BR-SRV: mariadb image load завершён/пропущен'
else
  if docker image inspect mariadb:11 >/dev/null 2>&1 || docker image inspect mariadb:10.11 >/dev/null 2>&1 || docker image inspect mariadb:latest >/dev/null 2>&1; then
    echo 'REMOTE_STATUS: OK: BR-SRV: mariadb*.tar не найден, но MariaDB image уже есть локально'
  else
    remote_fail 'BR-SRV: mariadb*.tar не найден на Additional.iso и MariaDB image отсутствует'
  fi
fi

# Compose ждёт mariadb:11. На Additional.iso часто лежит mariadb:10.11 или mariadb:latest.
# Ничего не скачиваем: делаем локальный tag на уже загруженный образ.
if docker image inspect mariadb:11 >/dev/null 2>&1; then
  echo 'REMOTE_STATUS: OK: BR-SRV: образ mariadb:11 есть'
elif docker image inspect mariadb:10.11 >/dev/null 2>&1; then
  docker tag mariadb:10.11 mariadb:11
  echo 'REMOTE_STATUS: OK: BR-SRV: mariadb:10.11 отмечен как mariadb:11'
elif docker image inspect mariadb:latest >/dev/null 2>&1; then
  docker tag mariadb:latest mariadb:11
  echo 'REMOTE_STATUS: OK: BR-SRV: mariadb:latest отмечен как mariadb:11'
else
  remote_fail 'BR-SRV: образ mariadb:11/10.11/latest не найден; скачивание из интернета запрещено'
fi

if docker image inspect site:latest >/dev/null 2>&1; then
  echo 'REMOTE_STATUS: OK: BR-SRV: образ site:latest есть'
else
  remote_fail 'BR-SRV: образ site:latest не найден; приложение не стартует без него'
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
elif command -v podman-compose >/dev/null 2>&1; then
  COMPOSE_CMD="podman-compose"
else
  remote_fail 'BR-SRV: docker compose/docker-compose/podman-compose не найден'
fi

if [ -n "$COMPOSE_CMD" ]; then
  if docker image inspect site:latest >/dev/null 2>&1 && docker image inspect mariadb:11 >/dev/null 2>&1; then
    echo 'REMOTE_STATUS: START: BR-SRV: запускаю compose /opt/exam-app строго без pull из интернета'
    $COMPOSE_CMD down >/tmp/br_srv_compose_down.log 2>&1 || true
    if timeout 300 $COMPOSE_CMD up -d --pull never >/tmp/br_srv_compose_up.log 2>&1; then
      echo 'REMOTE_STATUS: OK: BR-SRV: compose up выполнен через --pull never'
    else
      echo 'REMOTE_STATUS: WARN: BR-SRV: compose не поддержал --pull never или завершился ошибкой; пробую без pull-флага, но только потому что локальные images уже есть'
      timeout 300 $COMPOSE_CMD up -d >/tmp/br_srv_compose_up.log 2>&1 || true
      echo 'REMOTE_STATUS: OK: BR-SRV: compose up выполнен fallback'
    fi
  else
    remote_fail 'BR-SRV: site:latest или mariadb:11 отсутствуют, compose не запускаю'
  fi
fi

docker ps --format 'REMOTE_STATUS: DOCKER: {{.Names}} {{.Image}} {{.Status}} {{.Ports}}' 2>/dev/null || true

for n in 1 2 3 4 5 6; do
  if curl -s --max-time 10 http://127.0.0.1:8080 >/tmp/br_srv_app_check.html 2>/tmp/br_srv_app_check.err; then
    echo 'REMOTE_STATUS: OK: BR-SRV: приложение отвечает на 127.0.0.1:8080'
    break
  fi
  echo "REMOTE_STATUS: WAIT: BR-SRV: приложение ещё не ответило, попытка $n/6"
  sleep 5
done

if ! curl -s --max-time 10 http://127.0.0.1:8080 >/tmp/br_srv_app_check.html 2>/tmp/br_srv_app_check.err; then
  echo 'REMOTE_STATUS: FAIL: BR-SRV: приложение не ответило на 127.0.0.1:8080'
  echo 'REMOTE_STATUS: FAIL: смотри /tmp/br_srv_compose_up.log и /tmp/br_srv_compose_logs.log'
  (cd /opt/exam-app && ($COMPOSE_CMD logs --tail=80 2>/tmp/br_srv_compose_logs.err || true)) >/tmp/br_srv_compose_logs.log 2>&1 || true
  exit 42
fi

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

remote_step(){ echo "REMOTE_STATUS: START: $1"; }
remote_done(){ echo "REMOTE_STATUS: OK: $1"; }
remote_fail(){ echo "REMOTE_STATUS: FAIL: $1"; exit 50; }
remote_skip(){ remote_fail "$1"; }


ensure_rpm_pkgs(){
  local label="$1"
  shift

  kill_blocking_dnf_rpm(){
    echo "REMOTE_STATUS: START: DNF-HARD: жёстко очищаю старые dnf/rpm/packagekit процессы"

    echo "REMOTE_STATUS: DNF-HARD: процессы до очистки:"
    ps -eo pid,ppid,stat,etime,cmd | grep -E '/usr/bin/dnf|/usr/bin/rpm|dnf |rpm |packagekitd|rpmdb' | grep -v grep | sed -u "s/^/REMOTE_STATUS: DNF-HARD-PROC: /" || true

    systemctl stop packagekit.service >/dev/null 2>&1 || true
    systemctl stop dnf-makecache.service >/dev/null 2>&1 || true
    systemctl stop dnf-makecache.timer >/dev/null 2>&1 || true

    pkill -9 -f '/usr/bin/dnf' >/dev/null 2>&1 || true
    pkill -9 -f '/usr/bin/rpm' >/dev/null 2>&1 || true
    pkill -9 -f 'packagekitd' >/dev/null 2>&1 || true
    pkill -9 -f 'rpmdb' >/dev/null 2>&1 || true

    sleep 2

    rm -f /var/cache/dnf/metadata_lock.pid \
          /var/cache/dnf/download_lock.pid \
          /var/cache/dnf/system-upgrade-download_lock.pid \
          /var/lib/dnf/rpmdb_lock.pid \
          /run/dnf.pid \
          /var/run/dnf.pid \
          /var/lib/rpm/.rpm.lock \
          /usr/lib/sysimage/rpm/.rpm.lock >/dev/null 2>&1 || true

    echo "REMOTE_STATUS: DNF-HARD: процессы после очистки:"
    ps -eo pid,ppid,stat,etime,cmd | grep -E '/usr/bin/dnf|/usr/bin/rpm|dnf |rpm |packagekitd|rpmdb' | grep -v grep | sed -u "s/^/REMOTE_STATUS: DNF-HARD-PROC: /" || true

    if rpm -qa >/dev/null 2>&1; then
      echo "REMOTE_STATUS: OK: DNF-HARD: rpmdb читается, rpm --rebuilddb пропускаю"
    else
      echo "REMOTE_STATUS: WARN: DNF-HARD: rpmdb не читается, выполняю rpm --rebuilddb максимум 180 секунд"
      timeout 180 rpm --rebuilddb >/tmp/${label//[^A-Za-z0-9_]/_}_rpm_rebuilddb.log 2>&1 || true
    fi

    echo "REMOTE_STATUS: OK: DNF-HARD: жёсткая очистка завершена"
  }

  fix_dns_for_dnf(){
    echo "REMOTE_STATUS: START: DNS: проверяю резолвинг для dnf"

    if getent hosts repo.red-soft.ru >/dev/null 2>&1 || getent hosts mirror.yandex.ru >/dev/null 2>&1; then
      echo "REMOTE_STATUS: OK: DNS: имена репозиториев уже резолвятся"
      return 0
    fi

    echo "REMOTE_STATUS: WARN: DNS: репозитории не резолвятся, применяю 77.88.8.8 и 8.8.8.8"

    # Прописываем DNS во все активные nmcli-подключения.
    if command -v nmcli >/dev/null 2>&1; then
      nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | while IFS=: read -r con dev; do
        [ -n "$con" ] || continue
        [ "$dev" = "lo" ] && continue
        nmcli con mod "$con" ipv4.dns "77.88.8.8 8.8.8.8" ipv4.ignore-auto-dns yes >/dev/null 2>&1 || true
        nmcli con up "$con" >/dev/null 2>&1 || true
      done
    fi

    # Если работает systemd-resolved, задаём DNS на default-интерфейс.
    local defdev=""
    defdev="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
    if [ -n "$defdev" ] && command -v resolvectl >/dev/null 2>&1; then
      resolvectl dns "$defdev" 77.88.8.8 8.8.8.8 >/dev/null 2>&1 || true
      resolvectl domain "$defdev" "~." >/dev/null 2>&1 || true
    fi
    systemctl restart systemd-resolved >/dev/null 2>&1 || true

    sleep 2

    if getent hosts repo.red-soft.ru >/dev/null 2>&1 || getent hosts mirror.yandex.ru >/dev/null 2>&1; then
      echo "REMOTE_STATUS: OK: DNS: резолвинг восстановлен через NetworkManager/systemd-resolved"
      return 0
    fi

    # Жёсткий fallback: статический /etc/resolv.conf.
    if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 || ping -c 1 -W 2 77.88.8.8 >/dev/null 2>&1; then
      echo "REMOTE_STATUS: WARN: DNS: интернет по IP есть, пишу статический /etc/resolv.conf"
      rm -f /etc/resolv.conf
      cat > /etc/resolv.conf <<'DNS_EOF'
nameserver 77.88.8.8
nameserver 8.8.8.8
DNS_EOF
      sleep 1
    fi

    if getent hosts repo.red-soft.ru >/dev/null 2>&1 || getent hosts mirror.yandex.ru >/dev/null 2>&1; then
      echo "REMOTE_STATUS: OK: DNS: резолвинг восстановлен через /etc/resolv.conf"
      return 0
    fi

    echo "REMOTE_STATUS: WARN: DNS: всё ещё не резолвится. dnf попробует установку, лог покажет причину."
    return 0
  }

  local missing=""
  for p in "$@"; do
    timeout 5 rpm -q "$p" >/dev/null 2>&1 || missing="$missing $p"
  done
  if [ -n "$missing" ]; then
    fix_dns_for_dnf
    kill_blocking_dnf_rpm
    echo "REMOTE_STATUS: START: $label: отсутствуют пакеты:$missing"
    echo "REMOTE_STATUS: INFO: $label: dnf clean all пропускаю, чтобы не перекачивать огромные метаданные RedOS"
    kill_blocking_dnf_rpm
    echo "REMOTE_STATUS: INFO: $label: активные dnf/rpm процессы перед установкой:"
    ps -eo pid,ppid,stat,cmd | grep -E "[d]nf|[r]pm" | sed -u "s/^/REMOTE_STATUS: PROC: /" || true
    echo "REMOTE_STATUS: START: $label: запускаю dnf install только для отсутствующих пакетов, без dnf update"
    dnf_log="/tmp/${label//[^A-Za-z0-9_]/_}_dnf_install.log"
    dnf_rc=99

    run_dnf_install_once(){
      local attempt="$1"
      : > "$dnf_log"
      echo "REMOTE_STATUS: DNF-START: $label: попытка $attempt/2"
      echo "REMOTE_STATUS: DNF-START: $label: лог установки: $dnf_log"
      echo "REMOTE_STATUS: DNF-START: $label: команда: dnf -v install -y $missing"

      dnf -v install -y --setopt=timeout=120 --setopt=retries=3 --setopt=minrate=1 $missing >"$dnf_log" 2>&1 &
      dnf_pid=$!
      dnf_started="$(date +%s)"
      empty_log_killed=0
      echo "REMOTE_STATUS: DNF-START: $label: PID=$dnf_pid"

      while kill -0 "$dnf_pid" >/dev/null 2>&1; do
        now="$(date +%s)"
        elapsed=$((now - dnf_started))
        echo "REMOTE_STATUS: DNF-WAIT: $label: PID=$dnf_pid, прошло ${elapsed} сек, установка ещё идёт"

        echo "REMOTE_STATUS: DNF-WAIT: $label: дерево процесса dnf:"
        ps -o pid,ppid,stat,etime,cmd --forest -g "$(ps -o sid= -p "$dnf_pid" 2>/dev/null | tr -d ' ')" 2>/dev/null | sed -u "s/^/REMOTE_STATUS: DNF-PS: /" || ps -fp "$dnf_pid" 2>/dev/null | sed -u "s/^/REMOTE_STATUS: DNF-PS: /" || true

        if [ -s "$dnf_log" ]; then
          echo "REMOTE_STATUS: DNF-WAIT: $label: последние строки dnf-лога:"
          tail -n 12 "$dnf_log" | sed -u "s/^/REMOTE_STATUS: DNF-LOG: /"
        else
          echo "REMOTE_STATUS: DNF-WAIT: $label: dnf-лог пока пустой"
          if [ "$elapsed" -ge 120 ]; then
            echo "REMOTE_STATUS: WARN: $label: dnf-лог пустой уже ${elapsed} сек — считаю, что dnf застрял до вывода"
            echo "REMOTE_STATUS: WARN: $label: убиваю dnf PID=$dnf_pid и очищаю lock"
            kill "$dnf_pid" >/dev/null 2>&1 || true
            sleep 3
            kill -9 "$dnf_pid" >/dev/null 2>&1 || true
            empty_log_killed=1
            break
          fi
        fi

        if [ "$elapsed" -ge 900 ]; then
          echo "REMOTE_STATUS: WARN: $label: dnf install идёт дольше 900 сек, убиваю PID=$dnf_pid"
          kill "$dnf_pid" >/dev/null 2>&1 || true
          sleep 5
          kill -9 "$dnf_pid" >/dev/null 2>&1 || true
          break
        fi

        sleep 20
      done

      wait "$dnf_pid" >/tmp/${label//[^A-Za-z0-9_]/_}_dnf_wait_rc.log 2>&1
      dnf_rc=$?

      if [ "$empty_log_killed" = "1" ]; then
        echo "REMOTE_STATUS: WARN: $label: dnf был убит из-за пустого лога, код wait=$dnf_rc"
        return 88
      fi

      echo "REMOTE_STATUS: DNF-END: $label: dnf завершился с кодом $dnf_rc"
      echo "REMOTE_STATUS: DNF-END: $label: финальные строки dnf-лога:"
      tail -n 40 "$dnf_log" | sed -u "s/^/REMOTE_STATUS: DNF-LOG: /" || true
      return "$dnf_rc"
    }

    run_dnf_install_once 1 || dnf_rc=$?
    if [ "${dnf_rc:-99}" = "88" ]; then
      echo "REMOTE_STATUS: START: $label: повтор после пустого dnf-лога: hard kill locks"
      kill_blocking_dnf_rpm
      run_dnf_install_once 2 || dnf_rc=$?
    fi
  fi

  local still_missing=""
  for p in "$@"; do
    timeout 5 rpm -q "$p" >/dev/null 2>&1 || still_missing="$still_missing $p"
  done
  if [ -n "$still_missing" ]; then
    echo "REMOTE_STATUS: FAIL: $label: пакеты всё ещё не установлены:$still_missing"
    echo "REMOTE_STATUS: FAIL: смотри /tmp/${label//[^A-Za-z0-9_]/_}_dnf_install.log"
    exit 31
  fi
  echo "REMOTE_STATUS: OK: $label: нужные пакеты установлены"
}

try_rpm_pkgs(){
  local label="$1"
  shift
  local missing=""
  for p in "$@"; do
    timeout 5 rpm -q "$p" >/dev/null 2>&1 || missing="$missing $p"
  done
  if [ -n "$missing" ]; then
    echo "REMOTE_STATUS: START: $label: пробую поставить необязательные пакеты:$missing"
    if declare -f fix_dns_for_dnf >/dev/null 2>&1; then fix_dns_for_dnf; fi
    if declare -f kill_blocking_dnf_rpm >/dev/null 2>&1; then kill_blocking_dnf_rpm; fi
    timeout 600 dnf install -y --setopt=timeout=20 --setopt=retries=1 $missing >/tmp/${label//[^A-Za-z0-9_]/_}_dnf_optional.log 2>&1 || true
  fi
}

hostnamectl set-hostname hq-cli.sirius-exam.org || true
echo "REMOTE_STATUS: START: HQ-CLI: проверяю/доустанавливаю базовые пакеты"
ensure_rpm_pkgs "HQ_CLI_BASE_PACKAGES" samba-client cifs-utils nfs-utils chrony curl bind-utils sudo

if timeout 5 rpm -q yandex-browser-stable >/dev/null 2>&1; then
  echo "REMOTE_STATUS: OK: HQ-CLI: yandex-browser-stable уже установлен"
else
  echo "REMOTE_STATUS: INFO: HQ-CLI: yandex-browser-stable не установлен"
  echo "REMOTE_STATUS: INFO: HQ-CLI: установи браузер вручную после скрипта с другого браузера/локального rpm"
fi
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
  local ip="$1"
  local user="$2"
  local pass="$3"
  local name="$4"
  local payload="$5"
  local err="/tmp/demoexam_${name}.err"
  local out="/tmp/demoexam_${name}_remote.log"
  rm -f "$out" "$err"
  echo "[..] $name: удалённое выполнение началось, подробный лог: $out"
  sshpass -p "$pass" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o UpdateHostKeys=no -o LogLevel=ERROR -o ConnectTimeout=10 -o PubkeyAuthentication=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 "$user@$ip" "bash -s" 2>"$err" <<< "$payload" | tee "$out" | sed -u -n 's/^REMOTE_STATUS: //p'
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
  sshpass -p "$pass" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o UpdateHostKeys=no -o LogLevel=ERROR -o ConnectTimeout=8 -o PubkeyAuthentication=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 "$user@$ip" "echo ok" >/dev/null 2>&1
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
    echo "[..] $title: пробую AUTO-PROBE порта на Eltex перед ручной подсказкой"
    case "$title" in
      HQ-SRV)
        autoprobe_hq_ports_if_needed || true
        ;;
      HQ-CLI)
        autoprobe_hq_ports_if_needed || true
        ;;
      BR-SRV)
        autoprobe_br_ports_if_needed || true
        ;;
    esac

    if ! check_ping "$ip"; then
      if [ "${NONINTERACTIVE:-0}" = "1" ]; then
        fail "$title не отвечает на ping — в параллельном режиме пропускаю этот узел"
        return 1
      fi
      "$hint_func"
      wait_enter
      check_ping "$ip" || { fail "$title не отвечает на ping"; return 1; }
    fi
  fi
  echo "[OK] $title ping есть"

  echo "[..] $title: проверяю первичный SSH root@$ip:22"
  if ! check_ssh "$ip" root "$ROOT_SSH_PASS"; then
    echo "[WARN] $title: первичный SSH не прошёл."
    echo "Проверь вручную с ISP:"
    echo "  ssh root@$ip"
    [ -s /tmp/demoexam_check_ssh.err ] && { echo "Последняя SSH-ошибка:"; tail -n 5 /tmp/demoexam_check_ssh.err; }

    if [ "${NONINTERACTIVE:-0}" = "1" ]; then
      fail "$title недоступен по SSH — в параллельном режиме пропускаю этот узел"
      return 1
    fi

    echo "Если вручную заходит — введи здесь тот же root-пароль."
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

  echo "[..] $title: отправляю команды настройки. Если долго — будут строки START/OK ниже"
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


repair_br_dnat(){
  echo "[..] BR-RTR: перепрописываю DNAT 172.16.2.2:8080 -> 192.168.30.2:8080 и SSH 2026"
  local ip="172.16.2.2" tmp="/tmp/demoexam_br_dnat_repair.expect" log="/tmp/demoexam_br_dnat_repair.log"
  cat > "$tmp" <<'EOF'
#!/usr/bin/expect -f
set timeout 120
set ip "172.16.2.2"
set user "net_admin"
set pass "P@ssw0rd"
log_user 1
proc c {cmd} {
    send_user -- "STEP CMD: $cmd\n"
    send -- "$cmd\r"
    expect {
        -re {More\?.*} { send " "; exp_continue }
        -re {[#>]} {}
        timeout { send_user -- "ERROR TIMEOUT: $cmd\n"; exit 20 }
        eof { send_user -- "ERROR EOF: $cmd\n"; exit 21 }
    }
}
spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o UpdateHostKeys=no -o LogLevel=ERROR -o ConnectTimeout=10 -o PubkeyAuthentication=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 $user@$ip
expect {
    -re {Are you sure you want to continue connecting.*} { send "yes\r"; exp_continue }
    -re {yes/no} { send "yes\r"; exp_continue }
    -re {fingerprint} { send "yes\r"; exp_continue }
    -re "(P|p)assword:" { send "$pass\r" }
    timeout { exit 10 }
    eof { exit 11 }
}
expect -re {[#>]}
c "configure terminal"
c "interface __BRR_ISP_PORT__"
c "ip firewall disable"
c "ip address 172.16.2.2/28"
c "ip nat proxy-arp PUBLIC_POOL"
c "exit"
c "interface __BRR_LAN_PORT__"
c "ip firewall disable"
c "ip address 192.168.30.1/28"
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
c "ip route 0.0.0.0/0 172.16.2.1"
c "ip ssh server"
c "do commit"
c "do confirm"
c "exit"
expect {
    -re {Do you still want to log out\?.*} { send "y\r"; exp_continue }
    eof {}
    timeout {}
}
EOF
  chmod +x "$tmp"
  sed -i \
    -e "s#__BRR_ISP_PORT__#$BRR_ISP_PORT#g" \
    -e "s#__BRR_LAN_PORT__#$BRR_LAN_PORT#g" "$tmp"
  "$tmp" > "$log" 2>&1 || { echo "[WARN] BR-RTR: DNAT repair завершился с ошибкой, лог $log"; tail -40 "$log"; return 1; }
  echo "[OK] BR-RTR: DNAT repair отправлен, лог $log"
  sleep 3
}


preflight_resume_status(){
  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "ПРЕДПРОВЕРКА / RESUME"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"
  check_ping 172.16.1.2 && echo "[READY] HQ-RTR ping 172.16.1.2" || echo "[MISS] HQ-RTR ping 172.16.1.2"
  check_ping 172.16.2.2 && echo "[READY] BR-RTR ping 172.16.2.2" || echo "[MISS] BR-RTR ping 172.16.2.2"
  check_ping 192.168.100.2 && echo "[READY] HQ-SRV ping 192.168.100.2" || echo "[MISS] HQ-SRV ping 192.168.100.2"
  check_ping 192.168.30.2 && echo "[READY] BR-SRV ping 192.168.30.2" || echo "[MISS] BR-SRV ping 192.168.30.2"
  check_ping 192.168.200.3 && echo "[READY] HQ-CLI ping 192.168.200.3" || echo "[MISS] HQ-CLI ping 192.168.200.3"
  curl -s --max-time 5 http://192.168.30.2:8080 | grep -qiE 'студент|html|сайт' \
    && echo "[READY] Docker direct http://192.168.30.2:8080" \
    || echo "[MISS] Docker direct http://192.168.30.2:8080"
  curl -s --max-time 5 http://172.16.2.2:8080 | grep -qiE 'студент|html|сайт' \
    && echo "[READY] BR DNAT http://172.16.2.2:8080" \
    || echo "[MISS] BR DNAT http://172.16.2.2:8080"
  echo "Скрипт можно запускать повторно: готовые части будут перезаписаны тем же конфигом или проверены, недостающие — дочинены."
  echo
}

final_checks(){
  check_ping 172.16.1.2 && ok "HQ-RTR отвечает" || fail "HQ-RTR не отвечает"
  check_ping 172.16.2.2 && ok "BR-RTR отвечает" || fail "BR-RTR не отвечает"
  check_ping 192.168.100.2 && ok "HQ-SRV отвечает" || fail "HQ-SRV не отвечает"
  check_ping 192.168.30.2 && ok "BR-SRV отвечает" || fail "BR-SRV не отвечает"
  check_ping 192.168.200.3 && ok "HQ-CLI отвечает" || fail "HQ-CLI не отвечает"

  echo "[..] Проверяю Docker-сайт напрямую на BR-SRV: http://192.168.30.2:8080"
  if curl -s --max-time 8 http://192.168.30.2:8080 | grep -qiE 'студент|html|сайт'; then
    ok "Docker-сайт напрямую 192.168.30.2:8080 доступен"
  else
    fail "Docker-сайт напрямую 192.168.30.2:8080 не проверен"
    echo "Проверь на BR-SRV: docker ps -a ; cd /opt/exam-app ; docker compose logs --tail=80"
  fi

  echo "[..] Проверяю DNAT BR-RTR: http://172.16.2.2:8080"
  if curl -s --max-time 8 http://172.16.2.2:8080 | grep -qiE 'студент|html|сайт'; then
    ok "DNAT BR-RTR 172.16.2.2:8080 доступен"
  else
    echo "[WARN] DNAT 172.16.2.2:8080 не ответил, перепрописываю NAT на BR-RTR и повторяю"
    repair_br_dnat || true
    if curl -s --max-time 8 http://172.16.2.2:8080 | grep -qiE 'студент|html|сайт'; then
      ok "DNAT BR-RTR 172.16.2.2:8080 доступен после repair"
    else
      fail "DNAT BR-RTR 172.16.2.2:8080 всё ещё не ответил"
      echo "Ручная проверка: ssh net_admin@172.16.2.2 ; show running-config | смотреть nat destination"
    fi
  fi

  if ! curl -s --max-time 8 http://172.16.1.2:8080 | grep -qiE 'html|php|сайт|студент|таблиц|<!doctype'; then
    echo "[WARN] HQ-SRV web upstream 172.16.1.2:8080 не проверен, чиню Apache/PHP/MariaDB"
    repair_hq_web_from_isp || true
  fi

  if curl -s --max-time 8 -u WEB:'P@ssw0rd' http://web.sirius-exam.org | grep -qiE 'html|php|сайт|студент|таблиц|<!doctype'; then
    ok "web.sirius-exam.org доступен"
  else
    echo "[WARN] web.sirius-exam.org не проверен, чиню Nginx reverse proxy на ISP и повторяю"
    repair_isp_proxy || true
    curl -s --max-time 8 -u WEB:'P@ssw0rd' http://web.sirius-exam.org | grep -qiE 'html|php|сайт|студент' \
      && ok "web.sirius-exam.org доступен после repair" \
      || fail "web.sirius-exam.org не проверен"
  fi
  curl -k -s -I --max-time 5 https://192.168.30.2 | grep -qi Strict-Transport-Security && ok "HSTS Nextcloud есть" || fail "HSTS Nextcloud не проверен"
}

run_parallel_linux_nodes(){
  say ""
  say "━━━━━━━━━━━━━━━━━━━━━━━━━━"
  say "ШАГ 4-6/7 — Linux-узлы параллельно"
  say "━━━━━━━━━━━━━━━━━━━━━━━━━━"
  say "[INFO] HQ-SRV, BR-SRV и HQ-CLI запускаются одновременно."
  say "[INFO] Если один узел недоступен или падает, остальные продолжают настраиваться."
  say "[INFO] Логи:"
  say "  /tmp/demoexam_parallel_hq_srv.log"
  say "  /tmp/demoexam_parallel_br_srv.log"
  say "  /tmp/demoexam_parallel_hq_cli.log"
  say ""

  get_root_ssh_pass_once

  rm -f /tmp/demoexam_parallel_hq_srv.log /tmp/demoexam_parallel_br_srv.log /tmp/demoexam_parallel_hq_cli.log

  echo "[PLAN] HQ-SRV: настроить сервер HQ-SRV: SSH, DNS/BIND, Chrony, NFS/RAID или /raid, Apache/PHP/MariaDB." | tee -a /tmp/demoexam_parallel_hq_srv.log
  (
    NONINTERACTIVE=1
    echo "REMOTE_STATUS: PLAN: HQ-SRV: начинаю настройку сервера HQ-SRV"
    configure_linux_device HQ-SRV hq_srv 192.168.100.2 linux_hint_hq_srv hq_srv_payload
  ) >> /tmp/demoexam_parallel_hq_srv.log 2>&1 &
  pid_hq_srv=$!

  echo "[PLAN] BR-SRV: настроить сервер BR-SRV: SSH, Docker/Compose, web-контейнер и сервисы филиала." | tee -a /tmp/demoexam_parallel_br_srv.log
  (
    NONINTERACTIVE=1
    echo "REMOTE_STATUS: PLAN: BR-SRV: начинаю настройку сервера BR-SRV"
    configure_linux_device BR-SRV br_srv 192.168.30.2 linux_hint_br_srv br_srv_payload
  ) >> /tmp/demoexam_parallel_br_srv.log 2>&1 &
  pid_br_srv=$!

  echo "[PLAN] HQ-CLI: настроить клиент HQ-CLI: SSH, сеть/DHCP, DNS-проверки и клиентские параметры." | tee -a /tmp/demoexam_parallel_hq_cli.log
  (
    NONINTERACTIVE=1
    echo "REMOTE_STATUS: PLAN: HQ-CLI: начинаю настройку клиента HQ-CLI"
    configure_linux_device HQ-CLI hq_cli 192.168.200.3 linux_hint_hq_cli hq_cli_payload
  ) >> /tmp/demoexam_parallel_hq_cli.log 2>&1 &
  pid_hq_cli=$!

  echo "[INFO] PID HQ-SRV=$pid_hq_srv, BR-SRV=$pid_br_srv, HQ-CLI=$pid_hq_cli"
  echo "[INFO] Пока идут установки, можно смотреть отдельные логи:"
  echo "  tail -f /tmp/demoexam_parallel_hq_srv.log"
  echo "  tail -f /tmp/demoexam_parallel_br_srv.log"
  echo "  tail -f /tmp/demoexam_parallel_hq_cli.log"

  hq_done=0
  br_done=0
  cli_done=0
  hq_rc=999
  br_rc=999
  cli_rc=999

  while [ "$hq_done" -eq 0 ] || [ "$br_done" -eq 0 ] || [ "$cli_done" -eq 0 ]; do
    if [ "$hq_done" -eq 0 ] && ! kill -0 "$pid_hq_srv" >/dev/null 2>&1; then
      wait "$pid_hq_srv"; hq_rc=$?
      hq_done=1
      echo "[DONE] HQ-SRV завершился с кодом $hq_rc"
      tail -n 25 /tmp/demoexam_parallel_hq_srv.log | sed 's/^/[HQ-SRV] /'
    fi

    if [ "$br_done" -eq 0 ] && ! kill -0 "$pid_br_srv" >/dev/null 2>&1; then
      wait "$pid_br_srv"; br_rc=$?
      br_done=1
      echo "[DONE] BR-SRV завершился с кодом $br_rc"
      tail -n 25 /tmp/demoexam_parallel_br_srv.log | sed 's/^/[BR-SRV] /'
    fi

    if [ "$cli_done" -eq 0 ] && ! kill -0 "$pid_hq_cli" >/dev/null 2>&1; then
      wait "$pid_hq_cli"; cli_rc=$?
      cli_done=1
      echo "[DONE] HQ-CLI завершился с кодом $cli_rc"
      tail -n 25 /tmp/demoexam_parallel_hq_cli.log | sed 's/^/[HQ-CLI] /'
    fi

    if [ "$hq_done" -eq 0 ] || [ "$br_done" -eq 0 ] || [ "$cli_done" -eq 0 ]; then
      echo ""
      echo "[WAIT] Linux-узлы ещё работают:"
      [ "$hq_done" -eq 0 ] && echo "  HQ-SRV PID=$pid_hq_srv, последние строки:" && tail -n 8 /tmp/demoexam_parallel_hq_srv.log | sed 's/^/    /'
      [ "$br_done" -eq 0 ] && echo "  BR-SRV PID=$pid_br_srv, последние строки:" && tail -n 8 /tmp/demoexam_parallel_br_srv.log | sed 's/^/    /'
      [ "$cli_done" -eq 0 ] && echo "  HQ-CLI PID=$pid_hq_cli, последние строки:" && tail -n 8 /tmp/demoexam_parallel_hq_cli.log | sed 's/^/    /'
      sleep 30
    fi
  done

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "ИТОГ ПАРАЛЛЕЛЬНЫХ LINUX-ШАГОВ"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"

  [ "$hq_rc" -eq 0 ] && ok "HQ-SRV настроен" || fail "HQ-SRV не настроен, смотри /tmp/demoexam_parallel_hq_srv.log"
  [ "$br_rc" -eq 0 ] && ok "BR-SRV настроен" || fail "BR-SRV не настроен, смотри /tmp/demoexam_parallel_br_srv.log"
  [ "$cli_rc" -eq 0 ] && ok "HQ-CLI настроен" || fail "HQ-CLI не настроен, смотри /tmp/demoexam_parallel_hq_cli.log"

  # Не возвращаем ошибку: финальная проверка покажет, что именно осталось доделать.
  return 0
}

main(){
  need_root
  run_until_ok "ПОДГОТОВКА — утилиты ISP" install_tools
  run_until_ok "ПОДГОТОВКА — автоопределение топологии" auto_from_bootstrap
  preflight_resume_status || true

  say "Центральная настройка с режимом skip-on-error."
  say "Если шаг упал: введи yes для повтора или no/Enter, чтобы перейти дальше."
  say "Linux-узлы HQ-SRV, BR-SRV и HQ-CLI запускаются параллельно."
  say "Ошибки: /tmp/demoexam_*.err"

  run_until_ok "ШАГ 1/7 — ISP" configure_isp
  run_until_ok "ШАГ 2/7 — HQ-RTR" configure_hq_rtr
  run_until_ok "ШАГ 3/7 — BR-RTR" configure_br_rtr

  run_until_ok "ШАГ 4-6/7 — Linux-узлы параллельно" run_parallel_linux_nodes

  if curl -s --max-time 8 http://192.168.30.2:8080 | grep -qiE 'студент|html|сайт'; then
    ok "BR-SRV Docker сайт отвечает напрямую"
    curl -s --max-time 8 http://172.16.2.2:8080 | grep -qiE 'студент|html|сайт' || repair_br_dnat || true
  else
    echo "[WARN] BR-SRV Docker сайт напрямую пока не ответил, финальная проверка покажет детали"
  fi

  run_until_ok "ШАГ 7/7 — финальные проверки" final_checks

  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "ПОДСКАЗКА ПО БРАУЗЕРУ"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Установка yandex-browser-stable отключена, чтобы скрипт не зависал на dnf."
  echo "После завершения установи браузер на HQ-CLI вручную с другого браузера или из локального rpm."
  echo "Проверка на HQ-CLI:"
  echo "  rpm -q yandex-browser-stable || echo 'Скачайте и установите браузер вручную'"
  echo
  echo "Готово. Статус: $STATUS_FILE"
  cat "$STATUS_FILE"
}

main "$@"
