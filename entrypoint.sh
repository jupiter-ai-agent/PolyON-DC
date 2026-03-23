#!/bin/bash
set -e

PROVISIONED="${HELIOS_PROVISIONED_FILE:-/var/lib/samba/.helios-provisioned}"
SETUP_JSON="/shared/setup.json"
PROGRESS_JSON="/shared/setup-progress.json"

# ── Helper: write progress ──
write_progress() {
    local phase="$1" step="$2" progress="$3"
    echo "{\"phase\":\"${phase}\",\"step\":\"${step}\",\"progress\":${progress}}" > "$PROGRESS_JSON"
}

# ── Check for factory reset signal ──
if [ -f "/shared/.helios-resetting" ]; then
    echo "[HELIOS] ⚠ Factory reset detected! Wiping domain data..."
    
    # Stop samba if running
    pkill samba 2>/dev/null || true
    sleep 2
    
    # Wipe samba data
    rm -rf /var/lib/samba/*
    rm -rf /etc/samba/smb.conf
    rm -rf /etc/krb5.conf
    
    # Remove provisioned marker
    rm -f "$PROVISIONED"
    
    echo "[HELIOS] Domain data wiped. Waiting for new setup..."
    write_progress "waiting" "설정 대기 중" 0
    
    # Remove reset signal (consumed)
    rm -f /shared/.helios-resetting
    
    # Fall through to setup.json wait loop below
fi

# ── Already provisioned → symlink configs & start ──
if [ -f "$PROVISIONED" ]; then
    echo "============================================="
    echo "  HELIOS - Samba AD Domain Controller"
    echo "  Domain already provisioned. Starting..."
    echo "============================================="

    # smb.conf: PVC(/var/lib/samba/smb.conf) → /etc/samba/smb.conf symlink
    mkdir -p /etc/samba /var/log/samba
    if [ -f "/var/lib/samba/smb.conf" ]; then
        ln -sf /var/lib/samba/smb.conf /etc/samba/smb.conf
        echo "[HELIOS] smb.conf linked from PVC"
    else
        echo "[HELIOS] ERROR: /var/lib/samba/smb.conf not found. Re-provisioning..."
        rm -f "$PROVISIONED"
        # Fall through to provisioning below
    fi

    # krb5.conf: PVC → /etc/krb5.conf symlink
    if [ -f "/var/lib/samba/private/krb5.conf" ]; then
        ln -sf /var/lib/samba/private/krb5.conf /etc/krb5.conf
        echo "[HELIOS] krb5.conf linked from PVC"
    fi

    if [ -f "$PROVISIONED" ]; then
        # Ensure shared marker exists for API
        touch /shared/.helios-provisioned 2>/dev/null || true
        write_progress "complete" "완료" 100

        echo "[HELIOS] Starting Samba AD DC..."
        exec samba --foreground --no-process-group
    fi
fi

# ── Not provisioned: wait for setup.json or use env defaults ──
# Read admin password from secret file or env
if [ -f "/run/secrets/admin_password" ]; then
    ADMIN_PASSWORD=$(cat /run/secrets/admin_password)
fi

# If no setup.json exists, wait for it (Setup Wizard flow)
if [ ! -f "$SETUP_JSON" ]; then
    echo "[HELIOS] Waiting for initial setup... (configure via HELIOS UI)"
    write_progress "waiting" "설정 대기 중" 0

    while [ ! -f "$SETUP_JSON" ]; do
        sleep 10
    done

    echo "[HELIOS] Setup configuration detected!"
fi

# ── Read configuration from setup.json ──
write_progress "reading" "설정 파일 읽기" 10

if [ -f "$SETUP_JSON" ]; then
    REALM=$(cat "$SETUP_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('realm','POLYON.DEV'))" 2>/dev/null || echo "POLYON.DEV")
    DOMAIN=$(cat "$SETUP_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('domain','POLYON'))" 2>/dev/null || echo "POLYON")
    DNS_FORWARDER=$(cat "$SETUP_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('dns_forwarder','8.8.8.8'))" 2>/dev/null || echo "8.8.8.8")
    FUNCTION_LEVEL=$(cat "$SETUP_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('function_level','2008_R2'))" 2>/dev/null || echo "2008_R2")
    # Use dc_admin_password if set, otherwise fall back to admin_password
    SETUP_PASSWORD=$(cat "$SETUP_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('dc_admin_password') or d.get('admin_password',''))" 2>/dev/null || echo "")
    if [ -n "$SETUP_PASSWORD" ]; then
        ADMIN_PASSWORD="$SETUP_PASSWORD"
    fi
fi

# Fallback to environment variables
REALM="${REALM:-POLYON.DEV}"
DOMAIN="${DOMAIN:-POLYON}"

# Ensure DOMAIN is NetBIOS name (first label only, max 15 chars, uppercase)
# If FQDN was passed (e.g. polyon.dev), extract first part
DOMAIN=$(echo "$DOMAIN" | cut -d. -f1 | tr '[:lower:]' '[:upper:]' | cut -c1-15)
DNS_FORWARDER="${DNS_FORWARDER:-8.8.8.8}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-ChangeMe123!}"

REALM_LOWER=$(echo "$REALM" | tr '[:upper:]' '[:lower:]')

echo "============================================="
echo "  HELIOS - Samba AD Domain Controller"
echo "  Realm: ${REALM}"
echo "  Domain: ${DOMAIN}"
echo "  Hostname: $(hostname)"
echo "============================================="

# ── Provision the domain ──
echo "[HELIOS] First run detected — provisioning AD domain..."
write_progress "provisioning" "samba-tool domain provision" 30

# Remove default configs
rm -f /etc/samba/smb.conf
rm -f /etc/krb5.conf
mkdir -p /etc/samba /var/log/samba

# Provision Samba AD DC
FUNCTION_LEVEL="${FUNCTION_LEVEL:-2008_R2}"
# Provision supports up to 2008_R2; higher levels via raise after start
case "$FUNCTION_LEVEL" in
    2003|2008|2008_R2) PROVISION_LEVEL="$FUNCTION_LEVEL" ;;
    *) PROVISION_LEVEL="2008_R2" ;;
esac

samba-tool domain provision \
    --use-rfc2307 \
    --realm="${REALM}" \
    --domain="${DOMAIN}" \
    --server-role=dc \
    --dns-backend=SAMBA_INTERNAL \
    --adminpass="${ADMIN_PASSWORD}" \
    --function-level="${PROVISION_LEVEL}" \
    --option="dns forwarder = ${DNS_FORWARDER}" \
    --option="log level = 1" \
    --option="log file = /var/log/samba/samba.log"

# ── Move smb.conf to PVC and symlink (survive container restarts) ──
write_progress "configuring" "SMB 설정 PVC 이전" 55

# Append HELIOS-specific settings to smb.conf
cat >> /etc/samba/smb.conf << EOF

# HELIOS container settings
	log level = 1
	log file = /var/log/samba/samba.log
	max log size = 10000
	bind interfaces only = no
	server services = s3fs, rpc, nbt, wrepl, ldap, cldap, kdc, drepl, winbindd, ntp_signd, kcc, dnsupdate
	ldap server require strong auth = no
EOF

# Move smb.conf to PVC, symlink back
cp /etc/samba/smb.conf /var/lib/samba/smb.conf
ln -sf /var/lib/samba/smb.conf /etc/samba/smb.conf
echo "[HELIOS] smb.conf moved to PVC and symlinked"

# Configure Kerberos (already in private/ which is in PVC)
write_progress "configuring" "Kerberos 설정" 60
ln -sf /var/lib/samba/private/krb5.conf /etc/krb5.conf
echo "[HELIOS] krb5.conf linked from PVC private/"

# Note: function levels 2012/2012_R2 can be raised via Settings UI after DC starts
# (samba provision only supports up to 2008_R2)

# Mark as provisioned
echo "$(date -Iseconds)" > "$PROVISIONED"
touch /shared/.helios-provisioned 2>/dev/null || true
write_progress "complete" "완료" 100

echo "[HELIOS] Domain provisioned successfully!"
echo "[HELIOS] Realm: ${REALM}"
echo "[HELIOS] Admin password set."

# ── Start Samba AD DC ──
echo "[HELIOS] Starting Samba AD DC..."
exec samba --foreground --no-process-group
