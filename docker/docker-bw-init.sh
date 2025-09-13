#!/bin/bash
set -e

SSH_DIR="/home/borgwarehouse/.ssh"
AUTHORIZED_KEYS_FILE="$SSH_DIR/authorized_keys"
REPOS_DIR="/home/borgwarehouse/repos"

print_green() {
  echo -e "\e[92m$1\e[0m"
}
print_red() {
  echo -e "\e[91m$1\e[0m"
}

# Ensure /run/sshd exists each start (tmpfs) and host keys are present
ensure_privsep_dir() {
  mkdir -p /run/sshd
  chmod 755 /run/sshd
  chown root:root /run/sshd
}

# Return 0 (true) if kernel is known-old (needs haveged), else 1 (false)
kernel_is_old() {
  local kmv
  kmv="$(uname -r | awk -F. '{printf("%s.%s\n",$1,$2)}')"
  [ "$kmv" = "3.10" ] || [ "$kmv" = "3.2" ]
}

# Start haveged only if entropy is low or kernel is old
maybe_start_haveged() {
  local ent
  ent="$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null || echo 0)"
  if kernel_is_old || [ "${ent:-0}" -lt 256 ]; then
    if command -v haveged >/dev/null 2>&1; then
      mkdir -p /home/borgwarehouse/logs
      print_green "Starting haveged (entropy_avail=${ent})..."
      haveged -F -w 1024 -D >/home/borgwarehouse/logs/haveged.log 2>&1 &
    else
      print_red "haveged not installed; old kernels may fail to provide sufficient entropy."
    fi
  else
    print_green "Entropy sufficient (entropy_avail=${ent}); not starting haveged."
  fi
}

init_ssh_server() {
  # If /etc/ssh appears empty, (re)generate host keys and seed moduli (best-effort)
  if [ -z "$(ls -A /etc/ssh 2>/dev/null)" ]; then
    print_green "/etc/ssh is empty, generating SSH host keys..."
    ssh-keygen -A
    [ -f /home/borgwarehouse/moduli ] && cp /home/borgwarehouse/moduli /etc/ssh/ || true
  fi

  # If no user-provided sshd_config mounted, copy the project default
  if [ ! -f "/etc/ssh/sshd_config" ]; then
    print_green "sshd_config not found in your volume, copying the default one..."
    cp /home/borgwarehouse/app/sshd_config /etc/ssh/
  fi
}

check_ssh_directory() {
  if [ ! -d "$SSH_DIR" ]; then
    print_red "The .ssh directory does not exist, you need to mount it as a docker volume."
    exit 1
  else
    chmod 700 "$SSH_DIR"
  fi
}

create_authorized_keys_file() {
  if [ ! -f "$AUTHORIZED_KEYS_FILE" ]; then
    print_green "The authorized_keys file does not exist, creating..."
    touch "$AUTHORIZED_KEYS_FILE"
  fi
  chmod 600 "$AUTHORIZED_KEYS_FILE"
}

check_repos_directory() {
  if [ ! -d "$REPOS_DIR" ]; then
    print_red "The repos directory does not exist, you need to mount it as a docker volume."
    exit 2
  else
    chmod 700 "$REPOS_DIR"
  fi
}

get_SSH_fingerprints() {
  print_green "Getting SSH fingerprints..."
  # Best-effort: only compute if keys exist
  [ -f /etc/ssh/ssh_host_rsa_key ] && \
    RSA_FINGERPRINT=$(ssh-keygen -lf /etc/ssh/ssh_host_rsa_key | awk '{print $2}') || true
  [ -f /etc/ssh/ssh_host_ed25519_key ] && \
    ED25519_FINGERPRINT=$(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key | awk '{print $2}') || true
  [ -f /etc/ssh/ssh_host_ecdsa_key ] && \
    ECDSA_FINGERPRINT=$(ssh-keygen -lf /etc/ssh/ssh_host_ecdsa_key | awk '{print $2}') || true

  [ -n "${RSA_FINGERPRINT:-}" ] && export SSH_SERVER_FINGERPRINT_RSA="$RSA_FINGERPRINT"
  [ -n "${ED25519_FINGERPRINT:-}" ] && export SSH_SERVER_FINGERPRINT_ED25519="$ED25519_FINGERPRINT"
  [ -n "${ECDSA_FINGERPRINT:-}" ] && export SSH_SERVER_FINGERPRINT_ECDSA="$ECDSA_FINGERPRINT"
}

check_env() {
  if [ -z "${CRONJOB_KEY:-}" ]; then
    CRONJOB_KEY=$(openssl rand -base64 32)
    print_green "CRONJOB_KEY not found or empty. Generating a random key..."
    export CRONJOB_KEY
  fi

  if [ -z "${NEXTAUTH_SECRET:-}" ]; then
    NEXTAUTH_SECRET=$(openssl rand -base64 32)
    print_green "NEXTAUTH_SECRET not found or empty. Generating a random key..."
    export NEXTAUTH_SECRET
  fi
}

check_env
#ensure_privsep_dir
init_ssh_server
check_ssh_directory
create_authorized_keys_file
check_repos_directory
maybe_start_haveged
get_SSH_fingerprints

print_green "Successful initialization. BorgWarehouse is ready !"
exec supervisord -c /home/borgwarehouse/app/supervisord.conf
